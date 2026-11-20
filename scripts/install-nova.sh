#!/bin/bash
# 把 Nova Squirrel 装到 /Library/Input Methods，与官方鼠须管并存，不碰官方版。需要 sudo。
#
# 为什么不装在 ~/Library/Input Methods：装在那里时，通知中心、锁屏这类系统界面不接受 Nova，
# 一拿到键盘焦点就把输入法换成 ABC，还回焦点后也不换回来。微信输入法装在 /Library 就没有这个问题，
# 把 Nova 移过去之后也好了。
#
# 用户目录是 ~/Library/NovaSquirrel。第一次安装时从 ~/Library/Rime 复制方案和词库，
# 不复制用户词库和编译结果。
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

if [ ! -d "$USERDIR" ] && [ -d "$HOME/Library/Rime" ]; then
  rsync -a --exclude build --exclude sync --exclude '*.userdb' --exclude '*.userdb.txt' \
    --exclude installation.yaml --exclude user.yaml --exclude '.bak*' --exclude '*.bak*' \
    "$HOME/Library/Rime/" "$USERDIR/"
fi
mkdir -p "$USERDIR/lua"
cp "$ROOT/nova-schema/nova.schema.yaml" "$ROOT/nova-schema/nova_lexicon.txt" "$ROOT/nova-schema/nova_quanpin.txt" "$ROOT/nova-schema/nova_rare.txt" "$USERDIR/"
cp "$ROOT"/nova-schema/lua/*.lua "$USERDIR/lua/"
# 全拼的简拼要查简拼表，旧的词库里没有。少了它别的功能照常，只是简拼不出字。
if [ ! -f "$USERDIR/nova_wx_jp.dict.yaml" ]; then
  echo "没找到简拼表（$USERDIR/nova_wx_jp.dict.yaml）：全拼的简拼不出字。运行 scripts/wanxiang/setup-wanxiang.sh 重新生成词库。"
fi
# GPT-2 标橙插件的模型和字表（约 111 MB，不进 git）。默认在 nova-lm/model/，可用 NOVA_LM_DIR 指定。
LM="${NOVA_LM_DIR:-$ROOT/nova-lm/model}"
# 本地没有时从 nova-model 的最新 Release 下载，按 SHA256SUMS 校验；下载失败或校验不过就当没有模型。
MODEL_URL="${NOVA_MODEL_URL:-https://github.com/nova-ime/nova-model/releases/latest/download}"
if [ ! -f "$LM/gpt2.gguf" ] || [ ! -f "$LM/charmap.tsv" ]; then
  echo "下载 GPT-2 模型（约 111 MB）：$MODEL_URL"
  DL=$(mktemp -d)
  if (cd "$DL" && for f in SHA256SUMS gpt2.gguf charmap.tsv; do curl -fL --retry 3 -o "$f" "$MODEL_URL/$f" || exit 1; done &&
      shasum -a 256 -c SHA256SUMS); then
    mkdir -p "$LM"
    mv "$DL/gpt2.gguf" "$DL/charmap.tsv" "$LM/"
    # 用 sudo 跑时文件别留成 root 的
    [ -n "${SUDO_USER:-}" ] && chown -R "$SUDO_USER" "$LM"
  else
    echo "模型下载或校验失败。"
  fi
  rm -rf "$DL"
fi
if [ -f "$LM/gpt2.gguf" ] && [ -f "$LM/charmap.tsv" ]; then
  mkdir -p "$USERDIR/nova_lm"
  cp "$LM/gpt2.gguf" "$LM/charmap.tsv" "$USERDIR/nova_lm/"
else
  echo "没找到 GPT-2 模型（$LM/gpt2.gguf、charmap.tsv）：照常安装，但不按 GPT-2 标橙。"
fi

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
echo "已安装到 ${TARGET}。在输入法列表里选 Nova 鼠须管，用 F4 切到 Nova 方案，打 nihkuijx。"
if [ "$MOVED" = 1 ]; then
  echo "这次是从 ~/Library/Input Methods 搬过来的：切换列表里可能暂时没有 Nova，注销再登录一次即可。"
fi
