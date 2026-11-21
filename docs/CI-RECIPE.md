# Linux CI 出 iOS klib：成功路径配方（devops-ci 固化，2026-11-22）
> 实证：ios-klib #14/#15 SUCCESS（head 31c8d76），工件 ios-klib 114,183B。
> 工件真身：`shared/build/classes/kotlin/iosArm64/main/klib/shared-core.klib`（K/N 编译输出在 classes 布局，不在 libs/——31c8d76 修正）

## 四段配方，缺一不可
1. **x86_64 runner**：`runs-on: ubuntu-24.04`（ubuntu-latest 已指向 ARM；K/N 无 linux-aarch64 预编译，repo1 404 实证）。步骤开头 `uname -m` 自证断言。
2. **双开关必须在 ensure-kn-distro 之前注入**（鸡生蛋）：`kotlin.native.ignoreDisabledTargets=true` + `kotlin.native.enableKlibsCrossCompilation=true` 先写进 shared/gradle.properties，再触发任何 gradle 任务——否则 iosArm64 编译任务被禁用→SKIPPED→BUILD SUCCESSFUL（假象），K/N 发行包永不下发。**教训：任何 `gradle <task> || true` 兜底都会制造假绿；gradle 退出码必须裸奔**（`| tail` 管道吞码事故：ios-klib #1/#2）。
3. **移植平台 klib**：linux 发行包缺 ios_arm64 平台库（#7/#20 KLIB resolver: Could not find org.jetbrains.kotlin.native.platform.posix）；从 `kotlin-native-prebuilt-2.0.21-macos-aarch64.tar.gz`（repo1，206 实证）取 `klib/platform/ios_arm64`（**169 个 klib**）拷进 `~/.konan/kotlin-native-prebuilt-linux-x86_64-2.0.21/klib/platform/`。klib 是 host 无关 zip，跨发行包移植无损。发行包本体也从 repo1 直下（分类器命名：`kotlin-native-prebuilt-<ver>-linux-x86_64.tar.gz`）。
4. **源码须 K/N 兼容**：55a2cbb 的 encodeToByteArray 修正（commonMain 不能用 JVM 专属编码 API）。 JVM 编译通过 ≠ K/N 通过。

## 缓存
`actions/cache ~/.konan`，key `konan-linux-x64-kotlin-2.0.21-iosplatklib-v2`（内含移植后的平台库，restore-keys 回退旧 key）。命中即跳过直下+移植两步。

## link 与 framework 的边界（2026-11-22 二次定谳，任务级证据）
- **lead 定谳③成立**：Linux 上 link 任务**可注册但执行被 SKIPPED**——#30/#36 任务行原话 `> Task :linkReleaseFrameworkIosArm64 SKIPPED`（binaries 声明齐备+平台库移植齐备仍如此）
- 我曾据 #30 steps 级 success 改判「Linux 可 link」，**系误判**：SKIPPED 任务的 gradle 依旧 BUILD SUCCESSFUL exit 0——**steps 级结论必须落到任务级**才算数（第二次假绿教训，比管道吞码更隐蔽）
- 现役边界（不再动摇）：**Linux 免费 CI 产出 = klib（.klib 工件）**；framework 链接与 xcodebuild archive 均需 macOS（scripts/mac-link-archive.sh 一键承接）
- 配方四段对 klib 成立；对 framework 仅解决「任务存在性」，不解「执行性」——host 限制在链接器层（Apple ld64 只随 macOS 发行包分发）

## 历史事故清单（防复发）
| 事故 | 根因 | 防复发 |
|---|---|---|
| #1 jvm exit 127 | shared 嵌套仓 gitlink | 平铺真实源码 |
| #14 jvm 配置炸 | iosArm64() 双声明 | target 唯一，binaries 挂载分离 |
| ios-klib #1/#2 假绿 | 管道吞退出码 | 裸命令 + if-no-files-found: error |
| aapt2 进仓 | 机特有 hack | gradle.properties 只进通用配置 |
| SKIPPED 仍 exit 0 | 任务注册≠任务执行（#30/#36） | 结论读任务行，断言 grep SKIPPED |
| 断言管道吞真失败 | `gradlew \| tee` 无 pipefail | 断言脚本 set -o pipefail（第四类假绿） |
