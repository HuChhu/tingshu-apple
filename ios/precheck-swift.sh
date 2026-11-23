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
for a, b, name in [('{','}','braces'), ('(',')','parens'), ('[',']','brackets')]:
    if s.count(a) != s.count(b):
        print(f"FAIL: {p}  {name} {s.count(a)}/{s.count(b)} 不配对")
        sys.exit(1)
PY

  # 3. 禁用语法（Swift 5.0 模式）
  if grep -q 'nonisolated(unsafe)' "$f" 2>/dev/null; then
    echo "FAIL: $f  用了 nonisolated(unsafe)，Swift 5.0 不支持"
    FAIL=1
  fi
done

if [ $FAIL -eq 0 ]; then
  echo "PASS: Swift 静态预检全绿"
else
  exit 1
fi
