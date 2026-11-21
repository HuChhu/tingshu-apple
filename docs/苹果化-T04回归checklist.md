# T04 迁移回归 checklist（dev-android，2026-11-21）

> 配合 dev-core T03「data/ximalaya → shared」逐步迁移；**每收到一步完成通知就按本表执行对应行**，证据落 docs/苹果化-执行日志.md（一行一条，格式见每步「证据」）。
> 纪律锚点：AGENTS.md §19.7（逐文件搬、搬一个删一个、回退=revert 单提交）；验收表 M5 飞行模式护栏；§19.6 隔离墙。

## 0. 基线（迁移开始前跑一次，全部绿才允许第一步落盘）

| # | 命令 | 位置 | 通过标准 |
|---|---|---|---|
| B1 | `./gradlew :app:testDebugUnitTest --tests "com.local.audiobook.data.ximalaya.*"` | 主工程（本地） | 0 failed（当前 ximalaya 单测基线，步 ①② 先沿用此命令） |
| B2 | `python3 -m pytest -q` | bridge 工程（本地） | 39 passed / 0 failed（签名对拍用例已在 test_api_logic.py；若 dev-core 动签名，新用例数以此为基线只增不减） |
| B3 | `git status --porcelain` 为空 + `git log -1 --oneline` 记下起点 commit | 主工程（本地） | 工作区干净；起点 SHA 写进执行日志，回退锚点用它 |
| B4 | 手机装当前 release 包（ting-shu-1.2.0-release.apk 同版本重装）+ 开启飞行模式实测 | 真机 | STAGE6B2 **A4** 全过：书架/续播/书签/定时本地照常，仅进喜马拉雅页提示网络问题——迁移前先证明护栏本身是绿的 |

## 通用规则（六步共用，不随步变化）

- 每步四个动作：**搬 → 删 → 引用改 import → 测**；一次 git 提交 = 一步，commit message 写「迁移顺序表第 N 步」
- **禁双实现**：每步完成后 `grep -rn "<旧包名>" app/src/main/java --include=*.kt` 必须零命中（旧包名 = com.local.audiobook.data.ximalaya 中已迁类）；零命中前不许开下一步
- 单测暂时搬去 shared-core jvmTest（待 §19.7 顺序表落定成文后与 dev-core 对齐搬动批次），搬前先把同一用例在原处跑绿再搬
- 每步回归四件套（时间紧可只跑 G1+G2，**手机 A4 每周至少一次全量**）
- 回退：任何一步红了且 30 分钟内修不绿 → `git revert` 该步单提交，按 G3 复验，原因写执行日志

## 1. 分步回归矩阵

| 步 | 迁移物 | G1 单测（audiobook-app） | G2 pytest（ximalaya-bridge） | G3 编译 | G4 真机 A4 | 证据 |
|---|---|---|---|---|---|---|
| ① | XimalayaResult 错误分类 | B1 命令 | F 段全量（39 条） | `./gradlew :app:compileDebugKotlin` BUILD SUCCESSFUL | 每步跑 | G1+G2+G3 摘要行 + A4 结果一行 |
| ② | RequestThrottle | 同上 | 同上 | 同上 | 每步跑 | 同上 |
| ③ | engine/XmSignEngine | B1 + **新增对拍用例：shared-core jvmTest 同输入 → 与 pytest 签名用例输出逐字节一致** | 全量（桥端签名实现是它） | 同上 + **shared-core `./gradlew jvmTest` 14→N 全绿** | 同上 | 双端输出一致性截图/文本贴日志 |
| ④ | XimalayaSession 纯逻辑（Cookie 存储触点留 expect/actual） | B1 命令 | F1/F2/E1–E3 相关用例全量跑 | 同上 | 同上 | 同上 |
| ⑤ | CategoryCatalog + DiscoverRules | B1 命令 | B3/B4 发现页随机相关（桥侧 mock 或 pytest fixture）+ 全量 | 同上 | 同上 | 同上 |
| ⑥ | XimalayaApiClient 收口 | B1 命令 | 全量 | 同上；最后补 `./gradlew :app:assembleDebug`（不止 Kotlin 编译，整包过） | 最后一步全量 A4 + F 段失败文案实测 | 同上 + 步 ⑥ 结束写「安卓侧迁移完成」 |

## 2. 每步四件套的具体口径

### G1 app 单测（audiobook-app）
```bash
./gradlew :app:testDebugUnitTest --tests "com.local.audiobook.data.ximalaya.*"
```
- 步 ①② 时类还在 app：直接跑
- 步 ③ 起：类已进 shared-core → 改跑 `./gradlew jvmTest`（shared-core 目录），app 侧此命令转「确认旧包名零命中」的 grep 检查
- 报告文件：build/test-results/**/TEST-*.xml，摘要行（tests/failures）抄进执行日志

### G2 pytest（ximalaya-bridge，桥不可达期间的固定回归）
```bash
cd bridge 工程（本地） && python3 -m pytest -q
```
- 基线 39 passed（T19 后）；dev-core 每步若加对拍用例，数字只增不减
- 签名步（③）双跑：本目录 pytest + shared-core `./gradlew jvmTest`，同输入同输出逐字节一致才许落盘

### G3 编译门（每次提交前必过）
```bash
./gradlew :app:compileDebugKotlin      # 每步
./gradlew :app:assembleDebug           # 仅步 ⑥
```

### G4 真机飞行模式护栏（验收表 M5 口径，STAGE6B2 A4）
- 装最新 debug/release 包 → 开飞行模式 → 书架/续播/书签/定时全走本地 → 进喜马拉雅页应只报网络问题
- 结果一行进执行日志：「A4 @ 步N：本地全过 / 喜马拉雅页仅网络提示，符合预期」

## 3. 收尾（步 ⑥ 后）
- 全量六步证据汇总一段进执行日志；`grep -rn "data.ximalaya" app/src/main/java` 期望仅剩 expect/actual 接线（若有）
- `git log --oneline` 六个迁移提交可逐一 revert——回退路径按 §19.7.3 验证一次（revert 最早一步 → G3 复绿 → 再恢复）
- A4 最终全量复测一次（与 B4 同口径），写「迁移后 A4 全绿」进执行日志
