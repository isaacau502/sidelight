import AppKit
import QuartzCore

/// The floating, non-activating HUD panel that hosts the text view.
final class SidelightPanel: NSPanel {
    static let size = NSSize(width: 720, height: 420)
    static let screenInset: CGFloat = 16
    static let cornerRadius: CGFloat = 22
    static let idleInterval: TimeInterval = 10

    let textView: SidelightTextView
    /// Called with the note text when the user commits in away mode.
    var onCommit: (String) -> Void = { _ in }
    private(set) var isAwayMode = false
    private let backdrop: NSView
    private var idleTimer: Timer?
    private var isHiding = false

    // MARK: - Init

    init() {
        let contentRect = NSRect(origin: .zero, size: Self.size)
        textView = SidelightTextView(frame: contentRect)
        backdrop = Self.makeBackdrop(hosting: textView, size: Self.size)

        super.init(contentRect: contentRect,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)

        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        isMovable = false
        isMovableByWindowBackground = false
        hasShadow = true
        backgroundColor = .clear
        isOpaque = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        isReleasedWhenClosed = false
        animationBehavior = .none

        contentView = backdrop
        applyAppearance()

        textView.onDismiss = { [weak self] in self?.hide() }
        textView.onQuit = { NSApp.terminate(nil) }
        textView.onKeystroke = { [weak self] in self?.resetIdleTimer() }
        textView.onCommit = { [weak self] text in
            guard let self else { return }
            self.onCommit(text)
            self.hide()
        }
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    // MARK: - Backdrop

    private static func makeBackdrop(hosting view: NSView, size: NSSize) -> NSView {
        let frame = NSRect(origin: .zero, size: size)
        let backdrop: NSView

        if #available(macOS 26, *) {
            let glass = NSGlassEffectView(frame: frame)
            glass.cornerRadius = Self.cornerRadius
            glass.contentView = view
            backdrop = glass
        } else {
            let effect = NSVisualEffectView(frame: frame)
            effect.blendingMode = .behindWindow
            effect.state = .active
            effect.wantsLayer = true
            effect.layer?.cornerRadius = Self.cornerRadius
            effect.layer?.cornerCurve = .continuous
            effect.layer?.borderWidth = 0.5
            effect.layer?.masksToBounds = true
            view.frame = effect.bounds
            effect.addSubview(view)
            backdrop = effect
        }

        backdrop.wantsLayer = true
        backdrop.autoresizingMask = [.width, .height]
        if let layer = backdrop.layer {
            // AppKit layers anchor at (0,0); centre the anchor so the scale animation is centred.
            layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            layer.position = CGPoint(x: frame.midX, y: frame.midY)
            // Round the window's alpha shape too, so the window shadow follows the corners
            // instead of the rectangular frame.
            layer.cornerRadius = Self.cornerRadius
            layer.cornerCurve = .continuous
            layer.masksToBounds = true
        }
        return backdrop
    }

    // MARK: - Appearance

    /// Applies the dark/light setting to the window, backdrop and text.
    func applyAppearance() {
        let mode = Settings.appearance
        appearance = NSAppearance(named: mode == .dark ? .darkAqua : .aqua)

        if #available(macOS 26, *), let glass = backdrop as? NSGlassEffectView {
            glass.tintColor = mode == .dark
                ? NSColor(white: 0.1, alpha: 0.6)
                : NSColor(white: 0.97, alpha: 0.6)
        } else if let effect = backdrop as? NSVisualEffectView {
            effect.material = mode == .dark ? .hudWindow : .popover
            effect.layer?.borderColor = (mode == .dark
                ? NSColor.white.withAlphaComponent(0.18)
                : NSColor.black.withAlphaComponent(0.12)).cgColor
        }

        textView.inkColor = mode == .dark ? .white : .black
        textView.placeholderColor = mode == .dark
            ? NSColor(white: 0.55, alpha: 1)
            : NSColor(white: 0.62, alpha: 1)
        if isVisible { invalidateShadow() }
    }

    // MARK: - Position

    /// Places the panel 16 pt below the menu bar and 16 pt in from the chosen side of the
    /// main screen's visible frame (which excludes the menu bar and the Dock).
    func reposition() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        let x: CGFloat
        switch Settings.corner {
        case .right: x = visible.maxX - Self.screenInset - Self.size.width
        case .left:  x = visible.minX + Self.screenInset
        }
        let y = visible.maxY - Self.screenInset - Self.size.height
        setFrameOrigin(NSPoint(x: x, y: y))
    }

    /// Opens the panel in `corner`, or slides it there if it is already open.
    func show(in corner: Corner) {
        Settings.corner = corner
        if isVisible && !isHiding {
            reposition()
        } else {
            show()
        }
    }

    // MARK: - Show / hide

    func toggle() {
        if isVisible && !isHiding { hide() } else { show() }
    }

    /// Opens the panel in away mode: Return commits the note instead of adding a line.
    func showAway() {
        if !isVisible || isHiding { show() }
        setAwayMode(true)
    }

    private func setAwayMode(_ away: Bool) {
        isAwayMode = away
        textView.commitsOnReturn = away
        textView.placeholderText = away ? "away note" : "type"
    }

    func show() {
        guard !isVisible || isHiding else { return }
        isHiding = false
        setAwayMode(false)
        reposition()
        textView.clear()
        textView.refit()
        alphaValue = 0
        makeKeyAndOrderFront(nil)
        makeFirstResponder(textView)
        // The shadow is computed before the glass has rendered; recompute it from the drawn shape.
        DispatchQueue.main.async { [weak self] in self?.invalidateShadow() }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = 1
        }

        if let layer = contentView?.layer {
            let scale = CABasicAnimation(keyPath: "transform")
            scale.fromValue = CATransform3DMakeScale(0.96, 0.96, 1)
            scale.toValue = CATransform3DIdentity
            scale.duration = 0.12
            scale.timingFunction = CAMediaTimingFunction(name: .easeOut)
            layer.removeAnimation(forKey: "show")
            layer.add(scale, forKey: "show")
            layer.transform = CATransform3DIdentity
        }

        resetIdleTimer()
    }

    func hide() {
        guard isVisible, !isHiding else { return }
        isHiding = true
        cancelIdleTimer()

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.08
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, self.isHiding else { return }
            self.orderOut(nil)
            self.textView.clear()
            self.alphaValue = 1
            self.isHiding = false
        })
    }

    override func resignKey() {
        super.resignKey()
        hide()
    }

    // MARK: - Idle dim

    private func resetIdleTimer() {
        cancelIdleTimer()
        // Zero-duration group so this overrides any in-flight dim animation.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            animator().alphaValue = 1
        }
        idleTimer = Timer.scheduledTimer(withTimeInterval: Self.idleInterval, repeats: false) { [weak self] _ in
            self?.dim()
        }
    }

    private func cancelIdleTimer() {
        idleTimer?.invalidate()
        idleTimer = nil
    }

    private func dim() {
        guard isVisible, !isHiding else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.3
            animator().alphaValue = 0.5
        }
    }
}
