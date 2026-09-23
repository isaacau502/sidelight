import AppKit
import KeyboardShortcuts
import ServiceManagement

/// The menu bar item and its menu. Also owns the small hotkey recorder window.
final class StatusMenu: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private let showPanel: () -> Void
    private let showInCorner: (Corner) -> Void
    private let showAway: () -> Void
    private let onAppearanceChanged: () -> Void

    private var cornerItems: [Corner: NSMenuItem] = [:]
    private var appearanceItems: [Appearance: NSMenuItem] = [:]
    private var launchAtLoginItem: NSMenuItem!
    private var hotkeyWindow: NSWindow?

    init(showPanel: @escaping () -> Void,
         showInCorner: @escaping (Corner) -> Void,
         showAway: @escaping () -> Void,
         onAppearanceChanged: @escaping () -> Void) {
        self.showPanel = showPanel
        self.showInCorner = showInCorner
        self.showAway = showAway
        self.onAppearanceChanged = onAppearanceChanged
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "rectangle.inset.topright.filled",
                                accessibilityDescription: "Sidelight")
            image?.isTemplate = true
            button.image = image
        }

        buildMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    // MARK: - Menu

    private func buildMenu() {
        let show = NSMenuItem(title: "Show Sidelight", action: #selector(showAction), keyEquivalent: "")
        show.target = self
        show.setShortcut(for: .togglePanel)
        menu.addItem(show)

        let away = NSMenuItem(title: "Away Note…", action: #selector(awayAction), keyEquivalent: "")
        away.target = self
        away.setShortcut(for: .awayNote)
        menu.addItem(away)

        menu.addItem(.separator())

        let cornerItem = NSMenuItem(title: "Corner", action: nil, keyEquivalent: "")
        let cornerMenu = NSMenu(title: "Corner")
        let corners: [(String, Corner, KeyboardShortcuts.Name)] = [
            ("Top right", .right, .showRight),
            ("Top left", .left, .showLeft)
        ]
        for (title, corner, shortcut) in corners {
            let item = NSMenuItem(title: title, action: #selector(cornerAction(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = corner.rawValue
            item.setShortcut(for: shortcut)
            cornerMenu.addItem(item)
            cornerItems[corner] = item
        }
        cornerItem.submenu = cornerMenu
        menu.addItem(cornerItem)

        let appearanceItem = NSMenuItem(title: "Appearance", action: nil, keyEquivalent: "")
        let appearanceMenu = NSMenu(title: "Appearance")
        for (title, mode) in [("Dark", Appearance.dark), ("Light", Appearance.light)] {
            let item = NSMenuItem(title: title, action: #selector(appearanceAction(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode.rawValue
            appearanceMenu.addItem(item)
            appearanceItems[mode] = item
        }
        appearanceItem.submenu = appearanceMenu
        menu.addItem(appearanceItem)

        let hotkey = NSMenuItem(title: "Hotkey…", action: #selector(hotkeyAction), keyEquivalent: "")
        hotkey.target = self
        menu.addItem(hotkey)

        launchAtLoginItem = NSMenuItem(title: "Launch at login", action: #selector(launchAtLoginAction),
                                       keyEquivalent: "")
        launchAtLoginItem.target = self
        menu.addItem(launchAtLoginItem)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit Sidelight", action: #selector(quitAction), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    func menuWillOpen(_ menu: NSMenu) {
        refreshState()
    }

    private func refreshState() {
        let current = Settings.corner
        for (corner, item) in cornerItems {
            item.state = corner == current ? .on : .off
        }
        let mode = Settings.appearance
        for (candidate, item) in appearanceItems {
            item.state = candidate == mode ? .on : .off
        }
        launchAtLoginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    // MARK: - Actions

    @objc private func showAction() {
        showPanel()
    }

    @objc private func awayAction() {
        showAway()
    }

    @objc private func cornerAction(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let corner = Corner(rawValue: raw) else { return }
        showInCorner(corner)
    }

    @objc private func appearanceAction(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let mode = Appearance(rawValue: raw) else { return }
        Settings.appearance = mode
        onAppearanceChanged()
    }

    @objc private func hotkeyAction() {
        let window = hotkeyWindow ?? makeHotkeyWindow()
        hotkeyWindow = window
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    @objc private func launchAtLoginAction() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            NSLog("Launch at login change failed: \(error)")
        }
    }

    @objc private func quitAction() {
        NSApp.terminate(nil)
    }

    // MARK: - Hotkey window

    private func makeHotkeyWindow() -> NSWindow {
        let rows: [(String, KeyboardShortcuts.Name)] = [
            ("Toggle", .togglePanel),
            ("Open left", .showLeft),
            ("Open right", .showRight),
            ("Away note", .awayNote)
        ]
        let rowHeight: CGFloat = 32
        let margin: CGFloat = 16
        let labelWidth: CGFloat = 90
        let size = NSSize(width: 300, height: margin * 2 + rowHeight * CGFloat(rows.count))

        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable],
                              backing: .buffered,
                              defer: false)
        window.title = "Hotkeys"
        window.isReleasedWhenClosed = false
        window.level = .floating

        let content = NSView(frame: NSRect(origin: .zero, size: size))
        for (index, (title, name)) in rows.enumerated() {
            let rowY = size.height - margin - rowHeight * CGFloat(index + 1)

            let label = NSTextField(labelWithString: title)
            label.alignment = .right
            label.sizeToFit()
            label.frame = NSRect(x: margin, y: rowY + (rowHeight - label.frame.height) / 2,
                                 width: labelWidth, height: label.frame.height)
            content.addSubview(label)

            let recorder = KeyboardShortcuts.RecorderCocoa(for: name)
            recorder.sizeToFit()
            recorder.frame.origin = NSPoint(x: margin + labelWidth + 12,
                                            y: rowY + (rowHeight - recorder.frame.height) / 2)
            content.addSubview(recorder)
        }
        window.contentView = content
        return window
    }
}
