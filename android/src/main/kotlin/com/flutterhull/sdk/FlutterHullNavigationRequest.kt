package com.flutterhull.sdk

import android.os.Handler
import android.os.Looper
import com.aeris.sdk.AndroidBridgeUIContext
import io.flutter.plugin.common.MethodChannel

/** 先安装 onClose 再展示页面；正常返回也必须等待真实 UI 清理完成。 */
class FlutterHullNavigationRequest
internal constructor(
    val navigationId: String,
    val pageId: String,
    val route: String,
    val arguments: Map<String, Any?>,
    val context: AndroidBridgeUIContext,
    private val reply: MethodChannel.Result,
    private val finished: () -> Unit,
) {
    var onClose: ((() -> Unit) -> Unit)? = null
    var isCancelled = false
        private set

    private var ending = false
    private var delivered = false
    private var outcome: Map<String, Any?>? = null
    private var failure: Pair<String, String>? = null
    internal var ticket: FlutterHullCleanupTicket? = null

    fun complete(result: Map<String, Any?>? = null) {
        val copied =
            try {
                result?.let { FlutterHullJSON.objectCopy(it) }
            } catch (_: IllegalArgumentException) {
                fail("INVALID_RESULT", "导航结果必须是受限 JSON 对象")
                return
            }
        onMain {
            if (!ending) {
                outcome = copied
                ending = true
                ticket?.cancel()
            }
        }
    }

    fun fail(code: String, message: String) {
        onMain {
            if (!ending) {
                failure = code to message
                ending = true
                ticket?.cancel()
            }
        }
    }

    private fun onMain(action: () -> Unit) {
        if (Looper.myLooper() == Looper.getMainLooper()) action()
        else Handler(Looper.getMainLooper()).post { action() }
    }

    internal fun cancel() {
        isCancelled = true
        ending = true
        deliver("NAVIGATION_CANCELLED" to "导航已取消")
        ticket?.cancel()
    }

    internal fun cleanup(done: () -> Unit) {
        var drained = false
        val drain: () -> Unit = {
            if (!drained) {
                drained = true
                if (!isCancelled) deliver(failure)
                ticket?.finish()
                ticket = null
                onClose = null
                finished()
                done()
            }
        }
        val finish: () -> Unit = {
            if (Looper.myLooper() == Looper.getMainLooper()) drain()
            else Handler(Looper.getMainLooper()).post { drain() }
        }
        onClose?.invoke(finish) ?: finish()
    }

    private fun deliver(error: Pair<String, String>?) {
        if (delivered) return
        delivered = true
        if (error == null) reply.success(outcome) else reply.error(error.first, error.second, null)
    }
}

internal class FlutterHullNavigationStore(
    private val registry: FlutterHullCleanupRegistry,
    private val context: AndroidBridgeUIContext,
    private val onOpen: ((FlutterHullNavigationRequest) -> Unit)?,
) {
    private val active = mutableMapOf<String, FlutterHullNavigationRequest>()
    val activeCount
        get() = active.size

    private var closing = false
    private var transportAvailable = true

    fun open(input: Map<String, *>, reply: MethodChannel.Result) {
        if (closing) {
            reply.error("CLOSED", "导航已关闭", null)
            return
        }
        val id = input["navigationId"] as? String
        val page = input["pageId"] as? String
        val route = input["route"] as? String
        val args = input["arguments"] as? Map<*, *>
        if (
            id.isNullOrEmpty() ||
                id.toByteArray(Charsets.UTF_8).size > 256 ||
                page.isNullOrEmpty() ||
                page.toByteArray(Charsets.UTF_8).size > 256 ||
                route.isNullOrEmpty() ||
                route.toByteArray(Charsets.UTF_8).size > 512 ||
                args == null ||
                runCatching { FlutterHullJSON.objectCopy(args) }.isFailure
        ) {
            reply.error("INVALID_ARGUMENT", "无效导航参数", null)
            return
        }
        if (active.containsKey(id) || active.size >= 32) {
            reply.error("BACKPRESSURE", "导航重复或配额已满", null)
            return
        }
        val handler =
            onOpen
                ?: run {
                    reply.error("NAVIGATION_UNAVAILABLE", "宿主未提供原生导航", null)
                    return
                }
        val gated =
            object : MethodChannel.Result {
                override fun success(value: Any?) {
                    if (transportAvailable) reply.success(value)
                }

                override fun error(code: String, message: String?, details: Any?) {
                    if (transportAvailable) reply.error(code, message, details)
                }

                override fun notImplemented() {
                    if (transportAvailable) reply.notImplemented()
                }
            }
        val copied = FlutterHullJSON.objectCopy(args)
        val request =
            FlutterHullNavigationRequest(id, page, route, copied, context, gated) {
                active.remove(id)
            }
        active[id] = request
        try {
            request.ticket = registry.register("nativeNavigation", request.pageId) { request.cleanup(it) }
            handler(request)
        } catch (error: Exception) {
            if (request.ticket == null) {
                active.remove(id)
                reply.error("CLOSED", "资源作用域已关闭", null)
            } else request.fail("NAVIGATION_FAILED", error.toString())
        }
    }

    fun cancel(id: String): Boolean {
        val request = active[id] ?: return false
        request.cancel()
        return true
    }

    fun sealTransport() {
        transportAvailable = false
    }

    fun close(transportAvailable: Boolean) {
        this.transportAvailable = this.transportAvailable && transportAvailable
        closing = true
        active.values.toList().forEach { it.cancel() }
    }
}
