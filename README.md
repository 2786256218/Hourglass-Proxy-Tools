# Hourglass Proxy Tools

[中文](#中文) · [English](#english) · [GitHub Releases](https://github.com/2786256218/Hourglass-Proxy-Tools/releases)

## 中文

Hourglass 是一款基于 sing-box 的 Android 代理客户端，用于导入订阅、管理节点、配置分流和查看连接状态。应用支持 Android 7.0（API 24）及以上。

### 功能与项目特色

| 功能 | 说明 |
| --- | --- |
| 订阅与节点 | 支持 HTTPS 订阅、代理分享链接和本地 YAML 配置（`.yaml`、`.yml`、`.yam`）。支持订阅分组、重命名、节点延迟测试和自动选择。分享链接解析覆盖 VLESS、VMess、Shadowsocks、Trojan、Hysteria2、TUIC、AnyTLS、SOCKS 和 HTTP。 |
| 两种代理模式 | 默认使用系统代理规则模式，按规则将流量分配到代理、直连或屏蔽。切换到全局 TUN 后，应用将捕获的流量统一交给代理，国内和局域网绕过规则在该模式下暂不生效。 |
| 自定义分流与运行参数 | 支持按应用、域名和 IP 网段配置规则，提供 DNS 等运行参数覆写。内置中国 IP、中国站点及广告分类的 SRS 规则集。 |
| 住宅代理链 | 可直接连接住宅代理，也可先通过订阅节点，再经住宅代理出站。支持 SOCKS4、SOCKS5、HTTP 和 HTTPS，以及并行检测多个站点的连通性。 |
| 界面与流量 | 使用 Liquid Glass 风格界面展示实时上传、下载速率和流量曲线，并集中呈现节点、代理模式和连接状态。 |
| 凭据与更新 | 连接凭据使用 Android Keystore 保护。局域网代理默认关闭，启用时要求认证。应用从 GitHub Releases 检查更新，选择适合设备架构的 APK，并在调用系统安装器前检查包名和版本码。 |

### 技术栈

| 层级 | 实现 |
| --- | --- |
| 应用与配置 | Flutter 3.44+、Dart 3.12+。Flutter 负责界面与应用状态，Dart 负责订阅解析、节点管理和运行配置生成。 |
| Android 原生层 | Kotlin、Gradle Kotlin DSL、Android SDK。通过 Flutter 平台通道处理文件、凭据、APK 安装和代理服务。 |
| 代理核心 | Go 编写的 sing-box 通过 gomobile 导出为 Android AAR。本地 Flutter 插件 `sing_box` 负责连接 Dart 与 libbox。 |

### 主要第三方模块

| 模块 | 用途 |
| --- | --- |
| [sing_box](Android/packages/sing_box) / [sing-box](https://github.com/SagerNet/sing-box) | 仓库内置 Flutter 插件，封装代理配置、运行状态和 Android VPN 服务。核心版本固定在 [LIBBOX_VERSION](Android/packages/sing_box/LIBBOX_VERSION)，原生层部分实现源自 sing-box 官方客户端。 |
| [http](https://pub.dev/packages/http)、[yaml](https://pub.dev/packages/yaml) | 应用声明的 HTTP 客户端和 YAML 解析依赖。 |
| [shared_preferences](https://pub.dev/packages/shared_preferences)、[cupertino_icons](https://pub.dev/packages/cupertino_icons) | 应用偏好存储与 Cupertino 图标资源。 |
| [plugin_platform_interface](https://pub.dev/packages/plugin_platform_interface)、AndroidX Core KTX、Kotlin Coroutines | 插件的平台接口、Android 扩展 API 和异步任务。 |

完整的 Dart 依赖见 [pubspec.yaml](Android/pubspec.yaml) 和 [pubspec.lock](Android/pubspec.lock)。第三方版权与来源见 [sing_box 声明](Android/packages/sing_box/THIRD_PARTY_NOTICES.md)和 [Zashboard 资源声明](Android/assets/zashboard/THIRD_PARTY_NOTICES.md)。

### 仓库结构

| 路径 | 内容 |
| --- | --- |
| [Android/lib/](Android/lib/) | Flutter 应用、订阅解析及界面 |
| [Android/android/](Android/android/) | Android 应用模块、原生平台通道及打包配置 |
| [Android/packages/sing_box/](Android/packages/sing_box/) | 本地代理插件、libbox 下载配置和核心构建脚本 |
| [Android/assets/](Android/assets/) | 图标、规则集及其他资源 |
| [Android/test/](Android/test/) | Flutter 测试 |

### 构建 Android APK

需要 Flutter 3.44 或更高版本（Dart 3.12 至 4.0 之前）、JDK 21、Android SDK Platform 36 和 Build Tools 36.0.0。应用的最低 API 为 24，目标 API 为 35。先用 `flutter doctor -v` 检查工具链，并用 `flutter doctor --android-licenses` 接受 SDK 许可。

从仓库根目录执行：

```sh
cd Android
flutter pub get
flutter build apk --debug --split-per-abi --target-platform android-arm,android-arm64
```

输出位于 `Android/build/app/outputs/flutter-apk/`。选择与设备架构匹配的 `app-armeabi-v7a-debug.apk`（32 位 ARM）或 `app-arm64-v8a-debug.apk`（64 位 ARM）。

**正式发布。** 在 `Android/android/key.properties` 中配置 `storeFile`、`storePassword`、`keyAlias` 和 `keyPassword`。建议为 `storeFile` 使用绝对路径，并将密钥库与配置文件保留在版本控制之外。然后在 `Android/` 下执行：

```sh
flutter build apk --release --split-per-abi --target-platform android-arm,android-arm64
```

覆盖安装需使用同一签名密钥，并递增 [pubspec.yaml](Android/pubspec.yaml) 中 `version` 的 `+` 后数字，即 Android `versionCode`。签名配置可参考 [Flutter Android 发布指南](https://docs.flutter.dev/deployment/android)。

**libbox 获取方式。** 默认由 Gradle 根据 [libbox.properties](Android/packages/sing_box/android/libbox.properties) 下载 AAR，校验 SHA-256 后缓存。若无法访问下载地址，可将环境变量 `SING_BOX_LIBBOX_AAR` 指向本地 AAR 的绝对路径。也可以在具备 Bash、Go、Android SDK、NDK 和 JDK 的环境中，从 `Android/` 运行：

```sh
bash packages/sing_box/scripts/build_libbox.sh android --install
```

脚本会构建固定版本的核心并安装到插件的 `android/libs/` 目录。Gradle 会优先使用本地 AAR。

**开发检查。** 在 `Android/` 运行 `flutter analyze` 和 `flutter test`。

### 许可证

项目使用 [GPL-3.0-or-later](LICENSE)。随附组件和资源适用各自的许可及版权声明。

## English

Hourglass is a sing-box–based Android proxy client for importing subscriptions, managing nodes, configuring traffic rules, and monitoring connections. It supports Android 7.0 (API 24) and later.

### Features

| Feature | Details |
| --- | --- |
| Subscriptions and nodes | Import HTTPS subscriptions, proxy share links, and local YAML files (`.yaml`, `.yml`, `.yam`). Group and rename subscriptions, test node latency, and let the app select a node automatically. The share-link parser handles VLESS, VMess, Shadowsocks, Trojan, Hysteria2, TUIC, AnyTLS, SOCKS, and HTTP. |
| Two proxy modes | System proxy is the default and applies rules for proxying, direct access, and blocking. Global TUN sends captured traffic through the proxy and suspends China and LAN bypass rules while active. |
| Routing and overrides | Create per-app, domain, and IP-range rules, override runtime settings such as DNS, and use bundled SRS rule sets for China IP ranges, China sites, and ad domains. |
| Residential proxy chaining | Connect directly to a residential proxy or use a subscription node as the first hop and a residential proxy as the exit. Supports SOCKS4, SOCKS5, HTTP, and HTTPS, with parallel connectivity checks across multiple sites. |
| Interface and traffic | A Liquid Glass-inspired interface brings proxy mode, node selection, and connection status together with live upload and download rates and traffic charts. |
| Credentials and updates | Android Keystore protects connection credentials. LAN proxy access is disabled by default and requires authentication when enabled. The app checks GitHub Releases, chooses an APK for the device architecture, and checks its package name and version code before opening the Android installer. |

### Stack and third-party modules

| Module | Role |
| --- | --- |
| Flutter and Dart | Application UI, state, subscription parsing, and proxy configuration generation. |
| Kotlin and Gradle Kotlin DSL | Android integration and packaging. Flutter platform channels handle files, credentials, APK installation, and proxy service calls. |
| [sing_box](Android/packages/sing_box) and [sing-box](https://github.com/SagerNet/sing-box) | The bundled Flutter plugin bridges Dart to the Go-based sing-box engine. gomobile packages the core as an Android AAR. See [LIBBOX_VERSION](Android/packages/sing_box/LIBBOX_VERSION) for the pinned version. Some native code is adapted from the official clients. |
| [http](https://pub.dev/packages/http), [yaml](https://pub.dev/packages/yaml) | Declared HTTP and YAML parsing dependencies. |
| [shared_preferences](https://pub.dev/packages/shared_preferences), [cupertino_icons](https://pub.dev/packages/cupertino_icons) | Application preferences and Cupertino icon assets. |
| [plugin_platform_interface](https://pub.dev/packages/plugin_platform_interface), AndroidX Core KTX, Kotlin Coroutines | Plugin platform contract, Android extension APIs, and asynchronous native work. |

The Flutter application is in [Android/lib/](Android/lib/), the native app module in [Android/android/](Android/android/), and the proxy plugin and build scripts in [Android/packages/sing_box/](Android/packages/sing_box/). See the [dependency manifest](Android/pubspec.yaml), [lockfile](Android/pubspec.lock), [sing_box notices](Android/packages/sing_box/THIRD_PARTY_NOTICES.md), and [Zashboard asset notices](Android/assets/zashboard/THIRD_PARTY_NOTICES.md).

### Build the Android APK

Install Flutter 3.44 or later with Dart 3.12 through 3.x, JDK 21, Android SDK Platform 36, and Build Tools 36.0.0. The app uses min SDK 24 and target SDK 35. Check the toolchain with `flutter doctor -v` and accept the SDK licenses with `flutter doctor --android-licenses`.

From the repository root:

```sh
cd Android
flutter pub get
flutter build apk --debug --split-per-abi --target-platform android-arm,android-arm64
```

Find the 32-bit ARM and 64-bit ARM APKs under `Android/build/app/outputs/flutter-apk/`. For a signed release, configure `storeFile`, `storePassword`, `keyAlias`, and `keyPassword` in `Android/android/key.properties`. An absolute keystore path is recommended. Keep the keystore and credentials out of version control. From `Android/`, run:

```sh
flutter build apk --release --split-per-abi --target-platform android-arm,android-arm64
```

For in-place updates, reuse the signing key and increase the number after `+` in the [pubspec.yaml](Android/pubspec.yaml) version field, which sets Android's `versionCode`. See the [Flutter Android release guide](https://docs.flutter.dev/deployment/android) for signing details.

Gradle downloads and caches libbox after checking the SHA-256 in [libbox.properties](Android/packages/sing_box/android/libbox.properties). Set `SING_BOX_LIBBOX_AAR` to an absolute path to use a local AAR. To build the pinned core locally, install Bash, Go, the Android SDK and NDK, and a JDK, then run `bash packages/sing_box/scripts/build_libbox.sh android --install` from `Android/`. The script installs the AAR in the plugin's `android/libs/` directory.

Run `flutter analyze` and `flutter test` from `Android/` for development checks.

### License

Hourglass is licensed under [GPL-3.0-or-later](LICENSE). Bundled components and assets are subject to their respective licenses and copyright notices.
