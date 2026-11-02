import 'dart:convert';
import 'dart:io';

Map<String, dynamic> _read(File file) {
  if (file.lengthSync() > 262144) throw const FormatException('配置超过256KiB');
  final value = jsonDecode(file.readAsStringSync());
  if (value is! Map<String, dynamic>) throw const FormatException('配置需要JSON对象');
  return value;
}

String? _version(Directory root) {
  final file = File.fromUri(root.uri.resolve('pubspec.yaml'));
  if (!file.existsSync()) return null;
  return RegExp(
    r'^version:\s*[\x22\x27]?([^\s\x22\x27]+)',
    multiLine: true,
  ).firstMatch(file.readAsStringSync())?.group(1);
}

Map<String, String?> _installed(Directory app) {
  final file = File.fromUri(app.uri.resolve('.dart_tool/package_config.json'));
  if (!file.existsSync()) return {};
  final packages = _read(file)['packages'];
  if (packages is! List || packages.length > 4096)
    throw const FormatException('package_config不合法');
  return {
    for (final item in packages)
      if (item is Map && item['name'] is String && item['rootUri'] is String)
        item['name'] as String: _version(
          Directory.fromUri(file.uri.resolve(item['rootUri'] as String)),
        ),
  };
}

/// 静态接线检查与真实设备验收分开，缺少工具或配置不能报告已运行。
Map<String, Object?> inspectFlutterHull(Directory app) {
  final installed = _installed(app);
  final checks = <Map<String, Object?>>[];
  void add(String code, String state, String message) =>
      checks.add({'code': code, 'state': state, 'message': message});
  final version = installed['flutter_hull'];
  add(
    version == null ? 'SDK_NOT_INSTALLED' : 'SDK_INSTALLED',
    version == null ? 'failed' : 'passed',
    version == null ? '先运行flutter pub get' : 'flutter_hull $version',
  );
  final configFile = File.fromUri(app.uri.resolve('container.project.json'));
  if (!configFile.existsSync()) {
    add(
      'HOST_CONFIGURATION_MISSING',
      'not_applicable',
      '未提供container.project.json平台接线声明',
    );
  } else {
    final config = _read(configFile);
    final expected = config['expectedVersions'];
    if (expected == null) {
      add(
        'COMPATIBILITY_UNDECLARED',
        'not_applicable',
        '未声明expectedVersions，不能确认精确配套',
      );
    } else {
      if (expected is! Map || expected.isEmpty || expected.length > 64) {
        throw const FormatException('expectedVersions需要非空精确版本映射');
      }
      for (final entry in expected.entries) {
        if (entry.key is! String ||
            entry.value is! String ||
            !RegExp(r'^\d+\.\d+\.\d+(?:[-+][A-Za-z0-9.-]+)?$')
                .hasMatch(entry.value as String)) {
          throw const FormatException('expectedVersions仅接受精确版本');
        }
        final matched = installed[entry.key] == entry.value;
        add(
          matched ? 'VERSION_MATCH' : 'VERSION_MISMATCH',
          matched ? 'passed' : 'failed',
          '${entry.key}要求${entry.value}，实际${installed[entry.key] ?? '未安装'}',
        );
      }
    }
    final platforms = config['platforms'];
    if (config['schemaVersion'] != 1 ||
        platforms is! Map ||
        platforms.isEmpty ||
        platforms.keys.any((p) => p != 'ios' && p != 'android')) {
      throw const FormatException('需要schemaVersion=1及非空ios/android配置');
    }
    for (final entry in platforms.entries) {
      final values = entry.value;
      if (values is! Map) throw const FormatException('平台配置需要对象');
      for (final key in [
        'project',
        if (entry.key == 'ios') 'podfile',
        if (values['bundle'] != null) 'bundle',
      ]) {
        final relative = values[key];
        final exists =
            relative is String &&
            relative.isNotEmpty &&
            FileSystemEntity.typeSync(app.uri.resolve(relative).toFilePath()) !=
                FileSystemEntityType.notFound;
        add(
          '${entry.key}_${key}'.toUpperCase(),
          exists ? 'passed' : 'failed',
          '${entry.key} $key${exists ? '存在' : '缺失'}',
        );
      }
      if (entry.key == 'ios' && values['podfile'] is String) {
        final pod = File.fromUri(app.uri.resolve(values['podfile'] as String));
        if (pod.existsSync()) {
          final text = pod.readAsStringSync();
          final linked =
              text.contains('flutter_install_all_ios_pods') ||
              text.contains('install_all_flutter_pods');
          add(
            'IOS_AUTOLINK',
            linked ? 'passed' : 'failed',
            linked ? '发现Flutter插件安装入口' : '缺少Flutter插件安装入口',
          );
          final duplicate = RegExp(
            r'''^\s*pod\s+['\x22](flutter_hull|aeris_flutter)['\x22]''',
            multiLine: true,
          ).hasMatch(text);
          add(
            duplicate ? 'DUPLICATE_PLUGIN_SOURCE' : 'PLUGIN_SOURCE_UNIQUE',
            duplicate ? 'failed' : 'passed',
            duplicate ? 'Flutter自动安装的插件不应再显式指定另一个Pod来源' : '没有发现插件重复来源声明',
          );
          final native = config['expectedNativeVersions'];
          if (native != null) {
            if (native is! Map || native.isEmpty || native.length > 32)
              throw const FormatException('expectedNativeVersions需要版本映射');
            final lock = File.fromUri(pod.uri.resolve('Podfile.lock'));
            if (!lock.existsSync()) {
              add(
                'NATIVE_LOCK_MISSING',
                'not_applicable',
                '尚未提供Podfile.lock，未确认Native配套',
              );
            } else {
              final lockText = lock.readAsStringSync();
              for (final entry in native.entries) {
                if (entry.key is! String || entry.value is! String)
                  throw const FormatException('Native版本格式不合法');
                final versions = RegExp(
                  '^\\s*-\\s+${RegExp.escape(entry.key as String)}(?:/[A-Za-z0-9_/-]+)?\\s+\\(([^)\\s]+)',
                  multiLine: true,
                ).allMatches(lockText).map((m) => m.group(1)).toSet();
                final matched =
                    versions.length == 1 && versions.single == entry.value;
                add(
                  'NATIVE_VERSION_${matched ? 'MATCH' : 'MISMATCH'}',
                  matched ? 'passed' : 'failed',
                  '${entry.key}期望${entry.value}',
                );
              }
            }
          }
        }
      }
    }
  }
  return {
    'schemaVersion': 1,
    'runtimeVerified': false,
    'state': checks.any((c) => c['state'] == 'failed')
        ? 'failed'
        : checks.any((c) => c['state'] == 'not_applicable')
        ? 'not_applicable'
        : 'ready',
    'sdkVersion': version,
    'checks': checks,
  };
}

/// 只报告完整配套目标的差异，不自动修改pubspec或任何锁。
Map<String, Object?> planFlutterHullUpgrade(
  Directory app,
  Map<String, dynamic> target,
) {
  final packages = target['packages'];
  if (target['schemaVersion'] != 1 ||
      packages is! List ||
      packages.isEmpty ||
      packages.length > 64) {
    throw const FormatException('需要schemaVersion=1及1至64项精确packages');
  }
  final seen = <String>{};
  final changes = <Map<String, Object?>>[];
  final installed = _installed(app);
  final versionPattern = RegExp(
    r'^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-[0-9A-Za-z]+(?:[.-][0-9A-Za-z]+)*)?(?:\+[0-9A-Za-z.-]+)?$',
  );
  for (final item in packages) {
    if (item is! Map ||
        item['name'] is! String ||
        item['version'] is! String ||
        !RegExp(r'^[a-z][a-z0-9_]*$').hasMatch(item['name'] as String) ||
        !versionPattern.hasMatch(item['version'] as String) ||
        !seen.add(item['name'] as String)) {
      throw const FormatException('包名、精确版本或唯一性不合法');
    }
    final name = item['name'] as String;
    if (installed[name] != item['version'])
      changes.add({
        'name': name,
        'current': installed[name],
        'target': item['version'],
      });
  }
  return {
    'schemaVersion': 1,
    'dryRun': true,
    'changes': changes,
    'steps': [
      '审阅Dart和Native完整配套版本',
      '由宿主更新pubspec并重新生成锁文件',
      '执行Pod/Gradle和插件接线检查',
      '完成Debug/Release和设备场景验收',
    ],
    'message': '未修改文件；静态版本一致不等同于设备验收。',
  };
}

Future<int> runFlutterHullTools(List<String> arguments) async {
  try {
    if (arguments.isEmpty || arguments.contains('--help')) {
      stdout.writeln(
        'dart run flutter_hull doctor --app DIR\ndart run flutter_hull upgrade --app DIR --target PROFILE.json --dry-run',
      );
      return 0;
    }
    final command = arguments.first;
    if (!['doctor', 'upgrade'].contains(command))
      throw const FormatException('未知命令');
    final options = <String, String>{};
    for (var i = 1; i < arguments.length; i++) {
      final key = arguments[i];
      if (options.containsKey(key)) throw const FormatException('重复参数');
      if (key == '--dry-run') {
        options[key] = 'true';
        continue;
      }
      if (!['--app', '--target'].contains(key) ||
          i + 1 >= arguments.length ||
          arguments[i + 1].startsWith('--'))
        throw const FormatException('参数不合法');
      options[key] = arguments[++i];
    }
    final appPath = options['--app'];
    if (appPath == null) throw const FormatException('必须指定--app');
    final app = Directory(appPath).absolute;
    if (!app.existsSync()) throw const FormatException('应用目录不存在');
    Map<String, Object?> report;
    if (command == 'upgrade') {
      final target = options['--target'];
      if (target == null || options['--dry-run'] != 'true')
        throw const FormatException('upgrade需要--target和--dry-run');
      report = planFlutterHullUpgrade(app, _read(File(target)));
    } else {
      if (options.containsKey('--target') || options.containsKey('--dry-run'))
        throw const FormatException('doctor只接受--app');
      report = inspectFlutterHull(app);
    }
    stdout.writeln(const JsonEncoder.withIndent('  ').convert(report));
    return 0;
  } catch (error) {
    stderr.writeln('FlutterHull: $error');
    return 2;
  }
}
