// ignore_for_file: unused_catch_stack, empty_catches

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:hourglass/app/local_services/vpn_service.dart';
import 'package:hourglass/app/modules/setting_manager.dart';
import 'package:hourglass/app/runtime/return_result.dart';
import 'package:hourglass/app/utils/app_lifecycle_state_notify.dart';
import 'package:hourglass/app/utils/app_utils.dart';
import 'package:hourglass/app/utils/crypto_utils.dart';
import 'package:hourglass/app/utils/download_utils.dart';
import 'package:hourglass/app/utils/file_utils.dart';
import 'package:hourglass/app/utils/install_referrer_utils.dart';
import 'package:hourglass/app/utils/log.dart';
import 'package:hourglass/app/utils/path_utils.dart';
import 'package:hourglass/app/utils/platform_utils.dart';
import 'package:hourglass/app/utils/version_compare_utils.dart';
import 'package:path/path.dart' as path;
import 'package:vpn_service/state.dart';

class AutoUpdateCheckVersion {
  String latestCheck = "";
  bool newVersion = false;
  String version = "";
  String url = "";
  String releaseUrl =
      "https://github.com/2786256218/Hourglass-Proxy-Tools/releases";

  String sha256 = "";
  Map<String, dynamic> toJson() => {
    'latest_check': latestCheck,
    'new_version': newVersion,
    "version": version,
    "url": url,
    "release_url": releaseUrl,
    "sha256": sha256,
  };
  void fromJson(Map<String, dynamic>? map) {
    if (map == null) {
      return;
    }
    latestCheck = map["latest_check"] ?? "";
    newVersion = map["new_version"] ?? "";
    version = map["version"] ?? "";
    url = map["url"] ?? "";
    releaseUrl = map["release_url"] ?? releaseUrl;
    sha256 = map["sha256"] ?? "";
  }

  static AutoUpdateCheckVersion fromJsonStatic(Map<String, dynamic>? map) {
    AutoUpdateCheckVersion config = AutoUpdateCheckVersion();
    config.fromJson(map);
    return config;
  }

  String getExtension() {
    String ext = path.extension(url);
    if (ext.isNotEmpty && ext.length <= ".AppImage".length) {
      return ext;
    }
    final channelName = InstallReferrerUtils.getBuildChannelName();
    if (Platform.isAndroid) {
      ext = ".apk";
    } else if (Platform.isWindows) {
      ext = ".exe";
    } else if (Platform.isMacOS) {
      ext = ".pkg";
    } else if (Platform.isLinux) {
      if (channelName.toLowerCase().contains("deb")) {
        ext = ".deb";
      } else if (channelName.toLowerCase().contains("rpm")) {
        ext = ".rpm";
      } else if (channelName.toLowerCase().contains("appimage")) {
        return "";
      }
    }
    return ext;
  }

  Future<String> getDownloadPath() async {
    String ext = getExtension();
    if (ext.isEmpty) {
      return "";
    }
    final newPath = path.join(await PathUtils.cacheDir(), version);
    return "$newPath$ext";
  }

  void clear() {
    latestCheck = "";
    newVersion = false;
    version = "";
    url = "";
    releaseUrl = "https://github.com/2786256218/Hourglass-Proxy-Tools/releases";
    sha256 = "";
  }
}

class AutoUpdateManager {
  static const String _releaseApiUrl =
      "https://api.github.com/repos/2786256218/Hourglass-Proxy-Tools/releases/latest";
  static const String _releasesPageUrl =
      "https://github.com/2786256218/Hourglass-Proxy-Tools/releases";
  static final List<void Function()> onEventCheck = [];
  static Timer? _timerChecker;
  static bool _checking = false;
  static final FileSaver _fileSaver = FileSaver();
  static bool _downloading = false;
  static Duration _duration = const Duration(hours: 3);
  static final AutoUpdateCheckVersion _versionCheck = AutoUpdateCheckVersion();

  static bool isSupport() {
    return Platform.isWindows ||
        Platform.isAndroid ||
        Platform.isMacOS ||
        Platform.isLinux;
  }

  static List<String> updateChannels() {
    return ["beta", "stable"];
  }

  static Future<void> init() async {
    _fileSaver.setSavePath(await PathUtils.autoUpdateFilePath());
    await load();
    String version = AppUtils.getBuildinVersion();

    if (VersionCompareUtils.compareVersion(
          _normalizeVersion(version),
          _normalizeVersion(_versionCheck.version),
        ) >=
        0) {
      if (_versionCheck.version.isNotEmpty) {
        if (isSupport()) {
          String downloadPath = await _versionCheck.getDownloadPath();
          if (downloadPath.isNotEmpty) {
            Future.delayed(const Duration(seconds: 10), () async {
              await FileUtils.deletePath(downloadPath);
            });
          }
        }
      }

      _versionCheck.clear();

      save();
    }
    VPNService.onEventStateChanged.add((
      FlutterVpnServiceState state,
      Map<String, String> params,
    ) async {
      if (state == FlutterVpnServiceState.connected) {
        Future.delayed(const Duration(seconds: 3), () async {
          _check();
        });
      }
    });
    AppLifecycleStateNofity.onStateResumed(null, () {
      Future.delayed(const Duration(seconds: 3), () async {
        _check();
      });
    });
    Future.delayed(const Duration(seconds: 3), () async {
      _check();
    });

    if (PlatformUtils.isPC()) {
      _timerChecker = Timer.periodic(const Duration(minutes: 30), (timer) {
        _check();
      });
    }
  }

  static Future<void> uninit() async {
    _timerChecker?.cancel();
    _timerChecker = null;
  }

  static void updateChannelChanged() {
    _versionCheck.clear();
    _check();
  }

  static AutoUpdateCheckVersion getVersionCheck() {
    return _versionCheck;
  }

  static Future<UpdateCheckStatus> checkNow({bool notify = true}) =>
      _check(force: true, notify: notify);

  static Future<void> load() async {
    String filePath = await PathUtils.autoUpdateFilePath();
    var file = File(filePath);
    bool exists = await file.exists();
    if (!exists) {
      return;
    }
    try {
      String content = await file.readAsString();
      if (content.isNotEmpty) {
        var config = jsonDecode(content);
        _versionCheck.fromJson(config);
      }
    } catch (err, stacktrace) {}
  }

  static Future<void> save() async {
    await _fileSaver.saveAsJson(_versionCheck);
  }

  static Future<String?> checkReplace() async {
    if (!isSupport()) {
      return null;
    }
    if (_versionCheck.version.isEmpty) {
      return null;
    }
    String version = AppUtils.getBuildinVersion();
    String downloadPath = await _versionCheck.getDownloadPath();
    if (downloadPath.isEmpty) {
      return null;
    }
    if (VersionCompareUtils.compareVersion(
          _normalizeVersion(version),
          _normalizeVersion(_versionCheck.version),
        ) <
        0) {
      var file = File(downloadPath);
      bool exist = await file.exists();
      if (exist) {
        await _sanitizeMacOSInstaller(downloadPath);
        return downloadPath;
      }
    }

    return null;
  }

  static Future<void> download({bool force = false}) async {
    if (!force && !SettingManager.getConfig().autoDownloadUpdatePkg) {
      return;
    }
    if (!isSupport()) {
      return;
    }
    if (PathUtils.portableMode()) {
      return;
    }
    if (_versionCheck.version.isEmpty || _versionCheck.url.isEmpty) {
      return;
    }
    if (_downloading && force) {
      for (var attempt = 0; attempt < 600 && _downloading; attempt++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }
    if (_downloading) {
      return;
    }
    List<int?> ports = [];
    if (SettingManager.getConfig().checkByProxy) {
      final started = await VPNService.getStarted();
      if (!started) {
        return;
      }
      ports = [SettingManager.getConfig().proxy.mixedForwardPort];
    } else {
      ports = await VPNService.getPortsByPrefer(true);
    }
    if (ports.isEmpty) {
      ports = [null];
    }
    String version = AppUtils.getBuildinVersion();
    if (VersionCompareUtils.compareVersion(
          _normalizeVersion(version),
          _normalizeVersion(_versionCheck.version),
        ) <
        0) {
      String downloadPath = await _versionCheck.getDownloadPath();
      if (downloadPath.isEmpty) {
        return;
      }
      if (await File(downloadPath).exists()) {
        return;
      }
      String dir = await PathUtils.cacheDir();
      final ext = _versionCheck.getExtension();
      if (ext.isEmpty) {
        return;
      }
      var files = FileUtils.recursionFile(dir, extensionFilter: {ext});
      for (var file in files) {
        await FileUtils.deletePath(file);
      }
      Uri? uri = Uri.tryParse(_versionCheck.url);
      if (uri == null) {
        return;
      }
      if (_downloading) {
        return;
      }
      _downloading = true;
      try {
        late ReturnResult<HttpHeaders> result;
        for (var port in ports) {
          result = await DownloadUtils.downloadWithPort(
            uri,
            downloadPath,
            null,
            false,
            port,
          );
          if (result.error == null) {
            break;
          }
        }

        if (result.error != null) {
          if (result.error!.message.contains("404")) {
            _versionCheck.newVersion = false;
            _versionCheck.version = "";
            _versionCheck.url = "";
            _versionCheck.sha256 = "";

            save();
          }
        }
        if (_versionCheck.sha256.isNotEmpty) {
          final hash = await CryptoUtils.getFileSha256(downloadPath);
          if (hash != null) {
            if (_versionCheck.sha256 != hash) {
              await FileUtils.deletePath(downloadPath);
            }
          }
        }
        await _sanitizeMacOSInstaller(downloadPath);
      } finally {
        _downloading = false;
      }
      Future.delayed(const Duration(milliseconds: 300), () async {
        for (var callback in onEventCheck) {
          callback();
        }
      });
    }
  }

  static Future<void> _sanitizeMacOSInstaller(String downloadPath) async {
    if (!Platform.isMacOS || downloadPath.isEmpty) {
      return;
    }
    final file = File(downloadPath);
    if (!await file.exists()) {
      return;
    }
    try {
      final clearResult = await Process.run("xattr", ["-c", downloadPath]);
      if (clearResult.exitCode == 0) {
        return;
      }
      Log.w(
        "AutoUpdateManager._sanitizeMacOSInstaller xattr -c failed, path=$downloadPath, exitCode=${clearResult.exitCode}, stderr=${clearResult.stderr.toString().trim()}",
      );

      final delQuarantine = await Process.run("xattr", [
        "-d",
        "com.apple.quarantine",
        downloadPath,
      ]);
      final delProvenance = await Process.run("xattr", [
        "-d",
        "com.apple.provenance",
        downloadPath,
      ]);
      if (delQuarantine.exitCode != 0 && delProvenance.exitCode != 0) {
        Log.w(
          "AutoUpdateManager._sanitizeMacOSInstaller fallback failed, path=$downloadPath, quarantineExit=${delQuarantine.exitCode}, provenanceExit=${delProvenance.exitCode}",
        );
      }
    } catch (err, _) {
      Log.w(
        "AutoUpdateManager._sanitizeMacOSInstaller exception ${err.toString()}",
      );
    }
  }

  static Future<UpdateCheckStatus> _check({
    bool force = false,
    bool notify = true,
  }) async {
    if (_checking) {
      for (var attempt = 0; attempt < 100 && _checking; attempt++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      return _checking
          ? UpdateCheckStatus.failed
          : (_versionCheck.newVersion
                ? UpdateCheckStatus.available
                : UpdateCheckStatus.upToDate);
    }
    if (SettingManager.getConfig().checkByProxy) {
      final started = await VPNService.getStarted();
      if (!started) {
        return UpdateCheckStatus.failed;
      }
      if (VPNService.currentIsDirect()) {
        return UpdateCheckStatus.failed;
      }
    }
    var last = DateTime.tryParse(_versionCheck.latestCheck);
    DateTime now = DateTime.now();
    if (!force && last != null) {
      Duration dur = now.difference(last);
      if (dur.inSeconds < _duration.inSeconds) {
        await download();
        return _versionCheck.newVersion
            ? UpdateCheckStatus.available
            : UpdateCheckStatus.upToDate;
      }
    }
    _versionCheck.latestCheck = now.toString();
    _checking = true;
    HttpClient? client;
    try {
      client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
      final request = await client.getUrl(Uri.parse(_releaseApiUrl));
      request.headers.set(
        HttpHeaders.acceptHeader,
        "application/vnd.github+json",
      );
      request.headers.set(HttpHeaders.userAgentHeader, "Hourglass-Proxy-Tools");
      final response = await request.close().timeout(
        const Duration(seconds: 20),
      );
      if (response.statusCode != HttpStatus.ok) {
        await response.drain<void>();
        client.close(force: true);
        _duration = const Duration(minutes: 10);
        await save();
        _checking = false;
        if (!force) {
          Future.delayed(_duration, () => _check());
        }
        return UpdateCheckStatus.failed;
      }
      final body = await response
          .transform(utf8.decoder)
          .join()
          .timeout(const Duration(seconds: 20));
      client.close();
      client = null;
      _duration = const Duration(hours: 3);
      final release = jsonDecode(body) as Map<String, dynamic>;
      final tag = (release["tag_name"] ?? "").toString().trim();
      final latestVersion = tag.replaceFirst(RegExp(r"^[vV]"), "");
      final releaseUrl = (release["html_url"] ?? _releasesPageUrl).toString();
      final currentVersion = AppUtils.getBuildinVersion();
      _versionCheck.newVersion =
          latestVersion.isNotEmpty &&
          VersionCompareUtils.compareVersion(
                _normalizeVersion(currentVersion),
                _normalizeVersion(latestVersion),
              ) <
              0;
      _versionCheck.version = _versionCheck.newVersion ? latestVersion : "";
      _versionCheck.releaseUrl = releaseUrl;
      _versionCheck.url = _versionCheck.newVersion
          ? _selectReleaseAsset(release)
          : "";
      _versionCheck.sha256 = "";

      await save();
      if (notify) {
        Future.delayed(const Duration(milliseconds: 300), () {
          for (final callback in onEventCheck) {
            callback();
          }
        });
      }
      await download();
      _checking = false;
      if (!force) {
        Future.delayed(_duration, () => _check());
      }
      return _versionCheck.newVersion
          ? UpdateCheckStatus.available
          : UpdateCheckStatus.upToDate;
    } catch (err, _) {
      client?.close(force: true);
      Log.w("AutoUpdateManager._check exception ${err.toString()}");
      _duration = const Duration(minutes: 10);
      _checking = false;
      await save();
      if (!force) {
        Future.delayed(_duration, () => _check());
      }
      return UpdateCheckStatus.failed;
    }
  }

  static String _selectReleaseAsset(Map<String, dynamic> release) {
    final assets = (release["assets"] as List<dynamic>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .toList();
    if (Platform.isAndroid) {
      final apkAssets = assets
          .where(
            (asset) =>
                (asset["name"] ?? "").toString().toLowerCase().endsWith(".apk"),
          )
          .toList();
      if (apkAssets.isEmpty) {
        return "";
      }
      final abis = VPNService.getABIs();
      for (final abi in abis) {
        final match = apkAssets.where(
          (asset) => (asset["name"] ?? "").toString().toLowerCase().contains(
            abi.toLowerCase(),
          ),
        );
        if (match.isNotEmpty) {
          return (match.first["browser_download_url"] ?? "").toString();
        }
      }
      final universal = apkAssets.where((asset) {
        final name = (asset["name"] ?? "").toString().toLowerCase();
        return name == "app-release.apk" ||
            name == "app-debug.apk" ||
            name == "hourglass.apk";
      });
      return universal.isEmpty
          ? ""
          : (universal.first["browser_download_url"] ?? "").toString();
    }
    return "";
  }

  static String _normalizeVersion(String version) {
    final value = version.trim().replaceFirst(RegExp(r"^[vV]"), "");
    final withoutBuild = value.split("+").first;
    final separator = withoutBuild.indexOf("-");
    final core = separator < 0
        ? withoutBuild
        : withoutBuild.substring(0, separator);
    final suffix = separator < 0 ? "" : withoutBuild.substring(separator);
    final parts = core.split(".");
    while (parts.length < 3) {
      parts.add("0");
    }
    return "${parts.join(".")}$suffix";
  }
}

enum UpdateCheckStatus { available, upToDate, failed }
