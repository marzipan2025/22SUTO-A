import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:suto_a/model_store.dart';

ModelManifest _m(Map<String, String> blobs, {String rev = 'r1'}) =>
    ModelManifest(
      {
        for (final e in blobs.entries) e.key: (blob: e.value, size: 100),
      },
      rev,
    );

void main() {
  test('같은 지문이면 새것이 아니다', () {
    final a = _m({'onnx/tts.json': 'aaa', 'onnx/vocoder.onnx': 'bbb'});
    final b = _m({'onnx/tts.json': 'aaa', 'onnx/vocoder.onnx': 'bbb'});
    expect(a.sameAs(b), isTrue);
  });

  test('저장소 커밋만 달라진 것으로는 새것이라 하지 않는다', () {
    // 읽어 보기 파일 한 줄이 고쳐지면 sha 는 바뀌지만 모델은 그대로다.
    // 우리가 쓰는 파일의 지문이 같으면 새것이 아니다.
    final a = _m({'onnx/tts.json': 'aaa'}, rev: 'old');
    final b = _m({'onnx/tts.json': 'aaa'}, rev: 'new');
    expect(a.sameAs(b), isTrue);
  });

  test('쓰는 파일 하나라도 바뀌면 새것이다', () {
    final a = _m({'onnx/tts.json': 'aaa', 'onnx/vocoder.onnx': 'bbb'});
    final b = _m({'onnx/tts.json': 'aaa', 'onnx/vocoder.onnx': 'CCC'});
    expect(a.sameAs(b), isFalse);
  });

  test('파일 수가 다르면 새것이다', () {
    final a = _m({'onnx/tts.json': 'aaa'});
    final b = _m({'onnx/tts.json': 'aaa', 'onnx/vocoder.onnx': 'bbb'});
    expect(a.sameAs(b), isFalse);
  });

  test('지문을 적었다 다시 읽어도 같은 것이다', () {
    final a = _m({'onnx/tts.json': 'aaa', 'voice_styles/M1.json': 'bbb'});
    final back = ModelManifest.fromJson(jsonDecode(jsonEncode(a.toJson())));
    expect(back, isNotNull);
    expect(back!.sameAs(a), isTrue);
    expect(back.revision, a.revision);
    expect(back.totalBytes, a.totalBytes);
  });

  test('깨진 지문은 읽지 않는다 — 없는 것으로 친다', () {
    expect(ModelManifest.fromJson(null), isNull);
    expect(ModelManifest.fromJson('그냥 글자'), isNull);
    expect(ModelManifest.fromJson({'revision': 'r'}), isNull);
    expect(
      ModelManifest.fromJson({
        'files': {
          'onnx/tts.json': {'blob': 'aaa'} // 크기가 없다
        }
      }),
      isNull,
    );
  });

  test('받아야 할 크기는 파일 크기를 모두 더한 것이다', () {
    final m = ModelManifest({
      'a': (blob: 'x', size: 300),
      'b': (blob: 'y', size: 700),
    }, 'r');
    expect(m.totalBytes, 1000);
  });

  test('앱이 쓰는 파일 목록에 견본 소리나 그림은 없다', () {
    // 저장소에는 audio_samples/ 와 img/ 도 있다. 그것까지 받으면 쓸데없이
    // 무겁고, 그것이 고쳐졌다고 새 모델이라 하면 안 된다.
    expect(modelFiles.every((f) => f.startsWith('onnx/') || f.startsWith('voice_styles/')),
        isTrue);
    expect(modelFiles.length, 16);
  });
}
