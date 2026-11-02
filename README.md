# Hourglass

[中文](#中文) | [English](#english)

## 中文

**Hourglass By ASwave · V1.0.0**

Hourglass 是一款面向 Android 的轻量代理工具，采用简洁的 Liquid Glass 风格界面，基于 sing-box 核心，帮助你管理订阅、节点和网络分流。

### 功能

- 支持 HTTPS 在线订阅、代理分享链接，以及本地 YAML、YML、YAM 配置文件
- 支持规则模式的系统代理和全局 TUN 代理
- 支持按应用、域名和 IP 网段配置代理、直连与屏蔽规则
- 支持节点延迟测试、自动选择、局域网代理和住宅代理设置
- 支持订阅分组、自定义名称及节点管理

### 构建 Android APK

需要 Flutter 3.44 或更高版本、JDK 21 和 Android SDK。在项目根目录执行：

```powershell
flutter pub get
flutter build apk --debug --split-per-abi --target-platform android-arm,android-arm64
```

APK 输出在 `build/app/outputs/flutter-apk/`。发布正式版本时请使用自己的签名密钥；不要将签名密钥或 `android/key.properties` 上传到仓库。

### 项目信息

- 作者：ASwave
- 版本：V1.0.0
- GitHub：[Hourglass-Proxy-Tools](https://github.com/2786256218/Hourglass-Proxy-Tools)

### 许可证

项目使用 GPL-3.0-or-later。`sing_box` 插件及随包使用的 sing-box 核心也受其各自许可证和版权声明约束。

## English

**Hourglass By ASwave · V1.0.0**

Hourglass is a lightweight Android proxy client with a clean Liquid Glass-inspired interface. Powered by the sing-box core, it helps you manage subscriptions, proxy nodes, and traffic routing.

### Features

- HTTPS subscription URLs, proxy share links, and local YAML, YML, or YAM configuration files
- Rule-based system proxy and global TUN modes
- Per-app, domain, and IP-range proxy, direct, and block rules
- Node latency tests, automatic selection, LAN proxy, and residential proxy settings
- Subscription groups, custom names, and node management

### Build the Android APK

Requirements: Flutter 3.44 or later, JDK 21, and the Android SDK. From the project root, run:

```powershell
flutter pub get
flutter build apk --debug --split-per-abi --target-platform android-arm,android-arm64
```

APK files are written to `build/app/outputs/flutter-apk/`. Use your own signing key for release builds. Do not commit signing keys or `android/key.properties` to the repository.

### Project

- Author: ASwave
- Version: V1.0.0
- GitHub: [Hourglass-Proxy-Tools](https://github.com/2786256218/Hourglass-Proxy-Tools)

### License

This project is licensed under GPL-3.0-or-later. The `sing_box` plugin and bundled sing-box core are also subject to their respective licenses and copyright notices.
