import AppKit
import SwiftUI

/// Account management is a separate native window. It never constructs the legacy workbench,
/// its microphone owner, mirror watcher, or running-instance replacement.
struct PpomiAccountApp: App {
    @NSApplicationDelegateAdaptor(AccountAppDelegate.self) private var delegate

    init() { _ = Fonts.registered }

    var body: some Scene {
        Window("나", id: "account") {
            MeSheet(close: { NSApp.terminate(nil) })
        }
        .windowResizability(.contentSize)
    }
}

final class AccountAppDelegate: NSObject, NSApplicationDelegate {
    private var ownerMonitor: DispatchSourceProcess?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A helper restart must not leave an untracked account editor able to change the new session.
        if let index = CommandLine.arguments.firstIndex(of: "--owner-pid") {
            guard CommandLine.arguments.indices.contains(index + 1),
                  let owner = Int32(CommandLine.arguments[index + 1]), owner > 1, getppid() == owner else {
                NSApp.terminate(nil); return
            }
            let monitor = DispatchSource.makeProcessSource(identifier: owner, eventMask: .exit, queue: .main)
            monitor.setEventHandler { NSApp.terminate(nil) }
            monitor.resume(); ownerMonitor = monitor
            // Cover a parent that exited between the initial check and source registration.
            guard getppid() == owner else { NSApp.terminate(nil); return }
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        GoogleAccount.shared.startSharing()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
