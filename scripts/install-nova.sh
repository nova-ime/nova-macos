#!/bin/bash
# 把 Nova Squirrel 装到 ~/Library/Input Methods，与官方鼠须管并存。不需要 sudo，不碰官方版。
# 用户目录是 ~/Library/NovaSquirrel。第一次安装时从 ~/Library/Rime 复制方案和词库，
# 不复制用户词库和编译结果。
# 卸载：scripts/install-nova.sh --uninstall（用户目录保留）
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TARGET="$HOME/Library/Input Methods/NovaSquirrel.app"
USERDIR="$HOME/Library/NovaSquirrel"
BIN="$TARGET/Contents/MacOS/Squirrel"

if [ "${1:-}" = "--uninstall" ]; then
  if [ -x "$BIN" ]; then
    "$BIN" --quit || true
    "$BIN" --disable-input-source || true
  fi
  rm -rf "$TARGET"
  echo "已卸载。用户目录保留在 $USERDIR"
  exit 0
fi

NEW="$ROOT/build-release/Build/Products/Release/Squirrel.app"
[ -d "$NEW" ] || { echo "没有构建产物，先运行 scripts/build-nova.sh: $NEW"; exit 1; }

if [ ! -d "$USERDIR" ] && [ -d "$HOME/Library/Rime" ]; then
  rsync -a --exclude build --exclude sync --exclude '*.userdb' --exclude '*.userdb.txt' \
    --exclude installation.yaml --exclude user.yaml --exclude '.bak*' --exclude '*.bak*' \
    "$HOME/Library/Rime/" "$USERDIR/"
fi
mkdir -p "$USERDIR/lua"
cp "$ROOT/nova-schema/nova.schema.yaml" "$USERDIR/"
cp "$ROOT"/nova-schema/lua/*.lua "$USERDIR/lua/"

mkdir -p "$(dirname "$TARGET")"
if [ -x "$BIN" ]; then "$BIN" --quit || true; fi
sleep 1
rm -rf "$TARGET"
ditto "$NEW" "$TARGET"
"$BIN" --register-input-source
"$BIN" --enable-input-source
open "$TARGET"
sleep 2
"$BIN" --reload
echo "已安装。在输入法列表里选 Nova 鼠须管，用 F4 切到 Nova 方案，打 nihkuijx。"
