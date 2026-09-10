import AppKit
import SwiftUI
import WebKit

/// A docked workbench can still take keyboard focus when the person explicitly activates its app.
func keepsPhoneKeyboardFocus(_ view: NSView, applicationIsActive: Bool = NSApp.isActive) -> Bool {
    (view.window as? MainPanel)?.hasDockedWindow == true && !applicationIsActive
}

/// Pointer navigation keeps Mirroring in front. Native text-field descendants retain their own focus policy.
class WorkbenchHostingView<Content: View>: NSHostingView<Content> {
    private var isDocked: Bool { (window as? MainPanel)?.hasDockedWindow == true }

    override var needsPanelToBecomeKey: Bool { keepsPhoneKeyboardFocus(self) ? false : super.needsPanelToBecomeKey }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        isDocked || super.acceptsFirstMouse(for: event)
    }

    override func shouldDelayWindowOrdering(for event: NSEvent) -> Bool {
        isDocked || super.shouldDelayWindowOrdering(for: event)
    }

    override func mouseDown(with event: NSEvent) {
        if isDocked { NSApp.preventWindowOrdering() }
        super.mouseDown(with: event)
    }
}

/// Report pages handle pointer selection without taking Mirroring's keyboard focus.
/// Pages that add editable content or keyboard navigation must opt in explicitly.
class WorkbenchWebView: WKWebView {
    var allowsKeyboardInteraction = false
    private var isDocked: Bool { (window as? MainPanel)?.hasDockedWindow == true }

    override var needsPanelToBecomeKey: Bool {
        keepsPhoneKeyboardFocus(self) ? allowsKeyboardInteraction : super.needsPanelToBecomeKey
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        isDocked || super.acceptsFirstMouse(for: event)
    }

    override func shouldDelayWindowOrdering(for event: NSEvent) -> Bool {
        isDocked || super.shouldDelayWindowOrdering(for: event)
    }

    override func mouseDown(with event: NSEvent) {
        if isDocked { NSApp.preventWindowOrdering() }
        super.mouseDown(with: event)
    }
}

/// Empty space, native approval controls, and their gaps need the same mouse-down behavior as the hosting view.
class WorkbenchSurface: NSView {
    private var isDocked: Bool { (window as? MainPanel)?.hasDockedWindow == true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { isDocked || super.acceptsFirstMouse(for: event) }
    override func shouldDelayWindowOrdering(for event: NSEvent) -> Bool { isDocked || super.shouldDelayWindowOrdering(for: event) }
    override func mouseDown(with event: NSEvent) {
        if isDocked { NSApp.preventWindowOrdering() }
        super.mouseDown(with: event)
    }
}

final class WorkbenchButton: NSButton {
    private var isDocked: Bool { (window as? MainPanel)?.hasDockedWindow == true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { isDocked || super.acceptsFirstMouse(for: event) }
    override func shouldDelayWindowOrdering(for event: NSEvent) -> Bool { isDocked || super.shouldDelayWindowOrdering(for: event) }
    override func mouseDown(with event: NSEvent) {
        if isDocked { NSApp.preventWindowOrdering() }
        super.mouseDown(with: event)
    }
}

final class WorkbenchStack: NSStackView {
    private var isDocked: Bool { (window as? MainPanel)?.hasDockedWindow == true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { isDocked || super.acceptsFirstMouse(for: event) }
    override func shouldDelayWindowOrdering(for event: NSEvent) -> Bool { isDocked || super.shouldDelayWindowOrdering(for: event) }
    override func mouseDown(with event: NSEvent) {
        if isDocked { NSApp.preventWindowOrdering() }
        super.mouseDown(with: event)
    }
}

final class WorkbenchLabel: NSTextField {
    private var isDocked: Bool { (window as? MainPanel)?.hasDockedWindow == true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { isDocked || super.acceptsFirstMouse(for: event) }
    override func shouldDelayWindowOrdering(for event: NSEvent) -> Bool { isDocked || super.shouldDelayWindowOrdering(for: event) }
    override func mouseDown(with event: NSEvent) {
        if isDocked { NSApp.preventWindowOrdering() }
        super.mouseDown(with: event)
    }
}
