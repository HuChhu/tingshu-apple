// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PlaybackCore",
    products: [.library(name: "PlaybackCore", targets: ["PlaybackCore"])],
    targets: [
        .target(name: "PlaybackCore", path: "Sources/PlaybackCore"),
        /// 把两套纯逻辑源文件直接编进来（各页面用到的搜索筛选 / 底部留白判定）。
        /// 只挑不 import SwiftUI/UIKit 的文件：这两个文件的依赖只有 Foundation。
        /// 用 symlink 让 PlaybackCore 看到它们，避免复制两份源码。
        .target(name: "UILogic", path: "Sources/UILogic"),
        .testTarget(name: "PlaybackCoreTests", dependencies: ["PlaybackCore", "UILogic"],
                    path: "Tests/PlaybackCoreTests"),
    ]
)
