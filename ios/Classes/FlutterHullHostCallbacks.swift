import Flutter
import UIKit

/// 每个 Scene 持有一个适配器；官方 Delegate 自己完成插件分发和去重。
/// FlutterSceneDelegate 宿主直接传 self；非继承宿主传长期持有的
/// FlutterPluginSceneLifeCycleDelegate，并按官方 FlutterSceneLifeCycleProvider 转发 Scene 回调。
/// App 回调由 FlutterAppDelegate 或 FlutterAppLifeCycleProvider 的官方 helper 承接。
@MainActor public final class FlutterHullHostCallbacks {
  private weak var sceneDelegate: (any FlutterSceneLifeCycleEngineRegistration)?
  private var engines: [ObjectIdentifier: WeakEngine] = [:]
  public var boundEngineCount: Int { engines.values.filter { $0.value != nil }.count }

  public init(sceneDelegate: any FlutterSceneLifeCycleEngineRegistration) {
    self.sceneDelegate = sceneDelegate
  }

  @discardableResult public func bind(engine: FlutterEngine) -> Bool {
    let id = ObjectIdentifier(engine)
    guard engines[id]?.value == nil else { return false }
    guard sceneDelegate?.registerSceneLifeCycle(with: engine) == true else { return false }
    engines[id] = WeakEngine(engine)
    return true
  }

  @discardableResult public func unbind(engine: FlutterEngine) -> Bool {
    guard engines.removeValue(forKey: ObjectIdentifier(engine)) != nil else { return false }
    return sceneDelegate?.unregisterSceneLifeCycle(with: engine) ?? false
  }

  private final class WeakEngine {
    weak var value: FlutterEngine?
    init(_ value: FlutterEngine) { self.value = value }
  }
}
