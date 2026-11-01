part of 'runtime.dart';

/// 只发布框架标识、阶段、时间与资源计数；观察者失败不影响业务。
final class FlutterHullDiagnostics {
  final void Function(Map<String, Object?>)? observer;
  final int Function() clock;
  static final _watch = Stopwatch()..start();
  FlutterHullDiagnostics({this.observer, int Function()? clock})
    : clock = clock ?? (() => _watch.elapsedMicroseconds);

  void _emit(
    String phase, {
    required String containerId,
    String? pageId,
    String? errorCode,
    Map<String, Object?> counts = const {},
  }) {
    if (observer == null) return;
    try {
      observer?.call(
        Map.unmodifiable({
          'phase': phase,
          'timestampMicros': clock(),
          'containerId': containerId,
          if (pageId != null) 'pageId': pageId,
          if (errorCode != null) 'errorCode': errorCode,
          'counts': counts,
        }),
      );
    } catch (_) {
      /* 诊断不得成为业务依赖。 */
    }
  }
}
