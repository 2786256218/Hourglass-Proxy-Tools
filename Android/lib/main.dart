import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui';
import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:sing_box/sing_box.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'subscription_support.dart';

const _ink = Color(0xFF14223A);
const _blue = Color(0xFF4E8DF5);
const _mint = Color(0xFF4BCDB0);
const _appVersion = '1.27.47';
const _repositoryUrl = 'https://github.com/2786256218/Hourglass-Proxy-Tools';
const _routingPrefsKey = 'hourglass.userRoutingRules.v1';
const _subscriptionGroupsPrefsKey = 'hourglass.subscriptionGroups.v1';
const _subscriptionNamesPrefsKey = 'hourglass.subscriptionNames.v1';
const _subscriptionSyncTimesPrefsKey = 'hourglass.subscriptionSyncTimes.v1';
const _overridePrefsKey = 'hourglass.configOverrides.v1';
const _geoRoutingPrefsKey = 'hourglass.subscriptionGeodata.v1';
const _probeResultsPrefsKey = 'hourglass.probeResults.v1';
const _directNetworkChannel = MethodChannel('sing_box');
const _installedAppsChannel = MethodChannel('hourglass.installed_apps');
const _localFilesChannel = MethodChannel('hourglass.local_files');
const _externalLinkChannel = MethodChannel('hourglass.external_links');
const _residentialProxyPrefsKey = 'hourglass.residentialProxy.v1';
const _autoSelectPrefsKey = 'hourglass.autoSelectEnabled.v1';
const _residentialProbeResultId = 'hourglass-residential-active';
const _protectedStorageChannel = MethodChannel('hourglass.secure_storage');
const _bundledRuleSetAssets = <String, String>{
  'geoip-cn': 'assets/datas/geoip/cn.srs',
  'geosite-cn': 'assets/datas/geosite/cn.srs',
  'geosite-category-ads-all': 'assets/datas/geosite/category-ads-all.srs',
};
bool _ruleSetUpdateRunning = false;

bool _isValidSrs(Uint8List bytes) =>
    bytes.length >= 4 &&
    bytes[0] == 0x53 &&
    bytes[1] == 0x52 &&
    bytes[2] == 0x53 &&
    // Upstream SagerNet rule sets currently use v1; bundled sets may use v2.
    (bytes[3] == 0x01 || bytes[3] == 0x02);

Future<bool> _isValidSrsFile(File file) async {
  if (!await file.exists() || await file.length() <= 32) return false;
  final handle = await file.open();
  try {
    return _isValidSrs(await handle.read(4));
  } finally {
    await handle.close();
  }
}

Future<Map<String, String>> _prepareLocalRuleSets(
  SingBox engine,
  Map<String, dynamic> config,
) async {
  try {
    return await _prepareLocalRuleSetsUnsafe(engine, config);
  } on Object {
    final route = config['route'] as Map?;
    if (route == null) return const {};
    final sets = route['rule_set'];
    if (sets is List) {
      route['rule_set'] = sets
          .where((item) => item is! Map || item['type'] != 'remote')
          .toList();
    }
    void dropRulesDependingOnRemoteSets(Map container) {
      final rules = container['rules'];
      if (rules is List) {
        container['rules'] = rules
            .where((item) => item is! Map || item['rule_set'] is! List)
            .toList();
      }
    }

    dropRulesDependingOnRemoteSets(route);
    final dns = config['dns'];
    if (dns is Map) dropRulesDependingOnRemoteSets(dns);
    return const {};
  }
}

Future<Map<String, String>> _prepareLocalRuleSetsUnsafe(
  SingBox engine,
  Map<String, dynamic> config,
) async {
  final ruleSets = (config['route'] as Map?)?['rule_set'];
  if (ruleSets is! List) return const {};
  final workDir = engine.runtimeInfo?.workingDirectory;
  final remoteUrls = <String, String>{};
  final availableTags = <String>{};
  if (workDir == null || workDir.isEmpty) {
    final route = config['route'] as Map?;
    route?['rule_set'] = ruleSets
        .where((item) => item is! Map || item['type'] != 'remote')
        .toList();
    final rules = route?['rules'];
    if (rules is List) {
      route!['rules'] = rules
          .where((item) => item is! Map || item['rule_set'] is! List)
          .toList();
    }
    return remoteUrls;
  }
  final moduleDir = Directory('$workDir${Platform.pathSeparator}rule-set');
  await moduleDir.create(recursive: true);
  final retained = <Map<String, dynamic>>[];
  for (final raw in ruleSets) {
    if (raw is! Map) continue;
    final item = Map<String, dynamic>.from(raw);
    if (item['type'] != 'remote') {
      retained.add(item);
      availableTags.add('${item['tag']}');
      continue;
    }
    final tag = (item['tag'] ?? '').toString();
    final url = (item['url'] ?? '').toString();
    if (tag.isEmpty) continue;
    if (url.startsWith('https://')) remoteUrls[tag] = url;
    final file = File('${moduleDir.path}${Platform.pathSeparator}$tag.srs');
    if (!await _isValidSrsFile(file)) {
      if (await file.exists()) await file.delete();
      final asset =
          _bundledRuleSetAssets[tag] ??
          _bundledRuleSetAssets.entries
              .where((entry) => tag.endsWith(entry.key))
              .map((entry) => entry.value)
              .firstOrNull;
      if (asset != null) {
        try {
          final bytes = (await rootBundle.load(asset)).buffer.asUint8List();
          await file.writeAsBytes(bytes, flush: true);
        } on Object {
          // The rule stays optional; a missing bundled asset must not block VPN.
        }
      }
    }
    if (await _isValidSrsFile(file)) {
      retained.add({
        'type': 'local',
        'tag': tag,
        'format': 'binary',
        'path': file.path,
      });
      availableTags.add(tag);
    }
  }
  (config['route'] as Map)['rule_set'] = retained;
  final route = config['route'] as Map;
  void sanitizeRuleSetReferences(Map container) {
    final rules = container['rules'];
    if (rules is! List) return;
    container['rules'] = rules
        .map((raw) {
          if (raw is! Map || raw['rule_set'] is! List) return raw;
          final updated = Map<String, dynamic>.from(raw);
          updated['rule_set'] = (raw['rule_set'] as List)
              .map((tag) => tag.toString())
              .where(availableTags.contains)
              .toList();
          return updated;
        })
        .where(
          (raw) =>
              raw is! Map ||
              raw['rule_set'] is! List ||
              (raw['rule_set'] as List).isNotEmpty,
        )
        .toList();
  }

  sanitizeRuleSetReferences(route);
  final dns = config['dns'];
  if (dns is Map) sanitizeRuleSetReferences(dns);
  return remoteUrls;
}

Uri? _ruleSetCdnMirror(Uri uri) {
  if (uri.host != 'raw.githubusercontent.com') return null;
  final segments = uri.pathSegments;
  if (segments.length < 4) return null;
  return Uri.https(
    'cdn.jsdelivr.net',
    '/gh/${segments[0]}/${segments[1]}@${segments[2]}/${segments.skip(3).join('/')}',
  );
}

Future<({int updated, int failed})> _updateRuleSetModules(
  Map<String, String> urls,
  String workingDirectory, {
  bool force = false,
}) async {
  if (_ruleSetUpdateRunning || urls.isEmpty) {
    return (updated: 0, failed: urls.length);
  }
  _ruleSetUpdateRunning = true;
  var updated = 0;
  var failed = 0;
  HttpClient? client;
  try {
    final preferences = await SharedPreferences.getInstance();
    final moduleDir = Directory(
      '$workingDirectory${Platform.pathSeparator}rule-set',
    );
    await moduleDir.create(recursive: true);
    client = HttpClient()..connectionTimeout = const Duration(seconds: 12);
    for (final entry in urls.entries) {
      final uri = Uri.tryParse(entry.value);
      if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) {
        failed++;
        continue;
      }
      final stampKey = 'hourglass.moduleUpdate.${entry.key}';
      final last = preferences.getInt(stampKey) ?? 0;
      if (!force &&
          DateTime.now().millisecondsSinceEpoch - last <
              const Duration(days: 7).inMilliseconds) {
        continue;
      }
      try {
        Uint8List? data;
        final urlsToTry = <Uri>{
          uri,
          if (_ruleSetCdnMirror(uri) case final mirror?) mirror,
        };
        for (final candidate in urlsToTry) {
          try {
            final request = await client
                .getUrl(candidate)
                .timeout(const Duration(seconds: 15));
            request.headers.set(HttpHeaders.userAgentHeader, 'Hourglass/0.1.0');
            request.headers.set(HttpHeaders.cacheControlHeader, 'no-cache');
            final response = await request.close().timeout(
              const Duration(seconds: 20),
            );
            if (response.statusCode < 200 || response.statusCode >= 300) {
              await response.drain<void>();
              continue;
            }
            final bytes = await response
                .fold<BytesBuilder>(
                  BytesBuilder(),
                  (builder, chunk) => builder..add(chunk),
                )
                .timeout(const Duration(seconds: 20));
            final candidateData = bytes.takeBytes();
            if (candidateData.length > 32 && _isValidSrs(candidateData)) {
              data = candidateData;
              break;
            }
          } on Object {
            // Try the next HTTPS source before treating the module as failed.
          }
        }
        if (data == null) {
          failed++;
          continue;
        }
        final target = File(
          '${moduleDir.path}${Platform.pathSeparator}${entry.key}.srs',
        );
        final temporary = File('${target.path}.download');
        await temporary.writeAsBytes(data, flush: true);
        final backup = File('${target.path}.previous');
        if (await backup.exists()) await backup.delete();
        if (await target.exists()) await target.rename(backup.path);
        try {
          await temporary.rename(target.path);
          if (await backup.exists()) await backup.delete();
        } on Object {
          if (!await target.exists() && await backup.exists()) {
            await backup.rename(target.path);
          }
          rethrow;
        }
        await preferences.setInt(
          stampKey,
          DateTime.now().millisecondsSinceEpoch,
        );
        updated++;
      } on Object {
        // Optional third-party data updates are silent and never affect startup.
        failed++;
      }
    }
  } on Object {
    // Module update failures must never escape into proxy startup.
  } finally {
    client?.close(force: true);
    _ruleSetUpdateRunning = false;
  }
  return (updated: updated, failed: failed);
}

Future<({int updated, int failed})> _downloadSubscriptionRuleModules(
  SingBox engine,
  List<Map<String, String>> geodataRules,
) async {
  final workDir = engine.runtimeInfo?.workingDirectory;
  if (workDir == null || workDir.isEmpty) {
    return (updated: 0, failed: geodataRules.length);
  }
  final urls = <String, String>{};
  for (final rule in geodataRules) {
    final type = rule['type']?.toUpperCase();
    final value = rule['value']?.trim().toLowerCase();
    if (value == null || value.isEmpty) continue;
    final template = switch (type) {
      'GEOIP' => engine.configOptions.geoipRuleSetUrl,
      'GEOSITE' => engine.configOptions.geositeRuleSetUrl,
      _ => null,
    };
    if (template == null || !template.contains('{tag}')) continue;
    final moduleTag = '${type == 'GEOSITE' ? 'geosite' : 'geoip'}-$value';
    final configTag = 'hourglass-$moduleTag'.replaceAll(
      RegExp(r'[^A-Za-z0-9_.-]'),
      '_',
    );
    urls[configTag] = template.replaceAll('{tag}', moduleTag);
  }
  if (urls.isEmpty) return (updated: 0, failed: 0);
  // Provider-specific geosite/geoip references are materialized at import
  // time, while their subscription endpoints are still known and reachable.
  return _updateRuleSetModules(urls, workDir, force: true);
}

Future<String?> _readProtectedString(String key) async {
  final preferences = await SharedPreferences.getInstance();
  if (Platform.isAndroid) {
    final protected = await _protectedStorageChannel.invokeMethod<String>(
      'read',
      {'key': key},
    );
    if (protected != null) {
      await preferences.remove(key);
      return protected;
    }
  }
  final legacy = preferences.getString(key);
  if (legacy != null) {
    if (Platform.isAndroid) {
      await _protectedStorageChannel.invokeMethod<void>('write', {
        'key': key,
        'value': legacy,
      });
      await preferences.remove(key);
    }
    return legacy;
  }
  return null;
}

Future<void> _writeProtectedString(String key, String value) async {
  final preferences = await SharedPreferences.getInstance();
  if (Platform.isAndroid) {
    await _protectedStorageChannel.invokeMethod<void>('write', {
      'key': key,
      'value': value,
    });
    await preferences.remove(key);
  } else {
    await preferences.setString(key, value);
  }
}

Future<void> _deleteProtectedString(String key) async {
  final preferences = await SharedPreferences.getInstance();
  if (Platform.isAndroid) {
    await _protectedStorageChannel.invokeMethod<void>('delete', {'key': key});
  }
  await preferences.remove(key);
}

const _residentialSiteTargets = <_ResidentialSiteTarget>[
  _ResidentialSiteTarget(
    id: 'github',
    title: 'GitHub',
    url: 'https://github.com/',
    groupTag: 'hourglass-check-github',
  ),
  _ResidentialSiteTarget(
    id: 'google',
    title: 'Google',
    url: 'https://www.google.com/generate_204',
    groupTag: 'hourglass-check-google',
  ),
  _ResidentialSiteTarget(
    id: 'youtube',
    title: 'YouTube',
    url: 'https://www.youtube.com/generate_204',
    groupTag: 'hourglass-check-youtube',
  ),
  _ResidentialSiteTarget(
    id: 'openai',
    title: 'OpenAI',
    url: 'https://chatgpt.com/',
    groupTag: 'hourglass-check-openai',
  ),
];

class _ResidentialSiteTarget {
  const _ResidentialSiteTarget({
    required this.id,
    required this.title,
    required this.url,
    required this.groupTag,
  });
  final String id, title, url, groupTag;
}

class _ResidentialSiteResult {
  const _ResidentialSiteResult({
    required this.success,
    this.timedOut = false,
    this.delayMs,
    this.detail,
  });
  final bool success, timedOut;
  final int? delayMs;
  final String? detail;
}

class _ResidentialProxySettings {
  const _ResidentialProxySettings({
    this.enabled = false,
    this.mode = 'direct',
    this.protocol = 'socks5',
    this.server = '',
    this.port = 1080,
    this.username = '',
    this.password = '',
  });

  final bool enabled;
  final String mode, protocol, server, username, password;
  final int port;

  factory _ResidentialProxySettings.fromMap(Map<dynamic, dynamic> map) =>
      _ResidentialProxySettings(
        enabled: map['enabled'] as bool? ?? false,
        mode: map['mode'] == 'chain' ? 'chain' : 'direct',
        protocol:
            const {
              'socks5',
              'socks4',
              'http',
              'https',
            }.contains(map['protocol'])
            ? map['protocol'] as String
            : 'socks5',
        server: map['server'] as String? ?? '',
        port: (map['port'] as num?)?.toInt() ?? 1080,
        username: map['username'] as String? ?? '',
        password: map['password'] as String? ?? '',
      );

  Map<String, dynamic> toMap() => {
    'enabled': enabled,
    'mode': mode,
    'protocol': protocol,
    'server': server,
    'port': port,
    'username': username,
    'password': password,
  };

  _ResidentialProxySettings copyWith({
    bool? enabled,
    String? mode,
    String? protocol,
    String? server,
    int? port,
    String? username,
    String? password,
  }) => _ResidentialProxySettings(
    enabled: enabled ?? this.enabled,
    mode: mode ?? this.mode,
    protocol: protocol ?? this.protocol,
    server: server ?? this.server,
    port: port ?? this.port,
    username: username ?? this.username,
    password: password ?? this.password,
  );
}

Future<_ResidentialProxySettings> _loadResidentialProxySettings() async {
  final raw = await _readProtectedString(_residentialProxyPrefsKey);
  if (raw == null) return const _ResidentialProxySettings();
  try {
    final decoded = jsonDecode(raw);
    return decoded is Map
        ? _ResidentialProxySettings.fromMap(decoded)
        : const _ResidentialProxySettings();
  } on Object {
    return const _ResidentialProxySettings();
  }
}

Future<Map<String, SingBoxPingResult>> _readProbeResults() async {
  final preferences = await SharedPreferences.getInstance();
  final raw = preferences.getString(_probeResultsPrefsKey);
  if (raw == null) return {};
  try {
    final decoded = jsonDecode(raw);
    if (decoded is Map) {
      return {
        for (final entry in decoded.entries)
          if (entry.value is Map)
            entry.key.toString(): _rejectSuspiciousNodeLatency(
              SingBoxPingResult.fromMap(entry.value as Map),
            ),
      };
    }
  } on Object {
    // Ignore corrupt or stale latency snapshots.
  }
  return {};
}

Future<void> _persistProbeResults(
  Map<String, SingBoxPingResult> results,
) async {
  final preferences = await SharedPreferences.getInstance();
  await preferences.setString(
    _probeResultsPrefsKey,
    jsonEncode({
      for (final entry in results.entries) entry.key: entry.value.toMap(),
    }),
  );
}

Future<List<Map<String, String>>> _loadGeodataRules() async {
  final raw = await _readProtectedString(_geoRoutingPrefsKey);
  if (raw == null) return const [];
  try {
    final decoded = jsonDecode(raw);
    if (decoded is Map) {
      return decoded.values
          .whereType<List>()
          .expand((items) => items)
          .whereType<Map>()
          .map((item) => item.map((key, value) => MapEntry('$key', '$value')))
          .toList();
    }
  } on Object {
    // Ignore malformed cached geodata rules.
  }
  return const [];
}

Future<void> _removeSubscriptionGeodata(String subscriptionId) async {
  final raw = await _readProtectedString(_geoRoutingPrefsKey);
  if (raw == null) return;
  try {
    final decoded = jsonDecode(raw);
    if (decoded is Map) {
      final remaining = Map<String, dynamic>.from(decoded)
        ..remove(subscriptionId);
      await _writeProtectedString(_geoRoutingPrefsKey, jsonEncode(remaining));
    }
  } on Object {
    await _deleteProtectedString(_geoRoutingPrefsKey);
  }
}

bool _isSubscriptionGroupId(String? id) =>
    id != null &&
    (id.startsWith('http://') ||
        id.startsWith('https://') ||
        id.startsWith('local-file:'));

String _subscriptionFallbackName(String id) {
  if (id.startsWith('local-file:')) return '本地 YAML 订阅';
  return Uri.tryParse(id)?.host ?? '订阅';
}

Future<Map<String, String>> _readSubscriptionNames() async {
  final raw = await _readProtectedString(_subscriptionNamesPrefsKey);
  if (raw == null) return {};
  try {
    final decoded = jsonDecode(raw);
    if (decoded is Map) {
      return decoded.map((key, value) => MapEntry('$key', '$value'));
    }
  } on Object {
    // Ignore invalid optional display names.
  }
  return {};
}

Future<void> _saveSubscriptionName(String id, String name) async {
  final names = await _readSubscriptionNames();
  final value = name.trim();
  if (value.isEmpty) {
    names.remove(id);
  } else {
    names[id] = value;
  }
  await _writeProtectedString(_subscriptionNamesPrefsKey, jsonEncode(names));
}

Future<Map<String, DateTime>> _readSubscriptionSyncTimes() async {
  final raw = await _readProtectedString(_subscriptionSyncTimesPrefsKey);
  if (raw == null) return {};
  try {
    final decoded = jsonDecode(raw);
    if (decoded is Map) {
      final syncTimes = <String, DateTime>{};
      for (final entry in decoded.entries) {
        final time = DateTime.tryParse('${entry.value}');
        if (time != null) syncTimes['${entry.key}'] = time.toLocal();
      }
      return syncTimes;
    }
  } on Object {
    // Ignore invalid optional synchronization metadata.
  }
  return {};
}

Future<void> _saveSubscriptionSyncTime(String id) async {
  final syncTimes = await _readSubscriptionSyncTimes();
  syncTimes[id] = DateTime.now();
  await _writeProtectedString(
    _subscriptionSyncTimesPrefsKey,
    jsonEncode({
      for (final entry in syncTimes.entries)
        entry.key: entry.value.toUtc().toIso8601String(),
    }),
  );
}

Future<void> _removeSubscriptionSyncTime(String id) async {
  final syncTimes = await _readSubscriptionSyncTimes();
  syncTimes.remove(id);
  await _writeProtectedString(
    _subscriptionSyncTimesPrefsKey,
    jsonEncode({
      for (final entry in syncTimes.entries)
        entry.key: entry.value.toUtc().toIso8601String(),
    }),
  );
}

String _formatSubscriptionSyncTime(DateTime? syncedAt) {
  if (syncedAt == null) return '未记录';
  final age = DateTime.now().difference(syncedAt);
  if (age < const Duration(hours: 1)) return '刚刚';
  if (age < const Duration(days: 2)) return '一天前';
  if (age < const Duration(days: 7)) return '最近';
  if (age < const Duration(days: 21)) return '半个月前';
  if (age < const Duration(days: 45)) return '一个月前';
  return '早期';
}

class _HourglassOverrides {
  const _HourglassOverrides({
    this.allowLan = false,
    this.ipv6Proxy = false,
    this.tunIpv6 = false,
    this.fakeIp = true,
    this.sniff = true,
    this.protocol = 'mixed',
    this.port = 7897,
    this.mtu = 1500,
    this.username = 'hourglass',
    this.password = '',
  });

  final bool allowLan, ipv6Proxy, tunIpv6, fakeIp, sniff;
  final String protocol, username, password;
  final int port, mtu;

  factory _HourglassOverrides.fromMap(Map<dynamic, dynamic> map) =>
      _HourglassOverrides(
        allowLan: map['allowLan'] as bool? ?? false,
        ipv6Proxy: map['ipv6Proxy'] as bool? ?? false,
        tunIpv6: map['tunIpv6'] as bool? ?? false,
        fakeIp: map['fakeIp'] as bool? ?? true,
        sniff: map['sniff'] as bool? ?? true,
        protocol: map['protocol'] as String? ?? 'mixed',
        port: (map['port'] as num?)?.toInt() ?? 7897,
        mtu: (map['mtu'] as num?)?.toInt() ?? 1500,
        username: map['username'] as String? ?? 'hourglass',
        password: map['password'] as String? ?? '',
      );

  Map<String, dynamic> toMap() => {
    'allowLan': allowLan,
    'ipv6Proxy': ipv6Proxy,
    'tunIpv6': tunIpv6,
    'fakeIp': fakeIp,
    'sniff': sniff,
    'protocol': protocol,
    'port': port,
    'mtu': mtu,
    'username': username,
    'password': password,
  };

  _HourglassOverrides copyWith({
    bool? allowLan,
    bool? ipv6Proxy,
    bool? tunIpv6,
    bool? fakeIp,
    bool? sniff,
    String? protocol,
    int? port,
    int? mtu,
    String? username,
    String? password,
  }) => _HourglassOverrides(
    allowLan: allowLan ?? this.allowLan,
    ipv6Proxy: ipv6Proxy ?? this.ipv6Proxy,
    tunIpv6: tunIpv6 ?? this.tunIpv6,
    fakeIp: fakeIp ?? this.fakeIp,
    sniff: sniff ?? this.sniff,
    protocol: protocol ?? this.protocol,
    port: port ?? this.port,
    mtu: mtu ?? this.mtu,
    username: username ?? this.username,
    password: password ?? this.password,
  );
}

Future<_HourglassOverrides> _loadOverrides() async {
  final raw = await _readProtectedString(_overridePrefsKey);
  if (raw == null) return const _HourglassOverrides();
  try {
    final decoded = jsonDecode(raw);
    if (decoded is Map) return _HourglassOverrides.fromMap(decoded);
  } on Object {
    // Ignore malformed override data and use safe defaults.
  }
  return const _HourglassOverrides();
}

Future<SingBoxRoutingRules> _loadUserRoutingRules(SingBox engine) async {
  final saved = await _readProtectedString(_routingPrefsKey);
  if (saved == null || saved.isEmpty) return engine.getRoutingRules();
  try {
    final decoded = jsonDecode(saved);
    if (decoded is Map) return SingBoxRoutingRules.fromMap(decoded);
  } on Object {
    // Recover from stale or malformed local preferences by using engine data.
  }
  return engine.getRoutingRules();
}

SingBoxRoutingRules _effectiveRoutingRules(
  SingBoxRoutingRules saved, {
  required bool globalTun,
}) => saved.copyWith(
  bypassCountries: globalTun ? const [] : const ['cn'],
  bypassLan: !globalTun && saved.bypassLan,
  bypassDomains: globalTun ? const [] : saved.bypassDomains,
  bypassSubnets: globalTun ? const [] : saved.bypassSubnets,
  bypassApps: globalTun ? const [] : saved.bypassApps,
  proxyApps: globalTun ? const [] : saved.proxyApps,
);

Future<void> _saveUserRoutingRules(
  SingBox engine,
  SingBoxRoutingRules rules, {
  required bool globalTun,
}) async {
  await _writeProtectedString(_routingPrefsKey, jsonEncode(rules.toMap()));
  await engine.saveRoutingRules(
    _effectiveRoutingRules(rules, globalTun: globalTun),
  );
}

class _SubscriptionInstallResult {
  const _SubscriptionInstallResult(this.servers, this.resources, this.warnings);
  final List<SingBoxServerConfig> servers;
  final int resources;
  final List<String> warnings;
}

Future<_SubscriptionInstallResult> _installSubscription(
  SingBox engine,
  String content, {
  required String subscriptionId,
  required bool globalTun,
  String? sourceUrl,
  SubscriptionDownloader? downloader,
}) async {
  final parsedLinks = SingBoxShareLink.parseSubscription(content);
  final clash = await parseClashSubscription(
    content,
    sourceUrl: sourceUrl,
    downloader: downloader,
  );
  if (parsedLinks.isEmpty && clash == null) {
    throw const FormatException('订阅格式不受支持，或内容中没有可用节点');
  }
  var downloadedRuleModules = 0;
  final ruleModuleWarnings = <String>[];
  if (clash == null) await _removeSubscriptionGeodata(subscriptionId);
  final existing = await engine.getServerConfigs();
  final oldGroup = existing
      .where((server) => server.subscriptionId == subscriptionId)
      .toList();
  final active = await engine.getActiveServerConfig();
  await engine.clearServerConfigs(subscriptionId: subscriptionId);
  List<SingBoxServerConfig> imported;
  if (clash != null) {
    imported = [];
    final host = Uri.tryParse(subscriptionId)?.host ?? 'clash';
    for (var index = 0; index < clash.outbounds.length; index++) {
      final outbound = clash.outbounds[index];
      final rawTag = (outbound['tag'] ?? 'node-${index + 1}').toString();
      final safeHost = host.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
      final safeTag = rawTag.replaceAll(RegExp(r'[^A-Za-z0-9_.-]'), '_');
      final server = SingBoxServerConfig.fromOutbound(
        outbound,
        id: 'sub_${safeHost}_${_stableId(subscriptionId)}_${index + 1}_$safeTag',
        name: rawTag,
        subscriptionId: subscriptionId,
      );
      if (await engine.addServerConfig(server)) imported.add(server);
    }
    final rawGeoRules = await _readProtectedString(_geoRoutingPrefsKey);
    final storedGeoRules = <String, dynamic>{};
    if (rawGeoRules != null) {
      try {
        final decoded = jsonDecode(rawGeoRules);
        if (decoded is Map)
          storedGeoRules.addAll(Map<String, dynamic>.from(decoded));
      } on Object {
        // Replace invalid stored geodata with the latest subscription data.
      }
    }
    if (clash.geodataRules.isEmpty) {
      storedGeoRules.remove(subscriptionId);
    } else {
      storedGeoRules[subscriptionId] = clash.geodataRules;
      final moduleResult = await _downloadSubscriptionRuleModules(
        engine,
        clash.geodataRules,
      );
      downloadedRuleModules = moduleResult.updated;
      if (moduleResult.failed > 0) {
        ruleModuleWarnings.add(
          '${moduleResult.failed} 个订阅规则模块未能在导入时下载；已保留现有本地文件，连接仍可继续。',
        );
      }
    }
    await _writeProtectedString(
      _geoRoutingPrefsKey,
      jsonEncode(storedGeoRules),
    );
    if (clash.bypassDomains.isNotEmpty ||
        clash.blockedDomains.isNotEmpty ||
        clash.bypassSubnets.isNotEmpty ||
        clash.bypassCountries.isNotEmpty) {
      final rules = await _loadUserRoutingRules(engine);
      await _saveUserRoutingRules(
        engine,
        rules.copyWith(
          bypassDomains: {
            ...rules.bypassDomains,
            ...clash.bypassDomains,
          }.toList(),
          blockedDomains: {
            ...rules.blockedDomains,
            ...clash.blockedDomains,
          }.toList(),
          bypassSubnets: {
            ...rules.bypassSubnets,
            ...clash.bypassSubnets,
          }.toList(),
          bypassCountries: {
            ...rules.bypassCountries,
            ...clash.bypassCountries,
          }.toList(),
        ),
        globalTun: globalTun,
      );
    }
  } else {
    imported = await engine.importServerConfigs(
      content,
      subscriptionId: subscriptionId,
    );
  }
  if (imported.isEmpty) throw const FormatException('订阅下载成功，但没有可用节点');
  final rawSavedGroups = await _readProtectedString(
    _subscriptionGroupsPrefsKey,
  );
  final savedGroups = <String, dynamic>{};
  if (rawSavedGroups != null) {
    try {
      final decoded = jsonDecode(rawSavedGroups);
      if (decoded is Map)
        savedGroups.addAll(Map<String, dynamic>.from(decoded));
    } on Object {
      // Replace invalid saved group metadata with the latest subscription data.
    }
  }
  if (clash == null || clash.proxyGroups.isEmpty) {
    savedGroups.remove(subscriptionId);
  } else {
    savedGroups[subscriptionId] = clash.proxyGroups;
  }
  await _writeProtectedString(
    _subscriptionGroupsPrefsKey,
    jsonEncode(savedGroups),
  );
  await _saveSubscriptionSyncTime(subscriptionId);
  if (active == null || oldGroup.any((server) => server.id == active.id)) {
    final replacement =
        imported
            .where(
              (server) =>
                  server.server == active?.server &&
                  server.port == active?.port,
            )
            .firstOrNull ??
        imported.first;
    await engine.setActiveServerConfig(replacement.id);
  }
  return _SubscriptionInstallResult(
    imported,
    (clash?.downloadedProviders ?? 0) + downloadedRuleModules,
    [...?clash?.warnings, ...ruleModuleWarnings],
  );
}

String _stableId(String value) {
  var hash = 0x811c9dc5;
  for (final codeUnit in value.codeUnits) {
    hash = ((hash ^ codeUnit) * 0x01000193) & 0xffffffff;
  }
  return hash.toRadixString(16);
}

const _githubLatestReleaseApi =
    'https://api.github.com/repos/2786256218/Hourglass-Proxy-Tools/releases/latest';
const _githubReleasesUrl =
    'https://github.com/2786256218/Hourglass-Proxy-Tools/releases';
bool _updatePromptVisible = false;
bool _startupUpdateCheckStarted = false;
Future<_GithubRelease?>? _pendingReleaseCheck;

class _GithubRelease {
  const _GithubRelease({
    required this.version,
    required this.releaseUrl,
    required this.apkUrl,
    required this.apkAssetName,
  });

  final String version;
  final String releaseUrl;
  final String? apkUrl;
  final String? apkAssetName;
}

Future<_GithubRelease?> _fetchLatestRelease() {
  final pending = _pendingReleaseCheck;
  if (pending != null) return pending;
  final check = _requestLatestRelease();
  _pendingReleaseCheck = check;
  return check.whenComplete(() => _pendingReleaseCheck = null);
}

Future<({String host, int port, String? username, String? password})?>
_activeUpdateProxy() async {
  final engine = SingBox.instance;
  if (!engine.isConnected) return null;
  try {
    final raw = await engine.getLastConfig();
    final config = raw == null ? null : jsonDecode(raw);
    if (config is! Map || config['inbounds'] is! List) return null;
    for (final rawInbound in config['inbounds'] as List) {
      if (rawInbound is! Map || rawInbound['tag'] != 'hourglass-update-proxy') {
        continue;
      }
      final host = (rawInbound['listen'] ?? '').toString();
      final port = rawInbound['listen_port'];
      if (!{'127.0.0.1', '::1', 'localhost'}.contains(host) ||
          port is! int ||
          port < 1 ||
          port > 65535) {
        return null;
      }
      final users = rawInbound['users'];
      final firstUser = users is List && users.isNotEmpty && users.first is Map
          ? users.first as Map
          : null;
      return (
        host: host,
        port: port,
        username: firstUser?['username']?.toString(),
        password: firstUser?['password']?.toString(),
      );
    }
  } on Object {
    // A saved tunnel without the local updater inbound keeps using the normal
    // network path; new connections add this private loopback proxy.
  }
  return null;
}

Future<void> _configureReleaseHttpClient(HttpClient client) async {
  final proxy = await _activeUpdateProxy();
  if (proxy == null) return;
  client.findProxy = (_) => 'PROXY ${proxy.host}:${proxy.port}';
  if (proxy.username?.isNotEmpty == true &&
      proxy.password?.isNotEmpty == true) {
    final credentials = HttpClientBasicCredentials(
      proxy.username!,
      proxy.password!,
    );
    for (final realm in const ['', 'sing-box']) {
      client.addProxyCredentials(proxy.host, proxy.port, realm, credentials);
    }
  }
}

Future<_GithubRelease?> _requestLatestRelease() async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 12);
  try {
    await _configureReleaseHttpClient(client);
    final request = await client
        .getUrl(Uri.parse(_githubLatestReleaseApi))
        .timeout(const Duration(seconds: 15));
    request.headers
      ..set(HttpHeaders.acceptHeader, 'application/vnd.github+json')
      ..set(HttpHeaders.userAgentHeader, 'Hourglass-Android/$_appVersion');
    final response = await request.close().timeout(const Duration(seconds: 15));
    if (response.statusCode != HttpStatus.ok) {
      throw HttpException('GitHub 返回状态码 ${response.statusCode}');
    }
    final body = await response
        .transform(utf8.decoder)
        .join()
        .timeout(const Duration(seconds: 15));
    final decoded = jsonDecode(body);
    if (decoded is! Map) throw const FormatException('Release 响应格式无效');
    final tag = (decoded['tag_name'] ?? '').toString().trim();
    final releaseCandidate = Uri.tryParse(
      (decoded['html_url'] ?? _githubReleasesUrl).toString(),
    );
    final releaseUrl =
        releaseCandidate != null &&
            releaseCandidate.scheme == 'https' &&
            releaseCandidate.host == 'github.com'
        ? releaseCandidate.toString()
        : _githubReleasesUrl;
    if (tag.isEmpty) throw const FormatException('Release 未提供版本号');
    final assets = decoded['assets'];
    final installedAbi = Platform.isAndroid
        ? await _externalLinkChannel.invokeMethod<String>('getInstalledAbi')
        : null;
    final expectedApkName = switch (installedAbi) {
      'arm64-v8a' => 'app-arm64-v8a-release.apk',
      'armeabi-v7a' => 'app-armeabi-v7a-release.apk',
      'x86_64' => 'app-x86_64-release.apk',
      _ => null,
    };
    String? apkUrl;
    String? apkAssetName;
    if (assets is List) {
      for (final asset in assets.whereType<Map>()) {
        final name = (asset['name'] ?? '').toString().toLowerCase();
        if (expectedApkName != null && name == expectedApkName) {
          apkUrl = asset['browser_download_url']?.toString();
          apkAssetName = name;
          break;
        }
      }
    }
    return _GithubRelease(
      version: tag.replaceFirst(RegExp(r'^[vV]'), ''),
      releaseUrl: releaseUrl,
      apkUrl: apkUrl,
      apkAssetName: apkAssetName,
    );
  } finally {
    client.close(force: true);
  }
}

bool _isNewerVersion(String candidate, String current) {
  List<int> parts(String version) => version
      .split(RegExp(r'[-+]'))
      .first
      .split('.')
      .map((part) => int.tryParse(part) ?? 0)
      .toList();
  final newer = parts(candidate);
  final installed = parts(current);
  for (var index = 0; index < max(newer.length, installed.length); index++) {
    final left = index < newer.length ? newer[index] : 0;
    final right = index < installed.length ? installed[index] : 0;
    if (left != right) return left > right;
  }
  return false;
}

Future<File> _downloadReleaseApk(
  _GithubRelease release, {
  void Function(int receivedBytes, int totalBytes)? onProgress,
}) async {
  final url = release.apkUrl;
  final uri = url == null ? null : Uri.tryParse(url);
  if (uri == null || uri.scheme != 'https' || uri.host != 'github.com') {
    throw const FormatException('此 Release 没有当前设备架构对应的 APK');
  }
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
  File? apkFile;
  var completed = false;
  try {
    await _configureReleaseHttpClient(client);
    final request = await client
        .getUrl(uri)
        .timeout(const Duration(seconds: 20));
    request.headers.set(HttpHeaders.userAgentHeader, 'Hourglass-Android');
    final response = await request.close().timeout(const Duration(seconds: 30));
    if (response.statusCode != HttpStatus.ok) {
      throw HttpException('APK 下载失败，状态码 ${response.statusCode}');
    }
    final totalBytes = response.contentLength > 0 ? response.contentLength : 0;
    if (totalBytes > 500 * 1024 * 1024) {
      throw const FormatException('更新包超过 500 MB');
    }
    final safeVersion = release.version.replaceAll(
      RegExp(r'[^A-Za-z0-9._-]'),
      '_',
    );
    final updateDirectory = await _externalLinkChannel.invokeMethod<String>(
      'getUpdateDirectory',
    );
    if (updateDirectory == null || updateDirectory.isEmpty) {
      throw const FileSystemException('无法获取应用更新缓存目录');
    }
    final file = File(
      '$updateDirectory${Platform.pathSeparator}hourglass-update-$safeVersion.apk',
    );
    apkFile = file;
    if (await file.exists()) await file.delete();
    final sink = file.openWrite();
    var size = 0;
    onProgress?.call(0, totalBytes);
    try {
      await for (final chunk in response.timeout(const Duration(seconds: 45))) {
        size += chunk.length;
        if (size > 500 * 1024 * 1024) {
          throw const FormatException('更新包超过 500 MB');
        }
        sink.add(chunk);
        onProgress?.call(size, totalBytes);
      }
      await sink.flush();
    } finally {
      await sink.close();
    }
    if (size == 0 || size < 64 * 1024) {
      throw const FormatException('下载文件过小，GitHub 可能未返回 APK');
    }
    if (totalBytes > 0 && size != totalBytes) {
      throw HttpException('APK 下载不完整（$size/$totalBytes 字节）');
    }
    final handle = await file.open();
    try {
      final header = await handle.read(4);
      if (header.length < 4 ||
          header[0] != 0x50 ||
          header[1] != 0x4B ||
          header[2] != 0x03 ||
          header[3] != 0x04) {
        throw const FormatException('GitHub 返回的文件不是有效 APK');
      }
    } finally {
      await handle.close();
    }
    completed = true;
    return file;
  } finally {
    client.close(force: true);
    if (!completed && apkFile != null && await apkFile.exists()) {
      await apkFile.delete();
    }
  }
}

String _friendlyUpdateError(Object error) => error
    .toString()
    .replaceFirst('Exception: ', '')
    .replaceFirst('HttpException: ', '');

Future<void> _downloadAndInstallRelease(
  BuildContext context,
  _GithubRelease release,
) async {
  if (!Platform.isAndroid) {
    _showGlassNotice(context, '直接安装目前仅支持 Android');
    return;
  }
  var progressShown = false;
  var receivedBytes = 0;
  var totalBytes = 0;
  var lastProgressBytes = 0;
  var lastProgressPercent = -1;
  var lastProgressUpdate = DateTime.fromMillisecondsSinceEpoch(0);
  StateSetter? updateProgressDialog;
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (dialogContext) => StatefulBuilder(
      builder: (dialogContext, setDialogState) {
        updateProgressDialog = setDialogState;
        final progress = totalBytes > 0
            ? (receivedBytes / totalBytes).clamp(0.0, 1.0)
            : null;
        String formatMegabytes(int value) =>
            '${(value / (1024 * 1024)).toStringAsFixed(1)} MB';
        return Dialog(
          backgroundColor: Colors.transparent,
          child: _Glass(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('正在下载 Hourglass ${release.version}…'),
                const SizedBox(height: 16),
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: LinearProgressIndicator(value: progress, minHeight: 8),
                ),
                const SizedBox(height: 10),
                Text(
                  totalBytes > 0
                      ? '${formatMegabytes(receivedBytes)} / ${formatMegabytes(totalBytes)}'
                      : '${formatMegabytes(receivedBytes)} 已下载',
                  style: const TextStyle(
                    color: Color(0xFF64758C),
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    ),
  );
  progressShown = true;
  try {
    final apk = await _downloadReleaseApk(
      release,
      onProgress: (received, total) {
        receivedBytes = received;
        totalBytes = total;
        final now = DateTime.now();
        final percent = total > 0 ? received * 100 ~/ total : -1;
        final shouldUpdate =
            (total > 0 && percent != lastProgressPercent) ||
            received - lastProgressBytes >= 512 * 1024 ||
            (received == total && total > 0) ||
            now.difference(lastProgressUpdate) >=
                const Duration(milliseconds: 250);
        if (shouldUpdate) {
          lastProgressBytes = received;
          lastProgressPercent = percent;
          lastProgressUpdate = now;
          if (context.mounted) updateProgressDialog?.call(() {});
        }
      },
    );
    if (!context.mounted) return;
    if (progressShown) Navigator.of(context, rootNavigator: true).pop();
    progressShown = false;
    await _externalLinkChannel.invokeMethod<bool>('installApk', {
      'path': apk.path,
    });
  } on Object catch (error) {
    if (!context.mounted) return;
    if (progressShown) Navigator.of(context, rootNavigator: true).pop();
    _showGlassNotice(context, '更新失败：${_friendlyUpdateError(error)}');
  }
}

Future<void> _showReleaseUpdateDialog(
  BuildContext context,
  _GithubRelease release,
) async {
  if (!context.mounted || _updatePromptVisible) return;
  _updatePromptVisible = true;
  try {
    final action = await showDialog<int>(
      context: context,
      barrierDismissible: true,
      builder: (dialogContext) => Dialog(
        backgroundColor: Colors.transparent,
        child: _Glass(
          padding: const EdgeInsets.all(22),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '发现新版本',
                style: TextStyle(
                  color: _ink,
                  fontSize: 19,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 9),
              Text(
                'Hourglass ${release.version} 已发布。将下载适用于当前设备的 ${release.apkAssetName ?? 'APK'}。',
                style: const TextStyle(color: Color(0xFF64758C), height: 1.5),
              ),
              const SizedBox(height: 20),
              Row(
                children: [
                  Expanded(
                    child: TextButton(
                      onPressed: () => Navigator.pop(dialogContext, 0),
                      child: const Text('取消'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => Navigator.pop(dialogContext, 2),
                      icon: const Icon(Icons.open_in_new_rounded, size: 16),
                      label: const Text('访问 GitHub'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: release.apkUrl == null
                      ? null
                      : () => Navigator.pop(dialogContext, 1),
                  icon: const Icon(Icons.download_rounded, size: 18),
                  label: const Text('立即下载并安装'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (!context.mounted) return;
    if (action == 1) {
      await _downloadAndInstallRelease(context, release);
    } else if (action == 2) {
      await _externalLinkChannel.invokeMethod<bool>('openUrl', {
        'url': release.releaseUrl,
      });
    }
  } finally {
    _updatePromptVisible = false;
  }
}

Future<void> _checkForAppUpdate(
  BuildContext context, {
  required bool showUpToDate,
}) async {
  try {
    final release = await _fetchLatestRelease();
    if (!context.mounted || release == null) return;
    if (release.apkUrl != null &&
        _isNewerVersion(release.version, _appVersion)) {
      await _showReleaseUpdateDialog(context, release);
    } else if (showUpToDate) {
      _showGlassNotice(context, '当前已是最新版本');
    }
  } on Object catch (error) {
    if (showUpToDate && context.mounted) {
      _showGlassNotice(context, '检查更新失败：${_friendlyUpdateError(error)}');
    }
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const HourglassApp());
}

class HourglassApp extends StatelessWidget {
  const HourglassApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Hourglass',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      useMaterial3: true,
      brightness: Brightness.light,
      scaffoldBackgroundColor: const Color(0xFFF0F5FC),
      colorScheme: ColorScheme.fromSeed(seedColor: _blue),
      fontFamily: 'sans-serif',
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: Colors.white.withValues(alpha: .68),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(18),
          borderSide: BorderSide.none,
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 18,
          vertical: 16,
        ),
      ),
    ),
    home: const ProxyHomePage(),
  );
}

class ProxyHomePage extends StatefulWidget {
  const ProxyHomePage({super.key});

  @override
  State<ProxyHomePage> createState() => _ProxyHomePageState();
}

class _ProxyHomePageState extends State<ProxyHomePage>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  final _engine = SingBox.instance;
  final _scrollController = ScrollController();
  late final AnimationController _tabAnimationController;
  double _tabEntryDirection = 0;
  List<SingBoxServerConfig> _servers = const [];
  SingBoxConnectionState _connection = SingBoxConnectionState.initial;
  SingBoxConnectionStats _stats = SingBoxConnectionStats.empty;
  String? _activeId;
  String? _bootError;
  bool _ready = false;
  bool _busy = false;
  bool _globalTun = false;
  _HourglassOverrides _overrides = const _HourglassOverrides();
  _ResidentialProxySettings _residential = const _ResidentialProxySettings();
  final Map<String, SingBoxPingResult> _probeResults = {};
  SingBoxPingResult? _liveGraphLatency;
  Map<String, String> _subscriptionNames = {};
  Map<String, DateTime> _subscriptionSyncTimes = {};
  final Set<String> _testingIds = {};

  final List<double> _downloadHistory = [];
  final List<double> _uploadHistory = [];
  final List<double> _latencyHistory = [];
  String? _graphLatencyServerId;
  DateTime? _lastGraphLatencySampleAt;
  bool _graphLatencySampling = false;
  bool _testingAvailability = false;
  bool _testingAll = false;
  bool _autoSelectEnabled = false;
  bool _savingAutoSelect = false;
  bool _autoSelecting = false;
  Timer? _autoSelectTimer;
  DateTime? _lastAutoSelectionAt;
  DateTime? _lastStatsUiAt;
  DateTime? _lastTrafficTotalsSampleAt;
  int? _lastDownloadTotal;
  int? _lastUploadTotal;
  int _tabIndex = 0;
  StreamSubscription<SingBoxConnectionState>? _stateSub;
  StreamSubscription<SingBoxConnectionStats>? _statsSub;
  StreamSubscription<List<SingBoxOutboundGroup>>? _groupsSub;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _tabAnimationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 260),
      value: 1,
    );
    _initialize();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !_startupUpdateCheckStarted) {
        _startupUpdateCheckStarted = true;
        unawaited(_checkForAppUpdate(context, showUpToDate: false));
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _syncStatsSubscription();
      final last = _lastAutoSelectionAt;
      _syncAutoSelectTimer(
        runNow:
            _autoSelectEnabled &&
            (last == null ||
                DateTime.now().difference(last) >= const Duration(minutes: 15)),
      );
    } else {
      _syncStatsSubscription();
      _autoSelectTimer?.cancel();
      _autoSelectTimer = null;
    }
  }

  void _changeTabInstant(int index) {
    _tabAnimationController.stop();
    _tabAnimationController.value = 1;
    _tabEntryDirection = 0;
    setState(() => _tabIndex = index);
    _syncStatsSubscription();
  }

  void _changeTabBySwipe(int index, double direction) {
    _tabEntryDirection = direction;
    setState(() => _tabIndex = index);
    _syncStatsSubscription();
    _tabAnimationController.forward(from: 0);
  }

  Future<void> _initialize() async {
    try {
      _probeResults.addAll(await _readProbeResults());
      _subscriptionNames = await _readSubscriptionNames();
      _subscriptionSyncTimes = await _readSubscriptionSyncTimes();
      _overrides = await _loadOverrides();
      _residential = await _loadResidentialProxySettings();
      _autoSelectEnabled =
          (await _readProtectedString(_autoSelectPrefsKey)) == 'true';
      _applyOverridesToEngine();
      await _engine.initialize();
      final savedRules = await _engine.getRoutingRules();
      final values = await Future.wait([
        _engine.getServerConfigs(),
        _engine.getActiveServerConfig(),
        _engine.watchConnectionState().first,
      ]);
      if (!mounted) return;
      setState(() {
        _servers = values[0] as List<SingBoxServerConfig>;
        _activeId = (values[1] as SingBoxServerConfig?)?.id;
        _connection = values[2] as SingBoxConnectionState;
        _globalTun =
            !savedRules.bypassCountries.contains('cn') && !savedRules.bypassLan;
        _ready = true;
      });
      _stateSub = _engine.watchConnectionState().listen((state) {
        final wasConnected =
            _connection.status == SingBoxConnectionStatus.connected;
        if (mounted) {
          setState(() {
            _connection = state;
            if (state.status == SingBoxConnectionStatus.disconnected) {
              _latencyHistory.clear();
              _liveGraphLatency = null;
              _lastGraphLatencySampleAt = null;
              _graphLatencyServerId = null;
            }
          });
        }
        _syncStatsSubscription();
        if (!wasConnected &&
            state.status == SingBoxConnectionStatus.connected &&
            _autoSelectEnabled) {
          unawaited(_runAutoSelectionProbe());
        }
      });
      _syncStatsSubscription();
      _groupsSub = _engine.watchGroups().listen((groups) {
        final selectedTag = groups
            .where((group) => group.selectable)
            .map((group) => group.selected)
            .where((tag) => tag.isNotEmpty)
            .firstOrNull;
        if (selectedTag == null) return;
        final profile = _servers
            .where((item) => item.name == selectedTag)
            .firstOrNull;
        if (profile != null && profile.id != _activeId) {
          if (mounted) setState(() => _activeId = profile.id);
          unawaited(_engine.setActiveServerConfig(profile.id));
        }
      });
      await _reloadServers();
      _syncAutoSelectTimer(
        runNow: _connection.status == SingBoxConnectionStatus.connected,
      );
      if (_overrides.allowLan && _connection.status.isActive) {
        final active = _servers
            .where((server) => server.id == _activeId)
            .firstOrNull;
        if (active != null) {
          try {
            await _connectProfile(active);
          } on Object catch (error) {
            if (mounted)
              setState(() => _bootError = '局域网代理启动失败：${_friendlyError(error)}');
          }
        }
      }
    } on Object catch (error) {
      if (mounted)
        setState(() {
          _bootError = _friendlyError(error);
          _ready = true;
        });
    }
  }

  /// The native status stream polls the VPN core once per second. Keep it
  /// attached only while the connected home dashboard is visible.
  void _syncStatsSubscription() {
    final shouldListen =
        mounted &&
        _tabIndex == 0 &&
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed &&
        _connection.status == SingBoxConnectionStatus.connected;
    if (!shouldListen) {
      _statsSub?.cancel();
      _statsSub = null;
      return;
    }
    if (_statsSub != null) return;
    _statsSub = _engine.watchConnectionStats().listen(_onConnectionStats);
  }

  Future<void> _restartStatsSubscription() async {
    final subscription = _statsSub;
    _statsSub = null;
    await subscription?.cancel();
    _lastStatsUiAt = null;
    _lastTrafficTotalsSampleAt = null;
    _lastDownloadTotal = null;
    _lastUploadTotal = null;
    _syncStatsSubscription();
  }

  void _onConnectionStats(SingBoxConnectionStats stats) {
    // URL availability probes can temporarily reset the core's reported
    // instantaneous rates. Keep the last dashboard sample during the probe;
    // the status channel is restarted after it completes.
    if (_testingAvailability) return;
    final now = DateTime.now();
    // Follow the native half-second status cadence for responsive traffic data.
    if (_lastStatsUiAt != null &&
        now.difference(_lastStatsUiAt!) < const Duration(milliseconds: 400)) {
      return;
    }
    _lastStatsUiAt = now;
    final previousAt = _lastTrafficTotalsSampleAt;
    final previousDownload = _lastDownloadTotal;
    final previousUpload = _lastUploadTotal;
    final elapsed = previousAt == null
        ? null
        : now.difference(previousAt).inMilliseconds / 1000;
    final hasUsableDelta =
        elapsed != null &&
        elapsed >= .35 &&
        elapsed <= 3 &&
        previousDownload != null &&
        previousUpload != null &&
        stats.downloadTotal >= previousDownload &&
        stats.uploadTotal >= previousUpload;
    final measuredStats = hasUsableDelta
        ? stats.copyWith(
            downloadSpeed:
                ((stats.downloadTotal - previousDownload!) / elapsed!).round(),
            uploadSpeed: ((stats.uploadTotal - previousUpload!) / elapsed!)
                .round(),
          )
        : stats;
    _stats = measuredStats;
    _lastTrafficTotalsSampleAt = now;
    _lastDownloadTotal = stats.downloadTotal;
    _lastUploadTotal = stats.uploadTotal;
    final active = _servers
        .where((server) => server.id == _activeId)
        .firstOrNull;
    if (_graphLatencyServerId != active?.id) {
      _graphLatencyServerId = active?.id;
      _lastGraphLatencySampleAt = null;
      _latencyHistory.clear();
      _liveGraphLatency = null;
    }
    final homeRouteVisible =
        mounted && (ModalRoute.of(context)?.isCurrent ?? true);
    final shouldSampleLatency =
        active != null &&
        (_lastGraphLatencySampleAt == null ||
            now.difference(_lastGraphLatencySampleAt!) >=
                const Duration(minutes: 1));
    if (shouldSampleLatency &&
        _connection.status == SingBoxConnectionStatus.connected &&
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed &&
        homeRouteVisible &&
        !_graphLatencySampling &&
        !_testingAvailability &&
        _testingIds.isEmpty &&
        !_busy &&
        !_autoSelecting) {
      _lastGraphLatencySampleAt = now;
      unawaited(_sampleGraphLatency(active));
    }
    if (mounted) {
      setState(() {
        _appendSample(_downloadHistory, measuredStats.downloadSpeed.toDouble());
        _appendSample(_uploadHistory, measuredStats.uploadSpeed.toDouble());
      });
    }
  }

  Future<void> _reloadServers() async {
    final servers = await _engine.getServerConfigs();
    final active = await _engine.getActiveServerConfig();
    final savedProbeResults = await _readProbeResults();
    final subscriptionNames = await _readSubscriptionNames();
    final subscriptionSyncTimes = await _readSubscriptionSyncTimes();
    for (final server in servers.where(_isLoopbackProfile)) {
      savedProbeResults[server.id] = SingBoxPingResult.failure(
        '无效节点：服务器地址是本机回环地址',
        address: server.server,
        tag: server.name,
        serverId: server.id,
      );
    }
    unawaited(_persistProbeResults(savedProbeResults));
    if (!mounted) return;
    setState(() {
      _servers = servers;
      _activeId = active?.id;
      _subscriptionNames = subscriptionNames;
      _subscriptionSyncTimes = subscriptionSyncTimes;
      _probeResults.addAll(savedProbeResults);
    });
  }

  Future<void> _sampleGraphLatency(SingBoxServerConfig server) async {
    if (_graphLatencySampling) return;
    _graphLatencySampling = true;
    try {
      if (_activeId != server.id ||
          _connection.status != SingBoxConnectionStatus.connected) {
        return;
      }
      final result = _rejectSuspiciousNodeLatency(
        await _directTcpPing(server, const Duration(seconds: 5)),
      );
      if (!mounted ||
          _activeId != server.id ||
          _connection.status != SingBoxConnectionStatus.connected) {
        return;
      }
      setState(() {
        _liveGraphLatency = result;
        if (result.success) {
          _appendSample(_latencyHistory, result.ping.toDouble());
        }
      });
    } on Object {
      if (mounted) {
        setState(() {
          _liveGraphLatency = null;
        });
      }
    } finally {
      _graphLatencySampling = false;
    }
  }

  Future<SubscriptionHttpResponse> _downloadSubscriptionWithFallback(
    String url, {
    SubscriptionBodyValidator? validate,
  }) async {
    try {
      return await downloadSubscription(
        url,
        validate: validate,
        maxAttempts: 2,
        timeout: const Duration(seconds: 18),
      );
    } on SubscriptionDownloadException catch (initialError) {
      if (!initialError.retryable) rethrow;
      var lastError = initialError;
      final wasConnected = (await _engine.getConnectionStatus()).isActive;
      final original = await _engine.getActiveServerConfig();
      final candidates =
          _servers
              .where((server) => server.enabled && !_isLoopbackProfile(server))
              .toList()
            ..sort((a, b) {
              if (a.id == original?.id) return -1;
              if (b.id == original?.id) return 1;
              final ar = _probeResults[a.id];
              final br = _probeResults[b.id];
              if (ar?.success == true && br?.success != true) return -1;
              if (br?.success == true && ar?.success != true) return 1;
              return (ar?.ping ?? 1 << 30).compareTo(br?.ping ?? 1 << 30);
            });
      if (candidates.isEmpty) rethrow;

      try {
        for (final server in candidates) {
          try {
            _notice(
              '订阅直连超时，尝试通过节点「${server.name}」重试…',
              duration: const Duration(minutes: 2),
            );
            await _connectProfile(server);
            return await downloadSubscription(
              url,
              validate: validate,
              maxAttempts: 3,
              timeout: const Duration(seconds: 25),
            );
          } on SubscriptionDownloadException catch (error) {
            lastError = error;
            if (!error.retryable) break;
          } on Object catch (error) {
            lastError = SubscriptionDownloadException(
              '通过节点「${server.name}」重试订阅失败：$error',
              retryable: true,
            );
          }
        }
      } finally {
        try {
          if (wasConnected && original != null) {
            await _connectProfile(original);
          } else {
            if ((await _engine.getConnectionStatus()).isActive) {
              await _engine.disconnect();
            }
            if (original != null)
              await _engine.setActiveServerConfig(original.id);
          }
        } on Object {
          // Keep the import error as the primary failure; the proxy can be reconnected manually.
        }
      }
      throw SubscriptionDownloadException(
        '直连超时，并已尝试通过 ${candidates.length} 个节点重试：$lastError',
        retryable: false,
      );
    }
  }

  Future<void> _testProfiles(
    Iterable<SingBoxServerConfig> profiles, {
    String? label,
  }) async {
    final targets = profiles.where((server) => server.enabled).toList();
    if (targets.isEmpty ||
        _testingAll ||
        targets.any((server) => _testingIds.contains(server.id)))
      return;
    final validTargets = targets
        .where((server) => !_isLoopbackProfile(server))
        .toList();
    final invalidTargets = targets.where(_isLoopbackProfile).toList();
    final ids = targets.map((server) => server.id).toSet();
    setState(() {
      _testingIds.addAll(ids);
      _testingAll = label == '全部订阅';
      for (final id in ids) {
        _probeResults.remove(id);
      }
      for (final server in invalidTargets) {
        _probeResults[server.id] = SingBoxPingResult.failure(
          '无效节点：服务器地址是本机回环地址',
          address: server.server,
          tag: server.name,
          serverId: server.id,
        );
      }
    });
    _notice('正在通过设备当前网络直连测试节点 TCP 延迟…', duration: const Duration(minutes: 2));
    try {
      await for (final result in Stream.fromFutures(
        validTargets.map(
          (server) => _directTcpPing(server, const Duration(seconds: 7)),
        ),
      )) {
        if (!mounted) return;
        setState(
          () => _probeResults[result.serverId!] = _rejectSuspiciousNodeLatency(
            result,
          ),
        );
      }
      await _persistProbeResults(_probeResults);
      final alive = targets
          .where((server) => _probeResults[server.id]?.success == true)
          .length;
      if (mounted)
        _notice(
          '直连 TCP 延迟测试完成：$alive/${targets.length} 个节点可连接；网站可用性请连接 VPN 后单独测试',
        );
    } on Object catch (error) {
      if (mounted) _notice(_friendlyError(error));
    } finally {
      if (mounted)
        setState(() {
          _testingIds.removeAll(ids);
          _testingAll = false;
        });
    }
  }

  Future<void> _setAutoSelectEnabled(bool enabled) async {
    if (_savingAutoSelect || _autoSelectEnabled == enabled) return;
    _savingAutoSelect = true;
    setState(() => _autoSelectEnabled = enabled);
    try {
      await _writeProtectedString(
        _autoSelectPrefsKey,
        enabled ? 'true' : 'false',
      );
    } on Object catch (error) {
      if (mounted) setState(() => _autoSelectEnabled = !enabled);
      _savingAutoSelect = false;
      _notice(_friendlyError(error));
      return;
    }
    _syncAutoSelectTimer(
      runNow:
          enabled && _connection.status == SingBoxConnectionStatus.connected,
    );
    if (!enabled) _notice('自动选择已关闭');
    _savingAutoSelect = false;
  }

  void _syncAutoSelectTimer({bool runNow = false}) {
    _autoSelectTimer?.cancel();
    _autoSelectTimer = null;
    if (!_autoSelectEnabled ||
        WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) {
      return;
    }
    if (runNow) unawaited(_runAutoSelectionProbe());
    _autoSelectTimer = Timer.periodic(
      const Duration(minutes: 15),
      (_) => unawaited(_runAutoSelectionProbe()),
    );
  }

  Future<void> _runAutoSelectionProbe() async {
    if (!_autoSelectEnabled ||
        _autoSelecting ||
        _busy ||
        _testingAvailability ||
        _testingAll ||
        _testingIds.isNotEmpty ||
        _connection.status != SingBoxConnectionStatus.connected ||
        _residential.enabled) {
      return;
    }
    final targets = _servers
        .where((server) => server.enabled && !_isLoopbackProfile(server))
        .toList();
    if (targets.isEmpty) return;
    _autoSelecting = true;
    _lastAutoSelectionAt = DateTime.now();
    try {
      final startedAt = DateTime.now().subtract(const Duration(seconds: 1));
      final group = await _engine.testGroup(
        SingBoxConfigBuilder.autoTag,
        timeout: const Duration(seconds: 60),
      );
      if (!_autoSelectEnabled ||
          _connection.status != SingBoxConnectionStatus.connected ||
          group == null) {
        return;
      }
      final candidates =
          group.items
              .where(
                (item) =>
                    item.urlTestDelay != null &&
                    item.urlTestDelay! > 5 &&
                    item.urlTestTime != null &&
                    !item.urlTestTime!.isBefore(startedAt),
              )
              .toList()
            ..sort(
              (left, right) =>
                  left.urlTestDelay!.compareTo(right.urlTestDelay!),
            );
      for (final candidate in candidates) {
        final server = targets
            .where(
              (item) =>
                  item.name == candidate.tag ||
                  candidate.tag.startsWith('${item.name} ('),
            )
            .firstOrNull;
        if (server == null) continue;
        if (!_autoSelectEnabled ||
            _connection.status != SingBoxConnectionStatus.connected) {
          return;
        }
        await _engine.selectOutbound(
          SingBoxConfigBuilder.proxyTag,
          candidate.tag,
        );
        await _engine.setActiveServerConfig(server.id);
        if (!mounted) return;
        setState(() {
          _activeId = server.id;
          _probeResults[server.id] = _nodeUrlTestResult(
            candidate.urlTestDelay,
            tag: candidate.tag,
            serverId: server.id,
          );
        });
        await _persistProbeResults(_probeResults);
        return;
      }
    } on Object {
      // Periodic switching is intentionally silent; manual status stays intact.
    } finally {
      _autoSelecting = false;
    }
  }

  Future<void> _testCurrentAvailability() async {
    if (_testingAvailability) return;
    if (!_connection.status.isActive) {
      _notice('请先连接 VPN，再测试网站可用性');
      return;
    }
    final residentialActive = _residential.enabled;
    final active = residentialActive
        ? null
        : await _engine.getActiveServerConfig();
    if (!residentialActive && active == null) {
      _notice('当前没有可测试的活动节点');
      return;
    }
    final loopback = active != null
        ? _isLoopbackProfile(active)
        : _isLoopbackHost(_residential.server);
    if (loopback) {
      final failure = SingBoxPingResult.failure(
        '无效节点：服务器地址是本机回环地址',
        address: active?.server ?? _residential.server,
        tag: active?.name ?? 'hourglass-residential-ip',
        serverId: active?.id ?? _residentialProbeResultId,
      );
      setState(() => _probeResults[failure.serverId!] = failure);
      await _persistProbeResults(_probeResults);
      _notice('当前节点地址为 127.0.0.1 / localhost，已标记为无效');
      return;
    }
    setState(() => _testingAvailability = true);
    _notice('正在经当前代理访问 Google 测试地址…');
    try {
      SingBoxPingResult? result;
      for (var attempt = 0; attempt < 2; attempt++) {
        try {
          if (residentialActive) {
            final startedAt = DateTime.now().subtract(
              const Duration(seconds: 1),
            );
            final group = await _engine.testGroup(
              'hourglass-check-google',
              timeout: const Duration(seconds: 20),
            );
            final item = group?.items
                .where(
                  (candidate) => candidate.tag == 'hourglass-residential-ip',
                )
                .firstOrNull;
            final fresh =
                item?.urlTestTime != null &&
                !item!.urlTestTime!.isBefore(startedAt);
            result = fresh && item?.urlTestDelay != null
                ? SingBoxPingResult(
                    ping: item!.urlTestDelay!,
                    success: true,
                    tag: item.tag,
                    serverId: _residentialProbeResultId,
                  )
                : SingBoxPingResult.failure(
                    'Google 测试地址暂时无响应',
                    tag: item?.tag ?? 'hourglass-residential-ip',
                    serverId: _residentialProbeResultId,
                  );
          } else {
            result = await _engine
                .pingServers(
                  [active!],
                  concurrency: 1,
                  timeout: const Duration(seconds: 18),
                  testParentGroup: false,
                )
                .first;
            result = result.forServer(active.id);
          }
        } on Object catch (error) {
          result = SingBoxPingResult.failure(
            _friendlyError(error),
            tag: active?.name ?? 'hourglass-residential-ip',
            serverId: active?.id ?? _residentialProbeResultId,
          );
        }
        if (result.success || attempt == 1) break;
        await Future<void>.delayed(const Duration(milliseconds: 700));
      }
      final availabilityResult = _rejectSuspiciousNodeLatency(result!);
      if (!mounted) return;
      setState(() {
        _probeResults[availabilityResult.serverId!] = availabilityResult;
      });
      await _persistProbeResults(_probeResults);
      _notice(
        availabilityResult.success
            ? '网站可用性测试成功：${availabilityResult.ping} ms'
            : '网站可用性测试失败：${availabilityResult.errorMessage ?? '目标无法访问'}',
      );
    } on Object catch (error) {
      if (mounted) _notice(_friendlyError(error));
    } finally {
      if (mounted) setState(() => _testingAvailability = false);
      await _restartStatsSubscription();
    }
  }

  Future<void> _toggleTunnel() async {
    if (_busy || _connection.status.isTransitioning) return;
    if (_residential.enabled && _residential.mode == 'direct') {
      final selected =
          _servers
              .where(
                (item) =>
                    item.id == _activeId &&
                    item.enabled &&
                    !_isLoopbackProfile(item),
              )
              .firstOrNull ??
          _servers
              .where((item) => item.enabled && !_isLoopbackProfile(item))
              .firstOrNull;
      if (selected == null) {
        _notice('没有普通代理节点可切换；请先关闭住宅 IP 或添加节点');
        return;
      }
      setState(() {
        _busy = true;
        _residential = _residential.copyWith(enabled: false);
        _activeId = selected.id;
      });
      try {
        await _writeProtectedString(
          _residentialProxyPrefsKey,
          jsonEncode(_residential.toMap()),
        );
        await _saveRoutingMode();
        await _connectProfile(selected);
        _notice('已关闭住宅 IP，切换到普通代理节点');
      } on Object catch (error) {
        _notice(_friendlyError(error));
      } finally {
        if (mounted) setState(() => _busy = false);
        await _reloadServers();
      }
      return;
    }
    if (_connection.status.isActive) {
      setState(() => _busy = true);
      try {
        await _engine.disconnect();
      } on Object catch (error) {
        _notice(_friendlyError(error));
      } finally {
        if (mounted) setState(() => _busy = false);
      }
      return;
    }
    final directResidential =
        _residential.enabled && _residential.mode == 'direct';
    final selected =
        _servers
            .where(
              (item) =>
                  item.id == _activeId &&
                  item.enabled &&
                  !_isLoopbackProfile(item),
            )
            .firstOrNull ??
        _servers
            .where((item) => item.enabled && !_isLoopbackProfile(item))
            .firstOrNull;
    if (selected == null && !directResidential) {
      if (_servers.isEmpty) {
        _notice('先添加一个节点或订阅');
        await _showImportDialog();
      } else {
        _notice('没有可连接的有效节点，请更新订阅或检查节点地址');
      }
      return;
    }
    setState(() {
      _busy = true;
      if (selected != null) _activeId = selected.id;
    });
    try {
      await _saveRoutingMode();
      await _connectProfile(selected);
    } on Object catch (error) {
      _notice(_friendlyError(error));
    } finally {
      if (mounted) setState(() => _busy = false);
      await _reloadServers();
    }
  }

  Future<void> _connectProfile(SingBoxServerConfig? selected) async {
    if (selected != null && _isLoopbackProfile(selected)) {
      throw const FormatException(
        '当前选中节点地址为 127.0.0.1 / localhost，无法连接；请更新订阅或选择有效节点',
      );
    }
    final profiles = _servers.where((profile) => profile.enabled).toList();
    _applyOverridesToEngine();
    final geodataRules = await _loadGeodataRules();
    final residentialEnabled = _residential.enabled;
    final residentialDirect =
        residentialEnabled && _residential.mode == 'direct';
    {
      if (_overrides.allowLan &&
          (_overrides.username.trim().isEmpty || _overrides.password.isEmpty)) {
        throw const FormatException('局域网代理缺少认证信息，已阻止启动未受保护的代理端口');
      }
      final taggedOutbounds = <Map<String, dynamic>>[];
      final usedTags = <String>{
        'proxy',
        'auto',
        'direct',
        'hourglass-residential-ip',
      };
      String? selectedTag;
      for (final profile
          in residentialDirect ? const <SingBoxServerConfig>[] : profiles) {
        final outbound = profile.outbound;
        if (outbound == null) continue;
        var tag = profile.name.isNotEmpty ? profile.name : profile.id;
        if (usedTags.contains(tag)) {
          final base = tag;
          var suffix = 2;
          while (usedTags.contains('$base ($suffix)')) {
            suffix++;
          }
          tag = '$base ($suffix)';
        }
        usedTags.add(tag);
        taggedOutbounds.add({...outbound, 'tag': tag});
        if (profile.id == selected?.id) selectedTag = tag;
      }
      if (residentialEnabled) {
        if (!residentialDirect && selectedTag == null) {
          throw const FormatException('链式住宅 IP 模式需要先选择一个普通代理节点');
        }
        final residentialTag = 'hourglass-residential-ip';
        taggedOutbounds.add(
          _buildResidentialOutbound(
            tag: residentialTag,
            detour: residentialDirect ? null : selectedTag,
          ),
        );
        selectedTag = residentialTag;
      }
      if (taggedOutbounds.isEmpty) {
        throw const FormatException('当前没有可用于连接的代理节点');
      }
      final savedRules = await _loadUserRoutingRules(_engine);
      final base = await _engine.buildConfig(
        jsonEncode(taggedOutbounds),
        rules: _effectiveRoutingRules(savedRules, globalTun: _globalTun),
        selectedTag: selectedTag,
      );
      final config = Map<String, dynamic>.from(jsonDecode(base) as Map);
      if (residentialEnabled) _appendResidentialSiteTestGroups(config);
      _appendGeodataRules(config, geodataRules, globalTun: _globalTun);
      final ruleSetUpdates = await _prepareLocalRuleSets(_engine, config);
      final inbounds = (config['inbounds'] as List)
          .cast<Map<String, dynamic>>();
      final addresses = <String>['0.0.0.0'];
      if (_overrides.allowLan && _overrides.ipv6Proxy) {
        final v6 = await _lanIpv6Addresses();
        addresses.addAll(v6.isEmpty ? const ['::'] : v6);
      }
      final inboundType = switch (_overrides.protocol) {
        'http' => 'http',
        'socks' => 'socks',
        _ => 'mixed',
      };
      final inboundAuth =
          _overrides.username.isNotEmpty && _overrides.password.isNotEmpty
          ? [
              {
                'username': _overrides.username,
                'password': _overrides.password,
              },
            ]
          : const [];
      if (_overrides.allowLan) {
        for (var index = 0; index < addresses.length; index++) {
          inbounds.add({
            'type': inboundType,
            'tag': 'lan-proxy-$index',
            'listen': addresses[index],
            'listen_port': _overrides.port,
            if (inboundAuth.isNotEmpty) 'users': inboundAuth,
          });
        }
      }
      if (Platform.isAndroid) {
        final reservedPort = await ServerSocket.bind(
          InternetAddress.loopbackIPv4,
          0,
        );
        final updateProxyPort = reservedPort.port;
        await reservedPort.close();
        final updateProxyPassword = base64Url
            .encode(List<int>.generate(24, (_) => Random.secure().nextInt(256)))
            .replaceAll('=', '');
        inbounds.add({
          'type': 'mixed',
          'tag': 'hourglass-update-proxy',
          'listen': '127.0.0.1',
          'listen_port': updateProxyPort,
          'users': [
            {'username': 'hourglass-update', 'password': updateProxyPassword},
          ],
        });
      }
      await _engine.connect(
        jsonEncode(config),
        timeout: const Duration(seconds: 45),
      );
      final workDir = _engine.runtimeInfo?.workingDirectory;
      if (workDir != null && ruleSetUpdates.isNotEmpty) {
        unawaited(
          Future<void>.delayed(const Duration(seconds: 30), () async {
            if (_engine.isConnected) {
              await _updateRuleSetModules(ruleSetUpdates, workDir);
            }
          }),
        );
      }
      return;
    }
  }

  Map<String, dynamic> _buildResidentialOutbound({
    required String tag,
    String? detour,
  }) {
    final server = _residential.server.trim();
    final port = _residential.port;
    if (server.isEmpty || port < 1 || port > 65535) {
      throw const FormatException('请填写有效的住宅代理服务器地址和端口');
    }
    final protocol = _residential.protocol;
    final isSocks = protocol == 'socks4' || protocol == 'socks5';
    return {
      'type': isSocks ? 'socks' : 'http',
      'tag': tag,
      'server': server,
      'server_port': port,
      if (isSocks) 'version': protocol == 'socks4' ? '4' : '5',
      if (protocol == 'https') 'tls': {'enabled': true, 'server_name': server},
      if (_residential.username.isNotEmpty) 'username': _residential.username,
      if (_residential.password.isNotEmpty && protocol != 'socks4')
        'password': _residential.password,
      if (detour != null) 'detour': detour,
    };
  }

  void _appendResidentialSiteTestGroups(Map<String, dynamic> config) {
    final outbounds = (config['outbounds'] as List)
        .cast<Map<String, dynamic>>();
    for (final target in _residentialSiteTargets) {
      outbounds.add({
        'type': 'urltest',
        'tag': target.groupTag,
        'outbounds': ['hourglass-residential-ip'],
        'url': target.url,
        // sing-box requires urltest interval <= idle_timeout (default 5m).
        'interval': '3m',
        'tolerance': 0,
      });
    }
    config['outbounds'] = outbounds;
  }

  void _appendGeodataRules(
    Map<String, dynamic> config,
    List<Map<String, String>> geodataRules, {
    required bool globalTun,
  }) {
    if (geodataRules.isEmpty) return;
    final route = Map<String, dynamic>.from(config['route'] as Map);
    final routeRules = (route['rules'] as List).cast<Map<String, dynamic>>();
    final ruleSets = (route['rule_set'] as List? ?? <dynamic>[])
        .cast<Map<String, dynamic>>();
    final httpClients = (config['http_clients'] as List? ?? <dynamic>[])
        .cast<Map<String, dynamic>>();
    if (!httpClients.any((client) => client['tag'] == 'hourglass-geodata')) {
      httpClients.add({'tag': 'hourglass-geodata', 'detour': 'proxy'});
    }
    final seen = <String>{for (final item in ruleSets) '${item['tag']}'};
    for (final rule in geodataRules) {
      final type = rule['type']?.toUpperCase();
      final value = rule['value']?.toLowerCase();
      final configuredAction = rule['action']?.toUpperCase();
      final action = globalTun && configuredAction == 'DIRECT'
          ? 'PROXY'
          : configuredAction;
      if (!{'GEOIP', 'GEOSITE'}.contains(type) ||
          value == null ||
          value.isEmpty)
        continue;
      if (!{'DIRECT', 'PROXY', 'REJECT'}.contains(action)) continue;
      final category = type == 'GEOSITE' ? 'geosite' : 'geoip';
      final geodataTag = '$category-$value';
      final tag = 'hourglass-$geodataTag'.replaceAll(
        RegExp(r'[^A-Za-z0-9_.-]'),
        '_',
      );
      if (seen.add(tag)) {
        final template = type == 'GEOSITE'
            ? _engine.configOptions.geositeRuleSetUrl
            : _engine.configOptions.geoipRuleSetUrl;
        ruleSets.add({
          'type': 'remote',
          'tag': tag,
          'format': 'binary',
          'url': template.replaceAll('{tag}', geodataTag),
          'update_interval': '24h',
          'http_client': 'hourglass-geodata',
        });
      }
      if (action == 'REJECT') {
        routeRules.add({
          'rule_set': [tag],
          'action': 'reject',
        });
      } else {
        routeRules.add({
          'rule_set': [tag],
          'action': 'route',
          'outbound': action == 'DIRECT' ? 'direct' : 'proxy',
        });
      }
    }
    route['rules'] = routeRules;
    route['rule_set'] = ruleSets;
    config['route'] = route;
    config['http_clients'] = httpClients;
  }

  void _applyOverridesToEngine() {
    final options = _engine.configOptions;
    _engine.configOptions = options.copyWith(
      sniff: _overrides.sniff,
      tun: options.tun.copyWith(
        enableIpv6: _overrides.tunIpv6,
        mtu: _overrides.mtu.clamp(576, 1500),
      ),
      dns: options.dns.copyWith(fakeIp: _overrides.fakeIp),
      ruleSetDownloadDetour: 'proxy',
      // Reduce background probes across all nodes. Manual tests remain instant.
      urlTestInterval: const Duration(minutes: 15),
    );
  }

  Future<List<String>> _lanIpv6Addresses() async {
    try {
      final interfaces = await NetworkInterface.list(
        includeLoopback: false,
        type: InternetAddressType.IPv6,
      );
      return interfaces
          .expand((item) => item.addresses)
          .where(
            (address) =>
                !address.isLoopback &&
                !address.isLinkLocal &&
                !address.isMulticast &&
                !address.address.toLowerCase().startsWith('fdfe:dcba:'),
          )
          .map((address) => address.address)
          .toSet()
          .toList();
    } on Object {
      return const [];
    }
  }

  Future<void> _saveOverrides(_HourglassOverrides overrides) async {
    await _writeProtectedString(
      _overridePrefsKey,
      jsonEncode(overrides.toMap()),
    );
    if (!mounted) return;
    setState(() => _overrides = overrides);
    _applyOverridesToEngine();
    if (_connection.status.isActive) {
      final selected = _servers
          .where((server) => server.id == _activeId)
          .firstOrNull;
      if (selected != null) {
        setState(() => _busy = true);
        try {
          await _connectProfile(selected);
        } on Object catch (error) {
          _notice(_friendlyError(error));
        } finally {
          if (mounted) setState(() => _busy = false);
        }
      }
    }
  }

  Future<void> _saveRoutingMode() async {
    final saved = await _loadUserRoutingRules(_engine);
    await _saveUserRoutingRules(_engine, saved, globalTun: _globalTun);
  }

  Future<void> _selectRoutingMode(bool globalTun) async {
    if (_busy || _globalTun == globalTun) return;
    final previousMode = _globalTun;
    setState(() {
      _globalTun = globalTun;
      _busy = true;
    });
    try {
      await _saveRoutingMode();
    } on Object catch (error) {
      if (mounted) setState(() => _globalTun = previousMode);
      _notice(_friendlyError(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _selectServer(SingBoxServerConfig server) async {
    if (_busy || _connection.status.isTransitioning) return;
    if (_isLoopbackProfile(server)) {
      _notice('该节点服务器地址是 127.0.0.1 / localhost，已判为无效');
      return;
    }
    setState(() => _busy = true);
    try {
      await _disableDirectResidentialForNode();
      await _engine.setActiveServerConfig(server.id);
      final connected = _connection.status == SingBoxConnectionStatus.connected;
      final switched = connected && await _trySwitchConnectedNode(server);
      if (connected && !switched) {
        await _saveRoutingMode();
        await _connectProfile(server);
      }
      if (mounted) setState(() => _activeId = server.id);
    } on Object catch (error) {
      _notice(_friendlyError(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _selectAndConnectServer(SingBoxServerConfig server) async {
    if (_busy || _connection.status.isTransitioning) return;
    if (_isLoopbackProfile(server)) {
      _notice('该节点服务器地址是 127.0.0.1 / localhost，已判为无效');
      return;
    }
    setState(() => _busy = true);
    try {
      await _disableDirectResidentialForNode();
      await _engine.setActiveServerConfig(server.id);
      final connected = _connection.status == SingBoxConnectionStatus.connected;
      final switched = connected && await _trySwitchConnectedNode(server);
      if (!switched) {
        await _saveRoutingMode();
        await _connectProfile(server);
      }
      if (mounted) setState(() => _activeId = server.id);
    } on Object catch (error) {
      _notice(_friendlyError(error));
    } finally {
      if (mounted) setState(() => _busy = false);
      await _reloadServers();
    }
  }

  Future<bool> _trySwitchConnectedNode(SingBoxServerConfig server) async {
    // Use sing-box's live selector for ordinary node changes. Rebuilding the
    // Android VPN service while connected can stall OEM VpnService processes.
    if (_residential.enabled) return false;
    final groups = await _engine.watchGroups().first.timeout(
      const Duration(seconds: 3),
    );
    final selector = groups
        .where((group) => group.tag == SingBoxConfigBuilder.proxyTag)
        .firstOrNull;
    if (selector == null || !selector.selectable) return false;
    final item = selector.items
        .where(
          (candidate) =>
              candidate.tag == server.name ||
              candidate.tag.startsWith('${server.name} ('),
        )
        .firstOrNull;
    if (item == null) return false;
    // Do not start a second full config reload if the live selector call
    // fails or times out. That used to overlap two native service operations.
    await _engine
        .selectOutbound(selector.tag, item.tag)
        .timeout(const Duration(seconds: 10));
    return true;
  }

  Future<void> _disableDirectResidentialForNode() async {
    if (!_residential.enabled || _residential.mode != 'direct') return;
    final next = _residential.copyWith(enabled: false);
    await _writeProtectedString(
      _residentialProxyPrefsKey,
      jsonEncode(next.toMap()),
    );
    if (mounted) setState(() => _residential = next);
  }

  Future<void> _showImportDialog() async {
    final result = await Navigator.of(context).push<_ImportRequest>(
      MaterialPageRoute<_ImportRequest>(
        builder: (_) => const _ImportProfilePage(),
      ),
    );
    if (!mounted || result == null) return;
    final input = result.content.trim();
    if (input.isEmpty) return;
    setState(() => _busy = true);
    _notice('正在下载并解析订阅…', duration: const Duration(minutes: 1));
    try {
      var content = input;
      final uri = Uri.tryParse(input);
      final isHttpSubscription =
          uri != null &&
          uri.host.isNotEmpty &&
          !input.contains('\n') &&
          (uri.scheme == 'https' ||
              (uri.scheme == 'http' &&
                  (uri.pathSegments.isNotEmpty ||
                      uri.hasQuery ||
                      !uri.hasPort)));
      if (isHttpSubscription) {
        content = (await _downloadSubscriptionWithFallback(
          input,
          validate: isSupportedSubscriptionBody,
        )).body;
      }
      final subscriptionId = isHttpSubscription
          ? input
          : result.localFile
          ? 'local-file:${DateTime.now().microsecondsSinceEpoch}'
          : 'manual-${DateTime.now().microsecondsSinceEpoch}';
      final installed = await _installSubscription(
        _engine,
        content,
        subscriptionId: subscriptionId,
        globalTun: _globalTun,
        sourceUrl: isHttpSubscription ? input : null,
        downloader: _downloadSubscriptionWithFallback,
      );
      if (isHttpSubscription || result.localFile) {
        final fallback = result.localFile
            ? (result.fileName?.replaceFirst(
                    RegExp(r'\.(yaml|yml|yam)$', caseSensitive: false),
                    '',
                  ) ??
                  '本地 YAML 订阅')
            : _subscriptionFallbackName(subscriptionId);
        await _saveSubscriptionName(
          subscriptionId,
          result.customName.trim().isEmpty ? fallback : result.customName,
        );
      }
      final imported = installed.servers;
      if (imported.isEmpty) {
        throw const FormatException('没有识别到可用节点。请检查分享链接或订阅内容。');
      }
      await _engine.setActiveServerConfig(imported.first.id);
      await _reloadServers();
      final providers = installed.resources;
      _notice(
        '已导入 ${imported.length} 个节点${providers > 0 ? '，并下载应用 $providers 个规则/节点资源' : ''}',
      );
      final warnings = installed.warnings;
      if (warnings.isNotEmpty) _notice(warnings.first);
    } on Object catch (error) {
      _notice(_friendlyError(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _showSubscriptions() async {
    await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (_) => _SubscriptionManagerPage(
          engine: _engine,
          globalTun: _globalTun,
          downloader: _downloadSubscriptionWithFallback,
        ),
      ),
    );
    // The system back gesture returns null, so always reload the lightweight
    // subscription metadata when the management route closes.
    await _reloadServers();
  }

  Future<void> _showResidentialSettings() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => _ResidentialProxyPage(
          engine: _engine,
          initial: _residential,
          onSave: _saveResidentialSettings,
        ),
      ),
    );
  }

  Future<void> _saveResidentialSettings(
    _ResidentialProxySettings settings,
  ) async {
    final previous = _residential;
    await _writeProtectedString(
      _residentialProxyPrefsKey,
      jsonEncode(settings.toMap()),
    );
    if (mounted) setState(() => _residential = settings);
    final active = _connection.status.isActive;
    if ((settings.enabled && settings.mode == 'direct') ||
        (active && settings.enabled && settings.mode == 'chain') ||
        (active &&
            previous.enabled &&
            previous.mode == 'chain' &&
            !settings.enabled)) {
      final selected = settings.enabled && settings.mode == 'direct'
          ? null
          : _servers.where((server) => server.id == _activeId).firstOrNull;
      try {
        await _connectProfile(selected);
      } on Object catch (error) {
        _notice('设置已保存，但重新应用连接失败：${_friendlyError(error)}');
        return;
      }
    } else if (active &&
        previous.enabled &&
        previous.mode == 'direct' &&
        !settings.enabled) {
      try {
        await _engine.disconnect();
      } on Object catch (error) {
        _notice('住宅 IP 已关闭，但断开 VPN 失败：${_friendlyError(error)}');
        return;
      }
    }
    _notice(settings.enabled ? '住宅 IP 设置已保存' : '住宅 IP 功能已关闭');
  }

  Future<void> _openSubscriptionNodes(String subscriptionId) async {
    await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (_) => _SubscriptionNodesPage(
          engine: _engine,
          subscriptionId: subscriptionId,
          displayName:
              _subscriptionNames[subscriptionId] ??
              _subscriptionFallbackName(subscriptionId),
          globalTun: _globalTun,
          downloader: _downloadSubscriptionWithFallback,
          onReconfigure: _connectProfile,
        ),
      ),
    );
    await _reloadServers();
  }

  Future<void> _removeServer(SingBoxServerConfig server) async {
    final ok = await showCupertinoDialog<bool>(
      context: context,
      builder: (dialogContext) => CupertinoAlertDialog(
        title: const Text('删除节点？'),
        content: Text('“${server.name}”将从本机移除。'),
        actions: [
          CupertinoDialogAction(
            onPressed: () => dialogContext.pop(false),
            child: const Text('取消'),
          ),
          CupertinoDialogAction(
            isDestructiveAction: true,
            onPressed: () => dialogContext.pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    if (_connection.status.isActive && _activeId == server.id)
      await _engine.disconnect();
    await _engine.removeServerConfig(server.id);
    await _reloadServers();
  }

  void _notice(
    String message, {
    Duration duration = const Duration(seconds: 4),
  }) {
    if (!mounted) return;
    _showGlassNotice(context, message, duration: duration);
  }

  String _friendlyError(Object error) {
    final text = error.toString().replaceFirst('Exception: ', '');
    return text.length > 180 ? '${text.substring(0, 177)}…' : text;
  }

  @override
  void dispose() {
    _stateSub?.cancel();
    _statsSub?.cancel();
    _groupsSub?.cancel();
    _autoSelectTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _scrollController.dispose();
    _tabAnimationController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final status = _connection.status;
    final connected = status == SingBoxConnectionStatus.connected;
    final selected = _servers.where((item) => item.id == _activeId).firstOrNull;
    return Scaffold(
      body: Stack(
        children: [
          const _AmbientBackground(),
          SafeArea(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 680),
                child: GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onHorizontalDragEnd: (details) {
                    final velocity = details.primaryVelocity ?? 0;
                    if (velocity.abs() < 240) return;
                    final nextIndex = (_tabIndex + (velocity < 0 ? 1 : -1))
                        .clamp(0, 2);
                    if (nextIndex != _tabIndex) {
                      _changeTabBySwipe(nextIndex, velocity < 0 ? 1 : -1);
                    }
                  },
                  child: SlideTransition(
                    position:
                        Tween<Offset>(
                          begin: Offset(_tabEntryDirection, 0),
                          end: Offset.zero,
                        ).animate(
                          CurvedAnimation(
                            parent: _tabAnimationController,
                            curve: Curves.easeOutCubic,
                          ),
                        ),
                    child: Scrollbar(
                      controller: _scrollController,
                      child: CustomScrollView(
                        controller: _scrollController,
                        physics: const BouncingScrollPhysics(),
                        slivers: [
                          if (_tabIndex == 0) ...[
                            SliverPadding(
                              padding: const EdgeInsets.fromLTRB(
                                22,
                                16,
                                22,
                                18,
                              ),
                              sliver: SliverToBoxAdapter(
                                child: _Header(
                                  onSettings: () => _changeTabInstant(2),
                                ),
                              ),
                            ),
                            SliverPadding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 20,
                              ),
                              sliver: SliverToBoxAdapter(
                                child: _ConnectionCard(
                                  connected: connected,
                                  transitioning:
                                      status.isTransitioning || _busy,
                                  selectedName:
                                      _residential.enabled &&
                                          _residential.mode == 'direct'
                                      ? '住宅 IP · 直连模式'
                                      : _residential.enabled
                                      ? '${selected?.name ?? '选择代理节点'} · 住宅链式'
                                      : selected?.name,
                                  error: _connection.error,
                                  onTap: _toggleTunnel,
                                ),
                              ),
                            ),
                            SliverPadding(
                              padding: const EdgeInsets.fromLTRB(22, 14, 22, 0),
                              sliver: SliverToBoxAdapter(
                                child: _ModePicker(
                                  globalTun: _globalTun,
                                  enabled: !_busy,
                                  onChanged: _selectRoutingMode,
                                ),
                              ),
                            ),
                            SliverPadding(
                              padding: const EdgeInsets.fromLTRB(22, 18, 22, 0),
                              sliver: SliverToBoxAdapter(
                                child: _TrafficSummary(
                                  stats: _stats,
                                  connected: connected,
                                ),
                              ),
                            ),
                            SliverPadding(
                              padding: const EdgeInsets.fromLTRB(22, 14, 22, 0),
                              sliver: SliverToBoxAdapter(
                                child: _NetworkAnalysisCard(
                                  connected: connected,
                                  transitioning:
                                      status.isTransitioning || _busy,
                                  stats: _stats,
                                  latency: _liveGraphLatency,
                                  downloadHistory: _downloadHistory,
                                  uploadHistory: _uploadHistory,
                                  latencyHistory: _latencyHistory,
                                  testing: _testingAvailability,
                                  onTest: connected
                                      ? _testCurrentAvailability
                                      : null,
                                ),
                              ),
                            ),
                            SliverPadding(
                              padding: const EdgeInsets.fromLTRB(
                                22,
                                20,
                                22,
                                12,
                              ),
                              sliver: SliverToBoxAdapter(
                                child: _HomeProfileCard(
                                  server: selected,
                                  count: _servers.length,
                                  onTap: () => _changeTabInstant(1),
                                  onAdd: _showImportDialog,
                                ),
                              ),
                            ),
                            SliverPadding(
                              padding: const EdgeInsets.fromLTRB(22, 0, 22, 10),
                              sliver: SliverToBoxAdapter(
                                child: _ResidentialEntryCard(
                                  settings: _residential,
                                  onTap: _showResidentialSettings,
                                ),
                              ),
                            ),
                            if (_bootError != null)
                              SliverPadding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 22,
                                ),
                                sliver: SliverToBoxAdapter(
                                  child: _MessageCard(
                                    icon: Icons.error_outline_rounded,
                                    text: _bootError!,
                                  ),
                                ),
                              ),
                            if (!_ready)
                              const SliverToBoxAdapter(
                                child: SizedBox(
                                  height: 100,
                                  child: Center(
                                    child: CircularProgressIndicator.adaptive(),
                                  ),
                                ),
                              ),
                            SliverPadding(
                              padding: const EdgeInsets.fromLTRB(
                                24,
                                12,
                                24,
                                26,
                              ),
                              sliver: SliverToBoxAdapter(
                                child: _Footer(
                                  version: _engine.runtimeInfo?.singBoxVersion,
                                ),
                              ),
                            ),
                          ],
                          if (_tabIndex == 1) ...[
                            SliverPadding(
                              padding: const EdgeInsets.fromLTRB(
                                22,
                                20,
                                22,
                                18,
                              ),
                              sliver: SliverToBoxAdapter(
                                child: Row(
                                  children: [
                                    const Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            '代理配置',
                                            style: TextStyle(
                                              fontSize: 24,
                                              fontWeight: FontWeight.w800,
                                              color: _ink,
                                            ),
                                          ),
                                          SizedBox(height: 4),
                                          Text(
                                            '节点与订阅集中管理',
                                            style: TextStyle(
                                              color: Color(0xFF71829B),
                                              fontSize: 12,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                    TextButton.icon(
                                      onPressed: _showSubscriptions,
                                      icon: const Icon(Icons.sync_rounded),
                                      label: const Text('订阅'),
                                    ),
                                    const SizedBox(width: 8),
                                    _SmallIconButton(
                                      icon: Icons.add_rounded,
                                      onTap: _showImportDialog,
                                      tooltip: '添加节点或订阅',
                                    ),
                                  ],
                                ),
                              ),
                            ),
                            if (_bootError != null)
                              SliverPadding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 22,
                                ),
                                sliver: SliverToBoxAdapter(
                                  child: _MessageCard(
                                    icon: Icons.error_outline_rounded,
                                    text: _bootError!,
                                  ),
                                ),
                              ),
                            if (!_ready)
                              const SliverToBoxAdapter(
                                child: SizedBox(
                                  height: 140,
                                  child: Center(
                                    child: CircularProgressIndicator.adaptive(),
                                  ),
                                ),
                              ),
                            if (_ready && _servers.isEmpty)
                              SliverPadding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 22,
                                ),
                                sliver: SliverToBoxAdapter(
                                  child: _EmptyState(onAdd: _showImportDialog),
                                ),
                              ),
                            if (_ready && _servers.isNotEmpty)
                              SliverPadding(
                                padding: const EdgeInsets.fromLTRB(
                                  20,
                                  0,
                                  20,
                                  12,
                                ),
                                sliver: SliverToBoxAdapter(
                                  child: _TestControlCard(
                                    connected: connected,
                                    testing: _testingAll,
                                    onTestAll: _testingAll
                                        ? null
                                        : () => _testProfiles(
                                            _servers.where(
                                              (server) =>
                                                  _isSubscriptionGroupId(
                                                    server.subscriptionId,
                                                  ),
                                            ),
                                            label: '全部订阅',
                                          ),
                                    results: _probeResults,
                                    servers: _servers,
                                    onSelect: _selectAndConnectServer,
                                    autoSelect: _autoSelectEnabled,
                                    onAutoSelectChanged: _setAutoSelectEnabled,
                                  ),
                                ),
                              ),
                            if (_ready &&
                                _servers.isNotEmpty &&
                                _bootError == null)
                              SliverPadding(
                                padding: const EdgeInsets.fromLTRB(
                                  20,
                                  0,
                                  20,
                                  16,
                                ),
                                sliver: SliverList.builder(
                                  itemCount: _ready && _bootError == null
                                      ? _servers
                                                .where(
                                                  (server) =>
                                                      !_isSubscriptionGroupId(
                                                        server.subscriptionId,
                                                      ),
                                                )
                                                .length +
                                            _servers
                                                .map(
                                                  (server) =>
                                                      server.subscriptionId,
                                                )
                                                .whereType<String>()
                                                .where(_isSubscriptionGroupId)
                                                .toSet()
                                                .length
                                      : 0,
                                  itemBuilder: (context, index) {
                                    final subscriptions = _servers
                                        .map((server) => server.subscriptionId)
                                        .whereType<String>()
                                        .where(_isSubscriptionGroupId)
                                        .toSet()
                                        .toList();
                                    if (index < subscriptions.length) {
                                      final url = subscriptions[index];
                                      final servers = _servers
                                          .where(
                                            (server) =>
                                                server.subscriptionId == url,
                                          )
                                          .toList();
                                      final active = servers.any(
                                        (server) => server.id == _activeId,
                                      );
                                      return Padding(
                                        padding: const EdgeInsets.only(
                                          bottom: 10,
                                        ),
                                        child: _SubscriptionFolderTile(
                                          url: url,
                                          name:
                                              _subscriptionNames[url] ??
                                              _subscriptionFallbackName(url),
                                          count: servers.length,
                                          lastSyncTime:
                                              _subscriptionSyncTimes[url],
                                          active: active,
                                          onTap: () =>
                                              _openSubscriptionNodes(url),
                                          testing: servers.any(
                                            (server) =>
                                                _testingIds.contains(server.id),
                                          ),
                                          onTest: () => _testProfiles(servers),
                                        ),
                                      );
                                    }
                                    final manual = _servers
                                        .where(
                                          (server) => !_isSubscriptionGroupId(
                                            server.subscriptionId,
                                          ),
                                        )
                                        .toList();
                                    final server =
                                        manual[index - subscriptions.length];
                                    final isActive = server.id == _activeId;
                                    return Padding(
                                      padding: const EdgeInsets.only(
                                        bottom: 10,
                                      ),
                                      child: _ServerTile(
                                        server: server,
                                        active: isActive,
                                        connected: connected && isActive,
                                        onTap: () => _selectServer(server),
                                        onDelete: () => _removeServer(server),
                                        result: _probeResults[server.id],
                                        testing: _testingIds.contains(
                                          server.id,
                                        ),
                                        onTest: () => _testProfiles([server]),
                                      ),
                                    );
                                  },
                                ),
                              ),
                          ],
                          if (_tabIndex == 2)
                            SliverPadding(
                              padding: const EdgeInsets.fromLTRB(
                                22,
                                20,
                                22,
                                28,
                              ),
                              sliver: SliverToBoxAdapter(
                                child: _SettingsHub(
                                  engine: _engine,
                                  globalTun: _globalTun,
                                  overrides: _overrides,
                                  onSaveOverrides: _saveOverrides,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tabIndex,
        onDestinationSelected: _changeTabInstant,
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.home_outlined),
            selectedIcon: Icon(Icons.home_rounded),
            label: '首页',
          ),
          NavigationDestination(
            icon: Icon(Icons.dns_outlined),
            selectedIcon: Icon(Icons.dns_rounded),
            label: '节点',
          ),
          NavigationDestination(
            icon: Icon(Icons.tune_rounded),
            selectedIcon: Icon(Icons.tune_rounded),
            label: '设置',
          ),
        ],
      ),
    );
  }
}

class _ResidentialEntryCard extends StatelessWidget {
  const _ResidentialEntryCard({required this.settings, required this.onTap});
  final _ResidentialProxySettings settings;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => _Glass(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
    radius: 21,
    child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(18),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: const Color(0xFF8B79D8).withValues(alpha: .11),
              borderRadius: BorderRadius.circular(14),
            ),
            child: const Icon(
              Icons.home_work_outlined,
              color: Color(0xFF8070CB),
              size: 21,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '住宅 IP 配置',
                  style: TextStyle(
                    color: _ink,
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  settings.enabled
                      ? settings.mode == 'direct'
                            ? '已启用 · 直连模式'
                            : '已启用 · 链式代理'
                      : '配置稳定的住宅网络出口',
                  style: const TextStyle(
                    color: Color(0xFF7D8CA2),
                    fontSize: 10,
                  ),
                ),
              ],
            ),
          ),
          const Icon(Icons.chevron_right_rounded, color: Color(0xFF8C9AAF)),
        ],
      ),
    ),
  );
}

class _ResidentialProxyPage extends StatefulWidget {
  const _ResidentialProxyPage({
    required this.engine,
    required this.initial,
    required this.onSave,
  });
  final SingBox engine;
  final _ResidentialProxySettings initial;
  final Future<void> Function(_ResidentialProxySettings) onSave;

  @override
  State<_ResidentialProxyPage> createState() => _ResidentialProxyPageState();
}

class _ResidentialProxyPageState extends State<_ResidentialProxyPage> {
  late _ResidentialProxySettings _value = widget.initial;
  late final TextEditingController _server = TextEditingController(
    text: _value.server,
  );
  late final TextEditingController _port = TextEditingController(
    text: '${_value.port}',
  );
  late final TextEditingController _username = TextEditingController(
    text: _value.username,
  );
  late final TextEditingController _password = TextEditingController(
    text: _value.password,
  );
  bool _saving = false;
  bool _testingAll = false;
  final Set<String> _testingSites = {};
  final Map<String, _ResidentialSiteResult> _siteResults = {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _value.enabled && widget.engine.isConnected) {
        _testAllSites();
      }
    });
  }

  @override
  void dispose() {
    _server.dispose();
    _port.dispose();
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving) return;
    final port = int.tryParse(_port.text.trim());
    if (_value.enabled &&
        (_server.text.trim().isEmpty ||
            port == null ||
            port < 1 ||
            port > 65535)) {
      _showGlassNotice(context, '请填写有效的住宅代理地址和端口');
      return;
    }
    setState(() => _saving = true);
    final next = _value.copyWith(
      server: _server.text.trim(),
      port: port ?? _value.port,
      username: _username.text.trim(),
      password: _password.text,
    );
    try {
      await widget.onSave(next);
      if (mounted && next.enabled && widget.engine.isConnected) {
        setState(() => _value = next);
        await _testAllSites();
      } else if (mounted) {
        Navigator.of(context).pop();
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _testAllSites() async {
    if (_testingAll || _testingSites.isNotEmpty) return;
    if (!_value.enabled || !widget.engine.isConnected) {
      setState(() {
        for (final site in _residentialSiteTargets) {
          _siteResults[site.id] = const _ResidentialSiteResult(
            success: false,
            detail: '启用住宅 IP 并连接 VPN 后测试',
          );
        }
      });
      return;
    }
    setState(() => _testingAll = true);
    try {
      for (final site in _residentialSiteTargets) {
        await _testSite(site, fromBatch: true);
      }
    } finally {
      if (mounted) setState(() => _testingAll = false);
    }
  }

  Future<void> _testSite(
    _ResidentialSiteTarget site, {
    bool fromBatch = false,
  }) async {
    if (!_value.enabled ||
        !widget.engine.isConnected ||
        _testingSites.contains(site.id) ||
        (_testingSites.isNotEmpty && !fromBatch) ||
        (_testingAll && !fromBatch)) {
      return;
    }
    setState(() {
      _testingSites.add(site.id);
      _siteResults.remove(site.id);
    });
    _ResidentialSiteResult? successResult;
    var lastError = '测试地址暂时没有返回有效结果';
    var timedOut = true;
    try {
      for (var attempt = 0; attempt < 2; attempt++) {
        final startedAt = DateTime.now().subtract(const Duration(seconds: 1));
        try {
          final group = await widget.engine.testGroup(
            site.groupTag,
            timeout: const Duration(seconds: 22),
          );
          final item = group?.items
              .where((candidate) => candidate.tag == 'hourglass-residential-ip')
              .firstOrNull;
          final fresh =
              item?.urlTestTime != null &&
              !item!.urlTestTime!.isBefore(startedAt);
          final delay = item?.urlTestDelay;
          if (fresh && delay != null) {
            successResult = _ResidentialSiteResult(
              success: true,
              delayMs: delay,
              detail: '经住宅 IP 测试成功',
            );
            break;
          }
          lastError = item == null ? '没有收到住宅代理的测速结果' : '测试目标未返回有效结果';
          timedOut = true;
        } on TimeoutException {
          lastError = '连接超时';
          timedOut = true;
        } on Object catch (error) {
          lastError = error.toString().replaceFirst('Exception: ', '');
          timedOut = false;
        }
        if (attempt == 0) {
          await Future<void>.delayed(const Duration(milliseconds: 800));
        }
      }
      if (mounted) {
        setState(() {
          _siteResults[site.id] =
              successResult ??
              _ResidentialSiteResult(
                success: false,
                timedOut: timedOut,
                detail: '重试后仍失败：$lastError',
              );
        });
      }
    } finally {
      if (mounted) setState(() => _testingSites.remove(site.id));
    }
  }

  Widget _field({
    required TextEditingController controller,
    required String label,
    String? hint,
    bool password = false,
    TextInputType? keyboardType,
  }) => TextField(
    controller: controller,
    obscureText: password,
    keyboardType: keyboardType,
    decoration: InputDecoration(
      labelText: label,
      hintText: hint,
      filled: true,
      fillColor: Colors.white.withValues(alpha: .66),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(15),
        borderSide: BorderSide.none,
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
    ),
  );

  Widget _modeChoice(
    String mode,
    String title,
    String subtitle,
    IconData icon,
  ) {
    final selected = _value.mode == mode;
    return Expanded(
      child: InkWell(
        onTap: () => setState(() => _value = _value.copyWith(mode: mode)),
        borderRadius: BorderRadius.circular(18),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 230),
          curve: Curves.easeOutCubic,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
          decoration: BoxDecoration(
            color: selected
                ? _blue.withValues(alpha: .13)
                : Colors.white.withValues(alpha: .58),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: selected
                  ? _blue.withValues(alpha: .38)
                  : Colors.white.withValues(alpha: .7),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    icon,
                    size: 18,
                    color: selected ? _blue : const Color(0xFF8190A5),
                  ),
                  const Spacer(),
                  Icon(
                    selected
                        ? Icons.radio_button_checked_rounded
                        : Icons.radio_button_unchecked_rounded,
                    color: selected ? _blue : const Color(0xFFABB6C5),
                    size: 18,
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                title,
                style: TextStyle(
                  color: selected ? _ink : const Color(0xFF64758E),
                  fontWeight: FontWeight.w800,
                  fontSize: 12,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                subtitle,
                style: const TextStyle(
                  color: Color(0xFF8190A5),
                  fontSize: 9,
                  height: 1.3,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _protocolChoice(String protocol, String label) {
    final selected = _value.protocol == protocol;
    return InkWell(
      onTap: () => setState(() => _value = _value.copyWith(protocol: protocol)),
      borderRadius: BorderRadius.circular(13),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 9),
        decoration: BoxDecoration(
          color: selected
              ? _blue.withValues(alpha: .1)
              : Colors.white.withValues(alpha: .52),
          borderRadius: BorderRadius.circular(13),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              selected
                  ? Icons.radio_button_checked_rounded
                  : Icons.radio_button_unchecked_rounded,
              size: 16,
              color: selected ? _blue : const Color(0xFFABB6C5),
            ),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                color: selected ? _ink : const Color(0xFF71829B),
                fontSize: 11,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Stack(
      children: [
        const _AmbientBackground(),
        SafeArea(
          child: Scrollbar(
            child: SingleChildScrollView(
              physics: const BouncingScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(22, 16, 22, 30),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 620),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          _SmallIconButton(
                            icon: Icons.arrow_back_rounded,
                            tooltip: '返回',
                            onTap: () => Navigator.of(context).pop(),
                          ),
                          const SizedBox(width: 13),
                          const Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  '住宅 IP 配置',
                                  style: TextStyle(
                                    fontSize: 21,
                                    fontWeight: FontWeight.w800,
                                    color: _ink,
                                  ),
                                ),
                                SizedBox(height: 3),
                                Text(
                                  '选择稳定的住宅网络出口',
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: Color(0xFF7889A0),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 18),
                      _Glass(
                        padding: const EdgeInsets.fromLTRB(16, 11, 12, 11),
                        radius: 20,
                        child: Row(
                          children: [
                            const Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    '住宅 IP 功能',
                                    style: TextStyle(
                                      color: _ink,
                                      fontWeight: FontWeight.w800,
                                      fontSize: 13,
                                    ),
                                  ),
                                  SizedBox(height: 3),
                                  Text(
                                    '开启后按下方模式建立住宅代理出口',
                                    style: TextStyle(
                                      color: Color(0xFF8190A5),
                                      fontSize: 10,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            Switch.adaptive(
                              value: _value.enabled,
                              onChanged: (value) => setState(
                                () => _value = _value.copyWith(enabled: value),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 15),
                      const Text(
                        '连接模式',
                        style: TextStyle(
                          color: _ink,
                          fontSize: 13,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          _modeChoice(
                            'direct',
                            '直连模式',
                            '住宅出口，不经过普通节点',
                            Icons.home_work_outlined,
                          ),
                          const SizedBox(width: 9),
                          _modeChoice(
                            'chain',
                            '链式代理',
                            '普通节点 → 住宅代理 → 网站',
                            Icons.alt_route_rounded,
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      _Glass(
                        padding: const EdgeInsets.all(15),
                        radius: 22,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              '代理协议',
                              style: TextStyle(
                                color: _ink,
                                fontSize: 13,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            const SizedBox(height: 10),
                            Wrap(
                              spacing: 7,
                              runSpacing: 7,
                              children: [
                                _protocolChoice('socks5', 'SOCKS5'),
                                _protocolChoice('socks4', 'SOCKS4'),
                                _protocolChoice('http', 'HTTP'),
                                _protocolChoice('https', 'HTTPS'),
                              ],
                            ),
                            if (_value.protocol == 'http') ...[
                              const SizedBox(height: 8),
                              const Text(
                                'HTTP 协议不会加密到住宅代理服务商的链路，账号、目标地址和流量可能被沿途网络观察。优先使用 HTTPS 代理端口。',
                                style: TextStyle(
                                  color: Color(0xFFB06B39),
                                  fontSize: 10,
                                  height: 1.4,
                                ),
                              ),
                            ],
                            const SizedBox(height: 14),
                            _field(
                              controller: _server,
                              label: '服务器地址',
                              hint: '例如 residential.example.com',
                            ),
                            const SizedBox(height: 10),
                            _field(
                              controller: _port,
                              label: '端口',
                              hint: '1080',
                              keyboardType: TextInputType.number,
                            ),
                            const SizedBox(height: 10),
                            _field(controller: _username, label: '用户名（可选）'),
                            const SizedBox(height: 10),
                            _field(
                              controller: _password,
                              label: '密码（可选）',
                              password: true,
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 16),
                      _Glass(
                        padding: const EdgeInsets.all(15),
                        radius: 22,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                const Expanded(
                                  child: Text(
                                    '住宅出口连通性',
                                    style: TextStyle(
                                      color: _ink,
                                      fontSize: 13,
                                      fontWeight: FontWeight.w800,
                                    ),
                                  ),
                                ),
                                TextButton.icon(
                                  onPressed: _testingAll ? null : _testAllSites,
                                  icon: _testingAll
                                      ? const SizedBox(
                                          width: 14,
                                          height: 14,
                                          child:
                                              CircularProgressIndicator.adaptive(
                                                strokeWidth: 2,
                                              ),
                                        )
                                      : const Icon(
                                          Icons.refresh_rounded,
                                          size: 17,
                                        ),
                                  label: const Text('全部检测'),
                                ),
                              ],
                            ),
                            const SizedBox(height: 2),
                            Text(
                              _value.mode == 'chain'
                                  ? '测试流量经过普通节点 → 住宅 IP 后访问目标'
                                  : '测试流量直接经过住宅 IP 访问目标',
                              style: const TextStyle(
                                color: Color(0xFF8190A5),
                                fontSize: 10,
                              ),
                            ),
                            const SizedBox(height: 12),
                            LayoutBuilder(
                              builder: (context, constraints) => Wrap(
                                spacing: 9,
                                runSpacing: 9,
                                children: [
                                  for (final site in _residentialSiteTargets)
                                    SizedBox(
                                      width: (constraints.maxWidth - 9) / 2,
                                      child: _ResidentialSiteCard(
                                        site: site,
                                        result: _siteResults[site.id],
                                        testing: _testingSites.contains(
                                          site.id,
                                        ),
                                        enabled:
                                            _value.enabled &&
                                            widget.engine.isConnected,
                                        onTest: () => _testSite(site),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 15),
                      FilledButton.icon(
                        onPressed: _saving ? null : _save,
                        icon: _saving
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator.adaptive(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.check_rounded),
                        label: Text(_saving ? '正在应用…' : '保存并应用'),
                        style: FilledButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    ),
  );
}

class _ResidentialSiteCard extends StatelessWidget {
  const _ResidentialSiteCard({
    required this.site,
    required this.result,
    required this.testing,
    required this.enabled,
    required this.onTest,
  });

  final _ResidentialSiteTarget site;
  final _ResidentialSiteResult? result;
  final bool testing, enabled;
  final VoidCallback onTest;

  Color get _brandColor => switch (site.id) {
    'github' => const Color(0xFF202832),
    'google' => const Color(0xFF4285F4),
    'youtube' => const Color(0xFFFF0033),
    _ => const Color(0xFF18202A),
  };

  Widget _brandIcon() => switch (site.id) {
    'github' => Container(
      width: 22,
      height: 22,
      decoration: const BoxDecoration(
        color: Color(0xFF202832),
        shape: BoxShape.circle,
      ),
      child: const Icon(Icons.pets_rounded, color: Colors.white, size: 15),
    ),
    'google' => ShaderMask(
      shaderCallback: (bounds) => const LinearGradient(
        colors: [
          Color(0xFF4285F4),
          Color(0xFF34A853),
          Color(0xFFFBBC05),
          Color(0xFFEA4335),
        ],
      ).createShader(bounds),
      child: const Text(
        'G',
        style: TextStyle(
          color: Colors.white,
          fontSize: 23,
          fontWeight: FontWeight.w900,
        ),
      ),
    ),
    'youtube' => Container(
      width: 24,
      height: 17,
      decoration: BoxDecoration(
        color: const Color(0xFFFF0033),
        borderRadius: BorderRadius.circular(5),
      ),
      child: const Icon(
        Icons.play_arrow_rounded,
        color: Colors.white,
        size: 16,
      ),
    ),
    _ => const Icon(Icons.hub_rounded, color: Color(0xFF18202A), size: 22),
  };

  @override
  Widget build(BuildContext context) {
    final statusColor = testing
        ? _blue
        : result == null
        ? const Color(0xFF8997AA)
        : result!.success
        ? _mint
        : const Color(0xFFD76F76);
    final status = testing
        ? '正在测试…'
        : result == null
        ? enabled
              ? '等待测试'
              : '启用并连接住宅 IP'
        : result!.success
        ? '${result!.delayMs} ms'
        : result!.timedOut
        ? '连接超时'
        : '测试失败';
    return AnimatedContainer(
      duration: const Duration(milliseconds: 220),
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 11),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: .72),
        borderRadius: BorderRadius.circular(17),
        border: Border.all(color: statusColor.withValues(alpha: .22)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 33,
                height: 33,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: _brandColor.withValues(alpha: .08),
                  borderRadius: BorderRadius.circular(11),
                ),
                child: _brandIcon(),
              ),
              const Spacer(),
              IconButton(
                visualDensity: VisualDensity.compact,
                tooltip: '检测 ${site.title}',
                onPressed: enabled && !testing ? onTest : null,
                icon: testing
                    ? const SizedBox(
                        width: 15,
                        height: 15,
                        child: CircularProgressIndicator.adaptive(
                          strokeWidth: 2,
                        ),
                      )
                    : const Icon(Icons.refresh_rounded, size: 17),
                color: _blue,
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            site.title,
            style: const TextStyle(
              color: _ink,
              fontSize: 12,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 4),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 200),
            child: Text(
              status,
              key: ValueKey(status),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: statusColor,
                fontSize: 10,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          if (!testing && result?.detail != null) ...[
            const SizedBox(height: 3),
            Text(
              result!.detail!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Color(0xFF8997AA), fontSize: 8),
            ),
          ],
        ],
      ),
    );
  }
}

class _SubscriptionFolderTile extends StatelessWidget {
  const _SubscriptionFolderTile({
    required this.url,
    required this.name,
    required this.count,
    required this.lastSyncTime,
    required this.active,
    required this.onTap,
    this.testing = false,
    this.onTest,
  });
  final String url;
  final String name;
  final int count;
  final DateTime? lastSyncTime;
  final bool active;
  final VoidCallback onTap;
  final bool testing;
  final VoidCallback? onTest;
  @override
  Widget build(BuildContext context) {
    final isLocal = url.startsWith('local-file:');
    return _Glass(
      padding: EdgeInsets.zero,
      radius: 22,
      blur: false,
      color: Colors.white.withValues(alpha: .84),
      child: InkWell(
        borderRadius: BorderRadius.circular(22),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(15, 14, 14, 14),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: active
                      ? _mint.withValues(alpha: .13)
                      : _blue.withValues(alpha: .11),
                  borderRadius: BorderRadius.circular(15),
                ),
                child: Icon(
                  Icons.folder_copy_rounded,
                  color: active ? _mint : _blue,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 14,
                        color: _ink,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${isLocal ? '本地配置' : Uri.tryParse(url)?.host ?? '在线订阅'} · $count 个节点 · 同步${_formatSubscriptionSyncTime(lastSyncTime)} · 点击查看',
                      style: const TextStyle(
                        fontSize: 11,
                        color: Color(0xFF7F8EA4),
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: '测试此订阅全部节点',
                onPressed: testing ? null : onTest,
                icon: testing
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator.adaptive(
                          strokeWidth: 2,
                        ),
                      )
                    : const Icon(Icons.speed_rounded, color: _blue, size: 20),
              ),
              const Icon(Icons.chevron_right_rounded, color: Color(0xFF8D9BAD)),
            ],
          ),
        ),
      ),
    );
  }
}

class _SubscriptionNodesPage extends StatefulWidget {
  const _SubscriptionNodesPage({
    required this.engine,
    required this.subscriptionId,
    required this.displayName,
    required this.globalTun,
    required this.downloader,
    required this.onReconfigure,
  });
  final SingBox engine;
  final String subscriptionId;
  final String displayName;
  final bool globalTun;
  final SubscriptionDownloader downloader;
  final Future<void> Function(SingBoxServerConfig?) onReconfigure;
  @override
  State<_SubscriptionNodesPage> createState() => _SubscriptionNodesPageState();
}

class _SubscriptionNodesPageState extends State<_SubscriptionNodesPage> {
  List<SingBoxServerConfig> _servers = const [];
  List<Map<String, dynamic>> _proxyGroups = const [];
  late String _displayName;
  DateTime? _lastSyncTime;
  String? _activeId;
  String? _error;
  bool _loading = true;
  bool _updating = false;
  bool _changed = false;
  bool _connected = false;
  bool _selecting = false;
  final Map<String, SingBoxPingResult> _probeResults = {};
  final Set<String> _testingIds = {};

  List<({String title, String type, List<SingBoxServerConfig> servers})>
  get _serverSections {
    final sections =
        <({String title, String type, List<SingBoxServerConfig> servers})>[];
    final assigned = <String>{};
    for (final group in _proxyGroups) {
      final rawNodes = group['nodes'];
      if (rawNodes is! List) continue;
      final names = rawNodes.map((value) => value.toString()).toSet();
      final servers = _servers
          .where((server) => names.contains(server.name))
          .toList();
      if (servers.isEmpty) continue;
      assigned.addAll(servers.map((server) => server.id));
      final type = (group['type'] ?? 'select').toString().toLowerCase();
      final strategy = switch (type) {
        'url-test' || 'urltest' => '自动测速',
        'fallback' => '故障转移',
        'load-balance' || 'loadbalance' => '负载均衡',
        'relay' => '链式代理',
        _ => '手动选择',
      };
      sections.add((
        title: (group['name'] ?? '策略组').toString(),
        type: strategy,
        servers: servers,
      ));
    }
    final ungrouped = _servers
        .where((server) => !assigned.contains(server.id))
        .toList();
    if (ungrouped.isNotEmpty || sections.isEmpty) {
      sections.add((
        title: sections.isEmpty ? '节点' : '未分组节点',
        type: '普通节点',
        servers: ungrouped.isEmpty && sections.isEmpty ? _servers : ungrouped,
      ));
    }
    return sections;
  }

  @override
  void initState() {
    super.initState();
    _displayName = widget.displayName;
    _load();
  }

  Future<void> _load() async {
    try {
      _probeResults.addAll(await _readProbeResults());
      final all = await widget.engine.getServerConfigs();
      final active = await widget.engine.getActiveServerConfig();
      final status = await widget.engine.getConnectionStatus();
      final names = await _readSubscriptionNames();
      final syncTimes = await _readSubscriptionSyncTimes();
      final savedGroups = await _readProtectedString(
        _subscriptionGroupsPrefsKey,
      );
      final parsedGroups = <Map<String, dynamic>>[];
      if (savedGroups != null) {
        try {
          final decoded = jsonDecode(savedGroups);
          final raw = decoded is Map ? decoded[widget.subscriptionId] : null;
          if (raw is List) {
            parsedGroups.addAll(
              raw.whereType<Map>().map(
                (item) => Map<String, dynamic>.from(item),
              ),
            );
          }
        } on Object {
          // Ignore malformed optional presentation metadata.
        }
      }
      if (mounted)
        setState(() {
          _servers = all
              .where((server) => server.subscriptionId == widget.subscriptionId)
              .toList();
          _activeId = active?.id;
          _proxyGroups = parsedGroups;
          _connected = status.isActive;
          _displayName =
              names[widget.subscriptionId] ??
              _subscriptionFallbackName(widget.subscriptionId);
          _lastSyncTime = syncTimes[widget.subscriptionId];
          _loading = false;
        });
    } on Object catch (error) {
      if (mounted)
        setState(() {
          _error = error.toString();
          _loading = false;
        });
    }
  }

  Future<void> _refresh() async {
    if (_updating) return;
    setState(() {
      _updating = true;
      _error = null;
    });
    try {
      final response = await widget.downloader(
        widget.subscriptionId,
        validate: isSupportedSubscriptionBody,
      );
      await _installSubscription(
        widget.engine,
        response.body,
        subscriptionId: widget.subscriptionId,
        globalTun: widget.globalTun,
        sourceUrl: widget.subscriptionId,
        downloader: widget.downloader,
      );
      _changed = true;
      await _load();
    } on Object catch (error) {
      if (mounted)
        setState(
          () => _error = error.toString().replaceFirst('Exception: ', ''),
        );
    } finally {
      if (mounted) setState(() => _updating = false);
    }
  }

  Future<void> _select(SingBoxServerConfig server) async {
    if (_selecting) return;
    setState(() => _selecting = true);
    try {
      final status = await widget.engine.getConnectionStatus();
      if (status == SingBoxConnectionStatus.connected) {
        List<SingBoxOutboundGroup> groups = const [];
        try {
          groups = await widget.engine.watchGroups().first.timeout(
            const Duration(seconds: 2),
          );
        } on Object {
          // Old configs may not expose live group state.
        }
        final selector = groups
            .where((group) => group.tag == SingBoxConfigBuilder.proxyTag)
            .firstOrNull;
        final item = selector?.items
            .where(
              (candidate) =>
                  candidate.tag == server.name ||
                  candidate.tag.startsWith('${server.name} ('),
            )
            .firstOrNull;
        if (selector != null && item != null && selector.selectable) {
          await widget.engine
              .selectOutbound(selector.tag, item.tag)
              .timeout(const Duration(seconds: 8));
        } else {
          // Older active configs may predate the selector. Rebuild the full
          // profile set and reload it in-place so the VPN stays established.
          await widget.onReconfigure(server);
        }
      }
      await widget.engine.setActiveServerConfig(server.id);
      if (mounted) setState(() => _activeId = server.id);
      _changed = true;
    } on Object catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _selecting = false);
    }
  }

  Future<void> _testProfiles(Iterable<SingBoxServerConfig> profiles) async {
    if (_testingIds.isNotEmpty) return;
    final targets = profiles.where((server) => server.enabled).toList();
    if (targets.isEmpty) return;
    final validTargets = targets
        .where((server) => !_isLoopbackProfile(server))
        .toList();
    final invalidTargets = targets.where(_isLoopbackProfile).toList();
    final ids = targets.map((server) => server.id).toSet();
    setState(() {
      _testingIds.addAll(ids);
      for (final id in ids) {
        _probeResults.remove(id);
      }
      for (final server in invalidTargets) {
        _probeResults[server.id] = SingBoxPingResult.failure(
          '无效节点：服务器地址是本机回环地址',
          address: server.server,
          tag: server.name,
          serverId: server.id,
        );
      }
    });
    try {
      await for (final result in Stream.fromFutures(
        validTargets.map(
          (server) => _directTcpPing(server, const Duration(seconds: 7)),
        ),
      )) {
        if (!mounted) return;
        setState(
          () => _probeResults[result.serverId!] = _rejectSuspiciousNodeLatency(
            result,
          ),
        );
        _changed = true;
      }
      _changed = true;
      await _persistProbeResults(_probeResults);
    } on Object catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _testingIds.removeAll(ids));
    }
  }

  Future<void> _remove(SingBoxServerConfig server) async {
    await widget.engine.removeServerConfig(server.id);
    _changed = true;
    await _load();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Stack(
      children: [
        const _AmbientBackground(),
        SafeArea(
          child: _loading
              ? const Center(child: CircularProgressIndicator.adaptive())
              : Scrollbar(
                  child: CustomScrollView(
                    slivers: [
                      SliverPadding(
                        padding: const EdgeInsets.fromLTRB(22, 16, 18, 18),
                        sliver: SliverToBoxAdapter(
                          child: Row(
                            children: [
                              _SmallIconButton(
                                icon: Icons.arrow_back_rounded,
                                tooltip: '返回',
                                onTap: () =>
                                    Navigator.of(context).pop(_changed),
                              ),
                              const SizedBox(width: 13),
                              Expanded(
                                child: Text(
                                  _displayName,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontSize: 19,
                                    fontWeight: FontWeight.w700,
                                    color: _ink,
                                  ),
                                ),
                              ),
                              IconButton(
                                tooltip:
                                    widget.subscriptionId.startsWith(
                                      'local-file:',
                                    )
                                    ? '本地文件订阅，请重新导入文件更新'
                                    : '更新订阅',
                                onPressed:
                                    _updating ||
                                        widget.subscriptionId.startsWith(
                                          'local-file:',
                                        )
                                    ? null
                                    : _refresh,
                                icon: _updating
                                    ? const SizedBox(
                                        width: 20,
                                        height: 20,
                                        child:
                                            CircularProgressIndicator.adaptive(
                                              strokeWidth: 2,
                                            ),
                                      )
                                    : const Icon(
                                        Icons.refresh_rounded,
                                        color: _blue,
                                      ),
                              ),
                              IconButton(
                                tooltip: '测试此订阅全部节点',
                                onPressed: _testingIds.isNotEmpty
                                    ? null
                                    : () => _testProfiles(_servers),
                                icon: _testingIds.isNotEmpty
                                    ? const SizedBox(
                                        width: 18,
                                        height: 18,
                                        child:
                                            CircularProgressIndicator.adaptive(
                                              strokeWidth: 2,
                                            ),
                                      )
                                    : const Icon(
                                        Icons.speed_rounded,
                                        color: _blue,
                                      ),
                              ),
                              IconButton(
                                tooltip: '订阅设置',
                                onPressed: () async {
                                  await Navigator.of(context).push<bool>(
                                    MaterialPageRoute<bool>(
                                      builder: (_) => _SubscriptionManagerPage(
                                        engine: widget.engine,
                                        globalTun: widget.globalTun,
                                        downloader: widget.downloader,
                                      ),
                                    ),
                                  );
                                  _changed = true;
                                  await _load();
                                },
                                icon: const Icon(
                                  Icons.more_horiz_rounded,
                                  color: Color(0xFF8190A5),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      if (_error != null)
                        SliverPadding(
                          padding: const EdgeInsets.symmetric(horizontal: 22),
                          sliver: SliverToBoxAdapter(
                            child: _MessageCard(
                              icon: Icons.error_outline_rounded,
                              text: _error!,
                            ),
                          ),
                        ),
                      if (_servers.isEmpty)
                        const SliverToBoxAdapter(
                          child: Center(
                            child: Padding(
                              padding: EdgeInsets.all(30),
                              child: Text(
                                '此订阅中没有节点',
                                style: TextStyle(color: Color(0xFF71829B)),
                              ),
                            ),
                          ),
                        ),
                      SliverPadding(
                        padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
                        sliver: SliverList.builder(
                          itemCount: _serverSections.length,
                          itemBuilder: (context, index) {
                            final section = _serverSections[index];
                            return Padding(
                              padding: const EdgeInsets.only(bottom: 8),
                              child: _Glass(
                                padding: EdgeInsets.zero,
                                radius: 18,
                                blur: false,
                                color: Colors.white.withValues(alpha: .8),
                                child: Theme(
                                  data: Theme.of(
                                    context,
                                  ).copyWith(dividerColor: Colors.transparent),
                                  child: ExpansionTile(
                                    initiallyExpanded: true,
                                    tilePadding: const EdgeInsets.symmetric(
                                      horizontal: 15,
                                    ),
                                    childrenPadding: const EdgeInsets.fromLTRB(
                                      10,
                                      0,
                                      10,
                                      8,
                                    ),
                                    leading: Icon(
                                      section.type == '自动测速'
                                          ? Icons.bolt_rounded
                                          : section.type == '故障转移'
                                          ? Icons.swap_horiz_rounded
                                          : section.type == '负载均衡'
                                          ? Icons.balance_rounded
                                          : Icons.folder_outlined,
                                      color: _blue,
                                    ),
                                    title: Text(
                                      section.title,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        color: _ink,
                                        fontSize: 13,
                                        fontWeight: FontWeight.w800,
                                      ),
                                    ),
                                    subtitle: Text(
                                      '${section.type} · ${section.servers.length} 个节点',
                                      style: const TextStyle(
                                        color: Color(0xFF7889A0),
                                        fontSize: 10,
                                      ),
                                    ),
                                    children: [
                                      for (final server in section.servers)
                                        Padding(
                                          padding: const EdgeInsets.only(
                                            bottom: 7,
                                          ),
                                          child: _ServerTile(
                                            server: server,
                                            active: server.id == _activeId,
                                            connected:
                                                server.id == _activeId &&
                                                _connected,
                                            lastSyncTime: _lastSyncTime,
                                            onTap: () {
                                              if (!_selecting) _select(server);
                                            },
                                            onDelete: () => _remove(server),
                                            result: _probeResults[server.id],
                                            testing: _testingIds.contains(
                                              server.id,
                                            ),
                                            onTest: () =>
                                                _testProfiles([server]),
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                    ],
                  ),
                ),
        ),
      ],
    ),
  );
}

class _SubscriptionManagerPage extends StatefulWidget {
  const _SubscriptionManagerPage({
    required this.engine,
    required this.globalTun,
    required this.downloader,
  });
  final SingBox engine;
  final bool globalTun;
  final SubscriptionDownloader downloader;
  @override
  State<_SubscriptionManagerPage> createState() =>
      _SubscriptionManagerPageState();
}

class _SubscriptionManagerPageState extends State<_SubscriptionManagerPage> {
  List<String> _subscriptions = const [];
  Map<String, String> _names = {};
  Map<String, DateTime> _syncTimes = {};
  final Set<String> _working = {};
  bool _loading = true;
  bool _changed = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final servers = await widget.engine.getServerConfigs();
      final names = await _readSubscriptionNames();
      final syncTimes = await _readSubscriptionSyncTimes();
      final subscriptions = servers
          .map((server) => server.subscriptionId)
          .whereType<String>()
          .where(_isSubscriptionGroupId)
          .toSet()
          .toList();
      if (mounted)
        setState(() {
          _subscriptions = subscriptions;
          _names = names;
          _syncTimes = syncTimes;
          _loading = false;
        });
    } on Object catch (error) {
      if (mounted)
        setState(() {
          _error = error.toString();
          _loading = false;
        });
    }
  }

  Future<void> _rename(String id) async {
    final controller = TextEditingController(
      text: _names[id] ?? _subscriptionFallbackName(id),
    );
    final name = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: Colors.transparent,
        elevation: 0,
        contentPadding: EdgeInsets.zero,
        content: _Glass(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '订阅组名称',
                style: TextStyle(
                  color: _ink,
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: controller,
                autofocus: true,
                maxLength: 40,
                decoration: const InputDecoration(hintText: '输入自定义名称'),
              ),
              const SizedBox(height: 10),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(dialogContext).pop(),
                    child: const Text('取消'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: () =>
                        Navigator.of(dialogContext).pop(controller.text.trim()),
                    child: const Text('保存'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
    controller.dispose();
    if (name == null) return;
    final value = name.trim();
    await _saveSubscriptionName(id, value);
    if (mounted) {
      setState(() {
        _names = Map<String, String>.from(_names);
        if (value.isEmpty) {
          _names.remove(id);
        } else {
          _names[id] = value;
        }
      });
    }
    _changed = true;
  }

  Future<void> _refreshLocal(String id) async {
    if (_working.contains(id)) return;
    setState(() {
      _working.add(id);
      _error = null;
    });
    try {
      final file = await _localFilesChannel.invokeMapMethod<String, String>(
        'pickYamlFile',
      );
      if (file == null) return;
      await _installSubscription(
        widget.engine,
        file['content'] ?? '',
        subscriptionId: id,
        globalTun: widget.globalTun,
        downloader: widget.downloader,
      );
      _changed = true;
      await _load();
    } on Object catch (error) {
      if (mounted) {
        setState(
          () => _error = error.toString().replaceFirst('Exception: ', ''),
        );
      }
    } finally {
      if (mounted) setState(() => _working.remove(id));
    }
  }

  Future<void> _refresh(String url) async {
    setState(() {
      _working.add(url);
      _error = null;
    });
    try {
      final response = await widget.downloader(
        url,
        validate: isSupportedSubscriptionBody,
      );
      final previous = await widget.engine.getServerConfigs();
      final active = await widget.engine.getActiveServerConfig();
      final oldGroup = previous
          .where((server) => server.subscriptionId == url)
          .toList();
      final installed = await _installSubscription(
        widget.engine,
        response.body,
        subscriptionId: url,
        globalTun: widget.globalTun,
        sourceUrl: url,
        downloader: widget.downloader,
      );
      final imported = installed.servers;
      if (active != null && oldGroup.any((server) => server.id == active.id)) {
        final replacement =
            imported
                .where(
                  (server) =>
                      server.server == active.server &&
                      server.port == active.port,
                )
                .firstOrNull ??
            imported.first;
        await widget.engine.setActiveServerConfig(replacement.id);
        if ((await widget.engine.getConnectionStatus()).isActive) {
          final all = await widget.engine.getServerConfigs();
          if (all.where((server) => server.enabled).length > 1) {
            await widget.engine.connectToServers(
              all,
              selectedId: replacement.id,
            );
          } else {
            await widget.engine.connectToServer(replacement);
          }
        }
      }
      _changed = true;
      await _load();
    } on Object catch (error) {
      if (mounted)
        setState(
          () => _error = error.toString().replaceFirst('Exception: ', ''),
        );
    } finally {
      if (mounted) setState(() => _working.remove(url));
    }
  }

  Future<void> _remove(String url) async {
    try {
      final servers = await widget.engine.getServerConfigs();
      final active = await widget.engine.getActiveServerConfig();
      final group = servers
          .where((server) => server.subscriptionId == url)
          .toList();
      await widget.engine.clearServerConfigs(subscriptionId: url);
      await _removeSubscriptionGeodata(url);
      await _saveSubscriptionName(url, '');
      await _removeSubscriptionSyncTime(url);
      if (active != null && group.any((server) => server.id == active.id)) {
        final remaining = await widget.engine.getServerConfigs();
        await widget.engine.setActiveServerConfig(remaining.firstOrNull?.id);
      }
      _changed = true;
      await _load();
    } on Object catch (error) {
      if (mounted) setState(() => _error = error.toString());
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Stack(
      children: [
        const _AmbientBackground(),
        SafeArea(
          child: _loading
              ? const Center(child: CircularProgressIndicator.adaptive())
              : Scrollbar(
                  child: CustomScrollView(
                    slivers: [
                      SliverPadding(
                        padding: const EdgeInsets.fromLTRB(22, 16, 22, 20),
                        sliver: SliverToBoxAdapter(
                          child: Row(
                            children: [
                              _SmallIconButton(
                                icon: Icons.arrow_back_rounded,
                                tooltip: '返回',
                                onTap: () =>
                                    Navigator.of(context).pop(_changed),
                              ),
                              const SizedBox(width: 13),
                              const Expanded(
                                child: Text(
                                  '订阅管理',
                                  style: TextStyle(
                                    fontSize: 21,
                                    fontWeight: FontWeight.w700,
                                    color: _ink,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      if (_error != null)
                        SliverPadding(
                          padding: const EdgeInsets.symmetric(horizontal: 22),
                          sliver: SliverToBoxAdapter(
                            child: _MessageCard(
                              icon: Icons.error_outline_rounded,
                              text: _error!,
                            ),
                          ),
                        ),
                      if (_subscriptions.isEmpty)
                        SliverPadding(
                          padding: const EdgeInsets.symmetric(horizontal: 22),
                          sliver: SliverToBoxAdapter(
                            child: _Glass(
                              child: const Column(
                                children: [
                                  Icon(
                                    Icons.rss_feed_rounded,
                                    color: _blue,
                                    size: 30,
                                  ),
                                  SizedBox(height: 10),
                                  Text(
                                    '还没有订阅',
                                    style: TextStyle(
                                      color: _ink,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                  SizedBox(height: 5),
                                  Text(
                                    '通过节点页添加订阅地址后，可在此手动更新。',
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                      color: Color(0xFF71829B),
                                      fontSize: 12,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      SliverPadding(
                        padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
                        sliver: SliverList.builder(
                          itemCount: _subscriptions.length,
                          itemBuilder: (context, index) {
                            final url = _subscriptions[index];
                            final working = _working.contains(url);
                            final isLocal = url.startsWith('local-file:');
                            final title =
                                _names[url] ?? _subscriptionFallbackName(url);
                            return Padding(
                              padding: const EdgeInsets.only(bottom: 10),
                              child: _Glass(
                                padding: const EdgeInsets.fromLTRB(
                                  16,
                                  12,
                                  8,
                                  12,
                                ),
                                radius: 22,
                                blur: false,
                                color: Colors.white.withValues(alpha: .82),
                                child: Row(
                                  children: [
                                    Container(
                                      width: 40,
                                      height: 40,
                                      decoration: BoxDecoration(
                                        color: _blue.withValues(alpha: .1),
                                        borderRadius: BorderRadius.circular(14),
                                      ),
                                      child: const Icon(
                                        Icons.rss_feed_rounded,
                                        color: _blue,
                                        size: 20,
                                      ),
                                    ),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            title,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: const TextStyle(
                                              fontSize: 13,
                                              fontWeight: FontWeight.w700,
                                              color: _ink,
                                            ),
                                          ),
                                          Text(
                                            isLocal ? '本地 YAML 配置文件' : url,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: const TextStyle(
                                              fontSize: 10,
                                              color: Color(0xFF8190A5),
                                            ),
                                          ),
                                          Text(
                                            '最后同步 · ${_formatSubscriptionSyncTime(_syncTimes[url])}',
                                            style: const TextStyle(
                                              fontSize: 10,
                                              color: Color(0xFF8190A5),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                    IconButton(
                                      tooltip: isLocal ? '重新选择本地文件更新' : '更新订阅',
                                      onPressed: working
                                          ? null
                                          : () => isLocal
                                                ? _refreshLocal(url)
                                                : _refresh(url),
                                      icon: working
                                          ? const SizedBox(
                                              width: 20,
                                              height: 20,
                                              child:
                                                  CircularProgressIndicator.adaptive(
                                                    strokeWidth: 2,
                                                  ),
                                            )
                                          : Icon(
                                              isLocal
                                                  ? Icons.folder_open_rounded
                                                  : Icons.refresh_rounded,
                                              color: _blue,
                                            ),
                                    ),
                                    IconButton(
                                      tooltip: '修改订阅组名称',
                                      onPressed: working
                                          ? null
                                          : () => _rename(url),
                                      icon: const Icon(
                                        Icons.edit_outlined,
                                        color: _blue,
                                      ),
                                    ),
                                    IconButton(
                                      tooltip: '删除订阅',
                                      onPressed: working
                                          ? null
                                          : () => _remove(url),
                                      icon: const Icon(
                                        Icons.delete_outline_rounded,
                                        color: Color(0xFF8190A5),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                    ],
                  ),
                ),
        ),
      ],
    ),
  );
}

class _ImportRequest {
  const _ImportRequest({
    required this.content,
    required this.customName,
    this.localFile = false,
    this.fileName,
  });
  final String content;
  final String customName;
  final bool localFile;
  final String? fileName;
}

class _ImportProfilePage extends StatefulWidget {
  const _ImportProfilePage();

  @override
  State<_ImportProfilePage> createState() => _ImportProfilePageState();
}

class _ImportProfilePageState extends State<_ImportProfilePage> {
  final _controller = TextEditingController();
  final _nameController = TextEditingController();
  String? _pickedFileName;
  String? _suggestedName;

  @override
  void dispose() {
    _controller.dispose();
    _nameController.dispose();
    super.dispose();
  }

  void _close([_ImportRequest? value]) {
    FocusManager.instance.primaryFocus?.unfocus();
    Navigator.of(context).pop(value);
  }

  Future<void> _pickLocalYaml() async {
    try {
      final file = await _localFilesChannel.invokeMapMethod<String, String>(
        'pickYamlFile',
      );
      if (!mounted || file == null) return;
      final fileName = file['name'] ?? 'config.yaml';
      final suggestedName = fileName.replaceFirst(
        RegExp(r'\.(yaml|yml|yam)$', caseSensitive: false),
        '',
      );
      setState(() {
        final previousSuggestedName = _suggestedName;
        _pickedFileName = fileName;
        _suggestedName = suggestedName;
        _controller.text = file['content'] ?? '';
        if (_nameController.text.trim().isEmpty ||
            _nameController.text == previousSuggestedName) {
          _nameController.text = suggestedName;
        }
      });
    } on Object catch (error) {
      if (mounted) _showGlassNotice(context, '读取本地配置失败：$error');
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    resizeToAvoidBottomInset: true,
    body: Stack(
      children: [
        const _AmbientBackground(),
        SafeArea(
          child: CustomScrollView(
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            slivers: [
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(22, 16, 22, 20),
                sliver: SliverToBoxAdapter(
                  child: Row(
                    children: [
                      _SmallIconButton(
                        icon: Icons.arrow_back_rounded,
                        tooltip: '返回',
                        onTap: () => _close(),
                      ),
                      const SizedBox(width: 14),
                      const Expanded(
                        child: Text(
                          '添加节点 / 订阅',
                          style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.w700,
                            color: _ink,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              SliverPadding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                sliver: SliverToBoxAdapter(
                  child: _Glass(
                    padding: const EdgeInsets.all(22),
                    radius: 28,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          '导入代理配置',
                          style: TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w700,
                            color: _ink,
                          ),
                        ),
                        const SizedBox(height: 8),
                        const Text(
                          '可在线添加订阅，也可从设备选择 YAML 配置文件。订阅组支持自定义名称。',
                          style: TextStyle(
                            color: Color(0xFF60718C),
                            height: 1.5,
                            fontSize: 13,
                          ),
                        ),
                        const SizedBox(height: 18),
                        TextField(
                          controller: _nameController,
                          textCapitalization: TextCapitalization.sentences,
                          decoration: const InputDecoration(
                            labelText: '订阅组名称（可选）',
                            hintText: '例如：我的机场 / 家庭配置',
                          ),
                        ),
                        const SizedBox(height: 12),
                        SizedBox(
                          width: double.infinity,
                          child: OutlinedButton.icon(
                            onPressed: _pickLocalYaml,
                            icon: const Icon(Icons.folder_open_rounded),
                            label: Text(
                              _pickedFileName == null
                                  ? '选择本地 YAML / YAM 文件'
                                  : '已选择：$_pickedFileName',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          controller: _controller,
                          minLines: 5,
                          maxLines: 10,
                          keyboardType: TextInputType.multiline,
                          textCapitalization: TextCapitalization.none,
                          autocorrect: false,
                          decoration: const InputDecoration(
                            labelText: '在线订阅地址 / 分享链接 / 配置内容',
                            hintText: 'https://… 或 vless://… / YAML 内容',
                          ),
                        ),
                        const SizedBox(height: 20),
                        Row(
                          children: [
                            Expanded(
                              child: OutlinedButton(
                                onPressed: () => _close(),
                                child: const Padding(
                                  padding: EdgeInsets.symmetric(vertical: 13),
                                  child: Text('取消'),
                                ),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: FilledButton.icon(
                                onPressed: () => _close(
                                  _ImportRequest(
                                    content: _controller.text,
                                    customName: _nameController.text,
                                    localFile: _pickedFileName != null,
                                    fileName: _pickedFileName,
                                  ),
                                ),
                                icon: const Icon(Icons.add_rounded),
                                label: const Padding(
                                  padding: EdgeInsets.symmetric(vertical: 13),
                                  child: Text('导入'),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              const SliverPadding(padding: EdgeInsets.only(bottom: 28)),
            ],
          ),
        ),
      ],
    ),
  );
}

class _AmbientBackground extends StatelessWidget {
  const _AmbientBackground();
  @override
  Widget build(BuildContext context) => Positioned.fill(
    child: IgnorePointer(
      child: Stack(
        children: [
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  Color(0xFFF8FBFF),
                  Color(0xFFEAF2FD),
                  Color(0xFFF2F6FC),
                ],
              ),
            ),
          ),
          Positioned(
            top: -100,
            right: -90,
            child: _Glow(size: 280, color: _blue.withValues(alpha: .17)),
          ),
          Positioned(
            top: 310,
            left: -155,
            child: _Glow(size: 300, color: _mint.withValues(alpha: .14)),
          ),
          Positioned(
            bottom: -180,
            right: -100,
            child: _Glow(
              size: 320,
              color: const Color(0xFFB6A7FF).withValues(alpha: .16),
            ),
          ),
        ],
      ),
    ),
  );
}

class _Glow extends StatelessWidget {
  const _Glow({required this.size, required this.color});
  final double size;
  final Color color;
  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      shape: BoxShape.circle,
      color: color,
      boxShadow: [
        BoxShadow(
          color: color,
          blurRadius: size * .55,
          spreadRadius: size * .12,
        ),
      ],
    ),
  );
}

class _Glass extends StatelessWidget {
  const _Glass({
    required this.child,
    this.padding = const EdgeInsets.all(18),
    this.radius = 26,
    this.color,
    this.borderColor,
    this.blur = true,
  });
  final Widget child;
  final EdgeInsetsGeometry padding;
  final double radius;
  final Color? color;
  final Color? borderColor;
  final bool blur;
  @override
  Widget build(BuildContext context) {
    final sourceTint = color ?? Colors.white;
    final tint = sourceTint.withValues(
      alpha: ((color?.a ?? .36) * .32).clamp(.06, .2),
    );
    final panel = Container(
      padding: padding,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Colors.white.withValues(alpha: .30),
            tint,
            const Color(0xFFEAF3FF).withValues(alpha: .16),
          ],
          stops: const [0, .46, 1],
        ),
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(
          color: borderColor ?? Colors.white.withValues(alpha: .62),
          width: 1.1,
        ),
      ),
      child: child,
    );
    final liquidSurface = Stack(
      children: [
        panel,
        Positioned.fill(
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.white.withValues(alpha: .18),
                    Colors.white.withValues(alpha: .015),
                    const Color(0xFF9EC5FF).withValues(alpha: .055),
                  ],
                  stops: const [0, .32, 1],
                ),
              ),
            ),
          ),
        ),
        Positioned(
          top: .7,
          left: radius * .72,
          right: radius * .72,
          child: IgnorePointer(
            child: Container(
              height: 1.15,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    Colors.white.withValues(alpha: .05),
                    Colors.white.withValues(alpha: .96),
                    Colors.white.withValues(alpha: .42),
                    Colors.white.withValues(alpha: .04),
                  ],
                ),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
        ),
        Positioned(
          top: -34,
          right: -26,
          child: IgnorePointer(
            child: Transform.rotate(
              angle: -.28,
              child: Container(
                width: 128,
                height: 72,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(80),
                  gradient: RadialGradient(
                    colors: [
                      Colors.white.withValues(alpha: .36),
                      Colors.white.withValues(alpha: .12),
                      Colors.white.withValues(alpha: 0),
                    ],
                    stops: const [0, .48, 1],
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF5879A8).withValues(alpha: .08),
            blurRadius: 28,
            offset: const Offset(0, 12),
          ),
          BoxShadow(
            color: Colors.white.withValues(alpha: .48),
            blurRadius: 1,
            spreadRadius: -1,
            offset: const Offset(-1, -1),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: BackdropFilter(
          filter: ImageFilter.blur(
            sigmaX: blur ? 12 : 3,
            sigmaY: blur ? 12 : 3,
          ),
          child: liquidSurface,
        ),
      ),
    );
  }
}

void _showGlassNotice(
  BuildContext context,
  String message, {
  Duration duration = const Duration(seconds: 4),
}) {
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger == null) return;
  final isError = RegExp(r'失败|错误|无效|超时|请填写|需要设置').hasMatch(message);
  final isSuccess = RegExp(r'成功|已保存|已复制|已关闭|完成').hasMatch(message);
  final icon = isError
      ? Icons.error_outline_rounded
      : isSuccess
      ? Icons.check_circle_outline_rounded
      : Icons.info_outline_rounded;
  final color = isError
      ? const Color(0xFFC85E6D)
      : isSuccess
      ? _mint
      : _blue;
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: _Glass(
          padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 13),
          radius: 19,
          blur: true,
          color: Colors.white.withValues(alpha: .96),
          borderColor: Colors.white.withValues(alpha: .94),
          child: Row(
            children: [
              Container(
                width: 31,
                height: 31,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: .1),
                  shape: BoxShape.circle,
                ),
                child: Icon(icon, color: color, size: 18),
              ),
              const SizedBox(width: 11),
              Expanded(
                child: Text(
                  message,
                  style: const TextStyle(
                    color: _ink,
                    fontSize: 12,
                    height: 1.35,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ),
        backgroundColor: Colors.transparent,
        elevation: 0,
        padding: EdgeInsets.zero,
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 18),
        duration: duration,
      ),
    );
}

class _Header extends StatelessWidget {
  const _Header({required this.onSettings});
  final VoidCallback onSettings;
  @override
  Widget build(BuildContext context) => Row(
    children: [
      ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: Image.asset(
          'assets/images/hourglass_icon.png',
          width: 48,
          height: 48,
          fit: BoxFit.cover,
        ),
      ),
      const SizedBox(width: 13),
      const Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Hourglass',
              style: TextStyle(
                fontSize: 21,
                height: 1.1,
                fontWeight: FontWeight.w800,
                color: _ink,
              ),
            ),
            SizedBox(height: 3),
            Text(
              '轻盈、安全的网络连接',
              style: TextStyle(fontSize: 12, color: Color(0xFF71829B)),
            ),
          ],
        ),
      ),
      _SmallIconButton(
        icon: Icons.tune_rounded,
        onTap: onSettings,
        tooltip: '设置',
      ),
    ],
  );
}

class _HomeProfileCard extends StatelessWidget {
  const _HomeProfileCard({
    required this.server,
    required this.count,
    required this.onTap,
    required this.onAdd,
  });
  final SingBoxServerConfig? server;
  final int count;
  final VoidCallback onTap, onAdd;

  @override
  Widget build(BuildContext context) => _Glass(
    padding: EdgeInsets.zero,
    radius: 23,
    blur: false,
    color: Colors.white.withValues(alpha: .78),
    child: InkWell(
      onTap: count == 0 ? onAdd : onTap,
      borderRadius: BorderRadius.circular(23),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 17, vertical: 16),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: _blue.withValues(alpha: .11),
                borderRadius: BorderRadius.circular(15),
              ),
              child: const Icon(Icons.dns_rounded, color: _blue),
            ),
            const SizedBox(width: 13),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    server?.name ?? '还没有代理节点',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: _ink,
                      fontWeight: FontWeight.w700,
                      fontSize: 14,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    server == null
                        ? '添加一个节点或订阅开始使用'
                        : '${server!.protocol.toUpperCase()} · ${server!.server}:${server!.port} · $count 个配置',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Color(0xFF7B8AA0),
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
            ),
            const Icon(Icons.chevron_right_rounded, color: Color(0xFF8998AC)),
          ],
        ),
      ),
    ),
  );
}

class _ProxyOverridesPage extends StatefulWidget {
  const _ProxyOverridesPage({required this.initial, required this.onSave});
  final _HourglassOverrides initial;
  final Future<void> Function(_HourglassOverrides) onSave;
  @override
  State<_ProxyOverridesPage> createState() => _ProxyOverridesPageState();
}

class _ProxyOverridesPageState extends State<_ProxyOverridesPage> {
  late _HourglassOverrides _value = widget.initial;
  late final TextEditingController _port = TextEditingController(
    text: '${_value.port}',
  );
  late final TextEditingController _username = TextEditingController(
    text: _value.username,
  );
  late final TextEditingController _password = TextEditingController(
    text: _value.password.isEmpty ? _newPassword() : _value.password,
  );
  List<String> _addresses = const [];
  List<String> _ipv6Addresses = const [];
  bool _saving = false;
  bool _showPassword = false;

  String _newPassword() {
    const alphabet = 'abcdefghjkmnpqrstuvwxyzABCDEFGHJKMNPQRSTUVWXYZ23456789';
    final random = Random.secure();
    return List.generate(
      14,
      (_) => alphabet[random.nextInt(alphabet.length)],
    ).join();
  }

  @override
  void initState() {
    super.initState();
    _readAddresses();
  }

  Future<void> _readAddresses() async {
    try {
      final interfaces = await NetworkInterface.list(
        includeLoopback: false,
        type: InternetAddressType.IPv4,
      );
      final ipv6Interfaces = await NetworkInterface.list(
        includeLoopback: false,
        type: InternetAddressType.IPv6,
      );
      final addresses = interfaces
          .expand((item) => item.addresses)
          .map((address) => address.address)
          .where(
            (address) =>
                address.startsWith('10.') ||
                address.startsWith('192.168.') ||
                (address.startsWith('172.') &&
                    (int.tryParse(
                              address.split('.').elementAtOrNull(1) ?? '',
                            ) ??
                            0) >=
                        16 &&
                    (int.tryParse(
                              address.split('.').elementAtOrNull(1) ?? '',
                            ) ??
                            0) <=
                        31),
          )
          .where((address) => !address.startsWith('172.19.'))
          .toSet()
          .toList();
      final ipv6Addresses = ipv6Interfaces
          .expand((item) => item.addresses)
          .where(
            (address) =>
                !address.isLoopback &&
                !address.isLinkLocal &&
                !address.isMulticast &&
                !address.address.toLowerCase().startsWith('fdfe:dcba:'),
          )
          .map((address) => address.address)
          .toSet()
          .toList();
      if (mounted)
        setState(() {
          _addresses = addresses;
          _ipv6Addresses = ipv6Addresses;
        });
    } on Object {
      if (mounted)
        setState(() {
          _addresses = const [];
          _ipv6Addresses = const [];
        });
    }
  }

  Future<void> _copy(String value) async {
    await Clipboard.setData(ClipboardData(text: value));
    if (mounted) _showGlassNotice(context, '已复制');
  }

  Future<void> _save() async {
    if (_saving) return;
    final port = int.tryParse(_port.text.trim());
    if (port == null || port < 1 || port > 65535) {
      _showGlassNotice(context, '端口需为 1–65535');
      return;
    }
    if (_value.allowLan &&
        (_username.text.trim().isEmpty || _password.text.isEmpty)) {
      _showGlassNotice(context, '局域网代理需要设置用户名和密码');
      return;
    }
    setState(() => _saving = true);
    try {
      await widget.onSave(
        _value.copyWith(
          port: port,
          username: _username.text.trim(),
          password: _password.text,
        ),
      );
      if (mounted) {
        _showGlassNotice(context, '覆写设置已保存；如运行配置未自动更新，请手动重连');
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  void dispose() {
    _port.dispose();
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Stack(
      children: [
        const _AmbientBackground(),
        SafeArea(
          child: CustomScrollView(
            slivers: [
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(22, 16, 18, 18),
                sliver: SliverToBoxAdapter(
                  child: Row(
                    children: [
                      _SmallIconButton(
                        icon: Icons.arrow_back_rounded,
                        tooltip: '返回',
                        onTap: () => Navigator.of(context).pop(),
                      ),
                      const SizedBox(width: 13),
                      const Expanded(
                        child: Text(
                          '覆写与局域网代理',
                          style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.w700,
                            color: _ink,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              SliverPadding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                sliver: SliverToBoxAdapter(
                  child: Column(
                    children: [
                      _Glass(
                        padding: const EdgeInsets.all(18),
                        radius: 22,
                        blur: false,
                        color: Colors.white.withValues(alpha: .86),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              '配置覆写',
                              style: TextStyle(
                                color: _ink,
                                fontWeight: FontWeight.w800,
                                fontSize: 15,
                              ),
                            ),
                            const SizedBox(height: 8),
                            const Text(
                              '这些设置会覆写订阅配置中的对应运行参数，类似 Clash 的全局覆写。',
                              style: TextStyle(
                                color: Color(0xFF71829B),
                                fontSize: 11,
                                height: 1.45,
                              ),
                            ),
                            SwitchListTile(
                              contentPadding: EdgeInsets.zero,
                              title: const Text(
                                'FakeIP DNS',
                                style: TextStyle(
                                  color: _ink,
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              subtitle: const Text(
                                '代理常用模式；为代理域名返回映射地址以保留域名分流',
                                style: TextStyle(fontSize: 10),
                              ),
                              value: _value.fakeIp,
                              onChanged: (v) => setState(
                                () => _value = _value.copyWith(fakeIp: v),
                              ),
                            ),
                            SwitchListTile(
                              contentPadding: EdgeInsets.zero,
                              title: const Text(
                                'TUN IPv6',
                                style: TextStyle(
                                  color: _ink,
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              subtitle: const Text(
                                '默认关闭；仅控制 VPN/TUN 接管 IPv6 流量',
                                style: TextStyle(fontSize: 10),
                              ),
                              value: _value.tunIpv6,
                              onChanged: (v) => setState(
                                () => _value = _value.copyWith(tunIpv6: v),
                              ),
                            ),
                            SwitchListTile(
                              contentPadding: EdgeInsets.zero,
                              title: const Text(
                                '流量嗅探',
                                style: TextStyle(
                                  color: _ink,
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              subtitle: const Text(
                                '识别 TLS/HTTP 主机名以匹配分流规则',
                                style: TextStyle(fontSize: 10),
                              ),
                              value: _value.sniff,
                              onChanged: (v) => setState(
                                () => _value = _value.copyWith(sniff: v),
                              ),
                            ),
                            Row(
                              children: [
                                const Expanded(
                                  child: Text(
                                    'TUN MTU',
                                    style: TextStyle(
                                      color: _ink,
                                      fontSize: 13,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                                Text(
                                  '${_value.mtu}',
                                  style: const TextStyle(
                                    color: Color(0xFF71829B),
                                    fontSize: 12,
                                  ),
                                ),
                              ],
                            ),
                            Slider(
                              value: _value.mtu.toDouble(),
                              min: 1280,
                              max: 9000,
                              divisions: 77,
                              label: '${_value.mtu}',
                              onChanged: (v) => setState(
                                () => _value = _value.copyWith(
                                  mtu: (v / 100).round() * 100,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 12),
                      _Glass(
                        padding: const EdgeInsets.all(18),
                        radius: 22,
                        blur: false,
                        color: Colors.white.withValues(alpha: .86),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                const Expanded(
                                  child: Text(
                                    '局域网代理',
                                    style: TextStyle(
                                      color: _ink,
                                      fontWeight: FontWeight.w800,
                                      fontSize: 15,
                                    ),
                                  ),
                                ),
                                Switch(
                                  value: _value.allowLan,
                                  onChanged: (v) => setState(
                                    () => _value = _value.copyWith(allowLan: v),
                                  ),
                                ),
                              ],
                            ),
                            const Text(
                              '允许同一局域网的其他设备通过本机代理端口连接。需要 Hourglass VPN 服务处于运行状态。',
                              style: TextStyle(
                                color: Color(0xFF71829B),
                                fontSize: 11,
                                height: 1.45,
                              ),
                            ),
                            if (_value.allowLan) ...[
                              const SizedBox(height: 8),
                              const Text(
                                '安全要求：代理只应在可信 Wi-Fi 中开放；端口绑定所有网络接口，且 HTTP 代理认证在局域网内不提供传输加密。应用会强制账号密码，IPv6 监听默认关闭。',
                                style: TextStyle(
                                  color: Color(0xFFB06B39),
                                  fontSize: 10,
                                  height: 1.4,
                                ),
                              ),
                            ],
                            if (_value.allowLan) ...[
                              const SizedBox(height: 12),
                              DropdownButtonFormField<String>(
                                initialValue: _value.protocol,
                                isExpanded: true,
                                decoration: const InputDecoration(
                                  labelText: '代理协议',
                                  border: OutlineInputBorder(),
                                ),
                                selectedItemBuilder: (context) => const [
                                  Align(
                                    alignment: Alignment.centerLeft,
                                    child: Text(
                                      '复合端口（HTTP + SOCKS）',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                  Align(
                                    alignment: Alignment.centerLeft,
                                    child: Text(
                                      'HTTP / HTTPS CONNECT',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                  Align(
                                    alignment: Alignment.centerLeft,
                                    child: Text(
                                      'SOCKS4 / 4a / 5',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                ],
                                items: const [
                                  DropdownMenuItem(
                                    value: 'mixed',
                                    child: Text(
                                      '复合端口（HTTP(S) CONNECT + SOCKS4/4a/5）',
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                  DropdownMenuItem(
                                    value: 'http',
                                    child: Text(
                                      'HTTP 代理（支持 HTTPS CONNECT）',
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                  DropdownMenuItem(
                                    value: 'socks',
                                    child: Text(
                                      'SOCKS4 / 4a / 5',
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                ],
                                onChanged: (v) {
                                  if (v != null)
                                    setState(
                                      () =>
                                          _value = _value.copyWith(protocol: v),
                                    );
                                },
                              ),
                              const SizedBox(height: 10),
                              TextField(
                                controller: _port,
                                keyboardType: TextInputType.number,
                                decoration: const InputDecoration(
                                  labelText: '监听端口',
                                  hintText: '7897',
                                  border: OutlineInputBorder(),
                                ),
                              ),
                              const SizedBox(height: 6),
                              TextField(
                                controller: _username,
                                autocorrect: false,
                                decoration: const InputDecoration(
                                  labelText: '认证用户名',
                                  border: OutlineInputBorder(),
                                ),
                              ),
                              const SizedBox(height: 10),
                              TextField(
                                controller: _password,
                                autocorrect: false,
                                obscureText: !_showPassword,
                                decoration: InputDecoration(
                                  labelText: '认证密码',
                                  border: const OutlineInputBorder(),
                                  suffixIcon: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      IconButton(
                                        tooltip: _showPassword
                                            ? '隐藏密码'
                                            : '显示密码',
                                        icon: Icon(
                                          _showPassword
                                              ? Icons.visibility_off_rounded
                                              : Icons.visibility_rounded,
                                        ),
                                        onPressed: () => setState(
                                          () => _showPassword = !_showPassword,
                                        ),
                                      ),
                                      IconButton(
                                        tooltip: '生成新密码',
                                        icon: const Icon(Icons.refresh_rounded),
                                        onPressed: () => setState(
                                          () => _password.text = _newPassword(),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                              SwitchListTile(
                                contentPadding: EdgeInsets.zero,
                                title: const Text(
                                  'IPv6 局域网监听',
                                  style: TextStyle(
                                    color: _ink,
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                subtitle: const Text(
                                  '默认关闭；开启后监听设备可用的 IPv6 地址',
                                  style: TextStyle(fontSize: 10),
                                ),
                                value: _value.ipv6Proxy,
                                onChanged: (v) => setState(
                                  () => _value = _value.copyWith(ipv6Proxy: v),
                                ),
                              ),
                              ListTile(
                                contentPadding: EdgeInsets.zero,
                                leading: const Icon(
                                  Icons.info_outline_rounded,
                                  color: Color(0xFF8190A5),
                                ),
                                title: const Text(
                                  'TProxy',
                                  style: TextStyle(
                                    color: _ink,
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                subtitle: const Text(
                                  'sing-box 的 TProxy 入站仅支持 Linux；Android 无 root 权限时不可用。',
                                  style: TextStyle(fontSize: 10),
                                ),
                                dense: true,
                              ),
                              const Divider(),
                              const Text(
                                '本机局域网地址',
                                style: TextStyle(
                                  color: _ink,
                                  fontWeight: FontWeight.w700,
                                  fontSize: 12,
                                ),
                              ),
                              if (_addresses.isEmpty)
                                const Padding(
                                  padding: EdgeInsets.only(top: 8),
                                  child: Text(
                                    '暂未获取到 Wi-Fi/以太网 IPv4 地址；请确认设备已连接局域网。',
                                    style: TextStyle(
                                      color: Color(0xFF8190A5),
                                      fontSize: 10,
                                    ),
                                  ),
                                ),
                              for (final address in _addresses)
                                ListTile(
                                  contentPadding: EdgeInsets.zero,
                                  dense: true,
                                  leading: const Icon(
                                    Icons.wifi_rounded,
                                    color: _blue,
                                    size: 18,
                                  ),
                                  title: Text(
                                    '$address:${_port.text.isEmpty ? _value.port : _port.text}',
                                    style: const TextStyle(
                                      color: _ink,
                                      fontSize: 12,
                                      fontFamily: 'monospace',
                                    ),
                                  ),
                                  trailing: IconButton(
                                    tooltip: '复制代理地址',
                                    icon: const Icon(
                                      Icons.copy_rounded,
                                      size: 17,
                                    ),
                                    onPressed: () => _copy(
                                      '$address:${_port.text.isEmpty ? _value.port : _port.text}',
                                    ),
                                  ),
                                ),
                            ],
                          ],
                        ),
                      ),
                      const SizedBox(height: 16),
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton.icon(
                          onPressed: _saving ? null : _save,
                          icon: _saving
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator.adaptive(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.save_rounded),
                          label: const Padding(
                            padding: EdgeInsets.symmetric(vertical: 13),
                            child: Text('保存并应用'),
                          ),
                        ),
                      ),
                      const SizedBox(height: 24),
                    ],
                  ),
                ),
              ),
              if (_value.ipv6Proxy)
                for (final address in _ipv6Addresses)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    leading: const Icon(
                      Icons.language_rounded,
                      color: _mint,
                      size: 18,
                    ),
                    title: Text(
                      '[$address]:${_port.text.isEmpty ? _value.port : _port.text}',
                      style: const TextStyle(
                        color: _ink,
                        fontSize: 11,
                        fontFamily: 'monospace',
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: IconButton(
                      tooltip: '复制 IPv6 代理地址',
                      icon: const Icon(Icons.copy_rounded, size: 17),
                      onPressed: () => _copy(
                        '[$address]:${_port.text.isEmpty ? _value.port : _port.text}',
                      ),
                    ),
                  ),
              if (_value.ipv6Proxy && _ipv6Addresses.isEmpty)
                const Padding(
                  padding: EdgeInsets.only(top: 7),
                  child: Text(
                    '未检测到可用 IPv6 地址；此网络可能没有 IPv6。',
                    style: TextStyle(color: Color(0xFF8190A5), fontSize: 10),
                  ),
                ),
            ],
          ),
        ),
      ],
    ),
  );
}

class _SettingsHub extends StatelessWidget {
  const _SettingsHub({
    required this.engine,
    required this.globalTun,
    required this.overrides,
    required this.onSaveOverrides,
  });
  final SingBox engine;
  final bool globalTun;
  final _HourglassOverrides overrides;
  final Future<void> Function(_HourglassOverrides) onSaveOverrides;

  void _open(BuildContext context, Widget page) {
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page));
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const Text(
        '设置',
        style: TextStyle(
          fontSize: 24,
          fontWeight: FontWeight.w800,
          color: _ink,
        ),
      ),
      const SizedBox(height: 4),
      const Text(
        '按需调整路由、DNS 与应用连接方式',
        style: TextStyle(color: Color(0xFF71829B), fontSize: 12),
      ),
      const SizedBox(height: 20),
      _Glass(
        padding: const EdgeInsets.all(15),
        radius: 20,
        blur: false,
        color: Colors.white.withValues(alpha: .82),
        child: const Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.verified_user_rounded, color: _mint, size: 20),
            SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '连接安全保护',
                    style: TextStyle(
                      color: _ink,
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  SizedBox(height: 4),
                  Text(
                    '凭据与连接配置使用 Android Keystore 加密；订阅仅允许 HTTPS 且始终校验证书；应用数据不参与备份。局域网代理默认关闭，启用时必须设置认证。',
                    style: TextStyle(
                      color: Color(0xFF7889A0),
                      fontSize: 10,
                      height: 1.45,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      const SizedBox(height: 17),
      _SettingsGroup(
        title: '网络',
        children: [
          _SettingsEntry(
            icon: Icons.alt_route_rounded,
            title: '路由与分流',
            subtitle: '国内直连、域名、网段、广告过滤',
            onTap: () => _open(
              context,
              _RoutingSettingsPage(engine: engine, globalTun: globalTun),
            ),
          ),
          _SettingsEntry(
            icon: Icons.dns_rounded,
            title: 'DNS',
            subtitle: '自定义 DNS 服务器',
            onTap: () => _open(
              context,
              _RoutingSettingsPage(
                engine: engine,
                globalTun: globalTun,
                initialSection: 'dns',
              ),
            ),
          ),
          _SettingsEntry(
            icon: Icons.phone_android_rounded,
            title: '应用代理',
            subtitle: '指定代理应用或排除应用',
            onTap: () => _open(
              context,
              _RoutingSettingsPage(
                engine: engine,
                globalTun: globalTun,
                initialSection: 'apps',
              ),
            ),
          ),
          _SettingsEntry(
            icon: Icons.lan_rounded,
            title: '覆写与局域网代理',
            subtitle: overrides.allowLan
                ? '局域网监听已启用 · 端口 ${overrides.port}'
                : '混合端口、协议、MTU 与 IPv6',
            onTap: () => _open(
              context,
              _ProxyOverridesPage(initial: overrides, onSave: onSaveOverrides),
            ),
          ),
        ],
      ),
      const SizedBox(height: 14),
      _SettingsGroup(
        title: '代理工具',
        children: [
          _SettingsEntry(
            icon: Icons.system_update_alt_rounded,
            title: '规则数据模块',
            subtitle: '连接成功后后台更新，失败不影响代理',
            onTap: () => _open(context, _RuleDataModulesPage(engine: engine)),
          ),
          _SettingsEntry(
            icon: Icons.hub_rounded,
            title: '代理组',
            subtitle: '切换选择器节点、运行自动测速',
            onTap: () => _open(context, _ProxyGroupsPage(engine: engine)),
          ),
          _SettingsEntry(
            icon: Icons.swap_horiz_rounded,
            title: '活动连接',
            subtitle: '查看目标地址、应用、规则和出口',
            onTap: () => _open(context, _ActiveConnectionsPage(engine: engine)),
          ),
          _SettingsEntry(
            icon: Icons.receipt_long_rounded,
            title: '运行日志',
            subtitle: '查看内核运行状态与诊断信息',
            onTap: () => _open(context, _RuntimeLogsPage(engine: engine)),
          ),
        ],
      ),
      const SizedBox(height: 14),
      _SettingsGroup(
        title: '连接',
        children: [
          _SettingsEntry(
            icon: Icons.shield_outlined,
            title: '自动连接与保护',
            subtitle: '启动连接、断线重连、系统启动',
            onTap: () =>
                _open(context, _ServicePreferencesPage(engine: engine)),
          ),
        ],
      ),
      const SizedBox(height: 14),
      _SettingsGroup(
        title: '关于',
        children: [
          _SettingsEntry(
            icon: Icons.info_outline_rounded,
            title: '关于 Hourglass',
            subtitle: 'ASwave · V$_appVersion · 项目介绍与开源仓库',
            onTap: () => _open(context, const _AboutPage()),
          ),
        ],
      ),
    ],
  );
}

class _AboutPage extends StatefulWidget {
  const _AboutPage();

  @override
  State<_AboutPage> createState() => _AboutPageState();
}

class _AboutPageState extends State<_AboutPage> {
  bool _checkingUpdate = false;

  Future<void> _checkUpdates() async {
    if (_checkingUpdate) return;
    setState(() => _checkingUpdate = true);
    await _checkForAppUpdate(context, showUpToDate: true);
    if (mounted) setState(() => _checkingUpdate = false);
  }

  Future<void> _openRepository(BuildContext context) async {
    try {
      await _externalLinkChannel.invokeMethod<bool>('openUrl', {
        'url': _repositoryUrl,
      });
    } on Object {
      await Clipboard.setData(const ClipboardData(text: _repositoryUrl));
      if (context.mounted) _showGlassNotice(context, '仓库地址已复制');
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Stack(
      children: [
        const _AmbientBackground(),
        SafeArea(
          child: CustomScrollView(
            slivers: [
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(22, 16, 22, 18),
                sliver: SliverToBoxAdapter(
                  child: Row(
                    children: [
                      _SmallIconButton(
                        icon: Icons.arrow_back_rounded,
                        tooltip: '返回',
                        onTap: () => Navigator.of(context).pop(),
                      ),
                      const SizedBox(width: 13),
                      const Text(
                        '关于 Hourglass',
                        style: TextStyle(
                          color: _ink,
                          fontSize: 21,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              SliverPadding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                sliver: SliverToBoxAdapter(
                  child: _Glass(
                    padding: const EdgeInsets.all(22),
                    radius: 26,
                    blur: false,
                    color: Colors.white.withValues(alpha: .86),
                    child: Column(
                      children: [
                        Container(
                          width: 76,
                          height: 76,
                          decoration: BoxDecoration(
                            color: const Color(0xFF0D1421),
                            borderRadius: BorderRadius.circular(23),
                          ),
                          alignment: Alignment.center,
                          child: const Text(
                            'H',
                            style: TextStyle(
                              color: Color(0xFF78C9E8),
                              fontSize: 48,
                              fontWeight: FontWeight.w300,
                            ),
                          ),
                        ),
                        const SizedBox(height: 14),
                        const Text(
                          'Hourglass',
                          style: TextStyle(
                            color: _ink,
                            fontSize: 25,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 4),
                        const Text(
                          'Hourglass By ASwave · V$_appVersion',
                          style: TextStyle(
                            color: Color(0xFF71829B),
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 20),
                        const Text(
                          '一款面向 Android 的轻量代理工具。Hourglass 基于 sing-box 核心，帮助你管理订阅与节点，并按需使用系统规则代理或 TUN 全局代理。应用分流、规则配置和连接状态集中呈现，让网络连接更清晰、更易掌控。',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: Color(0xFF53657E),
                            height: 1.65,
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(20, 14, 20, 26),
                sliver: SliverToBoxAdapter(
                  child: _Glass(
                    padding: const EdgeInsets.all(16),
                    radius: 22,
                    blur: false,
                    color: Colors.white.withValues(alpha: .82),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          '开源项目',
                          style: TextStyle(
                            color: _ink,
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 8),
                        const SelectableText(
                          _repositoryUrl,
                          style: TextStyle(
                            color: Color(0xFF526B91),
                            fontSize: 12,
                          ),
                        ),
                        const SizedBox(height: 10),
                        Row(
                          children: [
                            Expanded(
                              child: OutlinedButton.icon(
                                onPressed: () => _openRepository(context),
                                icon: const Icon(Icons.open_in_new_rounded),
                                label: const Text('打开 GitHub 仓库'),
                              ),
                            ),
                            const SizedBox(width: 8),
                            IconButton(
                              tooltip: '复制仓库地址',
                              onPressed: () async {
                                await Clipboard.setData(
                                  const ClipboardData(text: _repositoryUrl),
                                );
                                if (context.mounted) {
                                  _showGlassNotice(context, '仓库地址已复制');
                                }
                              },
                              icon: const Icon(
                                Icons.copy_rounded,
                                color: _blue,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        SizedBox(
                          width: double.infinity,
                          child: OutlinedButton.icon(
                            onPressed: _checkingUpdate ? null : _checkUpdates,
                            icon: _checkingUpdate
                                ? const SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator.adaptive(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Icon(Icons.system_update_alt_rounded),
                            label: Text(_checkingUpdate ? '正在检查…' : '检查更新'),
                          ),
                        ),
                        const Divider(height: 24),
                        const Center(
                          child: Text(
                            'Hourglass V$_appVersion',
                            style: TextStyle(
                              color: Color(0xFF8797AC),
                              fontSize: 11,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

class _SettingsGroup extends StatelessWidget {
  const _SettingsGroup({required this.title, required this.children});
  final String title;
  final List<Widget> children;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Padding(
        padding: const EdgeInsets.only(left: 4, bottom: 8),
        child: Text(
          title,
          style: const TextStyle(
            color: Color(0xFF74849A),
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      _Glass(
        padding: const EdgeInsets.symmetric(vertical: 3),
        radius: 22,
        blur: false,
        color: Colors.white.withValues(alpha: .78),
        child: Column(children: children),
      ),
    ],
  );
}

class _SettingsEntry extends StatelessWidget {
  const _SettingsEntry({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });
  final IconData icon;
  final String title, subtitle;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => ListTile(
    leading: Icon(icon, color: _blue),
    title: Text(
      title,
      style: const TextStyle(
        color: _ink,
        fontWeight: FontWeight.w600,
        fontSize: 14,
      ),
    ),
    subtitle: Text(
      subtitle,
      style: const TextStyle(color: Color(0xFF8391A5), fontSize: 11),
    ),
    trailing: const Icon(Icons.chevron_right_rounded, color: Color(0xFF98A5B7)),
    onTap: onTap,
  );
}

class _RuleDataModulesPage extends StatefulWidget {
  const _RuleDataModulesPage({required this.engine});
  final SingBox engine;

  @override
  State<_RuleDataModulesPage> createState() => _RuleDataModulesPageState();
}

class _RuleDataModulesPageState extends State<_RuleDataModulesPage> {
  bool _updating = false;
  String? _message;

  Future<void> _updateNow() async {
    final workDir = widget.engine.runtimeInfo?.workingDirectory;
    if (workDir == null || workDir.isEmpty || _updating) {
      setState(() => _message = '模块目录暂不可用，请稍后重试。');
      return;
    }
    setState(() {
      _updating = true;
      _message = null;
    });
    final options = widget.engine.configOptions;
    final result = await _updateRuleSetModules(
      {
        'geoip-cn': options.geoipRuleSetUrl.replaceAll('{tag}', 'geoip-cn'),
        'geosite-cn': options.geositeRuleSetUrl.replaceAll(
          '{tag}',
          'geosite-cn',
        ),
        'geosite-category-ads-all': options.geositeRuleSetUrl.replaceAll(
          '{tag}',
          'geosite-category-ads-all',
        ),
      },
      workDir,
      force: true,
    );
    if (mounted) {
      setState(() {
        _updating = false;
        _message =
            '本次更新成功 ${result.updated} 个模块，失败 ${result.failed} 个。失败项保留现有版本，不影响代理连接，可稍后重试。';
      });
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Stack(
      children: [
        const _AmbientBackground(),
        SafeArea(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
            children: [
              Row(
                children: [
                  _SmallIconButton(
                    icon: Icons.arrow_back_rounded,
                    tooltip: '返回',
                    onTap: () => Navigator.of(context).pop(),
                  ),
                  const SizedBox(width: 12),
                  const Text(
                    '规则数据模块',
                    style: TextStyle(
                      color: _ink,
                      fontSize: 19,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 18),
              _Glass(
                padding: const EdgeInsets.all(16),
                radius: 20,
                blur: false,
                color: Colors.white.withValues(alpha: .84),
                child: const Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '第三方规则数据',
                      style: TextStyle(
                        color: _ink,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    SizedBox(height: 8),
                    Text(
                      '导入订阅时会识别其引用的 GeoIP、GeoSite 规则，并立即下载到本地供连接使用。后续连接优先读取本地模块；后台更新失败会保留现有文件，不影响代理。此处可用于内置基础规则的手动修复。',
                      style: TextStyle(
                        color: Color(0xFF71829B),
                        height: 1.5,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              for (final module in const [
                ('geoip-cn', 'GeoIP · 中国 IP 段'),
                ('geosite-cn', 'GeoSite · 中国域名'),
                ('geosite-category-ads-all', 'GeoSite · 广告过滤'),
              ])
                Padding(
                  padding: const EdgeInsets.only(bottom: 9),
                  child: _SettingsEntry(
                    icon: Icons.inventory_2_outlined,
                    title: module.$2,
                    subtitle: '模块 ID：${module.$1} · 后台可选更新',
                    onTap: _updateNow,
                  ),
                ),
              const SizedBox(height: 8),
              FilledButton.icon(
                onPressed: _updating ? null : _updateNow,
                icon: _updating
                    ? const SizedBox(
                        width: 17,
                        height: 17,
                        child: CircularProgressIndicator.adaptive(
                          strokeWidth: 2,
                        ),
                      )
                    : const Icon(Icons.system_update_alt_rounded),
                label: Text(_updating ? '更新中…' : '立即检查更新'),
              ),
              if (_message != null) ...[
                const SizedBox(height: 12),
                _MessageCard(icon: Icons.info_outline_rounded, text: _message!),
              ],
            ],
          ),
        ),
      ],
    ),
  );
}

class _ProxyGroupsPage extends StatelessWidget {
  const _ProxyGroupsPage({required this.engine});
  final SingBox engine;
  @override
  Widget build(BuildContext context) => Scaffold(
    body: Stack(
      children: [
        const _AmbientBackground(),
        SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(22, 16, 22, 12),
                child: Row(
                  children: [
                    _SmallIconButton(
                      icon: Icons.arrow_back_rounded,
                      tooltip: '返回',
                      onTap: () => Navigator.of(context).pop(),
                    ),
                    const SizedBox(width: 13),
                    const Text(
                      '代理组',
                      style: TextStyle(
                        fontSize: 21,
                        fontWeight: FontWeight.w700,
                        color: _ink,
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: StreamBuilder<List<SingBoxOutboundGroup>>(
                  stream: engine.watchGroups(),
                  initialData: const [],
                  builder: (context, snapshot) {
                    final groups =
                        snapshot.data ?? const <SingBoxOutboundGroup>[];
                    if (groups.isEmpty)
                      return const Center(
                        child: Padding(
                          padding: EdgeInsets.all(28),
                          child: Text(
                            '连接代理后，配置中的 selector / urltest 代理组会显示在这里。',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: Color(0xFF71829B),
                              height: 1.5,
                            ),
                          ),
                        ),
                      );
                    return ListView.builder(
                      padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
                      itemCount: groups.length,
                      itemBuilder: (context, index) {
                        final group = groups[index];
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: _Glass(
                            padding: const EdgeInsets.fromLTRB(15, 12, 15, 10),
                            radius: 23,
                            blur: false,
                            color: Colors.white.withValues(alpha: .86),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                        group.tag,
                                        style: const TextStyle(
                                          color: _ink,
                                          fontSize: 15,
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                    ),
                                    Text(
                                      group.type == 'urltest' ? '自动测速' : '手动选择',
                                      style: const TextStyle(
                                        color: Color(0xFF8190A5),
                                        fontSize: 11,
                                      ),
                                    ),
                                    if (group.type == 'urltest')
                                      IconButton(
                                        tooltip: '立即测速',
                                        onPressed: () =>
                                            engine.urlTest(group.tag),
                                        icon: const Icon(
                                          Icons.speed_rounded,
                                          color: _blue,
                                          size: 19,
                                        ),
                                      ),
                                  ],
                                ),
                                for (final item in group.items)
                                  ListTile(
                                    dense: true,
                                    contentPadding: EdgeInsets.zero,
                                    title: Text(
                                      item.tag,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        fontSize: 13,
                                        color: _ink,
                                      ),
                                    ),
                                    subtitle: Text(
                                      '${item.type}${item.urlTestDelay == null ? '' : ' · ${item.urlTestDelay} ms'}',
                                      style: const TextStyle(
                                        fontSize: 10,
                                        color: Color(0xFF8190A5),
                                      ),
                                    ),
                                    trailing: item.tag == group.selected
                                        ? const Icon(
                                            Icons.check_circle_rounded,
                                            color: _mint,
                                          )
                                        : group.selectable
                                        ? const Icon(
                                            Icons
                                                .radio_button_unchecked_rounded,
                                            color: Color(0xFF9AA7B8),
                                          )
                                        : null,
                                    onTap:
                                        group.selectable &&
                                            item.tag != group.selected
                                        ? () => engine.selectOutbound(
                                            group.tag,
                                            item.tag,
                                          )
                                        : null,
                                  ),
                              ],
                            ),
                          ),
                        );
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

class _ActiveConnectionsPage extends StatelessWidget {
  const _ActiveConnectionsPage({required this.engine});
  final SingBox engine;
  @override
  Widget build(BuildContext context) => Scaffold(
    body: Stack(
      children: [
        const _AmbientBackground(),
        SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(22, 16, 22, 12),
                child: Row(
                  children: [
                    _SmallIconButton(
                      icon: Icons.arrow_back_rounded,
                      tooltip: '返回',
                      onTap: () => Navigator.of(context).pop(),
                    ),
                    const SizedBox(width: 13),
                    const Expanded(
                      child: Text(
                        '活动连接',
                        style: TextStyle(
                          fontSize: 21,
                          fontWeight: FontWeight.w700,
                          color: _ink,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: '关闭全部连接',
                      onPressed: () => engine.closeAllConnections(),
                      icon: const Icon(
                        Icons.close_rounded,
                        color: Color(0xFF8190A5),
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: StreamBuilder<List<SingBoxConnection>>(
                  stream: engine.watchConnections(),
                  initialData: const [],
                  builder: (context, snapshot) {
                    final connections =
                        (snapshot.data ?? const <SingBoxConnection>[])
                            .where((c) => c.isActive)
                            .toList();
                    if (connections.isEmpty)
                      return const Center(
                        child: Text(
                          '当前没有活动连接',
                          style: TextStyle(color: Color(0xFF71829B)),
                        ),
                      );
                    return ListView.builder(
                      padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
                      itemCount: connections.length,
                      itemBuilder: (context, index) {
                        final connection = connections[index];
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 9),
                          child: _Glass(
                            padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
                            radius: 20,
                            blur: false,
                            color: Colors.white.withValues(alpha: .86),
                            child: Row(
                              children: [
                                Container(
                                  width: 38,
                                  height: 38,
                                  decoration: BoxDecoration(
                                    color: _blue.withValues(alpha: .1),
                                    borderRadius: BorderRadius.circular(13),
                                  ),
                                  child: Icon(
                                    connection.network == 'udp'
                                        ? Icons.wifi_tethering_rounded
                                        : Icons.swap_horiz_rounded,
                                    color: _blue,
                                    size: 19,
                                  ),
                                ),
                                const SizedBox(width: 11),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        connection.displayDestination,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          fontSize: 12,
                                          fontWeight: FontWeight.w700,
                                          color: _ink,
                                        ),
                                      ),
                                      Text(
                                        '${connection.processName ?? connection.protocol}  ·  ${connection.rule.isEmpty ? '默认规则' : connection.rule}  ·  ${connection.outbound}',
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          fontSize: 10,
                                          color: Color(0xFF8190A5),
                                        ),
                                      ),
                                      Text(
                                        '↓ ${_formatRate(connection.downloadSpeed)}  ↑ ${_formatRate(connection.uploadSpeed)}',
                                        style: const TextStyle(
                                          fontSize: 10,
                                          color: Color(0xFF71829B),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                IconButton(
                                  tooltip: '关闭连接',
                                  onPressed: () =>
                                      engine.closeConnection(connection.id),
                                  icon: const Icon(
                                    Icons.close_rounded,
                                    size: 19,
                                    color: Color(0xFF8B98AA),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

class _RuntimeLogsPage extends StatelessWidget {
  const _RuntimeLogsPage({required this.engine});
  final SingBox engine;
  @override
  Widget build(BuildContext context) => Scaffold(
    body: Stack(
      children: [
        const _AmbientBackground(),
        SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(22, 16, 22, 12),
                child: Row(
                  children: [
                    _SmallIconButton(
                      icon: Icons.arrow_back_rounded,
                      tooltip: '返回',
                      onTap: () => Navigator.of(context).pop(),
                    ),
                    const SizedBox(width: 13),
                    const Expanded(
                      child: Text(
                        '运行日志',
                        style: TextStyle(
                          fontSize: 21,
                          fontWeight: FontWeight.w700,
                          color: _ink,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: '清空日志',
                      onPressed: engine.clearLogs,
                      icon: const Icon(
                        Icons.delete_outline_rounded,
                        color: Color(0xFF8190A5),
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: StreamBuilder<List<SingBoxLogEntry>>(
                  stream: engine.watchLogBuffer(maxEntries: 600),
                  initialData: const [],
                  builder: (context, snapshot) {
                    final entries = snapshot.data ?? const <SingBoxLogEntry>[];
                    if (entries.isEmpty)
                      return const Center(
                        child: Text(
                          '暂无运行日志；连接代理后会显示内核事件。',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Color(0xFF71829B)),
                        ),
                      );
                    return ListView.builder(
                      reverse: true,
                      padding: const EdgeInsets.fromLTRB(18, 4, 18, 24),
                      itemCount: entries.length,
                      itemBuilder: (context, index) {
                        final entry = entries[entries.length - index - 1];
                        final color = switch (entry.level) {
                          SingBoxLogLevel.error ||
                          SingBoxLogLevel.fatal ||
                          SingBoxLogLevel.panic => const Color(0xFFBD5C66),
                          SingBoxLogLevel.warn => const Color(0xFFB07B28),
                          _ => const Color(0xFF64758E),
                        };
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 7),
                          child: _Glass(
                            padding: const EdgeInsets.all(11),
                            radius: 15,
                            blur: false,
                            color: Colors.white.withValues(alpha: .82),
                            child: Text(
                              '[${entry.level.name.toUpperCase()}] ${entry.plainMessage}',
                              style: TextStyle(
                                fontSize: 11,
                                height: 1.4,
                                color: color,
                                fontFamily: 'monospace',
                              ),
                            ),
                          ),
                        );
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

class _RoutingSettingsPage extends StatefulWidget {
  const _RoutingSettingsPage({
    required this.engine,
    required this.globalTun,
    this.initialSection,
  });
  final SingBox engine;
  final bool globalTun;
  final String? initialSection;
  @override
  State<_RoutingSettingsPage> createState() => _RoutingSettingsPageState();
}

class _RoutingSettingsPageState extends State<_RoutingSettingsPage> {
  SingBoxRoutingRules _rules = const SingBoxRoutingRules();
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final rules = await _loadUserRoutingRules(widget.engine);
      if (mounted)
        setState(() {
          _rules = rules;
          _loading = false;
        });
    } on Object catch (error) {
      if (mounted)
        setState(() {
          _error = error.toString();
          _loading = false;
        });
    }
  }

  Future<void> _save(SingBoxRoutingRules next) async {
    setState(() {
      _rules = next;
      _error = null;
    });
    try {
      await _saveUserRoutingRules(
        widget.engine,
        next,
        globalTun: widget.globalTun,
      );
    } on Object catch (error) {
      if (mounted) setState(() => _error = error.toString());
    }
  }

  Future<void> _editList(
    String title,
    List<String> current,
    ValueChanged<List<String>> apply,
  ) async {
    final next = await Navigator.of(context).push<List<String>>(
      MaterialPageRoute<List<String>>(
        builder: (_) => _StringListEditorPage(title: title, values: current),
      ),
    );
    if (next != null) apply(next);
  }

  Future<void> _pickApps(
    String title,
    List<String> current,
    ValueChanged<List<String>> apply,
  ) async {
    if (!Platform.isAndroid) {
      _showGlassNotice(context, '应用列表选择仅支持 Android');
      return;
    }
    final next = await Navigator.of(context).push<List<String>>(
      MaterialPageRoute<List<String>>(
        builder: (_) => _InstalledAppPickerPage(title: title, values: current),
      ),
    );
    if (next != null) apply(next);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Stack(
      children: [
        const _AmbientBackground(),
        SafeArea(
          child: _loading
              ? const Center(child: CircularProgressIndicator.adaptive())
              : CustomScrollView(
                  slivers: [
                    SliverPadding(
                      padding: const EdgeInsets.fromLTRB(22, 16, 22, 18),
                      sliver: SliverToBoxAdapter(
                        child: Row(
                          children: [
                            _SmallIconButton(
                              icon: Icons.arrow_back_rounded,
                              tooltip: '返回',
                              onTap: () => Navigator.of(context).pop(),
                            ),
                            const SizedBox(width: 13),
                            const Expanded(
                              child: Text(
                                '路由与分流',
                                style: TextStyle(
                                  color: _ink,
                                  fontSize: 21,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    if (_error != null)
                      SliverPadding(
                        padding: const EdgeInsets.symmetric(horizontal: 22),
                        sliver: SliverToBoxAdapter(
                          child: _MessageCard(
                            icon: Icons.error_outline_rounded,
                            text: _error!,
                          ),
                        ),
                      ),
                    SliverPadding(
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      sliver: SliverToBoxAdapter(
                        child: Column(
                          children: [
                            _Glass(
                              padding: const EdgeInsets.all(17),
                              radius: 22,
                              blur: false,
                              child: Row(
                                children: [
                                  const Icon(
                                    Icons.info_outline_rounded,
                                    color: _blue,
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Text(
                                      widget.globalTun
                                          ? '当前为全局 TUN：所有流量走代理，国内与局域网绕过规则不会生效。'
                                          : '当前为系统代理规则模式：中国流量直连，国外流量走代理。',
                                      style: const TextStyle(
                                        color: Color(0xFF60718C),
                                        height: 1.4,
                                        fontSize: 12,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(height: 14),
                            _SettingsGroup(
                              title: '基础规则',
                              children: [
                                SwitchListTile(
                                  title: const Text('屏蔽广告域名'),
                                  subtitle: const Text('使用 sing-box 广告域名规则集'),
                                  value: _rules.blockAds,
                                  onChanged: (v) =>
                                      _save(_rules.copyWith(blockAds: v)),
                                ),
                                SwitchListTile(
                                  title: const Text('局域网直连'),
                                  subtitle: Text(
                                    widget.globalTun
                                        ? '全局 TUN 暂不应用；切回规则模式后生效'
                                        : '私有地址与局域网主机名直连',
                                  ),
                                  value: _rules.bypassLan,
                                  onChanged: (v) =>
                                      _save(_rules.copyWith(bypassLan: v)),
                                ),
                              ],
                            ),
                            const SizedBox(height: 14),
                            _SettingsGroup(
                              title: '域名与网段',
                              children: [
                                _ruleEntry(
                                  '直连域名',
                                  '匹配域名后绕过代理',
                                  Icons.link_rounded,
                                  _rules.bypassDomains,
                                  (v) =>
                                      _save(_rules.copyWith(bypassDomains: v)),
                                  _editList,
                                ),
                                _ruleEntry(
                                  '屏蔽域名',
                                  '拒绝连接并屏蔽 DNS 查询',
                                  Icons.block_rounded,
                                  _rules.blockedDomains,
                                  (v) =>
                                      _save(_rules.copyWith(blockedDomains: v)),
                                  _editList,
                                ),
                                _ruleEntry(
                                  '直连网段',
                                  'CIDR 或单个 IP 地址',
                                  Icons.lan_rounded,
                                  _rules.bypassSubnets,
                                  (v) =>
                                      _save(_rules.copyWith(bypassSubnets: v)),
                                  _editList,
                                ),
                              ],
                            ),
                            const SizedBox(height: 14),
                            _SettingsGroup(
                              title: 'DNS',
                              children: [
                                _ruleEntry(
                                  'DNS 服务器',
                                  '例如 https://dns.google/dns-query',
                                  Icons.dns_rounded,
                                  _rules.dnsServers,
                                  (v) => _save(_rules.copyWith(dnsServers: v)),
                                  _editList,
                                ),
                              ],
                            ),
                            const SizedBox(height: 14),
                            _SettingsGroup(
                              title: '应用分流',
                              children: [
                                _ruleEntry(
                                  '仅代理这些应用',
                                  '选择需要通过代理连接的应用',
                                  Icons.filter_alt_rounded,
                                  _rules.proxyApps,
                                  (v) => _save(_rules.copyWith(proxyApps: v)),
                                  _pickApps,
                                  appSelection: true,
                                ),
                                _ruleEntry(
                                  '绕过这些应用',
                                  '选择不经过代理的应用',
                                  Icons.output_rounded,
                                  _rules.bypassApps,
                                  (v) => _save(_rules.copyWith(bypassApps: v)),
                                  _pickApps,
                                  appSelection: true,
                                ),
                                _ruleEntry(
                                  '屏蔽这些应用',
                                  '选择禁止联网的应用',
                                  Icons.app_blocking_rounded,
                                  _rules.blockedApps,
                                  (v) => _save(_rules.copyWith(blockedApps: v)),
                                  _pickApps,
                                  appSelection: true,
                                ),
                              ],
                            ),
                            const SizedBox(height: 24),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
        ),
      ],
    ),
  );

  Widget _ruleEntry(
    String title,
    String subtitle,
    IconData icon,
    List<String> values,
    ValueChanged<List<String>> apply,
    Future<void> Function(String, List<String>, ValueChanged<List<String>>)
    edit, {
    bool appSelection = false,
  }) => ListTile(
    leading: Icon(icon, color: _blue),
    title: Text(
      title,
      style: const TextStyle(
        color: _ink,
        fontSize: 14,
        fontWeight: FontWeight.w600,
      ),
    ),
    subtitle: Text(
      values.isEmpty
          ? subtitle
          : appSelection
          ? '已选择 ${values.length} 个应用'
          : '${values.length} 项 · ${values.take(2).join(', ')}',
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: const TextStyle(fontSize: 11, color: Color(0xFF8190A5)),
    ),
    trailing: const Icon(Icons.chevron_right_rounded, color: Color(0xFF98A5B7)),
    onTap: () => edit(title, values, apply),
  );
}

class _InstalledAppPickerPage extends StatefulWidget {
  const _InstalledAppPickerPage({required this.title, required this.values});
  final String title;
  final List<String> values;

  @override
  State<_InstalledAppPickerPage> createState() =>
      _InstalledAppPickerPageState();
}

class _InstalledAppPickerPageState extends State<_InstalledAppPickerPage> {
  final _search = TextEditingController();
  late final Set<String> _selected = widget.values.toSet();
  List<Map<String, String>> _apps = [];
  bool _consented = false;
  bool _loading = false;
  String? _error;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _loadApps() async {
    setState(() {
      _consented = true;
      _loading = true;
      _error = null;
    });
    try {
      final result = await _installedAppsChannel.invokeListMethod<dynamic>(
        'listInstalledApps',
      );
      final apps = (result ?? const <dynamic>[])
          .whereType<Map>()
          .map(
            (item) => <String, String>{
              'label': '${item['label'] ?? item['packageName'] ?? ''}',
              'packageName': '${item['packageName'] ?? ''}',
            },
          )
          .where((item) => item['packageName']!.isNotEmpty)
          .toList();
      if (!mounted) return;
      setState(() {
        _apps = apps;
        _loading = false;
        if (apps.isEmpty) _error = '没有读取到已安装应用';
      });
    } on Object {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '读取应用列表失败，请重新打开选择器';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final query = _search.text.trim().toLowerCase();
    final installedPackages = _apps.map((app) => app['packageName']).toSet();
    final visibleApps = _apps.where((app) {
      return query.isEmpty ||
          app['label']!.toLowerCase().contains(query) ||
          app['packageName']!.toLowerCase().contains(query);
    }).toList();
    final missing = _selected
        .where((packageName) => !installedPackages.contains(packageName))
        .where(
          (packageName) =>
              query.isEmpty || packageName.toLowerCase().contains(query),
        )
        .map(
          (packageName) => <String, String>{
            'label': '当前设备未安装',
            'packageName': packageName,
          },
        );
    final rows = [...missing, ...visibleApps];

    return Scaffold(
      body: Stack(
        children: [
          const _AmbientBackground(),
          SafeArea(
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(22, 16, 22, 12),
                  child: Row(
                    children: [
                      _SmallIconButton(
                        icon: Icons.arrow_back_rounded,
                        tooltip: '返回',
                        onTap: () => Navigator.of(context).pop(),
                      ),
                      const SizedBox(width: 13),
                      Expanded(
                        child: Text(
                          widget.title,
                          style: const TextStyle(
                            color: _ink,
                            fontSize: 20,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                if (!_consented)
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
                      child: _Glass(
                        padding: const EdgeInsets.all(22),
                        radius: 26,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Icon(
                              Icons.apps_rounded,
                              color: _blue,
                              size: 34,
                            ),
                            const SizedBox(height: 14),
                            const Text(
                              '读取设备上的应用列表',
                              style: TextStyle(
                                color: _ink,
                                fontSize: 17,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: 8),
                            const Text(
                              'Android 要求声明“查看所有应用”权限（QUERY_ALL_PACKAGES），此权限没有系统运行时授权弹窗。Hourglass 只在本机读取应用名称和包名来生成分流规则，不会上传应用列表。',
                              style: TextStyle(
                                color: Color(0xFF65758C),
                                fontSize: 13,
                                height: 1.55,
                              ),
                            ),
                            const SizedBox(height: 18),
                            SizedBox(
                              width: double.infinity,
                              child: FilledButton.icon(
                                onPressed: _loadApps,
                                icon: const Icon(Icons.check_rounded),
                                label: const Text('继续并选择应用'),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  )
                else ...[
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    child: _Glass(
                      padding: const EdgeInsets.fromLTRB(14, 8, 14, 8),
                      radius: 18,
                      child: TextField(
                        controller: _search,
                        onChanged: (_) => setState(() {}),
                        decoration: const InputDecoration(
                          hintText: '搜索应用名称或包名',
                          prefixIcon: Icon(Icons.search_rounded),
                          border: InputBorder.none,
                        ),
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(24, 10, 24, 8),
                    child: Row(
                      children: [
                        Text(
                          _loading
                              ? '正在读取应用…'
                              : '已选 ${_selected.length} 个 · 共 ${_apps.length} 个应用',
                          style: const TextStyle(
                            color: Color(0xFF65758C),
                            fontSize: 12,
                          ),
                        ),
                        const Spacer(),
                        TextButton(
                          onPressed: _loading || rows.isEmpty
                              ? null
                              : () => setState(() {
                                  final allSelected = rows.every(
                                    (app) =>
                                        _selected.contains(app['packageName']),
                                  );
                                  for (final app in rows) {
                                    final packageName = app['packageName']!;
                                    if (allSelected) {
                                      _selected.remove(packageName);
                                    } else {
                                      _selected.add(packageName);
                                    }
                                  }
                                }),
                          child: Text(
                            rows.isNotEmpty &&
                                    rows.every(
                                      (app) => _selected.contains(
                                        app['packageName'],
                                      ),
                                    )
                                ? '取消全选'
                                : '全选当前结果',
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(22, 0, 22, 8),
                      child: Text(
                        _error!,
                        style: const TextStyle(color: Color(0xFFB65B6A)),
                      ),
                    ),
                  Expanded(
                    child: _loading
                        ? const Center(
                            child: CircularProgressIndicator.adaptive(),
                          )
                        : rows.isEmpty
                        ? const Center(
                            child: Text(
                              '没有匹配的应用',
                              style: TextStyle(color: Color(0xFF65758C)),
                            ),
                          )
                        : ListView.builder(
                            padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                            itemCount: rows.length,
                            itemBuilder: (context, index) {
                              final app = rows[index];
                              final packageName = app['packageName']!;
                              return Padding(
                                padding: const EdgeInsets.only(bottom: 8),
                                child: _Glass(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 14,
                                    vertical: 8,
                                  ),
                                  radius: 17,
                                  child: CheckboxListTile(
                                    value: _selected.contains(packageName),
                                    onChanged: (value) => setState(() {
                                      if (value == true) {
                                        _selected.add(packageName);
                                      } else {
                                        _selected.remove(packageName);
                                      }
                                    }),
                                    controlAffinity:
                                        ListTileControlAffinity.trailing,
                                    contentPadding: EdgeInsets.zero,
                                    title: Text(
                                      app['label']!,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        color: _ink,
                                        fontSize: 14,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                    subtitle: Text(
                                      packageName,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        color: Color(0xFF8190A5),
                                        fontSize: 11,
                                      ),
                                    ),
                                  ),
                                ),
                              );
                            },
                          ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 6, 20, 12),
                    child: SizedBox(
                      width: double.infinity,
                      child: FilledButton(
                        onPressed: _loading || !_consented
                            ? null
                            : () => Navigator.of(
                                context,
                              ).pop(_selected.toList()..sort()),
                        child: const Padding(
                          padding: EdgeInsets.symmetric(vertical: 12),
                          child: Text('保存选择'),
                        ),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _StringListEditorPage extends StatefulWidget {
  const _StringListEditorPage({required this.title, required this.values});
  final String title;
  final List<String> values;
  @override
  State<_StringListEditorPage> createState() => _StringListEditorPageState();
}

class _StringListEditorPageState extends State<_StringListEditorPage> {
  late final _controller = TextEditingController(
    text: widget.values.join('\n'),
  );
  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    resizeToAvoidBottomInset: true,
    body: Stack(
      children: [
        const _AmbientBackground(),
        SafeArea(
          child: CustomScrollView(
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            slivers: [
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(22, 16, 22, 18),
                sliver: SliverToBoxAdapter(
                  child: Row(
                    children: [
                      _SmallIconButton(
                        icon: Icons.arrow_back_rounded,
                        tooltip: '返回',
                        onTap: () => Navigator.of(context).pop(),
                      ),
                      const SizedBox(width: 13),
                      Expanded(
                        child: Text(
                          widget.title,
                          style: const TextStyle(
                            color: _ink,
                            fontSize: 20,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              SliverPadding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                sliver: SliverToBoxAdapter(
                  child: _Glass(
                    padding: const EdgeInsets.all(20),
                    radius: 26,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          '每行填写一项，保存后立即应用。',
                          style: TextStyle(
                            color: Color(0xFF65758C),
                            fontSize: 13,
                          ),
                        ),
                        const SizedBox(height: 14),
                        TextField(
                          controller: _controller,
                          minLines: 8,
                          maxLines: 18,
                          autocorrect: false,
                          decoration: const InputDecoration(
                            hintText: 'example.com\nsub.example.com',
                          ),
                        ),
                        const SizedBox(height: 16),
                        SizedBox(
                          width: double.infinity,
                          child: FilledButton(
                            onPressed: () {
                              final values = _controller.text
                                  .split(RegExp(r'[\r\n,]+'))
                                  .map((e) => e.trim())
                                  .where((e) => e.isNotEmpty)
                                  .toSet()
                                  .toList();
                              Navigator.of(context).pop(values);
                            },
                            child: const Padding(
                              padding: EdgeInsets.symmetric(vertical: 12),
                              child: Text('保存'),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              const SliverPadding(padding: EdgeInsets.only(bottom: 30)),
            ],
          ),
        ),
      ],
    ),
  );
}

class _ServicePreferencesPage extends StatefulWidget {
  const _ServicePreferencesPage({required this.engine});
  final SingBox engine;
  @override
  State<_ServicePreferencesPage> createState() =>
      _ServicePreferencesPageState();
}

class _ServicePreferencesPageState extends State<_ServicePreferencesPage> {
  SingBoxSettings? _settings;
  String? _error;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final s = await widget.engine.getSettings();
      if (mounted) setState(() => _settings = s);
    } on Object catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  Future<void> _set(String key, bool value) async {
    try {
      await widget.engine.updateSetting(key, value);
      if (mounted) setState(() => _settings = _settings?.withValue(key, value));
    } on Object catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = _settings;
    return Scaffold(
      body: Stack(
        children: [
          const _AmbientBackground(),
          SafeArea(
            child: s == null
                ? Center(
                    child: _error == null
                        ? const CircularProgressIndicator.adaptive()
                        : _MessageCard(
                            icon: Icons.error_outline_rounded,
                            text: _error!,
                          ),
                  )
                : ListView(
                    padding: const EdgeInsets.fromLTRB(22, 16, 22, 30),
                    children: [
                      Row(
                        children: [
                          _SmallIconButton(
                            icon: Icons.arrow_back_rounded,
                            tooltip: '返回',
                            onTap: () => Navigator.of(context).pop(),
                          ),
                          const SizedBox(width: 13),
                          const Text(
                            '自动连接与保护',
                            style: TextStyle(
                              color: _ink,
                              fontSize: 20,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 18),
                      _SettingsGroup(
                        title: '连接行为',
                        children: [
                          SwitchListTile(
                            title: const Text('启动时自动连接'),
                            value: s.autoConnectOnStart,
                            onChanged: (v) =>
                                _set(SingBoxSettings.keyAutoConnectOnStart, v),
                          ),
                          SwitchListTile(
                            title: const Text('断线后自动重连'),
                            value: s.autoReconnectOnDisconnect,
                            onChanged: (v) => _set(
                              SingBoxSettings.keyAutoReconnectOnDisconnect,
                              v,
                            ),
                          ),
                          SwitchListTile(
                            title: const Text('开机启动 VPN'),
                            subtitle: const Text('Android 可能需要在系统 VPN 设置中确认'),
                            value: s.startOnBoot,
                            onChanged: (v) =>
                                _set(SingBoxSettings.keyStartOnBoot, v),
                          ),
                        ],
                      ),
                      const SizedBox(height: 14),
                      _SettingsGroup(
                        title: '流量保护',
                        children: [
                          SwitchListTile(
                            title: const Text('网络锁定'),
                            subtitle: const Text(
                              '启用后，建议同时在 Android VPN 设置中开启“始终开启”和“阻止未通过 VPN 的连接”',
                            ),
                            value: s.killSwitch,
                            onChanged: (v) =>
                                _set(SingBoxSettings.keyKillSwitch, v),
                          ),
                          SwitchListTile(
                            title: const Text('快捷设置磁贴'),
                            value: s.quickSettingsTile,
                            onChanged: (v) =>
                                _set(SingBoxSettings.keyQuickSettingsTile, v),
                          ),
                        ],
                      ),
                      if (_error != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 12),
                          child: _MessageCard(
                            icon: Icons.error_outline_rounded,
                            text: _error!,
                          ),
                        ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}

class _ConnectionCard extends StatelessWidget {
  const _ConnectionCard({
    required this.connected,
    required this.transitioning,
    required this.selectedName,
    required this.error,
    required this.onTap,
  });
  final bool connected, transitioning;
  final String? selectedName, error;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => _Glass(
    padding: const EdgeInsets.fromLTRB(24, 24, 24, 22),
    radius: 32,
    color: Colors.white.withValues(alpha: .69),
    child: Column(
      children: [
        Row(
          children: [
            Container(
              width: 9,
              height: 9,
              decoration: BoxDecoration(
                color: connected ? _mint : const Color(0xFFB7C2D2),
                shape: BoxShape.circle,
                boxShadow: connected
                    ? [
                        BoxShadow(
                          color: _mint.withValues(alpha: .55),
                          blurRadius: 9,
                        ),
                      ]
                    : null,
              ),
            ),
            const SizedBox(width: 8),
            Text(
              connected
                  ? (selectedName?.startsWith('住宅 IP') == true
                        ? '住宅 IP 已连接'
                        : '安全通道已连接')
                  : transitioning
                  ? '正在建立安全通道'
                  : '安全通道已关闭',
              style: const TextStyle(
                color: Color(0xFF64758E),
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
            const Spacer(),
            const Icon(
              Icons.shield_outlined,
              color: Color(0xFF75A0D9),
              size: 19,
            ),
          ],
        ),
        const SizedBox(height: 24),
        GestureDetector(
          onTap: transitioning ? null : onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 240),
            width: 142,
            height: 142,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: connected
                    ? [_mint, const Color(0xFF6EE0C4)]
                    : [_blue, const Color(0xFF80B4FF)],
              ),
              boxShadow: [
                BoxShadow(
                  color: (connected ? _mint : _blue).withValues(alpha: .28),
                  blurRadius: 30,
                  spreadRadius: 4,
                  offset: const Offset(0, 12),
                ),
                const BoxShadow(
                  color: Colors.white,
                  blurRadius: 2,
                  spreadRadius: -4,
                  offset: Offset(-3, -5),
                ),
              ],
              border: Border.all(
                color: Colors.white.withValues(alpha: .72),
                width: 4,
              ),
            ),
            child: Center(
              child: transitioning
                  ? const SizedBox(
                      width: 33,
                      height: 33,
                      child: CircularProgressIndicator(
                        color: Colors.white,
                        strokeWidth: 3,
                      ),
                    )
                  : Icon(
                      Icons.power_settings_new_rounded,
                      color: Colors.white,
                      size: 59,
                    ),
            ),
          ),
        ),
        const SizedBox(height: 21),
        Text(
          connected
              ? (selectedName?.startsWith('住宅 IP') == true
                    ? '点击切换到普通代理'
                    : '已连接')
              : '点击开启代理',
          style: const TextStyle(
            fontSize: 19,
            fontWeight: FontWeight.w700,
            color: _ink,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          selectedName ?? '选择节点后即可连接',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(color: Color(0xFF77869C), fontSize: 13),
        ),
        if (error != null && error!.isNotEmpty) ...[
          const SizedBox(height: 12),
          Text(
            error!,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Color(0xFFBD5C66), fontSize: 12),
          ),
        ],
      ],
    ),
  );
}

class _ModePicker extends StatelessWidget {
  const _ModePicker({
    required this.globalTun,
    required this.enabled,
    required this.onChanged,
  });
  final bool globalTun;
  final bool enabled;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) => _Glass(
    padding: const EdgeInsets.all(8),
    radius: 24,
    child: Row(
      children: [
        Expanded(
          child: _ModeOption(
            selected: !globalTun,
            enabled: enabled,
            icon: Icons.public_rounded,
            title: '系统代理',
            subtitle: '规则模式 · 国内直连',
            onTap: () => onChanged(false),
          ),
        ),
        const SizedBox(width: 6),
        Expanded(
          child: _ModeOption(
            selected: globalTun,
            enabled: enabled,
            icon: Icons.sync_alt_rounded,
            title: 'TUN',
            subtitle: '全局模式 · 全部代理',
            onTap: () => onChanged(true),
          ),
        ),
      ],
    ),
  );
}

class _ModeOption extends StatelessWidget {
  const _ModeOption({
    required this.selected,
    required this.enabled,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });
  final bool selected, enabled;
  final IconData icon;
  final String title, subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    selected: selected,
    child: Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        onTap: enabled ? onTap : null,
        borderRadius: BorderRadius.circular(18),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 240),
          curve: Curves.easeOutCubic,
          decoration: BoxDecoration(
            color: selected ? _blue.withValues(alpha: .12) : Colors.transparent,
            borderRadius: BorderRadius.circular(18),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
          child: Row(
            children: [
              Icon(
                icon,
                size: 21,
                color: selected ? _blue : const Color(0xFF8492A6),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: selected ? _ink : const Color(0xFF64758E),
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 10,
                        color: Color(0xFF8190A5),
                      ),
                    ),
                  ],
                ),
              ),
              if (selected)
                const Icon(Icons.check_circle_rounded, size: 16, color: _blue),
            ],
          ),
        ),
      ),
    ),
  );
}

class _NetworkAnalysisCard extends StatelessWidget {
  const _NetworkAnalysisCard({
    required this.connected,
    required this.transitioning,
    required this.stats,
    required this.latency,
    required this.downloadHistory,
    required this.uploadHistory,
    required this.latencyHistory,
    required this.testing,
    required this.onTest,
  });

  final bool connected, transitioning, testing;
  final SingBoxConnectionStats stats;
  final SingBoxPingResult? latency;
  final List<double> downloadHistory, uploadHistory, latencyHistory;
  final VoidCallback? onTest;

  @override
  Widget build(BuildContext context) {
    return _Glass(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 15),
      radius: 24,
      color: Colors.white.withValues(alpha: .82),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: const Color(0xFF6D92DC).withValues(alpha: .11),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(
                  Icons.graphic_eq_rounded,
                  color: _blue,
                  size: 20,
                ),
              ),
              const SizedBox(width: 10),
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '网络状态分析',
                      style: TextStyle(
                        color: _ink,
                        fontSize: 14,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    SizedBox(height: 2),
                    Text(
                      '实时流量 · 延迟曲线',
                      style: TextStyle(color: Color(0xFF8190A5), fontSize: 10),
                    ),
                  ],
                ),
              ),
              AnimatedContainer(
                duration: const Duration(milliseconds: 280),
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
                decoration: BoxDecoration(
                  color: connected
                      ? _mint.withValues(alpha: .12)
                      : const Color(0xFF8997AA).withValues(alpha: .1),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      connected ? Icons.wifi_rounded : Icons.wifi_off_rounded,
                      size: 13,
                      color: connected ? _mint : const Color(0xFF8997AA),
                    ),
                    const SizedBox(width: 4),
                    Text(
                      transitioning
                          ? '切换中'
                          : connected
                          ? '已连接'
                          : '未连接',
                      style: TextStyle(
                        color: connected ? _mint : const Color(0xFF8997AA),
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 112,
            width: double.infinity,
            child: _NetworkGraph(
              download: connected ? downloadHistory : const [],
              upload: connected ? uploadHistory : const [],
              latency: latencyHistory,
              active: connected,
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 12,
            runSpacing: 7,
            children: [
              _GraphLegend(
                color: _blue,
                label:
                    '下载 ${connected ? _formatRate(stats.downloadSpeed) : '—'}',
              ),
              _GraphLegend(
                color: _mint,
                label: '上传 ${connected ? _formatRate(stats.uploadSpeed) : '—'}',
              ),
              _GraphLegend(
                color: const Color(0xFFE4A453),
                label: connected && latency?.success == true
                    ? '延迟 ${latency!.ping} ms'
                    : '延迟 —',
              ),
            ],
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: FilledButton.tonalIcon(
              onPressed: onTest,
              icon: testing
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator.adaptive(strokeWidth: 2),
                    )
                  : const Icon(Icons.language_rounded, size: 18),
              label: Text(testing ? '正在测试网站连接…' : '测试网站可用性 · Google'),
              style: FilledButton.styleFrom(
                foregroundColor: connected ? _blue : const Color(0xFF8997AA),
                padding: const EdgeInsets.symmetric(vertical: 12),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(15),
                ),
              ),
            ),
          ),
          if (!connected)
            const Padding(
              padding: EdgeInsets.only(top: 7),
              child: Center(
                child: Text(
                  '连接 VPN 后可经代理测试网站访问与延迟',
                  style: TextStyle(color: Color(0xFF8997AA), fontSize: 10),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _GraphLegend extends StatelessWidget {
  const _GraphLegend({required this.color, required this.label});
  final Color color;
  final String label;
  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Container(
        width: 7,
        height: 7,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      ),
      const SizedBox(width: 5),
      Text(
        label,
        style: const TextStyle(
          color: Color(0xFF77869C),
          fontSize: 10,
          fontWeight: FontWeight.w600,
        ),
      ),
    ],
  );
}

class _NetworkGraph extends StatefulWidget {
  const _NetworkGraph({
    required this.download,
    required this.upload,
    required this.latency,
    required this.active,
  });
  final List<double> download, upload, latency;
  final bool active;

  @override
  State<_NetworkGraph> createState() => _NetworkGraphState();
}

class _NetworkGraphState extends State<_NetworkGraph>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late List<double> _fromDownload, _fromUpload, _fromLatency;
  late List<double> _toDownload, _toUpload, _toLatency;
  late bool _targetActive;
  double? _probeFraction;

  List<double> _copy(List<double> values) => List<double>.of(values);

  @override
  void initState() {
    super.initState();
    _fromDownload = _toDownload = _copy(widget.download);
    _fromUpload = _toUpload = _copy(widget.upload);
    _fromLatency = _toLatency = _copy(widget.latency);
    _targetActive = widget.active;
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 560),
      value: 1,
    );
  }

  bool _same(List<double> a, List<double> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  @override
  void didUpdateWidget(covariant _NetworkGraph oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Histories are mutable lists owned by the parent. Compare them with
    // our snapshots instead of oldWidget's references, which may already
    // contain the newly appended samples.
    if (_same(widget.download, _toDownload) &&
        _same(widget.upload, _toUpload) &&
        _same(widget.latency, _toLatency) &&
        widget.active == _targetActive) {
      return;
    }
    _fromDownload = _copy(_toDownload);
    _fromUpload = _copy(_toUpload);
    _fromLatency = _copy(_toLatency);
    _toDownload = _copy(widget.download);
    _toUpload = _copy(widget.upload);
    _toLatency = _copy(widget.latency);
    _targetActive = widget.active;
    _controller.forward(from: 0);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  List<double> _visibleValues(List<double> from, List<double> to) {
    final count = min(36, max(from.length, to.length));
    if (count == 0) return const [];
    List<double> fit(List<double> values) => values.isEmpty
        ? List<double>.filled(count, 0)
        : List<double>.generate(count, (i) {
            final at = count == 1 ? 0.0 : i * (values.length - 1) / (count - 1);
            final lo = at.floor();
            final hi = min(lo + 1, values.length - 1);
            return ui.lerpDouble(values[lo], values[hi], at - lo)!;
          });
    final a = fit(from);
    final b = fit(to);
    return List<double>.generate(
      count,
      (i) => ui.lerpDouble(a[i], b[i], _controller.value)!,
    );
  }

  double? _valueAt(List<double> from, List<double> to, double fraction) {
    final values = _visibleValues(from, to);
    if (values.isEmpty) return null;
    final index = (fraction * (values.length - 1)).round().clamp(
      0,
      values.length - 1,
    );
    return values[index];
  }

  void _setProbe(Offset localPosition, double width) {
    if (width <= 0) return;
    setState(() => _probeFraction = (localPosition.dx / width).clamp(0.0, 1.0));
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _controller,
    builder: (context, _) => LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final download = _probeFraction == null
            ? null
            : _valueAt(_fromDownload, _toDownload, _probeFraction!);
        final upload = _probeFraction == null
            ? null
            : _valueAt(_fromUpload, _toUpload, _probeFraction!);
        final latency = _probeFraction == null
            ? null
            : _valueAt(_fromLatency, _toLatency, _probeFraction!);
        final chipWidth = min(238.0, width - 12);
        final chipLeft = _probeFraction == null
            ? 6.0
            : (_probeFraction! * width - chipWidth / 2)
                  .clamp(6.0, max(6.0, width - chipWidth - 6))
                  .toDouble();
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (details) => _setProbe(details.localPosition, width),
          onDoubleTap: () => setState(() => _probeFraction = null),
          onHorizontalDragUpdate: (details) =>
              _setProbe(details.localPosition, width),
          child: RepaintBoundary(
            child: Stack(
              fit: StackFit.expand,
              children: [
                ClipRect(
                  child: CustomPaint(
                    painter: _NetworkGraphPainter(
                      fromDownload: _fromDownload,
                      fromUpload: _fromUpload,
                      fromLatency: _fromLatency,
                      toDownload: _toDownload,
                      toUpload: _toUpload,
                      toLatency: _toLatency,
                      active: widget.active,
                      progress: Curves.easeInOutCubic.transform(
                        _controller.value,
                      ),
                      probeFraction: _probeFraction,
                    ),
                  ),
                ),
                if (_probeFraction != null)
                  Positioned(
                    left: chipLeft,
                    top: 3,
                    width: chipWidth,
                    child: IgnorePointer(
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 5,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: .92),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: Colors.white),
                          boxShadow: [
                            BoxShadow(
                              color: const Color(
                                0xFF45658A,
                              ).withValues(alpha: .1),
                              blurRadius: 10,
                              offset: const Offset(0, 3),
                            ),
                          ],
                        ),
                        child: Wrap(
                          spacing: 9,
                          runSpacing: 3,
                          children: [
                            _ProbeValue(
                              color: _blue,
                              text:
                                  '↓ ${download == null ? '—' : _formatRate(download.round())}',
                            ),
                            _ProbeValue(
                              color: _mint,
                              text:
                                  '↑ ${upload == null ? '—' : _formatRate(upload.round())}',
                            ),
                            _ProbeValue(
                              color: const Color(0xFFE3A04B),
                              text:
                                  '延迟 ${latency == null || latency <= 5 ? '—' : '${latency.round()} ms'}',
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    ),
  );
}

class _ProbeValue extends StatelessWidget {
  const _ProbeValue({required this.color, required this.text});
  final Color color;
  final String text;
  @override
  Widget build(BuildContext context) => Text(
    text,
    style: TextStyle(color: color, fontSize: 9, fontWeight: FontWeight.w700),
  );
}

class _NetworkGraphPainter extends CustomPainter {
  const _NetworkGraphPainter({
    required this.fromDownload,
    required this.fromUpload,
    required this.fromLatency,
    required this.toDownload,
    required this.toUpload,
    required this.toLatency,
    required this.active,
    required this.progress,
    required this.probeFraction,
  });
  final List<double> fromDownload, fromUpload, fromLatency;
  final List<double> toDownload, toUpload, toLatency;
  final bool active;
  final double progress;
  final double? probeFraction;

  List<double> _blend(List<double> from, List<double> to) {
    final count = min(36, max(from.length, to.length));
    if (count == 0) return const [];
    List<double> sample(List<double> values) {
      if (values.isEmpty) return List<double>.filled(count, 0);
      if (values.length == count) return values;
      return List<double>.generate(count, (index) {
        final position = count == 1
            ? values.length - 1
            : index * (values.length - 1) / (count - 1);
        final left = position.floor();
        final right = min(left + 1, values.length - 1);
        return ui.lerpDouble(
          values[left],
          values[right],
          (position - left).toDouble(),
        )!;
      });
    }

    final a = sample(from);
    final b = sample(to);
    return List<double>.generate(
      count,
      (index) => ui.lerpDouble(a[index], b[index], progress)!,
    );
  }

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    final grid = Paint()
      ..color = const Color(0xFFDCE7F4).withValues(alpha: .72)
      ..strokeWidth = .75;
    for (var i = 0; i < 4; i++) {
      final y = size.height * i / 3;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), grid);
    }
    final download = _blend(fromDownload, toDownload);
    final upload = _blend(fromUpload, toUpload);
    final latency = _blend(fromLatency, toLatency);
    final maxBar = [
      ...download,
      ...upload,
    ].fold<double>(1, (current, value) => max(current, value));
    final count = max(download.length, upload.length);
    if (count > 0) {
      final barWidth = size.width / count * .26;
      for (var i = 0; i < count; i++) {
        final d = i < download.length ? download[i] : 0;
        final u = i < upload.length ? upload[i] : 0;
        final height = (max(d, u) / maxBar * size.height * .55)
            .clamp(1.0, size.height * .55)
            .toDouble();
        final x = size.width - (count - i) * size.width / count;
        final alpha = .045 + .07 * (i + 1) / count;
        final bars = Paint()
          ..shader =
              LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  _blue.withValues(alpha: alpha),
                  _mint.withValues(alpha: alpha * .32),
                ],
              ).createShader(
                Rect.fromLTWH(x, size.height - height, barWidth, height),
              );
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(x, size.height - height, barWidth, height),
            Radius.circular(barWidth / 2),
          ),
          bars,
        );
      }
    }
    _drawLine(canvas, size, download, fromDownload, toDownload, _blue, 2.4);
    _drawLine(canvas, size, upload, fromUpload, toUpload, _mint, 2.0);
    _drawLine(
      canvas,
      size,
      latency,
      fromLatency,
      toLatency,
      const Color(0xFFE3A04B),
      2.0,
    );
    if (probeFraction != null) {
      final x = 4 + probeFraction! * (size.width - 8);
      canvas.drawLine(
        Offset(x, 0),
        Offset(x, size.height),
        Paint()
          ..color = const Color(0xFF526782).withValues(alpha: .48)
          ..strokeWidth = 1
          ..strokeCap = StrokeCap.round,
      );
      _drawProbeDot(canvas, size, download, x, _blue);
      _drawProbeDot(canvas, size, upload, x, _mint);
      _drawProbeDot(canvas, size, latency, x, const Color(0xFFE3A04B));
    }
    if (active && download.isEmpty) {
      _drawIdleTrace(canvas, size, size.height * .76, _blue);
    }
    if (active && upload.isEmpty) {
      _drawIdleTrace(canvas, size, size.height * .86, _mint);
    }
    if (active && latency.isEmpty) {
      _drawIdleTrace(canvas, size, size.height * .31, const Color(0xFFE3A04B));
    }
    if (!active && latency.isEmpty) {
      final dash = Paint()
        ..color = const Color(0xFFB5C0D0).withValues(alpha: .7)
        ..strokeWidth = 1.2
        ..strokeCap = StrokeCap.round;
      for (var x = 0.0; x < size.width; x += 12) {
        canvas.drawLine(
          Offset(x, size.height * .55),
          Offset(x + 5, size.height * .55),
          dash,
        );
      }
    }
    canvas.restore();
  }

  void _drawProbeDot(
    Canvas canvas,
    Size size,
    List<double> values,
    double x,
    Color color,
  ) {
    if (values.isEmpty) return;
    final index = ((x - 4) / (size.width - 8) * (values.length - 1))
        .round()
        .clamp(0, values.length - 1);
    final maximum = values.fold<double>(1, max);
    final inset = min(size.height * .18, 14.0);
    final y =
        (size.height -
                values[index] / maximum * size.height * .7 -
                size.height * .12)
            .clamp(inset, max(inset, size.height - inset))
            .toDouble();
    canvas.drawCircle(
      Offset(x, y),
      5,
      Paint()..color = color.withValues(alpha: .18),
    );
    canvas.drawCircle(
      Offset(x, y),
      3,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.4,
    );
    canvas.drawCircle(Offset(x, y), 1.8, Paint()..color = color);
  }

  void _drawIdleTrace(Canvas canvas, Size size, double y, Color color) {
    final path = Path()..moveTo(0, y);
    path.cubicTo(
      size.width * .22,
      y - 2,
      size.width * .28,
      y + 2,
      size.width * .5,
      y,
    );
    path.cubicTo(
      size.width * .72,
      y - 2,
      size.width * .78,
      y + 2,
      size.width,
      y,
    );
    canvas.drawPath(
      path,
      Paint()
        ..color = color.withValues(alpha: .42)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.8
        ..strokeCap = StrokeCap.round
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 1.5),
    );
  }

  void _drawLine(
    Canvas canvas,
    Size size,
    List<double> values,
    List<double> from,
    List<double> to,
    Color color,
    double width,
  ) {
    if (values.isEmpty) return;
    final verticalInset = min(size.height * .18, max(5.0, width * 4 + 6));
    final topBound = verticalInset;
    final bottomBound = max(topBound, size.height - verticalInset);
    final maxValue = [
      ...from,
      ...to,
      ...values,
    ].fold<double>(1, (current, value) => max(current, value));
    final points = <Offset>[];
    for (var i = 0; i < values.length; i++) {
      final x = values.length == 1
          ? size.width
          : 4 + i * (size.width - 8) / (values.length - 1);
      final y =
          (size.height -
                  (values[i] / maxValue * size.height * .7) -
                  size.height * .12)
              .clamp(topBound, bottomBound)
              .toDouble();
      points.add(Offset(x, y));
    }
    final line = Path()..moveTo(points.first.dx, points.first.dy);
    for (var i = 0; i < points.length - 1; i++) {
      final p0 = i == 0 ? points[i] : points[i - 1];
      final p1 = points[i];
      final p2 = points[i + 1];
      final p3 = i + 2 < points.length ? points[i + 2] : p2;
      final control1 = Offset(
        p1.dx + (p2.dx - p0.dx) / 6,
        (p1.dy + (p2.dy - p0.dy) / 6).clamp(topBound, bottomBound).toDouble(),
      );
      final control2 = Offset(
        p2.dx - (p3.dx - p1.dx) / 6,
        (p2.dy - (p3.dy - p1.dy) / 6).clamp(topBound, bottomBound).toDouble(),
      );
      line.cubicTo(
        control1.dx,
        control1.dy,
        control2.dx,
        control2.dy,
        p2.dx,
        p2.dy,
      );
    }
    final fill = Path.from(line)
      ..lineTo(points.last.dx, size.height)
      ..lineTo(points.first.dx, size.height)
      ..close();
    canvas.drawPath(
      fill,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [color.withValues(alpha: .14), color.withValues(alpha: .005)],
        ).createShader(Rect.fromLTWH(0, 0, size.width, size.height)),
    );
    canvas.drawPath(
      line,
      Paint()
        ..color = color.withValues(alpha: .2)
        ..style = PaintingStyle.stroke
        ..strokeWidth = width * 3.8
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4),
    );
    canvas.drawPath(
      line,
      Paint()
        ..shader = LinearGradient(
          colors: [
            color.withValues(alpha: .64),
            color,
            color.withValues(alpha: .78),
          ],
        ).createShader(Offset.zero & size)
        ..style = PaintingStyle.stroke
        ..strokeWidth = width
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
    if (points.length > 1) {
      final last = points.last;
      canvas.drawCircle(
        last,
        width * 2.1,
        Paint()..color = color.withValues(alpha: .12),
      );
      canvas.drawCircle(
        last,
        width * .82,
        Paint()..color = color.withValues(alpha: .9),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _NetworkGraphPainter oldDelegate) =>
      oldDelegate.progress != progress ||
      oldDelegate.active != active ||
      !_listEquals(oldDelegate.fromDownload, fromDownload) ||
      !_listEquals(oldDelegate.fromUpload, fromUpload) ||
      !_listEquals(oldDelegate.fromLatency, fromLatency) ||
      !_listEquals(oldDelegate.toDownload, toDownload) ||
      !_listEquals(oldDelegate.toUpload, toUpload) ||
      !_listEquals(oldDelegate.toLatency, toLatency);

  bool _listEquals(List<double> a, List<double> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

class _TrafficSummary extends StatelessWidget {
  const _TrafficSummary({required this.stats, required this.connected});
  final SingBoxConnectionStats stats;
  final bool connected;
  @override
  Widget build(BuildContext context) => Row(
    children: [
      Expanded(
        child: _TrafficCard(
          icon: Icons.south_rounded,
          label: '下载速度',
          value: connected ? _formatRate(stats.downloadSpeed) : '—',
          tint: _blue,
        ),
      ),
      const SizedBox(width: 10),
      Expanded(
        child: _TrafficCard(
          icon: Icons.north_rounded,
          label: '上传速度',
          value: connected ? _formatRate(stats.uploadSpeed) : '—',
          tint: _mint,
        ),
      ),
    ],
  );
}

class _TrafficCard extends StatelessWidget {
  const _TrafficCard({
    required this.icon,
    required this.label,
    required this.value,
    required this.tint,
  });
  final IconData icon;
  final String label, value;
  final Color tint;
  @override
  Widget build(BuildContext context) => _Glass(
    padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 15),
    radius: 22,
    child: Row(
      children: [
        Container(
          width: 34,
          height: 34,
          decoration: BoxDecoration(
            color: tint.withValues(alpha: .11),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Icon(icon, size: 19, color: tint),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: const TextStyle(fontSize: 11, color: Color(0xFF7D8CA2)),
              ),
              const SizedBox(height: 3),
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 260),
                transitionBuilder: (child, animation) =>
                    FadeTransition(opacity: animation, child: child),
                child: Text(
                  value,
                  key: ValueKey(value),
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: _ink,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

class _ServerTile extends StatelessWidget {
  const _ServerTile({
    required this.server,
    required this.active,
    required this.connected,
    required this.onTap,
    required this.onDelete,
    this.lastSyncTime,
    this.result,
    this.testing = false,
    this.onTest,
  });
  final SingBoxServerConfig server;
  final bool active, connected;
  final VoidCallback onTap, onDelete;
  final DateTime? lastSyncTime;
  final SingBoxPingResult? result;
  final bool testing;
  final VoidCallback? onTest;
  @override
  Widget build(BuildContext context) => _Glass(
    padding: EdgeInsets.zero,
    radius: 22,
    blur: false,
    borderColor: active ? _blue.withValues(alpha: .36) : null,
    color: Colors.white.withValues(alpha: .86),
    child: Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(22),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(15, 14, 8, 14),
          child: Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: active
                      ? _blue.withValues(alpha: .12)
                      : const Color(0xFFF0F4FA),
                  borderRadius: BorderRadius.circular(15),
                ),
                child: Icon(
                  _protocolIcon(server.protocol),
                  color: active ? _blue : const Color(0xFF8292A8),
                  size: 21,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      server.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: _ink,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${server.protocol.toUpperCase()}  ·  ${server.server}${server.port > 0 ? ':${server.port}' : ''}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 11,
                        color: Color(0xFF8090A6),
                      ),
                    ),
                    if (lastSyncTime != null) ...[
                      const SizedBox(height: 3),
                      Text(
                        '最后同步 · ${_formatSubscriptionSyncTime(lastSyncTime)}',
                        style: const TextStyle(
                          fontSize: 10,
                          color: Color(0xFF8190A5),
                        ),
                      ),
                    ],
                    if (result != null) ...[
                      const SizedBox(height: 4),
                      Text(
                        result!.success
                            ? '${result!.ping} ms · ${result!.method == SingBoxPingMethod.tcp ? 'TCP' : '代理可用'} · ${_latencyGrade(result!.ping)}'
                            : '不可用',
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                          color: result!.success
                              ? _latencyColor(result!.ping)
                              : const Color(0xFFC76B72),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              IconButton(
                tooltip: connected ? '通过代理测试延迟' : '测试 TCP 延迟',
                onPressed: testing ? null : onTest,
                icon: testing
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator.adaptive(
                          strokeWidth: 2,
                        ),
                      )
                    : const Icon(Icons.speed_rounded, color: _blue, size: 19),
              ),
              if (connected)
                const Padding(
                  padding: EdgeInsets.only(right: 4),
                  child: Icon(
                    Icons.check_circle_rounded,
                    color: _mint,
                    size: 20,
                  ),
                ),
              if (active && !connected)
                const Padding(
                  padding: EdgeInsets.only(right: 4),
                  child: Icon(
                    Icons.radio_button_checked_rounded,
                    color: _blue,
                    size: 19,
                  ),
                ),
              PopupMenuButton<String>(
                tooltip: '节点操作',
                icon: const Icon(
                  Icons.more_horiz_rounded,
                  color: Color(0xFF8190A4),
                ),
                onSelected: (value) {
                  if (value == 'delete') onDelete();
                },
                itemBuilder: (context) => const [
                  PopupMenuItem(value: 'delete', child: Text('删除节点')),
                ],
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

String _latencyGrade(int ms) => ms < 120
    ? '优'
    : ms < 250
    ? '良'
    : ms < 500
    ? '一般'
    : '较慢';
Color _latencyColor(int ms) => ms < 120
    ? const Color(0xFF219879)
    : ms < 250
    ? const Color(0xFF628A42)
    : ms < 500
    ? const Color(0xFFCE8D39)
    : const Color(0xFFCA5F6A);

void _appendSample(List<double> values, double value) {
  values.add(value);
  if (values.length > 36) values.removeAt(0);
}

Future<SingBoxPingResult> _directTcpPing(
  SingBoxServerConfig server,
  Duration timeout,
) async {
  if (_isLoopbackProfile(server)) {
    return SingBoxPingResult.failure(
      '无效节点：服务器地址是本机回环地址',
      address: server.server,
      tag: server.name,
      serverId: server.id,
    );
  }
  try {
    final result = await _directNetworkChannel
        .invokeMapMethod<String, dynamic>('directTcpPing', {
          'host': server.server,
          'port': server.port,
          'timeoutMs': timeout.inMilliseconds,
        });
    if (result?['success'] == true) {
      return SingBoxPingResult(
        ping: result?['ping'] as int? ?? 0,
        success: true,
        address: server.server,
        tag: server.name,
        serverId: server.id,
        method: SingBoxPingMethod.tcp,
      );
    }
    return SingBoxPingResult.failure(
      result?['error']?.toString() ?? '直连探测失败',
      address: server.server,
      tag: server.name,
      serverId: server.id,
      method: SingBoxPingMethod.tcp,
    );
  } on Object catch (error) {
    return SingBoxPingResult.failure(
      error.toString(),
      address: server.server,
      tag: server.name,
      serverId: server.id,
      method: SingBoxPingMethod.tcp,
    );
  }
}

bool _isLoopbackProfile(SingBoxServerConfig server) {
  return _isLoopbackHost(server.server);
}

bool _isLoopbackHost(String value) {
  final host = value.trim().toLowerCase();
  if (host == 'localhost' || host.endsWith('.localhost')) return true;
  final address = InternetAddress.tryParse(
    host.replaceAll('[', '').replaceAll(']', ''),
  );
  return address?.isLoopback ?? false;
}

SingBoxPingResult _rejectSuspiciousNodeLatency(SingBoxPingResult result) {
  if (!result.success || result.ping > 5) return result;
  return SingBoxPingResult.failure(
    '无效节点：延迟异常（${result.ping} ms）',
    address: result.address,
    tag: result.tag,
    serverId: result.serverId,
    method: result.method,
  );
}

SingBoxPingResult _nodeUrlTestResult(
  int? latency, {
  required String tag,
  required String serverId,
}) {
  if (latency == null) {
    return SingBoxPingResult.failure(
      'URL test failed',
      tag: tag,
      serverId: serverId,
    );
  }
  if (latency <= 5) {
    return SingBoxPingResult.failure(
      '无效节点：测速结果异常（$latency ms）',
      tag: tag,
      serverId: serverId,
    );
  }
  return SingBoxPingResult(
    ping: latency,
    success: true,
    tag: tag,
    serverId: serverId,
  );
}

class _TestControlCard extends StatelessWidget {
  const _TestControlCard({
    required this.connected,
    required this.testing,
    required this.onTestAll,
    required this.results,
    required this.servers,
    required this.onSelect,
    required this.autoSelect,
    required this.onAutoSelectChanged,
  });
  final bool connected, testing, autoSelect;
  final VoidCallback? onTestAll;
  final Map<String, SingBoxPingResult> results;
  final List<SingBoxServerConfig> servers;
  final ValueChanged<SingBoxServerConfig> onSelect;
  final ValueChanged<bool> onAutoSelectChanged;
  @override
  Widget build(BuildContext context) {
    final ranked =
        servers.where((server) => results[server.id]?.success == true).toList()
          ..sort((a, b) => results[a.id]!.ping.compareTo(results[b.id]!.ping));
    final recommended = ranked.take(5).toList();
    return _Glass(
      padding: const EdgeInsets.all(16),
      radius: 22,
      blur: false,
      color: Colors.white.withValues(alpha: .88),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: _blue.withValues(alpha: .1),
                  borderRadius: BorderRadius.circular(13),
                ),
                child: Icon(
                  connected
                      ? Icons.verified_rounded
                      : Icons.network_check_rounded,
                  color: _blue,
                  size: 20,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      connected ? '代理可用性与延迟' : '节点延迟测试',
                      style: const TextStyle(
                        color: _ink,
                        fontWeight: FontWeight.w800,
                        fontSize: 14,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      connected
                          ? '通过 Google 测试地址经代理探测；不切换当前节点'
                          : '未连接 VPN，仅测服务器 TCP 延迟',
                      style: const TextStyle(
                        color: Color(0xFF7889A0),
                        fontSize: 10,
                      ),
                    ),
                  ],
                ),
              ),
              FilledButton.tonalIcon(
                onPressed: onTestAll,
                icon: testing
                    ? const SizedBox(
                        width: 15,
                        height: 15,
                        child: CircularProgressIndicator.adaptive(
                          strokeWidth: 2,
                        ),
                      )
                    : const Icon(Icons.play_arrow_rounded, size: 18),
                label: const Text('测试全部'),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.fromLTRB(12, 8, 5, 8),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: .58),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: Colors.white.withValues(alpha: .82)),
            ),
            child: Row(
              children: [
                Icon(
                  Icons.auto_awesome_rounded,
                  size: 18,
                  color: autoSelect ? _blue : const Color(0xFF8997AA),
                ),
                const SizedBox(width: 9),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        '自动选择最低延迟节点',
                        style: TextStyle(
                          color: _ink,
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        autoSelect ? '已开启 · 每 5 分钟静默测速并切换' : '关闭时使用手动选择的节点',
                        style: const TextStyle(
                          color: Color(0xFF7889A0),
                          fontSize: 9,
                        ),
                      ),
                    ],
                  ),
                ),
                Switch.adaptive(
                  value: autoSelect,
                  onChanged: onAutoSelectChanged,
                ),
              ],
            ),
          ),
          if (recommended.isNotEmpty) ...[
            const Padding(
              padding: EdgeInsets.only(top: 14, bottom: 8),
              child: Text(
                '低延迟推荐',
                style: TextStyle(
                  color: _ink,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            for (final server in recommended)
              Padding(
                padding: const EdgeInsets.only(top: 5),
                child: InkWell(
                  onTap: () => onSelect(server),
                  borderRadius: BorderRadius.circular(12),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      vertical: 5,
                      horizontal: 3,
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.bolt_rounded, size: 16, color: _mint),
                        const SizedBox(width: 7),
                        Expanded(
                          child: Text(
                            server.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: _ink,
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        Text(
                          '${results[server.id]!.ping} ms · ${_latencyGrade(results[server.id]!.ping)}',
                          style: TextStyle(
                            color: _latencyColor(results[server.id]!.ping),
                            fontSize: 10,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ],
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.onAdd});
  final VoidCallback onAdd;
  @override
  Widget build(BuildContext context) => _Glass(
    padding: const EdgeInsets.fromLTRB(20, 26, 20, 24),
    child: Column(
      children: [
        Container(
          width: 60,
          height: 60,
          decoration: BoxDecoration(
            color: _blue.withValues(alpha: .1),
            shape: BoxShape.circle,
          ),
          child: const Icon(Icons.link_rounded, color: _blue, size: 26),
        ),
        const SizedBox(height: 13),
        const Text(
          '从一条链接开始',
          style: TextStyle(
            fontSize: 17,
            fontWeight: FontWeight.w700,
            color: _ink,
          ),
        ),
        const SizedBox(height: 7),
        const Text(
          '粘贴代理分享链接或订阅地址\n节点信息会保存在本机',
          textAlign: TextAlign.center,
          style: TextStyle(color: Color(0xFF75859A), height: 1.5, fontSize: 13),
        ),
        const SizedBox(height: 17),
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            onPressed: onAdd,
            icon: const Icon(Icons.add_link_rounded),
            label: const Text('添加订阅 / 节点'),
          ),
        ),
      ],
    ),
  );
}

class _MessageCard extends StatelessWidget {
  const _MessageCard({required this.icon, required this.text});
  final IconData icon;
  final String text;
  @override
  Widget build(BuildContext context) => _Glass(
    child: Row(
      children: [
        Icon(icon, color: const Color(0xFFCA5F6A)),
        const SizedBox(width: 12),
        Expanded(
          child: Text(text, style: const TextStyle(color: _ink)),
        ),
      ],
    ),
  );
}

class _Footer extends StatelessWidget {
  const _Footer({this.version});
  final String? version;
  @override
  Widget build(BuildContext context) => Row(
    mainAxisAlignment: MainAxisAlignment.center,
    children: [
      const Icon(
        Icons.lock_outline_rounded,
        size: 14,
        color: Color(0xFF91A0B5),
      ),
      const SizedBox(width: 6),
      Text(
        'Hourglass $_appVersion · 本地处理${version == null ? '' : ' · sing-box $version'}',
        style: const TextStyle(color: Color(0xFF8797AC), fontSize: 11),
      ),
    ],
  );
}

class _SmallIconButton extends StatelessWidget {
  const _SmallIconButton({
    required this.icon,
    required this.onTap,
    this.tooltip,
  });
  final IconData icon;
  final VoidCallback onTap;
  final String? tooltip;
  @override
  Widget build(BuildContext context) => Tooltip(
    message: tooltip ?? '',
    child: Material(
      color: Colors.white.withValues(alpha: .7),
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: SizedBox(
          width: 42,
          height: 42,
          child: Icon(icon, color: _ink, size: 21),
        ),
      ),
    ),
  );
}

IconData _protocolIcon(String protocol) => switch (protocol.toLowerCase()) {
  'vless' || 'vmess' => Icons.bolt_rounded,
  'trojan' || 'anytls' => Icons.shield_rounded,
  'shadowsocks' => Icons.blur_on_rounded,
  'hysteria' || 'hysteria2' || 'tuic' => Icons.speed_rounded,
  'wireguard' => Icons.hub_rounded,
  _ => Icons.public_rounded,
};

String _formatRate(int bytes) {
  if (bytes < 1024) return '$bytes B/s';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB/s';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB/s';
}

extension _NavigatorPop<T> on BuildContext {
  void pop<R>([R? result]) => Navigator.of(this).pop<R>(result);
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
