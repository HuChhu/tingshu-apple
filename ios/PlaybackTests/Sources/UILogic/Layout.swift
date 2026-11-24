import Foundation

/// 与 ios-shell/Storage/Layout.swift 里的底部留白段落保持一致。
/// 只搬这一小段（不 import SwiftUI 的部分），让「留白判定」这条最容易算错的
/// 规则能在 Linux 上跑测试：iPhone 竖屏要自绘栏 → 补条高；iPad/横屏走系统栏 → 只补 16pt 底线。
/// 任何一边改了公式而另一边没跟，测试会先炸。
enum Layout {
    static let dockHeight: CGFloat = 56
    static let dockBaseline: CGFloat = 16

    static func contentBottomPadding(customBottomBar: Bool,
                                     barHeight: CGFloat = dockHeight) -> CGFloat {
        customBottomBar ? barHeight + 24 : dockBaseline
    }
}
