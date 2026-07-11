import SwiftUI

// Programmatic SwiftUI app entry (executable SwiftPM target).
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    var window: NSWindow?

    /// A programmatic NSApplication has NO main menu, so the standard edit key
    /// equivalents (⌘V paste, ⌘C copy, ⌘X cut, ⌘A select-all) never reach the
    /// responder chain — pasting the access token into the password field was
    /// impossible. Install a minimal menu bar to restore them.
    private func installMainMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Hide", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit Realtime Translator",
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let editItem = NSMenuItem()
        main.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit

        NSApp.mainMenu = main
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        installMainMenu()
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

    /// On quit, tear capture down cleanly (stop AVAudioEngine + SCStream, close
    /// the WebSockets). Without this, quitting mid-capture leaves ScreenCaptureKit
    /// streams half-open, which coreaudiod keeps servicing — repeated over a
    /// session that can leak/spin the audio daemon. Give the async stop a brief
    /// moment to run before the process exits.
    func applicationWillTerminate(_ notification: Notification) {
        if model.running { model.stop() }
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
