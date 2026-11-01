#!/bin/bash
# 构建 ScreenDoodle 并打包为 .app
set -e

cd "$(dirname "$0")/.."

APP_NAME="ScreenDoodle"
BUILD_DIR=".build/release"
APP_BUNDLE="$APP_NAME.app"

echo "==> 编译 Release 版本…"
swift build -c release

echo "==> 打包 .app…"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

# 可执行文件
cp "$BUILD_DIR/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

# 应用图标（若已生成）
if [ -f "Resources/AppIcon.icns" ]; then
    cp "Resources/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
fi

# Info.plist（LSUIElement 隐藏 Dock 图标）
cat > "$APP_BUNDLE/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>
    <string>屏幕涂鸦</string>
    <key>CFBundleIdentifier</key>
    <string>com.screendoodle.app</string>
    <key>CFBundleVersion</key>
    <string>1.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>CFBundleDevelopmentRegion</key>
    <string>zh_CN</string>
    <key>CFBundleLocalizations</key>
    <array>
        <string>zh_CN</string>
    </array>
    <key>NSHumanReadableCopyright</key>
    <string>Copyright © 2026</string>
    <key>ITSAppUsesNonExemptEncryption</key>
    <false/>
</dict>
</plist>
EOF

echo "==> 完成：$APP_BUNDLE"
echo "==> 运行时可用：open $APP_BUNDLE"

echo "==> 签名（自动匹配 Apple Distribution / Apple Development 证书）…"
# 签名身份：优先环境变量覆盖；否则自动匹配 Apple Distribution，回退 Apple Development
SIGNING_IDENTITY="${SIGNING_IDENTITY:-}"
if [ -z "$SIGNING_IDENTITY" ]; then
    SIGNING_IDENTITY=$(security find-identity -v -p codesigning \
        | awk -F'"' '/Apple Distribution/{print $2; exit}')
fi
if [ -z "$SIGNING_IDENTITY" ]; then
    SIGNING_IDENTITY=$(security find-identity -v -p codesigning \
        | awk -F'"' '/Apple Development/{print $2; exit}')
fi
if [ -z "$SIGNING_IDENTITY" ]; then
    echo "错误：未找到签名证书（Apple Distribution 或 Apple Development）" >&2
    exit 1
fi

# 启用沙盒（ENABLE_SANDBOX=1）且存在 entitlements 文件时，附带签名
ENTITLEMENTS_ARGS=()
if [ "${ENABLE_SANDBOX:-0}" = "1" ] && [ -f "ScreenDoodle.entitlements" ]; then
    ENTITLEMENTS_ARGS=(--entitlements "ScreenDoodle.entitlements")
fi
codesign --force --deep --sign "$SIGNING_IDENTITY" "${ENTITLEMENTS_ARGS[@]}" "$APP_BUNDLE"