part of 'runtime.dart';

enum FlutterHullLoadState { loading, waitingCleanup, ready, error, closed }

/// 每条路由独立一份；加载重试只更换本页 Scope，不重建 Client 或 Engine。
class FlutterHullPageController extends ChangeNotifier {
  final FlutterHullRuntime runtime;
  final Future<Object?> Function(FlutterHullPageScope) loader;
  final Duration? loadTimeout;
  final Duration cleanupWaitTimeout;
  FlutterHullPageScope? _scope;
  FlutterHullPageScope get scope => _scope ?? (throw StateError('页面尚未开始加载'));
  Object? data;
  Object? error;
  FlutterHullLoadState state = FlutterHullLoadState.loading;
  int _round = 0;
  bool _closed = false, _visible = false;
  Future<void>? _retrying;
  FlutterHullRoutingRequest? _fallbackRequest;
  Set<String> _fallbackHistory = const {};
  _HullRouteRecord? _route;
  FlutterHullPageController({
    required this.runtime,
    required this.loader,
    this.loadTimeout = const Duration(seconds: 30),
    this.cleanupWaitTimeout = const Duration(seconds: 5),
  }) {
    if (cleanupWaitTimeout <= Duration.zero)
      throw ArgumentError.value(cleanupWaitTimeout);
    final deadline = loadTimeout;
    if (deadline != null && deadline <= Duration.zero)
      throw ArgumentError.value(deadline);
  }
  void setVisible(bool value) {
    final changed = _visible != value;
    _visible = value;
    _scope?.setVisible(value);
    if (changed) notifyListeners();
  }

  Future<void> load() async {
    if (_closed || _scope != null) return;
    if (runtime._closed) {
      await close();
      return;
    }
    await _begin(++_round);
  }

  Future<void> _begin(int round) async {
    if (_closed || runtime._closed || round != _round) return;
    final recordDomain = _route?.userDomain;
    if (recordDomain != null &&
        recordDomain != runtime.environment.userDomain) {
      error = const BridgeError('RESTORATION_INCOMPATIBLE', '旧用户域页面不能重新加载');
      state = FlutterHullLoadState.error;
      notifyListeners();
      return;
    }
    final epoch = runtime._routingEpoch;
    final fresh = runtime.createPageScope().._route = _route;
    _scope = fresh;
    fresh._lifecycle.addListener(() {
      if (!_closed && identical(_scope, fresh)) notifyListeners();
    });
    fresh.setVisible(_visible);
    state = FlutterHullLoadState.loading;
    runtime._diagnose('loadStarted', pageId: _scope?.pageId);
    error = null;
    notifyListeners();
    var applyingRestoration = false;
    final loadWatch = Stopwatch()..start();
    try {
      final loading = fresh._whileOpen(
        runtime._duringEpoch(Future<Object?>.sync(() => loader(fresh)), epoch),
      );
      final deadline = loadTimeout;
      final value = await (deadline == null
          ? loading
          : loading.timeout(deadline));
      if (_closed || round != _round) return;
      if (runtime._closed) {
        await close();
        return;
      }
      if (epoch != runtime._routingEpoch)
        throw const BridgeError('CANCELLED', '页面所属用户域已改变');
      final record = _route;
      if (record?.restoring == true) {
        applyingRestoration = record?.definition.applyState != null;
        final applying = runtime._duringEpoch(
          fresh._whileOpen(
            Future<void>.sync(
              () => record?.definition.applyState?.call(
                fresh,
                value,
                record.restorationState,
              ),
            ),
          ),
          epoch,
        );
        await (deadline == null
            ? applying
            : applying.timeout(deadline - loadWatch.elapsed));
        if (_closed || round != _round || runtime._closed) return;
        if (epoch != runtime._routingEpoch)
          throw const BridgeError('CANCELLED', '恢复所属用户域已改变');
        record?.restoring = false;
      }
      data = value;
      state = FlutterHullLoadState.ready;
      runtime._diagnose('loadReady', pageId: fresh.pageId);
      if (record != null) runtime._navigation?._initialPageRestored(record);
    } catch (failure) {
      if (_closed || round != _round) return;
      if (runtime._closed) {
        await close();
        return;
      }
      // 失败与超时都立即封闭旧轮次；错误页不等待真实业务清理完成。
      fresh._seal();
      unawaited(fresh.dispose().catchError((Object _) {}));
      error = failure;
      state = FlutterHullLoadState.error;
      runtime._diagnose(
        'loadFailed',
        pageId: _scope?.pageId,
        errorCode: 'LOAD_FAILED',
      );
      if (_route case final record?
          when applyingRestoration ||
              (record.restoring &&
                  (record.definition.applyState != null ||
                      record.definition.module != null)) ||
              epoch != runtime._routingEpoch)
        unawaited(
          runtime._navigation?._initialRestoreFailed(record) ?? Future.value(),
        );
      if (_route?.restoring != true && epoch == runtime._routingEpoch)
        unawaited(runtime._fallback(this, round, failure, fresh));
    }
    notifyListeners();
  }

  Future<void> retry() {
    if (_retrying != null) return _retrying ?? Future.value();
    if (_closed) return Future.value();
    if (runtime._closed) return close();
    final done = Completer<void>();
    _retrying = done.future;
    final round = ++_round;
    final fallback = _fallbackRequest;
    _fallbackRequest = null;
    if (fallback != null)
      unawaited(fallback.cancel().catchError((Object _) {}));
    state = FlutterHullLoadState.waitingCleanup;
    runtime._diagnose('waitingCleanup', pageId: _scope?.pageId);
    error = null;
    notifyListeners();
    () async {
      try {
        final previous = _scope;
        await (() async {
          await previous?.dispose();
          await previous?.whenDrained;
        })().timeout(
          cleanupWaitTimeout,
          onTimeout: () {
            throw const BridgeError(
              'CLEANUP_TIMEOUT',
              '旧页面清理仍未完成；请查询 cleanupResources 并恢复失败任务后重试',
            );
          },
        );
        if (_closed || round != _round) return;
        if (runtime._closed) {
          await close();
          return;
        }
        _scope = null;
        await _begin(round);
      } catch (failure) {
        if (!_closed && round == _round) {
          error = failure;
          state = FlutterHullLoadState.error;
          runtime._diagnose(
            'loadFailed',
            pageId: _scope?.pageId,
            errorCode: 'LOAD_FAILED',
          );
          notifyListeners();
        }
      } finally {
        _retrying = null;
        done.complete();
      }
    }();
    return done.future;
  }

  /// 错误页的Scope已经封闭，取消入口仍由受管导航负责退出。
  bool cancel([Map<String, Object?>? result]) =>
      !_closed && (runtime._navigation?._pop(_route, result) ?? false);

  Future<void> close() async {
    if (!_closed) {
      _closed = true;
      ++_round;
      final fallback = _fallbackRequest;
      _fallbackRequest = null;
      if (fallback != null) await fallback.cancel();
      state = FlutterHullLoadState.closed;
      notifyListeners();
    }
    final closing = _scope;
    try {
      await closing?.dispose();
    } catch (_) {
      if (closing != null) runtime._retryCleanup(closing);
      rethrow;
    }
  }
}

class _FlutterHullPage extends StatefulWidget {
  final _HullRouteRecord record;
  const _FlutterHullPage(this.record);
  @override
  State<_FlutterHullPage> createState() => _FlutterHullPageState();
}

class _FlutterHullPageState extends State<_FlutterHullPage> {
  FlutterHullPageController get page => widget.record.page;
  bool _frameScheduled = false;
  @override
  void initState() {
    super.initState();
    unawaited(page.load());
  }

  @override
  void dispose() {
    unawaited(
      page.close().catchError((Object error) {
        debugPrint('页面清理未完成：$error');
      }),
    );
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: page,
    builder: (context, _) {
      if (page.state == FlutterHullLoadState.ready) {
        if (!_frameScheduled &&
            !page.runtime._firstFrameReported &&
            page._visible) {
          _frameScheduled = true;
          final scope = page._scope;
          final round = page._round;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            _frameScheduled = false;
            if (mounted &&
                !page.runtime._closed &&
                !page._closed &&
                page.state == FlutterHullLoadState.ready &&
                page._round == round &&
                identical(page._scope, scope) &&
                page._visible &&
                widget.record.route.isCurrent &&
                !widget.record.returning &&
                scope?.lifecycle.value == FlutterHullPageLifecycle.visible) {
              unawaited(
                page.runtime.notifyFirstFrame().catchError((Object error) {
                  debugPrint('首帧通知失败：$error');
                }),
              );
            }
          });
        }
        return widget.record.definition.builder(context, page, page.data);
      }
      if (page.state == FlutterHullLoadState.closed) return const SizedBox();
      final definition = widget.record.definition;
      final custom = switch (page.state) {
        FlutterHullLoadState.loading => definition.loadingBuilder,
        FlutterHullLoadState.waitingCleanup => definition.waitingCleanupBuilder,
        FlutterHullLoadState.error => definition.errorBuilder,
        _ => null,
      };
      if (custom != null) return custom(context, page);
      return CupertinoPageScaffold(
        navigationBar: CupertinoNavigationBar(
          middle: Text(widget.record.definition.title),
        ),
        child: Center(
          child: page.state == FlutterHullLoadState.waitingCleanup
              ? const Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [CupertinoActivityIndicator(), Text('正在等待旧页面清理')],
                )
              : page.state == FlutterHullLoadState.loading
              ? const Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [CupertinoActivityIndicator(), Text('页面加载中')],
                )
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('页面加载失败'),
                    Text('${page.error}'),
                    CupertinoButton(
                      key: const ValueKey('flutter-hull-retry'),
                      onPressed: page.retry,
                      child: const Text('重试当前页'),
                    ),
                  ],
                ),
        ),
      );
    },
  );
}

/// 启动连接与业务页面加载分开；连接失败后的 Engine 重开由宿主负责。
class FlutterHullBootstrap extends StatefulWidget {
  final Future<FlutterHullRuntime> Function() connect;
  final Widget Function(BuildContext, FlutterHullRuntime) builder;
  final VoidCallback? onReopen;
  const FlutterHullBootstrap({
    super.key,
    required this.connect,
    required this.builder,
    this.onReopen,
  });
  @override
  State<FlutterHullBootstrap> createState() => _FlutterHullBootstrapState();
}

class _FlutterHullBootstrapState extends State<FlutterHullBootstrap> {
  late final pending = widget.connect();
  @override
  Widget build(BuildContext context) => FutureBuilder<FlutterHullRuntime>(
    future: pending,
    builder: (context, snapshot) {
      final runtime = snapshot.data;
      if (runtime != null) return widget.builder(context, runtime);
      return MaterialApp(
        home: Scaffold(
          body: Center(
            child: snapshot.hasError
                ? Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text('容器连接失败'),
                      Text('${snapshot.error}'),
                      if (widget.onReopen != null)
                        FilledButton(
                          onPressed: widget.onReopen,
                          child: const Text('重新打开容器'),
                        ),
                    ],
                  )
                : const CupertinoActivityIndicator(),
          ),
        ),
      );
    },
  );
}
