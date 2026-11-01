part of 'runtime.dart';

typedef FlutterHullRouteFactory = PageRoute<Map<String, Object?>?> Function(
  RouteSettings settings,
  WidgetBuilder builder,
  String title,
);
typedef FlutterHullPageStateBuilder = Widget Function(
  BuildContext context,
  FlutterHullPageController page,
);

class FlutterHullRoute {
  final String title;
  final Duration? loadTimeout;
  final Duration cleanupWaitTimeout;
  final FlutterHullRouteFactory? routeFactory;
  final FlutterHullPageStateBuilder? loadingBuilder,
      errorBuilder,
      waitingCleanupBuilder;
  final FlutterHullRouteState Function(FlutterHullRouteState)? restore;
  final Future<Object?> Function(FlutterHullPageScope)? loader;
  final Widget Function(BuildContext, FlutterHullPageController, Object?)
  builder;
  const FlutterHullRoute({
    this.title = '',
    this.loadTimeout = const Duration(seconds: 30),
    this.cleanupWaitTimeout = const Duration(seconds: 5),
    this.routeFactory,
    this.loadingBuilder,
    this.errorBuilder,
    this.waitingCleanupBuilder,
    this.loader,
    this.restore,
    required this.builder,
  });
}

class _HullRouteRecord {
  final FlutterHullRoute definition;
  final FlutterHullPageController page;
  late final PageRoute<Map<String, Object?>?> route;
  final Object admission;
  bool returning = false;
  Map<String, Object?> restorationState = const {};
  _HullRouteRecord(this.definition, this.page, this.admission);
}

/// 使用 Flutter 标准路由；不为内部业务页创建第二个 Native 容器或 Client。
class FlutterHullNavigator {
  final FlutterHullRuntime runtime;
  final void Function(Object, StackTrace)? onAutoSaveError;
  final Map<String, FlutterHullRoute> routes;
  final key = GlobalKey<NavigatorState>();
  late final NavigatorObserver observer = _HullNavigatorObserver(this);
  final _records = <Route<dynamic>, _HullRouteRecord>{};
  final _stack = <Route<dynamic>>[];
  // 预留先于自定义工厂执行，防止同步重入绕过容量。
  final _admissions = <Object, Map<String, Object?>>{};
  int _constructionDepth = 0;
  bool _disposed = false;
  bool _saveScheduled = false;
  bool _returning = false;
  bool _popAttempt = false, _backResolving = false;
  FlutterHullNavigator({
    required this.runtime,
    this.onAutoSaveError,
    required Map<String, FlutterHullRoute> routes,
  }) : routes = Map.unmodifiable(routes) {
    if (runtime._navigation != null) throw StateError('此 Runtime 已有导航实例');
    runtime._ensureOpen();
    runtime._navigation = this;
  }
  Route<dynamic>? onGenerateRoute(RouteSettings settings) {
    // 标准pushNamed也必须等待当前工厂事务结束，避免提前安装子路由。
    if (_constructionDepth > 0) {
      throw const BridgeError('NAVIGATION_REENTRANT', '路由构造期间不能生成其他受管路由');
    }
    if (_disposed || runtime._closed)
      throw const BridgeError('CLOSED', '导航已关闭');
    final name = settings.name;
    if (name == null || name.isEmpty || utf8.encode(name).length > 512)
      return null;
    final definition = routes[name];
    if (definition == null) return null;
    final copiedSettings = RouteSettings(
      name: name,
      arguments: settings.arguments == null
          ? null
          : _restorationObject(settings.arguments),
    );
    final before = _admissions.keys.toSet();
    final token = Object();
    final entry = <String, Object?>{
      'route': name,
      'arguments': copiedSettings.arguments ?? <String, Object?>{},
      'state': <String, Object?>{},
    };
    FlutterHullRestorationSnapshot.fromMap({
      'version': 1,
      'routes': [..._admissionEntries(), entry],
    });
    _admissions[token] = entry;
    _constructionDepth++;
    PageRoute<Map<String, Object?>?>? candidate;
    var alreadyManaged = false;
    try {
      final page = FlutterHullPageController(
        runtime: runtime,
        loader: definition.loader ?? (_) async => null,
        loadTimeout: definition.loadTimeout,
        cleanupWaitTimeout: definition.cleanupWaitTimeout,
      );
      final record = _HullRouteRecord(definition, page, token);
      page._route = record;
      final factory = definition.routeFactory;
      candidate = factory == null
          ? CupertinoPageRoute<Map<String, Object?>?>(
              settings: copiedSettings,
              title: definition.title,
              builder: (_) => _FlutterHullPage(record),
            )
          : factory(
              copiedSettings,
              (_) => _FlutterHullPage(record),
              definition.title,
            );
      record.route = candidate;
      alreadyManaged = _records.containsKey(candidate);
      if (alreadyManaged) throw StateError('自定义工厂必须返回新的Route');
      if (_disposed || runtime._closed)
        throw const BridgeError('CLOSED', '导航已关闭');
      if (record.route.settings.name != copiedSettings.name ||
          record.route.settings.arguments != copiedSettings.arguments) {
        throw const FormatException('自定义路由必须保留传入的RouteSettings');
      }
      _records[record.route] = record;
      return record.route;
    } catch (_) {
      // 创建失败的路由尚未交给Navigator，释放本轮分配且不触碰旧路由。
      if (candidate != null &&
          !alreadyManaged &&
          !_records.containsKey(candidate)) {
        candidate.dispose();
      }
      _rollbackAdmissions(before);
      rethrow;
    } finally {
      _constructionDepth--;
    }
  }

  Iterable<Map<String, Object?>> _admissionEntries({
    Map<_HullRouteRecord, Map<String, Object?>> overrides = const {},
  }) sync* {
    for (final entry in _admissions.entries) {
      final record = _records.values
          .where((value) => identical(value.admission, entry.key))
          .firstOrNull;
      yield {
        ...entry.value,
        if (record != null)
          'state': overrides[record] ?? record.restorationState,
      };
    }
  }

  void _rollbackAdmissions(Set<Object> before) {
    final removed = _records.values
        .where((record) => !before.contains(record.admission))
        .toList();
    // 先原子移除本轮登记，再通知可能同步重入的生命周期观察者。
    for (final record in removed) {
      _records.remove(record.route);
      _stack.remove(record.route);
    }
    _admissions.removeWhere((key, _) => !before.contains(key));
    for (final record in removed) {
      unawaited(record.page.close().catchError((Object _) {}));
      record.route.dispose();
    }
  }

  /// 接到 MaterialApp/CupertinoApp，恢复完整的受管页面栈。
  List<Route<dynamic>> initialRoutes(String initialRoute) {
    final before = _admissions.keys.toSet();
    final restored = runtime.restoration;
    if (restored != null) {
      try {
        // 先迁移并校验整栈，成功后才创建页面，避免半栈和旧资源泄漏。
        final migrated = FlutterHullRestorationSnapshot.fromMap({
          'version': 1,
          'routes': [for (final value in restored.routes) _migrateRoute(value)],
        });
        final restoredRoutes = [
          for (final value in migrated.routes) _restoreRoute(value),
        ];
        runtime._diagnose('restoration.accepted');
        return restoredRoutes;
      } catch (_) {
        _rollbackAdmissions(before);
        runtime._diagnose(
          'restoration.rejected',
          errorCode: 'RESTORATION_INCOMPATIBLE',
        );
        // 业务不兼容与数据超限统一回到初始路由。
      }
    }
    final route = onGenerateRoute(
      RouteSettings(name: initialRoute, arguments: runtime.arguments),
    );
    if (route == null) throw const BridgeError('ROUTE_NOT_FOUND', '初始路由未注册');
    return [route];
  }

  Map<String, Object?> _migrateRoute(FlutterHullRouteState value) {
    final definition = routes[value.route];
    if (definition == null) throw const FormatException('恢复路由未注册');
    final migrated = definition.restore?.call(value) ?? value;
    if (migrated.route != value.route) throw const FormatException('迁移不能替换路由');
    return {
      'route': migrated.route,
      'arguments': migrated.arguments,
      'state': migrated.state,
    };
  }

  Route<dynamic> _restoreRoute(FlutterHullRouteState value) {
    final route = onGenerateRoute(
      RouteSettings(name: value.route, arguments: value.arguments),
    );
    final record = _records[route];
    if (route == null || record == null) throw StateError('恢复路由创建失败');
    record.restorationState = value.state;
    return route;
  }

  FlutterHullRestorationSnapshot _snapshot({
    Map<_HullRouteRecord, Map<String, Object?>> overrides = const {},
  }) {
    // 保存业务状态同样遵守未入栈预留的容量，拒绝时不污染原状态。
    if (_admissions.isNotEmpty) {
      FlutterHullRestorationSnapshot.fromMap({
        'version': 1,
        'routes': _admissionEntries(overrides: overrides).toList(),
      });
    }
    return FlutterHullRestorationSnapshot.fromMap({
      'version': 1,
      'routes': [
        for (final route in _stack)
          if (_records[route] case final record?)
            if (!record.returning)
              {
                'route': record.route.settings.name,
                'arguments':
                    record.route.settings.arguments ?? <String, Object?>{},
                'state': overrides[record] ?? record.restorationState,
              },
      ],
    });
  }

  Future<void> saveState() {
    if (_disposed || runtime._closed)
      return Future.error(const BridgeError('CLOSED', '导航已关闭'));
    return runtime._saveRestoration(_snapshot());
  }

  FlutterHullRestorationSnapshot get restorationSnapshot => _snapshot();

  void _scheduleSave() {
    if (_saveScheduled ||
        _disposed ||
        runtime._closed ||
        !runtime._supportsRestoration)
      return;
    _saveScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _saveScheduled = false;
      if (_disposed || runtime._closed || _records.isEmpty) return;
      unawaited(
        Future<void>.sync(saveState)
            .catchError((Object error, StackTrace stack) {
              runtime._diagnose(
                'saveFailed',
                errorCode: error is BridgeError ? error.code : 'SAVE_FAILED',
              );
              try {
                onAutoSaveError?.call(error, stack);
              } catch (_) {
                /* 观察失败隔离。 */
              }
            }),
      );
    });
  }

  Future<Map<String, Object?>?> push(
    String name, {
    Map<String, Object?> arguments = const {},
  }) async {
    // 工厂必须先完成创建事务；同步重入不能提前把子路由交给Navigator。
    if (_constructionDepth > 0) {
      throw const BridgeError('NAVIGATION_REENTRANT', '路由构造期间不能入栈；请在工厂返回后发起导航');
    }
    if (_disposed || runtime._closed)
      throw const BridgeError('CLOSED', '导航已关闭');
    if (!routes.containsKey(name))
      throw const BridgeError('ROUTE_NOT_FOUND', '未注册 Flutter 路由');
    final state = key.currentState;
    if (state == null) throw StateError('Navigator 尚未挂载');
    final route = onGenerateRoute(
      RouteSettings(name: name, arguments: _restorationObject(arguments)),
    );
    if (route is! PageRoute<Map<String, Object?>?>) throw StateError('路由创建失败');
    try {
      state.push(route);
    } catch (_) {
      _removed(route);
      route.dispose();
      rethrow;
    }
    return route.completed;
  }

  bool _pop(_HullRouteRecord? record, Map<String, Object?>? result) {
    if (_disposed ||
        record == null ||
        record.returning ||
        _returning ||
        _popAttempt ||
        _backResolving ||
        !record.route.isCurrent)
      return false;
    if (record.route.popDisposition == RoutePopDisposition.doNotPop)
      return false;
    if (record.route.willHandlePopInternally) {
      _popAttempt = true;
      try {
        key.currentState?.pop(
          result == null ? null : _restorationObject(result),
        );
        return true;
      } finally {
        _popAttempt = false;
      }
    }
    if (record.route.isFirst) {
      if (!runtime._canFinishContainer) return false;
      record.returning = true;
      runtime
          .finish(result)
          .then(
            (accepted) {
              if (!accepted && !runtime._closed) record.returning = false;
            },
            onError: (Object error) {
              if (!runtime._closed) {
                record.returning = false;
                debugPrint('容器结束失败：$error');
              }
            },
          );
      return true;
    }
    _popAttempt = true;
    try {
      key.currentState?.pop(result == null ? null : _restorationObject(result));
      return true;
    } finally {
      _popAttempt = false;
    }
  }

  Future<bool> maybePop() async {
    if (_disposed) return false;
    if (_returning ||
        _popAttempt ||
        _backResolving ||
        key.currentState?.userGestureInProgress == true)
      return true;
    _backResolving = true;
    try {
      return await key.currentState?.maybePop() ?? false;
    } finally {
      _backResolving = false;
    }
  }

  void _committedPop(Route<dynamic> route) {
    _returning = true;
    if (route is TransitionRoute<dynamic>) {
      route.completed.whenComplete(() => _returning = false);
    } else {
      _returning = false;
    }
    _removed(route);
  }

  void _visibility(Route<dynamic>? top) {
    for (final entry in _records.entries) {
      entry.value.page.setVisible(entry.key == top);
    }
  }

  void _removed(Route<dynamic> route) {
    _stack.remove(route);
    final record = _records.remove(route);
    if (record != null) {
      _admissions.remove(record.admission);
      record.returning = true;
      unawaited(
        record.page.close().catchError((Object error) {
          debugPrint('导航清理未完成：$error');
        }),
      );
    }
    _scheduleSave();
  }

  void _pushed(Route<dynamic> route) {
    _stack.remove(route);
    _stack.add(route);
    _scheduleSave();
  }

  void _replaced(Route<dynamic>? oldRoute, Route<dynamic>? newRoute) {
    final position = oldRoute == null ? -1 : _stack.indexOf(oldRoute);
    if (oldRoute != null) _removed(oldRoute);
    if (newRoute != null) {
      _stack.remove(newRoute);
      _stack.insert(
        position < 0 ? _stack.length : min(position, _stack.length),
        newRoute,
      );
    }
    _scheduleSave();
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (final route in _records.keys.toList()) {
      _removed(route);
    }
    _admissions.clear();
    if (identical(runtime._navigation, this)) runtime._navigation = null;
  }
}

class _HullNavigatorObserver extends NavigatorObserver {
  final FlutterHullNavigator owner;
  _HullNavigatorObserver(this.owner);
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      owner._pushed(route);
  @override
  void didChangeTop(
    Route<dynamic> topRoute,
    Route<dynamic>? previousTopRoute,
  ) => owner._visibility(topRoute);
  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    owner._committedPop(route);
    owner._visibility(previousRoute);
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      owner._removed(route);
  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    owner._replaced(oldRoute, newRoute);
  }
}
