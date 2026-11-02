// ignore_for_file: unused_catch_stack

import 'dart:io';
import 'dart:ui';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:app_installer/app_installer.dart';
import 'package:hourglass/app/local_services/vpn_service.dart';
import 'package:hourglass/app/modules/auto_update_manager.dart';
import 'package:hourglass/app/modules/setting_manager.dart';
import 'package:hourglass/app/utils/install_referrer_utils.dart';
import 'package:hourglass/app/utils/log.dart';
import 'package:hourglass/i18n/strings.g.dart';
import 'package:hourglass/screens/dialog_utils.dart';
import 'package:hourglass/screens/theme_config.dart';
import 'package:hourglass/screens/theme_define.dart';
import 'package:hourglass/screens/widgets/framework.dart';
import 'package:url_launcher/url_launcher.dart';

class VersionUpdateScreen extends LasyRenderingStatefulWidget {
  static bool _promptVisible = false;

  static RouteSettings routeSettings() {
    return const RouteSettings(name: "VersionUpdateScreen");
  }

  const VersionUpdateScreen({super.key});

  static Future<void> showUpdatePrompt(BuildContext context) async {
    final check = AutoUpdateManager.getVersionCheck();
    if (!check.newVersion || !context.mounted || _promptVisible) {
      return;
    }
    _promptVisible = true;
    try {
      final isChinese = Localizations.localeOf(context).languageCode == 'zh';
      final action = await showDialog<int>(
        context: context,
        barrierDismissible: true,
        builder: (dialogContext) => Dialog(
          backgroundColor: Colors.transparent,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(28),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 22, sigmaY: 22),
              child: Container(
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(
                  color: Theme.of(
                    dialogContext,
                  ).colorScheme.surface.withValues(alpha: 0.92),
                  borderRadius: BorderRadius.circular(28),
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.75),
                  ),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      isChinese ? '发现新版本' : 'Update available',
                      style: Theme.of(dialogContext).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 10),
                    Text(
                      isChinese
                          ? 'Hourglass ${check.version} 已发布。你可以现在下载更新，稍后再说，或查看 GitHub Release。'
                          : 'Hourglass ${check.version} is available. Download it now, dismiss this reminder, or view the GitHub release.',
                    ),
                    const SizedBox(height: 24),
                    Wrap(
                      alignment: WrapAlignment.end,
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        TextButton(
                          onPressed: () => Navigator.pop(dialogContext, 0),
                          child: Text(isChinese ? '取消' : 'Cancel'),
                        ),
                        OutlinedButton.icon(
                          onPressed: () => Navigator.pop(dialogContext, 2),
                          icon: const Icon(Icons.open_in_new, size: 18),
                          label: Text(isChinese ? '访问 GitHub' : 'Visit GitHub'),
                        ),
                        FilledButton(
                          onPressed: () => Navigator.pop(dialogContext, 1),
                          child: Text(isChinese ? '直接更新' : 'Update now'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      if (!context.mounted) {
        return;
      }
      if (action == 1) {
        await Navigator.push(
          context,
          MaterialPageRoute(
            settings: routeSettings(),
            builder: (context) => const VersionUpdateScreen(),
          ),
        );
      } else if (action == 2) {
        final releaseUrl = check.releaseUrl.isEmpty
            ? 'https://github.com/2786256218/Hourglass-Proxy-Tools/releases'
            : check.releaseUrl;
        await launchUrl(
          Uri.parse(releaseUrl),
          mode: LaunchMode.externalApplication,
        );
      }
    } finally {
      _promptVisible = false;
    }
  }

  @override
  State<VersionUpdateScreen> createState() => _VersionUpdateScreenState();
}

class _VersionUpdateScreenState
    extends LasyRenderingState<VersionUpdateScreen> {
  bool _installing = false;
  @override
  void initState() {
    super.initState();
  }

  @override
  void dispose() {
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tcontext = Translations.of(context);
    var checkVersion = AutoUpdateManager.getVersionCheck();

    return Scaffold(
      appBar: PreferredSize(preferredSize: Size.zero, child: AppBar()),
      body: Stack(
        children: [
          Container(
            margin: const EdgeInsets.only(top: 20, left: 20, right: 20),
            alignment: Alignment.center,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    if (Platform.isAndroid) ...[
                      FutureBuilder(
                        future: getAndroidInstallTips(),
                        builder:
                            (
                              BuildContext context,
                              AsyncSnapshot<Widget> snapshot,
                            ) {
                              return snapshot.data ?? SizedBox.shrink();
                            },
                      ),
                    ],
                    Text(
                      "${SettingManager.getConfig().autoUpdateChannel} ${tcontext.VersionUpdateScreen.versionReady(p: checkVersion.version)}",
                      style: const TextStyle(
                        fontSize: ThemeConfig.kFontSizeListItem,
                        fontWeight: ThemeConfig.kFontWeightListItem,
                        color: ThemeDefine.kColorBlue,
                      ),
                    ),
                    const SizedBox(height: 30),
                    Wrap(
                      alignment: WrapAlignment.center,
                      spacing: 12,
                      runSpacing: 12,
                      children: [
                        SizedBox(
                          height: 45,
                          child: FilledButton(
                            onPressed: _installing ? null : checkReplace,
                            child: _installing
                                ? const SizedBox(
                                    width: 22,
                                    height: 22,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : Text(
                                    Platform.isAndroid
                                        ? (Localizations.localeOf(
                                                    context,
                                                  ).languageCode ==
                                                  'zh'
                                              ? '下载并安装'
                                              : 'Download and install')
                                        : tcontext.VersionUpdateScreen.update,
                                  ),
                          ),
                        ),
                        OutlinedButton.icon(
                          onPressed: () => launchUrl(
                            Uri.parse(checkVersion.releaseUrl),
                            mode: LaunchMode.externalApplication,
                          ),
                          icon: const Icon(Icons.open_in_new, size: 18),
                          label: Text(
                            Localizations.localeOf(context).languageCode == 'zh'
                                ? '访问 GitHub'
                                : 'Visit GitHub',
                          ),
                        ),
                        TextButton(
                          onPressed: _installing
                              ? null
                              : () => Navigator.pop(context),
                          child: Text(tcontext.VersionUpdateScreen.cancel),
                        ),
                      ],
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<Widget> getAndroidInstallTips() async {
    if (SettingManager.getConfig().regionCode.toLowerCase() != "cn") {
      return SizedBox.shrink();
    }
    final List<ConnectivityResult> connectivityResult = await (Connectivity()
        .checkConnectivity());
    if (connectivityResult.contains(ConnectivityResult.none)) {
      return SizedBox.shrink();
    }
    if (!mounted) {
      return SizedBox.shrink();
    }
    final tcontext = Translations.of(context);
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text(
          tcontext.turnOffNetworkBeforeInstall,
          style: const TextStyle(
            fontSize: ThemeConfig.kFontSizeListItem,
            fontWeight: ThemeConfig.kFontWeightListItem,
            color: Colors.red,
          ),
        ),
        const SizedBox(height: 30),
      ],
    );
  }

  Future<void> checkReplace() async {
    if (_installing) {
      return;
    }
    _installing = true;
    setState(() {});
    try {
      String? installer = await AutoUpdateManager.checkReplace();
      if (installer == null && Platform.isAndroid) {
        await AutoUpdateManager.download(force: true);
        installer = await AutoUpdateManager.checkReplace();
      }
      if (!mounted) {
        return;
      }
      if (installer == null) {
        _installing = false;
        setState(() {});
        await DialogUtils.showAlertDialog(
          context,
          Localizations.localeOf(context).languageCode == 'zh'
              ? '无法下载更新包，请检查网络或访问 GitHub Releases 手动下载。'
              : 'The update package could not be downloaded. Check your network or download it from GitHub Releases.',
        );
        return;
      }
      await VPNService.stop();
      if (Platform.isWindows) {
        await launchUrl(Uri(path: installer, scheme: 'file'));
        await ServicesBinding.instance.exitApplication(AppExitType.required);
      } else if (Platform.isMacOS) {
        await launchUrl(Uri(path: installer, scheme: 'file'));
        await ServicesBinding.instance.exitApplication(AppExitType.required);
      } else if (Platform.isAndroid) {
        await AppInstaller.installApk(installer);
      } else if (Platform.isLinux) {
        if (!mounted) {
          return;
        }

        String? password = await DialogUtils.showPasswordInputDialog(context);
        if (password == null || password.isEmpty) {
          _installing = false;
          setState(() {});
          return;
        }
        final shell = Platform.environment['SHELL'] ?? 'bash';
        final arguments = ["-c"];
        final channelName = InstallReferrerUtils.getBuildChannelName();
        if (channelName.toLowerCase().contains("deb")) {
          arguments.add('echo "$password" | sudo -S dpkg -i "$installer"');
        } else if (channelName.toLowerCase().contains("rpm")) {
          arguments.add('echo "$password" | sudo -S rpm -i "$installer"');
        } else if (channelName.toLowerCase().contains("appimage")) {
          _installing = false;
          setState(() {});
          return;
        } else {
          arguments.add('echo "$password" | sudo -S dpkg -i "$installer"');
        }
        final result = await Process.run(shell, arguments);
        if (result.exitCode != 0) {
          if (!mounted) {
            _installing = false;
            setState(() {});
            return;
          }
          DialogUtils.showAlertDialog(
            context,
            "install $installer failed, exitCode: ${result.exitCode}",
            showCopy: true,
            showFAQ: true,
            withVersion: true,
          );
          _installing = false;
          setState(() {});
          return;
        }
        await ServicesBinding.instance.exitApplication(AppExitType.required);
      }
    } catch (err, stacktrace) {
      Log.w("VersionUpdateScreen.checkReplace exception ${err.toString()}");
      _installing = false;
      if (!mounted) {
        return;
      }
      DialogUtils.showExceptionDialog(context, err, stacktrace);
      setState(() {});
    }
    _installing = false;
    if (mounted) {
      setState(() {});
    }
  }
}
