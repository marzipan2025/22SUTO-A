/// 새 버전이 나왔는지 GitHub 릴리스에 묻고, 새 APK 를 받아 설치 화면까지 넘긴다.
///
/// 맥 앱들(01haka·08FOSE·24DOST)이 쓰는 흐름을 그대로 옮긴 것이다.
/// 다만 그쪽은 dmg 를 조용히 마운트해 앱 번들을 통째로 갈아끼우는 반면,
/// 안드로이드는 앱이 자기를 설치할 수 없다 — 받은 APK 를 시스템 설치 화면에
/// 넘기고 사용자가 확인을 누르는 데까지가 앱이 할 수 있는 전부다.
///
/// 파일이 400MB 를 넘으므로 받는 동안 얼마나 왔는지 계속 알려 준다.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:suto_a/helper.dart' show logger;

const _updateChannel = MethodChannel('suto_a/update');

const _repo = 'marzipan2025/22SUTO-A';
const releasesPageUrl = 'https://github.com/$_repo/releases';

/// 이 앱이 기대고 있는 것들을 적어 둔 자리
const licensesPageUrl =
    'https://github.com/$_repo/blob/main/LICENSES.md';
const _latestApiUrl = 'https://api.github.com/repos/$_repo/releases/latest';

/// 한 번 확인한 결과
sealed class UpdateStatus {
  const UpdateStatus();
}

/// 이미 최신
class UpToDate extends UpdateStatus {
  const UpToDate(this.current);
  final String current;
}

/// 새 버전이 있다
class UpdateAvailable extends UpdateStatus {
  const UpdateAvailable({
    required this.latest,
    required this.current,
    required this.apkUrl,
    required this.bytes,
  });

  final String latest;
  final String current;

  /// 받을 APK 주소. 릴리스에 APK 가 안 붙어 있으면 null 이다.
  final String? apkUrl;

  /// 그 APK 의 크기 (바이트). 모르면 0.
  final int bytes;
}

/// GitHub 에 닿지 못했다
class UpdateCheckFailed extends UpdateStatus {
  const UpdateCheckFailed();
}

/// 지금 깔려 있는 버전 (pubspec 의 version 이 그대로 온다)
Future<String> currentVersion() async {
  final v = await _updateChannel.invokeMethod<String>('version');
  return v ?? '0.0.0';
}

/// 이 설치본을 가리키는 표 — 다시 깔 때마다 달라진다.
/// 앱과 함께 온 파일을 꺼내 두었을 때, 그것이 지금 앱의 것인지 가리는 데 쓴다.
Future<String> buildStamp() async {
  try {
    final v = await _updateChannel.invokeMethod<String>('buildStamp');
    if (v != null && v.isNotEmpty) return v;
  } catch (_) {}
  return '';
}

/// 점으로 끊어 숫자로 견준다. '0.1.10' 이 '0.1.9' 보다 새것이다.
/// 자리가 모자라면 0 으로 친다.
bool isNewer(String candidate, String current) {
  int part(List<String> xs, int i) =>
      i < xs.length ? (int.tryParse(xs[i]) ?? 0) : 0;
  final a = candidate.split('.');
  final b = current.split('.');
  for (var i = 0; i < (a.length > b.length ? a.length : b.length); i++) {
    final x = part(a, i);
    final y = part(b, i);
    if (x != y) return x > y;
  }
  return false;
}

/// 가장 최근 릴리스를 보고 지금 버전과 견준다.
Future<UpdateStatus> fetchStatus() async {
  final current = await currentVersion();
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
  try {
    final req = await client.getUrl(Uri.parse(_latestApiUrl));
    req.headers.set('Accept', 'application/vnd.github+json');
    final res = await req.close().timeout(const Duration(seconds: 15));
    if (res.statusCode != 200) return const UpdateCheckFailed();

    final body = await res.transform(utf8.decoder).join();
    final json = jsonDecode(body) as Map<String, dynamic>;
    final tag = json['tag_name'] as String?;
    if (tag == null) return const UpdateCheckFailed();
    final latest = tag.startsWith('v') ? tag.substring(1) : tag;

    if (!isNewer(latest, current)) return UpToDate(current);

    // 릴리스에 붙은 것 중 .apk 하나를 고른다
    final assets = (json['assets'] as List?) ?? const [];
    Map<String, dynamic>? apk;
    for (final a in assets) {
      final m = a as Map<String, dynamic>;
      if ((m['name'] as String?)?.endsWith('.apk') ?? false) {
        apk = m;
        break;
      }
    }
    return UpdateAvailable(
      latest: latest,
      current: current,
      apkUrl: apk?['browser_download_url'] as String?,
      bytes: (apk?['size'] as int?) ?? 0,
    );
  } catch (e) {
    logger.w('업데이트 확인 실패: $e');
    return const UpdateCheckFailed();
  } finally {
    client.close(force: true);
  }
}

/// 받는 동안의 진행 상황
class DownloadProgress {
  const DownloadProgress(this.received, this.total);

  final int received;
  final int total;

  /// 0~1. 전체 크기를 모르면 null (게이지 대신 받은 양만 보여 준다)
  double? get fraction => total > 0 ? received / total : null;
}

/// 새 APK 를 앱 전용 캐시에 받는다. [onProgress] 로 진행 상황을 계속 알린다.
///
/// 받아둔 파일은 캐시에 두므로 시스템이 필요할 때 알아서 지운다.
/// 설치가 끝나면 남겨 둘 이유가 없어 [installApk] 뒤에 지우지 않아도 된다.
Future<File> downloadApk(
  String url, {
  required void Function(DownloadProgress) onProgress,
  CancelToken? cancel,
}) async {
  final dir = Directory('${(await getTemporaryDirectory()).path}/update');
  if (!dir.existsSync()) dir.createSync(recursive: true);

  // 받다 만 파일이 남아 있을 수 있으므로 임시 이름으로 받고 끝나면 옮긴다
  final dest = File('${dir.path}/22SUTO-A.apk');
  final partial = File('${dest.path}.part');
  if (partial.existsSync()) partial.deleteSync();

  final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
  try {
    final req = await client.getUrl(Uri.parse(url));
    final res = await req.close();
    if (res.statusCode != 200) {
      throw HttpException('받기 실패 (${res.statusCode})');
    }

    final total = res.contentLength;
    var received = 0;
    final sink = partial.openWrite();
    try {
      await for (final chunk in res) {
        if (cancel?.isCancelled ?? false) {
          throw const _Cancelled();
        }
        sink.add(chunk);
        received += chunk.length;
        onProgress(DownloadProgress(received, total));
      }
    } finally {
      await sink.close();
    }

    if (dest.existsSync()) dest.deleteSync();
    partial.renameSync(dest.path);
    return dest;
  } catch (e) {
    if (partial.existsSync()) partial.deleteSync();
    rethrow;
  } finally {
    client.close(force: true);
  }
}

/// 받는 중에 그만두게 하는 표
class CancelToken {
  bool _cancelled = false;
  bool get isCancelled => _cancelled;
  void cancel() => _cancelled = true;
}

class _Cancelled implements Exception {
  const _Cancelled();
  @override
  String toString() => '받기를 그만뒀다';
}

/// 받아둔 APK 를 시스템 설치 화면에 넘긴다.
Future<void> installApk(File apk) =>
    _updateChannel.invokeMethod('install', {'path': apk.path});

/// 릴리스 페이지를 브라우저로 연다 (APK 가 없거나 설치가 막혔을 때)
Future<void> openReleasesPage() =>
    _updateChannel.invokeMethod('openUrl', {'url': releasesPageUrl});

Future<void> openLicensesPage() =>
    _updateChannel.invokeMethod('openUrl', {'url': licensesPageUrl});
