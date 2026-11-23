#!/bin/bash
# Swift 静态预检：在 push 前跑，抓 CI 才会暴露的低级错误。
# 用法：./ios/precheck-swift.sh
set -u
FAIL=0

for f in $(find ios -name '*.swift'); do
  # 1. #if / #endif 配对
  IF=$(grep -c '^\s*#if' "$f" 2>/dev/null || echo 0)
  END=$(grep -c '^\s*#endif' "$f" 2>/dev/null || echo 0)
  if [ "$IF" != "$END" ]; then
    echo "FAIL: $f  #if=$IF #endif=$END 不配对"
    FAIL=1
  fi

  # 2. 括号配对（粗检，字符串内的会误报但能抓大错）
  python3 - "$f" <<'PY' || FAIL=1
import sys
p = sys.argv[1]
s = open(p, encoding='utf-8', errors='ignore').read()
# {} 是结构性括号，必须严格配对
if s.count('{') != s.count('}'):
    print(f"FAIL: {p}  braces {s.count('{')}/{s.count('}')} 不配对")
    sys.exit(1)
# () [] 常出现在字符串/正则里，只报警差值 > 3 的情况
if abs(s.count('(') - s.count(')')) > 3:
    print(f"WARN: {p}  parens {s.count('(')}/{s.count(')')} 差值较大（可能是字符串内容）")
PY

  # 3. 禁用语法（Swift 5.0 模式）
  # 排除注释行（以 // 或 /// 开头）
  if grep -v '^\s*//' "$f" 2>/dev/null | grep -q 'nonisolated(unsafe)'; then
    echo "FAIL: $f  用了 nonisolated(unsafe)，Swift 5.0 不支持"
    FAIL=1
  fi
done

if [ $FAIL -eq 0 ]; then
  echo "PASS: Swift 静态预检全绿"
else
  exit 1
fi
