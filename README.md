# 听书 · iOS

「我的听书」的 iOS 版实现：Kotlin Multiplatform 核心 + SwiftUI 壳。

上游参考项目 [eprendre/tingshu](https://github.com/eprendre/tingshu)（Android 版，已停止维护，无 LICENSE）。
本仓库**不包含**上游任何代码，是独立重写：引擎走喜马拉雅官方接口，不搬运第三方源的解析逻辑。

---

## 这是什么

一个 iOS 听书 App：

- **搜索**：走官方接口 + 浏览器通道两路兜底
- **播放**：AVQueuePlayer，后台音频，锁屏控制
- **登录**：内置 WebView 走喜马拉雅官方登录页，cookie 自动同步
- **进度**：每 5 秒落盘，退出后接着听
- **收藏 / 最近播放**：本地存储

## 为什么不用第三方书源

上游 App 靠抓第三方听书站点的 HTML 工作。实测 24 个源站里 13 个已死，剩下的多数加了反爬或登录墙。
这条路不可持续——上游作者自己就是因为追不上站点改版才停更的。

本项目改为直连官方接口，并对官方接口的风控做了分级处理：
搜索被拦时降级给提示、不硬冲；播放地址每次重新提取，不缓存过期地址。

## 项目结构

```
shared/                     Kotlin Multiplatform 核心
├── src/commonMain/         纯 Kotlin，无平台依赖（18 个文件）
│   ├── core/Contract.kt     接口契约：SourceActions / Book / Episode / SourceErrors
│   ├── core/engine/         三动作编排：搜索、详情、取播放地址
│   ├── core/net/            JsonFetcher 接口（平台无关）
│   └── data/ximalaya/       喜马拉雅专属：签名、链接解析、限速、会话规则
├── src/jvmMain/            JVM 实现（Ktor CIO）+ CLI
├── src/iosMain/            iOS 实现（Ktor Darwin）+ Swift 门面
└── src/jvmTest/            单测（纯函数覆盖）

ios/                        SwiftUI 壳
├── Tingshu.xcodeproj
└── ios-shell/
    ├── Engine/Actual/       平台适配，恰好 5 个文件（白名单强制）
    ├── Engine/Bridge/       WebView 搜索桥
    ├── Storage/             本地持久化 + 布局常量
    ├── Shared/              SharedBridge.swift（唯一允许 import shared 的文件）
    └── Views/               书架 / 播放 / 设置 / 浏览器
```

## 工程约束

壳内 Swift 有硬性白名单，`ios/check-whitelist.sh` 机械校验：

- 只有 `Engine/Actual/BackgroundSession.swift` 允许 import Foundation/AVFoundation 之外的东西
- 只有 `SharedBridge.swift` 允许 `import shared`
- `Engine/Actual/` 必须恰好 5 个文件
- Swift 内不出现 `ktor` / `ksoup` 字样（引擎栈不下放到壳）
- `Info.plist` 的 `UIBackgroundModes=audio` 不能丢

本地自检：

```bash
cd ios && ./check-whitelist.sh
```

## 构建

需要 macOS + Xcode。

```bash
# 1. 编译 Kotlin framework
cd shared
./gradlew linkReleaseFrameworkIosArm64

# 2. 编译 iOS App
cd ../ios
xcodebuild -project Tingshu.xcodeproj -scheme Tingshu \
  -configuration Release -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  -archivePath build/Tingshu.xcarchive archive \
  CODE_SIGNING_ALLOWED=NO
```

Linux 上可以编译 klib（`compileKotlinIosArm64`），但 **link framework 只能 macOS** —— Apple 链接器只随 macOS 发行包分发。

## CI

`.github/workflows/` 五个任务：

| 任务 | 平台 | 作用 |
|---|---|---|
| `jvm-tests` | ubuntu | KMP 单测 |
| `ios-klib` | ubuntu | iOS 编译验证（不出产物） |
| `ios-framework` | ubuntu | 回归哨兵：Linux link 必然失败，红=禁令仍在 |
| `ios-whitelist` | ubuntu | 壳侧白名单 |
| `archive-ipa` | **macos** | 出未签名 IPA，自动发布到 Release |

`archive-ipa` 对 `linkReleaseFrameworkIosArm64 SKIPPED` 有任务级断言——
Kotlin/Native 在无 Xcode 的机器上会静默跳过 link，BUILD SUCCESSFUL 但零产物。这个断言防的就是这种假绿。

## 已知限制

- 未登录时专辑接口返回 `status=76`，搜不到数据
- 搜索接口风控严格（实测 `riskLevel=5`），经常降级
- 不接付费内容：只走公开官方接口
- 播放地址有时效，不缓存

## 许可

本仓库代码为独立实现。上游 `eprendre/tingshu` 无 LICENSE 文件，本项目未使用其任何代码。

内部参考过 [RSSHub](https://github.com/DIYgod/RSSHub)（MIT）的喜马拉雅路由思路：参数排序 + 时间戳 + 摘要的结构，代码为本项目重写。
