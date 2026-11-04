import XCTest
import AppKit
@testable import MacRunnerControlCenter

/// Полоса света на знаке MacRunner едет только в окне, которое на виду и активно.
/// Без окна и при `moving == false` анимации на слое быть не должно: иначе сервер отрисовки
/// гонял бы её в фоне (02.11.2026, «приложение ест процессор в простое»).
/// Положительный случай (окно на экране и активно) здесь не проверяется: он требует показать окно,
/// а это мешает человеку за машиной; его проверяли замером на сборке.
@MainActor
final class BrandSheenViewTests: XCTestCase {
    func testNoSweepWithoutWindow() {
        let view = BrandSheenView(frame: NSRect(x: 0, y: 0, width: 28, height: 28))
        view.update(size: 28, scale: 2, moving: true) { nil }
        view.layoutSubtreeIfNeeded()
        XCTAssertFalse(view.isSweeping)
    }

    func testNoSweepWhenWindowInactive() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 64, height: 64),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        let view = BrandSheenView(frame: NSRect(x: 0, y: 0, width: 28, height: 28))
        window.contentView?.addSubview(view)
        view.update(size: 28, scale: 2, moving: false) { nil }
        view.layoutSubtreeIfNeeded()
        XCTAssertFalse(view.isSweeping)
    }
}
