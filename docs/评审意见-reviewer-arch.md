# 评审意见 · reviewer-arch（架构席）2026-11-21
裁决：**带条件通过**（核验依据：TingShu.kt 265 行全文、105 class、JVM BUILD SUCCESSFUL、6B 模块隔离实测零反向泄漏）
## 五项条件（已并入方案集 v1.2）
1. commonMain 接口（三动作+提取器）先于 SwiftUI 冻结并落盘 docs/
2. AudioUrlExtractor 去命令化：suspend 纯返回播放地址，autoPlay/isCache/isDebug 留壳侧
3. iOS actual 收敛五触点：WebView 级提取器 / WebView 容器 / Cookie 存储 / 播放器 / 后台会话；解析+限速+错误分类+签名引擎全进 commonMain
4. 安卓迁移策略落纸：audiobook-app 的 data/ximalaya 纯逻辑切 shared，禁双实现漂移
5. Mac 硬件确认提前到周 1 spike 之前（与产品席决策清单 #1 联动）
