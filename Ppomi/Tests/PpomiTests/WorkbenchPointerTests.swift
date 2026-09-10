import AppKit
import SwiftUI
import WebKit
import XCTest
@testable import Ppomi

final class WorkbenchPointerTests: XCTestCase {
    @MainActor func testAgentOnlyDockPreservesPointerFocusWithoutPhone() throws {
        let panel = makePanel()
        defer { panel.close() }
        let host = WorkbenchHostingView(rootView: Text("Records"))
        panel.contentView = host
        panel.phoneID = 52
        let event = try mouseDown(in: panel)
        assertFocusPolicy(host, docked: true)
        XCTAssertTrue(host.shouldDelayWindowOrdering(for: event))
        XCTAssertTrue(host.acceptsFirstMouse(for: event))
        XCTAssertFalse(panel.isVisible)
        panel.phoneID = nil
        assertFocusPolicy(host, docked: false)
    }

    @MainActor func testDockedHostingNavigationKeepsNativeEditingAvailable() throws {
        let panel = makePanel()
        defer { panel.close() }
        let host = WorkbenchHostingView(rootView: Text("Navigation"))
        panel.contentView = host
        let ordinaryHost = NSHostingView(rootView: Text("Navigation"))
        XCTAssertEqual(host.needsPanelToBecomeKey, ordinaryHost.needsPanelToBecomeKey)
        assertFocusPolicy(host, docked: false)

        panel.phoneID = 31
        let event = try mouseDown(in: panel)
        assertFocusPolicy(host, docked: true)
        XCTAssertEqual(host.needsPanelToBecomeKey, NSApp.isActive && ordinaryHost.needsPanelToBecomeKey)
        XCTAssertTrue(host.shouldDelayWindowOrdering(for: event))
        XCTAssertTrue(host.acceptsFirstMouse(for: event))

        let field = NSTextField(string: "Editable")
        host.addSubview(field)
        XCTAssertTrue(field.isEditable)
        XCTAssertTrue(field.needsPanelToBecomeKey)
        XCTAssertTrue(field.acceptsFirstResponder)
        XCTAssertTrue(panel.canBecomeKey)
        XCTAssertFalse(panel.isVisible)

        panel.phoneID = nil
        XCTAssertEqual(host.needsPanelToBecomeKey, ordinaryHost.needsPanelToBecomeKey)
        assertFocusPolicy(host, docked: false)
    }

    @MainActor func testReportPageCanOptIntoKeyboardFocusWithoutLosingOrderingProtection() throws {
        let panel = makePanel()
        defer { panel.close() }
        let web = WorkbenchWebView(frame: .zero, configuration: WKWebViewConfiguration())
        panel.contentView = web
        let ordinaryWeb = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        XCTAssertEqual(web.needsPanelToBecomeKey, ordinaryWeb.needsPanelToBecomeKey)
        assertFocusPolicy(web, docked: false)

        panel.phoneID = 31
        let event = try mouseDown(in: panel)
        assertFocusPolicy(web, docked: true)
        XCTAssertEqual(web.needsPanelToBecomeKey, NSApp.isActive && ordinaryWeb.needsPanelToBecomeKey)
        XCTAssertTrue(web.shouldDelayWindowOrdering(for: event))
        XCTAssertTrue(web.acceptsFirstMouse(for: event))

        web.allowsKeyboardInteraction = true
        XCTAssertEqual(web.needsPanelToBecomeKey, !NSApp.isActive || ordinaryWeb.needsPanelToBecomeKey)
        XCTAssertTrue(web.shouldDelayWindowOrdering(for: event))
        XCTAssertTrue(panel.canBecomeKey)
        XCTAssertFalse(panel.isVisible)

        panel.phoneID = nil
        XCTAssertEqual(web.needsPanelToBecomeKey, ordinaryWeb.needsPanelToBecomeKey)
        assertFocusPolicy(web, docked: false)
    }

    @MainActor func testNativeSurfacesKeepButtonActionsAndAppKitKeySemantics() throws {
        let panel = makePanel()
        defer { panel.close() }
        let container = NSView(frame: panel.contentLayoutRect)
        panel.contentView = container
        let target = ButtonTarget()
        let button = WorkbenchButton(title: "Test action", target: target, action: #selector(ButtonTarget.clicked(_:)))
        let pairs: [(NSView, NSView)] = [
            (WorkbenchSurface(), NSView()),
            (button, NSButton(title: "Test action", target: nil, action: nil)),
            (WorkbenchStack(), NSStackView()),
            (WorkbenchLabel(labelWithString: "Status"), NSTextField(labelWithString: "Status"))
        ]
        for (view, _) in pairs { container.addSubview(view) }
        let event = try mouseDown(in: panel)

        for docked in [false, true, false] {
            panel.phoneID = docked ? 31 : nil
            for (view, ordinary) in pairs {
                XCTAssertEqual(view.needsPanelToBecomeKey, ordinary.needsPanelToBecomeKey)
                XCTAssertEqual(view.acceptsFirstMouse(for: event), docked || ordinary.acceptsFirstMouse(for: event))
                XCTAssertEqual(view.shouldDelayWindowOrdering(for: event), docked || ordinary.shouldDelayWindowOrdering(for: event))
                assertFocusPolicy(view, docked: docked)
            }
        }

        panel.phoneID = 31
        XCTAssertEqual(target.clicks, 0)
        button.performClick(nil)
        XCTAssertEqual(target.clicks, 1)
        XCTAssertTrue(target.sender === button)
        XCTAssertFalse(panel.isVisible)
        XCTAssertTrue(panel.canBecomeKey)
    }

    /// Test both activation states without changing the user's active application or displaying the panel.
    @MainActor private func assertFocusPolicy(_ view: NSView, docked: Bool, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(keepsPhoneKeyboardFocus(view, applicationIsActive: false), docked, file: file, line: line)
        XCTAssertFalse(keepsPhoneKeyboardFocus(view, applicationIsActive: true), file: file, line: line)
    }

    @MainActor private func makePanel() -> MainPanel {
        _ = NSApplication.shared
        let panel = MainPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        return panel
    }

    @MainActor private func mouseDown(in panel: NSPanel) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 30, y: 30),
                                        modifierFlags: [], timestamp: 0, windowNumber: panel.windowNumber,
                                        context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
    }
}

@MainActor private final class ButtonTarget: NSObject {
    var clicks = 0
    weak var sender: NSButton?
    @objc func clicked(_ sender: NSButton) { clicks += 1; self.sender = sender }
}
