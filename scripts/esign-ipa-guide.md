# 企业证书 + 全能签（ESign）IPA 交付线（devops-ci 2026-11-22）
> 用户已拍板：不上架、不买 $99；企业证书 + 全能签自助签。免费的 7 天重签线只属个人证书，本线无 7 天烦恼，但承担企业证书吊销风险。

## 流程（从 CI 产物到 iPhone 出声）
1. **取包**：Mac 窗口跑 `scripts/mac-link-archive.sh`（或 archive-ipa.yml 的 runner 环境）得 `Tingshu-unsigned.ipa`
2. **传手机**：AirDrop / 文件 App / 任意直链——ipa 本体无签名，传输方式随意
3. **全能签重签**：
   - 全能签导入 ipa → 选择企业证书（p12 + mobileprovision）
   - entitlements 注入：用 `ios/TingshuEntitlements.plist` 模板，把 `TEAMID_PLACEHOLDER` 全部替换为证书的 TeamID（两处：application-identifier 前缀 + keychain-access-groups）
   - 重签并安装
4. **信任证书**：设置 → 通用 → VPN 与设备管理 → 信任企业开发者
5. **验收**：启动 → 播放 → 锁屏 ≥30s（QA 口径）；后台音频由 Info.plist 的 `UIBackgroundModes=audio` 保证（重签不动 Info.plist，entitlements 里不需要 audio）

## 技术要点
- shared framework 是**静态链接**（isStatic=true）：Kotlin 运行时已编进主二进制，ipa 内无动态依赖，ESign 单体重签即可，无需嵌 framework
- 重签只改签名层（Mach-O 签名 + entitlements），不动二进制内容——C1 头扫描结果在重签前后不变
- 企业证书吊销后：已装 App 启动受限；重新签发新证书 → 重跑本线第 3 步即可，无需重新编译
