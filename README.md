# Hourglass

[中文](#中文) | [English](#english)

## 中文

**Hourglass By ASwave · V1.27.45**

Hourglass 是一款面向 Android 的轻量代理工具，采用简洁的 Liquid Glass 风格界面，基于 sing-box 核心，帮助你管理订阅、节点和网络分流。

Android 端完整 Flutter 工程源码位于仓库的 [Android/](Android/) 目录。后续平台适配可在仓库根目录并列新增对应平台目录。

### 功能

- 支持 HTTPS 在线订阅、代理分享链接，以及本地 YAML、YML、YAM 配置文件
- 支持规则模式的系统代理和全局 TUN 代理
- 支持按应用、域名和 IP 网段配置代理、直连与屏蔽规则
- 支持节点延迟测试、自动选择、局域网代理和住宅代理设置
- 支持订阅分组、自定义名称及节点管理

### 构建 Android APK

需要 Flutter 3.44 或更高版本、JDK 21 和 Android SDK。在项目根目录执行：

```powershell
cd Android
flutter pub get
flutter build apk --release --split-per-abi
```

APK 输出在 `Android/build/app/outputs/flutter-apk/`。发布正式版本时请使用自己的签名密钥；不要将签名密钥或 `Android/android/key.properties` 上传到仓库。

### 项目信息

- 作者：ASwave
- 版本：V1.27.45
- GitHub：[Hourglass-Proxy-Tools](https://github.com/2786256218/Hourglass-Proxy-Tools)
- Android 源码：[Android/](Android/)

### 许可证

项目使用 GPL-3.0-or-later。`sing_box` 插件及随包使用的 sing-box 核心也受其各自许可证和版权声明约束。

## English

**Hourglass By ASwave · V1.27.45**

Hourglass is a lightweight Android proxy client with a clean Liquid Glass-inspired interface. Powered by the sing-box core, it helps you manage subscriptions, proxy nodes, and traffic routing.

The complete Android Flutter project is in the repository's [Android/](Android/) directory. Future platform adaptations can be added as sibling directories at the repository root.

### Features

- HTTPS subscription URLs, proxy share links, and local YAML, YML, or YAM configuration files
- Rule-based system proxy and global TUN modes
- Per-app, domain, and IP-range proxy, direct, and block rules
- Node latency tests, automatic selection, LAN proxy, and residential proxy settings
- Subscription groups, custom names, and node management

### Build the Android APK

Requirements: Flutter 3.44 or later, JDK 21, and the Android SDK. From the project root, run:

```powershell
cd Android
flutter pub get
flutter build apk --release --split-per-abi
```

APK files are written to `Android/build/app/outputs/flutter-apk/`. Use your own signing key for release builds. Do not commit signing keys or `Android/android/key.properties` to the repository.

### Project

- Author: ASwave
- Version: V1.27.45
- GitHub: [Hourglass-Proxy-Tools](https://github.com/2786256218/Hourglass-Proxy-Tools)
- Android source: [Android/](Android/)

### License

This project is licensed under GPL-3.0-or-later. The `sing_box` plugin and bundled sing-box core are also subject to their respective licenses and copyright notices.
