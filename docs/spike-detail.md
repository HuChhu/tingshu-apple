# M2 spike 证据 · 详情 + 曲目 + 播放地址（task-5 / dev-core）

> 2026-11-21 · 工程 shared-core · M1 同款纪律：clean-room 只读 §19 + 契约v1 + bridge（自有代码）
> 验收口径（验收表 M2）：URL HTTP 200 且 Content-Type=音频 —— **live 挂起待凭据**（lead 已批：fixture 管线 + 单测为过程证据）；详情链路已 live 全通

## 一、交付清单
| 件 | 内容 |
|---|---|
| Contract.kt | +CookieProvider SPI（lead 拍板接口）· Episode.coverUrl / ExtractedAudio.expiresInSeconds 尾部扩展 · SourceErrors 可抛化（见第六节差异清单） |
| engine/DetailRoutes.kt | 详情/曲目模板（ts-{nowMs}?albumId=&page=&pageSize=，bridge 同款）+ 播放接口 URL（revision/play/v1/audio?ptype=1&id=&xmSignType=1） |
| engine/TrackNormalizer.kt | normalize_track 回退链 + 索引数学 baseIndex=(page-1)*pageSize + **duration 秒→毫秒**（修正③） |
| engine/TrackExtractor.kt | 曲目分页信封抽取（tracks.list/totalCount/maxPageId）+ 裸列表防御形态（修正②） |
| engine/AudioUrlHeaders.kt | 头部纪律纯函数：host 精确匹配才注入 UA+Referer；错配必须空 map；/sound/{id} 与裸数字解析 |
| engine/XimalayaAudioExtractor.kt | 级1 直链（零请求）→ 级2 ksoup 预留（不实现）→ 级3 官方接口+Cookie（src/url/playUrl 回退链，expires 3600s）；need_login → refresh() 一次不重试 |
| engine/SearchEngine.kt | +bookDetail（动作二）：详情+曲目双请求、惰性 loadEpisodes/loadFullPages、翻页三重收口闸（totalCount→trackCount→maxPageId/硬上限200） |
| jvmMain/BridgeCookieProvider.kt | 桥凭据文件读取（env 路径，值不进日志，只记字段名——桥同款纪律） |
| Main.kt | +detail / extract 模式 + fixture tracks|play；SourceErrors → 干净 ERROR 行（无堆栈） |

## 二、live 实录（本机直连，≤1rps）
| 探测 | 端点 | 结果 |
|---|---|---|
| 死专辑 9002 | mobile-album 详情 | `{"msg":"当前内容已下架","ret":924,...}`（ret:924 新分类用例，fixtures/live-detail-delisted.json；分类对拍时曾复制 live-detail-delisted.json，qa 指出双名冗余已删除，以 anon 原件为准） |
| 活专辑 9001 | mobile-album 详情 | **匿名可用**：ret:0 + 完整专辑 + 曲目信封（33,467B，fixtures/live-detail-alive-anon.json）——§18.1「详情需登录」对免费专辑不成立，基线修正 |
| 引擎 live detail | 同上（经 SearchEngine） | `DETAIL albumId=9001 title=<redacted-title>… trackCount=2813 loaded=30` + 30 条真实曲目（trackId/标题/秒→毫秒时长/CDN 封面全对） |
| 播放接口（匿名，假 ID） | revision/play/v1/audio | 404 text/html（1,197B） |
| 播放接口（匿名，真实 trackId 9004） | 同上 | 404 text/html —— **匿名一律 404**，与 §16.4「播放地址必须登录」一致；带 Cookie 的 200 验证挂起待凭据 |
| 播放接口（引擎 extract） | 同上 | 非 JSON 响应 → `ERROR kind=ParseFailed`（干净错误行，无堆栈崩溃；契约 ParseFailed=响应不可解析，对应 bridge「非JSON→http_error」注记语义） |

## 三、bridge 三缺陷实录（live 实锤，回写清单待 lead 派单）
| # | bridge 现状 | live 实锤 | 引擎处置 |
|---|---|---|---|
| ① | api.py 直接把 `data.tracks` 当列表 | 是**分页信封 dict**（list/maxPageId/pageId/pageSize/totalCount），曲目在 tracks.list | TrackExtractor 信封为主+裸列表防御；get_book_detail 从未实跑（§17.7），M1 对拍覆盖不到 |
| ② | normalize_track duration 原样进 durationMs | 上游 duration=234 是**秒**（真实第1集 234s） | TrackNormalizer ×1000 换算，字段名与值单位对齐 |
| ③ | M1 已记录：normalize_album 缺类目端点 4 键 | （M1 对拍差异） | AlbumNormalizer 已补，待回写 |
§19.7.4 同步纪律方向：引擎→桥，三件一并回写 bridge api.py（涉及 get_book_detail 实现重写，建议 dev-android/lead 评估；桥当前停用不紧急）。

## 四、分类矩阵与 fixture 管线
- 分类矩阵扩到 **5/5 全同**：M1 四用例 + ret:924 下架（bridge http_error/Upstream ↔ Kotlin 同）。bridge 侧真 RiskGuard+Upstream._classify 直跑。
- fixture 实录与构造分目录：fixtures/live-*.json（实录 3 件：anon / alive-anon / play-anon-realid）+ fixtures/constructed/*.json（构造 4 件，文件名与内容均标 constructed，不冒充实录）；live-detail-delisted.json 已删（与 anon 双名同 md5，qa 观察①）。
- fixture tracks 输出（信封形态）：`TRACK trackId=31 index=31 … totalCount=2813 maxPageId=94 computedMaxPage=94`。
- fixture play 输出（回退链取 src + host 注入）：`EXTRACT url=https://a1.xmcdn.com/… headers=User-Agent=…, Referer=… expiresInSeconds=3600`。

## 五、单测（jvmTest，14 条全绿 0 败）
trackIndexMath / maxPageMath / headersHostMatchInjects / headersHostMismatchMustStayEmpty（含 fakeximalaya.com 与路径伪装两错配用例）/ directAudioAndTrackIdParse / albumIdParse / playResponseFallbackChain / classifyBridgeAligned（ret:50 保持桥语义 http_error 不新造分类）/ bridgeCookieProviderParsesFlatMap / cookieFileMissingMeansNull / needLoginThrowsAuthWithoutRetry（FakeFetcher 计数=1 证不重试）/ missingAlbumThrowsNotFound / detailPaginationIndexMath（跨页索引 1,2,31 + 秒→毫秒 + soundUrl）/ trackEnvelopeShape（信封+防御双形态）。

## 六、契约 v1.1 差异清单（全部机械需要，已同步 lead）
1. `Network.cause → reason`：与 Throwable.cause 属性冲突（override 类型不符）
2. `sealed interface → sealed class(继承 RuntimeException)`：Kotlin throw 需静态 Throwable 类型，引擎以接口类型 throw 传播错误
3. 追加：CookieProvider SPI（拍板）；Book/Episode/SearchResult/ExtractedAudio 尾部默认值字段（bridge 对齐）

## 七、遗留
- 播放地址 live 200（HTTP 200 + Content-Type audio/*）：**挂起待凭据/桥恢复**（CookieProvider 已就绪，注入即用）；期间过程证据=本文件第四节
- WebSearchBudget 落盘持久化 + 人工恢复入口：M2+ 排期（qa 观察②已并入）
- Gradle 升级时 withJava() 行为回归复查：qa 观察①已并入
- 级2 ksoup：预留，主路线非网页不实现
