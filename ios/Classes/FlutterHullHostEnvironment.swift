import Foundation

/// 仅注入非敏感宿主环境；值不可变，用户域使用宿主不透明标识。
public struct FlutterHullHostEnvironment {
  public let revision: Int
  public let theme: String
  public let locale: String
  public let fontScale: Double
  public let width: Double
  public let height: Double
  public let userDomain: String
  public init(
    revision: Int = 0, theme: String = "system", locale: String = "en",
    fontScale: Double = 1, width: Double = 0, height: Double = 0, userDomain: String = "anonymous"
  ) throws {
    guard revision >= 0, revision <= 9_007_199_254_740_991,
      ["system", "light", "dark"].contains(theme), !locale.isEmpty, locale.utf8.count <= 64,
      fontScale.isFinite, fontScale > 0, fontScale <= 10,
      width.isFinite, width >= 0, height.isFinite, height >= 0,
      !userDomain.isEmpty, userDomain.utf8.count <= 128
    else {
      throw FlutterHullCleanupError(code: "INVALID_ENVIRONMENT")
    }
    self.revision = revision
    self.theme = theme
    self.locale = locale
    self.fontScale = fontScale
    self.width = width
    self.height = height
    self.userDomain = userDomain
  }
  public var toMap: [String: Any] {
    [
      "revision": revision, "theme": theme, "locale": locale, "fontScale": fontScale,
      "width": width, "height": height, "userDomain": userDomain,
    ]
  }
}
