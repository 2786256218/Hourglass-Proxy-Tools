# Hourglass

**Hourglass By ASwave · V1.0.0**

Hourglass 是一款面向 Android 的轻量代理工具，使用简洁的双线 H 标志和 Liquid Glass 风格界面。应用基于 sing-box 核心，帮助你集中管理订阅、节点与网络分流策略。

## 功能

- 支持在线 HTTPS 订阅、代理分享链接和本地 YAML、YML、YAM 配置文件
- 支持规则模式的系统代理和全局 TUN 代理
- 支持按应用、域名、IP 网段配置代理、直连和屏蔽规则
- 支持节点延迟测试、自动选择、局域网代理与住宅代理设置
- 订阅名称、节点选择和连接偏好保存在设备本地

## 构建 Android APK

需要 Flutter 3.44 或更高版本、JDK 21 和 Android SDK。克隆仓库后，在项目根目录执行：

```powershell
flutter pub get
flutter build apk --debug --split-per-abi --target-platform android-arm,android-arm64
```

APK 输出到 `build/app/outputs/flutter-apk/`。正式发布时请配置自己的签名密钥，并构建 release APK。不要把签名密钥或 `android/key.properties` 提交到仓库。

## 项目仓库

[github.com/2786256218/Hourglass-Proxy-Tools](https://github.com/2786256218/Hourglass-Proxy-Tools)

## 许可证

项目使用 GPL-3.0-or-later。`sing_box` 插件及随包使用的 sing-box 核心请一并遵守其许可证和版权声明。
