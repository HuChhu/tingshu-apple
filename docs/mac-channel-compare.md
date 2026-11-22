# macOS 构建通道（T06 终定 2026-11-21）
**终定：GitHub Actions 为主通道**（用户提供 token，私有仓 <owner>/<repo>）
- jvm-tests.yml：ubuntu-latest + JDK17 → shared jvmTest（每次 push）
- ios-framework.yml：macos-14 runner → K/N linkReleaseFrameworkIosArm64（官方 macos-aarch64 可用）+ cache ~/.konan + 上传 framework 工件 + 无签名 xcodebuild 编译检查
- 云 Mac（~$20/月）：备用，真机调试需要时再开
- 借 Mac：仅 M3 闸口真机日
- 真机与签名：免费 Apple ID 7 天重签或 $99 TestFlight，待用户后续确认

> 2026-11-21 13:3x 修正：ios-framework 因「免费私有仓无 macOS runner」2 秒被取消（#2 实证：job 未分配 runner 即 cancelled）→ 改 ubuntu-latest 交叉编译（K/N linux-x86_64 预编译存在），framework 工件照出；xcodebuild 编译检查移到付费通道/借机日执行。

## 2026-11-21 14:5x 通道终定（用户拍板）
**IPA 交付线**：出未签名 IPA → 用户用企业证书 + 全能签（ESign）自签 → 直接装机。
- 意义：不需要 $99 账号、不需要 TestFlight、不需要 7 天重签——M3 闸口改为「全能签签后真机出声」
- 需要的构建环境不变：ipa = xcodebuild archive → export（无签名或企业级 provisioning none）→ 仍需 macOS host（xcodebuild 无法在 Linux 跑）
- 但 klib 路线仍有效：Linux CI 出 klib 工件 → 借/云 Mac 只做最后 link+archive（几小时→十几分钟）
- devops 交付线脚本化目标改为：ios-framework.yml 产出 framework 工件 + archive-ipa.yml（macOS runner/云 Mac）产出 unsigned ipa

## 二次定谳（devops-ci，2026-11-22，任务级证据）
- 撤回我此前基于 #30 steps 级的「Linux 可 link」改判：#30/#36 任务级均为 `linkReleaseFrameworkIosArm64 SKIPPED`（任务注册≠任务执行，gradle 对 SKIPPED 仍 exit 0）
- 维持原结论：**klib 可在 Linux CI 产出；framework link + xcodebuild archive 需 macOS host**（lead 定谳③复核成立）
- Mac 岗位 = scripts/mac-link-archive.sh 全程（link → archive → unsigned IPA）；Linux CI 的 klib/framework-tar 可作为 Mac 步骤的输入加速
