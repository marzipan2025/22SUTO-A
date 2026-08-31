# 22SUTO-A

Supertonic 3 을 폰에서 돌리는 온디바이스 TTS. Flutter · Android 전용.

## 폰에 설치할 때

```bash
flutter build apk --release
adb install -r build/app/outputs/flutter-apk/app-release.apk
```

**`flutter install` 을 쓰지 않는다.** 서명이 같아도 기존 앱을 먼저 **지우고**
새로 깐다("Uninstalling old version..."). 그러면 만들어둔 음성(수 GB), 글 목록,
읽던 자리, 받아둔 모델 383MB 가 전부 사라진다. 2026-08-31 에 이것으로 1.9GB 를
잃었다. `adb install -r` 은 데이터를 지키고, 서명이 다르면 조용히 지우는 대신
`INSTALL_FAILED_UPDATE_INCOMPATIBLE` 로 그냥 실패한다.

지웠는지는 `firstInstallTime` 으로 확인한다 — 바뀌었으면 데이터가 날아간 것이다.

```bash
adb shell dumpsys package com.artbrain.suto_a | grep -E "versionName|firstInstallTime"
```

## 릴리스

버전은 `pubspec.yaml` 의 `version:` 한 곳이다. main 에 바로 커밋하고 태그한다.

```bash
# pubspec.yaml 의 version 을 올린다 (0.5.3+45 처럼 뒤 숫자도 함께)
git commit && git tag vX.Y.Z && git push origin main && git push origin vX.Y.Z
flutter build apk --release
cp build/app/outputs/flutter-apk/app-release.apk /tmp/22SUTO-A-vX.Y.Z.apk
gh release create vX.Y.Z --title "..." --notes "..." /tmp/22SUTO-A-vX.Y.Z.apk
```

APK 이름은 `22SUTO-A-vX.Y.Z.apk` 여야 한다 — 앱 안의 UPDATE 가 릴리스에 붙은
`.apk` 하나를 골라 받는다. dmg/apk 는 저장소에 커밋하지 않는다.

## 모델은 앱과 따로 산다 (v0.5.0~)

383MB 짜리 Supertonic 3 은 APK 에 없다. 첫 실행 때 Hugging Face 에서 받아
앱 지원 폴더의 `model/` 에 둔다. 그래서 `assets/onnx` 는 빌드에 쓰이지 않는다 —
로컬에 남아 있어도 그만이고, 필요하면 `scripts/download_assets.sh` 로 받는다.

`OnnxRuntime.createSessionFromAsset` 을 쓰지 않는다. 그것은 인자를 **애셋 이름**
으로 알아듣고 rootBundle 에 물으러 간다. 모델이 파일로 사는 지금은
`createSession(경로)` 라야 한다. v0.5.0/v0.5.1 이 이것 때문에 새로 깐 기기에서
엔진이 서지 않았다.

## APK 는 arm64 한 벌만 넣는다

`android/app/build.gradle.kts` 의 `packaging.jniLibs.excludes` 가 한다.
104MB → 36.5MB.

- `defaultConfig` 의 `ndk.abiFilters` 로는 **안 된다.** 우리가 빌드한 것만
  걸러지고 ONNX Runtime 처럼 AAR 로 딸려 오는 `.so` 는 세 벌이 그대로 남는다.
- `flutter build --target-platform android-arm64` 는 **절반만** 듣는다.
  플러터 제 것만 걸러내고 AAR 쪽은 손대지 않아 72MB 에서 멈춘다.

gradle 이 하므로 빌드 명령에 플래그를 붙일 필요가 없다.

## 릴리스 빌드에서 로그 보기

`logger` 는 경고(`w`)와 오류(`e`)만 릴리스에서도 logcat 에 남긴다. `i`·`d` 는
디버그 빌드 전용이다.

```bash
adb logcat -d | grep "flutter :"
```
