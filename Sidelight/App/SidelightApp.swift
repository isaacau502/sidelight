import AppKit
import KeyboardShortcuts
import ServiceManagement

extension KeyboardShortcuts.Name {
    /// Toggle the panel in the last-used corner.
    static let togglePanel = Self("togglePanel", default: .init(.space, modifiers: [.option]))
    /// Open (or move) the panel in the top-left corner.
    static let showLeft = Self("showLeft", default: .init(.leftArrow, modifiers: [.control, .option]))
    /// Open (or move) the panel in the top-right corner.
    static let showRight = Self("showRight", default: .init(.rightArrow, modifiers: [.control, .option]))
    /// Open the panel in away mode: Return paints the note on the lock screen and locks.
    static let awayNote = Self("awayNote", default: .init(.upArrow, modifiers: [.control, .option]))
}

@main
final class SidelightApp: NSObject, NSApplicationDelegate {
    private var panel: SidelightPanel!
    private var statusMenu: StatusMenu!
    private var awayNote: AwayNote!

    static func main() {
        let app = NSApplication.shared
        let delegate = SidelightApp()
        app.delegate = delegate
        app.run()
    }

    /// Turns on "Launch at login" the first time the app runs. The menu item can turn it
    /// off afterwards; this never re-enables it once the user has made a choice.
    private func registerLaunchAtLoginOnFirstRun() {
        let key = "launchAtLoginConfigured"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        do {
            try SMAppService.mainApp.register()
        } catch {
            NSLog("Launch at login registration failed: \(error)")
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        registerLaunchAtLoginOnFirstRun()

        let panel = SidelightPanel()
        self.panel = panel
        let awayNote = AwayNote()
        self.awayNote = awayNote
        panel.onCommit = { text in
            awayNote.activate(text: text, appearance: Settings.appearance)
        }
        statusMenu = StatusMenu(showPanel: { panel.show() },
                                showInCorner: { panel.show(in: $0) },
                                showAway: { panel.showAway() },
                                onAppearanceChanged: { panel.applyAppearance() })

        KeyboardShortcuts.onKeyDown(for: .togglePanel) {
            panel.toggle()
        }
        KeyboardShortcuts.onKeyDown(for: .showLeft) {
            panel.show(in: .left)
        }
        KeyboardShortcuts.onKeyDown(for: .showRight) {
            panel.show(in: .right)
        }
        KeyboardShortcuts.onKeyDown(for: .awayNote) {
            panel.showAway()
        }

    }
}
