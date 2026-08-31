plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.artbrain.suto_a"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.artbrain.suto_a"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    // 64비트 ARM 한 벌만 넣는다.
    //
    // 기본값은 세 벌(arm64-v8a·armeabi-v7a·x86_64)을 다 담는다. 그중 102MB 가
    // .so 이고 x86_64 만 40MB 다 — 에뮬레이터용이라 어떤 폰에서도 실행되지
    // 않는 코드다. armeabi-v7a 는 64비트 이전 기기용인데, 380MB 모델을 CPU 로
    // 돌릴 만한 기기가 아니다.
    //
    // 한 벌로 줄이면 APK 가 104MB 에서 36MB 가 된다. 앱을 고칠 때마다 사람이
    // 그만큼을 다시 받는 자리라, 그 값이 그대로 사람에게 간다.
    //
    // **defaultConfig 의 ndk.abiFilters 로는 안 된다.** 그것으로는 우리가
    // 빌드하는 것만 걸러지고, ONNX Runtime 처럼 AAR 로 딸려 오는 .so 는 세 벌이
    // 그대로 남는다(35MB). 실제로 넣어 보면 x86_64/libonnxruntime.so 22MB 가
    // 그대로 있다. 꾸릴 때 걸러야 둘 다 빠진다.
    //
    // flutter build 의 --target-platform 도 절반만 듣는다 — 플러터 제 것만
    // 걸러내고 AAR 쪽은 손대지 않는다. 그래서 명령줄이 아니라 여기에 적는다.
    // 빌드할 때마다 기억해야 하는 것은 언젠가 잊힌다.
    //
    // 애플 실리콘 맥의 에뮬레이터도 arm64 라 그대로 돌아간다. 인텔 맥의 x86
    // 에뮬레이터에서 돌려야 할 일이 생기면 그때 여기를 푼다.
    packaging {
        jniLibs {
            excludes += listOf("**/x86/**", "**/x86_64/**", "**/armeabi-v7a/**")
        }
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
            // ONNX Runtime 이 JNI 로 찾는 클래스 이름을 R8 이 줄이지 않게 한다
            // (자세한 사정은 proguard-rules.pro 에)
            proguardFiles("proguard-rules.pro")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
