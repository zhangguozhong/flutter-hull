import Foundation

/// 取消只结算一次；若 Dart 已创建页面，仍由其 Scope 清理屏障持有资源。
@MainActor public final class FlutterHullRoutingOperation {
  public let requestId: String
  private let cancellation: () -> Void
  init(_ id: String, cancellation: @escaping () -> Void) {
    requestId = id
    self.cancellation = cancellation
  }
  public func cancel() { cancellation() }
}

/// 冷启动与活动页面共用队列；不记录 URL 或业务参数到诊断。
@MainActor final class FlutterHullRoutingQueue {
  typealias Completion = (Result<[String: Any]?, Error>) -> Void
  typealias Send = (String, [String: Any], @escaping Completion) -> Void
  private final class Entry {
    let operation: FlutterHullRoutingOperation
    let method: String
    let arguments: [String: Any]
    let dedupe: String?
    var completions: [Completion]
    var timer: Timer?
    var dispatched = false
    init(
      _ operation: FlutterHullRoutingOperation, method: String, arguments: [String: Any],
      dedupe: String?, completion: @escaping Completion
    ) {
      self.operation = operation
      self.method = method
      self.arguments = arguments
      self.dedupe = dedupe
      completions = [completion]
    }
  }
  private var entries: [String: Entry] = [:]
  private var order: [String] = []
  private var send: Send?
  private var cancelTransport: ((String) -> Void)?
  var count: Int { entries.count }

  @discardableResult func open(
    method: String, arguments: [String: Any], dedupe: String? = nil,
    timeout: TimeInterval = 30, completion: @escaping Completion
  ) -> FlutterHullRoutingOperation {
    if let dedupe, let existing = entries.values.first(where: { $0.dedupe == dedupe }) {
      // 重复请求的观察者也有上限，不能用同一 URL 绕过容量。
      if existing.completions.count < 32 {
        existing.completions.append(completion)
      } else {
        completion(.failure(FlutterHullCleanupError(code: "BACKPRESSURE")))
      }
      return existing.operation
    }
    let id = UUID().uuidString
    let operation = FlutterHullRoutingOperation(id) { [weak self] in
      self?.cancel(id, code: "CANCELLED")
    }
    guard entries.count < 32, timeout.isFinite, timeout > 0, timeout <= 86400 else {
      completion(.failure(FlutterHullCleanupError(code: "BACKPRESSURE")))
      return operation
    }
    let entry = Entry(
      operation, method: method, arguments: arguments, dedupe: dedupe, completion: completion)
    entries[id] = entry
    order.append(id)
    entry.timer = Timer.scheduledTimer(withTimeInterval: timeout, repeats: false) { [weak self] _ in
      Task { @MainActor in self?.cancel(id, code: "NAVIGATION_TIMEOUT") }
    }
    dispatch(id)
    return operation
  }
  func activate(send: @escaping Send, cancel: @escaping (String) -> Void) {
    self.send = send
    cancelTransport = cancel
    for id in order { dispatch(id) }
  }
  func deactivate(code: String = "CANCELLED") {
    for id in order { cancel(id, code: code) }
    send = nil
    cancelTransport = nil
  }
  private func dispatch(_ id: String) {
    guard let entry = entries[id], !entry.dispatched, let send else { return }
    entry.dispatched = true
    send(entry.method, entry.arguments.merging(["requestId": id]) { _, new in new }) {
      [weak self] result in
      self?.finish(id, result: result)
    }
  }
  private func cancel(_ id: String, code: String) {
    guard let entry = entries[id] else { return }
    if entry.dispatched { cancelTransport?(id) }
    finish(id, result: .failure(FlutterHullCleanupError(code: code)))
  }
  private func finish(_ id: String, result: Result<[String: Any]?, Error>) {
    guard let entry = entries.removeValue(forKey: id) else { return }
    order.removeAll { $0 == id }
    entry.timer?.invalidate()
    entry.completions.forEach { $0(result) }
  }
}
