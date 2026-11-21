#!/bin/bash
# C1 机械检查线（契约 v1）：壳内 Swift 白名单自检，CI 同口径。用法：sh check-whitelist.sh
set -u
ROOT="$(cd "$(dirname "$0")" && pwd)"
SRC="$ROOT/ios-shell"
ACT="$SRC/Engine/Actual"
fail=0

# 1) 禁词：引擎网络栈/解析器字样在 Swift 内零出现（大小写不敏感，含注释）
hits=$(grep -RniE 'ktor|ksoup' --include='*.swift' "$SRC" || true)
if [ -n "$hits" ]; then echo "FAIL: Swift 内出现引擎栈禁词"; echo "$hits"; fail=1; fi

# 2) import 白名单；shared 仅允许出现在 SharedBridge.swift（结果模型唯一入口）
for f in $(find "$SRC" -name '*.swift' -not -path '*/.*'); do
  for imp in $(grep -E '^import[[:space:]]+[A-Za-z_][A-Za-z0-9_.]*' "$f" | sed 's/import[[:space:]]*//' | sort -u); do
    case "$imp" in
      Foundation|SwiftUI|Combine|AVFoundation|WebKit|os) ;;
      shared) [ "$(basename "$f")" = "SharedBridge.swift" ] || { echo "FAIL: $f 非法 import shared（仅 SharedBridge.swift 允许）"; fail=1; } ;;
      *) echo "FAIL: $f 白名单外 import: $imp"; fail=1 ;;
    esac
  done
done

# 3) 五触点不变量：Actual 恰好 5 个 Swift 文件
n=$(find "$ACT" -maxdepth 1 -name '*.swift' 2>/dev/null | wc -l | tr -d ' ')
[ "$n" = "5" ] || { echo "FAIL: Actual 文件数=$n，不变量要求 5"; fail=1; }

# 4) 三件套 + 后台模式落点检查
grep -q '\.playback' "$ACT/BackgroundSession.swift" || { echo "FAIL: BackgroundSession 缺 .playback category"; fail=1; }
grep -q 'setActive' "$ACT/BackgroundSession.swift" || { echo "FAIL: BackgroundSession 缺 setActive"; fail=1; }
grep -q 'UIBackgroundModes' "$SRC/Info.plist" || { echo "FAIL: Info.plist 缺 UIBackgroundModes"; fail=1; }
grep -q '<string>audio</string>' "$SRC/Info.plist" || { echo "FAIL: UIBackgroundModes 缺 audio"; fail=1; }

if [ "$fail" = "0" ]; then echo "PASS: 白名单自检全绿（禁词0 / import合规 / Actual=5 / 三件套+后台模式在位）"; else exit 1; fi
