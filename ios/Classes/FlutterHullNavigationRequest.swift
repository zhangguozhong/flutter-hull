import Aeris
import Flutter
import Foundation

/// 一个 Native 导航请求；先安装 onClose 再展示 UI。正常返回也等真实清理完成。
@MainActor public final class FlutterHullNavigationRequest {
  public let navigationId: String
  public let pageId: String
  public let route: String
  public let arguments: [String: Any]
  public let context: BridgeUIContext
  public var onClose: ((@escaping () -> Void) -> Void)?
  public private(set) var isCancelled = false
  private var ending = false
  private var delivered = false
  private var outcome: Any?
  private let reply: FlutterResult
  private let finished: () -> Void
  var ticket: FlutterHullCleanupTicket?
  init(
    id: String, page: String, route: String, arguments: [String: Any], context: BridgeUIContext,
    reply: @escaping FlutterResult, finished: @escaping () -> Void
  ) {
    navigationId = id
    pageId = page
    self.route = route
    self.arguments = arguments
    self.context = context
    self.reply = reply
    self.finished = finished
  }
  nonisolated public func complete(_ result: [String: Any]? = nil) {
    do {
      // 在交接之前复制，后台调用方随后修改输入也不会污染结果。
      let copied = try result.map { try FlutterHullJSON.object($0) }
      onMain { [self] in
        guard !ending else { return }
        outcome = copied
        ending = true
        ticket?.cancel()
      }
    } catch { fail("INVALID_RESULT", message: "导航结果必须是受限 JSON 对象") }
  }
  nonisolated public func fail(_ code: String, message: String) {
    onMain { [self] in
      guard !ending else { return }
      outcome = FlutterError(code: code, message: message, details: nil)
      ending = true
      ticket?.cancel()
    }
  }
  nonisolated private func onMain(_ action: @escaping @MainActor () -> Void) {
    if Thread.isMainThread {
      MainActor.assumeIsolated { action() }
    } else {
      DispatchQueue.main.async { action() }
    }
  }
  func cancel() {
    isCancelled = true
    ending = true
    deliver(FlutterError(code: "NAVIGATION_CANCELLED", message: "导航已取消", details: nil))
    ticket?.cancel()
  }
  func cleanup(_ done: @escaping () -> Void) {
    var drained = false
    let drain = { [self] in
      guard !drained else { return }
      drained = true
      if !isCancelled { deliver(outcome) }
      ticket?.finish()
      ticket = nil
      onClose = nil
      finished()
      done()
    }
    let finish: () -> Void = {
      if Thread.isMainThread { drain() } else { DispatchQueue.main.async(execute: drain) }
    }
    if let onClose { onClose(finish) } else { finish() }
  }
  private func deliver(_ value: Any?) {
    guard !delivered else { return }
    delivered = true
    reply(value)
  }
}

@MainActor final class FlutterHullNavigationStore {
  private let registry: FlutterHullCleanupRegistry
  private let context: BridgeUIContext
  private let onOpen: ((FlutterHullNavigationRequest) throws -> Void)?
  private var active: [String: FlutterHullNavigationRequest] = [:]
  var activeCount: Int { active.count }
  private var closing = false
  private var transportAvailable = true
  init(
    registry: FlutterHullCleanupRegistry, context: BridgeUIContext,
    onOpen: ((FlutterHullNavigationRequest) throws -> Void)?
  ) {
    self.registry = registry
    self.context = context
    self.onOpen = onOpen
  }
  func open(_ input: [String: Any], reply: @escaping FlutterResult) {
    guard !closing else {
      reply(FlutterError(code: "CLOSED", message: "导航已关闭", details: nil))
      return
    }
    guard let id = input["navigationId"] as? String, !id.isEmpty, id.utf8.count <= 256,
      let page = input["pageId"] as? String, !page.isEmpty, page.utf8.count <= 256,
      let route = input["route"] as? String, !route.isEmpty, route.utf8.count <= 512,
      let raw = input["arguments"],
      let arguments = try? FlutterHullJSON.object(raw)
    else {
      reply(FlutterError(code: "INVALID_ARGUMENT", message: "无效导航参数", details: nil))
      return
    }
    guard active[id] == nil, active.count < 32 else {
      reply(FlutterError(code: "BACKPRESSURE", message: "导航重复或配额已满", details: nil))
      return
    }
    guard let onOpen else {
      reply(FlutterError(code: "NAVIGATION_UNAVAILABLE", message: "宿主未提供原生导航", details: nil))
      return
    }
    let request = FlutterHullNavigationRequest(
      id: id, page: page, route: route, arguments: arguments, context: context,
      reply: { [weak self] value in if self?.transportAvailable == true { reply(value) } },
      finished: { [weak self] in self?.active.removeValue(forKey: id) })
    do {
      active[id] = request
      request.ticket = try registry.register(name: "nativeNavigation", owner: request.pageId) { done in request.cleanup(done) }
      try onOpen(request)
    } catch {
      if request.ticket == nil {
        active.removeValue(forKey: id)
        reply(FlutterError(code: "CLOSED", message: "资源作用域已关闭", details: nil))
      } else {
        request.fail("NAVIGATION_FAILED", message: String(describing: error))
      }
    }
  }
  func cancel(_ id: String) -> Bool {
    guard let request = active[id] else { return false }
    request.cancel()
    return true
  }
  func sealTransport() { transportAvailable = false }
  func close(transportAvailable: Bool) {
    self.transportAvailable = self.transportAvailable && transportAvailable
    closing = true
    for request in Array(active.values) { request.cancel() }
  }
}
