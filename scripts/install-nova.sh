#!/bin/bash
# 把 Nova Squirrel 装到 /Library/Input Methods，与官方鼠须管并存，不碰官方版。需要 sudo。
#
# 为什么不装在 ~/Library/Input Methods：装在那里时，通知中心、锁屏这类系统界面不接受 Nova，
# 一拿到键盘焦点就把输入法换成 ABC，还回焦点后也不换回来。微信输入法装在 /Library 就没有这个问题，
# 把 Nova 移过去之后也好了。
#
# 用户目录是 ~/Library/NovaSquirrel，安装不往里写东西。
# 卸载：scripts/install-nova.sh --uninstall（用户目录保留）
#
# sudo 要在真正的终端里输密码；在 Claude Code 里用 `!` 运行会因为读不到密码而失败。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TARGET="/Library/Input Methods/NovaSquirrel.app"
OLD_TARGET="$HOME/Library/Input Methods/NovaSquirrel.app"
USERDIR="$HOME/Library/NovaSquirrel"
BIN="$TARGET/Contents/MacOS/Squirrel"

quit_running() {
  for b in "$BIN" "$OLD_TARGET/Contents/MacOS/Squirrel"; do
    if [ -x "$b" ]; then "$b" --quit || true; fi
  done
}

if [ "${1:-}" = "--uninstall" ]; then
  if [ -x "$BIN" ]; then "$BIN" --disable-input-source || true; fi
  quit_running
  sudo rm -rf "$TARGET"
  rm -rf "$OLD_TARGET"
  echo "已卸载。用户目录保留在 $USERDIR"
  exit 0
fi

NEW="$ROOT/build-release/Build/Products/Release/Squirrel.app"
[ -d "$NEW" ] || { echo "没有构建产物，先运行 scripts/build-nova.sh: $NEW"; exit 1; }

# 先拿到 sudo，免得删掉旧版之后才发现没有权限。
sudo -v

# 方案、词库、Lua、GPT-2 模型都在 app 的 SharedSupport 里（scripts/build-nova.sh 放进去），
# 用户目录只放用户自己的东西，不往里复制。用户目录里有同名文件时它优先，会盖住 app 带的新版本。
for f in nova.schema.yaml default.yaml nova_lexicon.txt nova_quanpin.txt nova_rare.txt lua nova_lm/gpt2.gguf; do
  if [ -e "$USERDIR/$f" ]; then echo "注意：用户目录里有 $f，它会盖住 app 自带的版本。"; fi
done

quit_running
sleep 1
sudo rm -rf "$TARGET"
sudo ditto "$NEW" "$TARGET"
codesign --verify --deep --strict "$TARGET"
# 旧版装在 ~/Library/Input Methods。新版装好、校验通过之后才删，免得两个同 ID 的 Nova 并存。
MOVED=0
if [ -d "$OLD_TARGET" ]; then MOVED=1; rm -rf "$OLD_TARGET"; fi

"$BIN" --register-input-source
"$BIN" --enable-input-source
open "$TARGET"
sleep 2
"$BIN" --reload
echo "已安装到 ${TARGET}。在输入法列表里选 Nova，第一次会弹出设置面板选输入方式。"
if [ "$MOVED" = 1 ]; then
  echo "这次是从 ~/Library/Input Methods 搬过来的：切换列表里可能暂时没有 Nova，注销再登录一次即可。"
fi
