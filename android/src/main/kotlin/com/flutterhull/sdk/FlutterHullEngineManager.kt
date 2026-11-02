package com.flutterhull.sdk

import android.app.Activity
import android.content.Context
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineGroup
import io.flutter.embedding.engine.dart.DartExecutor
import java.lang.ref.WeakReference
import java.util.WeakHashMap

/** 原始Engine句柄不转移manager租约，销毁完成前external绑定均不可准入。 */
internal object FlutterHullManagedEngineRegistry {
    private val engines = WeakHashMap<FlutterEngine, Unit>()
    fun add(engine: FlutterEngine) {
        engines[engine] = Unit
    }
    fun contains(engine: FlutterEngine) = engines.containsKey(engine)
    fun remove(engine: FlutterEngine) {
        engines.remove(engine)
    }
}

enum class FlutterHullEnginePolicy { SINGLE, GROUP }

/** 按业务运行域共享；活动和清理中租约在实际销毁后才归还容量。 */
class FlutterHullEngineManager(
    val policy: FlutterHullEnginePolicy = FlutterHullEnginePolicy.SINGLE,
    val maxEngines: Int = 4,
    val maxWarmEngines: Int = 1,
) {
    private companion object {
        // 同一 Activity 的插件回调只交给一个自有 Engine。
        val activityOwners = WeakHashMap<Activity, Any>()
    }
    init {
        require(maxEngines > 0 && maxWarmEngines >= 0)
    }
    private var group: FlutterEngineGroup? = null
    private data class Warm(val lease: Lease, val expiresAt: Long)
    private val warmEngines = mutableListOf<Warm>()
    // 销毁插件抛错后仍持有租约，禁止复用并提供显式重试。
    private val retiringEngines = mutableSetOf<Lease>()
    val failedWarmCleanupCount get() = retiringEngines.size
    private val handler = Handler(Looper.getMainLooper())
    private val expiry = Runnable { trimWarmEngines() }
    var activeEngineCount = 0
        private set
    val warmEngineCount get() = warmEngines.size

    /** 真实启动 Dart，但不绑定 Activity、视图或业务；首次 open 消费该租约。 */
    fun prewarm(context: Context, ttlMillis: Long = 30000,
        configureEngine: ((FlutterEngine) -> Unit)? = null): FlutterEngine {
        checkMain()
        trimWarmEngines()
        require(ttlMillis in 1..86400000) { "INVALID_PREWARM_TTL" }
        check(warmEngines.size < maxWarmEngines) { "WARM_CAPACITY_EXCEEDED" }
        val lease = createLease(context.applicationContext)
        try {
            configureEngine?.let { lease.configurePlugins(it) }
            val control = lease.engine.plugins.get(FlutterHullPlugin::class.java) as? FlutterHullPlugin
                ?: error("PLUGIN_NOT_REGISTERED: FlutterHullPlugin")
            control.markPrewarming(ttlMillis)
            lease.startDart()
            warmEngines.add(Warm(lease, SystemClock.uptimeMillis() + ttlMillis))
            scheduleExpiry()
            return lease.engine
        } catch (error: Exception) {
            runCatching { retire(lease) }.exceptionOrNull()?.let(error::addSuppressed)
            throw error
        }
    }
    fun trimWarmEngines() {
        checkMain()
        val now = SystemClock.uptimeMillis()
        val expired = warmEngines.filter { it.expiresAt <= now }
        warmEngines.removeAll(expired.toSet())
        expired.forEach { retire(it.lease) }
        scheduleExpiry()
    }
    /** 宿主 onTrimMemory/onLowMemory 转发；不触碰已消费或清理中的 Engine。 */
    fun handleMemoryPressure() {
        checkMain()
        handler.removeCallbacks(expiry)
        val removed = warmEngines.toList()
        warmEngines.clear()
        removed.forEach { retire(it.lease) }
    }
    fun retryWarmCleanup() {
        checkMain()
        retiringEngines.toList().forEach { retire(it) }
    }
    private fun retire(lease: Lease) {
        retiringEngines.add(lease)
        runCatching { lease.destroy() }.onSuccess { retiringEngines.remove(lease) }
    }
    private fun scheduleExpiry() {
        handler.removeCallbacks(expiry)
        warmEngines.minOfOrNull { it.expiresAt }?.let { handler.postAtTime(expiry, it) }
    }
    internal fun acquire(activity: Activity): Lease {
        checkMain()
        check(!activityOwners.containsKey(activity)) { "ACTIVITY_IN_USE" }
        trimWarmEngines()
        val lease = if (warmEngines.isEmpty()) createLease(activity.applicationContext)
            else warmEngines.removeAt(0).lease.also { scheduleExpiry() }
        val token = Any()
        activityOwners[activity] = token
        lease.activity = WeakReference(activity)
        lease.token = token
        return lease
    }
    private fun createLease(context: Context): Lease {
        val capacity = if (policy == FlutterHullEnginePolicy.SINGLE) 1 else maxEngines
        check(activeEngineCount < capacity) { "ENGINE_CAPACITY_EXCEEDED" }
        // 创建也先预留容量，插件同步重入不能超额创建。
        activeEngineCount++
        var currentGroup: FlutterEngineGroup? = null
        try {
            currentGroup = if (policy == FlutterHullEnginePolicy.GROUP)
                group ?: FlutterEngineGroup(context).also { group = it } else null
            val engine = if (currentGroup == null) FlutterEngine(context)
                else currentGroup.createAndRunEngine(FlutterEngineGroup.Options(context)
                    .setDartEntrypoint(DartExecutor.DartEntrypoint.createDefault()))
            FlutterHullManagedEngineRegistry.add(engine)
            return Lease(engine, currentGroup)
        } catch (error: Exception) {
            activeEngineCount--
            if (currentGroup != null && group === currentGroup) group = null
            throw error
        }
    }

    private fun checkMain() {
        check(Looper.myLooper() == Looper.getMainLooper()) { "请在主线程操作引擎" }
    }
    internal inner class Lease(val engine: FlutterEngine, private val generation: FlutterEngineGroup?) {
        internal var activity: WeakReference<Activity>? = null
        internal var token: Any? = null
        private var released = false
        private var pluginsConfigured = false
        fun configurePlugins(configure: (FlutterEngine) -> Unit) {
            check(!released) { "ENGINE_CLOSED" }
            if (pluginsConfigured) return
            configure(engine)
            pluginsConfigured = true
        }
        fun startDart() {
            check(!released) { "ENGINE_CLOSED" }
            if (!engine.dartExecutor.isExecutingDart)
                engine.dartExecutor.executeDartEntrypoint(DartExecutor.DartEntrypoint.createDefault())
        }
        fun destroy() {
            if (released) return
            // 退休已销毁 spawner 所属 Group，旧代关闭不影响新代。
            if (generation != null && group === generation) group = null
            engine.destroy()
            FlutterHullManagedEngineRegistry.remove(engine)
            released = true
            activeEngineCount--
            activity?.get()?.let { if (activityOwners[it] === token) activityOwners.remove(it) }
            activity?.clear()
        }
    }
}
