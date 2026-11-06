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
IDENTITY="${NOVA_SIGN_IDENTITY:-$(security find-identity -v -p codesigning \
  | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)}"
if [ -z "$IDENTITY" ]; then
  echo "没有 Developer ID 证书，保留 ad-hoc 签名。"
  exit 0
fi

# 由内到外签：先签插件和附带的命令行工具，最后签整个 app。
for f in "$APP"/Contents/Frameworks/rime-plugins/*.dylib \
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
