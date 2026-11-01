package com.flutterhull.sdk

import android.content.ComponentCallbacks2
import android.content.Intent
import android.os.Bundle
import android.os.Looper
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.platform.PlatformPlugin

/** ComponentActivity 的自有 Engine 接入点；Runner 自有回调由 Runner 转发。 */
class FlutterHullHostCallbacks
internal constructor(
    private val engine: () -> FlutterEngine?,
    private val firstFrameReady: () -> Boolean,
    private val platform: () -> PlatformPlugin?,
) {
    private companion object {
        const val PLUGIN_STATE = "com.flutterhull.pluginState"
    }

    private fun current(): FlutterEngine? {
        check(Looper.myLooper() == Looper.getMainLooper()) { "请在主线程转发宿主回调" }
        return engine()
    }

    /** 对应官方 onPostResume，在前台重新应用当前 Engine 的窗口样式。 */
    fun onPostResume() {
        val current = current() ?: return
        platform()?.updateSystemUiOverlays()
        current.platformViewsController.onResume()
    }

    fun onWindowFocusChanged(hasFocus: Boolean) {
        val current = current() ?: return
        if (hasFocus) {
            current.lifecycleChannel.aWindowIsFocused()
            platform()?.updateSystemUiOverlays()
        } else current.lifecycleChannel.noWindowsAreFocused()
    }

    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean =
        current()?.activityControlSurface?.onActivityResult(requestCode, resultCode, data) ?: false

    fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<String>,
        grantResults: IntArray,
    ): Boolean =
        current()
            ?.activityControlSurface
            ?.onRequestPermissionsResult(requestCode, permissions, grantResults) ?: false

    fun onNewIntent(intent: Intent) {
        current()?.activityControlSurface?.onNewIntent(intent)
    }

    fun onUserLeaveHint() {
        current()?.activityControlSurface?.onUserLeaveHint()
    }

    fun onSaveInstanceState(outState: Bundle) {
        val current = current() ?: return
        val plugins = Bundle()
        current.activityControlSurface.onSaveInstanceState(plugins)
        outState.putBundle(PLUGIN_STATE, plugins)
    }

    fun onRestoreInstanceState(savedState: Bundle?) {
        current()
            ?.activityControlSurface
            ?.onRestoreInstanceState(savedState?.getBundle(PLUGIN_STATE))
    }

    fun onTrimMemory(level: Int) {
        val current = current() ?: return
        // 与官方宿主一致，在首帧后才通知 Dart 内存压力，纹理和平台视图始终收到通知。
        if (firstFrameReady() && level >= ComponentCallbacks2.TRIM_MEMORY_RUNNING_LOW) {
            current.dartExecutor.notifyLowMemoryWarning()
            current.systemChannel.sendMemoryPressureWarning()
        }
        current.renderer.onTrimMemory(level)
        current.platformViewsController.onTrimMemory(level)
    }

    fun onLowMemory() {
        onTrimMemory(ComponentCallbacks2.TRIM_MEMORY_COMPLETE)
    }
}
