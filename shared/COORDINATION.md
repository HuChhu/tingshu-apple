# shared-core 协调留痕（dev-core / task-4）

- 2026-11-21 11:40 lead 放入契约脚手架（com.local.audiobook.core.Contract.kt + Main.jvm.kt TODO(dev-core)）
- 2026-11-21 11:51 dev-core 认领统一：**以 lead 的 Contract.kt 为唯一契约**，包名 com.local.audiobook.core；
  尾部默认值字段扩展（albumId/trackCount/playCount/isFinished/hint 等）对齐 bridge normalize_album，位置兼容
- 删除了 dev-core 早前另起的 com.tingshu.core 包树（未提交过，无双实现漂移窗口）
- engine 实现在 com.local.audiobook.core.engine（七件）+ net SPI（commonMain 引擎注入，actual 触点 0）
- devops-ci 正在 gradle-dist 分片下载 gradle-8.13；dev-core 并行走 wrapper（腾讯镜像）构建，
  谁先完成谁先跑，勿重复组装
- 真实探测记录（≤1rps，网页搜索预算 2/3 已用）：mobile 网关 HTML 错误页 / web riskLevel=5 ×2 /
  category v2/albums 匿名可用（fixtures/ 下四份原件）

## T07 定谳同步（dev-core 收讫，2026-11-21 12:0x）
- K/N 官方无 linux-aarch64 预编译（repo1 实测 404）→ 本机 iosArm64 永久不可行，framework 只能 CI 出；
  JVM 侧工作不受影响（已证：本机 BUILD SUCCESSFUL + live 跑通）
- Gradle 8.13 双份就位（devops-ci gradle-8.13 与 dev-core gradle-dist，同一分片合并包，md5 已由 devops 验）；
  后续统一用 gradle-8.13，gradle-dist 留作冗余
- ksoup 0.2.0（兼容 Kotlin 2.0.21）→ M2 网页级提取器（第2级 HTML 解析）引入；M1 search 全 JSON 管线未用到
- task-4 状态：**已完成待验收**（docs/spike-search.md 六节证据 + 执行日志已记）

## Cookie 策略拍板收讫（2026-11-21 12:1x）
- CookieProvider SPI 进 commonMain（cookie(): String? + refresh()），平台注入：JVM=桥持会话（凭据 env 路径，不进 git/文档），iOS M4=WKWebView+HTTPCookieStorage 拷贝
- M2 设计稿已落 docs/苹果化-M2设计稿.md（验收等待期产出，未动码）；task-5 等 QA 通过 + lead 完结 task-4 后 claim

## qa 验收观察处置（2026-11-21 12:3x dev-core）
- ① fixtures 双名冗余：live-detail-delisted.json 已删（与 live-detail-anon.json 同 md5 44dc22…），spike-detail.md 引用已更新；SLF4J NOP 静音列 M2+ 可选项
- ② **M3 前置硬条件已登记**：播放地址带 Cookie 的 live 200（audio/* Content-Type）必须在 M3 闸口前补验——桥/凭据恢复当天跑 `./build/install/shared-core/bin/shared-core extract <trackId>` + curl Content-Type 留痕（owner=dev-core，触发条件=凭据恢复，tie to docs/spike-detail.md §7 挂起项）
- T03 迁移进行中：五件纯逻辑已入 shared commonMain（Session/Result+Classifier/Throttle/LinkParser/Crypto+SignEngine），引擎统一与安卓侧删除进行中

## CI 污染事故（2026-11-21 14:1x）
- aapt2 override 本机 hack 曾入项目 gradle.properties（1fb88f2）→ CI 配置期污染（framework 7 连败真凶之一），lead 清理 + dev-core 落 commit d87bee1
- 本机配置现居 ~/.gradle/gradle.properties（用户级）；清理后三目标复验全绿——两仓规则：**项目配置文件永远不含本机绝对路径**

## 目录真身声明（2026-11-22 lead 定谳，架构席 ③）
- **唯一真身 = `shared-core`**（真实目录）
- `shared` = **symlink → shared-core**，仅由 audiobook-app 的 `includeBuild("../shared")` 消费；不是第二个工程，禁止在此 symlink 内独立改文件（会写到真身，但认知上易误判）
- 远端 `<owner>/<repo>/shared` = 真实目录（CI 用）
- 漂移防线：`搬一个删一个` + 禁双实现 grep 闸 + 三处（shared-core / tingshu-apple/shared / iOS framework）由 CI 与人工双查

## fixtures 双名清理（2026-11-22 · qa 观察项①归档 · 三仓库实测定谳）
**实物（盘上实测，非推断）**
- `fixtures/live-detail-delisted.json` = **4,629B / md5 `44dc22b27d7a52b3dbbe9bd0e924cfcc`** / ret=924 / albumId=9002
- `fixtures/live-detail-alive-anon.json` = 33,467B / md5 `ef2aea3b…` / ret=0 / albumId=9001
- 工作区 fixtures 11 项；jvmTest 20/0

**恢复来源（逐仓库实测，哈希必须注明所属仓库）**
| 仓库 | 12c660a | 03151e2 | 1bd7ab6 |
|---|---|---|---|
| **本仓 shared-core（真身）** | ✅ 存在（commit，基线 "M2 completed state"）——`git show 12c660a:fixtures/live-detail-delisted.json` = 4,629B/44dc22b2，**delisted 原版即在此** | ❌ 不存在 | ❌ 不存在 |
| 镜像 tingshu-apple（CI 用） | ❌ 不存在 | ✅ 存在 | — |
> **教训：早期留痕把三仓哈希混写，导致后人 `git show` 扑空。此后任何哈希必须标注所属仓库。**

**终态落盘**
- 提交 `80d6140`（本仓）：`git add -A fixtures` → delisted 原版入库、anon.json 删除未追踪状态消除
- tracked `live-` 实录 4 件（alive-anon / delisted / play-anon-realid / play-anon）
- **上次留痕称「已进 git 追踪」时为假**（当时 delisted 是 untracked 裸文件）——本次 80d6140 后才成立

**纪律沉淀**
1. 批量删除先列清单逐一确认，不按文件名模式猜
2. 留痕只写实测值，不写推断值
3. 跨仓引用必须标明仓库名，不写裸哈希
