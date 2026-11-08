import AppKit
import SwiftUI

@main
struct TokenStatsApplication: App {
    @NSApplicationDelegateAdaptor(TokenStatsAppDelegate.self) private var appDelegate
    @StateObject private var limits = LimitsStore.shared
    // Threadbear shows the same limits now, so the icon can go while Token Stats keeps
    // running for what only it does: writing limits.json, renewing logins, updating CLIs.
    @AppStorage(TokenStatsAppDelegate.showMenuBarIconKey) private var showMenuBarIcon = true

    init() {
        LimitsCommand.runIfRequested()
        UsageCommand.runIfRequested()
        #if DEBUG
        LimitsSnapshot.renderIfRequested()
        #endif
    }

    var body: some Scene {
        MenuBarExtra(isInserted: $showMenuBarIcon) {
            MenuBarPanel(store: limits) { appDelegate.showWindow() }
        } label: {
            MenuBarLabel(store: limits)
                .background(OpenWindowCapture(delegate: appDelegate))
        }
        .menuBarExtraStyle(.window)

        Window(TokenStatsAppDelegate.windowTitle, id: "main") {
            DashboardView()
                // With the icon hidden its label never draws, so the window hands over openWindow too.
                .background(OpenWindowCapture(delegate: appDelegate))
        }
        .defaultSize(width: 1180, height: 820)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {}
            // Token Stats lives in the menu bar, so ⌘Q just puts it back there. The Quit button
            // in the window really quits, and so does a quit from macOS (logging out, restarting).
            CommandGroup(replacing: .appTermination) {
                Button("Close to Menu Bar") { appDelegate.closeToMenuBar() }
                    .keyboardShortcut("q")
            }
        }
    }
}

/// Hands SwiftUI's openWindow action to the delegate, from the menu bar label or the window,
/// whichever draws first. At login the window opens and closes at once, which is enough.
private struct OpenWindowCapture: View {
    let delegate: TokenStatsAppDelegate
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Color.clear.onAppear {
            if delegate.openMainWindow == nil { delegate.openMainWindow = { openWindow(id: "main") } }
        }
    }
}

@MainActor
final class TokenStatsAppDelegate: NSObject, NSApplicationDelegate {
    static let windowTitle = "Token Stats"
    static let showMenuBarIconKey = "showMenuBarIcon"
    // SwiftUI drops the window when it closes, so only its own openWindow action can bring it back.
    var openMainWindow: (() -> Void)?

    // With the window closed Token Stats lives only in the menu bar, so it drops out of the Dock.
    func applicationDidFinishLaunching(_ notification: Notification) {
        let center = NotificationCenter.default
        center.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { note in
            guard (note.object as? NSWindow)?.title == Self.windowTitle else { return }
            MainActor.assumeIsolated { NSApp.setActivationPolicy(.accessory) }
        }
        center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { note in
            guard (note.object as? NSWindow)?.title == Self.windowTitle else { return }
            MainActor.assumeIsolated { if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) } }
        }
        LimitsStore.shared.start()
        CLIUpdater.shared.start()
        // Opened at login it starts quietly in the menu bar; opened by hand it shows the dashboard.
        if launchedAtLogin {
            NSApp.setActivationPolicy(.accessory)
            DispatchQueue.main.async { NSApp.windows.filter { $0.title == Self.windowTitle }.forEach { $0.close() } }
        } else {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // Reopening the app (Dock, Finder or `token-stats`) brings the dashboard back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { showWindow() }
        return true
    }

    func closeToMenuBar() {
        NSApp.windows.filter { $0.title == Self.windowTitle }.forEach { $0.close() }
        NSApp.setActivationPolicy(.accessory)
    }

    func showWindow() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.title == Self.windowTitle }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            openMainWindow?()
        }
    }

    private var launchedAtLogin: Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent else { return false }
        return event.eventID == kAEOpenApplication
            && event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }
}
