# flutter_hull

FlutterHull 为 Flutter 页面提供原生宿主管理、受管路由、页面资源清理和容器生命周期。`open` 创建并销毁自己的 Engine；`attach` 接入 Flutter Runner 的现有 Engine，由 Runner 保持 Engine、View 和平台回调的所有权。

公开预览配对为 FlutterHull `0.1.0-preview.2`、`aeris_flutter` `0.26.0-preview.3`、Aeris Native `0.26.0-preview.2`。当前为预览版本，请按应用的目标设备和插件组合验证集成。

## 环境与依赖

Dart `>=3.13.7 <4.0.0`、Flutter `>=3.47.8`；iOS 15.0+；Android minSdk 24、compileSdk 37、Java 17。本预览 iOS 使用 CocoaPods；Android 接入需保留 Flutter 工具支持的 Kotlin/AGP 配置。

```yaml
dependencies:
  flutter:
    sdk: flutter
  flutter_hull: 0.1.0-preview.2
flutter:
  uses-material-design: true
  config:
    enable-swift-package-manager: false
```

Aeris Flutter 为精确版本的 hosted 传递依赖。运行 `flutter pub get`，应用提交 `pubspec.lock`；升级时保持 Dart 与原生依赖的配套版本。

### iOS 公共 Specs

在宿主 Podfile 顶部合并以下内容，保留 Flutter 模板的 podhelper、插件安装及 post_install：

```ruby
source 'https://github.com/zhangguozhong/leo-podspecs.git'
source 'https://cdn.cocoapods.org/'
platform :ios, '15.0'
```

Flutter 自动安装 `flutter_hull`、`aeris_flutter` 及其固定的 Aeris Native 依赖，不要再为同名 Pod 配置其他源码来源。执行 `pod install` 后使用 `.xcworkspace`。本预览未提供 SwiftPM 描述，应用级开关见 [Flutter 官方说明](https://docs.flutter.dev/packages-and-plugins/swift-package-manager/for-app-developers)。

### Android 公共 Maven

将以下仓库添加到当前宿主已有的有效依赖仓库集合中：采用集中仓库管理时放入 `dependencyResolutionManagement.repositories`，采用 Flutter 模板项目仓库时放入既有 `allprojects.repositories`：

```kotlin
maven {
    url = uri("https://raw.githubusercontent.com/zhangguozhong/aeris-maven/0.26.0-preview.2")
    content { includeGroup("com.aeris.sdk") }
}
```

保留 `google()`、`mavenCentral()`；Native 坐标应解析为 `com.aeris.sdk:aeris:0.26.0-preview.2`。无需添加本地 `:aeris` 项目或修改全局仓库。

## 流程一：标准 Flutter App，接入现有 Engine

```sh
flutter create --empty --platforms ios,android hull_app
cd hull_app
```

将本包 [example/pubspec.yaml](example/pubspec.yaml) 的依赖和 Flutter 配置合并到新应用，把 [example/lib/main.dart](example/lib/main.dart) 作为应用入口，再添加上述公共平台仓库并执行 `flutter pub get`。示例只有 Dart 代码，平台 Runner 由 `flutter create` 生成；还必须完成下面的 Native attach。

Dart 使用 `FlutterHullBootstrap` 等待真实宿主握手，然后用 `FlutterHullNavigator` 为路由建立独立 PageScope。未完成 Native attach 时，默认启动期限为 8 秒，示例显示“容器连接失败”；该状态表示宿主未就绪，不表示通信成功。

### iOS：在实际 Runner controller 上 attach

保留生成的 AppDelegate、SceneDelegate 和 `GeneratedPluginRegistrant` 注册。由 SceneDelegate 或其他长期持有的对象保存 Coordinator，在拿到实际 FlutterViewController 后调用：

```swift
import Aeris
import Flutter
import UIKit
import flutter_hull

@MainActor final class HullRunnerBinding {
  private let bridge = BridgeEngine()
  private var coordinator: FlutterHullCoordinator?

  func attach(to controller: FlutterViewController) throws {
    guard coordinator == nil, controller.engine.viewController === controller else { return }
    let current = FlutterHullCoordinator(
      engine: bridge, allowedPermissions: [], allowedEventTopics: [])
    try current.attach(to: controller.engine, viewController: controller,
      route: "/", arguments: [:])
    coordinator = current
  }

  func becameActive() {
    coordinator?.setVisible(true)
    coordinator?.setForeground(true)
  }

  func enteredBackground() { coordinator?.setForeground(false) }

  func detach(completion: @escaping (Result<Void, Error>) -> Void) {
    guard let current = coordinator else { completion(.success(())); return }
    current.detach(completion: completion)
  }

  func engineWillDestroy() { coordinator?.engineWillDestroy() }
}
```

例如在 Scene 的 `willConnect` 或 `sceneDidBecomeActive` 中，确认 `window?.rootViewController` 是实际 FlutterViewController 后 attach，并在 Scene 前后台切换时转发状态。Runner 最终销毁 Engine 前同步调用 `engineWillDestroy()`；如果仅退出受管业务而保留 Runner，先 `detach` 并等待成功。不要为同一个 Engine 同时注册两套插件或创建第二个 Runtime。

### Android：FlutterActivity 保持默认所有权

```kotlin
import android.view.ViewGroup
import com.aeris.sdk.BridgeEngine
import com.flutterhull.sdk.FlutterHullCoordinator
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    private val bridge = BridgeEngine()
    private val container = FlutterHullCoordinator(bridge,
        allowedPermissions = emptySet(), allowedEventTopics = emptySet())

    override fun configureFlutterEngine(engine: FlutterEngine) {
        super.configureFlutterEngine(engine)
        val root = window.decorView.findViewById<ViewGroup>(android.R.id.content)
        container.attach(engine, root, route = "/")
    }

    override fun onResume() {
        super.onResume()
        container.setVisible(true)
        container.setForeground(true)
    }

    override fun onStop() {
        container.setForeground(false)
        super.onStop()
    }

    @Deprecated("Uses the preview container back protocol")
    override fun onBackPressed() {
        container.requestBack { handled ->
            if (!handled) container.detach { result ->
                if (result.isSuccess) finish()
            }
        }
    }

    override fun cleanUpFlutterEngine(engine: FlutterEngine) {
        container.engineWillDestroy()
        super.cleanUpFlutterEngine(engine)
    }
}
```

该片段面向默认的新建 Runner Engine；缓存 Engine 和 Activity 重建需要保留自己的所有权及清理交接策略。Android 返回事件先交给 `requestBack`，根页面退出前等待 `detach`；清理失败时保留容器并给出诊断/重试入口。默认 FlutterActivity 继续负责系统平台服务和插件生命周期，external 模式不要重复转发 `hostCallbacks`。

## 流程二：已有 Native App，创建 owned Engine

先创建 Flutter 模块并添加相同 hosted 依赖：

```sh
flutter create --template module hull_feature
cd hull_feature
flutter pub get
```

使用本包最小示例的 Dart 入口，并在模块 pubspec 保留 Flutter 工具生成的 `module` 配置。按 [Flutter Android add-to-app](https://docs.flutter.dev/add-to-app/android/project-setup)和 [iOS CocoaPods 既有工程集成](https://docs.flutter.dev/add-to-app/ios/project-setup-legacy#use-cocoapods-and-the-flutter-sdk)接入模块；合并公共 Specs/Maven 配置。模块生成的 `.ios`、`.android` 包装由 Flutter 管理，宿主代码放在实际 Native App 中。

### iOS owned 打开与关闭

下列方法属于宿主 UIViewController。宿主强持有 Coordinator，并提供生成的插件注册器；Native App 使用 Flutter 的插件生命周期分发器：

```swift
import Aeris
import Flutter
import FlutterPluginRegistrant
import UIKit
import flutter_hull

@MainActor final class HullHostViewController: UIViewController {
  private let bridge = BridgeEngine()
  private let callbacks: FlutterHullHostCallbacks
  private var coordinator: FlutterHullCoordinator?

  init(callbacks: FlutterHullHostCallbacks) {
    self.callbacks = callbacks
    super.init(nibName: nil, bundle: nil)
  }
  required init?(coder: NSCoder) { return nil }

  func openFlutter() throws {
    guard coordinator == nil else { return }
    let current = FlutterHullCoordinator(engine: bridge,
      allowedEventTopics: [], hostCallbacks: callbacks,
      registerPlugins: { GeneratedPluginRegistrant.register(with: $0) })
    current.onCloseRequested = { [weak current] in current?.close { _ in } }
    let page = try current.open(route: "/", arguments: [:])
    addChild(page)
    page.view.frame = view.bounds
    page.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    view.addSubview(page.view)
    page.didMove(toParent: self)
    coordinator = current
  }

  func closeFlutter(completion: @escaping (Result<Void, Error>) -> Void) {
    guard let current = coordinator else { completion(.success(())); return }
    current.close(completion: completion)
  }
}
```

采用 `FlutterSceneDelegate` 的 Scene 创建并持有 `FlutterHullHostCallbacks(sceneDelegate: self)`，传入宿主页面；其他 Scene/AppDelegate 架构使用 Flutter 官方 lifecycle provider/helper 转发。宿主页面显示/隐藏和 App 前后台变化分别调用 Coordinator 的 `setVisible` / `setForeground`。关闭完成前不要自行 `destroyContext`；失败或超时仍需保留 owner，查询并重试未完成清理。

### Android owned 打开与关闭

在实际 `ComponentActivity` 中创建并保留以下对象，在 `onCreate` 设置好 `FrameLayout` 后调用 `open`：

```kotlin
import android.widget.FrameLayout
import androidx.activity.ComponentActivity
import com.aeris.sdk.BridgeEngine
import com.flutterhull.sdk.FlutterHullCoordinator

class HullHostActivity : ComponentActivity() {
    private val bridge = BridgeEngine()
    private val container = FlutterHullCoordinator(bridge,
        allowedPermissions = emptySet(), allowedEventTopics = emptySet())

    fun openFlutter(slot: FrameLayout) {
        container.onCloseRequested = { container.close { } }
        container.open(this, slot, route = "/")
    }

    fun closeFlutter() {
        container.close { result ->
            if (result.isSuccess) finish()
        }
    }
}
```

这是打开/关闭的接线片段，Activity 还须完成生命周期与插件回调转发：`onResume` / `onPause` 对应 `container.resume()` / `container.pause()`；`onPostResume`、窗口焦点、Activity result、权限结果、Intent、user-leave、状态保存/恢复和内存回调对应 `container.hostCallbacks` 的同名方法。返回键通过 `requestBack`；未消费时进入 `close`，成功后再退出 Activity。使用到相应插件时必须转发所需回调，不能把此片段当作完整 Runner。

owned 模式由 SDK 安装当前 Engine 的 PlatformPlugin，负责 SystemChrome、Clipboard、HapticFeedback 等平台服务；宿主不要为同一 Engine 再安装一份。Activity 重建时必须先完成旧容器真实清理，再以最后确认的状态重新打开；不要在旧资源未释放时立即创建第二个容器。

## 页面、清理与返回

每个 Engine 主 isolate 调用一次 `FlutterHullRuntime.connect()`；各路由通过 `FlutterHullNavigator` 共享 Runtime，每页使用自己的 PageScope。业务调用、订阅和清理登记放在对应 scope，避免页面退出后仍使用旧句柄。

加载失败的页面可 `retry()`。旧业务清理仍在执行时页面进入 `waitingCleanup`；达到独立等待期限后显示错误，原资源仍被保留，完成清理后才能加载下一轮。宿主清理查询/显式重试入口用于恢复失败资源，超时不代表资源已解除。

默认路由/恢复快照上限为 32 条、64 KiB；清理登记每页 128、每 Runtime 512，Native registry 默认 512。Runtime 清理配额可以在 `connect(cleanupLimitPerPage: ..., cleanupLimitPerRuntime: ...)` 调整。诊断查询应使用分页接口，单页最多 64 条。

自定义样式通过 `FlutterHullRoute.routeFactory`、`loadingBuilder`、`errorBuilder`、`waitingCleanupBuilder` 接入，保留传入 RouteSettings，并继续使用 page 的 retry/cancel 控制。`notifyFirstFrame()` 应在业务首屏绘制后调用，和握手完成分开。

Dart `runtime.finish(result)` 请求结束整个容器，只有 Native 配置了关闭入口才会接受。Native `onResult` / `close` 成功回调才表示真实清理屏障结束；Flutter 路由返回和整个容器关闭分别处理。external 的 `detach` 保留 Runner Engine，owned 的 `close` 销毁自己的 Engine。

## 构建、升级与回滚

配置真实 Native 绑定后运行 `flutter run`。构建检查可使用 `flutter build apk --release --target-platform android-arm64` 和 `flutter build ios --release --no-codesign`；无签名编译不能替代真机安装验收。

升级时同时检查上述三项配对版本、应用锁文件和 Native 依赖解析结果。保留上一套已在自己应用验收的锁文件、平台配置及应用制品用于整体回滚；旧预览版本需连同其配套 Aeris 依赖一起回滚。已发布版本和 tag 保持不变，后续修复使用新版本。
