# 22SUTO-A

Supertonic 3 기반 안드로이드 온디바이스 TTS 앱. 22SUTO(macOS)의 안드로이드 버전.
구글드라이브·구글문서 등 어느 앱에서든 **공유 → 22SUTO-A**로 글을 보내면 읽어준다.

## 개발 환경 준비 (최초 1회)

1. [Flutter SDK](https://docs.flutter.dev/get-started/install/macos) 와 Android Studio 설치
2. (선택) 모델 미리 받기: `bash scripts/download_assets.sh`
   — 앱은 첫 실행 때 폰에서 직접 받는다. 이 스크립트는 맥에서 모델을
   들여다볼 일이 있을 때만 쓴다. 빌드에는 필요 없다.
3. 안드로이드 플랫폼 파일 생성: `flutter create --platforms=android --org com.artbrain --project-name suto_a .`
4. AndroidManifest.xml에 공유 수신 intent-filter 추가 (아래 참고)
5. 앱 아이콘 생성: `python3 scripts/make_icons.py`

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
- `lib/model_store.dart` — 음성 모델을 앱과 따로 두고 받아 두기
- `scripts/download_assets.sh` — (맥에서 들여다볼 때만) Hugging Face에서 모델 받기
- `scripts/make_icons.py` — 밑그림 한 장에서 앱 아이콘 전부 뽑기 (아래 참고)
- `scripts/make_chars.py` — 받은 캐릭터 그림을 앱에 넣을 꼴로 다듬기 (아래 참고)
- 모델 파일은 용량 문제로 git에 포함하지 않음

## 음성 모델은 앱과 따로 산다

Supertonic 3 (383MB) 은 APK 안에 넣지 않는다. 넣었을 때는 글자 하나만
고쳐도 480MB 를 다시 받아야 했다. 갈라 둔 지금 앱 갱신은 104MB 다.

- 첫 실행 때 안내가 뜨고, 받으면 앱 지원 폴더의 `model/` 에 들어간다.
- 다 받았을 때만 `model/manifest.json` 을 남긴다. 도중에 죽으면 지문이
  없으므로 '받다 만 것' 으로 알고 다시 청한다.
- 큰 파일은 `.part` 로 받다가 끊기면 그 자리에서 이어받는다 (HTTP Range).
- 새 모델이 나왔는지는 **설정에서 CHECK 를 눌렀을 때만** 묻는다. 그 한
  번의 확인이 앱과 모델 양쪽을 함께 본다.
- 견줄 때는 저장소 커밋(sha)이 아니라 **우리가 쓰는 16개 파일의 blob
  이름**을 본다. 읽어 보기 한 줄이 고쳐졌다고 알림이 뜨면 안 된다.

## 아이콘

밑그림은 저장소 맨 위의 `AppIcon_22SUTO-A.png` (3072px) 한 장뿐이다.
그림을 고쳤으면 그 파일만 갈아 끼우고 `python3 scripts/make_icons.py` 를 돌린다.
런처 아이콘 다섯 장, 시작 화면 그림, `assets/icon/app_icon.png` 이 한 번에 나온다.

**`dart run flutter_launcher_icons` 를 쓰지 말 것.** 부드럽게 보간해 줄이는 탓에
픽셀 그림의 가장자리가 뭉개져 뿌옇게 나온다. 스크립트는 '가장 가까운 점'만
골라 픽셀 경계를 살린다. 밑그림이 3072px 인 것도 48·96·192 로 딱
나누어떨어지게 하려는 것이다.

시작 화면 바탕색(`res/values/colors.xml` 의 `splash_bg`)은 밑그림 바탕과
같은 색이어야 한다. 지금은 `#6B8C8E` 다. 밑그림 바탕을 바꾸면 여기도 바꾼다.

## 캐릭터

목소리 열 가지마다 얼굴 하나씩, `assets/char/new_{m,f}_0N.png` 다.
받는 그림은 3072px 정사각형 캔버스에 캐릭터가 떠 있는 꼴이라, 그대로 넣으면
투명한 자리까지 폭으로 쳐서 캐릭터가 작아진다. 스크립트로 다듬어 넣는다:

```bash
python3 scripts/make_chars.py ~/Downloads/'SUTO-A asset'
```

투명한 가장자리를 잘라내고 '가장 가까운 점'으로 1/8 로 줄인다. 1/8 은 지금
있는 그림들이 쓰던 배율이라 캐릭터끼리의 크기 비율이 그대로 이어진다.
앱은 폭(`main.dart` 의 `_faceWidth`)만 맞춰 세우고 높이는 그림이 정한다 —
캐릭터마다 세로/가로 비가 다른 것은 일부러 그런 것이다.

## 글꼴

- 본문: 에이투지체 SemiBold (무게 한 벌)
- 숫자·영문 표시: [Panchang](https://www.fontshare.com/fonts/panchang)

## 릴리스 빌드 주의

`android/app/proguard-rules.pro` 를 지우지 말 것. R8 이 `ai.onnxruntime`
클래스 이름을 줄이면 네이티브 JNI 조회가 실패해 첫 문장을 합성하는
순간 앱이 통째로 죽는다. 디버그 빌드에서는 드러나지 않는다.

## 라이선스

- 코드: MIT · 모델: [OpenRAIL-M](https://huggingface.co/Supertone/supertonic-3/blob/main/LICENSE)
