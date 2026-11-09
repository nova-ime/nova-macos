#!/bin/bash
# 构建 Release 版，产物在 build-release/。需要 lib/ 和 bin/ 里已有 librime，见 INSTALL.md。
#
# 构建后用 Developer ID 证书重新签名，并开启 Hardened Runtime。
# 证书用 NOVA_SIGN_IDENTITY 指定；不指定时取钥匙串里第一张 "Developer ID Application" 证书。
# 一张都没有就退回 ad-hoc 签名：能用，但系统把 Nova 当作来历不明的程序。
set -euo pipefail
cd "$(dirname "$0")/.."
xcodebuild -project Squirrel.xcodeproj -scheme Squirrel -configuration Release \
  -derivedDataPath build-release CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO build

APP=build-release/Build/Products/Release/Squirrel.app
FW="$APP/Contents/Frameworks"

# GPT-2 标橙插件（nova-lm/build.sh 编出来的）连同它依赖的 Homebrew ggml、libomp 一起放进 app。
# 这些库原本按 /opt/homebrew 的绝对路径互相引用，改成 @rpath，并给插件和 CPU 后端补上指向
# Frameworks 的 rpath。改过的文件先 ad-hoc 签名，有证书时下面再统一重签。
PLUG=lib/rime-plugins/librime-nova-lm.dylib
if [ -f "$PLUG" ]; then
  BREW="$(brew --prefix)"
  mkdir -p "$FW/rime-plugins/nova-lm"
  cp "$PLUG" "$FW/rime-plugins/"
  cp lib/rime-plugins/nova-lm/*.so "$FW/rime-plugins/nova-lm/"
  cp "$BREW/opt/ggml/lib/libggml.0.dylib" "$BREW/opt/ggml/lib/libggml-base.0.dylib" \
     "$BREW/opt/libomp/lib/libomp.dylib" "$FW/"
  chmod u+w "$FW"/libggml*.dylib "$FW/libomp.dylib" "$FW/rime-plugins/librime-nova-lm.dylib" \
    "$FW"/rime-plugins/nova-lm/*.so
  for lib in libggml.0 libggml-base.0 libomp; do
    install_name_tool -id "@rpath/$lib.dylib" "$FW/$lib.dylib" 2>/dev/null
  done
  for f in "$FW"/libggml*.dylib "$FW/rime-plugins/librime-nova-lm.dylib" "$FW"/rime-plugins/nova-lm/*.so; do
    install_name_tool \
      -change "$BREW/opt/ggml/lib/libggml.0.dylib" @rpath/libggml.0.dylib \
      -change "$BREW/opt/ggml/lib/libggml-base.0.dylib" @rpath/libggml-base.0.dylib \
      -change "$BREW/opt/libomp/lib/libomp.dylib" @rpath/libomp.dylib "$f" 2>/dev/null
  done
  install_name_tool -add_rpath @loader_path/.. "$FW/rime-plugins/librime-nova-lm.dylib" 2>/dev/null
  for f in "$FW"/rime-plugins/nova-lm/*.so; do
    install_name_tool -add_rpath @loader_path/../.. "$f" 2>/dev/null
  done
  install_name_tool -add_rpath @loader_path "$FW/libggml.0.dylib" 2>/dev/null
  for f in "$FW"/libggml*.dylib "$FW/libomp.dylib" "$FW/rime-plugins/librime-nova-lm.dylib" \
           "$FW"/rime-plugins/nova-lm/*.so; do
    codesign --force --sign - "$f"
  done
  codesign --force --sign - --entitlements resources/Squirrel.entitlements "$APP"
  # 打包后不应再引用 /opt/homebrew。
  if otool -L "$FW"/libggml*.dylib "$FW/libomp.dylib" "$FW/rime-plugins/librime-nova-lm.dylib" \
       "$FW"/rime-plugins/nova-lm/*.so | grep -q /opt/homebrew; then
    echo "打包后的 GPT-2 插件仍引用 /opt/homebrew"; exit 1
  fi
  echo "已放入 GPT-2 插件和 ggml。"
fi
IDENTITY="${NOVA_SIGN_IDENTITY:-$(security find-identity -v -p codesigning \
  | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)}"
if [ -z "$IDENTITY" ]; then
  echo "没有 Developer ID 证书，保留 ad-hoc 签名。"
  exit 0
fi

# 由内到外签：先签插件和附带的命令行工具，最后签整个 app。
for f in "$APP"/Contents/Frameworks/rime-plugins/*.dylib \
         "$APP"/Contents/Frameworks/rime-plugins/nova-lm/*.so \
         "$APP"/Contents/Frameworks/*.dylib \
         "$APP"/Contents/MacOS/rime-install \
         "$APP"/Contents/MacOS/rime_dict_manager \
         "$APP"/Contents/MacOS/rime_deployer; do
  [ -f "$f" ] && codesign --force --timestamp --options runtime --sign "$IDENTITY" "$f"
done
codesign --force --timestamp --options runtime \
  --entitlements resources/Squirrel.entitlements --sign "$IDENTITY" "$APP"
codesign --verify --deep --strict "$APP"
echo "已用 $IDENTITY 签名。"
