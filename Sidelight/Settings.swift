import Foundation

enum Corner: String {
    case right
    case left
}

enum Appearance: String {
    case dark
    case light
}

/// UserDefaults-backed settings. The hotkeys themselves are stored by KeyboardShortcuts.
enum Settings {
    private static let cornerKey = "corner"
    private static let appearanceKey = "appearance"

    static var appearance: Appearance {
        get {
            let raw = UserDefaults.standard.string(forKey: appearanceKey) ?? ""
            return Appearance(rawValue: raw) ?? .dark
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: appearanceKey)
        }
    }

    static var corner: Corner {
        get {
            let raw = UserDefaults.standard.string(forKey: cornerKey) ?? ""
            return Corner(rawValue: raw) ?? .right
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: cornerKey)
        }
    }
}
