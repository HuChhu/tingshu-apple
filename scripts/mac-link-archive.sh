#!/usr/bin/env bash
# Mac 窗口一键 link+archive+unsigned IPA（devops-ci 2026-11-22）
# 用法: 在 macOS（Xcode 15+ / JDK17）上 ./scripts/mac-link-archive.sh
# 或: 自托管 runner 打标 [self-hosted, macos] 后 workflow_dispatch（archive-ipa.yml）
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

echo "== [1/3] K/N framework（macOS host 无禁令）=="
cd "$ROOT/shared"
./gradlew linkReleaseFrameworkIosArm64 --no-daemon
FW=$(find build/bin -name "shared.framework" -type d | head -1)
[ -n "$FW" ] || { echo "framework 未产出"; exit 1; }
mkdir -p build/bin/ios/ReleaseFramework
rm -rf build/bin/ios/ReleaseFramework/shared.framework
cp -R "$FW" build/bin/ios/ReleaseFramework/shared.framework   # pbxproj 引用的组合目标路径
file build/bin/ios/ReleaseFramework/shared.framework/shared

echo "== [2/3] xcodebuild archive（无签名）=="
cd "$ROOT"
xcodebuild -project ios/Tingshu.xcodeproj -scheme Tingshu \
  -configuration Release -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  -archivePath build/Tingshu.xcarchive archive \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO

echo "== [3/3] Payload 打包 → unsigned IPA（全能签上游产物）=="
APP=$(find build/Tingshu.xcarchive/Products/Applications -maxdepth 1 -name "*.app" | head -1)
rm -rf build/Payload && mkdir -p build/Payload
cp -R "$APP" build/Payload/
(cd build && rm -f Tingshu-unsigned.ipa && zip -qry Tingshu-unsigned.ipa Payload && ls -la Tingshu-unsigned.ipa)
echo "完成: $(cd "$ROOT/build" && pwd)/Tingshu-unsigned.ipa"
echo "下一步: 传到 iPhone → 全能签(ESign) 注入企业证书重签 → 见 scripts/esign-ipa-guide.md"
