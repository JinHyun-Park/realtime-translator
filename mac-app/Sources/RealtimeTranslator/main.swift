import SwiftUI

// Programmatic SwiftUI app entry (executable SwiftPM target).
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        let view = ContentView().environmentObject(model)
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 940, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        win.title = "Realtime Translator (KO↔JA)"
        win.contentView = NSHostingView(rootView: view)
        win.center()
        win.makeKeyAndOrderFront(nil)
        window = win
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

// Top-level code runs on the main thread; assert main-actor isolation so we can
// construct the @MainActor AppDelegate / AppModel.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
