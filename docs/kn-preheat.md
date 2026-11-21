# K/N 交叉编译预热（T07）
## lead 助跑实测（2026-11-21 11:5x，供 devops-ci 汇总）
- 环境：aarch64 Linux（手机 proot）+ JDK17 + Kotlin 2.0.21 + Gradle 8.0
- 结果：**iosArm64 target 被禁用**——K/N 无 linux_aarch64 官方预编译，Gradle 输出：
  "The following Kotlin/Native targets cannot be built on this machine and are disabled: iosArm64"
- 结论：本机 aarch64 预热路线不可行（与 devops-ci 预判一致）；**改走 x86_64 CI 缓存 ~/.konan**（GH Actions macos runner 自带 K/N 支持，或 x86_64 Linux CI 预热后拷缓存）
- JVM 侧不受影响：shared-core 契约编译继续在本机推进
- 证据：/tmp/kn-preheat.log（BUILD SUCCESSFUL in 3m46s，task SKIPPED=禁用而非报错）

## devops-ci 独立复现与定谳（2026-11-21 12:0x）
- 第二组工具链复现：**Kotlin 2.1.21 + Gradle 8.13 + JDK17**，compileKotlinIosArm64 同样 **SKIPPED**（BUILD SUCCESSFUL：冷启 1m19s / --rerun-tasks 后 10s）；flag 开关不改变结果
- 两台环境 `~/.konan` 均未创建 → **禁用发生在 Gradle 构建器层，K/N 编译器从未下发**，"预热"无从发生
- 工件命名定谳（repo1.maven.org 官方源，Kotlin 2.1.21，Range GET 实测）：
  - `kotlin-native-prebuilt-2.1.21-linux-x86_64.tar.gz` → **206 存在**
  - `kotlin-native-prebuilt-2.1.21-macos-aarch64.tar.gz` → **206 存在**
  - `kotlin-native-prebuilt-2.1.21-linux-aarch64.tar.gz` → **404 不存在**
  - → **K/N 官方预编译无 linux-aarch64 host；本机 aarch64 预热属永久不可行，非镜像缓存问题**（阿里镜像同名 404 一致，已排除镜像差异）
- 工具链交付：Gradle 8.13 腾讯镜像 8 段并行直拉（239s，分段字节校验）→ 合并 → md5 `ea50a70340ae49febcc239359925222d` → 装于 **/opt/gradle-8.13**（供本机 JVM 侧与 CI 镜像配置复用）
- 日志证据：/tmp/kn-preheat.log（lead 2.0.21+8.0）、/tmp/kn-preheat-devops.log（devops-ci 2.1.21+8.13）

## x86_64 CI 预热方案（落纸，完成口径）
1. 载体：GH Actions **macos-14 runner**（host 即 macos-aarch64，K/N 有官方预编译 206 实证，原生可跑）或 **ubuntu-22.04**（x86_64）
2. 步骤：搬 `kn-scratch` 进 CI → `gradle compileKotlinIosArm64`（首跑拉 ~几百 MB K/N 工具链落 `~/.konan`）→ `actions/cache` 锁 `~/.konan` + `~/.gradle/caches`
3. 验收：`linkDebugFrameworkIosArm64` 出 shared.framework；`file` 输出含 "Mach-O 64-bit dynamically linked shared library, arm64"；框架头扫描禁 Ktor/ksoup 字样（对齐契约 C1 机械检查）
4. 镜像：CI 仓库配置沿用 scratch settings.gradle.kts（腾讯 gradle-plugin + 阿里 public 置顶），省 GitHub egress
5. 否决备选：linux-aarch64 自编 K/N bootstrap 编译器（数小时级成本，工程上不值）

## scratch 工程交接
- `kn-scratch`：settings.gradle.kts（镜像置顶）/ build.gradle.kts（KGP 2.1.21 + iosArm64()，依赖仅 kotlin-stdlib）/ Probe.kt / gradle-wrapper（jar 复用主工程，URL 指腾讯 8.13）
- 纪律：未入主工程、未入任何 git 仓库（隔离墙 §19.6.3）；搬 CI 即用
- 部署目标未设定（等「待确认五件事」第 5 条的最低 iOS 版本后，在 CI 版 build.gradle.kts 里定）

## CI 终局定谳（2026-11-21 14:0x，ios-framework #2–#14 共 7 次实证）
1. 免费私有仓无 macOS runner：#2 macos-14 创建 2 秒被取消、runner 未分配
2. ubuntu-24.04 = x86_64 ✓（#10 uname 自证）
3. K2.0.20+：kotlin.native.enableKlibsCrossCompilation=true 只解锁 klib；**Apple 目标 framework 链接在 Linux 主机被上游禁用**（#12/#14 双开关全开、警告消失、K/N 编译器零下载、任务不注册）
4. 结论：framework 工件只有四条路——仓库转公开（macOS runner 免费）/ 启用 Actions 付费计费 / 云 Mac / 借 Mac。均需用户拍板
5. jvm-tests 在 CI 持续 SUCCESS（#2/#5/#6/#8/#9 全绿）

## 🎯 2026-11-22 05:3x 突破：Linux CI 成功产出 iosArm64 klib
**#15 SUCCESS，工件 ios-klib 112KB**（可下载）。
### 打通路径（三段，缺一不可）
1. **runner 必须 x86_64**：ubuntu-24.04 + uname 自证（ubuntu-latest 已 ARM 化）
2. **两个 gradle 开关先于一切**：`kotlin.native.ignoreDisabledTargets=true` + `kotlin.native.enableKlibsCrossCompilation=true`，且必须在 ensure-kn-distro 步之前注入（鸡生蛋：编译器不下载 prebuilt 就无目录可移植）
3. **平台库移植**：linux prebuilt 的 `klib/platform/ios_arm64` 是空的（169 个 platform klib 缺），从 maven 拉 `kotlin-native-prebuilt-2.0.21-macos-aarch64.tar.gz`，把它的 `klib/platform/ios_arm64`（169 个 klib）拷进 linux prebuilt 同路径
4. **源码 K/N 兼容**：commonMain 禁用 JVM-only API（`String.toByteArray()` → `encodeToByteArray()`）
### 产物路径（重要，与 framework 不同）
`shared/build/classes/kotlin/iosArm64/main/klib/shared-core.klib`（不是 build/libs/iosArm64/）
### 意义
- Linux CI 白嫖产出 iOS 编译真身：**源代码级验证通过**（不是纸上推演）
- Mac 窗口从「编译几小时」降到「只做 link，几分钟」
- 后续改动可全程在 CI 验证，只有最终 framework/IPA 需要 Mac
### 遗留
- link framework 仍必须 macOS host（上游禁令不解）
- IPA 需 xcodebuild archive（Mac）

## 🔒 终局定谳 2026-11-22 06:1x（铁证，不可再翻案）
**Linux 不能 link 出 framework，只能编译 klib。**

证据（ios-framework #36 / HEAD e6e420e 步步日志）：
```
> Task :compileKotlinIosArm64            ← 真跑，编译成功
> Task :xcodeVersion SKIPPED            ← K/N 检测无 Xcode
> Task :linkReleaseFrameworkIosArm64 SKIPPED   ← link 被主动跳过
BUILD SUCCESSFUL in 1m 52s              ← 但什么都没 link 出来
```
**陷阱**：BUILD SUCCESSFUL + task SKIPPED 会造成「假成功」，让 verify 步的 find 扑空（#36 的真正失败点）。
**结论**：
- ❌ dev-ios 的「#30 已实证 linux link 出 Mach-O」判断错误（#30 实为 failure，且同为此种 SKIPPED 假绿）
- ✅ 可行路径唯一：**klib 由 Linux CI 出（#26 SUCCESS，112KB）→ 必须 macOS 执行 linkReleaseFrameworkIosArm64 + xcodebuild archive → unsigned IPA**

