# 评审意见 · reviewer-ios（iOS工程席）2026-11-21
裁决：**带条件通过**（iOS 映射五项全成立、周1 spike 本机可验；硬伤=无 Mac 且「降级 C」兜底治不了它）
## 五项映射核验（全成立）
1. AVPlayer 后台出声：头号死因=漏设 category（默认 .soloAmbient 后台必静音，开 Background Modes 也救不回）；必须 .playback + setActive(true) + UIBackgroundModes=[audio]；验收含 interruptionNotification（.shouldResume 恢复）+ routeChange（拔耳机暂停）；章节连播用 AVQueuePlayer 预插下一章防 session 失活挂起；头部纪律落 iOS=AVURLAssetHTTPHeaderFieldsKey 按 host 精确注入
2. 锁屏控制：MPRemoteCommandCenter 四命令 + MPNowPlayingInfoCenter 同帧维护（暂停 rate=0 防进度飘）
3. WKWebView：全链路主线程；嗅探正路=WKUserScript documentStart 注入 hook audio/video/XHR/fetch + WKScriptMessageHandler 收 URL（非 evaluateJavaScript 轮询）；实例强引用
4. Cookie：登录用 WKWebView 默认持久 dataStore（SFSafariViewController 禁用——cookie 沙箱独立）；登录后显式拷 httpCookieStore → HTTPCookieStorage.shared（唯一稳路径）；Ktor Darwin 引擎零配置直通
5. UIBackgroundModes audio：一行配置，验收必须真机（模拟器后台打断是假象）
## KMP 坑与 spike 现实性
- hierarchy template（手写 dependsOn 必错）/ ObjC 泛型桥接（共享接口别嵌深泛型）/ Flow 消费难（IPlaybackStateCallback 四态回调=现成桥，免引 SKIE）/ freeze 坑已成历史
- 周1 spike=JVM 命令行 search，本机成立；clean-room 重写 search+签名约 2–3 天；首跑拉几百 MB K/N 依赖，先预热一次
- **加分**：K/N 交叉编译 iosArm64 在 Linux 主机可跑，framework 产出不需要 Xcode；要 Xcode 的是 SwiftUI 编译/打包/模拟器/签名/TestFlight
## 无 Mac 的解法（最重一条）
- 降级 C 治不了病（Compose iOS 同样要 Xcode）——「周3 降级 C」兜底条款删除
- macOS 构建通道三选一，**周2 末前锁定**：① GitHub Actions macOS runner（公开仓库免费；私有 2000 min/月≈200 真实分钟，够 xcodebuild+fastlane pilot）② 云 Mac（MacinCloud ~$20/月起、MacStadium）③ 借 Mac 只借构建窗口
- TestFlight 需 $99/年；纯自用=免费 Apple ID + Xcode 直装（7 天重签），周6 改为「直装+重签说明」
## 四条放行条件
1. 周2 末锁定 macOS 通道（三选一），未锁定则周3 顺延 2. 周3 闸口口径不动摇（后台出声三件套齐）3. WKWebView @MainActor+强引用+嗅探走注入+Cookie 显式拷贝 4. TestFlight 立项前确认 $99 账号
