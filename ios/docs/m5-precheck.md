# m5-precheck.md — 周3 闸口（M3 真机后台出声）前置清单
> T05 产出（task-8 · dev-ios 认领细化，2026-11-21）。闸口唯一口径 = 验收表 M3：
> 搜「三体」→ 首本 → 首集，后台锁屏播放 ≥30s，timeControlStatus=playing + 人耳/录屏双证，
> 录屏存 artifacts/。

## A. 通道与环境（周2末前锁定，风险登记册 #5）
- [ ] macOS 编译通道三选一落定：GH Actions macOS runner / 云 Mac（MacinCloud ~$20·月）/ 借机构建窗口
- [ ] K/N iosArm64 framework 产物就位：shared/build/bin/ios/ReleaseFramework/shared.framework
      （工程 FRAMEWORK_SEARCH_PATHS 已指向 $(PROJECT_DIR)/../shared/...）
- [ ] 签名路径确认：免费个人签（真机跑通即可）或 $99 账号（TestFlight），DEVELOPMENT_TEAM 留空待填
- [ ] 真机 iPhone（部署目标 iOS 16.0）+ 调试通道可用

## B. 三件套（后台静音的头号死因）
- [ ] .playback category 设置成功、无 error 回调（失败会 debugPrint 浮出）
- [ ] setActive(true) 在每次播放前调用（PlayerView stub 已接 BackgroundSession.activateForPlayback）
- [ ] Info.plist UIBackgroundModes=[audio] 在位（构建产物里复查未被打包工具剔除）
- [ ] 打断恢复：interruptionNotification → .shouldResume → resumeAfterInterruption（真身已落：队列非空即续播；勾选待真机验）
- [ ] 拔耳机暂停：routeChange .oldDeviceUnavailable → pause（已写，真机验）

## C. 播放链路（壳 ↔ 框架对接）
- [ ] SharedBridge.extractStub → 框架真 extract(url, 15s) 接通，返回 ExtractedAudio(url, headers)
- [ ] headers 注入 AVURLAsset options["AVURLAssetHTTPHeaderFieldsKey"]，原样注入不加工
      （共享核心已按 host 精确匹配过滤，壳侧不得二次处理）
- [ ] AVQueuePlayer 预插下一章（Player.enqueueNext），章节间隙场景实测不挂起
- [ ] PlaybackStateSink 四态回调接进 PlayerView 状态文案
- [ ] 命名对拍：Book / BookDetail / Episode / ExtractedAudio / SourceErrors 的 ObjC 桥接扁平类名
      以框架首产物为准，回填 SharedBridge

## D. 闸口当天（go/no-go）
- [ ] sh check-whitelist.sh → PASS（禁词0 / import 合规 / Actual=5 / 三件套+后台模式在位）
- [ ] 真机锁屏播放持续 ≥30s（timeControlStatus=playing）
- [ ] 人耳 + 录屏双证；录屏落 artifacts/
- [ ] 结论写回 docs/苹果化-验收表v1.md M3 行 + docs/苹果化-执行日志.md；不过闸无兜底降级条款

## E. T05.1 增量（2026-11-21 · dev-ios · 纯代码不卡 Mac）
- sniff 真身落盘（WebViewSniffer）：五路 hook（media src 原型拦截 / loadstart 捕获 / DOMContentLoaded 扫描 / XHR open / fetch+content-type confirm 通道）；15s 超时不猜；teardown 防引用环；busy/badURL/timeout/pageFailed 四态错误
- 打断恢复真身落盘：resumeStub → resumeAfterInterruption（队列非空即续播），BackgroundSession 调用点同步
- extract 真调用仍等 shared framework（板上遗留，不阻塞本清单 A/B/D）

## F. Mac 窗口最小执行序（framework 一 link 即按序走，窗口时间压最短）
> 现状：CI 已实证 iosArm64 klib 编译（ios-klib 工件）；framework link 需 Mac。
> 路径勘误（G 段）：产物目录 = build/bin/iosArm64/ReleaseFramework/（不是 ios/）。

1. shared 工程：printf 两个开关（kotlin.native.ignoreDisabledTargets=true /
   kotlin.native.enableKlibsCrossCompilation=true）→ ./gradlew linkReleaseFrameworkIosArm64
   → 产物 build/bin/iosArm64/ReleaseFramework/shared.framework
2. 框架头对拍：Book/BookDetail/Episode/SearchResult/ExtractedAudio/SourceErrors 桥接类名 +
   CookieProvider 协议签名 → 回填 SharedBridge / 启用 CookieProviderStub
3. SharedBridge.extractStub → 真身（唯一代码改动点）：extract(url, 15s) 返回
   ExtractedAudio(url, headers, expiresInSeconds)；错误族走 message(for:)；壳内其余文件零改动
4. xcodebuild -project Tingshu.xcodeproj -scheme Tingshu -configuration Release
   -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build 过编译 → 未签 IPA → 全能签装机
5. 真机顺序：启动 → 播放 Tab（三件套激活无 error 打印）→ M3 最小用例（搜「三体」→ 首本 → 首集）
   → 锁屏 ≥30s → timeControlStatus=playing + 人耳/录屏双证 → 录屏落 artifacts/
6. 收尾：check-whitelist.sh 复跑 PASS → 验收表 M3 行 + 执行日志回写 → go/no-go 上报

## G. Mac 窗口前对齐（2026-11-22 · dev-ios）
- FRAMEWORK_SEARCH_PATHS 已改：../shared/build/bin/iosArm64/ReleaseFramework（原 ios/ 少段）
- klib 与壳无关：Xcode 只吃 .framework，CI klib 工件不进 FRAMEWORK_SEARCH_PATHS
- framework 命名依赖 dev-core 一行：iosArm64 target binaries.framework.baseName = "shared"
  （rootProject.name=shared-core，缺这行产物=shared-core.framework / import shared_core，
  契约 v1.1 产物名=shared 将不成立）——已报 dev-core
- SharedBridge 按 v1.1 对照表全量补齐：12 增量字段消费 + Network.reason 改名 +
  NSArray 防御转换 + 桥接纪律注释；CookieProviderStub 落盘（匿名预检路径，M4 启用）

## H. M4 预置约束（lead 2026-11-22 传达 · 架构席条款）
- CookieProvider 真身（M4 启用）：refresh() 必须复用 WebViewContainer.actual（登录/过码同一容器），
  禁止为刷新流程加第六触点；真身替换只动 CookieStore.actual 与 SharedBridge，五触点不变量不动
- baseName 已拍板 = "shared"（lead 落 shared 工程 build.gradle.kts）：壳侧 import shared 维持不变，
  pbxproj 引用 shared.framework 与产物名一致，无需再动
