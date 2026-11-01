package com.flutterhull.sdk

import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import java.util.UUID

/** 诊断只接收安全错误代码，不传递业务异常消息。 */
class FlutterHullCleanupError(code: String) : Exception() {
    val code = code.takeIf { it.matches(Regex("^[A-Z][A-Z0-9_]{0,63}$")) } ?: "CLEANUP_FAILED"
}

enum class FlutterHullCleanupState { REGISTERED, RUNNING, FAILED, COMPLETED }

data class FlutterHullCleanupResource(
    val resourceId: String,
    val name: String,
    val owner: String,
    val elapsedMs: Long,
    val state: FlutterHullCleanupState,
    val attempt: Int,
    val retryable: Boolean,
    val errorCode: String?,
)

/** 超时只报告失败；登记的真实完成信号仍然负责解除资源持有。 */
class FlutterHullCleanupRegistry(val maxResources: Int = 512) {
    init { require(maxResources > 0) { "资源容量必须为正整数" } }
    private class Entry(
        val id: String,
        val name: String,
        val owner: String,
        val retryable: Boolean,
        val legacy: Boolean,
        var cleanup: (((Result<Unit>) -> Unit) -> Unit)?,
        var state: FlutterHullCleanupState = FlutterHullCleanupState.REGISTERED,
        var attempt: Int = 0,
        var startedAt: Long? = null,
        var elapsedMs: Long = 0,
        var errorCode: String? = null,
    )

    private val entries = linkedMapOf<String, Entry>()
    private val main = Handler(Looper.getMainLooper())
    private var closing = false
    private var drained = false
    private var outcome: Result<Unit>? = null
    private val waiters = mutableListOf<(Result<Unit>) -> Unit>()
    var onDrained: (() -> Unit)? = null
    var onResourceChanged: ((FlutterHullCleanupResource) -> Unit)? = null
    val pendingCount get() = entries.values.count { it.state != FlutterHullCleanupState.COMPLETED }
    val resources get() = entries.values.map(::snapshot)
    val statistics get() = mapOf(
        "registered" to entries.values.count { it.state == FlutterHullCleanupState.REGISTERED },
        "running" to entries.values.count { it.state == FlutterHullCleanupState.RUNNING },
        "failed" to entries.values.count { it.state == FlutterHullCleanupState.FAILED },
        "total" to entries.size, "limit" to maxResources,
    )
    /** 只复制当前页，已完成项归还容量；失败与运行中资源继续占用。 */
    fun resourcePage(offset: Int = 0, limit: Int = 64): List<FlutterHullCleanupResource> {
        checkMain()
        if (offset < 0 || limit !in 1..64) throw FlutterHullCleanupError("INVALID_ARGUMENT")
        return entries.values.asSequence().drop(offset).take(limit).map(::snapshot).toList()
    }

    fun register(cleanup: (() -> Unit) -> Unit): FlutterHullCleanupTicket =
        add("legacy", "", false, true) { done -> cleanup { done(Result.success(Unit)) } }

    fun register(name: String, owner: String, cleanup: (() -> Unit) -> Unit): FlutterHullCleanupTicket =
        add(name, owner, false, true) { done -> cleanup { done(Result.success(Unit)) } }

    fun registerOperation(
        name: String,
        owner: String,
        retryable: Boolean = false,
        cleanup: ((Result<Unit>) -> Unit) -> Unit,
    ): FlutterHullCleanupTicket = add(name, owner, retryable, false, cleanup)

    private fun add(
        name: String,
        owner: String,
        retryable: Boolean,
        legacy: Boolean,
        cleanup: ((Result<Unit>) -> Unit) -> Unit,
    ): FlutterHullCleanupTicket {
        checkMain()
        check(!closing) { "资源作用域已经关闭" }
        if (entries.size >= maxResources) throw FlutterHullCleanupError("RESOURCE_CAPACITY_EXCEEDED")
        val key = UUID.randomUUID().toString()
        entries[key] = Entry(key, name, owner, retryable, legacy, cleanup)
        notify(key)
        return FlutterHullCleanupTicket(key, { start(key) }, {
            val entry = entries[key]
            // 新操作必须由本轮 Result 完成，ticket 不能绕过失败或轮次隔离。
            if (entry?.legacy == true) finish(key, entry.attempt, Result.success(Unit))
        })
    }

    fun retry(resourceId: String): Boolean {
        checkMain()
        val entry = entries[resourceId] ?: return false
        if (entry.state != FlutterHullCleanupState.FAILED || !entry.retryable) return false
        entry.state = FlutterHullCleanupState.REGISTERED
        start(resourceId)
        return true
    }

    fun close(timeoutMillis: Long, completion: (Result<Unit>) -> Unit) {
        checkMain()
        outcome?.let { completion(it); return }
        waiters.add(completion)
        if (closing) return
        closing = true
        main.postDelayed({
            if (outcome == null) complete(Result.failure(FlutterHullCleanupError("CLEANUP_TIMEOUT")))
        }, timeoutMillis.coerceAtLeast(0))
        entries.keys.toList().forEach(::start)
        checkDrained()
    }

    private fun start(key: String) {
        checkMain()
        val entry = entries[key] ?: return
        if (entry.state != FlutterHullCleanupState.REGISTERED) return
        val cleanup = entry.cleanup ?: return
        entry.state = FlutterHullCleanupState.RUNNING
        val attempt = ++entry.attempt
        entry.startedAt = SystemClock.elapsedRealtime()
        entry.errorCode = null
        notify(key)
        // 观察者可能同步完成旧 ticket，不能在资源解除登记后继续调用清理。
        val current = entries[key]
        if (current == null || current.attempt != attempt || current.state != FlutterHullCleanupState.RUNNING) return
        fun complete(result: Result<Unit>) {
            if (Looper.myLooper() == Looper.getMainLooper()) finish(key, attempt, result)
            else main.post { finish(key, attempt, result) }
        }
        try { cleanup(::complete) }
        catch (error: Exception) { complete(Result.failure(error)) }
    }

    private fun finish(key: String, attempt: Int, result: Result<Unit>) {
        checkMain()
        val entry = entries[key] ?: return
        if (entry.attempt != attempt ||
            (entry.state != FlutterHullCleanupState.RUNNING &&
                !(entry.legacy && entry.state != FlutterHullCleanupState.COMPLETED))) return
        entry.elapsedMs = elapsed(entry)
        entry.startedAt = null
        if (result.isSuccess) {
            entry.state = FlutterHullCleanupState.COMPLETED
            entry.cleanup = null
        } else {
            entry.state = FlutterHullCleanupState.FAILED
            entry.errorCode = (result.exceptionOrNull() as? FlutterHullCleanupError)?.code ?: "CLEANUP_FAILED"
        }
        if (entry.state == FlutterHullCleanupState.COMPLETED) entries.remove(key)
        runCatching { onResourceChanged?.invoke(snapshot(entry)) }
        checkDrained()
    }

    private fun elapsed(entry: Entry) =
        entry.startedAt?.let { (SystemClock.elapsedRealtime() - it).coerceAtLeast(0) } ?: entry.elapsedMs

    private fun snapshot(entry: Entry) = FlutterHullCleanupResource(
        entry.id, entry.name, entry.owner, elapsed(entry), entry.state, entry.attempt, entry.retryable, entry.errorCode,
    )

    private fun notify(key: String) {
        entries[key]?.let { entry -> runCatching { onResourceChanged?.invoke(snapshot(entry)) } }
    }

    private fun checkDrained() {
        if (!closing || pendingCount != 0 || drained) return
        drained = true
        if (outcome == null) complete(Result.success(Unit))
        val done = onDrained
        onDrained = null
        runCatching { done?.invoke() }
    }

    private fun complete(result: Result<Unit>) {
        if (outcome != null) return
        outcome = result
        val callbacks = waiters.toList()
        waiters.clear()
        callbacks.forEach { runCatching { it(result) } }
    }

    private fun checkMain() {
        check(Looper.myLooper() == Looper.getMainLooper()) { "请在主线程操作容器" }
    }
}

class FlutterHullCleanupTicket internal constructor(
    val resourceId: String,
    private val cancelAction: () -> Unit,
    private val finishAction: () -> Unit,
) {
    fun cancel() = cancelAction()
    fun finish() = finishAction()
}
