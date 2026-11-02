part of 'runtime.dart';

/// 宿主声明能力只用于准入；不会在此授予系统权限。
final class FlutterHullModule {
  final String id, version;
  final String? parameterContract, baseline;
  final Set<String> requiredCapabilities;
  FlutterHullModule({
    required this.id,
    required this.version,
    Set<String> requiredCapabilities = const {},
    this.parameterContract,
    this.baseline,
  }) : requiredCapabilities = Set.unmodifiable(requiredCapabilities) {
    if (!RegExp(r'^[a-zA-Z0-9][a-zA-Z0-9._-]{0,127}$').hasMatch(id) ||
        version.isEmpty ||
        version.length > 128 ||
        requiredCapabilities.length > 256 ||
        (parameterContract != null &&
            (parameterContract?.isEmpty == true ||
                (parameterContract?.length ?? 0) > 128)) ||
        (baseline != null &&
            (baseline?.isEmpty == true || (baseline?.length ?? 0) > 128)) ||
        requiredCapabilities.any(
          (value) => value.isEmpty || value.length > 128,
        ))
      throw const FormatException('模块声明无效');
  }
  Map<String, Object?> toMap() => {
    'id': id,
    'version': version,
    'requiredCapabilities': requiredCapabilities.toList()..sort(),
    if (parameterContract != null) 'parameterContract': parameterContract,
    if (baseline != null) 'baseline': baseline,
  };
}

enum FlutterHullTargetKind { native, rn, flutter, web }

final class FlutterHullTarget {
  final FlutterHullTargetKind kind;
  final String route;
  final Map<String, Object?> arguments;
  final Set<String> _fallbackHistory;
  FlutterHullTarget({
    required this.kind,
    required this.route,
    Map<String, Object?> arguments = const {},
  }) : arguments = _restorationObject(arguments),
       _fallbackHistory = const {} {
    if (route.isEmpty || utf8.encode(route).length > 512)
      throw const FormatException('混合路由名无效');
    if (kind == FlutterHullTargetKind.web &&
        !{'http', 'https'}.contains(Uri.tryParse(route)?.scheme))
      throw const FormatException('Web目标必须为HTTP(S)');
  }
  FlutterHullTarget._fallback(FlutterHullTarget target, Set<String> history)
    : kind = target.kind,
      route = target.route,
      arguments = target.arguments,
      _fallbackHistory = Set.unmodifiable(history);
}

/// dispatcher 必须返回真实 UI owner；cancel 仅在真实清理完成后成功。
final class FlutterHullDispatchOperation {
  final Future<Map<String, Object?>?> result;
  final Future<void> Function() cancel;
  FlutterHullDispatchOperation({required this.result, required this.cancel});
}

final class FlutterHullRoutingContext {
  final String requestId, userDomain;
  final int epoch;
  final bool Function() _isCancelled;
  bool get isCancelled => _isCancelled();
  FlutterHullRoutingContext._(
    this.requestId,
    this.userDomain,
    this.epoch,
    this._isCancelled,
  );
}

final class FlutterHullRouting {
  final int queueLimit;
  final Duration timeout;
  final Map<String, FlutterHullTarget> links;
  final FutureOr<bool> Function(FlutterHullTarget, FlutterHullRoutingContext)?
  guard;
  final FutureOr<FlutterHullDispatchOperation> Function(
    FlutterHullTarget,
    FlutterHullRoutingContext,
  )?
  dispatcher;
  FlutterHullRouting({
    this.queueLimit = 32,
    this.timeout = const Duration(seconds: 30),
    Map<String, FlutterHullTarget> links = const {},
    this.guard,
    this.dispatcher,
  }) : links = Map.unmodifiable(links) {
    if (queueLimit <= 0 || queueLimit > 256 || timeout <= Duration.zero)
      throw ArgumentError('路由配额/超时无效');
  }
}

final class FlutterHullRoutingRequest {
  final String id;
  final Future<Map<String, Object?>?> result;
  final Future<void> Function() cancel;
  FlutterHullRoutingRequest._(this.id, this.result, this.cancel);
}

final class _RoutingOwner {
  final String id;
  final FlutterHullTarget target;
  final int epoch;
  final String userDomain;
  final FlutterHullPageScope? page;
  final Completer<Map<String, Object?>?> done = Completer();
  final cancelledSignal = Completer<void>();
  final drained = Completer<void>();
  Completer<Object> cleanupFailure = Completer<Object>();
  FlutterHullDispatchOperation? operation;
  Future<void>? cleaning;
  Timer? timer;
  bool cancelled = false, started = false;
  late FlutterHullRoutingRequest request;
  _RoutingOwner(this.id, this.target, this.epoch, this.userDomain, this.page);
}

extension _HullRouting on FlutterHullRuntime {
  bool _routingValid(_RoutingOwner owner) =>
      !_closed &&
      !owner.cancelled &&
      owner.epoch == _routingEpoch &&
      owner.userDomain == environment.userDomain &&
      owner.page?._closed != true;
  void _drainRouting() {
    for (final owner in _routingOwners.values.toList()) {
      if (owner.started || owner.cancelled) continue;
      if (owner.target.kind == FlutterHullTargetKind.flutter &&
          _navigation?.key.currentState == null)
        continue;
      owner.started = true;
      unawaited(_dispatchRouting(owner));
    }
  }

  Future<void> _dispatchRouting(_RoutingOwner owner) async {
    final context = FlutterHullRoutingContext._(
      owner.id,
      owner.userDomain,
      owner.epoch,
      () => !_routingValid(owner),
    );
    try {
      if (!_routingValid(owner)) return;
      final guard = _routing.guard;
      final accepted = guard == null
          ? true
          : await Future.any<bool>([
              Future<bool>.sync(() => guard(owner.target, context)),
              owner.cancelledSignal.future.then((_) => false),
            ]);
      if (!_routingValid(owner)) return;
      if (!accepted) throw const BridgeError('ROUTE_DENIED', '宿主路由守卫拒绝');
      final navigator = _navigation;
      final operation = owner.target.kind == FlutterHullTargetKind.flutter
          ? (navigator ?? (throw const BridgeError('CLOSED', '导航已关闭')))
                ._dispatchTarget(owner.target)
          : await (_routing.dispatcher?.call(owner.target, context) ??
                (throw const BridgeError(
                  'DISPATCHER_UNAVAILABLE',
                  '宿主未提供混合路由dispatcher',
                )));
      owner.operation = operation;
      // 先观察 result，防止取消清理期间的异步失败变成未处理异常。
      final observed = operation.result.then<Object?>(
        (value) => value,
        onError: (Object error, StackTrace stack) =>
            _RoutingFailure(error, stack),
      );
      if (!_routingValid(owner)) {
        await _cleanupRouting(owner);
        return;
      }
      final value = await Future.any<Object?>([
        observed,
        owner.cancelledSignal.future.then((_) => null),
      ]);
      if (!_routingValid(owner)) return;
      if (value is _RoutingFailure)
        Error.throwWithStackTrace(value.error, value.stack);
      if (!owner.done.isCompleted)
        owner.done.complete(value == null ? null : _restorationObject(value));
      _releaseRouting(owner);
    } catch (error, stack) {
      if (!owner.done.isCompleted) owner.done.completeError(error, stack);
      if (owner.operation != null && !owner.cancelled) {
        owner.cancelled = true;
        owner.timer?.cancel();
        try {
          await _cleanupRouting(owner);
        } catch (_) {
          /* 保留失败owner供显式重试。 */
        }
      } else if (owner.operation == null) {
        _releaseRouting(owner);
      }
    } finally {
      if (owner.cancelled && owner.operation == null) _releaseRouting(owner);
    }
  }

  void _releaseRouting(_RoutingOwner owner) {
    owner.timer?.cancel();
    _routingOwners.remove(owner.id);
    if (!owner.drained.isCompleted) owner.drained.complete();
    owner.page?._checkDrained();
    _routingDedup.removeWhere((_, value) => identical(value, owner));
    _checkDrained();
  }

  Future<void> _cancelRouting(
    _RoutingOwner owner, [
    String code = 'CANCELLED',
  ]) async {
    if (owner.done.isCompleted && !owner.cancelled) return;
    owner.cancelled = true;
    if (!owner.cancelledSignal.isCompleted) owner.cancelledSignal.complete();
    owner.timer?.cancel();
    if (!owner.done.isCompleted)
      owner.done.completeError(BridgeError(code, '混合路由已取消'));
    _routingDedup.removeWhere((_, value) => identical(value, owner));
    if (owner.operation != null) {
      await _cleanupRouting(owner);
    } else if (!owner.started) {
      _releaseRouting(owner);
    }
  }

  Future<void> _cleanupRouting(_RoutingOwner owner) {
    if (owner.cleaning case final pending?) return pending;
    final operation = owner.operation;
    if (operation == null) return Future.value();
    if (owner.cleanupFailure.isCompleted)
      owner.cleanupFailure = Completer<Object>();
    final pending = Future<void>.sync(operation.cancel).then<void>(
      (_) {
        _releaseRouting(owner);
        _diagnose('routing.cleaned');
      },
      onError: (Object error, StackTrace stack) {
        _diagnose('routing.cleanupFailed', errorCode: 'CLEANUP_FAILED');
        if (!owner.cleanupFailure.isCompleted)
          owner.cleanupFailure.complete(error);
        Error.throwWithStackTrace(error, stack);
      },
    );
    owner.cleaning = pending;
    return pending.whenComplete(() => owner.cleaning = null);
  }

  Future<void> _waitRoutingCleanup(_RoutingOwner owner) {
    final cancellation = _cancelRouting(owner);
    return Future.any<void>([
      cancellation.then((_) => owner.drained.future),
      owner.cleanupFailure.future.then<void>((error) => throw error),
    ]);
  }

  void _invalidateRouting() {
    ++_routingEpoch;
    final invalidated = _epochChanged;
    _epochChanged = Completer<void>();
    if (!invalidated.isCompleted) invalidated.complete();
    for (final owner in _routingOwners.values.toList()) {
      unawaited(
        _cancelRouting(owner).catchError((Object _) {
          _diagnose('routing.cleanupFailed', errorCode: 'CLEANUP_FAILED');
        }),
      );
    }
  }
}

final class _RoutingFailure {
  final Object error;
  final StackTrace stack;
  _RoutingFailure(this.error, this.stack);
}
