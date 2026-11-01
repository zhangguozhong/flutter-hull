import Foundation

public enum FlutterHullFailure: Error {
  case engineInUse, engineAlreadyBound, invalidContext, invalidOwnership, closed, cleanupTimeout,
    engineStartFailed, pluginMissing, invalidRestorationState
}

/// 只允许框架错误代码进入诊断，避免带入业务错误消息。
public struct FlutterHullCleanupError: Error {
  public let code: String
  public init(code: String) {
    self.code = code.range(of: "^[A-Z][A-Z0-9_]{0,63}$", options: .regularExpression) != nil
      ? code : "CLEANUP_FAILED"
  }
}
public enum FlutterHullCleanupState: String { case registered, running, failed, completed }
public struct FlutterHullCleanupResource {
  public let resourceId: String
  public let name: String
  public let owner: String
  public let elapsedMs: Double
  public let state: FlutterHullCleanupState
  public let attempt: Int
  public let retryable: Bool
  public let errorCode: String?
}

/// 真实完成之前保留清理闭包；超时只报告结果，不宣称资源已释放。
@MainActor public final class FlutterHullCleanupRegistry {
  private struct Entry {
    let id: String
    let name: String
    let owner: String
    let retryable: Bool
    let legacy: Bool
    var cleanup: ((@escaping (Result<Void, Error>) -> Void) -> Void)?
    var state: FlutterHullCleanupState = .registered
    var attempt = 0
    var startedAt: TimeInterval?
    var elapsedMs: Double = 0
    var errorCode: String?
  }
  private var entries: [String: Entry] = [:]
  private var order: [String] = []
  private var waiters: [(Result<Void, Error>) -> Void] = []
  private var retention: FlutterHullCleanupRegistry?
  private var closing = false
  private var drained = false
  private var outcome: Result<Void, Error>?
  public var onDrained: (() -> Void)?
  public var onResourceChanged: ((FlutterHullCleanupResource) throws -> Void)?
  public var pendingCount: Int { entries.values.filter { $0.state != .completed }.count }
  public var resources: [FlutterHullCleanupResource] {
    order.compactMap { entries[$0].map(snapshot) }
  }
  public let maxResources: Int
  public init(maxResources: Int = 512) {
    precondition(maxResources > 0, "资源容量必须为正整数")
    self.maxResources = maxResources
  }
  public var statistics: [String: Int] {
    ["registered": entries.values.filter { $0.state == .registered }.count,
     "running": entries.values.filter { $0.state == .running }.count,
     "failed": entries.values.filter { $0.state == .failed }.count,
     "total": entries.count, "limit": maxResources]
  }
  /// 分页只复制当前页；完成项从登记表移除并归还容量。
  public func resourcePage(offset: Int = 0, limit: Int = 64) throws -> [FlutterHullCleanupResource] {
    guard offset >= 0, limit > 0, limit <= 64 else {
      throw FlutterHullCleanupError(code: "INVALID_ARGUMENT")
    }
    return order.dropFirst(offset).prefix(limit).compactMap { entries[$0].map(snapshot) }
  }

  public func register(_ cleanup: @escaping (@escaping () -> Void) -> Void) throws
    -> FlutterHullCleanupTicket
  {
    try add(name: "legacy", owner: "", retryable: false, legacy: true) { done in
      cleanup { done(.success(())) }
    }
  }
  public func register(name: String, owner: String,
    _ cleanup: @escaping (@escaping () -> Void) -> Void) throws -> FlutterHullCleanupTicket {
    try add(name: name, owner: owner, retryable: false, legacy: true) { done in
      cleanup { done(.success(())) }
    }
  }
  public func registerOperation(
    name: String, owner: String, retryable: Bool = false,
    cleanup: @escaping (@escaping (Result<Void, Error>) -> Void) -> Void
  ) throws -> FlutterHullCleanupTicket {
    try add(name: name, owner: owner, retryable: retryable, legacy: false, cleanup: cleanup)
  }
  private func add(
    name: String, owner: String, retryable: Bool, legacy: Bool,
    cleanup: @escaping (@escaping (Result<Void, Error>) -> Void) -> Void
  ) throws -> FlutterHullCleanupTicket {
    guard !closing else { throw FlutterHullFailure.closed }
    guard entries.count < maxResources else {
      throw FlutterHullCleanupError(code: "RESOURCE_CAPACITY_EXCEEDED")
    }
    let id = UUID().uuidString
    entries[id] = Entry(id: id, name: name, owner: owner, retryable: retryable,
      legacy: legacy, cleanup: cleanup)
    order.append(id)
    notify(id)
    return FlutterHullCleanupTicket(resourceId: id, cancel: { [weak self] in self?.start(id) },
      finish: { [weak self] in
        // 旧 ticket 支持业务主动完成；新操作只接受本轮 Result，不能绕过失败或轮次隔离。
        guard let self, self.entries[id]?.legacy == true else { return }
        self.finish(id, attempt: self.entries[id]?.attempt ?? 0, result: .success(()))
      })
  }
  @discardableResult public func retry(resourceId: String) -> Bool {
    guard let entry = entries[resourceId], entry.state == .failed, entry.retryable else { return false }
    entries[resourceId]?.state = .registered
    start(resourceId)
    return true
  }
  public func close(timeout: TimeInterval, completion: @escaping (Result<Void, Error>) -> Void) {
    if let outcome { completion(outcome); return }
    waiters.append(completion)
    guard !closing else { return }
    closing = true
    retention = self
    let deadline = DispatchTime.now() + max(0, timeout)
    DispatchQueue.main.asyncAfter(deadline: deadline) { [weak self] in
      guard let self, self.outcome == nil else { return }
      self.complete(.failure(FlutterHullFailure.cleanupTimeout))
    }
    for id in order { start(id) }
    checkDrained()
  }
  private func start(_ id: String) {
    guard var entry = entries[id], entry.state == .registered,
      let cleanup = entry.cleanup else { return }
    entry.state = .running
    entry.attempt += 1
    entry.startedAt = ProcessInfo.processInfo.systemUptime
    entry.errorCode = nil
    entries[id] = entry
    let attempt = entry.attempt
    notify(id)
    // 观察者可能同步完成旧 ticket；只有仍属于本轮的运行项才可执行清理。
    guard let current = entries[id], current.attempt == attempt, current.state == .running else { return }
    cleanup { [weak self] result in
      if Thread.isMainThread { self?.finish(id, attempt: attempt, result: result) }
      else { DispatchQueue.main.async { self?.finish(id, attempt: attempt, result: result) } }
    }
  }
  private func finish(_ id: String, attempt: Int, result: Result<Void, Error>) {
    guard var entry = entries[id], entry.attempt == attempt,
      entry.state == .running || (entry.legacy && entry.state == .registered) else { return }
    entry.elapsedMs = elapsed(entry)
    entry.startedAt = nil
    switch result {
    case .success:
      entry.state = .completed
      entry.cleanup = nil
    case .failure(let error):
      entry.state = .failed
      entry.errorCode = (error as? FlutterHullCleanupError)?.code ?? "CLEANUP_FAILED"
    }
    entries[id] = entry
    if entry.state == .completed {
      entries.removeValue(forKey: id)
      order.removeAll { $0 == id }
    }
    try? onResourceChanged?(snapshot(entry))
    checkDrained()
  }
  private func elapsed(_ entry: Entry) -> Double {
    entry.startedAt.map { max(0, ProcessInfo.processInfo.systemUptime - $0) * 1000 }
      ?? entry.elapsedMs
  }
  private func snapshot(_ entry: Entry) -> FlutterHullCleanupResource {
    FlutterHullCleanupResource(resourceId: entry.id, name: entry.name, owner: entry.owner,
      elapsedMs: elapsed(entry), state: entry.state, attempt: entry.attempt,
      retryable: entry.retryable, errorCode: entry.errorCode)
  }
  private func notify(_ id: String) {
    if let entry = entries[id] { try? onResourceChanged?(snapshot(entry)) }
  }
  private func checkDrained() {
    guard closing, pendingCount == 0, !drained else { return }
    drained = true
    if outcome == nil { complete(.success(())) }
    let callback = onDrained
    onDrained = nil
    callback?()
    retention = nil
  }
  private func complete(_ value: Result<Void, Error>) {
    guard outcome == nil else { return }
    outcome = value
    let current = waiters
    waiters.removeAll()
    current.forEach { $0(value) }
  }
}

@MainActor public final class FlutterHullCleanupTicket {
  public let resourceId: String
  private let cancelAction: () -> Void
  private let finishAction: () -> Void
  fileprivate init(resourceId: String, cancel: @escaping () -> Void, finish: @escaping () -> Void) {
    self.resourceId = resourceId
    cancelAction = cancel
    finishAction = finish
  }
  public func cancel() { cancelAction() }
  public func finish() { finishAction() }
}
