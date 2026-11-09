#!/bin/bash
# Builds librime-nova-lm.dylib (arm64) into lib/rime-plugins/, next to the other Rime plugins.
# Needs Homebrew ggml and boost (header-only parts), and lib/librime.1.dylib.
set -euo pipefail
cd "$(dirname "$0")"
ROOT=..
BREW=$(brew --prefix)
clang++ -O3 -std=c++17 -arch arm64 -dynamiclib -fPIC \
  -I include -I "$ROOT/librime/src" -I "$ROOT/librime/include" -I "$BREW/include" \
  nova_lm.cc -o "$ROOT/lib/rime-plugins/librime-nova-lm.dylib" \
  -install_name @rpath/librime-nova-lm.dylib \
  "$ROOT/lib/librime.1.dylib" -L "$BREW/lib" -lggml -lggml-base -framework Accelerate
echo "built $ROOT/lib/rime-plugins/librime-nova-lm.dylib"
# ggml picks its CPU backend at run time; the plugin looks for it in rime-plugins/nova-lm/.
mkdir -p "$ROOT/lib/rime-plugins/nova-lm"
cp "$BREW/opt/ggml/libexec/"libggml-cpu-apple_m*.so "$ROOT/lib/rime-plugins/nova-lm/"
echo "copied ggml CPU backends to $ROOT/lib/rime-plugins/nova-lm/"
