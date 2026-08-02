# Links libnokre_app.so — the one artifact the APK carries. The NDK
# toolchain compiles every line of C/C++ (JNI shell, Skia shim,
# qrcodegen) so the object world matches the NDK-built Skia archive,
# the same one-toolchain rule the web build follows with emcc; the Zig
# world arrives as the static library `zig build` produced (the
# zigBuild task in ../../../build.gradle).
cmake_minimum_required(VERSION 3.22)
project(nokre_app C CXX)

get_filename_component(NOKRE_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/../../../../../../.." ABSOLUTE)

if(NOT EXISTS "${NOKRE_ROOT}/deps/skia-android/${ANDROID_ABI}/libskia.a")
    message(FATAL_ERROR "deps/skia-android/${ANDROID_ABI} not found — run tools/build-skia-android.sh first")
endif()

add_library(nokre_app SHARED
    ${NOKRE_ROOT}/src/platform/android/shell.c
    # secure_store's JNI leg (bridges the nokre_ss_* verbs to
    # NokreSecureStore's Keystore store). Always compiled, like the shell's
    # deep_link hook; the Zig side names the externs only when linked.
    ${NOKRE_ROOT}/src/services/secure_store/android.c
    # oauth's JNI leg (launches the Custom Tab through NokreOAuth and
    # routes the redirect back). Same rule as the store's: always
    # compiled, named by the Zig side only when linked.
    ${NOKRE_ROOT}/src/services/oauth/android.c
    # iap's JNI leg (bridges the store verbs to NokreBilling and carries
    # purchase updates back). Always compiled like the two above — it
    # includes only jni.h, so it costs nothing here; the Play Billing
    # dependency lives entirely on the Java side, which an app that
    # links iap adds to its own build.gradle (docs/services.md).
    ${NOKRE_ROOT}/src/services/iap/android.c
    # notification's JNI leg (bridges post/schedule/cancel and the
    # permission to NokreNotifications, and carries taps and tokens
    # back). Always compiled like the three above — jni.h only, and the
    # Firebase dependency the push half needs lives entirely on the Java
    # side, which an app that links push adds to its own build.gradle
    # (docs/services.md).
    ${NOKRE_ROOT}/src/services/notification/android.c
    ${NOKRE_ROOT}/shim/nokre_skia.cpp
    ${NOKRE_ROOT}/shim/nokre_skia_nocodec_stub.cpp
    # HarfBuzz rides in the shim, never in Skia (see build.zig addHarfBuzz).
    ${NOKRE_ROOT}/deps/harfbuzz/src/harfbuzz.cc
    ${NOKRE_ROOT}/deps/qrcodegen/qrcodegen.c)

set_target_properties(nokre_app PROPERTIES C_STANDARD 11 CXX_STANDARD 17)
target_compile_options(nokre_app PRIVATE
    $<$<COMPILE_LANGUAGE:CXX>:-fno-exceptions -fno-rtti>)
target_compile_definitions(nokre_app PRIVATE NDEBUG HB_NO_MT)
target_include_directories(nokre_app PRIVATE
    ${NOKRE_ROOT}/deps/skia
    ${NOKRE_ROOT}/deps/harfbuzz/src)

target_link_libraries(nokre_app
    ${CMAKE_CURRENT_SOURCE_DIR}/../../../build/zig-${ANDROID_ABI}/lib/libkitchen-sink.a
    ${NOKRE_ROOT}/deps/skia-android/${ANDROID_ABI}/libskia.a
    android
    log
    m)
