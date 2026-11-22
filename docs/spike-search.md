# M1 spike 证据 · search 命令行（task-4 / dev-core）

> 2026-11-21 · 工程位置 本仓 shared/（独立于 audiobook-app，迁移期隔离）
> clean-room 声明：写码期间唯一参考 = AGENTS.md §19 + docs/苹果化-引擎接口契约v1.md + ximalaya-bridge（自有代码）。
> 未阅读 本地隔离副本（不入本仓） 与 ZIP。

## 一、验收表 M1 对照
| 项 | 要求 | 结果 |
|---|---|---|
| 产物 | KMP 骨架 JVM 侧 + search 命令行 | shared-core（KMP 2.0.21 / Gradle 8.13 / JDK17 / jvm+withJava()），main 三模式：search / discover / fixture |
| 验收方式 | 运行 main 输出真实书名+作者+封面 URL | ✅ discover 路线打印真实书单（下附样例）；search 路线按 bridge 基线降级（环境性：搜索端点 riskLevel=<n>，§16.4/18.1 既有结论） |
| 证据路径 | docs/spike-search.md | 本文件 + fixtures/ 原始响应 |

## 二、命令行输出样例（UTF-8 实录）
### live：search 三体（降级路径完整走通）
```
RESULT source=none page=1 maxPage=0
HINT 网页搜索失败（risk, riskLevel=<n>）→ RateLimited；搜索降级：在喜马拉雅 App 内搜索后，复制分享链接或专辑 ID 到 App 直达
COUNT books=0
```
行为链 = bridge api.py search 语义：移动端路线（网关 HTML 错误页，非 JSON → 该路线放弃且不重试）→ 网页路线（预算闸门放行）→ ErrorClassifier 判 risk（riskLevel=<n>≥3）→ WebSearchBudget 记账 → 降级 + hint。与 §16.4 基线响应逐字节同型。

### live：discover 3 1 5（真实书单，验收表「书名+作者+封面URL」直接证据）
```
RESULT source=category page=1 maxPage=600
BOOK albumId=9001  title=<redacted-title>丨<redacted>演播丨…丨VIP免费多人有声剧  author=<redacted>  cover=https://<cdn>/storages/3896-…/GKwRIRwIxztKAAWRMwJTyIC8.jpeg  trackCount=9005  playCount=4709567255
BOOK albumId=81519744  title=蛊真人| 大爱仙尊|…  author=<redacted>  cover=https://<cdn>/…  trackCount=3434  playCount=2251048075
BOOK albumId=47517749  title=大奉打更人丨…  author=<redacted>  cover=https://<cdn>/…  trackCount=1754  playCount=11339235547
BOOK albumId=69486129  title=灵境行者丨…  author=<redacted>  cover=https://<cdn>/…  trackCount=2008  playCount=3267802833
BOOK albumId=49808826  title=诡秘之主 | …  author=<studio>  cover=https://<cdn>/…  trackCount=2070  playCount=2518438442
COUNT books=5
```
封面抽查：HEAD https://<cdn>/storages/3896-…/GKwRIRwIxztKAAWRMwJTyIC8.jpeg → 200 image/jpeg (364,851B)。

## 三、与 bridge 双实现对拍（本机，无网依赖）
对拍法：同一份真实 JSON fixtures，分别喂 Kotlin（installDist 产物 fixture 模式）与 bridge 真 Python 函数（import app.api，非转写）。
1. 归一矩阵（fixtures/category.json，5 本）：albumId/title **5/5 逐字节一致**；
   author/cover/trackCount/playCount 差异 = 已文档化的扩展键（类目端点 albumUserNickName/albumCoverPath/albumTrackCount/albumPlayCount，bridge 归一函数写于类目端点接入前，无此四键）。
   处置：Kotlin 侧按同 _pick 语义补键、既有键优先级不变；**M2 待办：四键回写 bridge normalize_album**（§19.7.4 同步纪律方向：引擎→桥）。
2. 错误分类矩阵 4/4 全同：risk-web.json→risk/RateLimited、need-login.json→need_login/Auth、http-error.json→http_error/Upstream、category.json→ok。bridge 侧走真 RiskGuard+Upstream._classify（状态落 /tmp，未碰桥真数据）。
3. fixture 清单：risk-web.json / risk-web-kw2.json（riskLevel=<n> 原件）、category.json（v2/albums 5 本）、gateway-mobile.html（移动端网关 HTML 错误页 336B）、need-login.json / http-error.json（构造对拍用例）。

## 四、上游探测台账（纪律：≤1rps、不硬冲）
| 时间 | 动作 | 结果 | 预算 |
|---|---|---|---|
| 11:42 | mobile search 直探（curl） | HTTP 200 但 336B HTML 网关错误页（非 JSON） | 不计网页预算 |
| 11:47 | web search 直探 #1（三体） | riskLevel=<n> | 1/3 |
| 11:52 | web search 直探 #2（明朝那些事儿，30s 冷却后） | riskLevel=<n> | 2/3 |
| 12:00 | web search 经引擎 #1（三体） | riskLevel=<n> → 降级 hint | 3/3 |
| 11:53 / 12:01 | category v2/albums（匿名端点） | 200，真实数据 | 非搜索端点 |
**网页搜索预算今日用尽（3/3，按 risk.py 纪律记 paused，不重试不换参数）**；后续对拍一律走 fixtures 离线管线。

## 五、构建通道（devops-ci 协同）
- Gradle 8.13 = devops-ci 分片下载合并包（<gradle-dist>/gradle-8.13-bin.zip，unzip -t 通过）→ 解压 <gradle-dist>；JDK17；KGP/序列化/coroutines 多数命中本机 Gradle 缓存，Ktor 3.0.3 走阿里云镜像。
- 坑两枚：① 顶层 application 插件与 KMP 不兼容 → 编译任务被跳过（假 BUILD SUCCESSFUL），修法 jvm { withJava() }；② JVM stdout 默认非 UTF-8 → main 内显式 PrintStream(FileDescriptor.out, UTF-8)。
- actual 触点：0（契约 C3 上限 5）——网络引擎经 commonMain JsonFetcher SPI 注入，jvmMain 仅 KtorJsonFetcher + Main。

## 六、遗留 / M2 接口
- bookDetail / audioExtractor 为显式 NotImplementedError 占位（M2 范围：详情+曲目+播放地址，依赖登录 Cookie）。
- WebSearchBudget 为内存态；落盘持久化 + 人工恢复入口（对齐 risk.py）M2+ 补。
- 协调留痕：shared-core/COORDINATION.md（lead 脚手架认领记录、双写规避、扩展键决策）。
