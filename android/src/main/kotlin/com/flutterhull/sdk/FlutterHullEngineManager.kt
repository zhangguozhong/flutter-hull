package com.flutterhull.sdk

import android.app.Activity
import android.os.Looper
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineGroup
import io.flutter.embedding.engine.dart.DartExecutor
import java.lang.ref.WeakReference
import java.util.WeakHashMap

enum class FlutterHullEnginePolicy {
    SINGLE,
    GROUP,
}

/** 按业务运行域共享；只统计自有租约，实际销毁成功后才归还容量。 */
class FlutterHullEngineManager(
    val policy: FlutterHullEnginePolicy = FlutterHullEnginePolicy.SINGLE,
    val maxEngines: Int = 4,
) {
    private companion object {
        // 不允许两个自有 Engine 争用 Activity 的第三方插件 requestCode。
        val activityOwners = WeakHashMap<Activity, Any>()
    }

    init {
        require(maxEngines > 0) { "maxEngines 必须为正整数" }
    }

    private var group: FlutterEngineGroup? = null
    var activeEngineCount = 0
        private set

    internal fun acquire(activity: Activity): Lease {
        check(Looper.myLooper() == Looper.getMainLooper()) { "请在主线程操作引擎" }
        check(!activityOwners.containsKey(activity)) { "ACTIVITY_IN_USE" }
        val capacity = if (policy == FlutterHullEnginePolicy.SINGLE) 1 else maxEngines
        check(activeEngineCount < capacity) { "ENGINE_CAPACITY_EXCEEDED" }
        val token = Any()
        activityOwners[activity] = token
        activeEngineCount++
        try {
            val context = activity.applicationContext
            val engine =
                when (policy) {
                    FlutterHullEnginePolicy.SINGLE -> FlutterEngine(context)
                    FlutterHullEnginePolicy.GROUP -> {
                        val current = group ?: FlutterEngineGroup(context).also { group = it }
                        current.createAndRunEngine(
                            FlutterEngineGroup.Options(context)
                                .setDartEntrypoint(DartExecutor.DartEntrypoint.createDefault())
                        )
                    }
                }
            return Lease(engine, WeakReference(activity), token)
        } catch (error: Exception) {
            if (activityOwners[activity] === token) activityOwners.remove(activity)
            activeEngineCount--
            throw error
        }
    }

    internal inner class Lease(
        val engine: FlutterEngine,
        private val activity: WeakReference<Activity>,
        private val token: Any,
    ) {
        private var released = false

        fun destroy() {
            if (released) return
            engine.destroy()
            released = true
            activeEngineCount--
            activity.get()?.let { if (activityOwners[it] === token) activityOwners.remove(it) }
            activity.clear()
        }
    }
}
