part of 'runtime.dart';

/// 降级仅处理宿主明确归类的运行故障；业务异常默认留在本页错误UI。
final class FlutterHullFailurePolicy {
  final int maxFailures;
  final Duration window, cooldown;
  final bool Function(Object)? shouldFallback;
  final FutureOr<FlutterHullTarget?> Function(String route, String errorCode)
  onFallback;
  final int Function() clock;
  // 参数、权限、取消、能力不足等业务/控制错误不默认降级；未知代码也须宿主显式归类。
  static const _runtimeFailureCodes = <String>{
    'HOST_FAILED',
    'ENGINE_START_FAILED',
    'RUNTIME_FAILED',
    'TRANSPORT_FAILED',
  };
  static final _watch = Stopwatch()..start();
  FlutterHullFailurePolicy({
    this.maxFailures = 3,
    this.window = const Duration(minutes: 1),
    this.cooldown = const Duration(minutes: 1),
    this.shouldFallback,
    required this.onFallback,
    int Function()? clock,
  }) : clock = clock ?? (() => _watch.elapsedMilliseconds) {
    if (maxFailures <= 0 ||
        maxFailures > 32 ||
        window <= Duration.zero ||
        cooldown <= Duration.zero)
      throw ArgumentError('降级窗口/次数无效');
  }
}

final class _FailureWindow {
  final times = <int>[];
  int? blockedUntil;
}

extension _HullFallback on FlutterHullRuntime {
  Future<void> _fallback(
    FlutterHullPageController page,
    int round,
    Object error,
    FlutterHullPageScope scope,
  ) async {
    final policy = _failurePolicy;
    if (policy == null) return;
    bool classified;
    try {
      classified =
          policy.shouldFallback?.call(error) ??
          (error is TimeoutException ||
              (error is BridgeError &&
                  FlutterHullFailurePolicy._runtimeFailureCodes.contains(
                    error.code,
                  )));
    } catch (_) {
      return;
    }
    if (!classified) return;
    final route = page._route?.route.settings.name ?? initialRoute;
    final history = _failureWindows.putIfAbsent(route, () => _FailureWindow());
    final now = policy.clock();
    if ((history.blockedUntil ?? 0) > now) {
      _diagnose('fallback.cooldown');
      return;
    }
    if (history.blockedUntil != null) {
      history.times.clear();
      history.blockedUntil = null;
    }
    history.times.removeWhere(
      (time) => now - time >= policy.window.inMilliseconds,
    );
    if (history.times.length >= policy.maxFailures) {
      history.blockedUntil = now + policy.cooldown.inMilliseconds;
      _diagnose('fallback.cooldown');
      return;
    }
    history.times.add(now);
    if (history.times.length >= policy.maxFailures)
      history.blockedUntil = now + policy.cooldown.inMilliseconds;
    final epoch = _routingEpoch, user = environment.userDomain;
    bool valid() =>
        !_closed &&
        !page._closed &&
        page._round == round &&
        epoch == _routingEpoch &&
        user == environment.userDomain;
    try {
      // 降级UI不得覆盖仍持有清理责任的业务页面。
      await scope.dispose();
      await scope.whenDrained;
      if (!valid()) return;
      final target = await policy.onFallback(
        route,
        error is BridgeError ? error.code : 'LOAD_TIMEOUT',
      );
      if (!valid() || target == null) return;
      if (target.kind == FlutterHullTargetKind.flutter &&
          (target.route == route ||
              page._fallbackHistory.contains(target.route))) {
        _diagnose('fallback.rejected', errorCode: 'FALLBACK_RECURSIVE');
        return;
      }
      final request = openTarget(
        FlutterHullTarget._fallback(target, {...page._fallbackHistory, route}),
      );
      page._fallbackRequest = request;
      request.result.then<void>(
        (_) {
          if (identical(page._fallbackRequest, request))
            page._fallbackRequest = null;
        },
        onError: (Object _, StackTrace __) {
          if (identical(page._fallbackRequest, request))
            page._fallbackRequest = null;
        },
      );
      _diagnose('fallback.dispatched');
    } catch (_) {
      _diagnose('fallback.failed', errorCode: 'FALLBACK_FAILED');
    }
  }
}
