#!/bin/bash
# ============================================================
#  yyds.dylib 手动编译脚本 (无需 Theos, 仅需 macOS + Xcode)
#
#  使用前请确保:
#   1. 安装了 Xcode Command Line Tools
#   2. 安装了 ldid (brew install ldid 或从越狱社区获取)
#
#  编译产物: yyds.dylib (可直接注入的 ARM64 dylib)
# ============================================================
set -e

SDK=$(xcrun --sdk iphoneos --show-sdk-path)
TARGET="arm64-apple-ios14.0"

echo "======================================"
echo " yyds.dylib 编译中..."
echo " SDK: $SDK"
echo " Target: $TARGET"
echo "======================================"

# ---------- 编译 Tweak.xm (需要用 clang++, 因为用了 objc++) ----------
clang++ -arch arm64 \
    -isysroot "$SDK" \
    -miphoneos-version-min=14.0 \
    -fobjc-arc \
    -fobjc-weak \
    -O2 \
    -dynamiclib \
    -o yyds.dylib \
    -install_name /Library/MobileSubstrate/DynamicLibraries/yyds.dylib \
    Tweak.xm \
    -framework Foundation \
    -framework UIKit \
    -framework IOKit \
    -F "$SDK/System/Library/PrivateFrameworks" \
    -framework Preferences \
    -lsubstrate \
    -lobjc \
    -lc++ \
    -Wl,-dead_strip

echo ""
echo "======================================"
echo " 编译完成!"
echo " 产物: yyds.dylib"
echo ""
echo " 下一步:"
echo " 1. 签名 (可选): ldid -S yyds.dylib"
echo " 2. 注入测试: DYLD_INSERT_LIBRARIES=yyds.dylib ./YourGame"
echo "======================================"
