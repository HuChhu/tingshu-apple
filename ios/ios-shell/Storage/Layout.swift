import SwiftUI

/// 屏幕尺寸与布局常量。
///
/// 两条纪律：
///   ① 不用 UIScreen.main（iOS 26 起已标记废弃，多窗口/外接屏下语义不明确）
///   ② 只 import SwiftUI（壳侧白名单限制），所以不直接用 UIApplication.shared
///
/// 取尺寸的做法：SwiftUI 环境里的 GeometryReader 由视图层喂进来，
/// 这里只提供基于宽度的断点判断，避免任何对 UIKit 单例的依赖。
enum Layout {
    /// 宽度 >= 430pt 视为大屏（Pro Max / Plus / iPad）
    static func isLarge(_ width: CGFloat) -> Bool { width >= 430 }

    /// 宽度 >= 700pt 视为 iPad 级（含横屏 iPad）
    static func isPad(_ width: CGFloat) -> Bool { width >= 700 }

    /// 封面尺寸：随可用宽度线性放大，钳在 44...80
    static func coverSize(_ width: CGFloat) -> CGFloat {
        min(80, max(44, width * 0.13))
    }

    /// 播放页主图标：随宽度放大，钳在 72...112
    static func heroIcon(_ width: CGFloat) -> CGFloat {
        min(112, max(72, width * 0.17))
    }

    /// 播放主按钮：随宽度放大，钳在 64...92
    static func mainButton(_ width: CGFloat) -> CGFloat {
        min(92, max(64, width * 0.15))
    }

    // MARK: - v1.4.0 统一视觉常量（R3 收口）
    // 之前各 View 各写各的魔数：圆角 6/8/12/14/16 混用、缩略图 38/48/52 混用、
    // 骨架色一处 .12 一处 .10、迷你条底部留白手写 49+max(16, inset)。
    // 统一收到这里，改一处全站生效。

    /// 内容左右边距（方案 §二：390pt 屏 16pt）
    static let hPadding: CGFloat = 16
    /// 分区垂直间距
    static let sectionSpacing: CGFloat = 22
    /// 分区标题与内容间距
    static let titleGap: CGFloat = 10
    /// 卡片间距
    static let cardSpacing: CGFloat = 12

    /// 圆角：列表缩略图 6 / 图片 8 / 卡片 12 / 迷你条与浮层 14
    static let radiusThumb: CGFloat = 6
    static let radiusImage: CGFloat = 8
    static let radiusCard: CGFloat = 12
    static let radiusBar: CGFloat = 14

    /// 缩略图尺寸：列表行 48 / 继续收听 64 / 详情头 96 / 横滑卡 116
    static let thumbRow: CGFloat = 48
    static let thumbContinue: CGFloat = 64
    static let thumbHeader: CGFloat = 96
    static let thumbCard: CGFloat = 116

    /// 迷你条：条高 56，距 TabBar 顶 6，左右外边距 8
    static let miniBarHeight: CGFloat = 56
    static let miniBarGap: CGFloat = 6
    static let miniBarSideMargin: CGFloat = 8
    /// 封面尺寸（迷你条内）
    static let miniBarCover: CGFloat = 40

    /// 点按热区下限（方案 §二：所有可点控件 44×44）
    static let hitTarget: CGFloat = 44

    /// 骨架屏统一底色（浅色/深色由语义色自动适配，不写死灰度）
    static var skeletonFill: Color { Color.secondary.opacity(0.12) }
    /// 卡片底（推荐卡、继续听）
    static var cardFill: Color { Color.secondary.opacity(0.08) }
    /// 胶囊底（状态标签、倍速按钮）
    static var pillFill: Color { Color.secondary.opacity(0.14) }

    // MARK: - 底部留白（v1.4.1 改语义）
    //
    // 旧实现 bottomInset(miniBarVisible:safeArea:) 是「手算迷你条 + TabBar + 安全区」，
    // 要求调用方自己知道 TabBar 多高 —— 这正是 iOS 26 悬浮胶囊上出现空隙的原因。
    //
    // 现在底部让位交给系统：
    //   - iOS 26+      tabViewBottomAccessory：配件由 TabView 托管，内容区 safe area 已包含
    //   - iOS 17–25    .safeAreaInset(edge: .bottom)：系统自动把内容区抬高
    // 所以页面**只能**再加「自绘 dock（iOS 26 兜底模式）」或「迷你条本体」这一截，
    // 绝不能再加 TabBar/安全区，否则就是重复让位。

    /// 自绘 dock：条高 56 / 外侧边距 10 / 中间播放键直径 58（比条高 2，微微凸出）
    static let dockHeight: CGFloat = 56
    static let dockSideMargin: CGFloat = 10
    static let dockPlayKey: CGFloat = 58

    /// 固定底部栏的底线留白（自绘 dock / 迷你条二选一，不会同时出现）
    static let dockBaseline: CGFloat = 16

    /// 页面用：内容底部还需要自己补多少。
    /// - Parameter bottomBar: 当前是否有一个**自绘的**底部栏占位（dock 或兜底迷你条）。
    ///   走系统方案时传 false —— 系统已经让位，页面再加就是重复。
    static func contentBottomPadding(customBottomBar: Bool, barHeight: CGFloat = dockHeight) -> CGFloat {
        customBottomBar ? barHeight + 24 : dockBaseline
    }
}
