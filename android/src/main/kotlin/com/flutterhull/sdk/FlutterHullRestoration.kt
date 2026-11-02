package com.flutterhull.sdk

import org.json.JSONArray
import org.json.JSONObject

/** 页面数据采用受限 JSON；只投影路由字段，不持久化运行时和回调引用。 */
internal object FlutterHullRestoration {
    const val BUNDLE_KEY = "com.flutterhull.restoration.v1"
    private const val MAX_BYTES = 65536

    fun normalize(value: Any?): Map<String, Any?> {
        val source = value as? Map<*, *> ?: invalid()
        require(source["version"] == 1 || source["version"] == 1L) { "INVALID_RESTORATION" }
        val routes = source["routes"] as? List<*> ?: invalid()
        require(routes.size in 1..32) { "INVALID_RESTORATION" }
        val normalized = routes.map { item ->
            val route = item as? Map<*, *> ?: invalid()
            val name = route["route"] as? String ?: invalid()
            require(name.isNotEmpty() && name.toByteArray(Charsets.UTF_8).size <= 512) {
                "INVALID_RESTORATION"
            }
            val arguments = route["arguments"] as? Map<*, *> ?: invalid()
            val state = route["state"] as? Map<*, *> ?: invalid()
            val result = mutableMapOf<String, Any?>("route" to name, "arguments" to arguments, "state" to state)
            if (route.containsKey("module")) {
                val module = route["module"] as? Map<*, *> ?: invalid()
                fun text(key: String): String {
                    val value = module[key] as? String ?: invalid()
                    require(value.isNotEmpty() && value.toByteArray(Charsets.UTF_8).size <= 128) { "INVALID_RESTORATION" }
                    return value
                }
                val copied = mutableMapOf<String, Any?>("id" to text("id"), "version" to text("version"))
                if (module.containsKey("baseline")) copied["baseline"] = text("baseline")
                result["module"] = copied
            }
            result.toMap()
        }
        val snapshot = mutableMapOf<String, Any?>("version" to 1, "routes" to normalized)
        if (source.containsKey("userDomain")) {
            val domain = source["userDomain"] as? String ?: invalid()
            require(domain.isNotEmpty() && domain.toByteArray(Charsets.UTF_8).size <= 128) { "INVALID_RESTORATION" }
            snapshot["userDomain"] = domain
        }
        return FlutterHullJSON.objectCopy(snapshot)
    }

    fun encode(value: Map<String, Any?>): String = JSONObject(value).toString()

    fun decode(value: String?): Map<String, Any?>? = runCatching {
        if (value == null || value.toByteArray(Charsets.UTF_8).size > MAX_BYTES)
            return@runCatching null
        normalize(fromJson(JSONObject(value)))
    }
        .getOrNull()

    private fun fromJson(value: Any?): Any? =
        when (value) {
            null,
            JSONObject.NULL -> null
            is JSONObject -> value.keys().asSequence().associateWith { fromJson(value.get(it)) }
            is JSONArray -> (0 until value.length()).map { fromJson(value.get(it)) }
            else -> value
        }

    private fun invalid(): Nothing = throw IllegalArgumentException("INVALID_RESTORATION")
}

/** 与 Dart/Swift 相同的结构预算及深拷贝，避免平台编码器差异。 */
internal object FlutterHullJSON {
    fun objectCopy(value: Any?): Map<String, Any?> {
        var remaining = 65536
        val parents = java.util.Collections.newSetFromMap(java.util.IdentityHashMap<Any, Boolean>())
        fun consume(count: Int) {
            remaining -= count
            require(remaining >= 0) { "INVALID_JSON" }
        }
        fun string(text: String) {
            consume(2)
            var index = 0
            while (index < text.length) {
                val char = text[index]
                val point = Character.codePointAt(text, index)
                require(!Character.isSurrogate(char) || point > 0xffff) { "INVALID_JSON" }
                consume(
                    when {
                        point < 32 -> 6
                        point == 34 || point == 92 -> 2
                        point < 128 -> 1
                        point < 2048 -> 2
                        point < 65536 -> 3
                        else -> 4
                    }
                )
                index += Character.charCount(point)
            }
        }
        fun copy(node: Any?, depth: Int): Any? {
            require(depth <= 16) { "INVALID_JSON" }
            return when (node) {
                null -> {
                    consume(4)
                    null
                }
                is Boolean -> node.also { consume(if (it) 4 else 5) }
                is String -> node.also { string(it) }
                is Byte,
                is Short,
                is Int,
                is Long ->
                    node.also {
                        val integer = (it as Number).toLong()
                        require(integer in -9_007_199_254_740_991L..9_007_199_254_740_991L) {
                            "INVALID_JSON"
                        }
                        consume(32)
                    }
                is Float ->
                    node.also {
                        require(it.isFinite()) { "INVALID_JSON" }
                        consume(32)
                    }
                is Double ->
                    node.also {
                        require(it.isFinite()) { "INVALID_JSON" }
                        consume(32)
                    }
                is Map<*, *> -> {
                    require(parents.add(node)) { "INVALID_JSON" }
                    try {
                        consume(2 + maxOf(0, node.size - 1))
                        java.util.Collections.unmodifiableMap(
                            node.entries.associate { (key, value) ->
                                require(key is String) { "INVALID_JSON" }
                                string(key)
                                consume(1)
                                key to copy(value, depth + 1)
                            }
                        )
                    } finally {
                        parents.remove(node)
                    }
                }
                is List<*> -> {
                    require(parents.add(node)) { "INVALID_JSON" }
                    try {
                        consume(2 + maxOf(0, node.size - 1))
                        java.util.Collections.unmodifiableList(node.map { copy(it, depth + 1) })
                    } finally {
                        parents.remove(node)
                    }
                }
                else -> throw IllegalArgumentException("INVALID_JSON")
            }
        }
        require(value is Map<*, *>) { "INVALID_JSON" }
        @Suppress("UNCHECKED_CAST")
        return copy(value, 0) as Map<String, Any?>
    }
}
