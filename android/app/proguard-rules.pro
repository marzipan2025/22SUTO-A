# ONNX Runtime 은 네이티브(C++) 쪽에서 JNI 로 자바 클래스를 이름으로 찾는다.
# R8 이 이름을 줄이면 FindClass 가 null 을 돌려주고, 첫 추론에서
#   "JNI DETECTED ERROR IN APPLICATION: java_class == null"
# 으로 앱이 통째로 죽는다. 릴리스 빌드에서만 나므로 더 늦게 발견된다.
# 그래서 이 묶음은 이름도 멤버도 손대지 않는다.
-keep class ai.onnxruntime.** { *; }
-keepclassmembers class ai.onnxruntime.** { *; }
-dontwarn ai.onnxruntime.**

# 네이티브에서 불러 쓰는 메서드는 어느 클래스에 있든 이름을 지킨다
-keepclasseswithmembernames class * {
    native <methods>;
}
