#!/usr/bin/env bash
#
# シミュレータ向けにビルドして、コンパイルが通るかを確認する。
#   ./scripts/build.sh
#
# 署名は不要（シミュレータ向けのため CODE_SIGNING_ALLOWED=NO）。
# 実機で動かすときは Xcode で開いて Signing & Capabilities からチームを選ぶ。
set -euo pipefail

cd "$(dirname "$0")/.."

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "xcodegen が見つかりません。次のコマンドで入れてください:" >&2
  echo "  brew install xcodegen" >&2
  exit 1
fi

echo "==> プロジェクトを生成"
xcodegen generate

echo "==> ビルド"
xcodebuild \
  -project RecallMonitor.xcodeproj \
  -scheme RecallMonitor \
  -configuration Debug \
  -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath build/DerivedData \
  CODE_SIGNING_ALLOWED=NO \
  build

echo
echo "ビルドに成功しました。"
echo "シミュレータで動かすには Xcode で開いてください:"
echo "  open RecallMonitor.xcodeproj"
