#!/bin/bash
# 生成官网截图。
#
#   ./Scripts/make_site_shots.sh
#   APP=/path/to/MediaCurator ./Scripts/make_site_shots.sh
#
# 做两件事：
#   1. 用「演示素材」（像真实照片库的那套，见 DemoFixtureBuilder）离屏渲染各页面；
#   2. 把渲染图缩到网页用的尺寸，写进 docs/images。
#
# 为什么要单独走一套素材：自检用的素材是多频正弦图案 —— 平滑、可缩放、便于判定，
# 但放到官网首屏就是一堆抽象色块。两套素材的取舍方向相反，所以分开。
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
APP="${APP:-$ROOT/dist/MediaCurator.app/Contents/MacOS/MediaCurator}"
OUT="$ROOT/docs/images"
# 素材放在固定路径而不是 mktemp：截图里会显示文件路径，
# 随机临时目录名（/private/var/folders/…/T/tmp.XXXXXXXX）出现在官网截图上很难看。
WORK="/tmp/mediacurator-site-demo"
rm -rf "$WORK"

if [ ! -x "$APP" ]; then
  echo "找不到可执行文件：$APP"
  echo "先跑 ./Scripts/build_app.sh，或用 APP=... 指定路径"
  exit 1
fi

echo "▸ 渲染演示素材与页面…"
"$APP" --headless demoshots --dir "$WORK/fixtures" --shots "$WORK/shots"

mkdir -p "$OUT"

# 渲染图是屏幕缩放比下的原始像素（本机 2x）。缩到网页尺寸后，
# 页面按 1x CSS 像素展示时正好是 2 倍密度，在 Retina 屏上不糊。
emit() { # <源文件（不含扩展名）> <目标文件名> <宽> <高> [png|jpg]
  local src="$WORK/shots/$1.png"
  local fmt="${5:-png}"
  if [ ! -f "$src" ]; then
    echo "  ✗ 缺少渲染图：$1.png"
    return 1
  fi
  if [ "$fmt" = "jpg" ]; then
    # 内容是一整张照片、没有大片纯色，PNG 无损在这里换不到画质，
    # 体积却是 JPEG 的五六倍（实测 1.3 MB → 0.2 MB）。
    sips -z "$4" "$3" -s format jpeg -s formatOptions 82 "$src" --out "$OUT/$2" >/dev/null
  else
    sips -z "$4" "$3" "$src" --out "$OUT/$2" >/dev/null
  fi
  local size
  size="$(sips -g pixelWidth -g pixelHeight "$OUT/$2" | awk '/pixel/{printf "%s ", $2}')"
  printf '  · %-30s %s %s\n' "$2" "$size" "$(du -h "$OUT/$2" | cut -f1)"
}

emit "overview-light"        "overview-light.png"        1800 1138
emit "overview-dark"         "overview-dark.png"         1400  885
emit "scan"                  "scan.png"                  1400  925
emit "all-media-selected"    "all-media-selected.png"    1400  925
emit "duplicates"            "duplicates.png"            1400  925
emit "duplicates-keep-whole" "duplicates-keep-whole.png" 1400  925
emit "duplicates-discard-all" "duplicates-discard-all.png" 1400 925
emit "organize"              "organize.png"              1400  925
emit "plan"                  "plan.png"                  1400  925
emit "journal"               "journal.png"               1400  925
emit "preview-image"         "preview-image.jpg"         1400  925 jpg
emit "preview-video"         "preview-video.png"         1400  925

# 各图的历史遗留版本清掉，避免仓库里留着没人引用的文件
rm -f "$OUT/preview-image.png"
# 「所有媒体」页只出带勾选的那一张（见 demoshots 里的说明）
rm -f "$OUT/all-media.png"

rm -rf "$WORK"

echo "▸ 官网截图已更新：$OUT"
du -sh "$OUT"
