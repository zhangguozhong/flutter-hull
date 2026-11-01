import CoreFoundation
import Foundation

/// 快照仅包含页面 JSON 数据；按统一预算深拷贝，避免可变 Foundation 对象逃逸到同步缓存。
enum FlutterHullRestoration {
  static let maxBytes = 64 * 1024
  static func integer(_ value: Any?) -> Int64? {
    guard let number = value as? NSNumber,
      CFGetTypeID(number) != CFBooleanGetTypeID(),
      // 浮点值即使恰好等于整数，也不是协议要求的整数类型。
      ["c", "C", "s", "S", "i", "I", "l", "L", "q", "Q"].contains(String(cString: number.objCType)),
      number.doubleValue.isFinite,
      abs(number.doubleValue) <= 9_007_199_254_740_991
    else { return nil }
    return number.int64Value
  }

  static func copy(_ value: Any) throws -> [String: Any] {
    guard let input = value as? NSDictionary, integer(input["version"]) == 1,
      let routes = input["routes"] as? NSArray, (1...32).contains(routes.count)
    else { throw FlutterHullFailure.invalidRestorationState }
    let normalized = try routes.map { raw -> [String: Any] in
      guard let item = raw as? NSDictionary,
        let route = item["route"] as? String, !route.isEmpty, route.utf8.count <= 512,
        let arguments = item["arguments"] as? NSDictionary,
        let state = item["state"] as? NSDictionary
      else { throw FlutterHullFailure.invalidRestorationState }
      return ["route": route, "arguments": arguments, "state": state]
    }
    return try FlutterHullJSON.object(["version": 1, "routes": normalized])
  }
}

/// 与 Dart/Kotlin 完全一致的保守预算；不依赖平台编码器的转义策略。
enum FlutterHullJSON {
  static func object(_ value: Any) throws -> [String: Any] {
    var remaining = 65536
    var parents = Set<ObjectIdentifier>()
    func consume(_ count: Int) throws {
      remaining -= count
      guard remaining >= 0 else { throw FlutterHullFailure.invalidRestorationState }
    }
    func string(_ value: String) throws {
      try consume(2)
      for scalar in value.unicodeScalars {
        let n = scalar.value
        try consume(
          n < 32 ? 6 : n == 34 || n == 92 ? 2 : n < 128 ? 1 : n < 2048 ? 2 : n < 65536 ? 3 : 4)
      }
    }
    func copy(_ node: Any, _ depth: Int) throws -> Any {
      guard depth <= 16 else { throw FlutterHullFailure.invalidRestorationState }
      if node is NSNull {
        try consume(4)
        return NSNull()
      }
      if let raw = node as? NSString {
        var index = 0
        while index < raw.length {
          let unit = raw.character(at: index)
          if (0xD800...0xDBFF).contains(unit) {
            index += 1
            guard index < raw.length, (0xDC00...0xDFFF).contains(raw.character(at: index)) else {
              throw FlutterHullFailure.invalidRestorationState
            }
          } else if (0xDC00...0xDFFF).contains(unit) {
            throw FlutterHullFailure.invalidRestorationState
          }
          index += 1
        }
        let value = raw as String
        try string(value)
        return value
      }
      if let value = node as? NSNumber {
        if CFGetTypeID(value) == CFBooleanGetTypeID() {
          try consume(value.boolValue ? 4 : 5)
        } else {
          let integer = ["c", "C", "s", "S", "i", "I", "l", "L", "q", "Q"].contains(
            String(cString: value.objCType))
          guard value.doubleValue.isFinite,
            !integer || abs(value.doubleValue) <= 9_007_199_254_740_991
          else { throw FlutterHullFailure.invalidRestorationState }
          try consume(32)
        }
        return value
      }
      if let map = node as? NSDictionary {
        let identity = ObjectIdentifier(map)
        guard parents.insert(identity).inserted else {
          throw FlutterHullFailure.invalidRestorationState
        }
        defer { parents.remove(identity) }
        try consume(2 + max(0, map.count - 1))
        var result: [String: Any] = [:]
        for raw in map.allKeys {
          guard raw is NSString, let key = try copy(raw, depth) as? String,
            let value = map.object(forKey: raw)
          else {
            throw FlutterHullFailure.invalidRestorationState
          }
          try consume(1)
          result[key] = try copy(value, depth + 1)
        }
        return result
      }
      if let list = node as? NSArray {
        let identity = ObjectIdentifier(list)
        guard parents.insert(identity).inserted else {
          throw FlutterHullFailure.invalidRestorationState
        }
        defer { parents.remove(identity) }
        try consume(2 + max(0, list.count - 1))
        var result: [Any] = []
        for value in list { result.append(try copy(value, depth + 1)) }
        return result
      }
      throw FlutterHullFailure.invalidRestorationState
    }
    guard let result = try copy(value, 0) as? [String: Any] else {
      throw FlutterHullFailure.invalidRestorationState
    }
    return result
  }
}
