#!/bin/bash
# 组装可双击运行的 MediaCurator.app
#
#   ./Scripts/build_app.sh              # 本机架构
#   UNIVERSAL=1 ./Scripts/build_app.sh  # 通用二进制（arm64 + x86_64）
#
# 说明：SwiftPM 只产出裸可执行文件，bundle 需要手工组装。
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
APP_NAME="MediaCurator"
DISPLAY_NAME="影像管家"
BUNDLE_ID="com.workbuddy.mediacurator"
DIST="$ROOT/dist"
APP_DIR="$DIST/$APP_NAME.app"
VERSION="1.0.4"
# 图标缓存以「bundle 标识 + CFBundleVersion + 路径」为键，
# 版本号写死会导致换了图标系统仍显示旧的，所以每次打包都让它变。
BUILD_NUMBER="$(date +%y%m%d.%H%M)"

echo "▸ 构建 release…"
if [ "${UNIVERSAL:-0}" = "1" ]; then
  BUILD_ARGS=(-c release --arch arm64 --arch x86_64 --disable-sandbox)
else
  BUILD_ARGS=(-c release --disable-sandbox)
fi

swift build "${BUILD_ARGS[@]}"
# 带 --arch 时产物路径会变，必须用同一组参数取路径
BIN_PATH="$(swift build "${BUILD_ARGS[@]}" --show-bin-path)"
echo "  可执行文件：$BIN_PATH/$APP_NAME"

echo "▸ 生成图标…"
ICONSET="$ROOT/.build/AppIcon.iconset"
ICNS="$ROOT/.build/AppIcon.icns"
# 脚本比产物新时重新生成 —— 否则改了图标脚本却看不到变化，
# 会白白怀疑到系统图标缓存头上。
if [ ! -f "$ICNS" ] || [ "$ROOT/Scripts/make_icon.swift" -nt "$ICNS" ]; then
  swiftc -O -o "$ROOT/.build/make-icon" "$ROOT/Scripts/make_icon.swift"
  "$ROOT/.build/make-icon" "$ICONSET"
  iconutil -c icns "$ICONSET" -o "$ICNS"
fi
echo "  $ICNS"

echo "▸ 组装 app bundle…"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
# 一律覆盖写入，不用 rm -rf：某些环境的安全护栏会拦截批量删除
cp -f "$BIN_PATH/$APP_NAME" "$APP_DIR/Contents/MacOS/$APP_NAME"
chmod +x "$APP_DIR/Contents/MacOS/$APP_NAME"
cp -f "$ICNS" "$APP_DIR/Contents/Resources/AppIcon.icns"

cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleName</key><string>$DISPLAY_NAME</string>
  <key>CFBundleDisplayName</key><string>$DISPLAY_NAME</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.photography</string>
  <key>NSHumanReadableCopyright</key><string>本地运行，不上传任何文件</string>
</dict>
</plist>
PLIST

echo "▸ 签名（ad-hoc）…"
codesign --force --deep --sign - "$APP_DIR" 2>/dev/null || echo "  签名跳过（不影响本机运行）"

if [ "${SKIP_ICON_CACHE_REFRESH:-0}" != "1" ]; then
  echo "▸ 刷新图标缓存…"
  touch "$APP_DIR" "$APP_DIR/Contents/Resources/AppIcon.icns"
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP_DIR" >/dev/null 2>&1 || true
  killall Dock >/dev/null 2>&1 || true
  killall Finder >/dev/null 2>&1 || true
  killall iconservicesagent >/dev/null 2>&1 || true
fi

# 链接完整性检查。
#
# SwiftUI 的 `VideoPlayer` 声明在私有框架 `_AVKit_SwiftUI` 里，编译器只会自动链接
# 那个私有框架，**不会**顺带链接 AVKit 本身；而 `VideoPlayer` 内部是 `AVPlayerView`
# （属 AVKit）的子类 —— 一旦 AVKit 没被链进来，运行时找不到父类，
# 点视频缩略图时直接 trap 闪退。链接期的问题不会报任何编译错误，
# 只能靠检查产物本身，所以在这里卡一道。
echo "▸ 校验链接完整性…"
LINKED=$(otool -L "$APP_DIR/Contents/MacOS/$APP_NAME" 2>/dev/null)
for framework in AVKit AVFoundation; do
  if echo "$LINKED" | grep -q "/$framework.framework/"; then
    echo "  ✓ $framework 已链接"
  else
    echo "  ✗ 缺少 $framework.framework —— 视频预览会闪退"
    exit 1
  fi
done

echo ""
echo "✓ 完成：$APP_DIR"
echo "  架构：$(lipo -archs "$APP_DIR/Contents/MacOS/$APP_NAME" 2>/dev/null || echo unknown)"
echo "  版本：$VERSION ($BUILD_NUMBER)"
echo ""
echo "  运行：open \"$APP_DIR\""
