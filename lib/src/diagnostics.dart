part of 'runtime.dart';

/// 只发布框架标识、阶段、时间与资源计数；观察者失败不影响业务。
final class FlutterHullDiagnostics {
  final void Function(Map<String, Object?>)? observer;
  final int Function() clock;
  final int eventLimit;
  final _events = <Map<String, Object?>>[];
  final _listeners = <VoidCallback>{};
  List<Map<String, Object?>> get events => List.unmodifiable(_events);
  VoidCallback listen(VoidCallback listener) {
    _listeners.add(listener);
    return () => _listeners.remove(listener);
  }

  static final _watch = Stopwatch()..start();
  FlutterHullDiagnostics({
    this.observer,
    this.eventLimit = 128,
    int Function()? clock,
  }) : clock = clock ?? (() => _watch.elapsedMicroseconds) {
    if (eventLimit <= 0 || eventLimit > 1024)
      throw ArgumentError.value(eventLimit);
  }

  void _emit(
    String phase, {
    required String containerId,
    String? pageId,
    String? errorCode,
    Map<String, Object?> counts = const {},
  }) {
    final event = Map<String, Object?>.unmodifiable({
      'phase': phase,
      'timestampMicros': clock(),
      'containerId': containerId,
      if (pageId != null) 'pageId': pageId,
      if (errorCode != null) 'errorCode': errorCode,
      'counts': Map<String, Object?>.unmodifiable(counts),
    });
    _events.add(event);
    while (_events.length > eventLimit) {
      _events.removeAt(0);
    }
    try {
      observer?.call(event);
    } catch (_) {}
    for (final listener in _listeners.toList()) {
      try {
        listener();
      } catch (_) {}
    }
  }
}

/// 宿主开发菜单可直接挂载；离开界面后自动解除事件订阅。
class FlutterHullDiagnosticsPanel extends StatefulWidget {
  final FlutterHullRuntime runtime;
  final ValueChanged<String>? onExport;
  const FlutterHullDiagnosticsPanel({
    super.key,
    required this.runtime,
    this.onExport,
  });
  @override
  State<FlutterHullDiagnosticsPanel> createState() =>
      _FlutterHullDiagnosticsPanelState();
}

class _FlutterHullDiagnosticsPanelState
    extends State<FlutterHullDiagnosticsPanel> {
  VoidCallback? _unsubscribe;
  void _subscribe() {
    _unsubscribe = widget.runtime.diagnostics.listen(() {
      if (mounted) setState(() {});
    });
  }

  @override
  void initState() {
    super.initState();
    _subscribe();
  }

  @override
  void didUpdateWidget(covariant FlutterHullDiagnosticsPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.runtime != widget.runtime) {
      _unsubscribe?.call();
      _subscribe();
    }
  }

  @override
  void dispose() {
    _unsubscribe?.call();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Material(
    child: Column(
      children: [
        Text('FlutterHull ${widget.runtime.containerId}'),
        Text(jsonEncode(widget.runtime.diagnosticSnapshot)),
        for (final id in widget.runtime.routingCleanupIds)
          TextButton(
            onPressed: () => unawaited(
              widget.runtime.retryRoutingCleanup(id).catchError((Object _) {}),
            ),
            child: Text('重试路由清理 $id'),
          ),
        for (final id
            in widget.runtime._navigation?.restorationCleanupIds ?? <String>[])
          TextButton(
            onPressed: () => unawaited(
              (widget.runtime._navigation?.retryRestorationCleanup(id) ??
                      Future<void>.value())
                  .catchError((Object _) {}),
            ),
            child: Text('重试恢复回滚 $id'),
          ),
        TextButton(
          onPressed: () {
            final report = widget.runtime.exportDiagnosticReport();
            if (widget.onExport != null) {
              widget.onExport?.call(report);
            } else {
              unawaited(Clipboard.setData(ClipboardData(text: report)));
            }
          },
          child: const Text('导出脱敏报告'),
        ),
        Expanded(
          child: ListView(
            children: [
              for (final event in widget.runtime.diagnostics.events)
                Text('${event['phase']} ${event['errorCode'] ?? ''}'),
            ],
          ),
        ),
      ],
    ),
  );
}
