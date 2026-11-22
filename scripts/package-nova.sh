#!/bin/bash
# 把 scripts/build-nova.sh 的构建产物打成安装包 build-release/Nova-<版本>.pkg。
# 用户双击安装：装到 /Library/Input Methods/NovaSquirrel.app，注册、启用并选中 Nova（见 package/nova/scripts）。
#
# 压缩：--compression latest 加 --min-os-version 13.0，让 pkgbuild 用新的压缩算法，下载体积约为 app 的一半。
# 签名：钥匙串里有 "Developer ID Installer" 证书就签；NOVA_INSTALLER_IDENTITY 可以指定。没有就不签。
# 公证：设了 NOVA_NOTARY_PROFILE（xcrun notarytool store-credentials 存的名字）就提交公证并装订。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build-release/Build/Products/Release/Squirrel.app"
OUT="$ROOT/build-release"
PKGDIR="$ROOT/package/nova"
[ -d "$APP" ] || { echo "没有构建产物，先运行 scripts/build-nova.sh: $APP"; exit 1; }

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" "$APP/Contents/Info.plist")
STAGE="$OUT/pkgroot"
rm -rf "$STAGE" "$OUT/nova-component.pkg"
mkdir -p "$STAGE"
ditto --noqtn "$APP" "$STAGE/NovaSquirrel.app"
# 只留签名用的扩展属性（rime-install 是脚本，签名存在 com.apple.cs.*），其余删掉，免得打进安装包。
xattr -rd com.apple.provenance "$STAGE/NovaSquirrel.app" 2>/dev/null || true
xattr -rd com.apple.macl "$STAGE/NovaSquirrel.app" 2>/dev/null || true
codesign --verify --deep --strict "$STAGE/NovaSquirrel.app"
chmod 755 "$PKGDIR/scripts/preinstall" "$PKGDIR/scripts/postinstall"

pkgbuild \
  --root "$STAGE" \
  --component-plist "$PKGDIR/component.plist" \
  --identifier im.nova.inputmethod.NovaSquirrel \
  --version "$VERSION" \
  --install-location "/Library/Input Methods" \
  --scripts "$PKGDIR/scripts" \
  --compression latest --min-os-version 13.0 \
  "$OUT/nova-component.pkg"

sed "s/VERSION/$VERSION/" "$PKGDIR/distribution.xml" > "$OUT/distribution.xml"
IDENTITY="${NOVA_INSTALLER_IDENTITY:-$(security find-identity -v \
  | sed -n 's/.*"\(Developer ID Installer: [^"]*\)".*/\1/p' | head -1)}"
PKG="$OUT/Nova-$VERSION.pkg"
SIGN=()
if [ -n "$IDENTITY" ]; then SIGN=(--sign "$IDENTITY" --timestamp); else echo "没有 Developer ID Installer 证书，安装包不签名。"; fi
productbuild --distribution "$OUT/distribution.xml" --package-path "$OUT" ${SIGN[@]+"${SIGN[@]}"} "$PKG"
rm -rf "$STAGE" "$OUT/nova-component.pkg" "$OUT/distribution.xml"

if [ -n "$IDENTITY" ] && [ -n "${NOVA_NOTARY_PROFILE:-}" ]; then
  xcrun notarytool submit "$PKG" --keychain-profile "$NOVA_NOTARY_PROFILE" --wait
  xcrun stapler staple "$PKG"
fi
echo "安装包：${PKG}（$(du -h "$PKG" | cut -f1)）"
