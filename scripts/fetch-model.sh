#!/bin/bash
# 把 GPT-2 模型和字表（约 116 MB，不进 git）下载到 nova-lm/model/，已经有就不下载。
# 来源是 nova-ime/nova-model 的最新 Release，按 SHA256SUMS 校验。
# NOVA_LM_DIR 换下载目录，NOVA_MODEL_URL 换下载地址。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LM="${NOVA_LM_DIR:-$ROOT/nova-lm/model}"
MODEL_URL="${NOVA_MODEL_URL:-https://github.com/nova-ime/nova-model/releases/latest/download}"
if [ -f "$LM/gpt2.gguf" ] && [ -f "$LM/charmap.tsv" ]; then
  exit 0
fi
echo "下载 GPT-2 模型（约 116 MB）：$MODEL_URL"
DL=$(mktemp -d)
trap 'rm -rf "$DL"' EXIT
(cd "$DL" && for f in SHA256SUMS gpt2.gguf charmap.tsv; do curl -fL --retry 3 -o "$f" "$MODEL_URL/$f"; done &&
  shasum -a 256 -c SHA256SUMS)
mkdir -p "$LM"
mv "$DL/gpt2.gguf" "$DL/charmap.tsv" "$LM/"
# 用 sudo 跑时文件别留成 root 的
if [ -n "${SUDO_USER:-}" ]; then chown -R "$SUDO_USER" "$LM"; fi
