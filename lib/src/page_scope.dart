part of 'runtime.dart';

enum FlutterHullPageLifecycle { created, visible, hidden, background, closed }

/// 一个 Flutter 路由的资源作用域，只清理自己的句柄，不关闭共享 Client。
final class FlutterHullPageScope {
  final _lifecycle = ValueNotifier(FlutterHullPageLifecycle.created);
  ValueListenable<FlutterHullPageLifecycle> get lifecycle => _lifecycle;
  final FlutterHullRuntime _runtime;
  final String pageId;
  String get routeName => _route?.route.settings.name ?? _runtime.initialRoute;
  Map<String, Object?> get arguments {
    final value = _route?.route.settings.arguments;
    return value is Map
        ? Map<String, Object?>.unmodifiable(Map<String, Object?>.from(value))
        : _runtime.arguments;
  }

  final _closedSignal = Completer<void>();
  final _nativeNavigations = <String>{};
  bool _routeVisible = false;
  _HullRouteRecord? _route;
  Map<String, Object?> get restorationState =>
      _route?.restorationState ?? const {};

  Future<void> saveRestorationState(Map<String, Object?> value) async {
    if (_closed) throw const BridgeError('CLOSED', '页面已关闭');
    final route = _route;
    final navigation = _runtime._navigation;
    if (route == null || navigation == null) throw StateError('只有托管页面可以保存恢复状态');
    final copied = _restorationObject(value);
    // 先校验整份快照，再更新业务状态，失败时不留下超额的内存状态。
    navigation._snapshot(overrides: {route: copied});
    route.restorationState = copied;
    await navigation.saveState();
  }

  void setVisible(bool visible) {
    _routeVisible = visible;
    _updateLifecycle();
  }

  void _updateLifecycle() {
    _lifecycle.value = _closed
        ? FlutterHullPageLifecycle.closed
        : (!_runtime._hostForeground || !_runtime._appForeground)
        ? FlutterHullPageLifecycle.background
        : (_routeVisible && _runtime._hostVisible)
        ? FlutterHullPageLifecycle.visible
        : FlutterHullPageLifecycle.hidden;
    _runtime._diagnose('pageLifecycle', pageId: pageId);
  }

  Future<T> _whileOpen<T>(Future<T> operation) {
    if (_closed) return Future.error(const BridgeError('CLOSED', '页面已关闭'));
    return Future.any([
      operation,
      _closedSignal.future.then<T>(
        (_) => throw const BridgeError('CLOSED', '调用页面已退出'),
      ),
    ]);
  }

  Future<Map<String, Object?>?> push(
    String route, {
    Map<String, Object?> arguments = const {},
  }) {
    final navigator = _runtime._navigation;
    if (_closed || navigator == null)
      return Future.error(const BridgeError('CLOSED', '导航不可用'));
    // 子页面归 Navigator 所有；调用者退出仅结束它的结果监听，不误关其他页面。
    return _whileOpen(navigator.push(route, arguments: arguments));
  }

  bool pop([Map<String, Object?>? result]) =>
      !_closed && (_runtime._navigation?._pop(_route, result) ?? false);
  Future<Map<String, Object?>?> openNative(
    String route, {
    Map<String, Object?> arguments = const {},
    Duration? timeout,
  }) async {
    if (_closed) throw const BridgeError('CLOSED', '页面已关闭');
    if (timeout != null && timeout <= Duration.zero)
      throw ArgumentError.value(timeout);
    if (route.isEmpty ||
        utf8.encode(route).length > 512 ||
        utf8.encode(pageId).length > 256) {
      throw const FormatException('导航标识超出限制');
    }
    final copied = _restorationObject(arguments);
    if (_nativeNavigations.length >= 32)
      throw const BridgeError('BACKPRESSURE', '导航配额已满');
    final id = '$pageId:n${++_runtime._pageSerial}';
    if (utf8.encode(id).length > 256) throw const FormatException('导航标识超出限制');
    _nativeNavigations.add(id);
    final raw = _runtime._control
        .invokeMapMethod<String, Object?>('openNative', {
          'navigationId': id,
          'pageId': pageId,
          'route': route,
          'arguments': copied,
        })
        .then((value) => value == null ? null : _restorationObject(value))
        .whenComplete(() => _nativeNavigations.remove(id));
    if (timeout == null) return _whileOpen(raw);
    return _whileOpen(raw).timeout(
      timeout,
      onTimeout: () async {
        try {
          await _cancelNative(id).timeout(const Duration(seconds: 2));
        } catch (_) {
          /* 整体关闭仍负责兜底。 */
        }
        throw const BridgeError('NAVIGATION_TIMEOUT', '原生页面返回超时');
      },
    );
  }

  Future<void> _cancelNative(String id) async {
    await _controls.run(
      () => _runtime._control.invokeMethod<void>('cancelNavigation', {
        'navigationId': id,
      }),
    );
    _nativeNavigations.remove(id);
  }

  final BridgeClient _bridge;
  final _ControlQueue _controls;
  final void Function() _onDisposed;
  final _calls = <_OwnedCall>{};
  final _subscriptions = <BridgeSubscription>{};
  final _pendingSubscriptions = <Future<BridgeSubscription>>{};
  int _inFlightSubscriptions = 0;
  bool _closed = false;
  Future<void>? _bridgeDisposal;
  Future<void>? _disposal;
  final cancellation = FlutterHullCancellationSignal._();
  final _businessResources = <String, _CleanupResource>{};
  final _drained = Completer<void>();
  int _resourceSerial = 0;
  bool _bridgeReleased = false;
  Future<void> get whenDrained => _drained.future;

  List<Map<String, Object?>> get cleanupResources => List.unmodifiable([
    for (final resource in _businessResources.values) resource.snapshot,
  ]);

  Map<String, Object?> get cleanupStats =>
      _cleanupStats(_businessResources.values, _runtime.cleanupLimitPerPage);
  Map<String, Object?> queryCleanupResources({
    int offset = 0,
    int limit = 64,
  }) => _cleanupPage(
    _businessResources.values,
    _runtime.cleanupLimitPerPage,
    offset,
    limit,
  );

  FlutterHullCleanupTicket registerCleanup(
    String name,
    FutureOr<void> Function() cleanup, {
    bool retryable = false,
  }) {
    if (_closed) throw StateError('页面已关闭');
    if (name.isEmpty || utf8.encode(name).length > 256)
      throw ArgumentError.value(name);
    if (_businessResources.length >= _runtime.cleanupLimitPerPage ||
        _runtime._resources.length >= _runtime.cleanupLimitPerRuntime) {
      throw const BridgeError('BACKPRESSURE', '业务清理配额已满；请等待真实任务完成');
    }
    final id = '$pageId:r${++_resourceSerial}';
    final resource = _CleanupResource(this, id, name, cleanup, retryable);
    _businessResources[id] = resource;
    return FlutterHullCleanupTicket._(resource);
  }

  bool retryCleanup(String resourceId) {
    final resource = _businessResources[resourceId];
    if (resource == null || resource.state != 'failed' || !resource.retryable)
      return false;
    resource.run();
    return true;
  }

  void _seal() {
    if (!_closed) {
      _closed = true;
      if (!_closedSignal.isCompleted) _closedSignal.complete();
      cancellation._cancel();
      _updateLifecycle();
    }
    for (final resource in _businessResources.values.toList()) {
      if (resource.state == 'registered') resource.run();
    }
  }

  Future<void> _waitBusinessCleanup() async {
    while (_businessResources.isNotEmpty) {
      await Future.wait(
        _businessResources.values.toList().map((resource) => resource.settled),
      );
      if (_businessResources.values.any(
        (resource) => resource.state == 'failed',
      )) {
        throw const BridgeError('CLEANUP_FAILED', '页面业务资源清理失败');
      }
    }
  }

  void _checkDrained() {
    if (!_closed ||
        !_bridgeReleased ||
        _businessResources.isNotEmpty ||
        _drained.isCompleted)
      return;
    _drained.complete();
    _onDisposed();
  }

  Future<void> dispose() {
    final existing = _disposal;
    if (existing != null) return existing;
    final done = Completer<void>();
    // 生命周期观察者可能同步重入，先发布同一逻辑关闭 Future。
    _disposal = done.future;
    _seal();
    Future.wait([_disposeBridge(), _waitBusinessCleanup()]).then(
      (_) {
        done.complete();
      },
      onError: (Object error, StackTrace stack) {
        _disposal = null;
        done.completeError(error, stack);
      },
    );
    return done.future;
  }

  FlutterHullPageScope._(
    this._bridge,
    this._controls, {
    required FlutterHullRuntime runtime,
    required this.pageId,
    required void Function() onDisposed,
  }) : _runtime = runtime,
       _onDisposed = onDisposed;

  BridgeHandle call(
    String method,
    Map<String, Object?> params,
    CallCallbacks callbacks, {
    String? extra,
    Duration? timeout,
  }) {
    if (_closed) throw StateError('页面已关闭');
    final record = _OwnedCall();
    _calls.add(record);
    final raw = _bridge.call(
      method,
      params,
      CallCallbacks(
        onData: (value) {
          if (!_closed) callbacks.onData?.call(value);
        },
        onComplete: (value) {
          if (!_closed) {
            _calls.remove(record);
            callbacks.onComplete(value);
          }
        },
        onError: (error) {
          if (!_closed) {
            _calls.remove(record);
            callbacks.onError(error);
          }
        },
      ),
      extra: extra,
      timeout: timeout,
    );
    record.handle = raw;
    return BridgeHandle(raw.callbackId, () => _controls.run(raw.cancel));
  }

  Future<BridgeSubscription> subscribe(
    String topic,
    void Function(Map<String, Object?>) onData, {
    void Function(BridgeError)? onError,
  }) {
    if (_closed) return Future.error(StateError('页面已关闭'));
    late final Future<BridgeSubscription> pending;
    pending = _runtime._subscriptions
        .run(() {
          if (_closed) throw const BridgeError('CLOSED', '页面已关闭');
          _inFlightSubscriptions++;
          return _bridge
              .subscribe(
                topic,
                (value) {
                  if (!_closed) onData(value);
                },
                onError: (error) {
                  if (!_closed) onError?.call(error);
                },
              )
              .then((raw) {
                late final BridgeSubscription tracked;
                tracked = BridgeSubscription(raw.subscriptionId, () async {
                  final accepted = await _controls.run(raw.unsubscribe);
                  _subscriptions.remove(tracked);
                  return accepted;
                });
                _subscriptions.add(tracked);
                if (_closed) {
                  // 新到达的真实句柄获得自己的有限重试预算。
                  _runtime._cleanupAttempts.remove(this);
                  _runtime._retryCleanup(this);
                }
                return tracked;
              })
              .whenComplete(() => _inFlightSubscriptions--);
        })
        .whenComplete(() => _pendingSubscriptions.remove(pending));
    _pendingSubscriptions.add(pending);
    return pending;
  }

  Future<void> _disposeBridge() {
    final existing = _bridgeDisposal;
    if (existing != null) return existing;
    final done = Completer<void>();
    _bridgeDisposal = done.future;
    _seal();
    () async {
      Object? failure;
      for (final id in _nativeNavigations.toList()) {
        try {
          await _cancelNative(id);
        } catch (error) {
          failure ??= error;
        }
      }
      // 先等已准入订阅；独立清理通道不被其他页面的订阅占用。
      for (final pending in _pendingSubscriptions.toList()) {
        try {
          await pending;
        } catch (error) {
          failure ??= error;
        }
      }
      for (final record in _calls.toList()) {
        try {
          final raw = record.handle;
          if (raw != null) await _controls.run(raw.cancel);
          _calls.remove(record);
        } catch (error) {
          failure ??= error;
        }
      }
      for (final subscription in _subscriptions.toList()) {
        try {
          await subscription.unsubscribe();
        } catch (error) {
          failure ??= error;
        }
      }
      if (_inFlightSubscriptions > 0) {
        failure ??= const BridgeError('CLEANUP_PENDING', '订阅创建仍待平台确认');
      }
      if (failure == null) {
        _bridgeReleased = true;
        _checkDrained();
        done.complete();
      } else {
        // 未确认的句柄仍归本页负责，允许宿主重试；Runtime 最终关闭会断开整条连接。
        _bridgeDisposal = null;
        _runtime._retryCleanup(this);
        done.completeError(failure);
      }
    }();
    return done.future;
  }

  void _releaseAfterConnectionClosed() {
    _seal();
    _nativeNavigations.clear();
    _calls.clear();
    _subscriptions.clear();
    _bridgeReleased = true;
    _checkDrained();
  }
}

final class _OwnedCall {
  BridgeHandle? handle;
}

/// 每条控制通道有界且限时；订阅和清理各自保留一个执行位置。
final class _ControlQueue {
  Future<void> _tail = Future<void>.value();
  int _pending = 0;
  Future<T> run<T>(Future<T> Function() operation) {
    if (_pending >= 256)
      return Future.error(const BridgeError('BACKPRESSURE', '容器控制队列已满'));
    _pending++;
    var expired = false;
    // 逻辑等待可以超时，但真实 RPC 结束前仍占用执行位置与容量。
    final raw = _tail
        .then((_) {
          if (expired) throw TimeoutException('控制请求排队超时');
          return operation();
        })
        .whenComplete(() => _pending--);
    _tail = raw.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return raw.timeout(
      const Duration(seconds: 2),
      onTimeout: () {
        expired = true;
        throw TimeoutException('控制请求确认超时');
      },
    );
  }
}
