import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_hull/flutter_hull.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    FlutterHullBootstrap(
      // 只接入真实宿主。尚未绑定 Native 时，启动超时会显示连接失败。
      connect: () => FlutterHullRuntime.connect(),
      builder: (_, runtime) => ConnectedApp(runtime: runtime),
    ),
  );
}

class ConnectedApp extends StatefulWidget {
  final FlutterHullRuntime runtime;
  const ConnectedApp({super.key, required this.runtime});

  @override
  State<ConnectedApp> createState() => _ConnectedAppState();
}

class _ConnectedAppState extends State<ConnectedApp> {
  late final FlutterHullNavigator navigation;
  bool _firstFrameScheduled = false;

  @override
  void initState() {
    super.initState();
    navigation = FlutterHullNavigator(
      runtime: widget.runtime,
      routes: {
        '/': FlutterHullRoute(
          title: 'FlutterHull',
          routeFactory: (settings, builder, title) =>
              MaterialPageRoute<Map<String, Object?>?>(
                settings: settings,
                builder: builder,
              ),
          builder: (_, page, data) {
            // 仅在受管页面已加载并绘制后报告业务首屏。
            if (!_firstFrameScheduled) {
              _firstFrameScheduled = true;
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (mounted) unawaited(_reportFirstFrame());
              });
            }
            return Scaffold(
              appBar: AppBar(title: const Text('FlutterHull preview')),
              body: Center(
                child: Text(
                  '原生容器已连接\n'
                  'container: ${widget.runtime.containerId}\n'
                  'page: ${page.scope.pageId}',
                  textAlign: TextAlign.center,
                ),
              ),
            );
          },
        ),
      },
    );
  }

  Future<void> _reportFirstFrame() async {
    try {
      await widget.runtime.notifyFirstFrame();
    } catch (error, stack) {
      FlutterError.reportError(
        FlutterErrorDetails(exception: error, stack: stack),
      );
    }
  }

  @override
  void dispose() {
    navigation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    navigatorKey: navigation.key,
    navigatorObservers: [navigation.observer],
    onGenerateRoute: navigation.onGenerateRoute,
    onGenerateInitialRoutes: navigation.initialRoutes,
    initialRoute: widget.runtime.initialRoute,
  );
}
