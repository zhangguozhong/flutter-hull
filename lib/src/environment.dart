part of 'runtime.dart';

/// 只含可公开环境信息，禁止存储凭据。每次变更整体替换不可变快照。
final class FlutterHullEnvironment {
  final int revision;
  final String theme, locale, userDomain;
  final double fontScale, width, height;
  const FlutterHullEnvironment({
    this.revision = 0,
    this.theme = 'system',
    this.locale = 'en',
    this.userDomain = 'anonymous',
    this.fontScale = 1,
    this.width = 0,
    this.height = 0,
  });
  factory FlutterHullEnvironment.fromMap(Object? value) {
    if (value is! Map) throw const FormatException('环境必须为对象');
    final revision = value['revision'];
    final theme = value['theme'] ?? 'system',
        locale = value['locale'] ?? 'en',
        user = value['userDomain'] ?? 'anonymous';
    double number(String key, double fallback) {
      final raw = value[key] ?? fallback;
      if (raw is! num || !raw.isFinite || raw < 0)
        throw const FormatException('环境数值无效');
      return raw.toDouble();
    }

    if (revision is! int ||
        revision < 0 ||
        !{'system', 'light', 'dark'}.contains(theme) ||
        locale is! String ||
        locale.isEmpty ||
        locale.length > 128 ||
        user is! String ||
        user.isEmpty ||
        user.length > 256)
      throw const FormatException('环境标识无效');
    final scale = number('fontScale', 1);
    if (scale <= 0 || scale > 10) throw const FormatException('字体缩放无效');
    return FlutterHullEnvironment(
      revision: revision,
      theme: theme as String,
      locale: locale,
      userDomain: user,
      fontScale: scale,
      width: number('width', 0),
      height: number('height', 0),
    );
  }
  Map<String, Object?> toMap() => {
    'revision': revision,
    'theme': theme,
    'locale': locale,
    'userDomain': userDomain,
    'fontScale': fontScale,
    'width': width,
    'height': height,
  };
}
