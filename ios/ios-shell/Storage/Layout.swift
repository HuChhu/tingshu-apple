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
}
