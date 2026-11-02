package com.flutterhull.sdk

/** 非敏感宿主环境不可变值；用户域由宿主提供不透明标识。 */
data class FlutterHullHostEnvironment(
    val revision: Long = 0,
    val theme: String = "system",
    val locale: String = "en",
    val fontScale: Double = 1.0,
    val width: Double = 0.0,
    val height: Double = 0.0,
    val userDomain: String = "anonymous",
) {
    init {
        require(
            revision in 0..9007199254740991L && theme in setOf("system", "light", "dark") &&
            locale.isNotEmpty() && locale.toByteArray(Charsets.UTF_8).size <= 64 &&
            fontScale.isFinite() && fontScale > 0 && fontScale <= 10 &&
            width.isFinite() && width >= 0 && height.isFinite() && height >= 0 &&
            userDomain.isNotEmpty() && userDomain.toByteArray(Charsets.UTF_8).size <= 128
        ) {
            "INVALID_ENVIRONMENT"
        }
    }
    fun toMap(): Map<String, Any?> = mapOf(
        "revision" to revision,
        "theme" to theme,
        "locale" to locale,
        "fontScale" to fontScale,
        "width" to width,
        "height" to height,
        "userDomain" to userDomain,
    )
}
