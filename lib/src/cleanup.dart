part of 'runtime.dart';

/// 合作式取消通知；业务仍需把真实停止操作登记到 Scope。
final class FlutterHullCancellationSignal {
  final _cancelled = Completer<void>();
  FlutterHullCancellationSignal._();
  bool get isCancelled => _cancelled.isCompleted;
  Future<void> get whenCancelled => _cancelled.future;
  void _cancel() {
    if (!_cancelled.isCompleted) _cancelled.complete();
  }
}

/// 正常完成的任务可解除登记；清理已经开始后只能由该轮清理结果释放。
final class FlutterHullCleanupTicket {
  final _CleanupResource _resource;
  FlutterHullCleanupTicket._(this._resource);
  String get resourceId => _resource.id;
  bool finish() => _resource.finish();
  bool remove() => finish();
}

final class _CleanupResource {
  final FlutterHullPageScope owner;
  final String id, name;
  final FutureOr<void> Function() cleanup;
  final bool retryable;
  String state = 'registered';
  int attempt = 0;
  final _watch = Stopwatch();
  Future<void> settled = Future.value();
  _CleanupResource(
    this.owner,
    this.id,
    this.name,
    this.cleanup,
    this.retryable,
  );

  Map<String, Object?> get snapshot => Map.unmodifiable({
    'resourceId': id,
    'name': name,
    'pageId': owner.pageId,
    'containerId': owner._runtime.containerId,
    'state': state,
    'attempt': attempt,
    'elapsedMs': _watch.elapsedMilliseconds,
    'retryable': retryable,
    if (state == 'failed') 'errorCode': 'CLEANUP_FAILED',
  });

  bool finish() {
    if (state != 'registered') return false;
    _complete();
    return true;
  }

  void _complete() {
    state = 'completed';
    _watch.stop();
    owner._businessResources.remove(id);
    owner._checkDrained();
  }

  void run() {
    state = 'running';
    final round = ++attempt;
    _watch
      ..reset()
      ..start();
    // 每轮只接受本轮完成；等待方超时不改变真实操作状态。
    final completion = Completer<void>();
    // 先发布真实轮次屏障，再调用可能同步重入的业务代码。
    settled = completion.future;
    Future<void>.sync(cleanup).then(
      (_) {
        if (round == attempt && state == 'running') _complete();
        completion.complete();
      },
      onError: (Object _, StackTrace __) {
        if (round != attempt || state != 'running') {
          completion.complete();
          return;
        }
        _watch.stop();
        state = 'failed';
        owner._runtime._diagnose(
          'cleanupFailed',
          pageId: owner.pageId,
          errorCode: 'CLEANUP_FAILED',
        );
        completion.complete();
      },
    );
  }
}

// 仅构造当前页的诊断快照；运行和失败任务继续占用真实容量。
Map<String, Object?> _cleanupStats(
  Iterable<_CleanupResource> resources,
  int limit,
) {
  final counts = <String, int>{'registered': 0, 'running': 0, 'failed': 0};
  var total = 0;
  for (final resource in resources) {
    total++;
    counts[resource.state] = (counts[resource.state] ?? 0) + 1;
  }
  return Map.unmodifiable({'total': total, 'limit': limit, ...counts});
}

Map<String, Object?> _cleanupPage(
  Iterable<_CleanupResource> resources,
  int capacity,
  int offset,
  int limit,
) {
  if (offset < 0 || limit < 1 || limit > 64)
    throw ArgumentError('offset必须非负，limit必须为1至64');
  final stats = _cleanupStats(resources, capacity);
  final total = stats['total'] as int;
  final items = List<Map<String, Object?>>.unmodifiable(
    resources.skip(offset).take(limit).map((value) => value.snapshot),
  );
  return Map.unmodifiable({
    'items': items,
    'total': total,
    'offset': offset,
    'limit': limit,
    'nextOffset': offset + items.length < total ? offset + items.length : null,
    'counts': stats,
  });
}
