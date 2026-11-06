#!/bin/bash
# 下载万象词库和万象语法模型，转换成 Nova 的格式后放进 ~/Library/NovaSquirrel。
#
# - 词库：rime-wanxiang 的 zrm-fuzhu 版（自然码辅助码），用 wx2nova.py 转成 nova_wx.dict.yaml
# - 模型：rime-wanxiang-data 的 wanxiang-lts-zh-hans.gram（约 420MB）
# 来源：https://github.com/amzxyz/rime-wanxiang 、https://github.com/amzxyz/rime-wanxiang-data（CC-BY-4.0）
#
# 下载的文件缓存在 .scratch/wanxiang，已经存在就不再下载。要更新，删掉缓存再跑一次。
# 跑完后执行 Squirrel --reload 重新部署（第一次编译词库要几秒）。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
USERDIR="$HOME/Library/NovaSquirrel"
CACHE="${NOVA_WANXIANG_CACHE:-$ROOT/.scratch/wanxiang}"
DICT_TAG="v18.1.8"
ZIP="rime-wanxiang-zrm-fuzhu.zip"
GRAM="wanxiang-lts-zh-hans.gram"
TABLES="zi.pro jichu.pro cuoyin.pro duoyin.pro diming.pro mingren.pro yiren.pro"

mkdir -p "$CACHE"
if [ ! -f "$CACHE/$ZIP" ]; then
  gh release download "$DICT_TAG" -R amzxyz/rime-wanxiang -p "$ZIP" -D "$CACHE"
fi
if [ ! -f "$CACHE/$GRAM" ]; then
  gh release download LTS -R amzxyz/rime-wanxiang-data -p "$GRAM" -D "$CACHE"
fi

rm -rf "$CACHE/zrm"
unzip -q "$CACHE/$ZIP" -d "$CACHE/zrm"
# shellcheck disable=SC2086
python3 -I "$ROOT/scripts/wanxiang/wx2nova.py" "$CACHE/zrm/dicts" "$CACHE/nova_wx.dict.yaml" nova_wx $TABLES

cp "$CACHE/nova_wx.dict.yaml" "$USERDIR/"
cp "$CACHE/$GRAM" "$USERDIR/"
echo "已放进 ${USERDIR}：nova_wx.dict.yaml、${GRAM}"
