import Flutter
import Foundation

public enum FlutterHullEnginePolicy { case single, group }

/// 由同一运行域显式共享；槽位只在所属 Engine 实际销毁后归还。
@MainActor public final class FlutterHullEngineManager {
  public let policy: FlutterHullEnginePolicy
  public let maxEngines: Int
  private var leases: Set<UUID> = []
  private struct GroupGeneration {
    let id = UUID()
    let group = FlutterEngineGroup(name: "flutter_hull_group_" + UUID().uuidString, project: nil)
  }
  private var currentGroup: GroupGeneration?
  public var activeEngineCount: Int { leases.count }

  public init(policy: FlutterHullEnginePolicy = .single, maxEngines: Int = 4) {
    self.policy = policy
    self.maxEngines = max(0, maxEngines)
  }

  func acquire(clock: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) throws -> FlutterHullEngineLease {
    let capacity = policy == .single ? min(1, maxEngines) : maxEngines
    guard leases.count < capacity else { throw FlutterHullFailure.engineInUse }
    let id = UUID()
    leases.insert(id)
    let startedAt = clock()
    var creationMs: Double = 0
    var dartStartMs: Double = 0
    let engine: FlutterEngine
    let generation: UUID?
    switch policy {
    case .single:
      generation = nil
      engine = FlutterEngine(
        name: "flutter_hull_" + id.uuidString, project: nil, allowHeadlessExecution: true)
      creationMs = max(0, clock() - startedAt) * 1000
      let dartStartedAt = clock()
      guard engine.run() else {
        engine.destroyContext()
        leases.remove(id)
        throw FlutterHullFailure.engineStartFailed
      }
      dartStartMs = max(0, clock() - dartStartedAt) * 1000
    case .group:
      let current = currentGroup ?? GroupGeneration()
      currentGroup = current
      generation = current.id
      // 官方 Group 返回的是已经运行的独立 Engine，不能再次调用 run。
      engine = current.group.makeEngine(withEntrypoint: nil, libraryURI: nil)
      // Group 的创建与 Dart 启动是官方组合 API，只报告组合耗时，不编造拆分数据。
      creationMs = max(0, clock() - startedAt) * 1000
    // isolateId 由 flutter/isolate 消息异步发布，就绪状态由控制通道握手确认。
    }
    return FlutterHullEngineLease(
      engine: engine,
      startupTimings: ["engineCreateMs": creationMs, "dartStartMs": dartStartMs,
        "dartStartIncludedInEngineCreate": policy == .group],
      beforeDestroy: { [self] in
        // FlutterEngineGroup 的弱表只判断对象存活；宿主可能仍强持有已 destroy 的 Engine。
        // 先退休对应 Group，避免销毁中的重入或未来创建选中失效的 spawner。
        // 更早 generation 的租约关闭，不得退休后来创建的 Group。
        if let generation, currentGroup?.id == generation { currentGroup = nil }
      },
      release: { [self] in leases.remove(id) })
  }
}

/// 容器负责调用 destroy；释放动作幂等，避免失败回滚和关闭重入重复减计数。
@MainActor final class FlutterHullEngineLease {
  let engine: FlutterEngine
  let startupTimings: [String: Any]
  private let beforeDestroy: () -> Void
  private var release: (() -> Void)?
  init(engine: FlutterEngine, startupTimings: [String: Any], beforeDestroy: @escaping () -> Void, release: @escaping () -> Void) {
    self.engine = engine
    self.startupTimings = startupTimings
    self.beforeDestroy = beforeDestroy
    self.release = release
  }
  func destroy() {
    guard let release else { return }
    self.release = nil
    beforeDestroy()
    engine.viewController = nil
    engine.destroyContext()
    release()
  }
}
