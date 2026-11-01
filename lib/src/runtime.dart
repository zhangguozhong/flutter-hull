import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:aeris_flutter/aeris_flutter.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

part 'page_scope.dart';
part 'navigation.dart';
part 'page.dart';
part 'restoration.dart';
part 'diagnostics.dart';
part 'cleanup.dart';

/// 每个 Messenger 唯一的容器环境。业务路由共享此环境，不自行创建 Client。
final class FlutterHullRuntime with WidgetsBindingObserver {
  static final _owners = Expando<FlutterHullRuntime>();
  final FlutterHullDiagnostics diagnostics;
  final int cleanupLimitPerPage, cleanupLimitPerRuntime;
  final BinaryMessenger _messenger;
  final MethodChannel _control;
  final _pages = <FlutterHullPageScope>{};
  final _controls = _ControlQueue();
  final _subscriptions = _ControlQueue();
  final _cleanupRetries = <FlutterHullPageScope, Timer>{};
  final _cleanupAttempts = <FlutterHullPageScope, int>{};
  _SnapshotWrite? _snapshotActive, _snapshotPending;
  bool _firstFrameReported = false;
  final _closedSignal = Completer<void>();
  BridgeClient? _bridge;
  bool _closed = false;
  bool _hostVisible = true, _hostForeground = true, _appForeground = true;
  Map<Object?, Object?>? _pendingLifecycle;
  FlutterHullNavigator? _navigation;
  int _pageSerial = 0;
  int _hostRevision = -1;
  bool _canFinishContainer = false;
  bool _supportsRestoration = false;
  int _restorationRevision = 0;
  FlutterHullRestorationSnapshot? _restoration;
  FlutterHullRestorationSnapshot? get restoration => _restoration;
  Future<void>? _disposal;
  final _drained = Completer<void>();
  bool _connectionClosed = false;
  Future<void> get whenDrained => _drained.future;

  List<Map<String, Object?>> get cleanupResources =>
      List.unmodifiable([for (final page in _pages) ...page.cleanupResources]);

  Iterable<_CleanupResource> get _resources =>
      _pages.expand((page) => page._businessResources.values);
  Map<String, Object?> get cleanupStats =>
      _cleanupStats(_resources, cleanupLimitPerRuntime);
  Map<String, Object?> queryCleanupResources({
    int offset = 0,
    int limit = 64,
  }) => _cleanupPage(_resources, cleanupLimitPerRuntime, offset, limit);

  bool retryCleanup(String resourceId) {
    for (final page in _pages.toList()) {
      if (page.retryCleanup(resourceId)) return true;
    }
    return false;
  }

  void _checkDrained() {
    if (!_closed ||
        !_connectionClosed ||
        _pages.isNotEmpty ||
        _drained.isCompleted)
      return;
    _diagnose('drained');
    _drained.complete();
    if (identical(_owners[_messenger], this)) {
      _control.setMethodCallHandler(null);
      _owners[_messenger] = null;
    }
  }

  String containerId = '';
  String initialRoute = '/';
  Map<String, Object?> arguments = const {};

  FlutterHullRuntime._(
    this._messenger,
    this.diagnostics,
    this.cleanupLimitPerPage,
    this.cleanupLimitPerRuntime,
  ) : _control = MethodChannel(
        'leo_flutter/control',
        const StandardMethodCodec(),
        _messenger,
      );

  static Future<FlutterHullRuntime> connect({
    FlutterHullDiagnostics? diagnostics,
    BridgeAdapter? adapter,
    BinaryMessenger? messenger,
    Duration startupTimeout = const Duration(seconds: 8),
    int cleanupLimitPerPage = 128,
    int cleanupLimitPerRuntime = 512,
  }) async {
    if (cleanupLimitPerPage <= 0 || cleanupLimitPerRuntime <= 0)
      throw ArgumentError('清理配额必须为正整数');
    if (startupTimeout <= Duration.zero)
      throw ArgumentError.value(startupTimeout);
    final target = messenger ?? ServicesBinding.instance.defaultBinaryMessenger;
    if (_owners[target] != null) {
      throw const BridgeError('DUPLICATE_INIT', '此 Engine 已存在容器环境');
    }
    final runtime = FlutterHullRuntime._(
      target,
      diagnostics ?? FlutterHullDiagnostics(),
      cleanupLimitPerPage,
      cleanupLimitPerRuntime,
    );
    _owners[target] = runtime;
    final initialState = WidgetsBinding.instance.lifecycleState;
    runtime._appForeground =
        initialState == null ||
        initialState == AppLifecycleState.resumed ||
        initialState == AppLifecycleState.inactive;
    WidgetsBinding.instance.addObserver(runtime);
    runtime._control.setMethodCallHandler((call) async {
      if (call.method == 'hostLifecycle') {
        final value = call.arguments;
        if (value is Map) runtime._receiveLifecycle(value);
        return null;
      }
      if (call.method == 'back')
        return runtime._navigation?.maybePop() ?? false;
      if (call.method == 'cleanupResources')
        return runtime.queryCleanupResources()['items'];
      if (call.method == 'cleanupResourcesPage') {
        final args = call.arguments;
        return runtime.queryCleanupResources(
          offset: args is Map && args['offset'] is int
              ? args['offset'] as int
              : 0,
          limit: args is Map && args['limit'] is int
              ? args['limit'] as int
              : 64,
        );
      }
      if (call.method == 'cleanupStats') return runtime.cleanupStats;
      if (call.method == 'retryCleanup') {
        final value = call.arguments;
        final id = value is Map ? value['resourceId'] : null;
        return id is String && runtime.retryCleanup(id);
      }
      if (call.method != 'shutdown') throw MissingPluginException();
      try {
        await runtime.dispose();
      } catch (_) {
        // 逻辑关闭失败仍保留真实屏障，显式恢复后原 shutdown 才获成功确认。
      }
      await runtime.whenDrained;
      return null;
    });
    try {
      await runtime._start(adapter, startupTimeout).timeout(startupTimeout);
      runtime._ensureOpen();
      return runtime;
    } catch (_) {
      await runtime.dispose();
      rethrow;
    }
  }

  Future<void> _start(BridgeAdapter? adapter, Duration timeout) async {
    final token = List.generate(
      4,
      (_) => Random.secure().nextInt(0x100000000).toRadixString(16),
    ).join('-');
    final watch = Stopwatch()..start();
    Map<Object?, Object?>? configuration;
    while (configuration == null) {
      _ensureOpen();
      try {
        configuration = await Future.any<Map<Object?, Object?>?>([
          _control.invokeMapMethod<Object?, Object?>('bootstrap', {
            'runToken': token,
          }),
          _closedSignal.future.then(
            (_) => throw const BridgeError('CLOSED', '启动已取消'),
          ),
        ]);
        if (configuration == null)
          throw const BridgeError('BOOTSTRAP_FAILED', '宿主未返回启动配置');
      } on MissingPluginException {
        if (watch.elapsed >= timeout) rethrow;
        await Future<void>.delayed(const Duration(milliseconds: 25));
      } on PlatformException catch (error) {
        if (error.code != 'NOT_READY' || watch.elapsed >= timeout) rethrow;
        await Future<void>.delayed(const Duration(milliseconds: 25));
      }
    }
    _ensureOpen();
    final id = configuration['containerId'];
    final route = configuration['route'];
    final params = configuration['arguments'];
    if (id is! String ||
        id.isEmpty ||
        utf8.encode(id).length > 256 ||
        route is! String ||
        route.isEmpty ||
        utf8.encode(route).length > 512 ||
        params is! Map) {
      throw const BridgeError('BOOTSTRAP_FAILED', '无效的容器配置');
    }
    containerId = id;
    _supportsRestoration = configuration['supportsRestoration'] == true;
    final restored = configuration['restoration'];
    if (restored != null)
      _restoration = FlutterHullRestorationSnapshot.fromMap(restored);
    _canFinishContainer = configuration['canFinishContainer'] == true;
    initialRoute = route;
    arguments = _restorationObject(params);
    _receiveLifecycle(configuration);
    final pending = _pendingLifecycle;
    _pendingLifecycle = null;
    if (pending != null) _receiveLifecycle(pending);
    final bridge = BridgeClient(
      adapter ?? FlutterAdapter(messenger: _messenger),
    );
    _bridge = bridge;
    await Future.any<void>([
      bridge.ready(),
      _closedSignal.future.then(
        (_) => throw const BridgeError('CLOSED', '启动已取消'),
      ),
    ]);
    _ensureOpen();
    await _control.invokeMethod<void>('communicationReady');
    _diagnose('communicationReady');
  }

  Map<String, Object?> get diagnosticSnapshot => Map.unmodifiable({
    'containerId': containerId,
    'pages': _pages.length,
    'controls': _controls._pending,
    'subscriptionQueue': _subscriptions._pending,
    'calls': _pages.fold<int>(0, (sum, page) => sum + page._calls.length),
    'subscriptions': _pages.fold<int>(
      0,
      (sum, page) => sum + page._subscriptions.length,
    ),
    'pendingSubscriptions': _pages.fold<int>(
      0,
      (sum, page) => sum + page._pendingSubscriptions.length,
    ),
    'navigation': _pages.fold<int>(
      0,
      (sum, page) => sum + page._nativeNavigations.length,
    ),
    'snapshotWrites':
        (_snapshotActive == null ? 0 : 1) + (_snapshotPending == null ? 0 : 1),
    'cleanupResources': _resources.length,
    'closed': _closed,
  });

  void _diagnose(String phase, {String? pageId, String? errorCode}) =>
      diagnostics._emit(
        phase,
        containerId: containerId,
        pageId: pageId,
        errorCode: errorCode,
        counts: diagnosticSnapshot,
      );

  void _ensureOpen() {
    if (_closed) throw const BridgeError('CLOSED', '容器已经关闭');
  }

  Future<void> _saveRestoration(FlutterHullRestorationSnapshot snapshot) {
    _ensureOpen();
    if (!_supportsRestoration) {
      return Future.error(
        const BridgeError('RESTORATION_UNAVAILABLE', '宿主未启用状态恢复'),
      );
    }
    final revision = ++_restorationRevision;
    final active = _snapshotActive;
    if (active != null && active.done.isCompleted) {
      return Future.error(
        const BridgeError('RESTORATION_TIMEOUT', '上一份快照仍未返回'),
      );
    }
    if (active != null) {
      // 所有被覆盖的调用共用一个完成点，只有最新快照获确认才成功。
      final pending = _snapshotPending;
      if (pending != null) {
        pending.snapshot = snapshot;
        pending.revision = revision;
        return pending.done.future;
      }
      final next = _SnapshotWrite(snapshot, revision);
      _snapshotPending = next;
      return next.done.future;
    }
    final write = _SnapshotWrite(snapshot, revision);
    _sendSnapshot(write);
    return write.done.future;
  }

  void _sendSnapshot(_SnapshotWrite write) {
    _snapshotActive = write;
    final raw = _control.invokeMethod<bool>('saveState', {
      'containerId': containerId,
      'revision': write.revision,
      'snapshot': write.snapshot.toMap(),
    });
    final timer = write.timer = Timer(const Duration(seconds: 2), () {
      const error = BridgeError('RESTORATION_TIMEOUT', '快照确认超时');
      if (!write.done.isCompleted) write.done.completeError(error);
      final pending = _snapshotPending;
      _snapshotPending = null;
      if (pending != null && !pending.done.isCompleted)
        pending.done.completeError(error);
      // 保留实际在途标记，迟到返回前不继续积累平台调用。
    });
    raw
        .then(
          (accepted) {
            if (!write.done.isCompleted) {
              if (_closed) {
                write.done.completeError(
                  const BridgeError('CLOSED', '快照所属容器已关闭'),
                );
              } else if (accepted == true) {
                write.done.complete();
              } else {
                write.done.completeError(
                  const BridgeError('RESTORATION_REJECTED', '恢复快照未被宿主确认'),
                );
              }
            }
          },
          onError: (Object error, StackTrace stack) {
            if (!write.done.isCompleted) write.done.completeError(error, stack);
          },
        )
        .whenComplete(() {
          timer.cancel();
          if (!identical(_snapshotActive, write)) return;
          _snapshotActive = null;
          final next = _snapshotPending;
          _snapshotPending = null;
          if (next != null && !_closed) _sendSnapshot(next);
        });
  }

  void _retryCleanup(FlutterHullPageScope scope) {
    if (_closed ||
        !_pages.contains(scope) ||
        _cleanupRetries.containsKey(scope))
      return;
    final attempt = _cleanupAttempts[scope] ?? 0;
    if (attempt >= 3) return;
    _cleanupAttempts[scope] = attempt + 1;
    _cleanupRetries[scope] = Timer(
      Duration(milliseconds: 100 * (1 << attempt)),
      () {
        _cleanupRetries.remove(scope);
        if (_closed || !_pages.contains(scope)) return;
        unawaited(
          // 自动恢复只推进桥接清理，不等待或重复执行业务清理。
          scope._disposeBridge().catchError((Object error) {
            _retryCleanup(scope);
          }),
        );
      },
    );
  }

  void _pageDisposed(FlutterHullPageScope scope) {
    _pages.remove(scope);
    _cleanupRetries.remove(scope)?.cancel();
    _cleanupAttempts.remove(scope);
    _checkDrained();
  }

  FlutterHullPageScope createPageScope() {
    _ensureOpen();
    final bridge = _bridge;
    if (bridge == null) throw StateError('通信尚未就绪');
    late final FlutterHullPageScope scope;
    scope = FlutterHullPageScope._(
      bridge,
      _controls,
      runtime: this,
      pageId: "$containerId:${++_pageSerial}",
      onDisposed: () => _pageDisposed(scope),
    );
    _pages.add(scope);
    _diagnose('pageCreated', pageId: scope.pageId);
    return scope;
  }

  void _receiveLifecycle(Map<Object?, Object?> value) {
    if (_closed) return;
    if (containerId.isEmpty) {
      _pendingLifecycle = value;
      return;
    }
    if (value['containerId'] != containerId) return;
    final revision = value['lifecycleRevision'] as int? ?? 0;
    if (revision < _hostRevision) return;
    _hostRevision = revision;
    _hostVisible = value['visible'] != false;
    _hostForeground = value['foreground'] != false;
    for (final page in _pages.toList()) {
      page._updateLifecycle();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _appForeground =
        state == AppLifecycleState.resumed ||
        state == AppLifecycleState.inactive;
    for (final page in _pages.toList()) {
      page._updateLifecycle();
    }
  }

  /// 请求结束整个容器；Native onResult 才代表真实清理完成。
  Future<bool> finish([Map<String, Object?>? result]) {
    _ensureOpen();
    if (!_canFinishContainer) return Future.value(false);
    return Future.any([
      _control
          .invokeMethod<bool>(
            'finishContainer',
            result == null ? null : _restorationObject(result),
          )
          .then((value) => value == true),
      _closedSignal.future.then((_) => true),
    ]);
  }

  /// 业务首屏绘制且可交互后调用，与 communicationReady 分开。
  Future<void> notifyFirstFrame() async {
    _ensureOpen();
    if (_firstFrameReported) return;
    _firstFrameReported = true;
    try {
      await _control.invokeMethod<void>('firstFrame');
      _diagnose('firstFrame');
    } catch (_) {
      _firstFrameReported = false;
      rethrow;
    }
  }

  Future<void> dispose() {
    if (_disposal != null) return _disposal ?? Future<void>.value();
    _closed = true;
    _diagnose('closing');
    for (final write in [_snapshotActive, _snapshotPending]) {
      write?.timer?.cancel();
      if (write != null && !write.done.isCompleted) {
        write.done.completeError(const BridgeError('CLOSED', '快照所属容器已关闭'));
      }
    }
    _snapshotPending = null;
    for (final timer in _cleanupRetries.values) {
      timer.cancel();
    }
    _cleanupRetries.clear();
    _cleanupAttempts.clear();
    WidgetsBinding.instance.removeObserver(this);
    if (!_closedSignal.isCompleted) _closedSignal.complete();
    final done = Completer<void>();
    _disposal = done.future;
    () async {
      Object? failure;
      final pages = _pages.toList();
      // 同时启动所有业务清理，但连接关闭只等待自己的桥接句柄。
      final business = Future.wait(
        pages.map((page) {
          page._seal();
          return page._waitBusinessCleanup();
        }),
      ).then<Object?>((_) => null, onError: (Object error) => error);
      try {
        await Future.wait(pages.map((page) => page._disposeBridge()));
      } catch (error) {
        failure = error;
      }
      try {
        await _bridge?.dispose();
      } catch (error) {
        failure ??= error;
      } finally {
        _bridge = null;
        _connectionClosed = true;
        for (final page in _pages.toList()) {
          page._releaseAfterConnectionClosed();
        }
        _checkDrained();
      }
      failure ??= await business;
      if (failure != null)
        _diagnose('cleanupFailed', errorCode: 'CLEANUP_FAILED');
      if (failure == null) {
        done.complete();
      } else {
        done.completeError(failure);
      }
    }();
    return done.future;
  }
}

final class _SnapshotWrite {
  FlutterHullRestorationSnapshot snapshot;
  int revision;
  final done = Completer<void>();
  Timer? timer;
  _SnapshotWrite(this.snapshot, this.revision);
}
