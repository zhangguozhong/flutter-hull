import Flutter
import Foundation

/// 独立控制通道只承载容器启动与关闭，业务仍走 Aeris。
public final class FlutterHullPlugin: NSObject, FlutterPlugin {
  private let channel: FlutterMethodChannel
  private var configuration: [String: Any]?
  private var runToken: String?
  private var closing = false
  private var reserved = false
  private var transportAvailable = true
  private var visible = true, foreground = true
  private var lifecycleRevision = 0
  var onSaveState: (([String: Any]) -> Void)?
  private var restorationRevision: Int64 = 0
  var onOpenNative: (([String: Any], @escaping FlutterResult) -> Void)?
  var onFinishContainer: (([String: Any]?, @escaping FlutterResult) -> Void)?
  var onCancelNavigation: ((String) -> Bool)?
  private var backRound = 0
  private var backWaiters: [(Bool) -> Void] = []
  public var onCommunicationReady: (() -> Void)?
  public var onFirstFrame: (() -> Void)?
  public var onRestart: (() -> Void)?
  var onEngineDetached: (() -> Void)?

  init(channel: FlutterMethodChannel) { self.channel = channel }
  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "leo_flutter/control", binaryMessenger: registrar.messenger())
    let plugin = FlutterHullPlugin(channel: channel)
    registrar.addMethodCallDelegate(plugin, channel: channel)
    registrar.publish(plugin)
  }
  func reserve() throws {
    guard !closing else {
      throw FlutterHullFailure.engineAlreadyBound
    }
    guard !reserved, configuration == nil else { throw FlutterHullFailure.engineInUse }
    reserved = true
  }
  func releaseReservation() { if configuration == nil && !closing { reserved = false } }
  func configure(_ configuration: [String: Any]) {
    self.configuration = configuration.merging([
      "visible": visible, "foreground": foreground, "lifecycleRevision": lifecycleRevision,
      "supportsRestoration": true,
    ]) {
      _, new in new
    }
  }
  func setLifecycle(visible: Bool? = nil, foreground: Bool? = nil) {
    lifecycleRevision += 1
    if let visible { self.visible = visible }
    if let foreground { self.foreground = foreground }
    guard !closing, transportAvailable, var value = configuration else { return }
    value["visible"] = self.visible
    value["foreground"] = self.foreground
    value["lifecycleRevision"] = lifecycleRevision
    configuration = value
    channel.invokeMethod(
      "hostLifecycle",
      arguments: [
        "containerId": value["containerId"] ?? "", "visible": self.visible,
        "foreground": self.foreground, "lifecycleRevision": lifecycleRevision,
      ])
  }
  func requestBack(_ completion: @escaping (Bool) -> Void) {
    guard !closing, transportAvailable else {
      completion(true)
      return
    }
    backWaiters.append(completion)
    guard backWaiters.count == 1 else { return }
    backRound += 1
    let round = backRound
    let finish = { [weak self] (handled: Bool) in
      guard let self, self.backRound == round else { return }
      let waiters = self.backWaiters
      self.backWaiters.removeAll()
      waiters.forEach { $0(handled) }
    }
    channel.invokeMethod("back", arguments: nil) { value in finish(value as? Bool ?? true) }
    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { finish(true) }
  }
  func prepareForEngineDestruction() {
    guard transportAvailable else { return }
    closing = true
    transportAvailable = false
    configuration = nil
    channel.setMethodCallHandler(nil)
    backRound += 1
    let waiters = backWaiters
    backWaiters.removeAll()
    waiters.forEach { $0(true) }
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard !closing || call.method == "cancelNavigation" else {
      result(FlutterError(code: "CLOSED", message: "容器正在关闭", details: nil))
      return
    }
    switch call.method {
    case "bootstrap":
      guard let token = (call.arguments as? [String: Any])?["runToken"] as? String, !token.isEmpty,
        token.utf8.count <= 256
      else {
        result(FlutterError(code: "INVALID_ARGUMENT", message: "缺少启动标记", details: nil))
        return
      }
      guard let configuration else {
        result(FlutterError(code: "NOT_READY", message: "原生绑定尚未完成", details: nil))
        return
      }
      if let previous = runToken, previous != token {
        result(FlutterError(code: "HOT_RESTART_REQUIRES_REOPEN", message: "请重新打开容器", details: nil))
        onRestart?()
        return
      }
      runToken = token
      result(configuration)
    case "saveState":
      guard let input = call.arguments as? [String: Any],
        let container = input["containerId"] as? String,
        container == configuration?["containerId"] as? String,
        let revision = FlutterHullRestoration.integer(input["revision"]), revision > 0,
        let snapshot = input["snapshot"], let copied = try? FlutterHullRestoration.copy(snapshot)
      else {
        result(FlutterError(code: "INVALID_ARGUMENT", message: "页面快照无效或容器已替换", details: nil))
        return
      }
      guard revision > restorationRevision else {
        result(false)
        return
      }
      restorationRevision = revision
      onSaveState?(copied)
      result(true)
    case "finishContainer":
      guard let handler = onFinishContainer,
        call.arguments == nil || call.arguments is [String: Any]
      else {
        result(false)
        return
      }
      handler(call.arguments as? [String: Any], result)
    case "openNative":
      guard let value = call.arguments as? [String: Any], let handler = onOpenNative else {
        result(FlutterError(code: "NAVIGATION_UNAVAILABLE", message: "原生导航未绑定", details: nil))
        return
      }
      handler(value, result)
    case "cancelNavigation":
      let id = (call.arguments as? [String: Any])?["navigationId"] as? String ?? ""
      _ = onCancelNavigation?(id)
      result(nil)
    case "communicationReady":
      onCommunicationReady?()
      result(nil)
    case "firstFrame":
      onFirstFrame?()
      result(nil)
    default: result(FlutterMethodNotImplemented)
    }
  }
  func shutdown(completion: @escaping () -> Void) {
    shutdownResult { result in if case .success = result { completion() } }
  }
  func shutdownResult(completion: @escaping (Result<Void, Error>) -> Void) {
    closing = true
    configuration = nil
    guard transportAvailable else {
      completion(.failure(FlutterHullCleanupError(code: "DART_UNAVAILABLE")))
      return
    }
    var delivered = false
    channel.invokeMethod("shutdown", arguments: nil) { value in
      guard !delivered else { return }
      delivered = true
      if value is FlutterError || (value as AnyObject?) === (FlutterMethodNotImplemented as AnyObject) {
        completion(.failure(FlutterHullCleanupError(code: "DART_SHUTDOWN_FAILED")))
      } else {
        // 不设置兜底完成；只有 Dart 的真实 drain 响应可以越过此屏障。
        completion(.success(()))
      }
    }
  }
  func queryCleanup(completion: @escaping (Result<[[String: Any]], Error>) -> Void) {
    guard transportAvailable else {
      completion(.failure(FlutterHullCleanupError(code: "DART_UNAVAILABLE"))); return
    }
    channel.invokeMethod("cleanupResources", arguments: nil) { value in
      guard let rows = value as? [[String: Any]], rows.count <= 64 else {
        completion(.failure(FlutterHullCleanupError(code: "DART_QUERY_FAILED"))); return
      }
      completion(.success(rows))
    }
  }
  func queryCleanupPage(offset: Int, limit: Int,
    completion: @escaping (Result<[String: Any], Error>) -> Void) {
    guard offset >= 0, limit > 0, limit <= 64 else {
      completion(.failure(FlutterHullCleanupError(code: "INVALID_ARGUMENT"))); return
    }
    guard transportAvailable else {
      completion(.failure(FlutterHullCleanupError(code: "DART_UNAVAILABLE"))); return
    }
    channel.invokeMethod("cleanupResourcesPage", arguments: ["offset": offset, "limit": limit]) { value in
      guard let page = value as? [String: Any], let rows = page["items"] as? [[String: Any]],
        rows.count <= limit, page["offset"] as? Int == offset, page["limit"] as? Int == limit,
        let total = page["total"] as? Int, total >= 0 else {
        completion(.failure(FlutterHullCleanupError(code: "DART_QUERY_FAILED"))); return
      }
      completion(.success(page))
    }
  }
  func retryCleanup(resourceId: String, completion: @escaping (Result<Bool, Error>) -> Void) {
    guard transportAvailable else {
      completion(.failure(FlutterHullCleanupError(code: "DART_UNAVAILABLE"))); return
    }
    channel.invokeMethod("retryCleanup", arguments: ["resourceId": resourceId]) { value in
      guard let accepted = value as? Bool else {
        completion(.failure(FlutterHullCleanupError(code: "DART_RETRY_FAILED"))); return
      }
      completion(.success(accepted))
    }
  }
  public func detachFromEngine(for registrar: FlutterPluginRegistrar) {
    let callback = onEngineDetached
    onEngineDetached = nil
    callback?()
    prepareForEngineDestruction()
    closing = true
    configuration = nil
    onRestart = nil
    onCommunicationReady = nil
    onFirstFrame = nil
  }
}
