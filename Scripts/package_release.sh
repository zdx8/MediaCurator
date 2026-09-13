#!/bin/bash
# 打出可分发的发布包，命名规则：<app名字>-v<版本>-<机型>.zip
#
#   ./Scripts/package_release.sh                 # 本机架构（Apple Silicon → arm64）
#   UNIVERSAL=1 ./Scripts/package_release.sh     # 通用二进制 → universal
#   SKIP_VERIFY=1 ./Scripts/package_release.sh   # 跳过解包验收（只出包，快）
#
# 为什么用 ditto 而不是 zip：ditto 会保留 bundle 的扩展属性与资源分叉，
# 解包后代码签名依然有效；用普通 zip 打包再解包，签名会被破坏，
# 用户双击时可能被 Gatekeeper 拦下。
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
DIST="$ROOT/dist"
APP_NAME="MediaCurator"
DISPLAY_NAME="影像管家"
VERSION="1.0.1"

# ---------- 1. 组装 .app ----------
"$ROOT/Scripts/build_app.sh"

APP_DIR="$DIST/$APP_NAME.app"
BIN="$APP_DIR/Contents/MacOS/$APP_NAME"

# ---------- 2. 判定机型标签 ----------
# 命名规则里的「机型」指这个包能跑在哪种机器上：Intel 机器跑不了 arm64，
# 所以架构必须写进文件名，否则用户下载下来才发现打不开。
ARCHS="$(lipo -archs "$BIN" 2>/dev/null || echo unknown)"
case "$ARCHS" in
  arm64)  MACHINE_TAG="arm64" ;;
  x86_64) MACHINE_TAG="x86_64" ;;
  *arm64*x86_64*|*x86_64*arm64*) MACHINE_TAG="universal" ;;
  *)      MACHINE_TAG="$(echo "$ARCHS" | tr ' ' '-')" ;;
esac
# 本机机型（写进包名旁边的说明，便于确认「对应机型」是否如预期）
HOST_MODEL="$(sysctl -n hw.model 2>/dev/null || echo unknown)"

ARCHIVE_NAME="${DISPLAY_NAME}-v${VERSION}-${MACHINE_TAG}.zip"
ARCHIVE="$DIST/$ARCHIVE_NAME"

# ---------- 3. 出包 ----------
echo ""
echo "▸ 打包…"
rm -f "$ARCHIVE"
ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$ARCHIVE"
echo "  $ARCHIVE_NAME  ($(du -h "$ARCHIVE" | cut -f1))"

# ---------- 4. 解包验收 ----------
# 必须验「解压出来的东西」，而不是打包前的那份 .app：
# 打包参数写错（例如漏掉 --sequesterRsrc）只会在解包后才暴露。
if [ "${SKIP_VERIFY:-0}" != "1" ]; then
  echo ""
  echo "▸ 解包验收…"
  WORK="$(mktemp -d /tmp/mediacurator-release.XXXXXX)"
  trap 'rm -rf "$WORK"' EXIT

  ditto -x -k "$ARCHIVE" "$WORK"
  EXTRACTED="$WORK/$APP_NAME.app"
  [ -d "$EXTRACTED" ] || { echo "  ✗ 解包后找不到 $APP_NAME.app"; exit 1; }
  echo "  ✓ 解包得到 $APP_NAME.app"

  [ -x "$EXTRACTED/Contents/MacOS/$APP_NAME" ] || { echo "  ✗ 可执行文件缺失或没有执行权限"; exit 1; }
  echo "  ✓ 可执行文件存在且可执行"

  PLIST_BUDDY=/usr/libexec/PlistBuddy
  EXTRACTED_NAME="$($PLIST_BUDDY -c 'Print :CFBundleName' "$EXTRACTED/Contents/Info.plist" 2>/dev/null || echo '')"
  EXTRACTED_VER="$($PLIST_BUDDY -c 'Print :CFBundleShortVersionString' "$EXTRACTED/Contents/Info.plist" 2>/dev/null || echo '')"
  [ "$EXTRACTED_VER" = "$VERSION" ] || { echo "  ✗ 版本号不符：$EXTRACTED_VER"; exit 1; }
  # 中文紧跟变量名时必须写 ${VAR}：多字节字符会被 bash 并进变量名，
  # 报成 `unbound variable` 且变量名里带乱码，很难一眼看出。
  echo "  ✓ 版本 ${EXTRACTED_VER}，显示名 ${EXTRACTED_NAME}"

  if codesign --verify --deep --strict "$EXTRACTED" 2>/dev/null; then
    echo "  ✓ 解包后签名依然有效"
  else
    echo "  ✗ 解包后签名损坏（打包参数有问题）"
    exit 1
  fi

  # 链接完整性：AVKit 缺失会让视频预览直接闪退，而编译期不报错
  LINKED="$(otool -L "$EXTRACTED/Contents/MacOS/$APP_NAME")"
  for framework in AVKit AVFoundation; do
    echo "$LINKED" | grep -q "/$framework.framework/" || { echo "  ✗ 缺少 $framework.framework"; exit 1; }
  done
  echo "  ✓ AVKit / AVFoundation 已链接"

  echo "  ▸ 对解包产物跑两项自检…"
  "$EXTRACTED/Contents/MacOS/$APP_NAME" --headless selftest 2>&1 | tail -2
  "$EXTRACTED/Contents/MacOS/$APP_NAME" --headless uicheck 2>&1 | tail -2
fi

echo ""
echo "✓ 发布包就绪：$ARCHIVE"
echo "  命名：<app名字>-v<版本>-<机型>"
echo "  app名字 = $DISPLAY_NAME   版本 = v$VERSION   机型 = $MACHINE_TAG (本机 $HOST_MODEL / $ARCHS)"
echo "  解包后的 app 仍是 $APP_NAME.app（bundle 名未改，改的是发布包文件名）"
echo ""
# GitHub 创建 Release 附件时会剥掉文件名里的非 ASCII 字符（改名接口同样如此），
# 中文名会变成 "-v1.0.0-arm64.zip" 这种残缺样子 —— 所以上传前必须换成 ASCII 名。
echo "  上传到 GitHub Release 时改用 ASCII 附件名（GitHub 会剥掉中文）："
echo "    $APP_NAME-v$VERSION-$MACHINE_TAG.zip"
