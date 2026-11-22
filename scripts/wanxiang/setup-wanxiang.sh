#!/bin/bash
# 下载万象词库，转换成 Nova 的格式，放在缓存目录里，供 scripts/build-nova.sh 打进 app。
#
# - 词库：rime-wanxiang 的 zrm-fuzhu 版（自然码辅助码），用 wx2nova.py 转成 nova_wx.dict.yaml
#   和简拼表 nova_wx_jp.dict.yaml（全拼的简拼用，主词典引入它）
# 来源：https://github.com/amzxyz/rime-wanxiang（CC-BY-4.0）
# 万象语法模型（.gram）不用：它只让整句多对约 0.6%，却要 420MB。
#
# 下载的文件缓存在 .scratch/wanxiang，已经存在就不再下载。要更新，删掉缓存再跑一次。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CACHE="${NOVA_WANXIANG_CACHE:-$ROOT/.scratch/wanxiang}"
DICT_TAG="v18.1.8"
ZIP="rime-wanxiang-zrm-fuzhu.zip"
TABLES="zi.pro jichu.pro cuoyin.pro duoyin.pro diming.pro mingren.pro yiren.pro"

mkdir -p "$CACHE"
if [ ! -f "$CACHE/$ZIP" ]; then
  gh release download "$DICT_TAG" -R amzxyz/rime-wanxiang -p "$ZIP" -D "$CACHE"
fi

rm -rf "$CACHE/zrm"
unzip -q "$CACHE/$ZIP" -d "$CACHE/zrm"
# shellcheck disable=SC2086
python3 -I "$ROOT/scripts/wanxiang/wx2nova.py" "$CACHE/zrm/dicts" "$CACHE/nova_wx.dict.yaml" nova_wx $TABLES

echo "已生成 ${CACHE}/nova_wx.dict.yaml、nova_wx_jp.dict.yaml。接着运行 scripts/build-nova.sh。"
