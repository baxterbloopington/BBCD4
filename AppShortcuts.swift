import AppKit
import SwiftUI

struct AppShortcut: Equatable {
    let key: String
    let modifiers: NSEvent.ModifierFlags

    private static let supportedModifiers: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
    private static let specialKeysByKeyCode: [UInt16: String] = [
        36: "return", 48: "tab", 49: "space", 51: "delete", 53: "escape",
        64: "F17", 71: "clear", 76: "enter", 79: "F18", 80: "F19",
        90: "F20", 96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8",
        101: "F9", 103: "F11", 105: "F13", 106: "F16", 107: "F14",
        109: "F10", 111: "F12", 113: "F15", 115: "home", 116: "pageUp",
        117: "forwardDelete", 118: "F4", 119: "end", 120: "F2", 121: "pageDown",
        122: "F1", 123: "leftArrow", 124: "rightArrow", 125: "downArrow", 126: "upArrow"
    ]
    private static let specialKeyDisplays: [String: String] = [
        "escape": "Esc", "tab": "⇥", "space": "Space", "return": "↩", "enter": "⌤",
        "delete": "⌫", "forwardDelete": "⌦", "clear": "⌧", "leftArrow": "←",
        "rightArrow": "→", "upArrow": "↑", "downArrow": "↓", "home": "↖",
        "end": "↘", "pageUp": "⇞", "pageDown": "⇟"
    ]

    init(key: String, modifiers: NSEvent.ModifierFlags = []) {
        self.key = Self.normalisedKey(key)
        self.modifiers = modifiers.intersection(Self.supportedModifiers)
    }

    init?(storedValue: String) {
        let components = storedValue.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard let lastComponent = components.last else {
            return nil
        }
        let key: String
        if lastComponent.hasPrefix("key=") {
            let encodedKey = String(lastComponent.dropFirst(4))
            key = encodedKey.removingPercentEncoding ?? encodedKey
        } else {
            key = lastComponent
        }
        guard Self.isSupportedKey(key) else { return nil }

        var modifiers: NSEvent.ModifierFlags = []
        for component in components.dropLast() {
            switch component {
            case "command": modifiers.insert(.command)
            case "option": modifiers.insert(.option)
            case "control": modifiers.insert(.control)
            case "shift": modifiers.insert(.shift)
            default: return nil
            }
        }

        self.init(key: key, modifiers: modifiers)
    }

    init?(event: NSEvent) {
        if [36, 53, 76].contains(event.keyCode) {
            return nil
        }
        if let specialKey = Self.specialKeysByKeyCode[event.keyCode] {
            self.init(key: specialKey, modifiers: event.modifierFlags)
            return
        }

        guard let key = event.charactersIgnoringModifiers,
              key.unicodeScalars.count == 1,
              Self.isSupportedKey(key) else {
            return nil
        }

        self.init(key: key, modifiers: event.modifierFlags)
    }

    init?(keyPress: KeyPress) {
        let key = keyPress.characters
        guard Self.isSupportedKey(key) else { return nil }

        var modifiers: NSEvent.ModifierFlags = []
        if keyPress.modifiers.contains(.command) { modifiers.insert(.command) }
        if keyPress.modifiers.contains(.option) { modifiers.insert(.option) }
        if keyPress.modifiers.contains(.control) { modifiers.insert(.control) }
        if keyPress.modifiers.contains(.shift) { modifiers.insert(.shift) }
        self.init(key: key, modifiers: modifiers)
    }

    var storedValue: String {
        var components: [String] = []
        if modifiers.contains(.command) { components.append("command") }
        if modifiers.contains(.option) { components.append("option") }
        if modifiers.contains(.control) { components.append("control") }
        if modifiers.contains(.shift) { components.append("shift") }
        let encodedKey = key.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? key
        components.append("key=\(encodedKey)")
        return components.joined(separator: "|")
    }

    var displayValue: String {
        modifierDisplayValue + (Self.specialKeyDisplays[key] ?? key)
    }

    var hintDisplayValue: String {
        let letter = key.count == 1 && key.allSatisfy(\.isLetter)
        return modifierDisplayValue + (Self.specialKeyDisplays[key] ?? (letter ? key.lowercased() : key))
    }

    private var modifierDisplayValue: String {
        var display = ""
        if modifiers.contains(.control) { display += "⌃" }
        if modifiers.contains(.option) { display += "⌥" }
        if modifiers.contains(.shift) { display += "⇧" }
        if modifiers.contains(.command) { display += "⌘" }
        return display
    }

    func matches(_ other: AppShortcut) -> Bool {
        key == other.key && modifiers == other.modifiers
    }

    func matches(_ keyPress: KeyPress) -> Bool {
        let pressedKey = keyPress.characters == "\u{1B}" ? "escape" : Self.normalisedKey(keyPress.characters)
        guard pressedKey == key else { return false }
        let pressedModifiers = keyPress.modifiers.intersection([.command, .option, .control, .shift])
        let shortcutModifiers: EventModifiers = [
            modifiers.contains(.command) ? .command : [],
            modifiers.contains(.option) ? .option : [],
            modifiers.contains(.control) ? .control : [],
            modifiers.contains(.shift) ? .shift : []
        ]
        return pressedModifiers == shortcutModifiers
    }

    private static func isSupportedKey(_ key: String) -> Bool {
        if ["escape", "return", "enter"].contains(key) { return false }
        if specialKeyDisplays[key] != nil || specialKeysByKeyCode.values.contains(key) {
            return true
        }
        guard key.unicodeScalars.count == 1,
              let scalar = key.unicodeScalars.first else {
            return false
        }
        return !CharacterSet.controlCharacters.contains(scalar)
            && !CharacterSet.whitespacesAndNewlines.contains(scalar)
    }

    private static func normalisedKey(_ key: String) -> String {
        if specialKeyDisplays[key] != nil || specialKeysByKeyCode.values.contains(key) {
            return key
        }
        return key.uppercased()
    }
}

enum AppKeybinding: String, CaseIterable, Identifiable {
    case editSelectedItem = "editSelectedItemKeybind"
    case toggleFavourite = "toggleFavouriteKeybind"
    case setTelevision = "setTelevisionKeybind"
    case setRadio = "setRadioKeybind"
    case setLiveStream = "setLiveStreamKeybind"
    case addDownloadToQueue = "addDownloadToQueueKeybind"
    case showDownloadQueue = "showDownloadQueueKeybind"
    case toggleEncode = "toggleEncodeKeybind"
    case openSettings = "openSettingsKeybind"
    case openManageStreams = "openManageStreamsKeybind"
    case download = "downloadKeybind"
    case trimIn = "trimInKeybind"
    case trimOut = "trimOutKeybind"
    case trimCut = "trimCutKeybind"
    case trimReset = "trimResetKeybind"
    case trimPreviousEditPoint = "trimPreviousEditPointKeybind"
    case trimNextEditPoint = "trimNextEditPointKeybind"
    case trimPlayback = "trimPlaybackKeybind"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .editSelectedItem: "Edit selected stream / preset time"
        case .toggleFavourite: "Toggle selected stream as favourite"
        case .setTelevision: "Set selected stream type to TV"
        case .setRadio: "Set selected stream type to radio"
        case .setLiveStream: "Set selected stream type to live stream"
        case .addDownloadToQueue: "Add download to queue"
        case .showDownloadQueue: "Show download queue"
        case .toggleEncode: "Toggle encode"
        case .openSettings: "Open settings"
        case .openManageStreams: "Open Manage Streams"
        case .download: "Download / cancel active download"
        case .trimIn: "Set trim start at playhead (In)"
        case .trimOut: "Set trim end at playhead (Out)"
        case .trimCut: "Start / finish cut at playhead"
        case .trimReset: "Reset trim and cuts"
        case .trimPreviousEditPoint: "Previous edit point"
        case .trimNextEditPoint: "Next edit point"
        case .trimPlayback: "Play / pause edited output"
        }
    }

    var defaultShortcut: AppShortcut {
        switch self {
        case .editSelectedItem: AppShortcut(key: "E")
        case .toggleFavourite: AppShortcut(key: "F")
        case .setTelevision: AppShortcut(key: "T")
        case .setRadio: AppShortcut(key: "R")
        case .setLiveStream: AppShortcut(key: "L")
        case .addDownloadToQueue: AppShortcut(key: "Q")
        case .showDownloadQueue: AppShortcut(key: "P")
        case .toggleEncode: AppShortcut(key: "E")
        case .openSettings: AppShortcut(key: "S")
        case .openManageStreams: AppShortcut(key: "M")
        case .download: AppShortcut(key: "D")
        case .trimIn: AppShortcut(key: "I")
        case .trimOut: AppShortcut(key: "O")
        case .trimCut: AppShortcut(key: "C")
        case .trimReset: AppShortcut(key: "R")
        case .trimPreviousEditPoint: AppShortcut(key: "P")
        case .trimNextEditPoint: AppShortcut(key: "N")
        case .trimPlayback: AppShortcut(key: "space")
        }
    }

    var enabledStorageKey: String { rawValue + "Enabled" }

    static let streamManagementActions: [AppKeybinding] = [
        .editSelectedItem, .toggleFavourite, .setTelevision, .setRadio, .setLiveStream
    ]

    static let mainWindowActions: [AppKeybinding] = [
        .toggleEncode, .openSettings, .openManageStreams,
        .addDownloadToQueue, .showDownloadQueue, .download
    ]

    static let otherActions: [AppKeybinding] = [
        .toggleFavourite, .setTelevision, .setRadio, .setLiveStream, .editSelectedItem
    ]

    static let trimActions: [AppKeybinding] = [.trimIn, .trimOut, .trimCut, .trimReset, .trimPreviousEditPoint, .trimNextEditPoint, .trimPlayback]

    func matches(_ shortcut: AppShortcut, defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: enabledStorageKey) as? Bool ?? true else { return false }
        return self.shortcut(from: defaults.string(forKey: rawValue) ?? defaultShortcut.storedValue).matches(shortcut)
    }

    func shortcut(from storedValue: String) -> AppShortcut {
        AppShortcut(storedValue: storedValue) ?? defaultShortcut
    }

    func hint(_ message: String, storedValue: String, enabled: Bool) -> String {
        enabled ? "\(message) (\(shortcut(from: storedValue).hintDisplayValue))" : message
    }
}
