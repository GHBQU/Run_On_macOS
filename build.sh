#!/bin/bash
# 一键构建 运行.app
# 用法: bash build.sh
set -e
cd "$(dirname "$0")"

APP="运行.app"

echo "==> 组装应用包目录"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "==> 编译 Swift 源码"
swiftc -O main.swift -o "$APP/Contents/MacOS/Run"

echo "==> 拷贝资源"
cp Info.plist "$APP/Contents/Info.plist"
cp Run.html "$APP/Contents/Resources/Run.html"
cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

echo "==> 本地重签名 (ad-hoc)"
codesign --force --deep --sign - "$APP"

echo "==> 构建完成: $(pwd)/$APP"
echo "    启动: open \"$(pwd)/$APP\""
