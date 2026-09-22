import AppKit

/// "Away note": paints the sign onto each display's wallpaper so it shows on the lock
/// screen, locks the screen, and restores the original wallpapers when the session
/// unlocks. The restore record lives in UserDefaults so a relaunch can also restore.
final class AwayNote {
    private static let restoreKey = "awayRestore"   // [displayID: original wallpaper path]
    private static let knownKey = "awayKnownWallpaper"   // [displayID: last readable wallpaper path]
    private var unlockObserver: NSObjectProtocol?

    init() {
        unlockObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.screenIsUnlocked"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.restore()
        }
        // Safety net: if the app quit or crashed while away, put the wallpaper back now.
        restore()
        rememberCurrentWallpaper()
    }

    /// Records the current wallpaper path per display whenever it is a readable file that
    /// is not one of our renders. macOS wallpapers are per Space, so the "current" answer
    /// can be stale; this gives restore something real to go back to.
    func rememberCurrentWallpaper() {
        var known = UserDefaults.standard.dictionary(forKey: Self.knownKey) as? [String: String] ?? [:]
        for screen in NSScreen.screens {
            guard let id = Self.displayID(of: screen),
                  let url = Self.originalWallpaper(for: screen, recorded: nil),
                  FileManager.default.isReadableFile(atPath: url.path) else { continue }
            known[id] = url.path
        }
        UserDefaults.standard.set(known, forKey: Self.knownKey)
    }

    deinit {
        if let unlockObserver {
            DistributedNotificationCenter.default().removeObserver(unlockObserver)
        }
    }

    var isActive: Bool {
        !(UserDefaults.standard.dictionary(forKey: Self.restoreKey) ?? [:]).isEmpty
    }

    // MARK: - Activate / restore

    /// Renders `text` onto every display's wallpaper, then locks the screen.
    func activate(text: String, appearance: Appearance, lock: Bool = true) {
        if isActive { restore() }
        rememberCurrentWallpaper()

        let workspace = NSWorkspace.shared
        let recorded = UserDefaults.standard.dictionary(forKey: Self.restoreKey) as? [String: String] ?? [:]
        var originals: [String: String] = [:]

        for screen in NSScreen.screens {
            guard let id = Self.displayID(of: screen) else { continue }
            let options = workspace.desktopImageOptions(for: screen) ?? [:]
            var original = Self.originalWallpaper(for: screen, recorded: recorded[id])
            var known = UserDefaults.standard.dictionary(forKey: Self.knownKey) as? [String: String] ?? [:]
            if let candidate = original, FileManager.default.isReadableFile(atPath: candidate.path) {
                known[id] = candidate.path
                UserDefaults.standard.set(known, forKey: Self.knownKey)
            } else if let last = known[id], FileManager.default.isReadableFile(atPath: last) {
                // The system reported nothing usable (e.g. it still pointed at one of our renders);
                // fall back to the last wallpaper we saw for this display.
                original = URL(fileURLWithPath: last)
            } else {
                NSLog("Away note: no readable wallpaper for display \(id), using a flat background")
            }
            guard let rendered = Self.renderToFile(text: text, appearance: appearance,
                                                   original: original, screen: screen, id: id) else { continue }
            do {
                try workspace.setDesktopImageURL(rendered, for: screen, options: options)
                originals[id] = original?.path ?? ""
            } catch {
                NSLog("Away note: could not set wallpaper for display \(id): \(error)")
            }
        }

        guard !originals.isEmpty else { return }
        UserDefaults.standard.set(originals, forKey: Self.restoreKey)

        if lock {
            // Give the Dock a moment to apply the new picture before the lock screen appears.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { Self.lockScreen() }
        }
    }

    /// Puts the original wallpapers back and deletes the rendered images.
    func restore() {
        guard let originals = UserDefaults.standard.dictionary(forKey: Self.restoreKey) as? [String: String],
              !originals.isEmpty else { return }

        let workspace = NSWorkspace.shared
        let known = UserDefaults.standard.dictionary(forKey: Self.knownKey) as? [String: String] ?? [:]
        var remaining = originals
        for screen in NSScreen.screens {
            guard let id = Self.displayID(of: screen), let recordedPath = originals[id] else { continue }
            let options = workspace.desktopImageOptions(for: screen) ?? [:]
            var path = recordedPath
            if path.isEmpty || !FileManager.default.fileExists(atPath: path) {
                path = known[id] ?? ""
            }
            guard !path.isEmpty, FileManager.default.fileExists(atPath: path) else {
                // Nothing to go back to (the wallpaper's source file is gone). Leave the note
                // up and keep the record so the next away note doesn't build on this one.
                NSLog("Away note: no original wallpaper to restore for display \(id)")
                continue
            }
            do {
                try workspace.setDesktopImageURL(URL(fileURLWithPath: path), for: screen, options: options)
                remaining.removeValue(forKey: id)
            } catch {
                NSLog("Away note: could not restore wallpaper for display \(id): \(error)")
            }
        }

        if remaining.isEmpty {
            UserDefaults.standard.removeObject(forKey: Self.restoreKey)
            try? FileManager.default.removeItem(at: Self.renderDirectory)
        } else {
            UserDefaults.standard.set(remaining, forKey: Self.restoreKey)
        }
    }

    /// The wallpaper to composite on and restore to. If a previous restore could not apply,
    /// the current wallpaper is one of our renders, so prefer the recorded original.
    private static func originalWallpaper(for screen: NSScreen, recorded: String?) -> URL? {
        if let recorded, !recorded.isEmpty { return URL(fileURLWithPath: recorded) }
        guard let current = NSWorkspace.shared.desktopImageURL(for: screen) else { return nil }
        if current.path.hasPrefix(renderDirectory.path) { return nil }
        return current
    }

    // MARK: - Rendering

    static var renderDirectory: URL {
        URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AwayNote", isDirectory: true)
    }

    private static func displayID(of screen: NSScreen) -> String? {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }
        return number.stringValue
    }

    /// Renders the wallpaper-plus-sign image for one display and writes it as a PNG.
    static func renderToFile(text: String, appearance: Appearance, original: URL?,
                             screen: NSScreen, id: String) -> URL? {
        let base = original.flatMap { NSImage(contentsOf: $0) }
        guard let rep = render(text: text, appearance: appearance, base: base,
                               size: screen.frame.size, scale: screen.backingScaleFactor),
              let png = rep.representation(using: .png, properties: [:]) else { return nil }

        let directory = renderDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Drop earlier renders for this display; the current wallpaper file itself stays readable
        // to the system until the new one is applied because the Dock keeps its own copy.
        if let files = try? FileManager.default.contentsOfDirectory(atPath: directory.path) {
            for file in files where file.hasPrefix("away-\(id)-") {
                try? FileManager.default.removeItem(at: directory.appendingPathComponent(file))
            }
        }
        // Unique name per render so the Dock never serves a cached earlier note.
        let url = directory.appendingPathComponent("away-\(id)-\(Int(Date().timeIntervalSince1970)).png")
        do {
            try png.write(to: url)
            return url
        } catch {
            NSLog("Away note: could not write image: \(error)")
            return nil
        }
    }

    /// Draws `base` (aspect-filled) or a flat dark background, then the sign in the
    /// lower part of the screen, clear of the lock screen's clock and password field.
    static func render(text: String, appearance: Appearance, base: NSImage?,
                       size: NSSize, scale: CGFloat) -> NSBitmapImageRep? {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                         pixelsWide: Int(size.width * scale),
                                         pixelsHigh: Int(size.height * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        rep.size = size

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        defer { NSGraphicsContext.restoreGraphicsState() }
        // The bitmap context is in pixels; draw in points.
        context.cgContext.scaleBy(x: scale, y: scale)

        let full = NSRect(origin: .zero, size: size)
        if let base, base.size.width > 0, base.size.height > 0 {
            let ratio = max(size.width / base.size.width, size.height / base.size.height)
            let drawSize = NSSize(width: base.size.width * ratio, height: base.size.height * ratio)
            let origin = NSPoint(x: (size.width - drawSize.width) / 2, y: (size.height - drawSize.height) / 2)
            base.draw(in: NSRect(origin: origin, size: drawSize), from: .zero, operation: .copy, fraction: 1)
        } else {
            NSColor(white: 0.12, alpha: 1).setFill()
            full.fill()
        }

        // The sign: 64% wide, 28% tall, centred on the screen.
        let box = NSRect(x: size.width * 0.18, y: size.height * 0.36,
                         width: size.width * 0.64, height: size.height * 0.28)
        let isDark = appearance == .dark
        let boxPath = NSBezierPath(roundedRect: box, xRadius: 28, yRadius: 28)
        (isDark ? NSColor(white: 0.1, alpha: 0.88) : NSColor(white: 0.97, alpha: 0.92)).setFill()
        boxPath.fill()
        (isDark ? NSColor.white.withAlphaComponent(0.18) : NSColor.black.withAlphaComponent(0.12)).setStroke()
        boxPath.lineWidth = 1
        boxPath.stroke()

        let textBox = box.insetBy(dx: 32, dy: 32)
        let fontSize = TextFitter.fontSize(for: text, in: textBox.size)
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.lineHeightMultiple = 1.02
        let attributed = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .semibold),
            .foregroundColor: isDark ? NSColor.white : NSColor.black,
            .paragraphStyle: style
        ])
        let options: NSString.DrawingOptions = [.usesLineFragmentOrigin, .usesFontLeading]
        let textHeight = attributed.boundingRect(
            with: NSSize(width: textBox.width, height: .greatestFiniteMagnitude), options: options).height
        let textRect = NSRect(x: textBox.minX, y: textBox.midY - textHeight / 2,
                              width: textBox.width, height: textHeight)
        attributed.draw(with: textRect, options: options)

        return rep
    }

    // MARK: - Lock

    /// Locks the screen the same way ⌃⌘Q does, via the login framework.
    private static func lockScreen() {
        typealias LockFunction = @convention(c) () -> Int32
        guard let handle = dlopen("/System/Library/PrivateFrameworks/login.framework/login", RTLD_NOW),
              let symbol = dlsym(handle, "SACLockScreenImmediate") else {
            NSLog("Away note: screen lock unavailable; press ⌃⌘Q to lock.")
            return
        }
        let lock = unsafeBitCast(symbol, to: LockFunction.self)
        _ = lock()
    }
}
