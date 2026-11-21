# Mac 窗口执行单（一页版 · 04-26 定稿）
> 前置：macOS + Xcode 15+ + JDK17。目标 = unsigned IPA，用户全能签自签装机。
> klib 已在 CI 产出（工件 ios-klib，112KB）；Mac 只做 link + archive 两段。

## 0. 准备（5 分钟）
```bash
git clone https://github.com/HuChhu/tingshu-apple.git && cd tingshu-apple
xcode-select -p   # 确认 Xcode
java -version     # 需 17
```

## 1. link framework（10–20 分钟，首次含 konan 下载）
```bash
cd shared
# 两个开关必开（否则 link 任务不注册）
printf "kotlin.native.ignoreDisabledTargets=true\n" >> gradle.properties
./gradlew linkReleaseFrameworkIosArm64 --no-daemon
ls build/bin/iosArm64/ReleaseFramework/shared.framework   # 应存在（注意 iosArm64 段，别写成 ios/）
```
> 若报 platform klib 缺失：从 maven 拉 macos 版发行包不需要（Mac 本机 full prebuilt 自带），直接重跑即可。

## 2. 壳对接（唯一代码改动点，10 分钟）
- 打开 `ios/ios-shell/Shared/SharedBridge.swift`
- 确认 `import shared` 能解析（FRAMEWORK_SEARCH_PATHS 已指向 ../shared/build/bin/iosArm64/ReleaseFramework）
- 把 `extractStub` 换成真实调用：`XimalayaAudioExtractor().extract(url)`（类名以 framework 头为准，用 `nm -gU shared.framework/shared | grep Extractor` 对拍）
- 跑 `cd ios && ./check-whitelist.sh`，必须 PASS

## 3. 编译验证（5 分钟）
```bash
cd ios
xcodebuild -project Tingshu.xcodeproj -scheme Tingshu \
  -destination 'generic/platform=iOS' -configuration Release \
  CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="" build
```

## 4. 出未签 IPA（5 分钟）
```bash
xcodebuild -project Tingshu.xcodeproj -scheme Tingshu \
  -configuration Release -sdk iphoneos -archivePath build/Tingshu.xcarchive \
  CODE_SIGNING_ALLOWED=NO archive
cd build && mkdir -p Payload \
  && cp -R Tingshu.xcarchive/Products/Applications/Tingshu.app Payload/ \
  && zip -qr Tingshu-unsigned.ipa Payload
```

## 5. 用户侧（你操作，5 分钟）
- 把 `Tingshu-unsigned.ipa` 传手机 → 全能签（ESign）→ 企业证书签名 → 安装
- **证书到期/吊销**：重签同一 IPA 即可（R6 对策）

## 6. M3 闸口验收（真机）
- 搜「三体」→ 首本 → 首集 → **后台锁屏播放 ≥30 秒**
- 证据：`timeControlStatus=playing` + 人耳/录屏双证
- 通过 → M3 go；不通过 → 按 no-go 出口评估

## 卡点速查
| 症状 | 原因 | 解法 |
|---|---|---|
| link 任务不存在 | 没开两个开关 | 见步骤 1 |
| import shared 找不到 | framework 路径不对 | FRAMEWORK_SEARCH_PATHS 指向 ReleaseFramework |
| 编译过但无人声 | cookie 缺失/未登录 | 桥登录后重试；或先验本地已缓存音频 |
| 后台播放静音 | category 未设 .playback | 检查 BackgroundSession.swift |
