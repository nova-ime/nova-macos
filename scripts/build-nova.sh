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
  # ggml 的库名带主版本号（libggml.0、libggml.1），以插件实际链接的为准。
  # Homebrew 升级 ggml 之后旧名字的库就不在了，这时要先重编插件。
  GGML=()
  while IFS= read -r lib; do GGML+=("$lib"); done \
    < <(otool -L "$PLUG" | awk '$1 ~ /\/libggml[^\/]*\.dylib$/ {print $1}')
  [ "${#GGML[@]}" -gt 0 ] || { echo "GPT-2 插件没有链接 ggml：$PLUG"; exit 1; }
  for lib in "${GGML[@]}"; do
    [ -f "$lib" ] || { echo "插件链接的 $lib 不在了（Homebrew 升级过 ggml？）。先运行 nova-lm/build.sh 重编插件。"; exit 1; }
  done
  mkdir -p "$FW/rime-plugins/nova-lm"
  # 上次构建留下的 ggml 可能是另一个主版本，先清掉。
  rm -f "$FW"/libggml*.dylib
  cp "$PLUG" "$FW/rime-plugins/"
  cp lib/rime-plugins/nova-lm/*.so "$FW/rime-plugins/nova-lm/"
  cp "${GGML[@]}" "$BREW/opt/libomp/lib/libomp.dylib" "$FW/"
  chmod u+w "$FW"/libggml*.dylib "$FW/libomp.dylib" "$FW/rime-plugins/librime-nova-lm.dylib" \
    "$FW"/rime-plugins/nova-lm/*.so
  CHANGES=(-change "$BREW/opt/libomp/lib/libomp.dylib" @rpath/libomp.dylib)
  install_name_tool -id @rpath/libomp.dylib "$FW/libomp.dylib" 2>/dev/null
  for lib in "${GGML[@]}"; do
    name="$(basename "$lib")"
    install_name_tool -id "@rpath/$name" "$FW/$name" 2>/dev/null
    install_name_tool -add_rpath @loader_path "$FW/$name" 2>/dev/null
    CHANGES+=(-change "$lib" "@rpath/$name")
  done
  for f in "$FW"/libggml*.dylib "$FW/rime-plugins/librime-nova-lm.dylib" "$FW"/rime-plugins/nova-lm/*.so; do
    install_name_tool "${CHANGES[@]}" "$f" 2>/dev/null
  done
  install_name_tool -add_rpath @loader_path/.. "$FW/rime-plugins/librime-nova-lm.dylib" 2>/dev/null
  for f in "$FW"/rime-plugins/nova-lm/*.so; do
    install_name_tool -add_rpath @loader_path/../.. "$f" 2>/dev/null
    # 后端是 nova-lm/build.sh 从 Homebrew 复制来的，要和插件出自同一版 ggml。
    for dep in $(otool -L "$f" | awk '$1 ~ /^@rpath\/libggml/ {print $1}'); do
      [ -f "$FW/${dep#@rpath/}" ] || { echo "$(basename "$f") 要的 ${dep#@rpath/} 不在 app 里。先运行 nova-lm/build.sh 重编插件。"; exit 1; }
    done
  done
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
