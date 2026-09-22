import AppKit

/// The single text view inside the panel. Handles the panel's key table,
/// draws the "type" placeholder, and refits the font on every change.
final class SidelightTextView: NSTextView {
    static let padding: CGFloat = 24
    static let weight: NSFont.Weight = .semibold
    static let lineHeightMultiple: CGFloat = 1.02

    var onDismiss: () -> Void = {}
    var onQuit: () -> Void = {}
    var onKeystroke: () -> Void = {}
    /// Away mode: Return commits the text instead of inserting a newline.
    var commitsOnReturn = false
    var onCommit: (String) -> Void = { _ in }

    var placeholderText = "type" {
        didSet { needsDisplay = true }
    }

    /// Placeholder colour. Opaque on purpose: translucent greys get washed out by the
    /// glass backdrop's vibrant blending, especially in light mode.
    var placeholderColor: NSColor = NSColor(white: 0.55, alpha: 1) {
        didSet { needsDisplay = true }
    }

    /// Text colour; the panel sets this from the appearance setting.
    var inkColor: NSColor = .white {
        didSet {
            textColor = inkColor
            refit()
        }
    }

    /// The area text must fit inside: the frame minus padding on all sides.
    private var fitBox: CGSize {
        CGSize(width: bounds.width - 2 * Self.padding, height: bounds.height - 2 * Self.padding)
    }

    // MARK: - Init

    override init(frame: NSRect) {
        // Explicit TextKit 1 stack so `layoutManager.usedRect` is available directly.
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: CGSize(width: frame.width - 2 * Self.padding,
                                                     height: .greatestFiniteMagnitude))
        container.widthTracksTextView = false
        container.heightTracksTextView = false
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)

        super.init(frame: frame, textContainer: container)

        isRichText = false
        isFieldEditor = false
        isEditable = true
        isSelectable = true
        allowsUndo = true
        drawsBackground = false
        isVerticallyResizable = false
        isHorizontallyResizable = false
        autoresizingMask = [.width, .height]
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isAutomaticTextCompletionEnabled = false
        isAutomaticLinkDetectionEnabled = false
        isAutomaticDataDetectionEnabled = false
        isContinuousSpellCheckingEnabled = false
        isGrammarCheckingEnabled = false
        usesFindBar = false
        usesFontPanel = false
        usesRuler = false
        smartInsertDeleteEnabled = false
        importsGraphics = false
        alignment = .center
        textColor = inkColor
        insertionPointColor = .clear
        textContainerInset = NSSize(width: Self.padding, height: Self.padding)

        refit()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var acceptsFirstResponder: Bool { true }

    // MARK: - Fitting

    override func didChangeText() {
        super.didChangeText()
        refit()
    }

    /// Recomputes the font size for the current text and vertically centres it.
    func refit() {
        guard let layoutManager, let textContainer else { return }

        let size = TextFitter.fontSize(for: string, in: fitBox, weight: Self.weight)
        let font = NSFont.systemFont(ofSize: size, weight: Self.weight)
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.lineHeightMultiple = Self.lineHeightMultiple
        // A lone word wider than the box must clip, never break mid-character.
        let isSingleWord = !string.contains(where: { $0.isWhitespace || $0.isNewline })
        style.lineBreakMode = isSingleWord ? .byClipping : .byWordWrapping

        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .paragraphStyle: style,
            .foregroundColor: inkColor
        ]
        let full = NSRange(location: 0, length: textStorage?.length ?? 0)
        if full.length > 0 {
            textStorage?.beginEditing()
            textStorage?.setAttributes(attrs, range: full)
            textStorage?.endEditing()
        }
        typingAttributes = attrs
        defaultParagraphStyle = style
        self.font = font

        layoutManager.ensureLayout(for: textContainer)
        let used = layoutManager.usedRect(for: textContainer).height
        let vertical = max(Self.padding, (bounds.height - used) / 2)
        textContainerInset = NSSize(width: Self.padding, height: vertical)
        needsDisplay = true
    }

    func clear() {
        guard !string.isEmpty else { return }
        string = ""
        didChangeText()
    }

    // MARK: - Insertion point

    /// The panel is a sign, not an editor: never draw the blinking caret.
    override func drawInsertionPoint(in rect: NSRect, color: NSColor, turnedOn flag: Bool) {}

    // MARK: - Placeholder

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty else { return }

        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: TextFitter.minSize, weight: Self.weight),
            .foregroundColor: placeholderColor,
            .paragraphStyle: style
        ]
        let placeholder = NSAttributedString(string: placeholderText, attributes: attrs)
        let height = placeholder.size().height
        let rect = NSRect(x: 0, y: (bounds.height - height) / 2, width: bounds.width, height: height)
        placeholder.draw(in: rect)
    }

    // MARK: - Keys

    private enum KeyCode {
        static let escape: UInt16 = 53
        static let delete: UInt16 = 51
        static let returnKey: UInt16 = 36
        static let keypadEnter: UInt16 = 76
    }

    override func keyDown(with event: NSEvent) {
        onKeystroke()
        let mods = Self.relevantModifiers(of: event)

        switch event.keyCode {
        case KeyCode.escape:
            onDismiss()
            return
        case KeyCode.delete where mods == .command:
            clear()
            return
        case KeyCode.returnKey, KeyCode.keypadEnter:
            if commitsOnReturn && mods.isEmpty {
                let text = string.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { onCommit(text) }
                return
            }
            super.keyDown(with: event)
        default:
            super.keyDown(with: event)
        }
    }

    /// The app never becomes active (non-activating panel), so main-menu key
    /// equivalents do not fire. Handle the ones the panel needs here.
    /// Arrow and delete keys carry `.numericPad` / `.function` flags; ignore those so
    /// "option only" and "command only" comparisons work.
    private static func relevantModifiers(of event: NSEvent) -> NSEvent.ModifierFlags {
        event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.numericPad, .function, .capsLock])
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let mods = Self.relevantModifiers(of: event)
        guard mods == .command else { return super.performKeyEquivalent(with: event) }
        onKeystroke()

        if event.keyCode == KeyCode.delete {
            clear()
            return true
        }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "q":
            onQuit()
            return true
        case "a":
            selectAll(nil)
            return true
        case "c":
            copy(nil)
            return true
        case "v":
            paste(nil)
            return true
        case "x":
            cut(nil)
            return true
        case "z":
            undoManager?.undo()
            return true
        default:
            return super.performKeyEquivalent(with: event)
        }
    }
}
