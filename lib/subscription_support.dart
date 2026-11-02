import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:sing_box/sing_box.dart';
import 'package:yaml/yaml.dart';

typedef SubscriptionBodyValidator = bool Function(String body);
typedef SubscriptionDownloader =
    Future<SubscriptionHttpResponse> Function(
      String url, {
      SubscriptionBodyValidator? validate,
    });

class SubscriptionDownloadException implements Exception {
  const SubscriptionDownloadException(this.message, {required this.retryable});
  final String message;
  final bool retryable;
  @override
  String toString() => message;
}

class SubscriptionHttpResponse {
  const SubscriptionHttpResponse(this.body, this.userAgent, this.statusCode);
  final String body;
  final String userAgent;
  final int statusCode;
}

class ClashSubscriptionData {
  const ClashSubscriptionData({
    required this.outbounds,
    required this.proxyGroups,
    required this.bypassDomains,
    required this.blockedDomains,
    required this.bypassSubnets,
    required this.bypassCountries,
    required this.geodataRules,
    required this.downloadedProviders,
    required this.warnings,
  });

  final List<Map<String, dynamic>> outbounds;

  /// Clash strategy groups retained for the subscription node browser.
  /// Each entry contains a name, source strategy type, and flattened node tags.
  final List<Map<String, dynamic>> proxyGroups;
  final List<String> bypassDomains;
  final List<String> blockedDomains;
  final List<String> bypassSubnets;
  final List<String> bypassCountries;
  final List<Map<String, String>> geodataRules;
  final int downloadedProviders;
  final List<String> warnings;
}

const _subscriptionUserAgents = [
  'Hourglass/0.1.0',
  'clash-verge/v2.0.0',
  'v2rayN/7.0.0',
  'NekoBox/1.4.1 (Prefer ClashMeta Format)',
  'Karing/1.2.26',
];

/// Retries provider-specific user agents and follows HTTP redirects. A caller
/// can validate the response format so an HTML error page does not look like
/// a successful subscription download.
Future<SubscriptionHttpResponse> downloadSubscription(
  String url, {
  String? preferredUserAgent,
  SubscriptionBodyValidator? validate,
  int? maxAttempts,
  Duration timeout = const Duration(seconds: 55),
}) async {
  final uri = Uri.tryParse(url.trim());
  if (uri?.scheme == 'http') {
    throw const FormatException('为保护订阅凭据与代理配置，Hourglass 仅允许 HTTPS 订阅和规则下载');
  }
  if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) {
    throw const FormatException('订阅地址必须是有效的 HTTPS 链接');
  }
  final userAgents = <String>{
    if (preferredUserAgent != null && preferredUserAgent.trim().isNotEmpty)
      preferredUserAgent.trim(),
    ..._subscriptionUserAgents,
  };
  Object? lastError;
  int? lastStatus;
  var attempts = 0;
  for (final userAgent in userAgents) {
    if (maxAttempts != null && attempts >= maxAttempts) break;
    attempts++;
    try {
      final response = await http
          .get(
            uri,
            headers: {
              'accept':
                  'application/yaml, text/yaml, text/plain, application/json, */*',
              'user-agent': userAgent,
              'cache-control': 'no-cache',
            },
          )
          .timeout(timeout);
      lastStatus = response.statusCode;
      if (response.statusCode < 200 || response.statusCode >= 300) {
        lastError = FormatException('HTTP ${response.statusCode}');
        continue;
      }
      var body = utf8.decode(response.bodyBytes, allowMalformed: true).trim();
      body = body.replaceFirst('\uFEFF', '').trim();
      if (body.isEmpty) {
        lastError = const FormatException('服务器返回了空内容');
        continue;
      }
      final lowered = body.toLowerCase();
      if (lowered.startsWith('<!doctype html') || lowered.startsWith('<html')) {
        lastError = const FormatException('服务器返回了网页而非订阅配置');
        continue;
      }
      if (validate != null && !validate(body)) {
        lastError = const FormatException('响应格式无法识别');
        continue;
      }
      return SubscriptionHttpResponse(body, userAgent, response.statusCode);
    } on Object catch (error) {
      lastError = error;
    }
  }
  final host = uri.host;
  final statusText = lastStatus == null ? '' : '（HTTP $lastStatus）';
  final retryable =
      lastError is TimeoutException ||
      lastError is SocketException ||
      lastError is HttpException ||
      lastError is http.ClientException;
  throw SubscriptionDownloadException(
    '订阅下载失败：$host$statusText。${lastError ?? '请检查网络、订阅地址或服务商要求的 User-Agent。'}',
    retryable: retryable,
  );
}

Future<ClashSubscriptionData?> parseClashSubscription(
  String content, {
  String? sourceUrl,
  SubscriptionDownloader? downloader,
}) async {
  Future<SubscriptionHttpResponse> fetch(
    String url, {
    SubscriptionBodyValidator? validate,
  }) =>
      downloader?.call(url, validate: validate) ??
      downloadSubscription(url, validate: validate);
  final decoded = _decodeYaml(content);
  if (decoded is! Map<String, dynamic>) return null;
  final root = decoded;
  final proxies = <Map<String, dynamic>>[];
  final warnings = <String>[];
  var downloadedProviders = 0;
  final seen = <String>{};

  void addProxies(Iterable<dynamic> values) {
    for (final value in values) {
      if (value is! Map) continue;
      final proxy = _stringMap(value);
      final tag = (proxy['name'] ?? proxy['tag'] ?? '').toString().trim();
      if (tag.isEmpty || !seen.add(tag)) continue;
      final outbound = _clashProxyToOutbound(proxy);
      if (outbound != null) proxies.add(outbound);
    }
  }

  final ownProxies = root['proxies'];
  if (ownProxies is List) addProxies(ownProxies);

  final proxyProviders = root['proxy-providers'];
  if (proxyProviders is Map) {
    for (final entry in proxyProviders.entries) {
      final provider = entry.value is Map
          ? _stringMap(entry.value as Map)
          : <String, dynamic>{};
      final inline = provider['proxies'];
      if (inline is List) {
        addProxies(inline);
        continue;
      }
      final rawUrl = provider['url']?.toString();
      if (rawUrl == null || rawUrl.isEmpty || provider['type'] == 'file') {
        if (provider['type'] == 'file')
          warnings.add('本地 proxy-provider「${entry.key}」无法从远程订阅读取');
        continue;
      }
      try {
        final providerUrl = _resolveUrl(rawUrl, sourceUrl);
        final response = await fetch(
          providerUrl,
          validate: (body) =>
              _hasProxyPayload(body) ||
              SingBoxShareLink.parseSubscription(body).isNotEmpty,
        );
        final shareLinks = SingBoxShareLink.parseSubscription(response.body);
        if (shareLinks.isNotEmpty) {
          for (final link in shareLinks) {
            final tag = link.tag;
            if (seen.add(tag))
              proxies.add(Map<String, dynamic>.from(link.json));
          }
        } else {
          final providerConfig = _decodeYaml(response.body);
          if (providerConfig is Map<String, dynamic> &&
              providerConfig['proxies'] is List) {
            addProxies(providerConfig['proxies'] as List);
          }
        }
        downloadedProviders++;
      } on Object catch (error) {
        warnings.add('proxy-provider「${entry.key}」下载失败：$error');
      }
    }
  }

  if (proxies.isEmpty) return null;

  final ruleProviders = <String, Map<String, dynamic>>{};
  final rawRuleProviders = root['rule-providers'];
  if (rawRuleProviders is Map) {
    for (final entry in rawRuleProviders.entries) {
      final provider = entry.value is Map
          ? _stringMap(entry.value as Map)
          : <String, dynamic>{};
      ruleProviders[entry.key.toString()] = provider;
    }
  }

  final bypassDomains = <String>{};
  final blockedDomains = <String>{};
  final bypassSubnets = <String>{};
  final bypassCountries = <String>{};
  final geodataRules = <String>{};
  final rules = root['rules'];
  final routeSets =
      <String, ({String action, Map<String, dynamic> provider})>{};
  if (rules is List) {
    for (final rawRule in rules) {
      if (rawRule is! String) continue;
      final parts = rawRule.split(',').map((part) => part.trim()).toList();
      if (parts.length < 2) continue;
      final type = parts[0].toUpperCase();
      final policyIndex = type == 'RULE-SET' ? 2 : 2;
      if (parts.length <= policyIndex) continue;
      final action = parts[policyIndex].toUpperCase();
      if (type == 'RULE-SET' && parts.length >= 3) {
        final provider = ruleProviders[parts[1]];
        if (provider != null)
          routeSets[parts[1]] = (action: action, provider: provider);
      } else {
        _applyClashRule(
          parts,
          action,
          bypassDomains,
          blockedDomains,
          bypassSubnets,
          bypassCountries,
          geodataRules,
        );
      }
    }
  }

  for (final entry in routeSets.entries) {
    final provider = entry.value.provider;
    final action = entry.value.action;
    final inlinePayload = provider['payload'];
    dynamic payload = inlinePayload;
    final rawUrl = provider['url']?.toString();
    if (payload == null &&
        rawUrl != null &&
        rawUrl.isNotEmpty &&
        provider['type'] != 'file') {
      try {
        final response = await fetch(_resolveUrl(rawUrl, sourceUrl));
        payload = _decodeYaml(response.body) ?? response.body;
        downloadedProviders++;
      } on Object catch (error) {
        warnings.add('rule-provider「${entry.key}」下载失败：$error');
        continue;
      }
    }
    final behavior = (provider['behavior'] ?? 'classical')
        .toString()
        .toLowerCase();
    _applyRuleProviderPayload(
      payload,
      behavior,
      action,
      bypassDomains,
      blockedDomains,
      bypassSubnets,
      bypassCountries,
      geodataRules,
    );
  }

  final rawGroups = root['proxy-groups'];
  final groupDefs = <String, Map<String, dynamic>>{};
  if (rawGroups is List) {
    for (final raw in rawGroups) {
      if (raw is! Map) continue;
      final definition = _stringMap(raw);
      final name = (definition['name'] ?? '').toString().trim();
      if (name.isNotEmpty) groupDefs[name] = definition;
    }
  }
  final availableTags = proxies
      .map((outbound) => (outbound['tag'] ?? '').toString())
      .where((tag) => tag.isNotEmpty)
      .toSet();
  final proxyGroups = <Map<String, dynamic>>[];
  for (final entry in groupDefs.entries) {
    final members = <String>{};
    final visited = <String>{};
    void collect(String groupName) {
      if (!visited.add(groupName)) return;
      final definition = groupDefs[groupName];
      if (definition == null) return;
      final rawMembers = definition['proxies'];
      if (rawMembers is! List) return;
      for (final rawMember in rawMembers) {
        final member = rawMember.toString();
        if (availableTags.contains(member)) {
          members.add(member);
        } else if (groupDefs.containsKey(member)) {
          collect(member);
        }
      }
    }

    collect(entry.key);
    if (members.isNotEmpty) {
      proxyGroups.add({
        'name': entry.key,
        'type': (entry.value['type'] ?? 'select').toString().toLowerCase(),
        'nodes': members.toList(),
      });
    }
  }

  return ClashSubscriptionData(
    outbounds: proxies,
    proxyGroups: proxyGroups,
    bypassDomains: bypassDomains.toList(),
    blockedDomains: blockedDomains.toList(),
    bypassSubnets: bypassSubnets.toList(),
    bypassCountries: bypassCountries.toList(),
    geodataRules: geodataRules.map((entry) {
      final parts = entry.split('|');
      return {'type': parts[0], 'value': parts[1], 'action': parts[2]};
    }).toList(),
    downloadedProviders: downloadedProviders,
    warnings: warnings,
  );
}

bool _hasProxyPayload(String body) {
  final parsed = _decodeYaml(body);
  return parsed is Map<String, dynamic> && parsed['proxies'] is List;
}

bool isSupportedSubscriptionBody(String body) {
  if (SingBoxShareLink.parseSubscription(body).isNotEmpty ||
      _hasProxyPayload(body)) {
    return true;
  }
  final value = _decodeYaml(body);
  return value is Map<String, dynamic> &&
      (value.containsKey('proxy-providers') ||
          value.containsKey('rule-providers'));
}

dynamic _decodeYaml(String input) {
  try {
    return _plainYaml(loadYaml(input));
  } on Object {
    return null;
  }
}

dynamic _plainYaml(dynamic value) {
  if (value is YamlMap || value is Map) {
    return <String, dynamic>{
      for (final entry in (value as Map).entries)
        entry.key.toString(): _plainYaml(entry.value),
    };
  }
  if (value is YamlList || value is List) return value.map(_plainYaml).toList();
  return value;
}

Map<String, dynamic> _stringMap(Map value) => {
  for (final entry in value.entries)
    entry.key.toString(): _plainYaml(entry.value),
};

String _resolveUrl(String raw, String? base) {
  final url = Uri.parse(raw);
  if (url.hasScheme || base == null) return url.toString();
  return Uri.parse(base).resolveUri(url).toString();
}

Map<String, dynamic>? _clashProxyToOutbound(Map<String, dynamic> proxy) {
  final type = (proxy['type'] ?? '').toString().toLowerCase();
  final tag = (proxy['name'] ?? proxy['tag'] ?? '').toString();
  final server = proxy['server']?.toString();
  final port = int.tryParse(proxy['port']?.toString() ?? '');
  if (tag.isEmpty ||
      server == null ||
      server.isEmpty ||
      port == null ||
      port <= 0)
    return null;
  final outbound = <String, dynamic>{
    'tag': tag,
    'server': server,
    'server_port': port,
  };
  switch (type) {
    case 'ss':
      outbound.addAll({
        'type': 'shadowsocks',
        'method': proxy['cipher'] ?? proxy['method'],
        'password': proxy['password'],
      });
      if (proxy['udp'] == false) outbound['network'] = 'tcp';
      final plugin = proxy['plugin']?.toString();
      final pluginOptions = proxy['plugin-opts'];
      if (plugin != null && plugin.isNotEmpty) {
        outbound['plugin'] = plugin == 'obfs' ? 'obfs-local' : plugin;
        if (pluginOptions is Map)
          outbound['plugin_opts'] = _stringMap(pluginOptions);
      }
      break;
    case 'vmess':
      outbound.addAll({
        'type': 'vmess',
        'uuid': proxy['uuid'],
        'security': proxy['cipher'] ?? 'auto',
        'alter_id': proxy['alterId'] ?? 0,
      });
      _applyTls(outbound, proxy);
      _applyTransport(outbound, proxy);
      break;
    case 'vless':
      outbound.addAll({'type': 'vless', 'uuid': proxy['uuid']});
      if (proxy['flow'] != null) outbound['flow'] = proxy['flow'];
      _applyTls(outbound, proxy);
      _applyTransport(outbound, proxy);
      break;
    case 'trojan':
      outbound.addAll({'type': 'trojan', 'password': proxy['password']});
      _applyTls(outbound, proxy, force: true);
      _applyTransport(outbound, proxy);
      break;
    case 'hysteria2':
    case 'hy2':
      outbound.addAll({'type': 'hysteria2', 'password': proxy['password']});
      _applyTls(outbound, proxy, force: true);
      final obfs = proxy[' obfs'] ?? proxy['obfs'];
      if (obfs is Map)
        outbound['obfs'] = {'type': obfs['type'], 'password': obfs['password']};
      break;
    case 'tuic':
      outbound.addAll({
        'type': 'tuic',
        'uuid': proxy['uuid'],
        'password': proxy['password'],
        'congestion_control': proxy['congestion-controller'] ?? 'bbr',
      });
      _applyTls(outbound, proxy, force: true);
      break;
    case 'socks5':
    case 'socks':
      outbound.addAll({'type': 'socks', 'version': '5'});
      if (proxy['username'] != null) outbound['username'] = proxy['username'];
      if (proxy['password'] != null) outbound['password'] = proxy['password'];
      break;
    case 'http':
      outbound['type'] = 'http';
      if (proxy['username'] != null) outbound['username'] = proxy['username'];
      if (proxy['password'] != null) outbound['password'] = proxy['password'];
      if (proxy['tls'] == true) _applyTls(outbound, proxy, force: true);
      break;
    case 'anytls':
      outbound.addAll({'type': 'anytls', 'password': proxy['password']});
      _applyTls(outbound, proxy, force: true);
      break;
    default:
      return null;
  }
  outbound.removeWhere((key, value) => value == null);
  return outbound;
}

void _applyTls(
  Map<String, dynamic> outbound,
  Map<String, dynamic> proxy, {
  bool force = false,
}) {
  if (proxy['tls'] != true && !force) return;
  final serverName =
      proxy['servername'] ?? proxy['server-name'] ?? proxy['sni'];
  final tls = <String, dynamic>{
    'enabled': true,
    if (serverName case final String name) 'server_name': name,
    // Never let a remote subscription disable certificate validation.
    'insecure': false,
  };
  final alpn = proxy['alpn'];
  if (alpn is List) tls['alpn'] = alpn;
  final reality = proxy['reality-opts'];
  if (reality is Map) {
    final values = _stringMap(reality);
    tls['reality'] = {
      'enabled': true,
      if (values['public-key'] != null) 'public_key': values['public-key'],
      if (values['short-id'] != null) 'short_id': values['short-id'],
    };
  }
  final fingerprint = proxy['client-fingerprint'];
  if (fingerprint != null)
    tls['utls'] = {'enabled': true, 'fingerprint': fingerprint};
  outbound['tls'] = tls;
}

void _applyTransport(
  Map<String, dynamic> outbound,
  Map<String, dynamic> proxy,
) {
  final network = (proxy['network'] ?? '').toString().toLowerCase();
  final ws = proxy['ws-opts'];
  final grpc = proxy['grpc-opts'];
  if (network == 'ws' || ws is Map) {
    final options = ws is Map ? _stringMap(ws) : <String, dynamic>{};
    final headers = options['headers'] is Map
        ? _stringMap(options['headers'])
        : <String, dynamic>{};
    outbound['transport'] = {
      'type': 'ws',
      if (options['path'] != null) 'path': options['path'],
      if (headers.isNotEmpty) 'headers': headers,
    };
  } else if (network == 'grpc' || grpc is Map) {
    final options = grpc is Map ? _stringMap(grpc) : <String, dynamic>{};
    outbound['transport'] = {
      'type': 'grpc',
      if (options['grpc-service-name'] != null)
        'service_name': options['grpc-service-name'],
    };
  } else if (network == 'h2' || network == 'http') {
    final options = proxy['h2-opts'] is Map
        ? _stringMap(proxy['h2-opts'] as Map)
        : <String, dynamic>{};
    outbound['transport'] = {
      'type': 'http',
      if (options['path'] is List && (options['path'] as List).isNotEmpty)
        'path': (options['path'] as List).first,
      if (options['host'] is List && (options['host'] as List).isNotEmpty)
        'host': (options['host'] as List).first,
    };
  }
}

void _applyClashRule(
  List<String> parts,
  String action,
  Set<String> bypassDomains,
  Set<String> blockedDomains,
  Set<String> bypassSubnets,
  Set<String> bypassCountries,
  Set<String> geodataRules,
) {
  final type = parts[0].toUpperCase();
  final value = parts.length > 1 ? parts[1].trim() : '';
  if (value.isEmpty) return;
  final direct = action == 'DIRECT';
  final reject = action == 'REJECT' || action == 'REJECT-DROP';
  if (type == 'GEOIP' && direct) bypassCountries.add(value.toLowerCase());
  if ({'GEOIP', 'GEOSITE'}.contains(type) &&
      (direct || reject || action == 'PROXY' || action == 'GLOBAL')) {
    if (type == 'GEOSITE' || !direct) {
      geodataRules.add(
        '$type|${value.toLowerCase()}|${reject
            ? 'REJECT'
            : direct
            ? 'DIRECT'
            : 'PROXY'}',
      );
    }
  }
  if ({'DOMAIN', 'DOMAIN-SUFFIX', 'DOMAIN-KEYWORD'}.contains(type)) {
    if (direct) bypassDomains.add(value.replaceFirst(RegExp(r'^\*\.'), ''));
    if (reject) blockedDomains.add(value.replaceFirst(RegExp(r'^\*\.'), ''));
  }
  if ((type == 'IP-CIDR' || type == 'IP-CIDR6') && direct)
    bypassSubnets.add(value);
}

void _applyRuleProviderPayload(
  dynamic payload,
  String behavior,
  String action,
  Set<String> bypassDomains,
  Set<String> blockedDomains,
  Set<String> bypassSubnets,
  Set<String> bypassCountries,
  Set<String> geodataRules,
) {
  final entries = payload is List
      ? payload
      : payload is Map
      ? (payload['payload'] is List ? payload['payload'] as List : const [])
      : payload is String
      ? payload.split(RegExp(r'[\r\n]+'))
      : const [];
  if (behavior == 'domain') {
    for (final raw in entries) {
      var value = raw.toString().trim();
      if (value.isEmpty || value.startsWith('#')) continue;
      value = value
          .replaceFirst(
            RegExp(r'^(\+\.|domain-suffix:|domain:|domain_keyword:)'),
            '',
          )
          .trim();
      if (value.isEmpty || value.contains(' ')) continue;
      if (action == 'DIRECT') bypassDomains.add(value);
      if (action == 'REJECT' || action == 'REJECT-DROP')
        blockedDomains.add(value);
    }
    return;
  }
  for (final raw in entries) {
    final line = raw.toString().trim();
    if (line.isEmpty || line.startsWith('#')) continue;
    final parts = line.split(',').map((part) => part.trim()).toList();
    if (parts.length >= 2) {
      _applyClashRule(
        parts,
        action,
        bypassDomains,
        blockedDomains,
        bypassSubnets,
        bypassCountries,
        geodataRules,
      );
    } else if (behavior == 'ipcidr' &&
        action == 'DIRECT' &&
        line.contains('/')) {
      bypassSubnets.add(line);
    }
  }
}
