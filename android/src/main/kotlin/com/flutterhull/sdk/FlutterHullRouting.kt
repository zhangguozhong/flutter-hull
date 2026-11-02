package com.flutterhull.sdk

import android.os.Handler
import android.os.Looper
import java.util.UUID

/** 可取消的宿主导航请求；Dart 已创建的页面仍由真实清理屏障拥有。 */
class FlutterHullRoutingOperation internal constructor(
    val requestId: String,
    private val cancellation: () -> Unit,
) {
    fun cancel() = cancellation()
}

internal class FlutterHullRoutingQueue {
    private class Entry(
        val operation: FlutterHullRoutingOperation,
        val method: String,
        val arguments: Map<String, Any?>,
        val dedupe: String?,
        completion: (Result<Map<String, Any?>?>) -> Unit,
    ) {
        val completions = mutableListOf(completion)
        var dispatched = false
        var expiry: Runnable? = null
    }
    private val entries = linkedMapOf<String, Entry>()
    private val handler = Handler(Looper.getMainLooper())
    private var send: ((String, Map<String, Any?>, (Result<Map<String, Any?>?>) -> Unit) -> Unit)? = null
    private var cancelTransport: ((String) -> Unit)? = null
    val count get() = entries.size
    fun open(
        method: String,
        arguments: Map<String, Any?>,
        dedupe: String? = null,
        timeoutMillis: Long = 30000,
        completion: (Result<Map<String, Any?>?>) -> Unit,
    ): FlutterHullRoutingOperation {
        if (dedupe != null) entries.values.firstOrNull { it.dedupe == dedupe }?.let {
            if (it.completions.size < 32) it.completions.add(completion)
            else completion(Result.failure(FlutterHullCleanupError("BACKPRESSURE")))
            return it.operation
        }
        val id = UUID.randomUUID().toString()
        val operation = FlutterHullRoutingOperation(id) { cancel(id, "CANCELLED") }
        if (entries.size >= 32 || timeoutMillis !in 1..86400000) {
            completion(Result.failure(FlutterHullCleanupError("BACKPRESSURE")))
            return operation
        }
        val entry = Entry(operation, method, arguments, dedupe, completion)
        entries[id] = entry
        entry.expiry = Runnable { cancel(id, "NAVIGATION_TIMEOUT") }.also {
            handler.postDelayed(it, timeoutMillis)
        }
        dispatch(id)
        return operation
    }
    fun activate(
        send: (String, Map<String, Any?>, (Result<Map<String, Any?>?>) -> Unit) -> Unit,
        cancel: (String) -> Unit,
    ) {
        this.send = send
        cancelTransport = cancel
        entries.keys.toList().forEach(::dispatch)
    }
    fun deactivate(code: String = "CANCELLED") {
        entries.keys.toList().forEach { cancel(it, code) }
        send = null
        cancelTransport = null
    }
    private fun dispatch(id: String) {
        val entry = entries[id] ?: return
        val transport = send ?: return
        if (entry.dispatched) return
        entry.dispatched = true
        transport(entry.method, entry.arguments + mapOf("requestId" to id)) { finish(id, it) }
    }
    private fun cancel(id: String, code: String) {
        val entry = entries[id] ?: return
        if (entry.dispatched) cancelTransport?.invoke(id)
        finish(id, Result.failure(FlutterHullCleanupError(code)))
    }
    private fun finish(id: String, result: Result<Map<String, Any?>?>) {
        val entry = entries.remove(id) ?: return
        entry.expiry?.let { handler.removeCallbacks(it) }
        entry.completions.forEach { runCatching { it(result) } }
    }
}
