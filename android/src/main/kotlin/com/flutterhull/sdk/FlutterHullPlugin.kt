package com.flutterhull.sdk

import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodChannel

/** 控制通道不传业务响应；同一个 Engine 只能由一个 Coordinator 配置。 */
class FlutterHullPlugin() : FlutterPlugin {
    internal constructor(channel: MethodChannel) : this() {
        this.channel = channel
    }

    private var channel: MethodChannel? = null
    private var configuration: Map<String, Any?>? = null
    private var runToken: String? = null
    private var closing = false
    private var reserved = false
    private var lifecycleRevision = 0
    private var restorationRevision = 0L
    internal var restorationSnapshot: Map<String, Any?>? = null
        private set

    private var visible = true
    private var foreground = true
    internal var onFinishContainer: ((Map<String, Any?>?, MethodChannel.Result) -> Unit)? = null
    internal var onOpenNative: ((Map<String, *>, MethodChannel.Result) -> Unit)? = null
    internal var onCancelNavigation: ((String) -> Boolean)? = null
    private var backRound = 0
    private val backWaiters = mutableListOf<(Boolean) -> Unit>()
    var onCommunicationReady: (() -> Unit)? = null
    var onFirstFrame: (() -> Unit)? = null
    var onRestart: (() -> Unit)? = null
    internal var onEngineDetached: (() -> Unit)? = null

    internal fun reserve() {
        check(!closing) { "ENGINE_ALREADY_BOUND" }
        check(!reserved && configuration == null) { "ENGINE_IN_USE" }
        reserved = true
    }

    internal fun releaseReservation() {
        if (configuration == null && !closing) reserved = false
    }

    internal fun prepareForEngineDestruction() {
        closing = true
        configuration = null
        channel?.setMethodCallHandler(null)
        channel = null
        backRound++
        val waiters = backWaiters.toList()
        backWaiters.clear()
        waiters.forEach { it(true) }
    }

    internal fun configure(value: Map<String, Any?>) {
        check(configuration == null && !closing)
        restorationRevision = 0
        restorationSnapshot = value["restoration"]?.let { FlutterHullRestoration.normalize(it) }
        configuration =
            value +
                mapOf(
                    "supportsRestoration" to true,
                    "visible" to visible,
                    "foreground" to foreground,
                    "lifecycleRevision" to lifecycleRevision,
                )
    }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel =
            MethodChannel(binding.binaryMessenger, "leo_flutter/control").also { control ->
                control.setMethodCallHandler { call, reply ->
                    if (closing && call.method != "cancelNavigation") {
                        reply.error("CLOSED", "容器正在关闭", null)
                        return@setMethodCallHandler
                    }
                    when (call.method) {
                        "bootstrap" -> {
                            val token = (call.arguments as? Map<*, *>)?.get("runToken") as? String
                            when {
                                token.isNullOrEmpty() ||
                                    token.toByteArray(Charsets.UTF_8).size > 256 ->
                                    reply.error("INVALID_ARGUMENT", "缺少启动标记", null)
                                configuration == null -> reply.error("NOT_READY", "原生绑定尚未完成", null)
                                runToken != null && runToken != token -> {
                                    reply.error("HOT_RESTART_REQUIRES_REOPEN", "请重新打开容器", null)
                                    onRestart?.invoke()
                                }
                                else -> {
                                    runToken = token
                                    reply.success(configuration)
                                }
                            }
                        }
                        "saveState" -> {
                            val args = call.arguments as? Map<*, *>
                            val revision = args?.get("revision")
                            val currentRevision =
                                when (revision) {
                                    is Int -> revision.toLong()
                                    is Long -> revision
                                    else -> null
                                }
                            if (
                                args == null ||
                                    configuration == null ||
                                    args["containerId"] != configuration?.get("containerId") ||
                                    currentRevision == null ||
                                    currentRevision <= 0 ||
                                    currentRevision > 9_007_199_254_740_991L
                            ) {
                                reply.error("INVALID_ARGUMENT", "无效的快照身份或版本", null)
                            } else if (currentRevision <= restorationRevision) {
                                reply.success(false)
                            } else {
                                val snapshot = runCatching {
                                    FlutterHullRestoration.normalize(args["snapshot"])
                                }
                                    .getOrNull()
                                if (snapshot == null)
                                    reply.error("INVALID_ARGUMENT", "无效的页面快照", null)
                                else {
                                    restorationSnapshot = snapshot
                                    restorationRevision = currentRevision
                                    reply.success(true)
                                }
                            }
                        }
                        "finishContainer" -> {
                            val copied =
                                call.arguments?.let { value ->
                                    runCatching { FlutterHullJSON.objectCopy(value) }.getOrNull()
                                }
                            if (
                                onFinishContainer == null ||
                                    (call.arguments != null && copied == null)
                            )
                                reply.success(false)
                            else onFinishContainer?.invoke(copied, reply)
                        }
                        "openNative" -> {
                            val args = call.arguments as? Map<*, *>
                            if (args == null || onOpenNative == null)
                                reply.error("NAVIGATION_UNAVAILABLE", "原生导航未绑定", null)
                            else
                                onOpenNative?.invoke(
                                    args.entries.associate { it.key.toString() to it.value },
                                    reply,
                                )
                        }
                        "cancelNavigation" -> {
                            onCancelNavigation?.invoke(
                                (call.arguments as? Map<*, *>)?.get("navigationId") as? String ?: ""
                            )
                            reply.success(null)
                        }
                        "communicationReady" -> {
                            onCommunicationReady?.invoke()
                            reply.success(null)
                        }
                        "firstFrame" -> {
                            onFirstFrame?.invoke()
                            reply.success(null)
                        }
                        else -> reply.notImplemented()
                    }
                }
            }
    }

    internal fun setLifecycle(visible: Boolean? = null, foreground: Boolean? = null) {
        lifecycleRevision++
        visible?.let { this.visible = it }
        foreground?.let { this.foreground = it }
        val current = configuration ?: return
        if (closing) return
        configuration =
            current +
                mapOf(
                    "visible" to this.visible,
                    "foreground" to this.foreground,
                    "lifecycleRevision" to lifecycleRevision,
                )
        channel?.invokeMethod(
            "hostLifecycle",
            mapOf(
                "containerId" to current["containerId"],
                "visible" to this.visible,
                "foreground" to this.foreground,
                "lifecycleRevision" to lifecycleRevision,
            ),
        )
    }

    internal fun requestBack(completion: (Boolean) -> Unit) {
        if (closing) {
            completion(true)
            return
        }
        backWaiters.add(completion)
        if (backWaiters.size != 1) return
        val round = ++backRound
        fun finish(handled: Boolean) {
            if (round != backRound) return
            val callbacks = backWaiters.toList()
            backWaiters.clear()
            callbacks.forEach { it(handled) }
        }
        channel?.invokeMethod(
            "back",
            null,
            object : MethodChannel.Result {
                override fun success(value: Any?) = finish(value as? Boolean ?: true)

                override fun error(code: String, message: String?, details: Any?) = finish(true)

                override fun notImplemented() = finish(true)
            },
        ) ?: finish(true)
        Handler(Looper.getMainLooper()).postDelayed({ finish(true) }, 1000)
    }

    fun shutdown(completion: () -> Unit) {
        shutdownResult { if (it.isSuccess) completion() }
    }

    internal fun shutdownResult(completion: (Result<Unit>) -> Unit) {
        closing = true
        configuration = null
        var delivered = false
        fun finish(result: Result<Unit>) {
            if (!delivered) { delivered = true; completion(result) }
        }
        channel?.invokeMethod("shutdown", null, object : MethodChannel.Result {
            override fun success(value: Any?) = finish(Result.success(Unit))
            override fun error(code: String, message: String?, details: Any?) =
                finish(Result.failure(FlutterHullCleanupError("DART_SHUTDOWN_FAILED")))
            override fun notImplemented() =
                finish(Result.failure(FlutterHullCleanupError("DART_SHUTDOWN_FAILED")))
        }) ?: finish(Result.failure(FlutterHullCleanupError("DART_UNAVAILABLE")))
        // 没有时间兜底：超时属于 close 等待，不属于真实清理完成。
    }

    internal fun queryCleanup(completion: (Result<List<Map<String, Any?>>>) -> Unit) {
        channel?.invokeMethod("cleanupResources", null, object : MethodChannel.Result {
            override fun success(value: Any?) {
                val rows = value as? List<*>
                if (rows == null || rows.size > 64 || rows.any { it !is Map<*, *> }) {
                    completion(Result.failure(FlutterHullCleanupError("DART_QUERY_FAILED")))
                } else {
                    completion(Result.success(rows.map { row ->
                        (row as Map<*, *>).entries.associate { it.key.toString() to it.value }
                    }))
                }
            }
            override fun error(code: String, message: String?, details: Any?) =
                completion(Result.failure(FlutterHullCleanupError("DART_QUERY_FAILED")))
            override fun notImplemented() =
                completion(Result.failure(FlutterHullCleanupError("DART_QUERY_FAILED")))
        }) ?: completion(Result.failure(FlutterHullCleanupError("DART_UNAVAILABLE")))
    }

    internal fun queryCleanupPage(offset: Int, limit: Int,
        completion: (Result<Map<String, Any?>>) -> Unit) {
        if (offset < 0 || limit !in 1..64) {
            completion(Result.failure(FlutterHullCleanupError("INVALID_ARGUMENT")))
            return
        }
        channel?.invokeMethod("cleanupResourcesPage", mapOf("offset" to offset, "limit" to limit), object : MethodChannel.Result {
            override fun success(value: Any?) {
                val page = value as? Map<*, *>
                val rows = page?.get("items") as? List<*>
                val total = page?.get("total") as? Number
                if (page == null || rows == null || rows.size > limit || rows.any { it !is Map<*, *> } ||
                    page["offset"] != offset || page["limit"] != limit || total == null || total.toLong() < 0) {
                    completion(Result.failure(FlutterHullCleanupError("DART_QUERY_FAILED")))
                } else completion(Result.success(page.entries.associate { it.key.toString() to it.value }))
            }
            override fun error(code: String, message: String?, details: Any?) =
                completion(Result.failure(FlutterHullCleanupError("DART_QUERY_FAILED")))
            override fun notImplemented() =
                completion(Result.failure(FlutterHullCleanupError("DART_QUERY_FAILED")))
        }) ?: completion(Result.failure(FlutterHullCleanupError("DART_UNAVAILABLE")))
    }

    internal fun retryCleanup(resourceId: String, completion: (Result<Boolean>) -> Unit) {
        channel?.invokeMethod("retryCleanup", mapOf("resourceId" to resourceId), object : MethodChannel.Result {
            override fun success(value: Any?) {
                if (value is Boolean) completion(Result.success(value))
                else completion(Result.failure(FlutterHullCleanupError("DART_RETRY_FAILED")))
            }
            override fun error(code: String, message: String?, details: Any?) =
                completion(Result.failure(FlutterHullCleanupError("DART_RETRY_FAILED")))
            override fun notImplemented() =
                completion(Result.failure(FlutterHullCleanupError("DART_RETRY_FAILED")))
        }) ?: completion(Result.failure(FlutterHullCleanupError("DART_UNAVAILABLE")))
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        val callback = onEngineDetached
        onEngineDetached = null
        callback?.invoke()
        prepareForEngineDestruction()
        closing = true
        configuration = null
        channel?.setMethodCallHandler(null)
        channel = null
        onRestart = null
        onFirstFrame = null
        onCommunicationReady = null
    }
}
