import XCTest
@testable import UILogic

final class LayoutBottomPaddingTests: XCTestCase {
    func testCustomBarReservesBarHeight() {
        XCTAssertEqual(Layout.contentBottomPadding(customBottomBar: true), 56 + 24)
    }

    func testSystemBarOnlyNeedsBaseline() {
        // 走系统 safeAreaInset / tabViewBottomAccessory 时，系统已经让位，
        // 页面再加一整条高就会在底部多出一大块空白（v1.4.0 的 iOS 26 空隙就是这么来的）
        XCTAssertEqual(Layout.contentBottomPadding(customBottomBar: false), 16)
    }

    func testExplicitBarHeight() {
        XCTAssertEqual(Layout.contentBottomPadding(customBottomBar: true, barHeight: 64), 88)
    }
}
