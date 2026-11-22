# AGENTS.md —— 听书 App 工程约定与架构决策

> 这个文件是给"下一个接手的人（或 AI）"看的说明书。每次改动代码，都要同步更新这里。
> 项目：**私人本地有声书 App**（自用单机：无账号、无服务器、无广告，数据只在本机）
> 版本：**1.0.0（versionCode 1）** · 2026-11-18 封版

---

## 1. 一句话说清这个 App 是什么

把手机里的有声书文件夹（每个子文件夹 = 一本书，里面是 mp3/m4a/flac 分集）导进来，
自动归书、排好章节、抠出封面，然后能播、能续播、能倍速、能后台播。

**第一阶段范围**：只做"骨架 + 最小闭环"。
- ✅ 导入 → 归书 → 播放 → 暂停 → 杀掉 App 重开 → 从上次那秒继续
- ⏳ 未做（第二阶段起）：毛玻璃 / 液态玻璃美化、睡眠定时、书签、统计、导入去重细化、播放记住进度到服务层

---

## 2. 技术栈（已定，不得更换）

| 层 | 选型 | 说明 |
|---|---|---|
| 语言 | Kotlin 2.0.21 + 协程 + Flow | |
| UI | Jetpack Compose + Material 3，深色为主 | `ui/theme/Theme.kt` |
| 播放 | AndroidX Media3 1.5.0（ExoPlayer + MediaSessionService） | 从官方 `demos/session_service` 裁剪 |
| 数据 | Room 2.6.1（三张表）+ DataStore（偏好） | |
| 导入 | SAF `OpenDocumentTree` + 持久化 Uri 权限 | |
| 封面 | MediaMetadataRetriever 抠内嵌封面；无封面用书名首字渐变 | |
| 图片 | Coil 2.7.0 | |
| 兼容 | minSdk 26（Android 8.0），compileSdk/targetSdk 35 | |
| 构建 | AGP 8.7.3 + Gradle 8.13 + KSP 2.0.21-1.0.28 | |

依赖镜像：`settings.gradle.kts` 里优先使用阿里云 Maven 镜像，国内网络可直接拉齐依赖。

---

## 3. 模块划分：为什么是"单模块分层"而不是多模块

选的方案：**单 module `app` + 包内分层**。

理由：
1. 这是一个人自用的小 App，多模块（`:core:data`、`:feature:shelf` 那种）会把构建时间、IDE 复杂度翻倍，
   换来的只是"编译隔离"，对这个规模不划算；
2. 分层用包名强制出来，同样能防止"UI 直接写 SQL"：

```
com.local.audiobook
├── AudiobookApp.kt              Application，启动时建 AppContainer
├── MainActivity.kt              唯一 Activity；把"进度写库"接到播放层
├── data/
│   ├── AppContainer.kt          手动依赖容器（DB / 仓库 / 导入器 / 偏好）
│   ├── db/                      Room：Entities.kt / LibrarySnapshot.kt / *Dao.kt / AppDatabase.kt
│   ├── repo/                    LibraryRepository / PlaybackRepository（界面只认仓库）
│   ├── imports/                 AudioFileScanner / NaturalSort / CoverGenerator / LibraryImporter
│   └── prefs/PlayerPrefs.kt     DataStore：倍速记忆
├── playback/
│   ├── AudiobookPlayerService.kt  MediaSessionService 骨架
│   ├── PlayerSession.kt           界面↔服务的唯一桥梁（单例 + StateFlow）
│   ├── PlayStateStore.kt          服务侧 DataStore：播放清单快照 + 上次位置
│   └── PlaybackRules.kt           纯规则函数（倍速档位、续播回退）
└── ui/
    ├── theme/                    深色主题
    ├── nav/AppNavHost.kt         Compose Navigation：shelf → player/{bookId}
    ├── shelf/                    书架页（ViewModel + Screen）
    ├── player/                   播放页（ViewModel + Screen）
    └── format/                   时长/相对时间格式化
```

> 什么时候才拆模块：当"数据层被第二个 App 复用"或"构建 > 2 分钟"时再拆。

---

## 4. 数据模型（Room，version = 1）

### books
| 字段 | 含义 |
|---|---|
| id | 主键 |
| title | 书名 = 文件夹名 |
| sourceUri | SAF 授权的 document tree uri（字符串） |
| folderPath | 相对授权根目录的路径（"书A" 或 "作者/书A"），与 sourceUri 一起唯一 |
| coverPath | 封面 jpg 的绝对路径（App 私有目录 `files/covers/`） |
| coverHue | 无封面时首字渐变封面的色相 |
| trackCount / totalDurationMs | 缓存，书架显示用 |
| createdAt / lastPlayedAt | 书架排序（最近听的排前面） |

### tracks
| 字段 | 含义 |
|---|---|
| id / bookId / chapterIndex | （bookId, chapterIndex）唯一 |
| title / uri / durationMs / sizeBytes | 集标题、SAF 文件 uri、时长、大小 |

### playback_position
| 字段 | 含义 |
|---|---|
| bookId（主键） | 一本书一条 |
| trackIndex | 上次听到第几集（0 起） |
| positionMs | 上次听到的具体毫秒 |
| updatedAt | 最后写入时间戳，用来判断"暂停是否超过 10 分钟" |

**改表必读**：改字段就要升 `version` 并写 `Migration`，否则启动崩。
schema 快照导出在 `app/schemas/`。

---

## 5. 关键规则（都在 `playback/PlaybackRules.kt`，纯函数，方便单测）

1. 倍速：0.5x ~ 3.0x，0.1x 一档；`nextSpeed/prevSpeed` 负责上下档。
2. 进度写回：**后台服务内**每 5 秒一次（另在暂停、切集、任务被划掉、服务销毁时补写）；写 Room 给书架/界面，写 DataStore 给服务自己重启恢复。
3. 续播回退：暂停（或被杀）超过 **10 分钟**再播，自动往回 **15 秒**；不足 10 分钟则精确续播。

进播放页时的续播流程（`PlayerViewModel.open`）：
读 progress → `resumePositionMs()` 算出起播毫秒 → `PlayerSession.loadBook()` 装全书 → 等用户点播放。

---

## 6. 导入规则（`data/imports/`）

1. 用户选一个文件夹（SAF `OpenDocumentTree`），立刻 `takePersistableUriPermission` 记住访问权。
2. 递归扫描（最多 6 层），只认 `.mp3/.m4a/.flac` 和 `audio/*`。
3. **同一文件夹 = 一本书**：授权根目录下每个（可能嵌套的）子文件夹各成一本；根目录直接放音频时，根目录本身算一本。
4. 章节顺序 = 文件名**自然排序**（`第2集` 在 `第10集` 前），写入 `chapterIndex`。
5. 封面：取这本书第一集的内嵌封面；没有就按"书名首字 + 书名算出的色相"生成渐变图，存 `files/covers/`。
6. 重复导入同一文件夹：按 (sourceUri, folderPath) 找到旧书，更新集列表和封面，不重复建书。

---

## 7. 代码规范

- 一段代码只做一件事；UI 不碰数据库，只认 Repository。
- 新逻辑先写成 `PlaybackRules` 那种**纯函数**，再接到 Android API 上，方便测试。
- 注释用中文，解释"为什么"而不是"做什么"；专业名词第一次出现写一句白话解释。
- 所有耗时操作（扫描、读元数据、写库）在 `Dispatchers.IO`；UI 只收 StateFlow。
- 命名：Compose 界面函数用大驼峰 `XxxScreen`；ViewModel 用 `XxxViewModel`；DAO 方法 `observeXxx/getXxx`。

---

## 8. 已知限制 / 第二阶段待办

- [x] **进度写库已搬进后台服务**：`AudiobookPlayerService` 每 5 秒写 Room + DataStore，
      服务被系统回收后能从 `play_state` DataStore 恢复"哪本书 / 第几集 / 第几毫秒"，并应用"超 10 分钟回退 15 秒"。
- [ ] 没有睡眠定时、书签、按书分组之外的筛选、排序。
- [ ] 通知栏只有 Media3 默认样式，未定制深色/毛玻璃。
- [ ] 音频焦点、来电中断已有 Media3 默认行为，但未做"被打断后自动续播"的策略配置。
- [x] 毛玻璃（Haze）与液态玻璃（Kyant0 backdrop）已接入，见第 10 节。
- [ ] 导入没有后台化（大量文件时界面会转圈），第二阶段改 WorkManager + 通知。

---

## 9. 构建与验证

- 本仓库的标准构建：Android Studio 打开 → Sync → Run 'app'。
- 命令行：`./gradlew assembleDebug`（产物 `app/build/outputs/apk/debug/app-debug.apk`）。
- 第一阶段的验收清单见 `docs/STAGE1-CHECKLIST.md`。

---

## 10. 第二阶段：视觉层（海报墙 + 玻璃）

### 10.1 三个库分别管什么（职责不重叠）

| 库 | 层级 | 管什么 | 不管什么 |
|---|---|---|---|
| **Haze** `dev.chrisbanes.haze:haze` | 页面级背景 | 封面放大虚化铺满 + 30% 黑遮罩；把背景注册成「可被控件取样的模糊源」（`hazeSource`/`hazeEffect`） | 控件外观、圆角、描边 |
| **Kyant0 backdrop**（即 AndroidLiquidGlass）`io.github.kyant0:backdrop` | 控件级前景 | 折射(lens)+提亮(vibrancy)+高光边，让按钮/迷你条像真玻璃 | 页面背景、布局 |
| **GlassCard**（自写 `Modifier` 扩展） | 通用卡片皮肤 | 半透明白 10% 底 + 1px 半透明白描边 + 顶部内高光 | 模糊（模糊由 Haze + 半透明叠加完成） |

### 10.2 版本决策（重要，别再乱升）

| 库 | 用过 / 目标版本 | 结论 |
|---|---|---|
| Haze | README 最新 **2.1.0** | ❌ 不可用：POM 强制 `compose 1.12.2` + `kotlin-stdlib 2.4.21`，本项目是 Compose BOM 2024.10（Compose 1.7.5）+ Kotlin 2.0.21，升级会把整个工程拖崩 |
| Haze | **1.6.10** ✅ | 依赖 `compose ui/foundation 1.8.0` + Kotlin 2.1，与本项目兼容（Gradle 会用 1.7.5 resolve，API 只用 `rememberHazeState/hazeSource`，1.6 起就有） |
| Haze | 1.5.0 | 依赖 Compose 1.7.3，理论上也行；选 1.6.10 是为了 bug 修复 |
| backdrop | README 指向 Maven Central 的 `io.github.kyant0:backdrop` 最新 **2.0.1** | ✅ 采纳为最终版本 |
| backdrop | 1.0.6 | 理论上更保守（依赖 Compose 1.10.3），但 **在 Maven Central 上后台只发布了 2.x 的 aar**，1.0.6 的 `backdrop-android` 取不到（404） |
| Coil | 2.7.0（第一阶段引入） | ❌ 第二阶段**移除**：见 10.4 |

> 升级 Haze/backdrop 到 2.x 的前提是：Compose 升到 1.12 + Kotlin 升到 2.4 + AGP 升到 9.x。那是「换技术栈」级别的事，需要单独一轮评估。

### 10.3 降级策略（必须遵守）

1. **系统版本降级**：backdrop 内部用 `RenderEffect`（API 31+）。`LiquidGlassSupport.isSupported` 在 API 26~30 返回 false，`Modifier.liquidGlass()` 直接走 `glassCard()` 分支（高光 + 半透明底），不调用任何新 API。
2. **拿不到背景源降级**：`LocalBackdrop` 默认值是 `null`（不是 error）。任何页面忘了提供背景源，玻璃控件自动退化成 `glassCard`，不会崩。
3. **库拉不下来**：删掉 `build.gradle.kts` 里 `io.github.kyant0:backdrop` 一行，同时把 `LiquidGlass.kt` 的 `LiquidGlassSupport.isSupported` 改成恒 `false`，视觉上仍保留 haze + GlassCard 同样的毛玻璃观感。**改完要在本节记一笔。**
4. Haze 也一样是「可选项」：若某天 Haze 抽风，删依赖 + 把 `HazeBackdrop` 里的 `hazeSource`/`hazeEffect` 注掉即可，`Modifier.blur` 的页面虚化仍然生效（那才是用户看到的主要效果）。

### 10.4 为什么把 Coil 换掉（第二阶段的技术决定）

- 封面全部是**本机** jpg（导入时已落盘），没有网络图，Coil 的缓存/请求管线是纯开销；
- Coil 的 `AsyncImage` 依赖 `AsyncImagePainter`/`EqualityDelegate` 等内部类，在没有 Compose 编译器插件的离线校验里无法验证，属于「不可验证的黑盒」；
- 换成 `ui/components/FileImage.kt`：`BitmapFactory` 按 `inSampleSize` 下采样（封面最大 720px，背景源 512px），IO 在 `Dispatchers.IO`，主线程零 IO；
- 收益：少一个 ~700KB 依赖、解码尺寸可控、列表滑动更稳。
- **注意**：`build.gradle.kts` 里的 `io.coil-kt:coil-compose` 暂时保留不删（防止你以后想加网络图），但代码里已经没有任何地方引用它。

### 10.5 视觉组件清单（新增 / 重写）

```
ui/glass/
├── GlassTokens.kt      设计令牌：颜色 / 圆角 / 间距 / 封面比例 / 模糊半径
├── GlassCard.kt        Modifier.glassCard(...)  通用玻璃卡片皮肤
├── HazeBackdrop.kt     HazeBackdrop(coverPath) { content }  页面级背景（虚化封面 + 30% 遮罩 + hazeSource）
└── LiquidGlass.kt      Modifier.liquidGlass(...) + LiquidGlassSupport（能力探测 / 降级）

ui/components/
├── BackdropHolder.kt   LocalBackdrop（CompositionLocal）+ ProvideBackdrop()
├── FileImage.kt        本地封面解码（替代 Coil）
├── CoverArt.kt         封面组件：有图用图，没图用书名首字渐变
├── ThinProgress.kt     4dp 圆角细进度条（Canvas，一次绘制）
├── MiniPlayerBar.kt    底部悬浮迷你播放条（滑入滑出 / 点整条跳页 / 点按钮只切播放）
├── GlassIconButton.kt  圆形玻璃按钮（顶部搜索/导入、卡片更多、播放页按钮）
└── EmptyShelf.kt       空书架：大标题 + 玻璃大按钮
```

### 10.6 书架页（海报墙）规格

- 头部：左「书架」30sp 粗体；右侧两个 44dp 圆形玻璃按钮（搜索 / 导入）。
- 网格：`LazyVerticalGrid(GridCells.Fixed(2))`，卡片间距 14dp，左右留白 16dp，**底部预留 90dp**给迷你条。
- 卡片：封面 `aspectRatio(2f/3f)` 圆角 14dp + 12dp 阴影；书名 15sp 半粗；副标题 12sp 62% 白（≥55% 下限）；4dp 细进度条。
- 进度口径：`(lastChapterIndex + 本集已播比例) / 总集数`，卡片文字和进度条**共用同一个函数** `progressOf()`，永远一致。
- 迷你条：距底 16dp、左右 16dp、高 64dp、圆角 22dp；无在播书时 `AnimatedVisibility` 完全隐藏。
- 空态：居中「先导入一本有声书」+ 说明文案 + 200×54 玻璃按钮「选择文件夹」。

### 10.7 播放页规格（只动皮肤）

- 背景：当前书封面虚化 + 30% 遮罩；中央封面卡 72% 宽、2:3、圆角 22dp、24dp 阴影。
- 滑块：Material3 `Slider` + 自定义颜色（白拇指/白活动轨/14% 白底轨），左「已播」右「-剩余」。
- 按钮排：上一集(52) / 播放暂停(76) / 下一集(52) / 倍速(52，显示 `1.0x`；点一下 +0.1，到 3.0 回到 0.5)。
- 章节：`ModalBottomSheet` 玻璃面板（顶部圆角 26dp），当前集行加粗 + 主色序号。
- 播放逻辑一行未改：续播、5 秒写库、10 分钟回退 15 秒全部走第一阶段的 `PlaybackRules` / `AudiobookPlayerService`。

### 10.8 第二阶段的验收自查（跑完在 `docs/STAGE2-CHECKLIST.md` 打勾）

见 `docs/STAGE2-CHECKLIST.md`。


---

## 11. 第三阶段：功能补全（睡眠定时 / 跳过片头片尾 / 后台导入 / 搜索）

### 11.1 数据库版本与迁移（重要）

| 项 | 值 |
|---|---|
| schema 版本 | **1 → 2** |
| 变化 | `books` 新增 `skipIntroSec INTEGER NOT NULL DEFAULT 0`、`skipOutroSec INTEGER NOT NULL DEFAULT 0` |
| 迁移实现 | `data/db/Migrations.kt` 的 `MIGRATION_1_2`，两条 `ALTER TABLE ... ADD COLUMN` |
| 是否删库 | **否**。禁止 `fallbackToDestructiveMigration` |
| 老数据影响 | 升级后老书自动 `skipIntroSec=0 / skipOutroSec=0`，行为与升级前完全一致 |
| 索引/外键 | 原样保留（`index_books_sourceUri_folderPath` 唯一索引、`tracks` 外键 CASCADE） |
| 实测 | 用 node:sqlite 建 v1 表 → 插入书/集/进度 → 执行两条 ALTER → 校验行数、旧字段值、新列默认值、索引、外键全部通过（`MIGRATION OK`） |

**以后再改表**：升 `version` + 在 `Migrations.kt` 追加 `MIGRATION_n_n+1` + 加进 `ALL_MIGRATIONS`，三件事缺一不可。

### 11.2 睡眠定时

- **驱动位置**：`AudiobookPlayerService` 内的 `SleepTimerController`，协程 + `delay(250ms)`，**不用 Handler**。
- **计时口径**：按"实际播放时间"。暂停时冻结剩余并 cancel 协程；恢复时用冻结值重新起跑；暂停 20 分钟不会扣 20 分钟。
- **渐弱**：剩余 ≤10 秒开始，`SleepTimerRules.fadeVolume()` 线性 1.0→0，每 250ms 写一次 `player.volume`；到 0 后 `pause()` 并**立刻把 volume 复位 1.0**（否则下次播放静音，这是这类功能最常见的隐藏 bug）。
- **播完本集停**：独立模式，服务里 250ms 轮询播放位置，`SleepTimerRules.hasReachedTrackEnd()` 命中即 `pause()`。
- **界面→服务**：Media3 自定义命令。参数编码进命令名（`SET_SLEEP_TIMER:30`），因为 `sendCustomCommand` 的 Bundle 在部分版本会丢。`onConnect` 里必须把每条带参命令**显式登记**，否则会被拒绝。
- 纯函数：`SleepTimerRules`（tick / fadeVolume / isFading / onPause / onResume / formatRemaining / hasReachedTrackEnd）+ `SleepTimerSimulator`（暂停恢复状态机）。

### 11.3 跳过片头片尾

- 每本书两列：`skipIntroSec`、`skipOutroSec`（秒，0=关）。界面档位白名单 0/5/10/15/20/30/45/60 秒（与 `ServiceCommands.SKIP_MARKER_STEPS_SEC` 一致，因为会话命令必须显式登记）。
- **进新一集**（`onMediaItemTransition`）时：`SkipMarkerRules.startPositionMs()` 决定是否把起点推到片头结束。不跳的四种情况：片头为 0 / 用户本集手动拖过 / 本来要播的位置已超过片头（续播，别拽回去）/ 片头比整集还长。
- **片尾**：服务里 250ms 轮询，`SkipMarkerRules.shouldSkipToNext()` 命中就 `seekToNextMediaItem()`；最后一集永远不切（让它自然结束）；片尾比整集还长时不切（防无限切集）。
- "手动拖过"的判定：`onPositionDiscontinuity(SEEK)` 里置位 `userSeekedThisTrack`，切集时复位。
- 纯函数：`SkipMarkerRules`（clampSkipSeconds / secondsToMs / startPositionMs / shouldSkipToNext）。

### 11.4 后台导入（WorkManager）

- **依赖机制**（三选三，全部用上）：
  1. WorkManager 的**持久化任务队列**：进程被杀/重启后系统重新拉起未完成任务；
  2. **前台作业 setForeground()**：常驻通知"正在导入《书名》3/12 集"，避免长导入被判后台耗电；
  3. **唯一任务名 + ExistingWorkPolicy.REPLACE**：重复点导入不会叠加两份任务。
- 导入本身是**幂等**的（按 `(sourceUri, folderPath)` 找旧书就更新），所以任务重启后从头再扫一遍不会产生重复书。
- 进度复用现有 `ImportState`：`LibraryImporter` 新增 `addProgressListener/removeProgressListener`，Worker 监听后 400ms 节流刷新通知。
- 界面：点导入 → `ImportScheduler.enqueue` 立刻返回；顶部细玻璃进度条不阻塞操作；导入中"+"按钮变淡且不响应（VM 里 `isImporting` 双重防抖）。
- 新增权限：`FOREGROUND_SERVICE_DATA_SYNC`（Android 14+ 前台作业必需）。
- 通知渠道：`import_progress`（IMPORTANCE_LOW，不出声），App 启动时创建（`AppContainer.init`）。

### 11.5 书架搜索

- 标题栏原地展开：`ShelfSearchBar`（BasicTextField + 玻璃底），右侧"取消"退出并清空。
- 只搜书名，大小写不敏感，支持空格分词（"三国 演义" 等价于两个词都要命中）。
- 纯函数：`ShelfSearch.filter()` / `ShelfSearch.emptyHint()`。拼音首字母未实现（需要多音字表，收益低，留作可选加分项）。
- 无结果 → `NoSearchResult` 空态；书架本身为空 → `EmptyShelf`（两者文案不同，不要混）。

### 11.6 第三阶段新增/改动文件

新增：`playback/SleepTimerRules.kt`、`playback/SleepTimerController.kt`、`playback/SkipMarkerRules.kt`、`playback/ServiceCommands.kt`、`data/db/Migrations.kt`、`data/imports/ImportWorker.kt`、`data/imports/ImportScheduler.kt`、`data/imports/ImportNotifications.kt`、`ui/shelf/ShelfSearch.kt`、`ui/player/SleepTimerSheet.kt`、`ui/player/SkipMarkerSheet.kt`、`res/drawable/ic_stat_import.xml`

改动：`data/db/Entities.kt`（+2 列）、`data/db/AppDatabase.kt`（v2 + 单例 + 迁移）、`data/db/BookDao.kt`（updateSkipMarkers）、`data/repo/LibraryRepository.kt`（同）、`data/AppContainer.kt`（单例 DB + 通知渠道）、`data/imports/LibraryImporter.kt`（进度监听）、`playback/AudiobookPlayerService.kt`（定时器 + 跳过 + 自定义命令）、`playback/PlayerSession.kt`（定时/跳过状态与命令）、`ui/shelf/ShelfViewModel.kt`、`ui/shelf/ShelfScreen.kt`、`ui/player/PlayerViewModel.kt`、`ui/player/PlayerScreen.kt`、`app/build.gradle.kts`（+ WorkManager）、`AndroidManifest.xml`（+ dataSync 权限）

### 11.7 视觉层约束（第三阶段不动）

海报墙、迷你条、背景虚化、GlassCard、液态玻璃一律不改；章节面板保持"自绘玻璃卡片"方案 A。


---

## 12. 第四阶段：本地智能推荐 + 书签

### 12.0 铁律

**全程零网络、零爬虫**。推荐只吃手机本地数据（收听会话 + 进度表），没有任何联网代码，也不打算加。

### 12.1 数据库版本与迁移链（v2 → v3）

| 项 | 值 |
|---|---|
| schema 版本 | **2 → 3** |
| 变化 | **只新建两张表**，旧表（books / tracks / playback_position）一列未动 |
| 新表 | `listening_stats`（收听会话）、`bookmarks`（书签） |
| 迁移实现 | `data/db/Migrations.kt` 的 `MIGRATION_2_3` |
| 登记顺序 | `ALL_MIGRATIONS = [MIGRATION_1_2, MIGRATION_2_3]` |
| 禁止 | `fallbackToDestructiveMigration`（删库） |

**迁移路径（实测，见 12.6）**：

| 用户状态 | 路径 |
|---|---|
| 第一阶段用户（v1） | v1 → *(MIGRATION_1_2)* → v2 → *(MIGRATION_2_3)* → v3 |
| 第三阶段用户（v2） | v2 → *(MIGRATION_2_3)* → v3 |
| 全新安装 | 直接建 v3 全表，不跑迁移 |

外键：两张新表都对 `books` 建 `ON DELETE CASCADE`（删书连带清统计和书签）。

### 12.2 收听统计口径（`data/stats/ListeningTimeRules.kt`）

- **只统计真正在播的时间**：暂停、缓冲不计；
- 统计的是"陪伴时长"，**与倍速无关**：3 倍速听 60 秒 = 60 秒；
- 单次采样上限 **2 秒**（防"休眠 3 小时被算成听了 3 小时"）；
- 会话：暂停超过 **30 分钟** 开新会话；单会话超过 **6 小时** 强制切断；
- 跨天：`splitByDay()` 把一段收听按自然日拆开，跨 0 点那部分正确落到两天；
- 单日上限 16 小时（异常数据兜底）；
- 本周区间：`weekWindow()` 返回**天序号**（不是毫秒）。

> **踩过的坑（重要）**：第一版 `weekRange()` 返回毫秒 `LongRange`，却拿去和"天序号"比较，
> 结果永远不命中、本周永远是 0。是单测抓出来的，已改成 `weekWindow()` 返回 `WeekWindow(startDayIndex, endDayIndexExclusive)`。
> 以后写任何"按天聚合"，都先想清楚手里这个是**毫秒**还是**天序号**。

写入时机：复用播放服务里已有的 250ms 位置轮询（`ListeningRecorder.tick`），
同一时间只允许一个写任务（AtomicBoolean 闸门），不会把数据库打爆。

### 12.3 推荐引擎（`data/recommend/RecommenderRules.kt`）

| 维度 | 函数 | 说明 | 权重 |
|---|---|---|---|
| 新鲜度 | `freshnessScore` | 7 天半衰期；≥30 天触底 0.05 | 0.35 |
| 完成度 | `completionScore` | 30%~80% 满分；<30% 线性升；≥95% 归零 | 0.30 |
| 累计时长 | `durationScore` | `1 - e^(-t/60min)` 饱和曲线，防霸榜 | 0.15 |
| 未开始加成 | `neverStartedScore` | 一次没听过给 0.6 | 0.20 |
| 已听完降权 | 乘子 | 完成度 ≥95% → 总分 ×0.1 | — |

权重集中在 `RecommenderRules.Weights`，改手感只改一处。

**行为约定（已单测）**：
- 列表为空 → `null`
- **只有 1 本 → 照常推荐它**（用户只有它）
- **全部听完 → `null`**，整卡隐藏
- 分数相同时取列表里靠前的那本（列表顺序稳定，结果可复现）
- `shouldShowCard(bookCount, recommendedIsNull)`：**书不足 3 本** 或 没有推荐 → 隐藏整卡（独立纯函数，避免和算法规则打架）

理由文案五种：`3 天没听了，接着上次` / `听了一半，正好续上` / `刚导入还没开始` / `刚开始听，接着往下走` / `一直听着，继续保持`。

### 12.4 书签（`data/bookmark/BookmarkRules.kt`）

- 默认标题：`第 X 集 mm:ss`（长时长自动 `h:mm:ss`）；
- 判重：同一本书 + 同一集 + 位置差 ≤1 秒 → **合并**（保留旧 id、更新位置、备注为空不覆盖旧备注）；
- 进度条小三角：只画当前集的；间距 <2% 的合并，避免挤成黑线；
- 跳转：`resolveJumpTarget` 把越界集序号夹到最后一集、位置夹到集时长内（防导入后集数变少导致跳飞）。

### 12.5 界面

- 书架：`✨ 猜你想听` 玻璃大卡（跨两列），点卡直进播放页；**每 30 分钟重算**，不做实时刷新（回到前台会补刷一次）。
- 播放页：底部一行小字「本周已听 X 小时 Y 分钟」（TextSecondary）；顶部书签按钮；进度条上方小三角；书签玻璃面板（点跳转 / 删）。

### 12.6 实测证据（本机跑出来的，非推演）

**纯函数单测：88 条全过**（`ALL PASS (88 checks)`），覆盖：
暂停不计入 / 2 秒采样上限 / 跨天拆分 / 周区间边界（含周日 23:50 跨零点）/ 完成度聚合 /
推荐四维度 / 理由文案 / 只有 1 本 / 全部听完 → null / 卡片显隐 / 书签判重合并 / 标记合并 / 跳转夹取。

**迁移链实测：13 条全过**（`MIGRATION CHAIN OK`），三条路径：
v1→v2→v3（老数据无损 + 新列默认 0 + 新表可写 + 删书级联清统计/书签/集）、
v2→v3（片头片尾设置保留）、v3 空库、以及 M23 重复执行幂等。

### 12.7 第四阶段新增/改动文件

新增：`data/stats/ListeningTimeRules.kt`、`data/stats/StatsModels.kt`、`data/stats/ListeningAggregator.kt`、`data/stats/ListeningRecorder.kt`、`data/recommend/RecommenderRules.kt`、`data/bookmark/BookmarkRules.kt`、`data/db/StatsEntities.kt`、`data/db/StatsDao.kt`、`data/db/BookmarkDao.kt`、`data/repo/InsightsRepository.kt`、`ui/components/RecommendCard.kt`、`ui/components/BookmarkMarkerTrack.kt`、`ui/player/BookmarkSheet.kt`

改动：`data/db/Migrations.kt`（+MIGRATION_2_3）、`data/db/AppDatabase.kt`（v3 + 两个 DAO）、`data/AppContainer.kt`（+InsightsRepository）、`playback/AudiobookPlayerService.kt`（+ListeningRecorder）、`ui/shelf/ShelfViewModel.kt`、`ui/shelf/ShelfScreen.kt`、`ui/player/PlayerViewModel.kt`、`ui/player/PlayerScreen.kt`

### 12.8 本轮明确不做

按用户要求：按作者分组、自定义睡眠分钟数、通知栏样式定制 —— 留给后续，不抢跑。


---

## 13. 构建环境（首次编译闭环，2026-11-18 完成）

> 本项目的 APK **只能在这台阿里云服务器上构建**。手机上的 aarch64 环境编不出来（原因见 13.1）。
> 下文路径均以「清理时看得懂」为目的，按依赖关系从下往上删即可。

### 13.1 为什么手机编不出来

手机侧是 aarch64 + proot Ubuntu，官方 build-tools 里的 `aapt2` 是 **x86_64 ELF**，执行不了；
系统自带的 `aapt2 2.19-debian` 虽是 ARM 原生，但读不了 API 35+ 的资源表（`entry offsets overlap actual entry data`）。
所以第一至第四阶段的"未实跑"都是这个原因，不是代码问题。

### 13.2 构建机信息

| 项 | 值 |
|---|---|
| 主机 | 阿里云 ECS，Alibaba Cloud Linux 3 (OpenAnolis)，x86_64 |
| 规格 | 2 核 / 3.5GiB 内存（可用约 2.6Gi）/ 2GiB swap（预装，未改动）/ 磁盘 49G |
| 连接 | `OPS_SSH`（密码不入库、不入文档、不入任何日志） |
| 项目路径 | `audiobook-app`（约 193M，含 build 产物） |

### 13.3 安装了什么（清理清单）

| 组件 | 路径 | 体积 | 说明 |
|---|---|---|---|
| JDK 17 完整版 | `/usr/lib/jvm/java-17-openjdk-17.0.20.0.8-1.1.0.2.1.al8.x86_64` | ~300M | 由 `java-17-openjdk-headless` + `java-17-openjdk-devel` 提供；**headless 只有 JRE，没有 javac，必须装 devel** |
| Android SDK 根 | `<ANDROID_SDK>` | ~1.0G | 含 cmdline-tools/latest、platform-tools 37.0.1、platforms/android-35、android-36、build-tools/35.0.0 |
| Gradle 缓存 | `~/.gradle` | ~1.7G | wrapper 发行版 + 全部依赖 |
| 项目 | `audiobook-app` | ~193M | 源码 + build 产物 |

> **注意**：`<ANDROID_SDK>` 里原本已有别人的 `android-9 / android-14 / android.jar / build-tools.zip`（254M，2026-11-14），
> **不是本项目的**，清理时别删。

**系统默认 Java 没有改动**：仍是 `1.8.0_502`，alternatives 未触碰。构建时靠 `JAVA_HOME` 环境变量指向 17。

### 13.4 构建命令（唯一正确姿势）

```bash
cd audiobook-app
export JAVA_HOME=/usr/lib/jvm/java-17-openjdk-17.0.20.0.8-1.1.0.2.1.al8.x86_64
export ANDROID_HOME=<ANDROID_SDK>
export ANDROID_SDK_ROOT=<ANDROID_SDK>
export http_proxy=http://127.0.0.1:7890     # 必须：GitHub release 直连只有几 KB/s
export https_proxy=http://127.0.0.1:7890
./gradlew assembleDebug --console=plain --no-daemon
```

产物：`app/build/outputs/apk/debug/app-debug.apk`

### 13.5 gradle.properties 的改动（为什么这么写）

```properties
org.gradle.jvmargs=-Xmx1200m -XX:MaxMetaspaceSize=384m
kotlin.daemon.jvmargs=-Xmx1024m
android.suppressUnsupportedCompileSdk=36
```
- 2.6G 可用内存，给 Gradle 1200m + Kotlin daemon 1024m，剩下给系统与 swap；
- `--no-daemon`：2 核机器上常驻 daemon 反而容易在下一轮 OOM；
- `suppressUnsupportedCompileSdk=36`：AGP 8.7.3 官方只支持到 35，但 backdrop 1.0.6 的 AAR 元数据强制要求
  `compileSdk >= 36`，否则 `:app:checkDebugAarMetadata` 直接失败。**这是被动升级，不是我们想用 36 的新 API。**

### 13.6 app/build.gradle.kts 的三处关键改动

1. **`compileSdk = 36`**（原 35）：backdrop 1.0.6 / shapes 1.2.0 的 AAR 元数据写了 `minCompileSdk=36`。
   `targetSdk` 仍保持 35，不影响运行时行为。
2. **强制 stdlib 版本**：
   ```kotlin
   configurations.all {
       resolutionStrategy {
           force("org.jetbrains.kotlin:kotlin-stdlib:2.0.21")
           force("org.jetbrains.kotlin:kotlin-stdlib-jdk7:2.0.21")
           force("org.jetbrains.kotlin:kotlin-stdlib-jdk8:2.0.21")
       }
   }
   ```
   backdrop 1.0.6 把 `kotlin-stdlib` 拖到 2.3.10，而本项目编译器是 2.0.21，读不了 2.3 的元数据。
3. **`freeCompilerArgs += listOf("-Xskip-metadata-version-check")`**：
   backdrop 1.0.6 本体仍是 Kotlin 2.3 编译的，需要放行元数据版本检查。
   **风险已知**：这意味着放弃"编译器能校验依赖 API 演进"这层保护；已实测本项目的 4 处调用（drawBackdrop/lens/vibrancy/blur）
   在 1.0.6 上编得过。**升级 backdrop 时必须重新核对**。

> 情报（用户提供，已记下）：backdrop 1.0.5 / 1.0.6 / 2.0.1 分别是 Kotlin 2.3.0 / 2.3.10 / 2.4.10 编译，
> **没有**能"自然兼容" Kotlin 2.0.21 的中间版本。1.0.6 + 上述两个压制手段是唯一现实解。

### 13.7 首次完整构建记录

| 项 | 值 |
|---|---|
| 首次全量构建耗时 | **约 12 分钟**（含下载 Gradle 发行版、全部依赖；共 6 轮迭代到 BUILD SUCCESSFUL） |
| 最终一轮（增量，改 3 个源文件） | **102 秒** |
| gradle assembleDebug 自报 | `BUILD SUCCESSFUL in 1m 41s` / 36 tasks |
| 内存峰值 | 构建前 used=936Mi / available=2.6Gi → 构建后 used=2.4Gi / **available 最低 1.1Gi**，未触发 OOM，swap 只用了 233Mi |
| APK 大小 | **24,560,293 字节（约 23.4 MiB）** |
| APK md5 | `6ac9602fe3451b549597950447da516d` |
| APK 信息 | package `com.local.audiobook`，versionCode 1，versionName 0.1.0，minSdk 26，targetSdk 35，compileSdk 36 |

### 13.8 编译期踩过的坑（按发现顺序）

| # | 现象 | 原因 | 修法 |
|---|---|---|---|
| 1 | `Toolchain ... does not provide [JAVA_COMPILER]` | 只装了 headless（JRE） | 补 `java-17-openjdk-devel` |
| 2 | Gradle 发行版下载 30 分钟没动静 | GitHub release 直连几 KB/s | 走 7890 代理 |
| 3 | `checkDebugAarMetadata FAILED`（要求 compileSdk 36） | backdrop 1.0.6 的 AAR 元数据 | compileSdk 升 36 + suppress 警告 |
| 4 | `Module was compiled with an incompatible version of Kotlin` | stdlib 被拖到 2.3.10 / backdrop 元数据 2.3 | force stdlib + skip-metadata-version-check |
| 5 | `Return type mismatch: expected String, actual Serializable` | `if(..) "str" else null` 被推断成共同父类 | 显式声明 `val x: String? = ...` 后 `?: 默认值` |
| 6 | `Unresolved reference 'MutableStateFlow'` | 第三阶段清理 import 时误删 | 补回 import |
| 7 | `onCustomCommand` 返回类型不匹配 | Media3 1.5.x 要求 `ListenableFuture<SessionResult>` | 改为返回 `SessionResult(RESULT_SUCCESS)` |
| 8 | `No parameter named 'importState'` / `Unresolved glassCard` / `Unresolved animateFloat` | 参数名写错 + 漏 3 个 import | 全部修正 |

### 13.9 清理指引（以后不用了怎么删）

```bash
# 1. 项目与产物
rm -rf audiobook-app
# 2. Gradle 缓存（1.7G）
rm -rf ~/.gradle
# 3. 本项目装的 SDK 组件（保留别人的 android-9/android-14，别全删）
<ANDROID_SDK>/cmdline-tools/latest/bin/sdkmanager --sdk_root=<ANDROID_SDK> \
  --uninstall "platforms;android-35" "platforms;android-36" "build-tools;35.0.0" "platform-tools"
rm -rf <ANDROID_SDK>/cmdline-tools
# 4. JDK 17（只在没有别的东西用它时）
dnf remove java-17-openjdk java-17-openjdk-headless java-17-openjdk-devel
```

### 13.10 安全提醒

- 构建机密码**不在任何文件里**，只在会话内的临时文件中使用，用完即删；
- 强烈建议后续改用 SSH 公钥登录，并在云防火墙安全组把 22 端口限制到你的固定 IP；
- 本阶段为下载 APK 临时开过 18080 端口的 `python3 -m http.server`，**已关闭并删除目录**；
  APK 最终通过 SFTP 直接拉取到手机，未依赖任何公网开放端口。


---

## 14. 第 6A 阶段：扫描规则重写 + 章节标题清洗（2026-11-18）

> 这一节是最重要的产品规则。**改归书逻辑之前必须读完整节**，否则会把用户的书拆散。

### 14.1 用户的真实文件夹结构

```
有声小说/                     ← 只授权这一个
  斗破苍穹/                   ← 第一层子文件夹 = 一本书
    第1-500集/
      001.mp3
    第501-1000集/
      001.mp3
    番外/
      001.mp3
  斗罗大陆/
    全集/
      x.m4a
```

### 14.2 归书规则（用户拍板，不可擅改）

| # | 规则 | 理由 |
|---|---|---|
| 1 | 递归后完全不含音频的第一层子文件夹 → 跳过，不建空书 | 空书污染书架 |
| 2 | 递归含音频的第一层子文件夹 → **一律当书，永不穿透、永不拆分** | 一本书的音频可能分散在「第1-500集/第501-1000集/番外」多个子文件夹，拆开就废了 |
| 3 | 第一层子文件夹的直接子项里没有音频、且音频都在**孙目录以下**（路径 ≥4 段）→ 不当书，列为「疑似分组文件夹」并**响亮提示** | 宁可漏收 + 警告，不可错拆、错并 |
| 4 | 授权根下直接放的音频 → 单独成书（书名 = 根文件夹名） | 混合结构也要收齐 |
| 5 | 直接授权某本书自己的文件夹 → 根本身就是一本书 | 两种授权方式都支持 |

**段数速查**（以授权根为第 0 层）：

| 段数 | 例子 | 判定 |
|---|---|---|
| 1 | `a.mp3` | 根下直接音频 → 单独成书 |
| 2 | `书/第1集.mp3` | 书文件夹里直接放音频 → **正常书** |
| 3 | `书/卷1/第1集.mp3` | 书里再套一层子文件夹 → **正常书**（这是最常见的真实结构） |
| 4+ | `2024年/斗破/第1-500集/a.mp3` 中「2024年」这一层 | **疑似分组文件夹** → 跳过 + 警告 |

> 上一版实现把「3 段」也当成疑似中间层，导致用户真实的「书/第1-500集/001.mp3」**整本被跳过**。
> 是单元测试抓出来的，已修正为 ≥4 段才判定。

### 14.3 章节排序

先按子文件夹名自然排序，同文件夹内再按文件名自然排序，跨子文件夹连续编号。

实现：`ChapterOrdering`（纯函数）。把文件拼成「书内相对路径」（如 `第1-500集/001.mp3`），
按 `/` 分段逐段自然比较；根下直接放的音频（键就是文件名）排最前。

### 14.4 章节标题清洗（`TitleCleaner`）

处理顺序**不能换**：
1. 去扩展名（只认已知音频扩展名，防止把「第1.5集」的点删掉）
2. 删完整域名（连主体一起删，否则会残留 `abc123` 这种碎片）
3. 删被括号包住的整段（`【www.xx.com】`）
4. 删水印词（词库 `NOISE_WORDS`，想加词只改这里）
5. 删空括号壳（`【 】`）
6. 去「第1-500集」这类范围前缀（**必须在水印/分隔符归一之前**，否则 `-` 会先变空格）
7. 分隔符归一（`_`、`.`、`-`、连续空白 → 单空格）
8. 剥离与书名重复的前缀（大小写不敏感）；剥完为空则**保留原名**
9. 纯数字/第N集 → 「第 N 集」或「第 N 章 副标题」
10. 认不出 → 清洗后的原名；文件名本身为空 → 「未命名章节」

清洗前后对照（单元测试里逐条验过）：

| 原始文件名 | 清洗后 |
|---|---|
| `001.mp3` | 第 1 集 |
| `0003.flac` | 第 3 集 |
| `第001集.mp3` | 第 1 集 |
| `第12章 拔剑四顾心茫然.mp3` | 第 12 章 拔剑四顾心茫然 |
| `001_www.abc123.com.mp3` | 第 1 集 |
| `001_【www.abc123.com】精校版.mp3` | 第 1 集 |
| `001精校版.mp3` | 第 1 集 |
| `斗破苍穹_001.mp3`（书名=斗破苍穹） | 第 1 集 |
| `Harry_Potter_012.mp3`（书名=harry potter） | 第 12 集 |
| `斗破苍穹.mp3`（书名=斗破苍穹） | 斗破苍穹（剥完为空，保留原名） |
| `第1-500集 001 三年之约.mp3` | 第 1 集 三年之约 |
| `012 拔剑四顾心茫然.mp3` | 第 12 集 拔剑四顾心茫然 |
| `三年之约_上.mp3` | 三年之约 上 |
| `hello_world.mp3` | hello world |

### 14.5 重扫与进度重映射（用户特别强调的一条）

**进度跟文件走，不跟序号走。**

旧实现「重扫后序号不变」只在章节顺序没变时成立。一旦中间插入「番外」文件夹，序号全变，进度就错了。

现在：`ProgressRemapRules.remap()` 用**旧进度所在集的 URI**去新列表里找新序号：

| 场景 | 行为 |
|---|---|
| 顺序未变 | 序号不变，位置不变 |
| 中间插入「番外」 | 旧 index 1 → 新 index 2，位置（毫秒）不变 |
| 原文件被删 | 降级：落到同位置，位置清零，并打警告日志 |
| 新列表为空 | 返回 null，不动进度 |

### 14.6 界面文案

全 App 用户可见的「导入」→「扫描」：空书架文案、顶部按钮 contentDescription、通知标题、进度条文字、Snackbar。
代码内部类名（`LibraryImporter`、`ImportWorker`、`ImportState`）**不改**，改动面太大、收益为零。

新增：书架顶部「刷新」按钮 → 对已授权的所有根重新扫描（增量同步新增/删除文件，走同一个 WorkManager 队列，不阻塞界面）。

### 14.7 性能

- 扫描深度从 6 提到 **12** 层（真实有声书常见「书/卷/子卷」多层），超深会打警告日志而不是崩；
- 写库时每 **20 集**刷新一次进度并 `yield()` 让出协程，1000+ 集时界面/通知仍可刷新；
- 每本书的 `replaceTracks` 是单事务，不会出现半本书的状态。

### 14.8 已知限制（本期不做）

1. **分别授权嵌套的两个文件夹会得到重复书**：例如既授权了 `有声小说`（其下有 `斗破苍穹`），又单独授权了 `有声小说/斗破苍穹`。
   因为两本书的 `(sourceUri, folderPath)` 不同，数据库层面认作两本。**不做自动合并**（合并涉及进度/书签二选一，需要产品决策）。
2. **场景 B 下如果书内还有子文件夹**，路径形态与场景 A 无法区分，会被按「第一层子文件夹 = 一本书」处理。
   规避方法：场景 B 只用于「音频直接躺在该书文件夹里」的情况；有子文件夹时授权上一层即可。
3. 章节标题里的中文数字（「第十二集」）不识别，会保留原名——不在本期范围。

### 14.9 交付物

- 新增纯函数：`data/imports/BookGroupingRules.kt`、`ChapterOrdering.kt`、`TitleCleaner.kt`、`ProgressRemapRules.kt`
- 重写：`data/imports/AudioFileScanner.kt`（保留完整路径分段）、`data/imports/LibraryImporter.kt`（新归书 + 标题清洗 + 重映射 + 分批）
- 文案：`ui/components/EmptyShelf.kt`、`ui/shelf/ShelfScreen.kt`、`data/imports/ImportNotifications.kt`、`ImportWorker.kt`、`ShelfViewModel.kt`、`data/recommend/RecommenderRules.kt`
- 刷新入口：`BookDao.distinctSourceUris()`、`LibraryRepository.distinctSourceUris()`、`ShelfViewModel.refreshAll()`、顶部「刷新」按钮
- 单元测试：**54 条全过**（标题清洗 19 条 / 归书 15 条 / 排序 5 条 / 重映射 11 条 / 其余边界）
- 构建：`BUILD SUCCESSFUL in 1m 20s`；APK 24,653,477 字节，md5 `7e6211aaaa8f5b2746794f1e4c70f4a8`


---

## 15. 定稿（v1.0.0 封版，2026-11-18）

### 15.1 封版声明

**核心功能到此封版。** 除非用户主动提出新需求并单独立项（如 6B、7…），否则不再开新功能线。
后续只做三类工作：① 修 bug；② 用户明确要求的新阶段；③ 依赖安全更新。

### 15.2 版本历史

| 版本 | 阶段 | 内容 |
|---|---|---|
| 0.1.0 | 一 | 骨架：导入→归书→播放→续播（Room v1，三张表） |
| — | 二 | 视觉：海报墙、玻璃语言（Haze + backdrop）、迷你播放条 |
| — | 三 | 睡眠定时、跳过片头片尾（Room v2）、后台导入、搜索 |
| — | 四 | 本地推荐、收听统计、书签（Room v3） |
| 0.2.0 | 6A | 扫描规则重写、章节标题清洗、进度重映射 |
| **1.0.0** | 收尾 | 定版、release 签名、文档、去 deprecation |

### 15.3 架构总览（一分钟读懂）

```
app/src/main/java/com/local/audiobook/
├── AudiobookApp.kt          Application → 建 AppContainer
├── MainActivity.kt          唯一 Activity；把"进度写库"接到播放层
├── data/
│   ├── AppContainer.kt      手动 DI：DB / 仓库 / 导入器 / 偏好
│   ├── db/                  Room v3：books · tracks · playback_position
│   │                              · listening_stats · bookmarks
│   │                        Migrations.kt = MIGRATION_1_2 + MIGRATION_2_3
│   ├── imports/             ★ 归书规则全在这里，改前先读第 14 节
│   │   ├── AudioFileScanner.kt   递归扫描（保留完整路径分段，深度 12）
│   │   ├── BookGroupingRules.kt  【纯函数】第一层子文件夹 = 一本书
│   │   ├── ChapterOrdering.kt    【纯函数】子文件夹名→文件名 自然排序
│   │   ├── TitleCleaner.kt       【纯函数】脏文件名 → 「第 N 集」
│   │   ├── ProgressRemapRules.kt 【纯函数】重扫后按 URI 重映射进度
│   │   ├── NaturalSort.kt        【纯函数】"第2集" < "第10集"
│   │   ├── CoverGenerator.kt     内嵌封面 / 首字渐变封面
│   │   ├── LibraryImporter.kt    串起来：扫→归→排→清洗→写库
│   │   ├── ImportWorker.kt       WorkManager 前台作业
│   │   ├── ImportScheduler.kt    唯一任务名 + REPLACE 防抖
│   │   └── ImportNotifications.kt
│   ├── repo/                LibraryRepository / PlaybackRepository / InsightsRepository
│   ├── prefs/               DataStore：倍速记忆
│   ├── stats/               【纯函数】ListeningTimeRules / ListeningAggregator
│   ├── recommend/           【纯函数】RecommenderRules
│   └── bookmark/            【纯函数】BookmarkRules
├── playback/
│   ├── AudiobookPlayerService.kt  MediaSessionService（进度/定时/片头尾/统计）
│   ├── PlayerSession.kt           界面↔服务唯一桥梁（单例）
│   ├── PlayerBridge.kt            同进程状态总线（定时器 250ms 更新）
│   ├── PlaybackRules.kt           【纯函数】倍速/5秒写库/10分钟回退15秒
│   ├── SleepTimerRules.kt         【纯函数】倒计时/渐弱
│   ├── SleepTimerController.kt    协程驱动定时器
│   ├── SkipMarkerRules.kt         【纯函数】片头/片尾判断
│   └── ServiceCommands.kt         自定义命令（参数编码进命令名）
└── ui/
    ├── glass/               GlassTokens · GlassCard · HazeBackdrop · LiquidGlass
    ├── components/          MiniPlayerBar · RecommendCard · BookmarkMarkerTrack ·
    │                        CoverArt · FileImage · GlassIconButton · ThinProgress · EmptyShelf
    ├── shelf/               ShelfScreen · ShelfViewModel · ShelfSearch
    ├── player/              PlayerScreen · PlayerViewModel · SleepTimerSheet · SkipMarkerSheet · BookmarkSheet
    ├── nav/AppNavHost.kt
    └── theme/Theme.kt
```

**设计原则（六条，违反必被回滚）**
1. **纯函数先行**：所有规则先写成不碰 Android 的 object/函数，再接到 Android API 上。目前 100% 的关键规则都有对应单测。
2. **单模块分层**：一个人自用，不拆多模块；用包结构强制分层。
3. **迁移只加不删**：禁止 `fallbackToDestructiveMigration`。
4. **进度跟文件走**（第 14.5 节）：任何重排都必须重映射。
5. **降级不崩**：液态玻璃在 API<31 直接走 GlassCard；拿不到背景源也走 GlassCard。
6. **零联网**：没有任何网络代码。推荐、统计全部本地。

### 15.4 全部关键设计决策与理由（浓缩版）

| 决策 | 理由 |
|---|---|
| 单模块 | 自用小 App，多模块只会拖慢构建、增加认知负担 |
| Room 三张表起步 → 五张 | 书/集/进度是核心；统计与书签后加，各自独立表 |
| 进度写库放**服务**里 | 界面会被杀，服务不会；这是"杀 App 重开还能续播"的根本原因 |
| 续播：10 分钟回退 15 秒 | 长时间中断后直接续上容易"断片"，回退一点能接上下文 |
| 睡眠定时走**协程**不走 Handler | 暂停要冻结、恢复要继续，协程 `delay` + cancel 最自然 |
| 睡眠状态用**同进程内存总线**不走 Binder | 250ms 一次的状态更新，走 Binder 不值得 |
| 会话命令**参数编码进命令名** | Media3 的 `sendCustomCommand` 参数 Bundle 在部分版本会丢 |
| 片头片尾**固定档位** | 会话命令必须显式登记，自由输入无法穷举 |
| 后台导入用 **WorkManager** | 持久队列（进程被杀能重跑）+ 前台作业（不被掐）+ 唯一任务名（防抖） |
| Coil → FileImage | 本地小图不需要请求管线；少 700KB 依赖 |
| Haze 1.6.10 / backdrop 1.0.6 | 2.x 强制 Compose 1.12+Kotlin 2.4，升了整个工程会崩 |
| `compileSdk 36` | backdrop AAR 元数据强制要求；targetSdk 仍 35 |
| `-Xskip-metadata-version-check` | backdrop 是 Kotlin 2.3 编译的，需放行 |
| **6A 裁定一**：不含音频 → 跳过 | 空书污染书架 |
| **6A 裁定二**：含音频 → 永不穿透、永不拆分 | 一本书的音频可能分散在多个子文件夹，拆开就废了 |
| **6A 裁定三**：疑似中间层跳过 + **响亮警告** | "宁可漏收+警告，不可错拆、错并" |
| **≥4 段才判中间层**（教训） | 上一版按 ≥3 段判，把用户真实的「书/第1-500集/001.mp3」整本跳过了；是单测抓出来的 |
| 进度按 URI 重映射 | "重扫后序号不变"只在顺序没变时成立，插一个「番外」就全错 |
| release 关闭 lintVital | 2GiB 机器上 lint 会把 daemon OOM 掉 |

### 15.5 签名与定版

| 项 | 值 |
|---|---|
| 应用名 | 听书 |
| applicationId | `com.local.audiobook` |
| versionName / versionCode | **1.0.0 / 1** |
| minSdk / targetSdk / compileSdk | 26 / 35 / 36 |
| keystore | `签名库（本地）`（别名 `tingshu`，RSA 4096，有效期 36500 天） |
| 证书 SHA-256 | `7B:2D:AC:B3:83:25:D3:08:05:B1:68:EE:E6:E9:EC:AE:BC:5A:E4:CC:CC:DE:4B:AB:A6:15:73:91:C8:16:61:60` |
| 签名配置来源 | 项目根目录 `local-signing.properties`（**已 .gitignore**） |

> **keystore 密码不记录在本仓库任何文件里。** 生成命令见 `docs/USER-GUIDE.md` 第六节。
> **keystore 丢了就无法给已安装的 App 出升级包**，务必单独备份。

### 15.6 最终产物

| 变体 | 大小 | md5 |
|---|---|---|
| release | **16,893,002 字节（约 16.1 MiB）** | `c7e2cd07eb50bba0e61dd14c99f8b515` |
| debug | 24,658,340 字节 | —（调试用） |

构建命令与耗时：
```bash
./gradlew assembleDebug    # 约 60s
./gradlew assembleRelease  # 约 50s（增量）/ 首次约 7 分钟
```

### 15.7 deprecation 清理记录（防止误伤）

| 文件 | 改前 | 改后 |
|---|---|---|
| `ui/player/PlayerScreen.kt` | `import androidx.compose.material.icons.filled.FormatListBulleted` | `import androidx.compose.material.icons.automirrored.filled.FormatListBulleted` |
| 同上（2 处调用） | `Icons.Filled.FormatListBulleted` | `Icons.AutoMirrored.Filled.FormatListBulleted` |
| `ui/player/PlayerScreen.kt` | `import androidx.compose.material.icons.filled.ArrowBack` | `import androidx.compose.material.icons.automirrored.filled.ArrowBack` |
| 同上（1 处调用） | `Icons.Filled.ArrowBack` | `Icons.AutoMirrored.Filled.ArrowBack` |

只动这两个符号（都是"应随文字方向镜像"的图标）。改完 deprecation 警告数从 3 → **0**。
**没动**的图标：Search / Refresh / Add / MoreVert / Bookmark / NightsStay / SkipPrevious / SkipNext / Pause / PlayArrow（都不在弃用列表里）。

### 15.8 文档索引

| 文档 | 给谁看 |
|---|---|
| `docs/USER-GUIDE.md` | **给你自己看**：怎么用、数据在哪、怎么备份 |
| `docs/STAGE1/2/3/4/6A-CHECKLIST.md` | 各阶段的验收自查表 |
| `docs/STAGE5-CHECKLIST.md` | **最终全量回归清单** |
| `AGENTS.md`（本文件） | 给下一个接手的人/AI 看 |


---

## 16. 6B 阶段 · 喜马拉雅桥（运维与决策记录）

### 16.1 架构定死

**App 本体不内置任何登录 / 签名 / 爬虫。** 所有喜马拉雅交互走服务器上的桥：
`App ──HTTP+Bearer token──> 桥(FastAPI) ──限速+风控守护──> 喜马拉雅`

收益：签名算法变更只改桥，App 不动；风控策略集中一处；账号凭据永不进手机。

### 16.2 服务器上的东西（借住清单，清理时照此删）

| 组件 | 路径 | 说明 |
|---|---|---|
| 桥代码 + venv | `bridge 部署路径（本地）` | 约 70MB（含 venv） |
| Cookie（登录态） | `bridge 部署路径（本地）/data/cookies.json` | 权限 600，**绝不外传** |
| API token | `bridge 部署路径（本地）/data/<token文件>` | 权限 600，只显示一次 |
| 风控状态 | `bridge 部署路径（本地）/data/risk_state.json` | 暂停/拉黑状态，重启不自动恢复 |
| systemd unit | `/etc/systemd/system/ximalaya-bridge.service` | `Nice=10`、`MemoryMax=100M` |
| 端口 | **BRIDGE_PORT** | 需用户在云防火墙安全组手动放行 |

**不动的东西**：系统默认 python、alternatives、其他任何服务、防火墙。

### 16.3 风控纪律（写死在代码里）

1. 全局 ≤1 请求/秒，批量并发 1（`app/ratelimit.py`，所有上游请求必经）；
2. 网页搜索端点最多 3 次、间隔 ≥30 秒；连续失败 → **IP 级拉黑**；
3. 任何风控信号（`riskLevel`/`risk invalid`/`isNeedLogin`）→ **立即暂停** + 落盘；
4. 进程重启 **不自动恢复**，只有 `POST /api/risk/resume` 人工解除；
5. **不做任何自动重试 / 换参数试探 / 换 UA 绕过**。

**理由**：喜马拉雅风控是账号维度的。硬冲会把风控从 IP 级升级到账号级，封掉白金会员账号。

### 16.4 2026-11-18 的探测结论（复测前的基线）

| 端点 | 结果 |
|---|---|
| `www.ximalaya.com` 首页 | 200 |
| 网页搜索 `/revision/search/main`（直连 + 代理各一次） | `{"ret":200,"data":{"reason":"risk invalid","riskLevel":5}}` |
| 网页曲目列表 `getTracksList` | `{"ret":401,"isNeedLogin":true}` |
| 移动端专辑详情 `mobile.ximalaya.com/mobile-album/...` | **200，返回真实数据** |
| 网页专辑详情 | 200（接口通，测试 id 已下架） |

→ 结论：**搜索是当前最脆弱的端点**；详情走移动端可行；播放地址必须登录。

### 16.5 登录方式：浏览器代登录（2026-11-18 二次修正）

演进：扫码 → 粘贴 Cookie → **浏览器代登录**（最终）。
粘贴 Cookie 要用户自己开 F12 翻 cookie，步骤多、易错，改为由桥的浏览器代劳。

**实现**：桥在服务器上启动 headless chromium（复用已有
`.cache/ms-playwright/chromium-1254` 的 Chrome for Testing 158，不重复下载），
打开官方登录页；`/api/login/session/frame` 500ms 轮询把截图投给网页；
用户在截图上点、在输入框打字，桥代为在真实页面执行；
检测到 `1&_token` 等关键 cookie → 立即导出存盘（600 权限）→ 关闭浏览器。

**技术选型**：
- Playwright **async API** —— sync API 在 asyncio 事件循环里会直接抛
  `It looks like you are using Playwright Sync API inside the asyncio loop`；
- 不用 xvfb —— 省一个 X server 进程和一堆系统依赖，机器上已有现成 chrome 二进制。

**内存管理**：浏览器启动约 +200MB 系统内存（5 个子进程），关闭后全部回收；
桥进程本身 RSS 约 30MB，`MemoryMax=100M` 约束桥进程，chromium 是子进程、用完即杀。
实测：启动前 available 1636MB → 会话中 1587MB → 关闭后 1649MB。

**兜底**：`/login/cookies` 页面底部保留「手动粘贴 Cookie」入口。

**安全**：登录接口全部要求 Bearer token；页面只显示登录状态，永不显示 cookie 内容；
cookie 只在进程内存与 600 权限文件之间流动，不经任何 HTTP 响应回传。

### 16.6 未实跑清单（诚实标注）

- **`getAudioUrl` 从未成功过**：需要登录 + 会员权益，本次交付时桥处于未登录态。
- **移动端搜索**：未验证是否可用（需要登录态 + 有限次数）。
- 所有"能不能用"的结论要等用户登录后的复测矩阵。


---

## 17. 6B 架构反转：App 直连（2026-11-18，最终版）

> **本节覆盖此前所有"走服务器桥"的设计。** 桥保留为休眠备胎，App 不依赖它。

### 17.1 反转前后

| | 反转前（16 节） | 反转后（本节） |
|---|---|---|
| 网络路径 | App → 我的服务器桥 → 喜马拉雅 | **App 直连喜马拉雅** |
| 登录 | 桥的浏览器代登录 | **App 内嵌 WebView 官方登录** |
| 凭证存放 | 服务器文件（600） | **App 内 EncryptedSharedPreferences（Android Keystore）** |
| 签名 | 服务器 Python | **App 内 XmSignEngine（隔离单文件）** |
| 服务器依赖 | 必需 | **无。桥已停用（保留，不删除）** |

**为什么不删桥**：它是已验证可用的备用通道。若某天 App 直连彻底失效、而桥的浏览器会话还能用，
可以临时切回去。但**App 代码里没有任何桥的引用**，删掉桥也不影响 App。

### 17.2 App 内模块结构（新增部分）

```
data/ximalaya/
├── XimalayaSession.kt          纯函数：cookie 解析/登录判定/过滤/请求头/失效判定
├── XimalayaResult.kt           纯函数：错误分类（未登录/风控/接口变更/加密音频）
├── RequestThrottle.kt          纯函数：<=1 请求/秒 + 并发 1（时钟可注入，可单测）
├── SessionStore.kt             EncryptedSharedPreferences 存储（日志只打字段名）
├── XimalayaLoginController.kt  登录会话管理（读/写 CookieManager、退出登录）
├── XimalayaApiClient.kt        三动作直连（限速、分类、**不重试**）
└── engine/
    └── XmSignEngine.kt         签名引擎【隔离模块 · 单文件】

ui/ximalaya/
├── XimalayaLoginWebView.kt     内嵌官方登录页（Compose AndroidView）
├── XimalayaViewModel.kt        在线模块状态（失败不影响本地书架）
└── XimalayaScreen.kt           搜专辑 / 专辑详情
```

### 17.3 签名引擎隔离策略（重要）

**所有签名逻辑只在 `engine/XmSignEngine.kt` 这一个文件里。** 约定：

1. 该文件**不碰网络、不碰 Context、不碰登录状态、不打日志**；
2. 外部只能通过 `XmSignEngine.sign(path, params, cookies, nowMs)` 拿到签名参数；
3. `XimalayaApiClient` 是唯一调用方，别处禁止自己拼 `xm-sign`；
4. **官方改签名时，修复路径 = 只改这一个文件 + 重新打包**，其它代码一行不动；
5. 引擎内部用 `XimalayaSessionRulesMirror.KEY_TOKEN` 镜像常量，避免反向依赖业务包。

参考：RSSHub 的 ximalaya 路由（MIT），仅借鉴"参数排序 + 时间戳 + 摘要"的结构，代码为本项目重写。
**已实现的是结构正确的通用版本**；真机若返回签名错误，按第 4 条只改引擎。

### 17.4 风控纪律（App 内，与桥同源）

| 规则 | 实现位置 |
|---|---|
| 全局 <=1 请求/秒 | `RequestThrottle.waitMs()` / `markRequest()` |
| 批量并发 1 | `RequestThrottle.tryAcquire()` / `release()` |
| **失败不重试** | `XimalayaApiClient.request()` 单次请求，无重试循环 |
| 三种失败文案严格区分 | `ErrorKind.userMessage()` |
| 付费加密音频明确不支持 | `ErrorClassifier.isEncryptedAudio()` → `ENCRYPTED_AUDIO` |

### 17.5 降级铁律

在线模块的任何失败（未登录 / 无网 / 风控 / 接口变更）**只影响在线页本身**：
本地书架、播放、进度、书签、统计、推荐、睡眠定时、片头片尾 —— **全部零影响**。

技术上保证的方式：
- `XimalayaApiClient` 只在 `ui/ximalaya/*` 里被使用；
- 本地模块（`data/imports`、`playback`、`ui/shelf`、`ui/player`）没有任何 `data/ximalaya` 的 import。

### 17.6 登录（ILogin 的对应实现）

- WebView 加载 **官方登录页**（`passport.ximalaya.com`），移动 UA、启用 JS/DOM storage；
- **不注入、不代填、不拦截** —— 扫码/短信/滑块都由官方页面自己完成；
- 登录成功判定：轮询 `CookieManager`，`XimalayaSessionRules.isLoggedIn()`；
- 成功后导出 `www.ximalaya.com` / `m.ximalaya.com` / `passport.ximalaya.com` 三个子域 cookie
  → `filterForStorage()` 只留关键字段 → `SessionStore.save()`（加密）；
- **日志永不打印 cookie 值**，只打印字段名；
- 会话失效（401 / isNeedLogin）→ 提示「未登录或登录已过期，去登录」→ 一键重开登录页；
- 「退出登录」清 SessionStore + CookieManager；
- WebView 页面销毁时 `destroy()`。

### 17.7 本轮未实跑项（诚实标注）

| 项 | 状态 |
|---|---|
| 真实登录（扫码/短信） | **未实跑** —— 构建机上无法扫码；需用户真机测试 |
| 网页搜索接口 | **未实跑**（无登录态，且基线已知 riskLevel 5） |
| 移动端专辑详情 | **未实跑** |
| 曲目列表 | **未实跑** |
| 播放地址（含签名） | **未实跑** —— 签名是结构正确的通用实现，真机可能被拒 |
| 发现页推荐流 | **未实现** —— 推荐流签名门槛高，本轮降级为「搜索 + 专辑详情」，在交付说明中写明 |

### 17.8 本轮构建记录

| 项 | 值 |
|---|---|
| 版本 | versionCode **2** / versionName **1.1.0** |
| debug 构建 | `BUILD SUCCESSFUL in 1m 39s` |
| release 构建 | `BUILD SUCCESSFUL in 2m 16s` |
| release APK | **17,646,894 字节（约 16.8 MiB）**，md5 `22c81230ba817df59ed560712258a701` |
| 签名 | CN=TingShu，SHA-256 `7B:2D:AC:B3:…:61:60`（与 1.0.0 同一签名，可覆盖升级） |
| 新增权限 | INTERNET、ACCESS_NETWORK_STATE |
| 新增依赖 | `androidx.security:security-crypto:1.1.0-alpha06` （EncryptedSharedPreferences） |

**构建期间的两个坑**（记录下来防止重复踩）：
1. **OOM**：默认 `-Xmx1200m` + `kotlin.daemon -Xmx1024m` 在这台 3.5GB/2核机器上会被 OOM killer 杀掉
   （dmesg 有 `Killed process (java) anon-rss:2048152kB`）。已降到 `1024m` + `768m`；
2. **构建期间停掉桥服务**释放约 55MB，构建完再 `systemctl start ximalaya-bridge` 恢复。


---

## 18. 6B.2：发现页 + 搜索降级 + WebView 修复（2026-11-18）

### 18.1 接口情报（重要，本轮实测）

| 接口 | 状态 | 说明 |
|---|---|---|
| `/revision/search/main`（网页搜索） | ❌ **已封** | `riskLevel: 5`，登录不解 |
| 移动端搜索 | ❌ 403 | — |
| 移动端专辑详情 `mobile.ximalaya.com/mobile-album` | ⚠️ **已收紧** | 从免登录变为 `ret:50 请登录` |
| **`/revision/category/v2/allCategory`** | ✅ 匿名可用 | 浏览器分类页真实调用的接口，返回 18 个分类 |
| **`/revision/category/v2/albums`** | ✅ 匿名可用 | 支持 `categoryId` + `pageNum` + `pageSize` + `sort=1`（播放量热排） |
| `queryCategoryPageAlbums?category=youshengshu` | ✅ 匿名可用 | 用户情报验证通过，但 `v2/albums` 更通用（带 categoryId），故选 v2 |

**结论**：详情/曲目/播放必须带用户登录 Cookie（6B 已实现）；浏览走 `v2/albums`。

### 18.2 分类码（全部来自官方接口，未硬编码未验证的码）

来源：`https://www.ximalaya.com/revision/category/v2/allCategory` → 返回 18 个分类：

```
id=2 music / id=3 book / id=4 entertainment / id=5 train / id=6 kid
id=8 finance / id=9 culture / id=12 comic / id=13 chair / id=15 radioplay
id=1001 audio-book / id=1002 humanities-sinology ...
```

本 App 只保留 6 个「对有声书用户有意义」且已用 `v2/albums?categoryId=` 实测有数据的：

| id | key | 显示名 | 实测 |
|---|---|---|---|
| 3 | book | 有声书 | ✅ 首条「蛊真人」 |
| 9 | culture | 人文国学 | ✅ 首条「明朝那些事儿」 |
| 6 | kid | 儿童 | ✅ 首条「神探迈克狐」 |
| 1001 | audio-book | 音频书 | ✅ 首条「哈利·波特 1-7 部」 |
| 2 | music | 音乐 | ✅ |
| 4 | entertainment | 娱乐 | ✅ |

运行时还有 `CategoryCatalog` 做**探测缓存**：先拉官方分类表，再逐个用 `v2/albums?categoryId=N&pageSize=1` 验证有数据，验证通过的才进候选池——官方改分类表也不会崩。

### 18.3 发现页（核心）

**随机机制**：分类 × sort=1 热门 × 随机页码

```
1. 随机选一个已验证分类
2. 取 1 条拿 total
3. DiscoverRules.randomPage(total) 在 [1, ceil(total/pageSize)] 内随机
4. 取该页 12 张卡片
```

- **深页可用**：实测 `page=1000` 正常返回，所以能抽到很久以前的专辑；
- **刷新三语义**：冷启动 `init` 抽一次 / 下拉刷新 / 「换一批」——全部重新抽，**不缓存**；
- 卡片：封面（`RemoteCover` 带磁盘缓存）+ 标题 + 播放量（`2887万播放` 格式）；
- 点卡片 → 专辑详情（带登录 Cookie 直连）。

### 18.4 搜索降级为 C 方案

搜索接口封死 → UI 上**不留死功能**，改为底部「粘贴专辑链接或专辑 ID 直达」：

- 支持 `/album/123456`、`?albumId=123`、纯数字、App 分享的整段文字；
- 单集链接（`/sound/xxx`）会提示「请改用专辑链接」；
- 解析逻辑在 `XimalayaLinkParser`（移植自服务器桥的 parse-link）。

### 18.5 WebView 重叠修复

| 猜测 | 处理 |
|---|---|
| 我们给 WebView 套了固定高度/padding | 排查：只有 `Modifier.weight(1f)`，没有固定高度 → **不是原因** |
| `windowSoftInputMode` 不对 | **改成 `adjustResize`**（原为默认 `adjustPan`，输入法弹起会把整页顶上去，官方 fixed 浮层因此错位） |
| 强制移动 UA 导致官方页面走另一套布局 | **移除自定义 UA**，用 WebView 默认 |

> 结论：**先删我们的自定义干预**（UA、以及确认没有额外 padding），补上 `adjustResize`。
> **尚未真机验证**——需要用户截图复验（见 STAGE6B2-CHECKLIST D 段）。

### 18.6 本轮构建

| 项 | 值 |
|---|---|
| 版本 | versionCode **3** / versionName **1.2.0** |
| debug | `BUILD SUCCESSFUL in 57s` |
| release | `BUILD SUCCESSFUL in 1m 26s` |
| release APK | **17,663,298 字节（约 16.8 MiB）**，md5 `375681cfbd63a81b9151bdade442aa5e` |
| 签名 | CN=TingShu（**新密码轮换后**），SHA-256 `7B:2D:AC:B3:…:61:60`，可覆盖升级 1.1.0 |

### 18.7 keystore 备份登记

| 项 | 值 |
|---|---|
| 主库 | `keystore/签名库（本地）` |
| 密码文件 | `签名库/密码文件（本地）`（600，**内容不记录于任何文档**） |
| 备份库 | `backups/签名库（本地）`（600） |
| 备份 md5 | `ddef2dc948c23c5f3af1c5336f860383` |
| 备份日期 | 2026-11-18 |
| 旧密码备份 | **已删除**（`签名库（本地）.bak.20261118093846`，删除前 keytool 验证新库 rc=0） |
| 手机副本 | `artifacts/签名库（本地）` |

> **App 永久自用不发版，用户侧不再接触 jks；以后每次构建由我维护备份。**

### 18.8 未实跑项

| 项 | 状态 |
|---|---|
| 发现页真实数据渲染 | **未实跑**（构建机无真机） |
| 分类探测缓存真实路径 | 部分实测（分类接口已在服务器 curl 验证，App 内未跑） |
| WebView 重叠修复效果 | **未验证**，需用户截图复验 |
| 专辑详情（登录 Cookie） | **未实跑** |
| 播放地址 / 签名 | **未实跑** |

---

## 19. 附录：书源设计图纸内化（2026-11-21 收录）

> 图纸来源：eprendre/tingshu（「我的听书」，已停止维护）的 CustomSources/TingShu.kt（265 行）。
> **纪律：该仓库无 LICENSE，只读设计思想，一行代码不抄。** 离线存档：`artifacts/tingshu-master.zip`（49.81MB）与 `TingShu.kt.原始参考.txt`，仓库删了也能查。

### 19.1 核心抽象：源 = 三动作 + 能力声明

TingShu 抽象基类只让每个书源回答三类问题，这个切分方式值得作为我们接口设计的对照：
1. **我是谁**：getSourceId()（UUID，全局唯一）/ getUrl() / getName() / getDesc()
2. **三动作**：search(keywords, page) → (书列表, 最大页数)；getBookDetailInfo(bookUrl, loadEpisodes, loadFullPages) → 详情+章节；getAudioUrlExtractor() → 播放地址提取器
3. **能力开关**（UI 据此渲染，不写死）：isSearchable / isDiscoverable / isCacheable / isWebViewNotRequired（无 WebView 的设备如手表能否用此源）/ isWebViewCompatible

**映射到本项目**：
- ximalaya-bridge 的 api.py 就是服务端形态的「三动作」，STAGE6B 发现页消费它——分层已经对齐，方向正确
- 值得吸收：bridge 接口响应可带 capabilities 字段（searchable / cacheable / needs_webview），App 按能力渲染，将来加数据源不用改 UI 判断逻辑
- search 返回 maxPage 来判断有无下一页——分页约定简单可靠，发现页分页已在用同思路
- getBookDetailInfo 的 loadEpisodes / loadFullPages 惰性参数：列表信息够就不二次拉取，章节按需翻页——发现页详情可参考，省请求

### 19.2 五级音频地址提取器：按站点难度分级

AudioUrlExtractor 家族分五级：直链 → HTML 解析 → JSON → 自定义处理 → WebView 嗅探。
- **分级思想**：先试便宜的（直链），逐级加价，最后才动 WebView。我们播放地址解析（当前未实跑项）照此排序实现
- **我们的对应**：ximalaya 官方接口+签名（bridge 的 upstream.py）相当于最高优先的「官方 API 级」；将来若加任何网页源，按级递进，不许一上来就 WebView
- **头部纪律（原作者注释里的血泪）**：AudioUrlExtraHeaders / CoverUrlExtraHeaders 的实现必须严格按 URL 匹配才加 header，不匹配必须原样返回——否则会污染其他源的请求。这条写进 bridge 的 header 处理纪律：按 host 精确匹配，默认不动

### 19.3 登录 / 风控 / 回调 / 配置：与 bridge 现状一一对应

| 图纸接口 | 思想 | 我们的对应 |
|---|---|---|
| ILogin | WebView 开官方页登录，前提是站点 Cookie 够长效 | browser_login.py 同思想且更进一步：浏览器登录、App 不碰密码 |
| ISearchVerification | 验证码中断→人工过→延迟恢复；能用 cookie 判断已验证就跳过 | risk.py + ratelimit.py 同思想；可吸收「cookie 判已验证」优化与毫秒级延迟防冲突 |
| IPlaybackStateCallback | playing / paused / error / stopped 四态回调 | PlayerSession 的 StateFlow 已对齐，保持四态语义 |
| ConfigurableSource | 源设置项 Text/Switch/Select/MultiSelect，key 命名空间 `${sourceId}.${key}` | 将来做服务器/源配置页时抄命名空间纪律，防 key 冲突 |

### 19.4 FAQ 血泪教训（原仓库的死因就是我们的护栏）

1. 「不要认为这个 app 可以播放所有收费的资源」→ 我们边界：只有用户自己会员账号能听的才做，聚合收费内容不做
2. 「部分源服务器在国外」→ 超时要短、失败要快，发现页保留离线缓存兜底
3. 「更新后新源要手动勾选」→ 数据源变更必须显式开关，不静默启用
4. **死因**：聚合免费站的网页接口，站点一改版全灭，追不动就弃坑 → 印证 6B 决策：抓取逻辑放 bridge 不进 App，直连官方接口；bridge 挂了本地功能照常（STAGE6B2 复测项 A4 飞行模式正是护栏验收）

### 19.5 苹果化路线指针

- 四路线方案集：`artifacts/听书苹果化-方案集v1.md`（A macOS 直转 1–2 周 / B KMP+SwiftUI 4–6 周·推荐 / C Compose MP 3–5 周 / D Flutter 兜底 6–8 周）
- 若立项 iOS：本节 19.1–19.3 的抽象就是 Swift/KMP 侧 protocol 清单的底稿；决策树 A→B→C→D，PoC 口径=真机出声

### 19.6 clean-room 隔离墙（法律席 2026-11-21 成文，三条硬规则）
1. **写码人唯一合法参考入口 = 本节 §19**；写 KMP/Swift 代码期间不得阅读 tingshu-ref 源码与 ZIP 内容。
2. tingshu-ref 与 ZIP 仅限「思想等价性检查者」访问，检查者与写码人角色分离；lead 兼双角色时，写码期间自我回避，检查结论落盘。
3. 隔离副本禁入主工程、禁入任何 git 仓库，编译产物不出该目录；执行日志中 jvmToolchain(18)→17 改动仅存于隔离副本构建脚本，不构成抄码。
4. 一切书源/接口定义以本节思想**重述**表达；评审抽查到符号层（原名、近改名、复制注释、魔数、端点细节）即违规。

### 19.7 安卓迁移策略（架构席 C4，2026-11-21 落纸）
1. KMP 工程独立为 shared/，安卓壳继续单模块——「数据层被第二个 App 复用」条款触发，不违反封版（苹果化为用户主动立项）。
2. 迁移顺序：data/ximalaya 纯逻辑（SessionRules / Result / RequestThrottle / ErrorClassifier / XmSignEngine）逐文件搬 package 进 commonMain；搬一个删一个，**禁双实现漂移**。
3. 回退路径 = git revert 单提交；本地模块（db/imports/playback）不动。
4. 签名引擎**两处**同步纪律：commonMain ↔ bridge upstream.py，改一处同步另一处（迁移窗口内 App 内 XmSignEngine 随「搬一个删一个」消失，终态两处）。
