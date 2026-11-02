#!/bin/bash
# 构建 Release 版，产物在 build-release/。需要 lib/ 和 bin/ 里已有 librime，见 INSTALL.md。
set -euo pipefail
cd "$(dirname "$0")/.."
xcodebuild -project Squirrel.xcodeproj -scheme Squirrel -configuration Release \
  -derivedDataPath build-release CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO build
