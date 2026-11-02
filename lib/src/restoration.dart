part of 'runtime.dart';

/// 可持久化的业务页面数据；不包含 callback、订阅和原生上下文。
final class FlutterHullRouteState {
  final String route;
  final Map<String, Object?> arguments;
  final Map<String, Object?> state;
  final Map<String, Object?>? module;
  FlutterHullRouteState._(
    this.route,
    this.arguments,
    this.state, [
    this.module,
  ]);

  /// 业务 schema 迁移仅携带可复制的数据；完整栈仍会再次校验。
  factory FlutterHullRouteState({
    required String route,
    Map<String, Object?> arguments = const {},
    Map<String, Object?> state = const {},
  }) {
    if (route.isEmpty || utf8.encode(route).length > 512) {
      throw const FormatException('恢复路由名超出限制');
    }
    return FlutterHullRouteState._(
      route,
      _restorationObject(arguments),
      _restorationObject(state),
    );
  }
}

final class FlutterHullRestorationSnapshot {
  final List<FlutterHullRouteState> routes;
  final String? userDomain;
  final String _encoded;
  FlutterHullRestorationSnapshot._(this.routes, this._encoded, this.userDomain);

  factory FlutterHullRestorationSnapshot.fromMap(Object? value) {
    if (value is! Map || value['version'] != 1 || value['version'] is! int) {
      throw const FormatException('无效的恢复快照版本');
    }
    final userDomain = value['userDomain'];
    if (userDomain != null &&
        (userDomain is! String ||
            userDomain.isEmpty ||
            userDomain.length > 256))
      throw const FormatException('恢复用户域无效');
    final raw = value['routes'];
    if (raw is! List || raw.isEmpty || raw.length > 32) {
      throw const FormatException('恢复路由数量必须为1至32');
    }
    final routes = <FlutterHullRouteState>[];
    for (final item in raw) {
      if (item is! Map ||
          item['route'] is! String ||
          item['arguments'] is! Map ||
          item['state'] is! Map) {
        throw const FormatException('无效的恢复路由');
      }
      final route = item['route'] as String;
      if (route.isEmpty || utf8.encode(route).length > 512) {
        throw const FormatException('恢复路由名超出限制');
      }
      routes.add(
        FlutterHullRouteState._(
          route,
          _restorationObject(item['arguments']),
          _restorationObject(item['state']),
          item['module'] == null ? null : _restorationObject(item['module']),
        ),
      );
    }
    final normalized = _restorationObject({
      'version': 1,
      if (userDomain != null) 'userDomain': userDomain,
      'routes': [
        for (final route in routes)
          {
            'route': route.route,
            'arguments': route.arguments,
            'state': route.state,
            if (route.module != null) 'module': route.module,
          },
      ],
    });
    final encoded = jsonEncode(normalized);
    return FlutterHullRestorationSnapshot._(
      List.unmodifiable(routes),
      encoded,
      userDomain as String?,
    );
  }

  /// 返回副本，业务修改导出值不会污染当前快照。
  Map<String, Object?> toMap() =>
      Map<String, Object?>.from(jsonDecode(_encoded) as Map);
}

/// 三端共用的保守 JSON 预算：数字32字节，控制字符6字节。
Map<String, Object?> _restorationObject(Object? value) {
  var remaining = 65536;
  final parents = Set<Object>.identity();
  void consume(int count) {
    remaining -= count;
    if (remaining < 0) throw const FormatException('JSON数据不能超过64KiB');
  }

  void string(String text) {
    for (var index = 0; index < text.length; index++) {
      final unit = text.codeUnitAt(index);
      if (unit >= 0xd800 && unit <= 0xdbff) {
        if (++index >= text.length ||
            text.codeUnitAt(index) < 0xdc00 ||
            text.codeUnitAt(index) > 0xdfff) {
          throw const FormatException('JSON字符串包含无效Unicode');
        }
      } else if (unit >= 0xdc00 && unit <= 0xdfff) {
        throw const FormatException('JSON字符串包含无效Unicode');
      }
    }
    consume(2);
    for (final rune in text.runes) {
      if (rune >= 0xd800 && rune <= 0xdfff) {
        throw const FormatException('JSON字符串包含无效Unicode');
      }
      consume(
        rune < 32
            ? 6
            : rune == 34 || rune == 92
            ? 2
            : rune < 128
            ? 1
            : rune < 2048
            ? 2
            : rune < 65536
            ? 3
            : 4,
      );
    }
  }

  Object? copy(Object? node, int depth) {
    if (depth > 16) throw const FormatException('JSON数据嵌套过深');
    if (node == null) {
      consume(4);
      return null;
    }
    if (node is String) {
      string(node);
      return node;
    }
    if (node is bool) {
      consume(node ? 4 : 5);
      return node;
    }
    if (node is num) {
      if (!node.isFinite ||
          (node is int &&
              (node < -9007199254740991 || node > 9007199254740991))) {
        throw const FormatException('JSON数字超出跨端范围');
      }
      consume(32);
      return node;
    }
    if (node is! Map && node is! List) throw const FormatException('数据必须为JSON');
    if (!parents.add(node)) throw const FormatException('JSON数据包含循环引用');
    try {
      consume(2);
      if (node is List) {
        consume(node.isEmpty ? 0 : node.length - 1);
        return List<Object?>.unmodifiable(node.map((v) => copy(v, depth + 1)));
      }
      final map = node as Map;
      consume(map.isEmpty ? 0 : map.length - 1);
      final output = <String, Object?>{};
      for (final entry in map.entries) {
        final key = entry.key;
        if (key is! String) throw const FormatException('JSON字段名必须是字符串');
        string(key);
        consume(1);
        output[key] = copy(entry.value, depth + 1);
      }
      return Map<String, Object?>.unmodifiable(output);
    } finally {
      parents.remove(node);
    }
  }

  if (value is! Map) throw const FormatException('JSON数据必须是对象');
  return copy(value, 0) as Map<String, Object?>;
}
