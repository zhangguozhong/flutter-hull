import Aeris
import AerisContracts
import Flutter
import UIKit
import aeris_flutter

public enum FlutterHullEngineOwnership: String { case owned, external }

public enum FlutterHullDevelopmentReopenResult {
  case owned(UIViewController)
  case hostRebuildRequired
}

/// 默认无观察者；只记录框架元数据，业务观察者抛错被隔离。
public final class FlutterHullDiagnostics {
  private let clock: () -> TimeInterval
  private let observer: (([String: Any]) throws -> Void)?
  public init(
    clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
    observer: (([String: Any]) throws -> Void)? = nil
  ) {
    self.clock = clock
    self.observer = observer
  }
  func now() -> TimeInterval { clock() }
  func emit(_ event: [String: Any]) { try? observer?(event) }
}

/// open 创建的 Engine 由容器销毁；attach 只借用 Runner 的 Engine。
@MainActor public final class FlutterHullCoordinator {
  public var diagnostics = FlutterHullDiagnostics()
  /// 仅调试构建接收 runToken 变化；业务显式调用 helper 决定重开或交还 Runner。
  public var onDevelopmentReopenRequested: (() -> Void)?
  private var generation = 0
  private var openingStarted: TimeInterval = 0
  private var openingTimings: [String: Any] = [:]
  private var lastTimings: [String: Any] = [:]
  private var reopening = false
  private var reopenWaiters: [(Result<FlutterHullDevelopmentReopenResult, Error>) -> Void] = []
  public var diagnosticSnapshot: [String: Any] {
    var result = record?.timings ?? lastTimings
    result["containerId"] = record?.id ?? ""
    result["generation"] = generation
    result["engineCount"] = record == nil ? 0 : 1
    result["managerEngineCount"] = engineManager.activeEngineCount
    result["cleanupPending"] = (record?.cleanup.pendingCount ?? 0) + (record?.dartBarrier.pendingCount ?? 0)
    result["navigation"] = record?.navigation?.activeCount ?? 0
    result["communicationReady"] = communicationReady
    result["firstFrameReady"] = firstFrameReady
    result["closing"] = record?.closing ?? false
    return result
  }
  private func diagnose(_ phase: String, current: Record? = nil, errorCode: String? = nil) {
    let target = current ?? record
    var event: [String: Any] = [
      "phase": phase, "timestampMicros": diagnostics.now() * 1_000_000,
      "thread": Thread.isMainThread ? "main" : (Thread.current.name ?? "unnamed"),
      "mainThread": Thread.isMainThread, "enginePolicy": String(describing: engineManager.policy),
      "sinceOpenMs": max(0, diagnostics.now() - openingStarted) * 1000,
      "containerId": target?.id ?? "", "generation": generation, "counts": diagnosticSnapshot,
    ]
    if let errorCode { event["errorCode"] = errorCode }
    diagnostics.emit(event)
  }
  private let bridgeEngine: BridgeEngine
  private let engineManager: FlutterHullEngineManager
  private let hostCallbacks: FlutterHullHostCallbacks?
  public private(set) var restorationState: [String: Any]?
  private let registerPlugins: (FlutterEngine) -> Void
  private let permissions: Set<String>
  private let topics: Set<String>?
  public var onCloseRequested: (() -> Void)?
  public var onResult: ((Result<[String: Any]?, Error>) -> Void)?
  public var onOpenNative: ((FlutterHullNavigationRequest) throws -> Void)?
  private var closingRetention: FlutterHullCoordinator?
  private var hostVisible = true, hostForeground = true
  private var record: Record?
  private var closeWaiters: [(Result<Void, Error>) -> Void] = []
  private var closeOutcome: Result<Void, Error>?
  public private(set) var destroyedEngineCount = 0
  public private(set) var detachedEngineCount = 0
  public var isOpen: Bool { record != nil }
  public var communicationReady: Bool { record?.communicationReady == true }
  public var firstFrameReady: Bool { record?.firstFrameReady == true }
  public var cleanup: FlutterHullCleanupRegistry? { record?.cleanup }
  public var cleanupResources: [FlutterHullCleanupResource] {
    (record?.cleanup.resources ?? []) + (record?.dartBarrier.resources ?? [])
  }
  @discardableResult public func retryCleanup(resourceId: String) -> Bool {
    (record?.cleanup.retry(resourceId: resourceId) ?? false)
      || (record?.dartBarrier.retry(resourceId: resourceId) ?? false)
  }
  public func queryDartCleanup(completion: @escaping (Result<[[String: Any]], Error>) -> Void) {
    guard let current = record, !current.engineUnavailable else {
      completion(.failure(FlutterHullCleanupError(code: "DART_UNAVAILABLE"))); return
    }
    current.control.queryCleanup(completion: completion)
  }
  public func queryDartCleanupPage(offset: Int = 0, limit: Int = 64,
    completion: @escaping (Result<[String: Any], Error>) -> Void) {
    guard let current = record, !current.engineUnavailable else {
      completion(.failure(FlutterHullCleanupError(code: "DART_UNAVAILABLE"))); return
    }
    current.control.queryCleanupPage(offset: offset, limit: limit, completion: completion)
  }
  public func retryDartCleanup(resourceId: String, completion: @escaping (Result<Bool, Error>) -> Void) {
    guard let current = record, !current.engineUnavailable else {
      completion(.failure(FlutterHullCleanupError(code: "DART_UNAVAILABLE"))); return
    }
    current.control.retryCleanup(resourceId: resourceId, completion: completion)
  }
  public var activeEngine: FlutterEngine? {
    record?.engineUnavailable == true ? nil : record?.engine
  }
  public func setVisible(_ visible: Bool) {
    hostVisible = visible
    record?.control.setLifecycle(visible: visible)
  }
  public func setForeground(_ foreground: Bool) {
    hostForeground = foreground
    record?.control.setLifecycle(foreground: foreground)
  }
  public func requestBack(completion: @escaping (Bool) -> Void) {
    guard let record, !record.closing else {
      completion(true)
      return
    }
    record.control.requestBack(completion)
  }
  public var engineOwnership: FlutterHullEngineOwnership? { record?.ownership }

  public init(
    engine: BridgeEngine, allowedPermissions: Set<String> = [],
    allowedEventTopics: Set<String>? = nil,
    engineManager: FlutterHullEngineManager? = nil,
    hostCallbacks: FlutterHullHostCallbacks? = nil,
    registerPlugins: @escaping (FlutterEngine) -> Void = { _ in }
  ) {
    bridgeEngine = engine
    self.engineManager = engineManager ?? FlutterHullEngineManager(policy: .single)
    self.hostCallbacks = hostCallbacks
    permissions = allowedPermissions
    topics = allowedEventTopics
    self.registerPlugins = registerPlugins
  }
  public func open(
    route: String = "/", arguments: [String: Any] = [:], restorationState: [String: Any]? = nil
  ) throws -> UIViewController {
    try validate(route: route, arguments: arguments)
    openingStarted = diagnostics.now()
    let restored = try restorationState.map { try FlutterHullRestoration.copy($0) }
    diagnose("engineCreating")
    let lease = try engineManager.acquire(clock: diagnostics.now)
    openingTimings = lease.startupTimings
    diagnose("engineCreated")
    diagnose("dartStarted")
    let engine = lease.engine
    let pluginStartedAt = diagnostics.now()
    registerPlugins(engine)
    openingTimings["pluginConfigureMs"] = max(0, diagnostics.now() - pluginStartedAt) * 1000
    diagnose("pluginsConfigured")
    let viewStartedAt = diagnostics.now()
    let page = FlutterHullViewController()
    do {
      let child = FlutterViewController(engine: engine, nibName: nil, bundle: nil)
      page.embed(child)
      try bind(
        engine: engine, context: BridgeUIContext(containerViewController: page), page: page,
        ownership: .owned, route: route, arguments: arguments, restoration: restored, lease: lease)
      if let current = record {
        current.timings["viewBindMs"] = max(0, diagnostics.now() - viewStartedAt) * 1000
        diagnose("viewBound")
      }
      hostCallbacks?.bind(engine: engine)
      page.onVisibility = { [weak self] in self?.setVisible($0) }
      page.onRemoved = { [weak self] in self?.close { _ in } }
      return page
    } catch {
      page.detach()
      lease.destroy()
      throw error
    }
  }
  public func attach(
    to engine: FlutterEngine, viewController: FlutterViewController,
    route: String = "/", arguments: [String: Any] = [:]
  ) throws {
    try validate(route: route, arguments: arguments)
    openingStarted = diagnostics.now()
    openingTimings = [:]
    guard viewController.engine === engine, engine.viewController === viewController else {
      throw FlutterHullFailure.invalidContext
    }
    try bind(
      engine: engine, context: BridgeUIContext(containerViewController: viewController), page: nil,
      ownership: .external, route: route, arguments: arguments)
  }
  private func validate(route: String, arguments: [String: Any]) throws {
    guard record == nil else { throw FlutterHullFailure.engineInUse }
    guard !route.isEmpty, route.utf8.count <= 512, (try? FlutterHullJSON.object(arguments)) != nil
    else {
      throw FlutterHullFailure.engineStartFailed
    }
  }
  private func bind(
    engine: FlutterEngine, context: BridgeUIContext, page: FlutterHullViewController?,
    ownership: FlutterHullEngineOwnership, route: String, arguments: [String: Any],
    restoration: [String: Any]? = nil, lease: FlutterHullEngineLease? = nil
  ) throws {
    guard
      let control = engine.valuePublished(byPlugin: "FlutterHullPlugin")
        as? FlutterHullPlugin,
      let plugin = engine.valuePublished(byPlugin: AerisFlutterBridgePluginKey)
        as? any AerisFlutterModuleBinding
    else {
      throw FlutterHullFailure.pluginMissing
    }
    let copiedArguments = try FlutterHullJSON.object(arguments)
    try control.reserve()
    do {
      let factory = try AerisBridgeReceiverFactory(
        engine: bridgeEngine, source: .flutter,
        allowedPermissions: permissions, allowedEventTopics: topics)
      factory.bindUIContext(context)
      let receiver = factory.makeReceiver { [weak plugin] text in plugin?.emitMessage(toDart: text)
      }
      plugin.bindReceiver(receiver)
      let current = Record(
        engine: engine, ownership: ownership, page: page, control: control,
        factory: factory, receiver: receiver, plugin: plugin, context: context, lease: lease)
      generation += 1
      current.initialRoute = route
      current.arguments = copiedArguments
      current.startedAt = openingStarted
      current.timings = openingTimings
      closeOutcome = nil
      record = current
      diagnose("opened")
      restorationState = restoration
      control.onSaveState = { [weak self, weak current] snapshot in
        guard let self, let current, self.record === current, !current.closing else { return }
        self.restorationState = snapshot
      }
      current.navigation = FlutterHullNavigationStore(
        registry: current.cleanup, context: context,
        onOpen: { [weak self] request in
          guard let handler = self?.onOpenNative else {
            request.fail("NAVIGATION_UNAVAILABLE", message: "宿主未提供原生导航")
            return
          }
          try handler(request)
        })
      control.onFinishContainer = { [weak self, weak current] value, reply in
        guard let self, let current, !current.closing, !current.finishRequested,
          let close = self.onCloseRequested,
          value == nil || (try? FlutterHullJSON.object(value ?? [:])) != nil
        else {
          reply(false)
          return
        }
        current.finishRequested = true
        current.result = try? value.map { try FlutterHullJSON.object($0) }
        reply(true)
        DispatchQueue.main.async { [weak self, weak current] in
          guard let self, let current, self.record === current, !current.closing,
            !current.engineUnavailable
          else { return }
          close()
        }
      }
      control.onOpenNative = { [weak current] input, reply in
        current?.navigation?.open(input, reply: reply)
      }
      control.onCancelNavigation = { [weak current] id in current?.navigation?.cancel(id) ?? false }
      control.onCommunicationReady = { [weak self, weak current] in
        guard let self, let current, self.record === current, !current.closing,
          !current.communicationReady
        else { return }
        current.communicationReady = true
        current.timings["engineReadyMs"] = (self.diagnostics.now() - current.startedAt) * 1000
        self.diagnose("communicationReady")
      }
      control.onFirstFrame = { [weak self, weak current] in
        guard let self, let current, self.record === current, !current.closing,
          !current.firstFrameReady
        else { return }
        current.firstFrameReady = true
        current.timings["firstScreenMs"] = (self.diagnostics.now() - current.startedAt) * 1000
        self.diagnose("firstFrame")
      }
      control.onRestart = { [weak self] in
        guard let self else { return }
        self.diagnose("runTokenChanged")
        #if DEBUG
          if let handler = self.onDevelopmentReopenRequested {
            handler()
            return
          }
        #endif
        self.close { _ in }
      }
      control.onEngineDetached = { [weak self, weak current] in
        guard let self, let current, self.record === current else { return }
        self.engineWillDestroy()
      }
      control.setLifecycle(visible: hostVisible, foreground: hostForeground)
      var configuration: [String: Any] = [
        "containerId": current.id, "route": route, "arguments": copiedArguments,
        "canFinishContainer": onCloseRequested != nil,
      ]
      if let restoration { configuration["restoration"] = restoration }
      control.configure(configuration)
    } catch {
      control.releaseReservation()
      context.invalidate()
      throw error
    }
  }
  public func detach(timeout: TimeInterval = 5, completion: @escaping (Result<Void, Error>) -> Void)
  {
    guard record?.ownership != .owned else {
      completion(.failure(FlutterHullFailure.invalidOwnership))
      return
    }
    close(timeout: timeout, completion: completion)
  }
  /// Runner 销毁前同步调用：不等待 Dart，不向即将失效的 Messenger 发消息。
  public func engineWillDestroy() {
    guard let current = record, current.ownership == .external else { return }
    current.engineUnavailable = true
    current.navigation?.sealTransport()
    current.control.prepareForEngineDestruction()
    current.navigation?.close(transportAvailable: false)
    beginClose(current, timeout: 5, skipDart: true)
  }
  public func close(timeout: TimeInterval = 5, completion: @escaping (Result<Void, Error>) -> Void)
  {
    if let closeOutcome {
      completion(closeOutcome)
      return
    }
    guard let current = record else {
      completion(.success(()))
      return
    }
    closeWaiters.append(completion)
    beginClose(current, timeout: timeout, skipDart: current.engineUnavailable)
  }
  /// 显式开发工具；超时只属于 close，重开仍等待真实 drain，外部 Engine 交还 Runner。
  public func developmentReopen(
    enabled: Bool = false, timeout: TimeInterval = 5,
    completion: @escaping (Result<FlutterHullDevelopmentReopenResult, Error>) -> Void
  ) {
    guard enabled else {
      completion(.failure(FlutterHullFailure.invalidOwnership))
      return
    }
    if reopening {
      reopenWaiters.append(completion)
      return
    }
    guard let current = record else {
      completion(.failure(FlutterHullFailure.closed))
      return
    }
    reopening = true
    reopenWaiters = [completion]
    let state = restorationState
    let route = current.initialRoute
    let arguments = current.arguments
    let ownership = current.ownership
    whenDrained { [weak self] in
      guard let self else { return }
      let result: Result<FlutterHullDevelopmentReopenResult, Error>
      if ownership == .external {
        result = .success(.hostRebuildRequired)
      } else {
        result = Result {
          .owned(try self.open(route: route, arguments: arguments, restorationState: state))
        }
      }
      self.reopening = false
      let callbacks = self.reopenWaiters
      self.reopenWaiters.removeAll()
      self.diagnose(ownership == .external ? "hostRebuildRequired" : "developmentReopened")
      callbacks.forEach { $0(result) }
    }
    close(timeout: timeout) { _ in }
  }

  /// 等待当前一代真实释放；不改写 close 的历史超时结果，也不主动关闭容器。
  public func whenDrained(_ completion: @escaping () -> Void) {
    guard let current = record else {
      completion()
      return
    }
    current.drainWaiters.append(completion)
  }
  private func beginClose(_ current: Record, timeout: TimeInterval, skipDart: Bool) {
    if !current.closing {
      let closeDeadline = DispatchTime.now() + max(0, timeout)
      current.closing = true
      current.closeStartedAt = diagnostics.now()
      diagnose("closing")
      current.navigation?.close(transportAvailable: !current.engineUnavailable)
      current.cleanupTimeout = timeout
      closingRetention = self
      (current.receiver as? any AerisClosingMessageReceiver)?.beginClosing()
      // close 的期限从关闭开始计时；真实 Dart drain 有自己的登记，不能被时间兜底替代。
      DispatchQueue.main.asyncAfter(deadline: closeDeadline) { [weak self, weak current] in
        guard let self, let current, self.record === current, self.closeOutcome == nil else { return }
        self.finishClose(.failure(FlutterHullFailure.cleanupTimeout))
      }
      if !skipDart {
        do {
          let barrier = try current.dartBarrier.registerOperation(name: "dartShutdown", owner: current.id) {
            [weak self, weak current] done in
            guard let self, let current else { return }
            current.control.shutdownResult { [weak self, weak current] result in
              guard let self, let current, self.record === current else { return }
              done(result)
              switch result {
              case .success: self.cleanNative(current)
              case .failure:
                self.diagnose("dartShutdownFailed", current: current, errorCode: "DART_SHUTDOWN_FAILED")
                self.finishClose(result)
              }
            }
          }
          barrier.cancel()
        } catch { finishClose(.failure(error)) }
      }
    }
    if skipDart { cleanNative(current) }
  }
  private func cleanNative(_ current: Record) {
    guard record === current, !current.nativeCleanupStarted else { return }
    current.nativeCleanupStarted = true
    current.plugin.close()
    current.context.invalidate()
    current.cleanup.onDrained = { [weak self, weak current] in
      guard let self, let current else { return }
      self.release(current)
    }
    current.cleanup.close(timeout: current.cleanupTimeout) { [weak self] result in
      if case .failure = result { self?.finishClose(result) }
    }
  }
  private func release(_ current: Record) {
    guard record === current else { return }
    current.control.onSaveState = nil
    current.control.onFinishContainer = nil
    current.control.onOpenNative = nil
    current.control.onCancelNavigation = nil
    current.control.onEngineDetached = nil
    current.control.onRestart = nil
    current.control.onFirstFrame = nil
    current.control.onCommunicationReady = nil
    current.factory.bindUIContext(nil)
    if current.ownership == .owned, let engine = current.engine {
      current.control.prepareForEngineDestruction()
      current.page?.onRemoved = nil
      current.page?.detach()
      hostCallbacks?.unbind(engine: engine)
      current.lease?.destroy()
      destroyedEngineCount += 1
    } else {
      detachedEngineCount += 1
    }
    let drained = current.drainWaiters
    current.drainWaiters.removeAll()
    current.timings["drainMs"] = (diagnostics.now() - current.closeStartedAt) * 1000
    if current.timings["closeMs"] == nil { current.timings["closeMs"] = current.timings["drainMs"] }
    lastTimings = current.timings
    record = nil
    diagnose("drained", current: current)
    closingRetention = nil
    let callback = onResult
    let result = (closeOutcome ?? .success(())).map { current.result }
    finishClose(.success(()))
    callback?(result)
    drained.forEach { $0() }
  }
  private func finishClose(_ result: Result<Void, Error>) {
    guard closeOutcome == nil else { return }
    closeOutcome = result
    if let current = record {
      current.timings["closeMs"] = (diagnostics.now() - current.closeStartedAt) * 1000
    }
    if case .failure(let error) = result {
      var code = (error as? FlutterHullCleanupError)?.code ?? "CLEANUP_FAILED"
      if case .cleanupTimeout? = error as? FlutterHullFailure { code = "CLEANUP_TIMEOUT" }
      diagnose(code == "CLEANUP_TIMEOUT" ? "closeTimeout" : "closeFailed", errorCode: code)
    }
    let callbacks = closeWaiters
    closeWaiters.removeAll()
    callbacks.forEach { $0(result) }
  }
  @MainActor private final class Record {
    let id = UUID().uuidString
    var initialRoute = "/"
    var arguments: [String: Any] = [:]
    var startedAt: TimeInterval = 0
    var closeStartedAt: TimeInterval = 0
    var timings: [String: Any] = [:]
    private let ownedEngine: FlutterEngine?
    private weak var externalEngine: FlutterEngine?
    var engine: FlutterEngine? { ownedEngine ?? externalEngine }
    let ownership: FlutterHullEngineOwnership
    let page: FlutterHullViewController?
    let control: FlutterHullPlugin
    let factory: AerisBridgeReceiverFactory
    let receiver: any AerisMessageReceiver
    let plugin: any AerisFlutterModuleBinding
    let context: BridgeUIContext
    let lease: FlutterHullEngineLease?
    let cleanup = FlutterHullCleanupRegistry()
    let dartBarrier = FlutterHullCleanupRegistry()
    var drainWaiters: [() -> Void] = []
    var navigation: FlutterHullNavigationStore?
    var result: [String: Any]?
    var finishRequested = false
    var closing = false, engineUnavailable = false, nativeCleanupStarted = false
    var communicationReady = false, firstFrameReady = false
    var cleanupTimeout: TimeInterval = 5
    init(
      engine: FlutterEngine, ownership: FlutterHullEngineOwnership,
      page: FlutterHullViewController?,
      control: FlutterHullPlugin,
      factory: AerisBridgeReceiverFactory, receiver: any AerisMessageReceiver,
      plugin: any AerisFlutterModuleBinding, context: BridgeUIContext,
      lease: FlutterHullEngineLease?
    ) {
      ownedEngine = ownership == .owned ? engine : nil
      externalEngine = ownership == .external ? engine : nil
      self.ownership = ownership
      self.page = page
      self.control = control
      self.factory = factory
      self.receiver = receiver
      self.plugin = plugin
      self.context = context
      self.lease = lease
    }
  }
}

/// 原生转场确认完成才清理；普通覆盖和手势取消不代表容器退出。
@MainActor private final class FlutterHullViewController: UIViewController {
  var onRemoved: (() -> Void)?
  var onVisibility: ((Bool) -> Void)?
  private var pendingRemoval = false
  func embed(_ child: UIViewController) {
    loadViewIfNeeded()
    addChild(child)
    child.view.frame = view.bounds
    child.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    view.addSubview(child.view)
    child.didMove(toParent: self)
  }
  func detach() {
    for child in children {
      child.willMove(toParent: nil)
      child.viewIfLoaded?.removeFromSuperview()
      child.removeFromParent()
    }
    willMove(toParent: nil)
    viewIfLoaded?.removeFromSuperview()
    removeFromParent()
  }
  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    onVisibility?(true)
  }
  override func viewWillDisappear(_ animated: Bool) {
    super.viewWillDisappear(animated)
    guard isMovingFromParent || isBeingDismissed || navigationController?.isBeingDismissed == true
    else { return }
    if let coordinator = transitionCoordinator {
      coordinator.animate(alongsideTransition: nil) { [weak self] context in
        if !context.isCancelled { self?.onRemoved?() }
      }
    } else {
      pendingRemoval = true
    }
  }
  override func viewDidDisappear(_ animated: Bool) {
    super.viewDidDisappear(animated)
    onVisibility?(false)
    if pendingRemoval {
      pendingRemoval = false
      onRemoved?()
    }
  }
}
