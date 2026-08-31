/// Supertonic 3 모델을 앱과 따로 두고, 필요할 때 받아 둔다.
///
/// 예전에는 모델 400MB 를 APK 안에 넣어 함께 배포했다. 그래서 글자 하나만
/// 고쳐도 480MB 를 다시 받아야 했다. 모델은 앱보다 훨씬 뜸하게 바뀌므로,
/// 갈라 두면 앱 갱신은 100MB 아래로 내려간다.
///
/// 받아 둔 것이 있으면 그대로 쓴다 — 만들어둔 음성을 다루는 규칙과 같다.
/// 없거나 깨졌을 때만 다시 받고, 모델 자체가 새로 나왔는지는 사람이
/// 설정에서 확인을 눌렀을 때만 묻는다.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:suto_a/helper.dart' show logger;
import 'package:suto_a/update_check.dart' show CancelToken, DownloadProgress;

/// 모델이 사는 곳 — Hugging Face 의 Supertone/supertonic-3
const modelRepo = 'Supertone/supertonic-3';
const modelPageUrl = 'https://huggingface.co/$modelRepo';
const _apiUrl = 'https://huggingface.co/api/models/$modelRepo?blobs=true';
const _fileBase = 'https://huggingface.co/$modelRepo/resolve/main';

/// 앱이 실제로 쓰는 파일들.
///
/// 저장소에는 견본 소리와 그림도 들어 있지만 앱은 쓰지 않는다. 받지도 않고,
/// 새로 나왔는지 견줄 때도 보지 않는다 — 읽어 보기 파일 하나가 고쳐졌다고
/// "새 모델이 있어요" 라고 하면 안 되기 때문이다.
const modelFiles = <String>[
  'onnx/tts.json',
  'onnx/unicode_indexer.json',
  'onnx/duration_predictor.onnx',
  'onnx/text_encoder.onnx',
  'onnx/vector_estimator.onnx',
  'onnx/vocoder.onnx',
  'voice_styles/M1.json',
  'voice_styles/M2.json',
  'voice_styles/M3.json',
  'voice_styles/M4.json',
  'voice_styles/M5.json',
  'voice_styles/F1.json',
  'voice_styles/F2.json',
  'voice_styles/F3.json',
  'voice_styles/F4.json',
  'voice_styles/F5.json',
];

/// 모델 한 벌의 지문 — 파일마다 git blob 이름과 크기.
///
/// 저장소 전체의 커밋 이름(sha)을 쓰지 않는 이유는, 읽어 보기 한 줄만
/// 고쳐도 그 이름이 바뀌기 때문이다. 우리가 쓰는 파일들의 지문만 본다.
class ModelManifest {
  const ModelManifest(this.files, this.revision);

  /// 파일 이름 → (blob 이름, 바이트)
  final Map<String, ({String blob, int size})> files;

  /// 저장소의 커밋 이름. 사람에게 보여 줄 때만 쓴다.
  final String revision;

  int get totalBytes =>
      files.values.fold<int>(0, (sum, f) => sum + f.size);

  /// 두 벌이 같은 모델인가 — 우리가 쓰는 파일들의 blob 이름이 모두 같으면.
  bool sameAs(ModelManifest other) {
    if (files.length != other.files.length) return false;
    for (final e in files.entries) {
      if (other.files[e.key]?.blob != e.value.blob) return false;
    }
    return true;
  }

  Map<String, Object?> toJson() => {
        'revision': revision,
        'files': {
          for (final e in files.entries)
            e.key: {'blob': e.value.blob, 'size': e.value.size},
        },
      };

  static ModelManifest? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final files = raw['files'];
    if (files is! Map) return null;
    final out = <String, ({String blob, int size})>{};
    for (final e in files.entries) {
      final v = e.value;
      if (v is! Map) return null;
      final blob = v['blob']?.toString();
      final size = (v['size'] as num?)?.toInt();
      if (blob == null || size == null) return null;
      out['${e.key}'] = (blob: blob, size: size);
    }
    return ModelManifest(out, raw['revision']?.toString() ?? '');
  }
}

/// 모델을 둔 폴더. 캐시가 아니라 지원 폴더에 둔다 — 400MB 를 시스템이
/// 마음대로 지워 버리면 다음에 켤 때 다시 받아야 한다.
Future<Directory> modelDir() async {
  final base = await getApplicationSupportDirectory();
  final dir = Directory('${base.path}/model');
  if (!dir.existsSync()) dir.createSync(recursive: true);
  return dir;
}

/// 모델 파일을 넘겨줄 때 쓰는 두 폴더 — helper 가 이 경로로 읽는다.
Future<String> onnxDirPath() async => '${(await modelDir()).path}/onnx';
Future<String> voiceStylesDirPath() async =>
    '${(await modelDir()).path}/voice_styles';

Future<File> _manifestFile() async =>
    File('${(await modelDir()).path}/manifest.json');

/// 받아 둔 모델의 지문. 아직 없으면 null.
Future<ModelManifest?> localManifest() async {
  try {
    final f = await _manifestFile();
    if (!f.existsSync()) return null;
    return ModelManifest.fromJson(jsonDecode(await f.readAsString()));
  } catch (e) {
    logger.w('모델 지문을 읽지 못함: $e');
    return null;
  }
}

/// 받아 둔 모델이 온전한가 — 지문이 있고, 파일이 다 있고, 크기가 맞으면.
///
/// 받다가 앱이 죽으면 반쪽짜리 파일이 남는다. 크기까지 봐야 그것을 걸러낸다.
Future<bool> modelInstalled() async {
  final m = await localManifest();
  if (m == null) return false;
  final dir = await modelDir();
  for (final name in modelFiles) {
    final want = m.files[name];
    if (want == null) return false;
    final f = File('${dir.path}/$name');
    if (!f.existsSync()) return false;
    try {
      if (f.lengthSync() != want.size) return false;
    } catch (_) {
      return false;
    }
  }
  return true;
}

/// 받아 둔 모델이 차지한 자리
Future<int> modelBytes() async {
  final dir = await modelDir();
  if (!dir.existsSync()) return 0;
  var sum = 0;
  for (final f in dir.listSync(recursive: true)) {
    if (f is File) {
      try {
        sum += f.lengthSync();
      } catch (_) {}
    }
  }
  return sum;
}

// --------------------------------------------------------------- 새것 확인

sealed class ModelStatus {
  const ModelStatus();
}

/// 아직 받은 적이 없다 (또는 받다 말았다)
class ModelMissing extends ModelStatus {
  const ModelMissing(this.remote);
  final ModelManifest remote;
  int get bytes => remote.totalBytes;
}

/// 받아 둔 것이 최신이다
class ModelUpToDate extends ModelStatus {
  const ModelUpToDate();
}

/// 새 모델이 나왔다
class ModelOutdated extends ModelStatus {
  const ModelOutdated(this.remote);
  final ModelManifest remote;
  int get bytes => remote.totalBytes;
}

/// Hugging Face 에 닿지 못했다
class ModelCheckFailed extends ModelStatus {
  const ModelCheckFailed();
}

/// 저장소에 지금 올라와 있는 지문을 묻는다.
Future<ModelManifest?> fetchRemoteManifest() async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
  try {
    final req = await client.getUrl(Uri.parse(_apiUrl));
    final res = await req.close().timeout(const Duration(seconds: 20));
    if (res.statusCode != 200) {
      logger.w('모델 정보 확인 실패 (${res.statusCode})');
      return null;
    }
    final json = jsonDecode(await res.transform(utf8.decoder).join());
    if (json is! Map) return null;

    final want = modelFiles.toSet();
    final files = <String, ({String blob, int size})>{};
    for (final s in (json['siblings'] as List?) ?? const []) {
      if (s is! Map) continue;
      final name = s['rfilename']?.toString();
      if (name == null || !want.contains(name)) continue;

      // 큰 파일은 LFS 로 올라가 있을 수 있다. 그때는 지문이 lfs 쪽에 있다.
      final lfs = s['lfs'];
      final blob = (lfs is Map ? lfs['oid']?.toString() : null) ??
          s['blobId']?.toString();
      final size = (lfs is Map ? (lfs['size'] as num?)?.toInt() : null) ??
          (s['size'] as num?)?.toInt();
      if (blob == null || size == null) continue;
      files[name] = (blob: blob, size: size);
    }

    // 하나라도 빠졌으면 견줄 수 없다 — 저장소 구조가 바뀐 것이다.
    if (files.length != modelFiles.length) {
      logger.w('모델 파일 목록이 달라졌다 (${files.length}/${modelFiles.length})');
      return null;
    }
    return ModelManifest(files, json['sha']?.toString() ?? '');
  } catch (e) {
    logger.w('모델 확인 실패: $e');
    return null;
  } finally {
    client.close(force: true);
  }
}

/// 지금 받아 둔 것과 저장소를 견준다.
Future<ModelStatus> fetchModelStatus() async {
  final remote = await fetchRemoteManifest();
  if (remote == null) return const ModelCheckFailed();

  if (!await modelInstalled()) return ModelMissing(remote);

  final local = await localManifest();
  if (local == null) return ModelMissing(remote);
  return local.sameAs(remote) ? const ModelUpToDate() : ModelOutdated(remote);
}

// ------------------------------------------------------------------- 받기

/// 모델을 받아 [modelDir] 에 채운다.
///
/// 이미 있고 지문이 맞는 파일은 건너뛴다. 받다 만 파일은 `.part` 로 남겨
/// 두었다가 다음에 이어받는다 — 가장 큰 것이 245MB 라, 끊길 때마다 처음부터
/// 다시 받게 하면 쓸 수 없다.
///
/// 다 받기 전에는 지문을 쓰지 않는다. 그래야 도중에 죽어도 '받아 둔 모델'
/// 로 오해하지 않는다.
Future<void> downloadModel(
  ModelManifest remote, {
  required void Function(DownloadProgress) onProgress,
  CancelToken? cancel,
}) async {
  final dir = await modelDir();
  final total = remote.totalBytes;

  // 건너뛸 파일들의 몫도 진행률에 넣어야 눈금이 뒤로 가지 않는다
  var done = 0;
  final keep = <String>{};
  for (final name in modelFiles) {
    final want = remote.files[name]!;
    final f = File('${dir.path}/$name');
    if (f.existsSync()) {
      try {
        if (f.lengthSync() == want.size) {
          keep.add(name);
          done += want.size;
        }
      } catch (_) {}
    }
  }
  onProgress(DownloadProgress(done, total));

  final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
  try {
    for (final name in modelFiles) {
      if (cancel?.isCancelled ?? false) throw const ModelDownloadCancelled();
      if (keep.contains(name)) continue;

      final want = remote.files[name]!;
      final dest = File('${dir.path}/$name');
      dest.parent.createSync(recursive: true);
      final partial = File('${dest.path}.part');

      // 이어받기 — 남아 있는 조각이 온전한 앞부분이라고 보고 그 뒤부터 청한다
      var from = 0;
      if (partial.existsSync()) {
        try {
          from = partial.lengthSync();
        } catch (_) {
          from = 0;
        }
        if (from >= want.size) {
          // 조각이 더 크다면 다른 판의 찌꺼기다. 버리고 처음부터.
          partial.deleteSync();
          from = 0;
        }
      }

      final req = await client.getUrl(Uri.parse('$_fileBase/$name'));
      if (from > 0) req.headers.set(HttpHeaders.rangeHeader, 'bytes=$from-');
      final res = await req.close();

      // 206 이면 이어받기가 받아들여진 것이고, 200 이면 처음부터 다시 온다
      if (res.statusCode == 200) {
        from = 0;
      } else if (res.statusCode != 206) {
        throw HttpException('$name download failed (${res.statusCode})');
      }

      var received = from;
      final sink = partial.openWrite(
          mode: from > 0 ? FileMode.append : FileMode.write);
      try {
        await for (final chunk in res) {
          if (cancel?.isCancelled ?? false) {
            throw const ModelDownloadCancelled();
          }
          sink.add(chunk);
          received += chunk.length;
          onProgress(DownloadProgress(done + received, total));
        }
      } finally {
        await sink.close();
      }

      if (partial.lengthSync() != want.size) {
        partial.deleteSync();
        throw HttpException('$name has the wrong size');
      }
      if (dest.existsSync()) dest.deleteSync();
      partial.renameSync(dest.path);
      done += want.size;
      onProgress(DownloadProgress(done, total));
    }

    // 여기까지 왔으면 한 벌이 온전히 갖춰졌다. 이제야 지문을 남긴다.
    await (await _manifestFile()).writeAsString(jsonEncode(remote.toJson()));
    logger.i('모델을 받았다 — ${remote.revision}');
  } finally {
    client.close(force: true);
  }
}

/// 받는 도중에 그만뒀다
class ModelDownloadCancelled implements Exception {
  const ModelDownloadCancelled();
  @override
  String toString() => 'Model download cancelled';
}
