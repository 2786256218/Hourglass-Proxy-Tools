# Hourglass for Android

[项目文档](../README.md#中文) · [Project documentation](../README.md#english)

这里是 Hourglass 的 Flutter 项目目录。完整的功能介绍、技术栈、第三方依赖、libbox 配置和签名步骤见上方文档。

This directory is the Flutter project root. The main README covers features, the stack, third-party dependencies, libbox setup, and release signing.

## 快速构建 / Quick build

准备 Flutter 3.44+、Dart 3.12 至 4.0 之前、JDK 21、Android SDK Platform 36 和 Build Tools 36.0.0。在本目录运行以下命令。

Install Flutter 3.44+ with Dart 3.12 through 3.x, JDK 21, Android SDK Platform 36, and Build Tools 36.0.0. Run the following from this directory.

```sh
flutter pub get
flutter build apk --debug --split-per-abi --target-platform android-arm,android-arm64
```

APK 输出目录 / APK output directory `build/app/outputs/flutter-apk/`.

[完整构建说明](../README.md#构建-android-apk) · [Full build instructions](../README.md#build-the-android-apk) · [GPL-3.0-or-later](../LICENSE)
