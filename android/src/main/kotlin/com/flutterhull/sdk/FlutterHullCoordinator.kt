package com.flutterhull.sdk

import android.app.Activity
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.view.ViewGroup
import android.widget.FrameLayout
import androidx.activity.ComponentActivity
import com.aeris.sdk.*
import com.aeris.sdk.flutter.AerisUnifiedBridgePlugin
import io.flutter.embedding.android.ExclusiveAppComponent
import io.flutter.embedding.android.FlutterView
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.platform.PlatformPlugin
import java.lang.ref.WeakReference
import java.util.UUID

enum class FlutterHullEngineOwnership {
    OWNED,
    EXTERNAL,
}

sealed class FlutterHullDevelopmentReopenResult {
    class Reopened(val view: FrameLayout) : FlutterHullDevelopmentReopenResult()

    data object HostRebuildRequired : FlutterHullDevelopmentReopenResult()
}

/** 只记录框架元数据；默认无观察者，异常不能影响业务流程。 */
class FlutterHullDiagnostics(
    private val clock: () -> Long = { System.nanoTime() },
    private val observer: ((Map<String, Any?>) -> Unit)? = null,
) {
    private var lastRaw: Long? = null
    private var lastSystem: Long? = null
    private var logicalTime = 0L

    internal fun now(): Long {
        val system = System.nanoTime()
        val raw = runCatching { clock() }.getOrNull()
        val previousSystem = lastSystem
        val previousRaw = lastRaw
        logicalTime =
            if (previousSystem == null) raw ?: system
            else {
                // 失败边界只累计同一时钟域的相邻差值，恢复时不混用绝对时间。
                val delta =
                    if (raw != null && previousRaw != null) raw - previousRaw
                    else system - previousSystem
                runCatching { Math.addExact(logicalTime, delta.coerceAtLeast(0)) }
                    .getOrDefault(Long.MAX_VALUE)
            }
        lastRaw = raw
        lastSystem = system
        return logicalTime
    }

    internal fun emit(event: Map<String, Any?>) {
        runCatching { observer?.invoke(event) }
    }
}

/** open 管理自有 Engine；attach 不接管 Runner 的执行、视图或 Activity 绑定。 */
class FlutterHullCoordinator(
    private val bridgeEngine: BridgeEngine,
    allowedPermissions: Set<String> = emptySet(),
    allowedEventTopics: Set<String>? = null,
    private val engineManager: FlutterHullEngineManager = FlutterHullEngineManager(),
    private val configureEngine: (FlutterEngine) -> Unit = {},
) {
    /** 保留已有四个位置参数的构造方式。 */
    constructor(
        bridgeEngine: BridgeEngine,
        allowedPermissions: Set<String>,
        allowedEventTopics: Set<String>?,
        configureEngine: (FlutterEngine) -> Unit,
    ) : this(
        bridgeEngine,
        allowedPermissions,
        allowedEventTopics,
        FlutterHullEngineManager(),
        configureEngine,
    )

    private companion object {
        val closingOwners = mutableSetOf<FlutterHullCoordinator>()
    }

    var diagnostics = FlutterHullDiagnostics()
    var onDevelopmentReopenRequested: (() -> Unit)? = null
    private var debuggable = false
    private val routing = FlutterHullRoutingQueue()
    var availableCapabilities: Set<String> = emptySet()
    var baselineId: String? = null
    private var generation = 0
    private var openingStarted = 0L
    private var openingTimings = emptyMap<String, Any?>()
    private var lastTimings = emptyMap<String, Any?>()
    private var reopening = false
    private val reopenWaiters =
        mutableListOf<(Result<FlutterHullDevelopmentReopenResult>) -> Unit>()
    val diagnosticSnapshot: Map<String, Any?>
        get() =
            (record?.timings ?: lastTimings) +
                mapOf(
                    "containerId" to (record?.id ?: ""),
                    "generation" to generation,
                    "engineCount" to if (record == null) 0 else 1,
                    "managerEngineCount" to engineManager.activeEngineCount,
                    "cleanupPending" to ((record?.cleanup?.pendingCount ?: 0) + (record?.dartBarrier?.pendingCount ?: 0) + (record?.bridgeBarrier?.pendingCount ?: 0)),
                    "navigation" to (record?.navigation?.activeCount ?: 0),
                    "routing" to routing.count,
                    "communicationReady" to communicationReady,
                    "firstFrameReady" to firstFrameReady,
                    "closing" to (record?.closing ?: false),
                )

    private fun diagnose(phase: String, current: Record? = record, errorCode: String? = null) {
        diagnostics.emit(
            mapOf(
                "phase" to phase,
                "thread" to Thread.currentThread().name,
                "mainThread" to (Looper.myLooper() == Looper.getMainLooper()),
                "enginePolicy" to engineManager.policy.name.lowercase(),
                "sinceOpenMs" to ((diagnostics.now() - openingStarted).coerceAtLeast(0) / 1_000_000.0),
                "timestampMicros" to diagnostics.now() / 1000,
                "containerId" to (current?.id ?: ""),
                "generation" to generation,
                "errorCode" to errorCode,
                "counts" to diagnosticSnapshot,
            )
        )
    }

    private val permissions = allowedPermissions.toSet()
    private val topics = allowedEventTopics?.toSet()
    private var record: Record? = null
    val hostCallbacks =
        FlutterHullHostCallbacks(
            engine = {
                record
                    ?.takeIf { !it.closing && it.ownership == FlutterHullEngineOwnership.OWNED }
                    ?.engine
            },
            firstFrameReady = { firstFrameReady },
            platform = { record?.takeUnless { it.closing }?.platformPlugin },
        )
    var environment: FlutterHullHostEnvironment? = null
        private set
    private var hostVisible = true
    private var hostForeground = true
    var onCloseRequested: (() -> Unit)? = null
    var onResult: ((Result<Map<String, Any?>?>) -> Unit)? = null
    var onOpenNative: ((FlutterHullNavigationRequest) -> Unit)? = null
    private val waiters = mutableListOf<(Result<Unit>) -> Unit>()
    private var outcome: Result<Unit>? = null
    var destroyedEngineCount = 0
        private set

    var detachedEngineCount = 0
        private set

    val isOpen
        get() = record != null

    val communicationReady
        get() = record?.communicationReady == true

    val firstFrameReady
        get() = record?.firstFrameReady == true

    val cleanupResources get() = (record?.cleanup?.resources ?: emptyList()) +
        (record?.dartBarrier?.resources ?: emptyList()) + (record?.bridgeBarrier?.resources ?: emptyList())
    fun retryCleanup(resourceId: String): Boolean {
        checkMain()
        return (record?.cleanup?.retry(resourceId) ?: false) ||
            (record?.dartBarrier?.retry(resourceId) ?: false)
    }
    fun queryDartCleanup(completion: (Result<List<Map<String, Any?>>>) -> Unit) {
        checkMain()
        val current = record?.takeUnless { it.engineUnavailable }
        if (current == null) completion(Result.failure(FlutterHullCleanupError("DART_UNAVAILABLE")))
        else current.control.queryCleanup(completion)
    }
    fun queryDartCleanupPage(offset: Int = 0, limit: Int = 64,
        completion: (Result<Map<String, Any?>>) -> Unit) {
        checkMain()
        val current = record?.takeUnless { it.engineUnavailable }
        if (current == null) completion(Result.failure(FlutterHullCleanupError("DART_UNAVAILABLE")))
        else current.control.queryCleanupPage(offset, limit, completion)
    }
    fun retryDartCleanup(resourceId: String, completion: (Result<Boolean>) -> Unit) {
        checkMain()
        val current = record?.takeUnless { it.engineUnavailable }
        if (current == null) completion(Result.failure(FlutterHullCleanupError("DART_UNAVAILABLE")))
        else current.control.retryCleanup(resourceId, completion)
    }

    val cleanup
        get() = record?.cleanup

    val activeEngine
        get() = record?.takeUnless { it.engineUnavailable }?.engine

    val activeContext
        get() = record?.context

    val engineOwnership
        get() = record?.ownership

    fun open(
        activity: ComponentActivity,
        parent: ViewGroup,
        route: String = "/",
        arguments: Map<String, Any?> = emptyMap(),
        savedState: Bundle? = null,
    ): FrameLayout {
        validate(route)
        FlutterHullJSON.objectCopy(arguments)
        openingStarted = diagnostics.now()
        debuggable =
            activity.applicationInfo.flags and android.content.pm.ApplicationInfo.FLAG_DEBUGGABLE !=
                0
        diagnose("engineCreating")
        val lease = engineManager.acquire(activity)
        val createdAt = diagnostics.now()
        diagnose("engineCreated")
        val engine = lease.engine
        val root = FrameLayout(activity)
        val view = FlutterView(activity)
        try {
            val pluginStart = diagnostics.now()
            lease.configurePlugins(configureEngine)
            openingTimings = mapOf(
                "engineCreateMs" to (createdAt - openingStarted) / 1_000_000.0,
                "pluginConfigureMs" to (diagnostics.now() - pluginStart) / 1_000_000.0,
                // 官方 EngineGroup 在创建中已执行 Dart；不能把组合耗时伪称为独立启动耗时。
                "dartStartIncludedInEngineCreate" to engine.dartExecutor.isExecutingDart,
            )
            diagnose("pluginsConfigured")
            val viewStart = diagnostics.now()
            parent.addView(root, ViewGroup.LayoutParams(-1, -1))
            root.addView(view, FrameLayout.LayoutParams(-1, -1))
            val current =
                bind(
                    engine,
                    AndroidBridgeUIContext(root),
                    FlutterHullEngineOwnership.OWNED,
                    route,
                    arguments,
                    activity,
                    root,
                    view,
                    lease,
                    FlutterHullRestoration.decode(
                        runCatching { savedState?.getString(FlutterHullRestoration.BUNDLE_KEY) }
                            .getOrNull()
                    ),
                )
            engine.activityControlSurface.attachToActivity(current, activity.lifecycle)
            current.platformPlugin = PlatformPlugin(activity, engine.platformChannel,
                object : PlatformPlugin.PlatformPluginDelegate {
                    override fun popSystemNavigator(): Boolean {
                        // 总是消费平台默认 finish；真实返回、路由 veto 与 drain 由当前容器处理。
                        if (record === current && !current.closing && !current.platformBackPending) {
                            current.platformBackPending = true
                            Handler(Looper.getMainLooper()).post {
                                if (record === current && !current.closing) requestBack { handled ->
                                    current.platformBackPending = false
                                    if (!handled && record === current && !current.closing) {
                                        val handler = onCloseRequested
                                        if (handler != null) handler() else close {}
                                    }
                                }
                            }
                        }
                        return true
                    }
                })
            hostCallbacks.onRestoreInstanceState(savedState)
            view.attachToFlutterEngine(engine)
            current.timings["viewBindMs"] = (diagnostics.now() - viewStart) / 1_000_000.0
            diagnose("viewBound")
            val dartStart = diagnostics.now()
            val alreadyExecuting = engine.dartExecutor.isExecutingDart
            // EngineGroup 已执行 Dart；再次 execute 会破坏每个租约的独立入口。
            if (!engine.dartExecutor.isExecutingDart)
                engine.dartExecutor.executeDartEntrypoint(
                    DartExecutor.DartEntrypoint.createDefault()
                )
            current.timings["dartStartMs"] =
                if (alreadyExecuting) 0.0 else (diagnostics.now() - dartStart) / 1_000_000.0
            diagnose("dartStarted")
            engine.lifecycleChannel.appIsResumed()
            return root
        } catch (error: Exception) {
            record?.platformPlugin?.destroy()
            record?.receiver?.close()
            record?.context?.invalidate()
            record = null
            view.detachFromFlutterEngine()
            (root.parent as? ViewGroup)?.removeView(root)
            runCatching { lease.destroy() }.exceptionOrNull()?.let(error::addSuppressed)
            throw error
        }
    }

    /** 局部区域沿用同一 FlutterView 与 Activity 所有权，原生兄弟视图保持原样。 */
    fun openEmbedded(activity: ComponentActivity, parent: ViewGroup,
        layout: ViewGroup.LayoutParams, route: String = "/",
        arguments: Map<String, Any?> = emptyMap(), savedState: Bundle? = null): FrameLayout {
        require(layout.width >= 0 && layout.height >= 0) { "INVALID_EMBEDDED_SIZE" }
        val root = open(activity, parent, route, arguments, savedState)
        record?.embedded = true
        root.layoutParams = layout
        root.requestLayout()
        return root
    }
    fun updateEmbeddedLayout(layout: ViewGroup.LayoutParams): Boolean {
        checkMain()
        val current = record?.takeIf { it.embedded && !it.closing } ?: return false
        require(layout.width >= 0 && layout.height >= 0) { "INVALID_EMBEDDED_SIZE" }
        current.root?.layoutParams = layout
        current.root?.requestLayout()
        return true
    }
    fun setEmbeddedVisible(visible: Boolean) {
        checkMain()
        val current = record?.takeIf { it.embedded && !it.closing } ?: return
        current.root?.visibility = if (visible) android.view.View.VISIBLE else android.view.View.GONE
        setVisible(visible)
    }
    fun setEmbeddedBackOwnership(ownsBack: Boolean) {
        checkMain()
        record?.takeIf { it.embedded && !it.closing }?.ownsBack = ownsBack
    }
    /** 失败保留 owner 与视图；资源恢复后实际 drain 才会 detach/remove。 */
    fun unmountEmbedded(timeoutMillis: Long = 5000, completion: (Result<Unit>) -> Unit = {}) {
        checkMain()
        if (record != null && record?.embedded != true) {
            completion(Result.failure(IllegalStateException("INVALID_OWNERSHIP")))
            return
        }
        close(timeoutMillis, completion)
    }

    /** 生命周期中只复制最后已确认快照，不等待 Dart 往返。插件状态单独由 hostCallbacks 转发。 */
    fun saveState(outState: Bundle) {
        checkMain()
        val snapshot = record?.control?.restorationSnapshot ?: return
        outState.putString(
            FlutterHullRestoration.BUNDLE_KEY,
            FlutterHullRestoration.encode(snapshot),
        )
    }

    fun attach(
        engine: FlutterEngine,
        container: ViewGroup,
        route: String = "/",
        arguments: Map<String, Any?> = emptyMap(),
    ) {
        validate(route)
        check(!FlutterHullManagedEngineRegistry.contains(engine)) { "ENGINE_IN_USE" }
        FlutterHullJSON.objectCopy(arguments)
        openingStarted = diagnostics.now()
        openingTimings = emptyMap()
        debuggable =
            container.context.applicationInfo.flags and
                android.content.pm.ApplicationInfo.FLAG_DEBUGGABLE != 0
        val context = AndroidBridgeUIContext(container)
        try {
            bind(engine, context, FlutterHullEngineOwnership.EXTERNAL, route, arguments)
        } catch (error: Exception) {
            context.invalidate()
            throw error
        }
    }

    private fun validate(route: String) {
        checkMain()
        check(record == null) { "ENGINE_IN_USE" }
        require(route.isNotEmpty() && route.toByteArray(Charsets.UTF_8).size <= 512)
    }

    private fun bind(
        engine: FlutterEngine,
        context: AndroidBridgeUIContext,
        ownership: FlutterHullEngineOwnership,
        route: String,
        arguments: Map<String, Any?>,
        activity: Activity? = null,
        root: FrameLayout? = null,
        view: FlutterView? = null,
        lease: FlutterHullEngineManager.Lease? = null,
        restoration: Map<String, Any?>? = null,
    ): Record {
        val control =
            engine.plugins.get(FlutterHullPlugin::class.java) as? FlutterHullPlugin
                ?: error("PLUGIN_NOT_REGISTERED: FlutterHullPlugin")
        val plugin =
            engine.plugins.get(AerisUnifiedBridgePlugin::class.java) as? AerisUnifiedBridgePlugin
                ?: error("PLUGIN_NOT_REGISTERED: AerisUnifiedBridgePlugin")
        control.reserve()
        try {
            var receiver: AerisMessageReceiver? = null
            plugin.bind(
                AerisReceiverFactory { emit ->
                    AerisFlutterNativeTransport(bridgeEngine, context, permissions, topics, emit)
                        .also { receiver = it }
                }
            )
            val current =
                Record(
                    engine,
                    ownership,
                    context,
                    control,
                    plugin,
                    requireNotNull(receiver),
                    activity,
                    root,
                    view,
                    lease,
                )
            generation++
            current.initialRoute = route
            current.arguments = FlutterHullJSON.objectCopy(arguments)
            current.startedAt = openingStarted
            current.timings.putAll(openingTimings)
            outcome = null
            record = current
            diagnose("opened")
            current.navigation =
                FlutterHullNavigationStore(current.cleanup, context) { request ->
                    val handler = onOpenNative
                    if (handler == null) request.fail("NAVIGATION_UNAVAILABLE", "宿主未提供原生导航")
                    else handler(request)
                }
            control.onFinishContainer = { value, reply ->
                val close = onCloseRequested
                if (
                    current.closing ||
                        current.finishRequested ||
                        close == null ||
                        (value != null &&
                            runCatching { FlutterHullJSON.objectCopy(value) }.isFailure)
                )
                    reply.success(false)
                else {
                    current.finishRequested = true
                    current.result = value?.let { FlutterHullJSON.objectCopy(it) }
                    reply.success(true)
                    android.os.Handler(Looper.getMainLooper()).post {
                        if (record === current && !current.closing && !current.engineUnavailable)
                            close()
                    }
                }
            }
            control.onOpenNative = { input, reply -> current.navigation?.open(input, reply) }
            control.onCancelNavigation = { id -> current.navigation?.cancel(id) ?: false }
            control.onCommunicationReady = {
                if (record === current && !current.closing && !current.communicationReady) {
                    current.communicationReady = true
                    current.timings["engineReadyMs"] =
                        (diagnostics.now() - current.startedAt) / 1_000_000.0
                    diagnose("communicationReady")
                    activateRouting(current)
                }
            }
            control.onFirstFrame = {
                if (record === current && !current.closing && !current.firstFrameReady) {
                    current.firstFrameReady = true
                    current.timings["firstScreenMs"] =
                        (diagnostics.now() - current.startedAt) / 1_000_000.0
                    diagnose("firstFrame")
                }
            }
            control.onRestart = {
                diagnose("runTokenChanged")
                val handler = onDevelopmentReopenRequested
                if (debuggable && handler != null) handler() else close {}
            }
            control.onEngineDetached = { if (record === current) engineWillDestroy() }
            environment?.let { control.setEnvironment(it) }
            control.setLifecycle(hostVisible, hostForeground)
            control.configure(
                mapOf(
                    "containerId" to current.id,
                    "route" to route,
                    "arguments" to current.arguments,
                    "canFinishContainer" to (onCloseRequested != null),
                    "availableCapabilities" to availableCapabilities.sorted(),
                    "baselineId" to baselineId,
                    "restoration" to restoration,
                )
            )
            return current
        } catch (error: Exception) {
            control.releaseReservation()
            context.invalidate()
            throw error
        }
    }

    /** 乱序修订丢弃；用户域切换在控制插件内同步清空恢复缓存。 */
    fun setEnvironment(next: FlutterHullHostEnvironment): Boolean {
        checkMain()
        if (next.revision <= (environment?.revision ?: -1)) return false
        if (environment != null && environment?.userDomain != next.userDomain)
            routing.deactivate("USER_DOMAIN_CHANGED")
        environment = next
        record?.control?.setEnvironment(next)
        record?.takeIf { it.communicationReady && !it.closing }?.let(::activateRouting)
        return true
    }

    /** 冷启动 URL 在通信就绪前有界排队，重复 URL 共用同一可取消操作。 */
    fun openURL(url: String, timeoutMillis: Long = 30000,
        completion: (Result<Map<String, Any?>?>) -> Unit): FlutterHullRoutingOperation {
        checkMain()
        check(record?.closing != true) { "CLOSED" }
        require(url.isNotEmpty() && url.toByteArray(Charsets.UTF_8).size <= 4096) { "INVALID_URL" }
        return routing.open("openURL", mapOf("url" to url), url, timeoutMillis, completion)
    }
    fun openTarget(kind: String, route: String, arguments: Map<String, Any?> = emptyMap(),
        timeoutMillis: Long = 30000, completion: (Result<Map<String, Any?>?>) -> Unit): FlutterHullRoutingOperation {
        checkMain()
        check(record?.closing != true) { "CLOSED" }
        require(kind in setOf("flutter", "native", "rn", "web") && route.isNotEmpty() &&
            route.toByteArray(Charsets.UTF_8).size <= 512) { "INVALID_TARGET" }
        return routing.open("openTarget", mapOf("kind" to kind, "route" to route,
            "arguments" to FlutterHullJSON.objectCopy(arguments)), timeoutMillis = timeoutMillis, completion = completion)
    }
    private fun activateRouting(current: Record) {
        routing.activate(send = { method, arguments, completion ->
            if (record !== current || current.closing) completion(Result.failure(FlutterHullCleanupError("CLOSED")))
            else current.control.sendRouting(method, arguments, completion)
        }, cancel = { current.control.cancelRouting(it) })
    }

    fun setVisible(visible: Boolean) {
        checkMain()
        hostVisible = visible
        record?.control?.setLifecycle(visible = visible)
    }

    fun setForeground(foreground: Boolean) {
        checkMain()
        hostForeground = foreground
        record?.control?.setLifecycle(foreground = foreground)
    }

    fun requestBack(completion: (Boolean) -> Unit) {
        checkMain()
        val current = record
        if (current?.embedded == true && (!current.ownsBack || !hostVisible)) completion(false)
        else current?.control?.requestBack(completion) ?: completion(true)
    }

    fun resume() {
        checkMain()
        setForeground(true)
        hostCallbacks.onPostResume()
        record
            ?.takeIf { !it.closing && it.ownership == FlutterHullEngineOwnership.OWNED }
            ?.engine
            ?.lifecycleChannel
            ?.appIsResumed()
    }

    fun pause() {
        checkMain()
        setForeground(false)
        record
            ?.takeIf { !it.closing && it.ownership == FlutterHullEngineOwnership.OWNED }
            ?.engine
            ?.lifecycleChannel
            ?.apply {
                appIsInactive()
                appIsPaused()
            }
    }

    fun detach(timeoutMillis: Long = 5000, completion: (Result<Unit>) -> Unit = {}) {
        checkMain()
        if (record?.ownership == FlutterHullEngineOwnership.OWNED) {
            completion(Result.failure(IllegalStateException("INVALID_OWNERSHIP")))
            return
        }
        close(timeoutMillis, completion)
    }

    /** Runner 在最终销毁前同步调用；不等待已经不可用的 Dart 通道。 */
    fun engineWillDestroy() {
        checkMain()
        val current =
            record?.takeIf { it.ownership == FlutterHullEngineOwnership.EXTERNAL } ?: return
        current.engineUnavailable = true
        current.navigation?.sealTransport()
        current.control.prepareForEngineDestruction()
        current.navigation?.close(false)
        beginClose(current, 5000, true)
    }

    fun close(timeoutMillis: Long = 5000, completion: (Result<Unit>) -> Unit = {}) {
        checkMain()
        outcome?.let {
            completion(it)
            return
        }
        val current =
            record
                ?: run {
                    completion(Result.success(Unit))
                    return
                }
        waiters.add(completion)
        beginClose(current, timeoutMillis, current.engineUnavailable)
    }

    /** 等待当前一代真实释放；不改写 close 的历史超时结果，也不主动关闭容器。 */
    fun whenDrained(completion: () -> Unit) {
        checkMain()
        val current = record
        if (current == null) completion() else current.drainWaiters.add(completion)
    }

    private fun beginClose(current: Record, timeoutMillis: Long, skipDart: Boolean) {
        if (!current.closing) {
            val now = SystemClock.uptimeMillis()
            val duration = timeoutMillis.coerceAtLeast(0)
            val closeDeadline = if (duration > Long.MAX_VALUE - now) Long.MAX_VALUE else now + duration
            routing.deactivate("CLOSED")
            current.closing = true
            // 开始关闭就解绑平台服务；真实清理挂起时也不得继续触达旧 Activity。
            current.platformPlugin?.destroy()
            current.platformPlugin = null
            current.closeStartedAt = diagnostics.now()
            diagnose("closing")
            current.navigation?.close(!current.engineUnavailable)
            current.cleanupTimeout = timeoutMillis
            closingOwners.add(this)
            current.receiver.beginClosing()
            // 有限等待从这里计时，不能等 Dart 响应之后才开始。
            Handler(Looper.getMainLooper()).postAtTime({
                if (record === current && outcome == null)
                    finish(Result.failure(FlutterHullCleanupError("CLEANUP_TIMEOUT")))
            }, closeDeadline)
            if (!skipDart) {
                current.dartBarrier.registerOperation("dartShutdown", current.id) { done ->
                    current.control.shutdownResult { result ->
                        if (record === current) {
                            done(result)
                            if (result.isSuccess) cleanNative(current)
                            else {
                                diagnose("dartShutdownFailed", current, "DART_SHUTDOWN_FAILED")
                                finish(result)
                            }
                        }
                    }
                }.cancel()
            }
        }
        if (skipDart) cleanNative(current)
    }

    private fun cleanNative(current: Record) {
        if (record !== current || current.nativeCleanupStarted) return
        current.nativeCleanupStarted = true
        // 先确认平台通道已解绑，再以实际连接关闭通知等待订阅与 Session 清理。
        // 已关闭连接可同步通知；此时通道释放也已完成，不依赖主队列 post 次数。
        current.context.invalidate()
        fun releaseWhenDrained() {
            if (current.businessCleanupDrained && current.bridgeCleanupDrained) release(current)
        }
        current.cleanup.onDrained = {
            current.businessCleanupDrained = true
            releaseWhenDrained()
        }
        current.bridgeBarrier.onDrained = {
            current.bridgeCleanupDrained = true
            releaseWhenDrained()
        }
        // 独立保留一个框架槽位；桥和业务清理并行，不消耗业务512项配额。
        current.bridgeBarrier.register("channelShutdown", current.id) { done ->
            current.plugin.close { released ->
                if (released.isSuccess) {
                    current.receiver.close()
                    current.receiver.observeClosed { done() }
                } else diagnose("channelReleaseFailed", current, "CHANNEL_RELEASE_FAILED")
            }
        }
        current.bridgeBarrier.close(current.cleanupTimeout) { result ->
            if (result.isFailure) finish(result)
        }
        current.cleanup.close(current.cleanupTimeout) { result ->
            if (result.isFailure) finish(result)
        }
    }

    private fun release(current: Record) {
        if (record !== current) return
        current.control.onFinishContainer = null
        current.control.onOpenNative = null
        current.control.onCancelNavigation = null
        current.control.onEngineDetached = null
        current.control.onRestart = null
        current.control.onFirstFrame = null
        current.control.onCommunicationReady = null
        if (current.ownership == FlutterHullEngineOwnership.OWNED) {
            current.view?.detachFromFlutterEngine()
            current.engine?.activityControlSurface?.detachFromActivity()
            current.root?.removeAllViews()
            (current.root?.parent as? ViewGroup)?.removeView(current.root)
            requireNotNull(current.lease).destroy()
            destroyedEngineCount++
        } else {
            detachedEngineCount++
        }
        val drained = current.drainWaiters.toList()
        current.drainWaiters.clear()
        current.timings["drainMs"] = (diagnostics.now() - current.closeStartedAt) / 1_000_000.0
        if ("closeMs" !in current.timings) current.timings["closeMs"] = current.timings["drainMs"]
        lastTimings = current.timings.toMap()
        record = null
        diagnose("drained", current)
        closingOwners.remove(this)
        val callback = onResult
        val result: Result<Map<String, Any?>?> =
            (outcome ?: Result.success(Unit)).map { current.result }
        finish(Result.success(Unit))
        runCatching { callback?.invoke(result) }
        drained.forEach { runCatching { it() } }
    }

    private fun finish(result: Result<Unit>) {
        if (outcome != null) return
        outcome = result
        record?.let {
            it.timings["closeMs"] = (diagnostics.now() - it.closeStartedAt) / 1_000_000.0
        }
        if (result.isFailure) {
            val code = (result.exceptionOrNull() as? FlutterHullCleanupError)?.code ?: "CLEANUP_FAILED"
            diagnose(if (code == "CLEANUP_TIMEOUT") "closeTimeout" else "closeFailed", errorCode = code)
        }
        val callbacks = waiters.toList()
        waiters.clear()
        callbacks.forEach { runCatching { it(result) } }
    }

    /** 仅显式调用；关闭超时仍等真实 drain，外部 Engine 由 Runner 创建新一代。 */
    fun developmentReopen(
        activity: ComponentActivity? = null,
        parent: ViewGroup? = null,
        enabled: Boolean = false,
        timeoutMillis: Long = 5000,
        completion: (Result<FlutterHullDevelopmentReopenResult>) -> Unit,
    ) {
        checkMain()
        if (!enabled) {
            completion(Result.failure(IllegalStateException("DEVELOPMENT_DISABLED")))
            return
        }
        if (reopening) {
            reopenWaiters.add(completion)
            return
        }
        val current =
            record
                ?: run {
                    completion(Result.failure(IllegalStateException("CLOSED")))
                    return
                }
        if (
            current.ownership == FlutterHullEngineOwnership.OWNED &&
                (activity == null || parent == null)
        ) {
            completion(Result.failure(IllegalArgumentException("HOST_REQUIRED")))
            return
        }
        val state = Bundle().also { saveState(it) }
        val route = current.initialRoute
        val arguments = current.arguments
        val ownership = current.ownership
        reopening = true
        reopenWaiters.add(completion)
        whenDrained {
            val result = runCatching {
                if (ownership == FlutterHullEngineOwnership.EXTERNAL)
                    FlutterHullDevelopmentReopenResult.HostRebuildRequired
                else
                    FlutterHullDevelopmentReopenResult.Reopened(
                        open(
                            requireNotNull(activity),
                            requireNotNull(parent),
                            route,
                            arguments,
                            state,
                        )
                    )
            }
            reopening = false
            val callbacks = reopenWaiters.toList()
            reopenWaiters.clear()
            diagnose(
                if (ownership == FlutterHullEngineOwnership.EXTERNAL) "hostRebuildRequired"
                else "developmentReopened"
            )
            callbacks.forEach { runCatching { it(result) } }
        }
        close(timeoutMillis) {}
    }

    private fun checkMain() {
        check(Looper.myLooper() == Looper.getMainLooper()) { "请在主线程操作容器" }
    }

    private inner class Record(
        engine: FlutterEngine,
        val ownership: FlutterHullEngineOwnership,
        val context: AndroidBridgeUIContext,
        val control: FlutterHullPlugin,
        val plugin: AerisUnifiedBridgePlugin,
        val receiver: AerisMessageReceiver,
        val activity: Activity?,
        val root: FrameLayout?,
        val view: FlutterView?,
        val lease: FlutterHullEngineManager.Lease?,
    ) : ExclusiveAppComponent<Activity> {
        private val ownedEngine =
            if (ownership == FlutterHullEngineOwnership.OWNED) engine else null
        private val borrowedEngine =
            WeakReference(if (ownership == FlutterHullEngineOwnership.EXTERNAL) engine else null)
        val engine
            get() = ownedEngine ?: borrowedEngine.get()

        val id = UUID.randomUUID().toString()
        var embedded = false
        var ownsBack = true
        var initialRoute = "/"
        var arguments = emptyMap<String, Any?>()
        var startedAt = 0L
        var closeStartedAt = 0L
        val timings = mutableMapOf<String, Any?>()
        val cleanup = FlutterHullCleanupRegistry()
        val dartBarrier = FlutterHullCleanupRegistry()
        val bridgeBarrier = FlutterHullCleanupRegistry(maxResources = 1)
        var businessCleanupDrained = false
        var bridgeCleanupDrained = false
        val drainWaiters = mutableListOf<() -> Unit>()
        var navigation: FlutterHullNavigationStore? = null
        var result: Map<String, Any?>? = null
        var finishRequested = false
        var platformPlugin: PlatformPlugin? = null
        var platformBackPending = false
        var closing = false
        var engineUnavailable = false
        var nativeCleanupStarted = false
        var communicationReady = false
        var firstFrameReady = false
        var cleanupTimeout = 5000L

        override fun getAppComponent(): Activity = requireNotNull(activity)

        override fun detachFromFlutterEngine() {
            close {}
        }
    }
}
