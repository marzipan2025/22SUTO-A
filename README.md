# 22SUTO-A

Supertonic 3 기반 안드로이드 온디바이스 TTS 앱. 22SUTO(macOS)의 안드로이드 버전.
구글드라이브·구글문서 등 어느 앱에서든 **공유 → 22SUTO-A**로 글을 보내면 읽어준다.

## 개발 환경 준비 (최초 1회)

1. [Flutter SDK](https://docs.flutter.dev/get-started/install/macos) 와 Android Studio 설치
2. 모델 다운로드 (~400MB): `bash scripts/download_assets.sh`
3. 안드로이드 플랫폼 파일 생성: `flutter create --platforms=android --org com.artbrain --project-name suto_a .`
4. AndroidManifest.xml에 공유 수신 intent-filter 추가 (아래 참고)
5. 앱 아이콘 생성: `dart run flutter_launcher_icons`

## 실행 / 빌드

```bash
flutter pub get
flutter run          # USB로 연결한 폰에서 실행
flutter build appbundle   # 플레이스토어 업로드용 .aab
```

## 공유 수신 intent-filter

`android/app/src/main/AndroidManifest.xml`의 MainActivity `<activity>` 안에 추가:

```xml
<intent-filter>
  <action android:name="android.intent.action.SEND" />
  <category android:name="android.intent.category.DEFAULT" />
  <data android:mimeType="text/plain" />
</intent-filter>
```

## 구조

- `lib/helper.dart` — Supertonic 공식 Flutter 예제의 추론 파이프라인 (ONNX Runtime)
- `lib/main.dart` — UI(한국어) + 공유 수신 + 재생
- `lib/narration_engine.dart` — 선행 합성 파이프라인
- `lib/theme.dart` — 색·글꼴·픽셀 카드
- `lib/pixel.dart` — 격자 아이콘, 계단 모서리, 목록 끝 덮개
- `scripts/download_assets.sh` — Hugging Face에서 모델 받기
- 모델 파일은 용량 문제로 git에 포함하지 않음

## 글꼴

- 본문: JTBC (무게 한 벌)
- 숫자·영문 표시: [Panchang](https://www.fontshare.com/fonts/panchang)

## 릴리스 빌드 주의

`android/app/proguard-rules.pro` 를 지우지 말 것. R8 이 `ai.onnxruntime`
클래스 이름을 줄이면 네이티브 JNI 조회가 실패해 첫 문장을 합성하는
순간 앱이 통째로 죽는다. 디버그 빌드에서는 드러나지 않는다.

## 라이선스

- 코드: MIT · 모델: [OpenRAIL-M](https://huggingface.co/Supertone/supertonic-3/blob/main/LICENSE)
