import AppKit
import SwiftUI

private struct AppShortcut: Equatable {
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
        var display = ""
        if modifiers.contains(.control) { display += "⌃" }
        if modifiers.contains(.option) { display += "⌥" }
        if modifiers.contains(.shift) { display += "⇧" }
        if modifiers.contains(.command) { display += "⌘" }
        return display + (Self.specialKeyDisplays[key] ?? key)
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

private var isTextInputOrMenuActive: Bool {
    MainActor.assumeIsolated {
        guard let responder = NSApp.keyWindow?.firstResponder else { return false }
        return responder is NSTextView
            || responder is NSTextField
            || responder is NSComboBox
            || responder is NSPopUpButton
    }
}

private func makePrimaryActionEventMonitor(
    for windowTitle: String,
    action: @escaping () -> Void
) -> Any? {
    NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard [36, 76].contains(event.keyCode),
              modifiers.isEmpty,
              isSecondaryWindowFocused(title: windowTitle),
              !isTextInputOrMenuActive else {
            return event
        }

        action()
        return nil
    }
}

private func removeEventMonitor(_ monitor: Any?) {
    if let monitor {
        NSEvent.removeMonitor(monitor)
    }
}

private enum AppKeybinding: String, CaseIterable, Identifiable {
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

    func shortcut(from storedValue: String) -> AppShortcut {
        AppShortcut(storedValue: storedValue) ?? defaultShortcut
    }
}

private enum CompletionPlaybackMode: String, CaseIterable, Hashable {
    case each
    case first
    case last

    var title: String {
        switch self {
        case .each: "Each download as it completes"
        case .first: "First download only"
        case .last: "Last download only"
        }
    }
}

struct ContentView: View {
    @EnvironmentObject private var streamStore: StreamStore
    @AppStorage("downloadDefaultHours") private var defaultHours = 0
    @AppStorage("downloadDefaultMinutes") private var defaultMinutes = 1
    @AppStorage("downloadDefaultSeconds") private var defaultSeconds = 0
    @AppStorage("dateFormat") private var dateFormat = "dd/MM/yyyy"
    @AppStorage("downloadFolder") private var downloadFolderPath = ""
    @AppStorage("revealFinishedVideo") private var revealFinishedMedia = false
    @AppStorage(UpdateCheckFrequency.preferenceKey) private var updateCheckFrequency = UpdateCheckFrequency.onLaunch.rawValue
    @AppStorage("downloadAttempts") private var downloadAttempts = 3
    @AppStorage("retryDelay") private var retryDelay = 2.0
    @AppStorage("sequentialDownloads") private var sequentialDownloads = false
    @AppStorage("segmentDownloadLimit") private var segmentDownloadLimit = 5
    @AppStorage(StreamAvailabilityPreferences.enabledKey) private var checkStreamAvailability = StreamAvailabilityPreferences.defaultEnabled
    @AppStorage(StreamAvailabilityPreferences.intervalKey) private var streamAvailabilityInterval = StreamAvailabilityPreferences.defaultInterval
    @AppStorage(StreamAvailabilityPreferences.startInAppKey) private var showStreamCheckStartInAppNotification = true
    @AppStorage(StreamAvailabilityPreferences.activeOnlineOnlyKey) private var activeOnlineOnly = false
    @AppStorage("streamLaunchFilter") private var launchStreamFilter = "All"
    @AppStorage("activeStreamCategoryFilter") private var activeStreamCategoryFilter = ""
    @AppStorage("activeFavouritesOnly") private var activeFavouritesOnly = false
    @AppStorage("downloadFilenameFormat") private var downloadFilenameFormat = DownloadFilenameFormat.defaultFormat.rawValue
    @AppStorage("appearanceMode") private var appearanceMode = AppAppearance.system.rawValue
    @AppStorage("downloadStartInAppNotification") private var showDownloadStartInAppNotification = true
    @AppStorage("downloadCompletionInAppNotification") private var showDownloadCompletionInAppNotification = true
    @AppStorage("downloadFailureInAppNotification") private var showDownloadFailureInAppNotification = true
    @AppStorage(AppKeybinding.addDownloadToQueue.rawValue) private var addDownloadToQueueKey = AppKeybinding.addDownloadToQueue.defaultShortcut.storedValue
    @AppStorage(AppKeybinding.showDownloadQueue.rawValue) private var showDownloadQueueKey = AppKeybinding.showDownloadQueue.defaultShortcut.storedValue
    @AppStorage(AppKeybinding.toggleEncode.rawValue) private var toggleEncodeKey = AppKeybinding.toggleEncode.defaultShortcut.storedValue
    @AppStorage(AppKeybinding.openSettings.rawValue) private var openSettingsKey = AppKeybinding.openSettings.defaultShortcut.storedValue
    @AppStorage(AppKeybinding.openManageStreams.rawValue) private var openManageStreamsKey = AppKeybinding.openManageStreams.defaultShortcut.storedValue
    @AppStorage(AppKeybinding.download.rawValue) private var downloadKey = AppKeybinding.download.defaultShortcut.storedValue
    @AppStorage(AppKeybinding.addDownloadToQueue.enabledStorageKey) private var addDownloadToQueueShortcutEnabled = true
    @AppStorage(AppKeybinding.showDownloadQueue.enabledStorageKey) private var showDownloadQueueShortcutEnabled = true
    @AppStorage(AppKeybinding.toggleEncode.enabledStorageKey) private var toggleEncodeShortcutEnabled = true
    @AppStorage(AppKeybinding.openSettings.enabledStorageKey) private var openSettingsShortcutEnabled = true
    @AppStorage(AppKeybinding.openManageStreams.enabledStorageKey) private var openManageStreamsShortcutEnabled = true
    @AppStorage(AppKeybinding.download.enabledStorageKey) private var downloadShortcutEnabled = true

    @State private var encodeH265 = EncodingConfiguration.defaultEnabled
    @State private var startDate = Date()
    @State private var hours = 0
    @State private var minutes = 1
    @State private var seconds = 0
    @State private var dateInput = ""
    @State private var timeInput = ""
    @State private var isShowingCalendar = false
    @State private var validationMessage: String?
    @State private var isManagingStreams = false
    @State private var isShowingSettings = false
    @State private var isShowingDownloadQueue = false
    @State private var isShowingUpdate = false
    @State private var isShowingCancelConfirmation = false
    @State private var isShowingQueueConfirmation = false
    @State private var queueConfirmationMessage = "Added to queue"
    @State private var queueConfirmationID = UUID()
    @StateObject private var updateChecker = UpdateChecker()
    @StateObject private var timeOptionsStore = TimeOptionsStore()
    @StateObject private var streamAvailability = StreamAvailabilityMonitor()
    @ObservedObject private var downloadController: DownloadController
    @State private var shortcutEventMonitor: Any?

    init(downloadController: DownloadController) {
        _downloadController = ObservedObject(wrappedValue: downloadController)
        let defaults = UserDefaults.standard
        _encodeH265 = State(initialValue: defaults.object(forKey: "encodeH265") as? Bool ?? EncodingConfiguration.defaultEnabled)
        let start = Date()
        _startDate = State(initialValue: start)
        _dateInput = State(initialValue: DateFormats.formatter(for: defaults.string(forKey: "dateFormat") ?? "dd/MM/yyyy").string(from: start))
        _timeInput = State(initialValue: Self.timeFormatter.string(from: start))
        _hours = State(initialValue: min(350, max(0, defaults.integer(forKey: "downloadDefaultHours"))))
        _minutes = State(initialValue: defaults.object(forKey: "downloadDefaultMinutes") == nil ? 1 : min(59, max(0, defaults.integer(forKey: "downloadDefaultMinutes"))))
        _seconds = State(initialValue: min(59, max(0, defaults.integer(forKey: "downloadDefaultSeconds"))))
    }

    private var activeFilteredStreams: [Stream] {
        let filter = StreamListFilter(
            category: StreamCategory.allCases.first { $0.title == activeStreamCategoryFilter },
            favouritesOnly: activeFavouritesOnly,
            onlineOnly: checkStreamAvailability && activeOnlineOnly
        )
        return streamStore.streams.filter { stream in
            filter.matches(stream, availability: streamAvailability.results[stream.url]?.state)
        }
    }

    private var canAddToQueue: Bool {
        downloadController.isDownloading && streamStore.selectedStream != nil && duration > 0
    }

    private var canViewDownloadQueue: Bool {
        downloadController.isDownloading || !downloadController.queue.isEmpty
    }

    private var canStartDownload: Bool {
        !downloadController.isDownloading
            && streamStore.selectedStream != nil
            && duration > 0
            && isValidStartDate(startDate)
            && isValidEndDate(startDate, duration: duration)
    }

    private func handleMainShortcut(_ shortcut: AppShortcut) -> Bool {
        guard !isTextInputOrMenuActive,
              let keybinding = AppKeybinding.mainWindowActions.first(where: {
                  shortcutIsEnabled($0) && $0.shortcut(from: shortcutValue(for: $0)).matches(shortcut)
              }) else {
            return false
        }

        switch keybinding {
        case .addDownloadToQueue:
            guard canAddToQueue else { return false }
            requestDownload(addToQueue: true)
        case .showDownloadQueue:
            guard canViewDownloadQueue else { return false }
            showSecondaryWindow(title: "Download queue", isPresented: $isShowingDownloadQueue)
        case .toggleEncode:
            guard !selectedStreamIsRadio else { return false }
            encodeH265.toggle()
        case .openSettings:
            showSecondaryWindow(title: "Settings", isPresented: $isShowingSettings)
        case .openManageStreams:
            showSecondaryWindow(title: "Manage streams", isPresented: $isManagingStreams)
        case .download:
            if downloadController.isDownloading {
                isShowingCancelConfirmation = true
            } else {
                guard canStartDownload else { return false }
                requestDownload()
            }
        default:
            return false
        }

        return true
    }

    private func shortcutValue(for keybinding: AppKeybinding) -> String {
        switch keybinding {
        case .addDownloadToQueue: addDownloadToQueueKey
        case .showDownloadQueue: showDownloadQueueKey
        case .toggleEncode: toggleEncodeKey
        case .openSettings: openSettingsKey
        case .openManageStreams: openManageStreamsKey
        case .download: downloadKey
        default: keybinding.defaultShortcut.storedValue
        }
    }

    private func shortcutIsEnabled(_ keybinding: AppKeybinding) -> Bool {
        switch keybinding {
        case .addDownloadToQueue: addDownloadToQueueShortcutEnabled
        case .showDownloadQueue: showDownloadQueueShortcutEnabled
        case .toggleEncode: toggleEncodeShortcutEnabled
        case .openSettings: openSettingsShortcutEnabled
        case .openManageStreams: openManageStreamsShortcutEnabled
        case .download: downloadShortcutEnabled
        default: true
        }
    }

    private func applyLaunchFilterToActiveFilter() {
        activeFavouritesOnly = launchStreamFilter == "Favourites"
        activeOnlineOnly = launchStreamFilter == "Online" && checkStreamAvailability
        activeStreamCategoryFilter = StreamCategory.allCases
            .first { $0.title == launchStreamFilter }?
            .title ?? ""
        streamStore.selectedStreamID = activeFilteredStreams.first?.id
    }

    var body: some View {
        observedContent
    }

    private var mainWindowContent: some View {
        mainContent
    }

    private var manageStreamsWindowContent: some View {
        mainWindowContent
        .childWindow(
            isPresented: $isManagingStreams,
            title: "Manage streams",
            size: NSSize(width: 560, height: 680)
        ) {
            AnyView(
                StreamManagementView()
                    .environmentObject(streamStore)
                    .environmentObject(streamAvailability)
            )
        }
    }

    private var settingsWindowContent: some View {
        manageStreamsWindowContent
        .childWindow(
            isPresented: $isShowingSettings,
            title: "Settings",
            size: NSSize(width: SettingsLayout.sheetWidth, height: SettingsLayout.sheetHeight)
        ) {
            AnyView(SettingsView(timeOptionsStore: timeOptionsStore))
        }
    }

    private var queueWindowContent: some View {
        settingsWindowContent
        .childWindow(
            isPresented: $isShowingDownloadQueue,
            title: "Download queue",
            size: NSSize(width: ControlMetrics.mainWindowWidth, height: 520)
        ) {
            AnyView(DownloadQueueView(downloadController: downloadController))
        }
    }

    private var keyboardEnabledContent: some View {
        queueWindowContent
    }

    private var observedContent: some View {
        keyboardEnabledContent
        .onAppear {
            configureMainWindow()
            installShortcutEventMonitor()
        }
        .onDisappear(perform: removeShortcutEventMonitor)
        .onChange(of: startDate) { _, _ in syncDateInputs() }
        .onChange(of: dateFormat) { _, _ in syncDateInputs() }
        .onChange(of: appearanceMode) { _, mode in
            (AppAppearance(rawValue: mode) ?? .system).apply()
        }
        .onChange(of: activeFilteredStreams.map(\.id)) { _, ids in
            if !ids.contains(streamStore.selectedStreamID ?? "") {
                streamStore.selectedStreamID = ids.first
            }
        }
        .onChange(of: defaultHours) { _, _ in applyDefaultDuration() }
        .onChange(of: defaultMinutes) { _, _ in applyDefaultDuration() }
        .onChange(of: defaultSeconds) { _, _ in applyDefaultDuration() }
        .onChange(of: downloadController.downloadStartID) { _, _ in
            handleDownloadStarted()
        }
        .onChange(of: streamAvailability.lastCheckStarted?.id) { _, _ in
            handleStreamStatusCheckStarted()
        }
        .onChange(of: downloadController.completedOutput) { _, output in
            handleCompletedOutputChange(output)
        }
        .onChange(of: showDownloadCompletionInAppNotification) { _, isEnabled in
            handleCompletionNotificationPreferenceChange(isEnabled)
        }
        .onChange(of: showDownloadFailureInAppNotification) { _, isEnabled in
            handleFailureNotificationPreferenceChange(isEnabled)
        }
        .onChange(of: downloadController.errorMessage) { _, message in
            handleDownloadFailureMessageChange(message)
        }
        .task(id: updateCheckFrequency) {
            await updateChecker.run(frequency: UpdateCheckFrequency(rawValue: updateCheckFrequency) ?? .onLaunch)
        }
        .task(id: StreamAvailabilitySchedule(
            isEnabled: checkStreamAvailability,
            interval: streamAvailabilityInterval,
            urls: streamStore.streams.map(\.url),
            refreshID: streamAvailability.refreshID
        ), priority: .background) {
            await streamAvailability.run(StreamAvailabilitySchedule(
                isEnabled: checkStreamAvailability,
                interval: streamAvailabilityInterval,
                urls: streamStore.streams.map(\.url),
                refreshID: streamAvailability.refreshID
            ))
        }
        .modifier(BBCD4DialogModifier(
            downloadController: downloadController,
            validationMessage: $validationMessage,
            isShowingCancelConfirmation: $isShowingCancelConfirmation,
            isShowingUpdate: $isShowingUpdate,
            release: updateChecker.release,
            showCompletionNotification: showDownloadCompletionInAppNotification,
            showFailureNotification: showDownloadFailureInAppNotification
        ))
    }

    private func handleDownloadFailureMessageChange(_ message: String?) {
        guard message != nil else { return }
        guard !showDownloadFailureInAppNotification else { return }
        downloadController.errorMessage = nil
    }

    private func configureMainWindow() {
        DownloadNotifications.migrateLegacyPreferenceIfNeeded()
        applyLaunchFilterToActiveFilter()
        applyDefaultDuration()
        syncDateInputs()
    }

    private func installShortcutEventMonitor() {
        guard shortcutEventMonitor == nil else { return }
        shortcutEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard NSApp.keyWindow?.title == "BBCD4",
                  let shortcut = AppShortcut(event: event),
                  handleMainShortcut(shortcut) else {
                return event
            }
            return nil
        }
    }

    private func removeShortcutEventMonitor() {
        guard let shortcutEventMonitor else { return }
        NSEvent.removeMonitor(shortcutEventMonitor)
        self.shortcutEventMonitor = nil
    }

    private func handleDownloadStarted() {
        guard let request = downloadController.lastDownloadStarted else { return }
        guard showDownloadStartInAppNotification else { return }
        let displayDuration = downloadController.lastDownloadStartedFromQueue ? 7.0 : 5.0
        let message = DownloadNotifications.inAppStartMessage(for: request)
        showQueueConfirmation(message, displayDuration: displayDuration)
    }

    private func handleStreamStatusCheckStarted() {
        guard checkStreamAvailability, let event = streamAvailability.lastCheckStarted else { return }
        DownloadNotifications.postStreamStatusCheckStarted(event)
        guard showStreamCheckStartInAppNotification,
              !isSecondaryWindowFocused(title: "Manage streams") else { return }
        showQueueConfirmation(event.message, displayDuration: 5)
    }

    private func handleCompletedOutputChange(_ output: URL?) {
        guard output != nil else { return }
        // Playback happens before the controller advances the queue.
        if revealFinishedMedia || !showDownloadCompletionInAppNotification {
            clearCompletedDownload()
        }
    }

    private func handleCompletionNotificationPreferenceChange(_ isEnabled: Bool) {
        if !isEnabled {
            clearCompletedDownload()
        }
    }

    private func clearCompletedDownload() {
        downloadController.completedOutput = nil
        downloadController.completedRequest = nil
    }

    private func handleFailureNotificationPreferenceChange(_ isEnabled: Bool) {
        if !isEnabled {
            downloadController.errorMessage = nil
            downloadController.resolveIncompleteDownloadWithoutPrompt()
        }
    }

    private var mainContent: some View {
        VStack(spacing: 0) {
            AnyView(downloadForm)
            AnyView(queueConfirmationArea)
            Divider()
            AnyView(downloadStatusFooter)
        }
    }

    private var downloadForm: some View {
        VStack(alignment: .leading, spacing: ControlMetrics.formSectionSpacing) {
            VStack(alignment: .leading, spacing: ControlMetrics.headerSectionSpacing) {
                AnyView(mainHeader)
                VStack(alignment: .leading, spacing: ControlMetrics.inputRowSpacing) {
                    streamPicker
                    startDateAndTimeFields
                    durationFields
                }
            }
            AnyView(downloadActionControls)
        }
        .frame(width: ControlMetrics.mainContentWidth, alignment: .leading)
        .padding(.horizontal, 24)
        .padding(.top, 12)
        .padding(.bottom, 12)
    }

    private var duration: Int {
        hours * 3600 + minutes * 60 + seconds
    }

    private var mainHeader: some View {
        HStack(alignment: .center) {
            Text("BBCD4")
                .font(.largeTitle.weight(.bold))
            Spacer()
            if updateChecker.release != nil {
                Button {
                    isShowingUpdate = true
                } label: {
                    Label("Update", systemImage: "arrow.down.circle.fill")
                }
                .buttonStyle(HoverUpdateButtonStyle())
            }
        }
        .frame(height: 44)
    }

    private var streamPicker: some View {
        VStack(alignment: .leading, spacing: ControlMetrics.labelToControlSpacing) {
            MainFormLabel("Choose stream")
            HStack(spacing: ControlMetrics.iconButtonGap) {
                StreamSelector(
                    streams: activeFilteredStreams,
                    groups: streamStore.groups,
                    selection: $streamStore.selectedStreamID,
                    availability: checkStreamAvailability ? streamAvailability.results : nil,
                    checkingURLs: streamAvailability.checkingURLs
                )
                    .frame(width: ControlMetrics.streamSelectorWidth, height: ControlMetrics.height)
                Button {
                    showSecondaryWindow(title: "Manage streams", isPresented: $isManagingStreams)
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 16, weight: .medium))
                }
                .buttonStyle(HoverGlassButtonStyle())
                .frame(width: 44, height: ControlMetrics.height)
                .hoverHint("Manage streams", alignment: .topTrailing)
            }
        }
    }

    private var startDateAndTimeFields: some View {
        HStack(alignment: .top, spacing: ControlMetrics.fieldGap) {
            startDateField
            startTimeField
        }
    }

    private var startDateField: some View {
        VStack(alignment: .leading, spacing: ControlMetrics.labelToControlSpacing) {
            MainFormLabel("Start date")
            DateSelector(value: $dateInput, dateFormat: dateFormat, onCommit: commitDate) {
                isShowingCalendar.toggle()
            }
            .frame(width: ControlMetrics.dateWidth, height: ControlMetrics.height, alignment: .leading)
            .popover(isPresented: $isShowingCalendar, arrowEdge: .bottom) {
                DatePicker("", selection: Binding(
                    get: { startDate },
                    set: { newDate in
                        applyCalendarDate(newDate)
                    }
                ), displayedComponents: .date)
                .labelsHidden()
                .datePickerStyle(.graphical)
                .padding()
            }
        }
    }

    private var startTimeField: some View {
        VStack(alignment: .leading, spacing: ControlMetrics.labelToControlSpacing) {
            MainFormLabel("Start time")
            TimeSelector(value: $timeInput, options: timeOptionsStore.options, onCommit: commitTime)
                .frame(width: ControlMetrics.timeWidth, height: ControlMetrics.height, alignment: .leading)
        }
    }

    private var durationFields: some View {
        VStack(alignment: .leading, spacing: ControlMetrics.labelToControlSpacing) {
            MainFormLabel("Duration")
            HStack(spacing: ControlMetrics.fieldGap) {
                DurationControl(title: "Hours", value: $hours, range: 0...350)
                DurationControl(title: "Minutes", value: $minutes, range: 0...59)
                DurationControl(title: "Seconds", value: $seconds, range: 0...59)
            }
        }
        .frame(width: ControlMetrics.durationRowWidth, alignment: .leading)
    }

    private var downloadStatusFooter: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(downloadController.status)
                    .font(.headline)
                    .lineLimit(1)
                Spacer(minLength: 12)
                Text("Saves to \(downloadFolderSummary)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .hoverHint(downloadFolder.path, alignment: .topTrailing)
            }
            DownloadProgressTrack(
                progress: downloadController.progress,
                isActive: downloadController.isDownloading
            )
        }
        .frame(width: ControlMetrics.mainContentWidth)
        .padding(.vertical, 16)
    }

    private var queueConfirmationArea: some View {
        InAppNotificationMessage(message: queueConfirmationMessage)
            .frame(maxWidth: ControlMetrics.mainContentWidth)
            .opacity(isShowingQueueConfirmation ? 1 : 0)
            .frame(maxWidth: .infinity, minHeight: 32, maxHeight: .infinity, alignment: .top)
            .animation(.easeInOut(duration: 0.3), value: isShowingQueueConfirmation)
            .allowsHitTesting(false)
    }

    private var downloadActionControls: some View {
        VStack(alignment: .leading, spacing: ControlMetrics.encodeRowSpacing) {
            if selectedStreamIsRadio {
                encodeToggle
                    .hidden()
                    .disabled(true)
                    .accessibilityHidden(true)
            } else {
                encodeToggle
            }
            HStack(spacing: ControlMetrics.fieldGap) {
                HStack(spacing: ControlMetrics.fieldGap) {
                    primaryDownloadButton
                    downloadQueueButtons
                }
                Spacer()
                settingsButton
            }
            .frame(height: ControlMetrics.actionRowHeight)
        }
        .frame(width: ControlMetrics.mainContentWidth)
    }

    private var primaryDownloadButton: some View {
        Button(downloadController.isDownloading ? "Cancel" : "Download", action: handlePrimaryDownloadButton)
            .buttonStyle(HoverPrimaryButtonStyle())
            .frame(width: ControlMetrics.durationWidth, height: ControlMetrics.height)
            .disabled(!downloadController.isDownloading && (streamStore.selectedStream == nil || duration == 0))
    }

    private func handlePrimaryDownloadButton() {
        if downloadController.isDownloading {
            isShowingCancelConfirmation = true
        } else {
            requestDownload()
        }
    }

    private var downloadQueueButtons: some View {
        HStack(spacing: ControlMetrics.iconButtonGap) {
            Button(action: addCurrentDownloadToQueue) {
                Image(systemName: "plus.rectangle.on.rectangle")
                    .font(.system(size: 16, weight: .medium))
            }
            .buttonStyle(HoverGlassIconButtonStyle())
            .frame(width: 44, height: ControlMetrics.height)
            .disabled(!canAddToQueue)
            .buttonCursor(isEnabled: canAddToQueue)
            .hoverHint("Add download to queue", isEnabled: canAddToQueue)

            Button(action: showDownloadQueue) {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: "list.bullet")
                        .font(.system(size: 16, weight: .medium))
                    if !downloadController.queue.isEmpty {
                        Text("\(downloadController.queue.count)")
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .frame(minWidth: 18, minHeight: 18)
                            .background(Color.red, in: Capsule())
                            .overlay {
                                Capsule().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 1)
                            }
                            .offset(x: 12, y: -12)
                            .accessibilityLabel("\(downloadController.queue.count) downloads in queue")
                    }
                }
            }
            .buttonStyle(HoverGlassIconButtonStyle())
            .frame(width: 44, height: ControlMetrics.height)
            .disabled(!canViewDownloadQueue)
            .buttonCursor(isEnabled: canViewDownloadQueue)
            .hoverHint("Show download queue", isEnabled: canViewDownloadQueue)
        }
    }

    private func addCurrentDownloadToQueue() {
        requestDownload(addToQueue: true)
    }

    private func showDownloadQueue() {
        showSecondaryWindow(title: "Download queue", isPresented: $isShowingDownloadQueue)
    }

    private var encodeToggle: some View {
        Toggle("Encode", isOn: $encodeH265)
            .toggleStyle(.checkbox)
            .hoverHint(
                "Encode to H.265 to improve compatibility",
                alignment: .topLeading
            )
    }

    private var settingsButton: some View {
        Button {
            showSecondaryWindow(title: "Settings", isPresented: $isShowingSettings)
        } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 16, weight: .medium))
                .frame(width: 22, height: 22)
        }
        .buttonStyle(HoverGlassButtonStyle())
        .frame(width: 44, height: 44)
        .hoverHint("Settings", alignment: .topTrailing)
    }

    private var downloadFolder: URL {
        guard !downloadFolderPath.isEmpty else {
            return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        }
        return URL(fileURLWithPath: downloadFolderPath)
    }

    private var downloadFolderSummary: String {
        downloadFolder.lastPathComponent
    }

    private func chooseDownloadFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = downloadFolder
        guard panel.runModal() == .OK, let selectedURL = panel.url else { return }
        downloadFolderPath = selectedURL.path
    }

    private func requestDownload(addToQueue: Bool = false) {
        commitDate()
        commitTime()
        guard let stream = streamStore.selectedStream else { return }
        guard isValidStartDate(startDate) else { return }
        guard isValidEndDate(startDate, duration: duration) else { return }
        let request = DownloadRequest(
            stream: stream,
            start: startDate,
            duration: duration,
            outputFolder: downloadFolder,
            encodeH265: encodeH265,
            retryAttempts: max(1, min(10, downloadAttempts)),
            retryDelay: DownloadLimits.retryDelay(retryDelay),
            maximumConcurrentSegments: sequentialDownloads ? 1 : max(1, min(50, segmentDownloadLimit)),
            filenameFormat: DownloadFilenameFormat(rawValue: downloadFilenameFormat) ?? .defaultFormat,
            encodingConfiguration: EncodingConfiguration.load()
        )
        if addToQueue, downloadController.isDownloading {
            downloadController.enqueue(request)
            showQueueConfirmation("Added to queue")
        } else {
            downloadController.submit(request)
        }
    }

    private func showQueueConfirmation(_ message: String, displayDuration: TimeInterval = 3) {
        let confirmationID = UUID()
        queueConfirmationID = confirmationID
        queueConfirmationMessage = message
        withAnimation(.easeInOut(duration: 0.3)) {
            isShowingQueueConfirmation = true
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + displayDuration) {
            guard queueConfirmationID == confirmationID else { return }
            withAnimation(.easeInOut(duration: 0.3)) {
                isShowingQueueConfirmation = false
            }
        }
    }

    private func syncDateInputs() {
        dateInput = DateFormats.formatter(for: dateFormat).string(from: startDate)
        timeInput = Self.timeFormatter.string(from: startDate)
    }

    private func applyDefaultDuration() {
        hours = min(350, max(0, defaultHours))
        minutes = min(59, max(0, defaultMinutes))
        seconds = min(59, max(0, defaultSeconds))
    }

    private func commitDate() {
        guard let date = DateFormats.date(from: dateInput, format: dateFormat) else {
            syncDateInputs()
            return
        }
        applyDate(date)
    }

    private func commitTime() {
        guard let time = Self.timeFormatters.lazy.compactMap({ $0.date(from: timeInput) }).first else {
            syncDateInputs()
            return
        }
        let components = Calendar.current.dateComponents([.hour, .minute, .second], from: time)
        let proposedDate = Calendar.current.date(
            bySettingHour: components.hour ?? 0,
            minute: components.minute ?? 0,
            second: components.second ?? 0,
            of: startDate
        ) ?? startDate
        guard isValidStartDate(proposedDate) else {
            syncDateInputs()
            return
        }
        startDate = proposedDate
        syncDateInputs()
    }

    private func applyCalendarDate(_ date: Date) {
        applyDate(date)
        isShowingCalendar = false
        DispatchQueue.main.async {
            NSApp.windows.first(where: { $0.title == "BBCD4" })?.makeFirstResponder(nil)
        }
    }

    private func applyDate(_ date: Date) {
        let calendar = Calendar.current
        let oldTime = calendar.dateComponents([.hour, .minute, .second], from: startDate)
        let newDate = calendar.date(
            bySettingHour: oldTime.hour ?? 0,
            minute: oldTime.minute ?? 0,
            second: oldTime.second ?? 0,
            of: date
        ) ?? date
        guard isValidStartDate(newDate) else {
            syncDateInputs()
            return
        }
        startDate = newDate
        syncDateInputs()
    }

    private func isValidStartDate(_ date: Date) -> Bool {
        let now = Date()
        if date > now {
            validationMessage = "Date and time cannot be in the future."
            return false
        }
        let earliestAllowedDate: Date
        if selectedStreamIsRadio {
            earliestAllowedDate = now.addingTimeInterval(-2 * 24 * 60 * 60)
        } else {
            earliestAllowedDate = Calendar.current.date(
                byAdding: .day,
                value: -14,
                to: Calendar.current.startOfDay(for: now)
            ) ?? now
        }
        if date <= earliestAllowedDate {
            validationMessage = selectedStreamIsRadio
                ? "Radio downloads are available for the last 24 hours only."
                : "Video downloads are available for the last 14 days only."
            return false
        }
        return true
    }

    private func isValidEndDate(_ date: Date, duration: Int) -> Bool {
        guard date.addingTimeInterval(TimeInterval(duration)) <= Date() else {
            validationMessage = "This download would end in the future. Please change the start time or duration."
            return false
        }
        return true
    }

    private var selectedStreamIsRadio: Bool {
        streamStore.selectedStream?.category == .radio
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    private static let shortTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private static let timeFormatters = [timeFormatter, shortTimeFormatter]

}

private struct BBCD4DialogModifier: ViewModifier {
    @ObservedObject var downloadController: DownloadController
    @Binding var validationMessage: String?
    @Binding var isShowingCancelConfirmation: Bool
    @Binding var isShowingUpdate: Bool
    let release: AvailableRelease?
    let showCompletionNotification: Bool
    let showFailureNotification: Bool
    @State private var isShowingIncompleteDownload = false

    private var isDownloadCompletePresented: Binding<Bool> {
        Binding(
            get: {
                showCompletionNotification &&
                    downloadController.completedOutput != nil
            },
            set: {
                if !$0 {
                    downloadController.completedOutput = nil
                    downloadController.completedRequest = nil
                }
            }
        )
    }

    private var isDownloadErrorPresented: Binding<Bool> {
        Binding(
            get: {
                showFailureNotification &&
                    downloadController.incompleteDownload == nil &&
                    downloadController.errorMessage != nil
            },
            set: { if !$0 { downloadController.errorMessage = nil } }
        )
    }

    private var isValidationErrorPresented: Binding<Bool> {
        Binding(
            get: { validationMessage != nil },
            set: { if !$0 { validationMessage = nil } }
        )
    }

    private var isUpdateSheetPresented: Binding<Bool> {
        Binding(
            get: { isShowingUpdate && release != nil },
            set: { if !$0 { isShowingUpdate = false } }
        )
    }

    func body(content: Content) -> some View {
        content
            .onReceive(downloadController.$incompleteDownload) { incomplete in
                isShowingIncompleteDownload = showFailureNotification && incomplete != nil
            }
            .onChange(of: showFailureNotification) { _, enabled in
                isShowingIncompleteDownload = enabled && downloadController.incompleteDownload != nil
            }
            .alert("Download incomplete", isPresented: $isShowingIncompleteDownload, presenting: downloadController.incompleteDownload) { _ in
                Button("Retry") {
                    downloadController.errorMessage = nil
                    downloadController.retryIncompleteDownload()
                }
                .keyboardShortcut(.defaultAction)
                Button("Save") {
                    downloadController.errorMessage = nil
                    downloadController.savePartialDownload()
                }
                Button("Abort", role: .cancel) {
                    downloadController.errorMessage = nil
                    downloadController.discardIncompleteDownload()
                }
            } message: { incomplete in
                Text(incompleteDownloadMessage(incomplete))
            }
            .alert("Download complete!", isPresented: isDownloadCompletePresented) {
                Button("Show media") {
                    if let output = downloadController.completedOutput {
                        NSWorkspace.shared.open(output)
                    }
                }
                Button("OK", role: .cancel) {}
            } message: {
                Text(downloadController.completedRequest.map {
                    DownloadNotifications.completionMessage(for: $0)
                } ?? "")
            }
            .alert("Download failed", isPresented: isDownloadErrorPresented) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(downloadController.errorMessage ?? "")
            }
            .alert("Invalid date and time", isPresented: isValidationErrorPresented) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(validationMessage ?? "")
            }
            .sheet(isPresented: isUpdateSheetPresented) {
                if let release {
                    UpdateReleaseNotesView(release: release)
                }
            }
            .confirmationDialog("Cancel download?", isPresented: $isShowingCancelConfirmation, titleVisibility: .visible) {
                Button("Yes", role: .destructive) {
                    downloadController.cancelCurrentDownload()
                }
                Button("No", role: .cancel) {}
            } message: {
                Text("The current download will be cancelled.")
            }
    }

    private func incompleteDownloadMessage(_ incomplete: IncompleteDownload) -> String {
        var message = "Failed to download \(incomplete.failedSegments.count) of \(incomplete.segments.count) segments."
        if let error = downloadController.errorMessage, !error.isEmpty {
            message += "\n\n" + error
        }
        return message + "\n\nRetry the missing segments, save the downloaded parts, or abort without saving."
    }
}

enum ControlMetrics {
    static let height: CGFloat = 32
    static let formSectionSpacing: CGFloat = 12
    static let headerSectionSpacing: CGFloat = 12
    static let encodeRowSpacing: CGFloat = 10
    static let actionRowHeight: CGFloat = 44
    static let inputRowSpacing: CGFloat = 18
    static let formLabelHeight: CGFloat = 24
    static let labelToControlSpacing: CGFloat = 9
    static let cornerRadius: CGFloat = 10
    static let hoverOpacity = 0.08
    static let controlBorderOpacity = 0.10
    static let dateTimeAccessoryWidth: CGFloat = 44
    static let timeChevronOffset: CGFloat = 0
    static let timeChevronHitWidth: CGFloat = 38
    static let timeChevronHitHeight: CGFloat = 32
    static let durationAccessoryWidth: CGFloat = 28
    static let fieldGap: CGFloat = 16
    static let iconButtonGap: CGFloat = 8
    static let settingsRowHeight: CGFloat = 24
    static let dateWidth: CGFloat = 160
    static let timeWidth: CGFloat = 160
    static let mainContentWidth = streamSelectorWidth + iconButtonGap + 44
    static let mainWindowWidth = mainContentWidth + 48
    static let streamSelectorWidth = durationRowWidth
    static var dateTimeValueWidth: CGFloat { dateWidth - dateTimeAccessoryWidth }
    static var timeValueWidth: CGFloat { timeWidth - timeChevronHitWidth }
    static let durationWidth = (dateWidth + timeWidth - fieldGap) / 3
    static let durationRowWidth = durationWidth * 3 + fieldGap * 2
}

private struct UpdateReleaseNotesView: View {
    let release: AvailableRelease
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Update available!")
                    .font(.title2.weight(.bold))
                Text("Version \(release.version) is ready to download.")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
            .padding(24)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("What's new:")
                        .font(.headline)
                    Text(release.notes.isEmpty ? "Full details are available on GitHub." : release.notes)
                        .font(.body)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(24)
            }

            Divider()

            HStack {
                Spacer()
                Button("Later") {
                    dismiss()
                }
                Button("View release on GitHub") {
                    NSWorkspace.shared.open(release.url)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
            .padding(20)
        }
        .frame(minWidth: 560, idealWidth: 620, maxWidth: 680, minHeight: 440, idealHeight: 540, maxHeight: 620)
    }
}

private struct InAppNotificationMessage: View {
    let message: String

    var body: some View {
        Text(message)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(Color.primary.opacity(ControlMetrics.controlBorderOpacity), lineWidth: 1)
            }
    }
}

private struct MainFormLabel: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(.title3.weight(.semibold))
            .lineLimit(1)
            .frame(height: ControlMetrics.formLabelHeight, alignment: .bottomLeading)
    }
}

private enum SettingsLayout {
    static let sheetWidth: CGFloat = 560
    static let sheetHeight: CGFloat = 720
    static let horizontalInset: CGFloat = 24
    static let scrollbarReserve: CGFloat = 18
}
private struct SharedControlHoverEffect: ViewModifier {
    let cornerRadius: CGFloat
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .background {
                if isHovered {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(Color.primary.opacity(ControlMetrics.hoverOpacity))
                }
            }
            .onHover { isHovered = $0 }
    }
}

private extension View {
    func sharedControlHover(cornerRadius: CGFloat = ControlMetrics.cornerRadius) -> some View {
        modifier(SharedControlHoverEffect(cornerRadius: cornerRadius))
    }

    func buttonCursor(isEnabled: Bool) -> some View {
        onHover { isHovering in
            guard isHovering else {
                NSCursor.arrow.set()
                return
            }
            (isEnabled ? NSCursor.pointingHand : NSCursor.operationNotAllowed).set()
        }
    }
}

private struct DownloadProgressTrack: View {
    let progress: Double
    let isActive: Bool

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.12))

                if isActive {
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: max(0, min(1, progress)) * proxy.size.width)
                }
            }
        }
        .frame(height: 7)
        .animation(.easeOut(duration: 0.16), value: progress)
    }
}
private struct HoverGlassButtonStyle: ButtonStyle {
    let minimumHeight: CGFloat

    init(minimumHeight: CGFloat = ControlMetrics.height) {
        self.minimumHeight = minimumHeight
    }

    func makeBody(configuration: Configuration) -> some View {
        HoverGlassButton(configuration: configuration, minimumHeight: minimumHeight)
    }

}
private struct HoverGlassIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverGlassIconButton(configuration: configuration)
    }
}
private struct HoverPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverPrimaryButton(configuration: configuration)
    }
}
private struct HoverPrimaryButton: View {
    let configuration: ButtonStyle.Configuration
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false


    var body: some View {
        configuration.label
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .frame(maxWidth: .infinity, minHeight: 36)
            .background(
                isHovered ? Color.accentColor.opacity(0.76) : Color.accentColor,
                in: RoundedRectangle(cornerRadius: ControlMetrics.cornerRadius, style: .continuous)
            )
            .opacity(isEnabled ? (configuration.isPressed ? 0.72 : 1) : 0.42)
            .contentShape(RoundedRectangle(cornerRadius: ControlMetrics.cornerRadius, style: .continuous))
            .onHover { isHovered = $0 }
    }

}
private struct HoverUpdateButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverUpdateButton(configuration: configuration)
    }
}
private struct HoverUpdateButton: View {
    let configuration: ButtonStyle.Configuration
    @State private var isHovered = false

    var body: some View {
        configuration.label
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                isHovered ? Color(red: 67.0 / 255.0, green: 145.0 / 255.0, blue: 22.0 / 255.0) : Color(red: 49.0 / 255.0, green: 107.0 / 255.0, blue: 16.0 / 255.0),
                in: RoundedRectangle(cornerRadius: ControlMetrics.cornerRadius, style: .continuous)
            )
            .opacity(configuration.isPressed ? 0.72 : 1)
            .contentShape(RoundedRectangle(cornerRadius: ControlMetrics.cornerRadius, style: .continuous))
            .onHover { isHovered = $0 }
    }
}

private struct HoverHintLayout: Layout {
    let horizontalAlignment: HorizontalAlignment
    let below: Bool

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions(by: .zero)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let tooltip = subviews.first else { return }
        let size = tooltip.sizeThatFits(ProposedViewSize(width: 300, height: nil))
        let x = horizontalAlignment == .trailing ? bounds.maxX - size.width : bounds.minX
        let y = below ? bounds.maxY + 8 : bounds.minY - size.height - 8
        tooltip.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(size))
    }
}

private struct DelayedHoverHint: ViewModifier {
    let message: String
    let alignment: Alignment
    let below: Bool
    let isEnabled: Bool
    @State private var isVisible = false
    @State private var pendingWork: DispatchWorkItem?
    @State private var isMenuTracking = false

    func body(content: Content) -> some View {
        content
            .onHover { isHovering in
                pendingWork?.cancel()
                guard isEnabled, isHovering, !isMenuTracking else {
                    isVisible = false
                    return
                }

                if isHovering {
                    let work = DispatchWorkItem { isVisible = true }
                    pendingWork = work
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSMenu.didBeginTrackingNotification)) { _ in
                isMenuTracking = true
                pendingWork?.cancel()
                isVisible = false
            }
            .onReceive(NotificationCenter.default.publisher(for: NSMenu.didEndTrackingNotification)) { _ in
                isMenuTracking = false
            }
            .onChange(of: isEnabled) { _, enabled in
                if !enabled {
                    pendingWork?.cancel()
                    isVisible = false
                }
            }
            .overlay {
                if isVisible {
                    HoverHintLayout(horizontalAlignment: alignment.horizontal, below: below) {
                        Text(message)
                            .font(.system(size: 11))
                            .lineLimit(nil)
                            .multilineTextAlignment(.leading)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .stroke(.white.opacity(0.14), lineWidth: 1)
                            }
                    }
                    .allowsHitTesting(false)
                }
            }
            .onDisappear { pendingWork?.cancel() }
    }
}
private extension View {
    func hoverHint(
        _ message: String,
        alignment: Alignment = .topLeading,
        below: Bool = false,
        isEnabled: Bool = true
    ) -> some View {
        modifier(DelayedHoverHint(message: message, alignment: alignment, below: below, isEnabled: isEnabled))
    }
}
private struct HoverGlassButton: View {
    let configuration: ButtonStyle.Configuration
    let minimumHeight: CGFloat

    var body: some View {
        configuration.label
            .padding(.horizontal, 12)
            .frame(minHeight: minimumHeight)
            .background(
                .quaternary,
                in: RoundedRectangle(
                    cornerRadius: ControlMetrics.cornerRadius,
                    style: .continuous
                )
            )
            .sharedControlHover()
            .overlay {
                RoundedRectangle(
                    cornerRadius: ControlMetrics.cornerRadius,
                    style: .continuous
                )
                .stroke(Color.primary.opacity(ControlMetrics.controlBorderOpacity), lineWidth: 1)
            }
            .opacity(configuration.isPressed ? 0.72 : 1)
            .contentShape(
                RoundedRectangle(
                    cornerRadius: ControlMetrics.cornerRadius,
                    style: .continuous
                )
            )
    }
}
private struct HoverGlassIconButton: View {
    let configuration: ButtonStyle.Configuration
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        configuration.label
            .frame(maxWidth: .infinity, minHeight: ControlMetrics.height)
            .background(
                .quaternary,
                in: RoundedRectangle(
                    cornerRadius: ControlMetrics.cornerRadius,
                    style: .continuous
                )
            )
            .sharedControlHover()
            .overlay {
                RoundedRectangle(
                    cornerRadius: ControlMetrics.cornerRadius,
                    style: .continuous
                )
                .stroke(Color.primary.opacity(ControlMetrics.controlBorderOpacity), lineWidth: 1)
            }
            .opacity(isEnabled ? (configuration.isPressed ? 0.72 : 1) : 0.2)
            .contentShape(
                RoundedRectangle(
                    cornerRadius: ControlMetrics.cornerRadius,
                    style: .continuous
                )
            )
    }
}
private extension StreamAvailabilityState {
    var indicatorColor: Color {
        switch self {
        case .unknown: .secondary
        case .online: .green
        case .offline: .red
        }
    }

    var menuImage: NSImage {
        let color: NSColor
        switch self {
        case .unknown: color = .secondaryLabelColor
        case .online: color = .systemGreen
        case .offline: color = .systemRed
        }
        let image = NSImage(size: NSSize(width: 8, height: 8), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect).fill()
            return true
        }
        image.accessibilityDescription = title
        return image
    }
}

private struct StreamAvailabilityIndicator: View {
    let result: StreamAvailabilityResult?
    var isChecking = false

    var body: some View {
        Group {
            if isChecking {
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(0.6)
                    .accessibilityLabel("Checking stream status")
            } else {
                Circle()
                    .fill((result?.state ?? .unknown).indicatorColor)
                    .accessibilityLabel(result?.state.title ?? StreamAvailabilityState.unknown.title)
            }
        }
        .frame(width: 8, height: 8)
    }

    static var loadingMenuImage: NSImage? {
        let image = NSImage(systemSymbolName: "hourglass", accessibilityDescription: "Checking stream status")
        image?.size = NSSize(width: 8, height: 8)
        return image
    }
}

private struct StreamSelector: View {
    let streams: [Stream]
    let groups: [StreamGroup]
    @Binding var selection: String?
    let availability: [String: StreamAvailabilityResult]?
    let checkingURLs: Set<String>

    var body: some View {
        ZStack {
            HStack(spacing: 8) {
                if let availability, let stream = streams.first(where: { $0.id == selection }) {
                    StreamAvailabilityIndicator(result: availability[stream.url], isChecking: checkingURLs.contains(stream.url))
                }
                Text(streams.first(where: { $0.id == selection })?.name ?? "Choose a stream")
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer()
                Image(systemName: "chevron.down")
                    .font(.system(size: 15, weight: .semibold))
                    .offset(x: ControlMetrics.timeChevronOffset)
                    .frame(width: ControlMetrics.timeChevronHitWidth, height: ControlMetrics.height)
            }
            .padding(.leading, 12)
            .frame(width: ControlMetrics.streamSelectorWidth, height: ControlMetrics.height)
            .contentShape(Rectangle())

            StreamMenuTrigger(streams: streams, groups: groups, selection: $selection, availability: availability, checkingURLs: checkingURLs)
                .frame(width: ControlMetrics.streamSelectorWidth, height: ControlMetrics.height)
        }
        .contentShape(RoundedRectangle(cornerRadius: ControlMetrics.cornerRadius, style: .continuous))
        .background(.quaternary, in: RoundedRectangle(cornerRadius: ControlMetrics.cornerRadius, style: .continuous))
        .sharedControlHover()
        .overlay {
            RoundedRectangle(cornerRadius: ControlMetrics.cornerRadius, style: .continuous)
                .stroke(Color.primary.opacity(ControlMetrics.controlBorderOpacity), lineWidth: 1)
        }
    }
}
private struct StreamMenuTrigger: NSViewRepresentable {
    let streams: [Stream]
    let groups: [StreamGroup]
    @Binding var selection: String?
    let availability: [String: StreamAvailabilityResult]?
    let checkingURLs: Set<String>

    func makeNSView(context: Context) -> StreamMenuTriggerView {
        let view = StreamMenuTriggerView()
        view.onSelect = { streamID in selection = streamID }
        return view
    }

    func updateNSView(_ view: StreamMenuTriggerView, context: Context) {
        view.streams = streams
        view.groups = groups
        view.selectedID = selection
        view.availability = availability
        view.checkingURLs = checkingURLs
        view.onSelect = { streamID in selection = streamID }
    }
}

private struct StreamFilterButton: NSViewRepresentable {
    @Binding var category: StreamCategory?
    @Binding var favouritesOnly: Bool
    @Binding var onlineOnly: Bool
    let showsOnline: Bool

    func makeNSView(context: Context) -> StreamFilterControl {
        StreamFilterControl()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: StreamFilterControl, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 24, height: proposal.height ?? 24)
    }

    func updateNSView(_ control: StreamFilterControl, context: Context) {
        control.category = category
        control.favouritesOnly = favouritesOnly
        control.onlineOnly = onlineOnly
        control.showsOnline = showsOnline
        control.onSelect = { choice in
            switch choice {
            case "all":
                category = nil
                favouritesOnly = false
                onlineOnly = false
            case "favourites": favouritesOnly.toggle()
            case "online": onlineOnly.toggle()
            default:
                if let selected = StreamCategory(rawValue: choice) {
                    category = category == selected ? nil : selected
                }
            }
        }
    }
}

private final class StreamFilterButtonCell: NSButtonCell {
    override func hitTest(for event: NSEvent, in cellFrame: NSRect, of controlView: NSView) -> NSCell.HitResult {
        guard isEnabled, cellFrame.contains(controlView.convert(event.locationInWindow, from: nil)) else { return [] }
        return [.contentArea, .trackableArea]
    }
}

private final class StreamFilterControl: NSButton {
    var category: StreamCategory?
    var favouritesOnly = false
    var onlineOnly = false
    var showsOnline = false
    var onSelect: ((String) -> Void)?

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 24, height: 24))
        cell = StreamFilterButtonCell()
        title = ""
        isBordered = false
        setButtonType(.momentaryChange)
        target = self
        action = #selector(openMenu(_:))
        setAccessibilityLabel("Filter streams")
    }

    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: NSSize { NSSize(width: 24, height: 24) }

    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0) }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    func filterMenu() -> NSMenu {
        let menu = NSMenu()
        func add(_ title: String, choice: String, selected: Bool) {
            let item = NSMenuItem(title: title, action: #selector(selectFilter(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = choice
            item.state = selected ? .on : .off
            menu.addItem(item)
        }
        add("All", choice: "all", selected: category == nil && !favouritesOnly && (!showsOnline || !onlineOnly))
        menu.addItem(.separator())
        add("Favourites", choice: "favourites", selected: favouritesOnly)
        if showsOnline { add("Active", choice: "online", selected: onlineOnly) }
        menu.addItem(.separator())
        for option in StreamCategory.allCases {
            add(option.title, choice: option.rawValue, selected: category == option)
        }
        return menu
    }

    @objc private func openMenu(_ sender: Any?) {
        let point = NSPoint(x: bounds.minX, y: isFlipped ? bounds.maxY + 4 : bounds.minY - 4)
        filterMenu().popUp(positioning: nil, at: point, in: self)
    }

    @objc private func selectFilter(_ sender: NSMenuItem) {
        guard let choice = sender.representedObject as? String else { return }
        onSelect?(choice)
    }
}

private final class StreamMenuTriggerView: NSView {
    var streams: [Stream] = []
    var groups: [StreamGroup] = []
    var selectedID: String?
    var onSelect: ((String) -> Void)?
    var checkingURLs: Set<String> = [] {
        didSet { if let activeMenu { updateAvailability(in: activeMenu) } }
    }
    var availability: [String: StreamAvailabilityResult]? {
        didSet { if let activeMenu { updateAvailability(in: activeMenu) } }
    }
    private weak var activeMenu: NSMenu?

    private func updateAvailability(in menu: NSMenu) {
        for item in menu.items {
            guard let id = item.representedObject as? String,
                  let stream = streams.first(where: { $0.id == id }) else { continue }
            if let availability {
                let result = availability[stream.url]
                item.image = checkingURLs.contains(stream.url)
                    ? StreamAvailabilityIndicator.loadingMenuImage
                    : (result?.state ?? .unknown).menuImage
            } else {
                item.image = nil
            }
        }
    }

    func streamMenu() -> NSMenu {
        let menu = NSMenu()
        for section in StreamGrouping.sections(for: streams, groups: groups) {
            if !menu.items.isEmpty { menu.addItem(.separator()) }
            if let title = section.title { menu.addItem(NSMenuItem.sectionHeader(title: title)) }
            for stream in section.streams {
                let item = NSMenuItem(title: stream.name, action: #selector(selectStream(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = stream.id
                item.state = stream.id == selectedID ? .on : .off
                menu.addItem(item)
            }
        }
        updateAvailability(in: menu)
        return menu
    }

    override func mouseDown(with event: NSEvent) {
        let menu = streamMenu()
        activeMenu = menu
        defer { activeMenu = nil }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.height), in: self)
    }

    override func scrollWheel(with event: NSEvent) {
        let orderedStreams = StreamGrouping.sections(for: streams, groups: groups).flatMap(\.streams)
        guard !orderedStreams.isEmpty, event.scrollingDeltaY != 0 else { return }
        let currentIndex = orderedStreams.firstIndex { $0.id == selectedID } ?? 0
        let step = event.scrollingDeltaY > 0 ? -1 : 1
        let nextIndex = min(max(currentIndex + step, 0), orderedStreams.count - 1)
        guard nextIndex != currentIndex else { return }
        onSelect?(orderedStreams[nextIndex].id)
    }

    @objc private func selectStream(_ sender: NSMenuItem) {
        guard let streamID = sender.representedObject as? String else { return }
        onSelect?(streamID)
    }
}

private struct TimeMenuTrigger: NSViewRepresentable {
    let options: [String]
    @Binding var selection: String
    let onSelect: () -> Void
    let onHoverChanged: (Bool) -> Void

    func makeNSView(context: Context) -> TimeMenuTriggerView {
        let view = TimeMenuTriggerView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.clear.cgColor
        view.onSelect = { time in
            selection = time
            onSelect()
        }
        view.onHoverChanged = onHoverChanged
        return view
    }

    func updateNSView(_ view: TimeMenuTriggerView, context: Context) {
        view.options = options
        view.selectedValue = selection
        view.onSelect = { time in
            selection = time
            onSelect()
        }
        view.onHoverChanged = onHoverChanged
    }
}

private final class TimeMenuTriggerView: NSView {
    var options: [String] = []
    var selectedValue = ""
    var onSelect: ((String) -> Void)?
    var onHoverChanged: ((Bool) -> Void)?
    private var hoverTrackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }

        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        hoverTrackingArea = trackingArea
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        onHoverChanged?(true)
    }

    override func mouseExited(with event: NSEvent) {
        onHoverChanged?(false)
    }

    override func mouseDown(with event: NSEvent) {
        let menu = NSMenu()
        for option in options {
            let item = NSMenuItem(title: option, action: #selector(selectTime(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = option
            item.state = option == selectedValue ? .on : .off
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.height), in: self)
    }

    override func scrollWheel(with event: NSEvent) {
        guard !options.isEmpty, event.scrollingDeltaY != 0 else { return }
        let currentIndex = options.firstIndex(of: selectedValue) ?? 0
        let step = event.scrollingDeltaY > 0 ? -1 : 1
        let nextIndex = min(max(currentIndex + step, 0), options.count - 1)
        guard nextIndex != currentIndex else { return }
        onSelect?(options[nextIndex])
    }

    @objc private func selectTime(_ sender: NSMenuItem) {
        guard let time = sender.representedObject as? String else { return }
        onSelect?(time)
    }
}

private struct DateSelector: View {
    @Binding var value: String
    let dateFormat: String
    let onCommit: () -> Void
    let showCalendar: () -> Void
    @State private var isFocused = false
    @State private var isHovered = false
    @State private var isHoveringCalendar = false

    var body: some View {
        HStack(spacing: 0) {
            DateEntryField(
                value: $value,
                dateFormat: dateFormat,
                onFocusChanged: { isFocused = $0 }
            )
                .frame(width: ControlMetrics.dateTimeValueWidth,
                       height: ControlMetrics.height)

            Button(action: showCalendar) {
                Image(systemName: "calendar")
                    .font(.system(size: 16, weight: .medium))
                    .frame(width: ControlMetrics.dateTimeAccessoryWidth,
                           height: ControlMetrics.height)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background {
                if isHoveringCalendar {
                    Rectangle()
                        .fill(Color.primary.opacity(ControlMetrics.hoverOpacity))
                }
            }
            .onHover { isHoveringCalendar = $0 }
        }
        .frame(width: ControlMetrics.dateWidth, height: ControlMetrics.height)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: ControlMetrics.cornerRadius, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: ControlMetrics.cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: ControlMetrics.cornerRadius, style: .continuous)
                .fill(isHovered && !isHoveringCalendar ? Color.primary.opacity(ControlMetrics.hoverOpacity) : .clear)
                .allowsHitTesting(false)
        }
        .overlay {
            RoundedRectangle(cornerRadius: ControlMetrics.cornerRadius, style: .continuous)
                .stroke(
                    isFocused ? Color.accentColor : Color.primary.opacity(ControlMetrics.controlBorderOpacity),
                    lineWidth: isFocused ? 2 : 1)
                .allowsHitTesting(false)
        }
        .onHover { isHovered = $0 }
        .onChange(of: isFocused) { _, focused in
            if !focused { onCommit() }
        }
    }
}

private struct DateEntryField: NSViewRepresentable {
    @Binding var value: String
    let dateFormat: String
    let onFocusChanged: (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(value: $value, dateFormat: dateFormat, onFocusChanged: onFocusChanged)
    }

    func makeNSView(context: Context) -> FocusTrackingTextField {
        let field = FocusTrackingTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.alignment = .center
        field.focusRingType = .none
        field.delegate = context.coordinator
        field.onFocusChange = context.coordinator.setFocus
        field.stringValue = value
        return field
    }

    func updateNSView(_ field: FocusTrackingTextField, context: Context) {
        context.coordinator.dateFormat = dateFormat
        context.coordinator.onFocusChanged = onFocusChanged
        field.onFocusChange = context.coordinator.setFocus
        guard !context.coordinator.isNormalizing, field.stringValue != value else { return }
        field.stringValue = value
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        @Binding private var value: String
        var dateFormat: String
        var onFocusChanged: (Bool) -> Void
        var isNormalizing = false

        init(value: Binding<String>, dateFormat: String, onFocusChanged: @escaping (Bool) -> Void) {
            _value = value
            self.dateFormat = dateFormat
            self.onFocusChanged = onFocusChanged
        }

        func setFocus(_ focused: Bool) { onFocusChanged(focused) }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            let cleaned = DateFormats.sanitizedNumericInput(field.stringValue, format: dateFormat)
            isNormalizing = true
            if field.stringValue != cleaned { field.stringValue = cleaned }
            value = cleaned
            isNormalizing = false
        }
    }
}

private struct TimeSelector: View {
    @Binding var value: String
    let options: [String]
    let onCommit: () -> Void
    @State private var isFocused = false
    @State private var isHovered = false
    @State private var isHoveringMenu = false

    var body: some View {
        HStack(spacing: 0) {
            TimeEntryField(
                value: $value,
                isFocused: $isFocused,
                onCommit: onCommit
            )
            .frame(width: ControlMetrics.timeValueWidth, height: ControlMetrics.height)

            ZStack {
                Image(systemName: "chevron.down")
                    .font(.system(size: 15, weight: .semibold))
                    .offset(x: ControlMetrics.timeChevronOffset)

                TimeMenuTrigger(
                    options: options,
                    selection: $value,
                    onSelect: onCommit,
                    onHoverChanged: { isHoveringMenu = $0 }
                )
                .frame(width: ControlMetrics.timeChevronHitWidth,
                       height: ControlMetrics.timeChevronHitHeight)
            }
            .frame(width: ControlMetrics.timeChevronHitWidth,
                   height: ControlMetrics.timeChevronHitHeight)
            .background {
                if isHoveringMenu {
                    Rectangle()
                        .fill(Color.primary.opacity(ControlMetrics.hoverOpacity))
                }
            }
            .contentShape(Rectangle())
        }
        .frame(width: ControlMetrics.timeWidth, height: ControlMetrics.height)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: ControlMetrics.cornerRadius, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: ControlMetrics.cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: ControlMetrics.cornerRadius, style: .continuous)
                .fill(isHovered && !isHoveringMenu ? Color.primary.opacity(ControlMetrics.hoverOpacity) : .clear)
                .allowsHitTesting(false)
        }
        .overlay {
            RoundedRectangle(cornerRadius: ControlMetrics.cornerRadius, style: .continuous)
                .stroke(
                    isFocused
                    ? Color.accentColor
                    : Color.primary.opacity(ControlMetrics.controlBorderOpacity),
                    lineWidth: isFocused ? 2 : 1)
                .allowsHitTesting(false)
        }
        .onHover { isHovered = $0 }
    }
}

private struct TimeEntryField: NSViewRepresentable {
    @Binding var value: String
    @Binding var isFocused: Bool
    let onCommit: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(value: $value, isFocused: $isFocused, onCommit: onCommit)
    }

    func makeNSView(context: Context) -> FocusTrackingTextField {
        let field = FocusTrackingTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.backgroundColor = .clear
        field.alignment = .center
        field.font = .systemFont(ofSize: NSFont.systemFontSize)
        field.focusRingType = .none
        field.delegate = context.coordinator
        field.onFocusChange = context.coordinator.setFocus
        field.stringValue = value
        return field
    }

    func updateNSView(_ field: FocusTrackingTextField, context: Context) {
        guard !context.coordinator.isNormalizing, field.stringValue != value else { return }
        field.stringValue = value
        context.coordinator.acceptExternalValue(value)
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        @Binding private var value: String
        @Binding private var isFocused: Bool
        private let onCommit: () -> Void
        var isNormalizing = false
        private var lastAcceptedValue: String

        init(value: Binding<String>, isFocused: Binding<Bool>, onCommit: @escaping () -> Void) {
            _value = value
            _isFocused = isFocused
            self.onCommit = onCommit
            lastAcceptedValue = value.wrappedValue
        }

        func acceptExternalValue(_ newValue: String) {
            lastAcceptedValue = newValue
        }

        func setFocus(_ focused: Bool) {
            guard isFocused != focused else { return }
            isFocused = focused
            if !focused {
                onCommit()
            }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.deleteBackward(_:)),
               let field = control as? NSTextField {
                deleteLiterally(in: field, editor: textView)
                return true
            }

            guard commandSelector == #selector(NSResponder.insertNewline(_:)) else { return false }
            guard Self.isCompleteTime(value) else {
                NSSound.beep()
                return true
            }
            onCommit()
            control.window?.makeFirstResponder(nil)
            return true
        }

        private func deleteLiterally(in field: NSTextField, editor: NSTextView) {
            let (currentString, selection): (String, NSRange) = MainActor.assumeIsolated {
                (field.stringValue, editor.selectedRange())
            }
            let current = currentString as NSString
            let deletionRange: NSRange

            if selection.length > 0 {
                deletionRange = selection
            } else {
                guard selection.location > 0 else { return }
                deletionRange = NSRange(location: selection.location - 1, length: 1)
            }

            guard NSMaxRange(deletionRange) <= current.length else { return }
            let proposed = current.replacingCharacters(in: deletionRange, with: "")
            isNormalizing = true
            value = proposed
            lastAcceptedValue = proposed
            MainActor.assumeIsolated {
                field.stringValue = proposed
                editor.setSelectedRange(NSRange(location: deletionRange.location, length: 0))
            }
            isNormalizing = false
        }

        func control(
            _ control: NSControl,
            textView: NSTextView,
            shouldChangeCharactersIn affectedCharRange: NSRange,
            replacementString: String?
        ) -> Bool {
            let current = MainActor.assumeIsolated {
                (control as? NSTextField)?.stringValue ?? ""
            }
            let text = current as NSString
            guard affectedCharRange.location != NSNotFound,
                  NSMaxRange(affectedCharRange) <= text.length else {
                return false
            }

            let replacement = replacementString ?? ""
            guard replacement.isEmpty else {
                let proposed = text.replacingCharacters(in: affectedCharRange, with: replacement)
                guard Self.isValidTimeEntry(proposed) else {
                    NSSound.beep()
                    return false
                }
                return true
            }

            return true
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            let proposed = field.stringValue
            let editor = field.currentEditor() as? NSTextView

            guard Self.isValidTimeEntry(proposed) else {
                isNormalizing = true
                field.stringValue = lastAcceptedValue
                editor?.setSelectedRange(
                    NSRange(location: min(lastAcceptedValue.utf16.count, proposed.utf16.count), length: 0)
                )
                isNormalizing = false
                NSSound.beep()
                return
            }

            isNormalizing = true
            value = proposed
            lastAcceptedValue = proposed
            isNormalizing = false
        }

        private static func isCompleteTime(_ value: String) -> Bool {
            validTimeDigits(value.filter(\.isNumber)).count == 6
        }

        private static func isValidTimeEntry(_ value: String) -> Bool {
            guard value.allSatisfy({ $0.isNumber || $0 == ":" }),
                  value.filter({ $0 == ":" }).count <= 2 else {
                return false
            }

            let digits = value.filter(\.isNumber)
            guard digits.count <= 6 else { return false }

            for (index, digit) in digits.enumerated() {
                guard let number = digit.wholeNumberValue else { return false }
                let isValid: Bool

                switch index {
                case 0:
                    isValid = (0...2).contains(number)
                case 1:
                    isValid = (0...((digits.first?.wholeNumberValue ?? 0) == 2 ? 3 : 9)).contains(number)
                case 2, 4:
                    isValid = (0...5).contains(number)
                case 3, 5:
                    isValid = (0...9).contains(number)
                default:
                    isValid = false
                }

                guard isValid else { return false }
            }

            return true
        }

        private static func validTimeDigits(_ input: String) -> String {
            var result = ""

            for digit in input.prefix(6) {
                guard let value = digit.wholeNumberValue else { continue }
                let position = result.count
                let isValid: Bool

                switch position {
                case 0:
                    isValid = (0...2).contains(value)
                case 1:
                    let firstDigit = result.first?.wholeNumberValue ?? 0
                    isValid = (0...(firstDigit == 2 ? 3 : 9)).contains(value)
                case 2, 4:
                    isValid = (0...5).contains(value)
                case 3, 5:
                    isValid = (0...9).contains(value)
                default:
                    isValid = false
                }

                guard isValid else { continue }
                result.append(digit)
            }

            return result
        }
    }
}

final class FocusTrackingTextField: NSTextField {
    var focusPreservationRightInset: CGFloat = 0

    func containsEditingAccessory(at windowPoint: NSPoint) -> Bool {
        guard focusPreservationRightInset > 0 else { return false }
        let point = convert(windowPoint, from: nil)
        return NSRect(x: bounds.minX, y: bounds.minY,
                      width: bounds.width + focusPreservationRightInset,
                      height: bounds.height).contains(point)
    }
    var onFocusChange: ((Bool) -> Void)?
    private var focusTimer: Timer?
    private var reportedFocus = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        focusTimer?.invalidate()
        focusTimer = nil
        if window != nil {
            // NSTextField hands keyboard input to the window's shared field editor.
            // Check its ownership rather than inferring focus from editing events.
            let timer = Timer(timeInterval: 0.05, target: self,
                              selector: #selector(refreshFocus), userInfo: nil, repeats: true)
            RunLoop.main.add(timer, forMode: .common)
            focusTimer = timer
        }
    }

    @objc private func refreshFocus() {
        let focused: Bool
        if let window, window.isKeyWindow, let responder = window.firstResponder {
            focused = responder === self || currentEditor().map { $0 === responder } == true
        } else {
            focused = false
        }
        guard focused != reportedFocus else { return }
        reportedFocus = focused
        onFocusChange?(focused)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .iBeam)
    }

}

private struct InitialKeyboardFocusReset: NSViewRepresentable {
    func makeNSView(context: Context) -> ResetView { ResetView() }

    func updateNSView(_ view: ResetView, context: Context) {}

    final class ResetView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            window.initialFirstResponder = nil
            DispatchQueue.main.async { [weak self, weak window] in
                guard let self, let window, self.window === window else { return }
                window.makeFirstResponder(nil)
            }
        }
    }
}

private struct DurationControl: View {
    let title: String?
    @Binding var value: Int
    let range: ClosedRange<Int>
    @State private var isFocused = false
    @State private var isHovered = false
    @State private var isHoveringStepper = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 0) {
                DigitsOnlyNumberField(value: $value, range: range) {
                    isFocused = $0
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                DurationStepperAccessory(
                    value: $value,
                    range: range,
                    onHoverChanged: { isHoveringStepper = $0 }
                )
            }
            .frame(width: ControlMetrics.durationWidth, height: ControlMetrics.height)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: ControlMetrics.cornerRadius, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: ControlMetrics.cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: ControlMetrics.cornerRadius, style: .continuous)
                    .fill(isHovered && !isHoveringStepper ? Color.primary.opacity(ControlMetrics.hoverOpacity) : .clear)
                    .allowsHitTesting(false)
            }
            .overlay {
                RoundedRectangle(cornerRadius: ControlMetrics.cornerRadius, style: .continuous)
                    .stroke(isFocused ? Color.accentColor : Color.primary.opacity(ControlMetrics.controlBorderOpacity), lineWidth: isFocused ? 2 : 1)
                    .allowsHitTesting(false)
            }
            .onHover { isHovered = $0 }

            if let title {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: ControlMetrics.durationWidth, alignment: .leading)
    }
}

private struct DurationStepperAccessory: View {
    @Binding var value: Int
    let range: ClosedRange<Int>
    var onHoverChanged: ((Bool) -> Void)? = nil
    @State private var isHovered = false

    private let chevronWidth: CGFloat = 18

    var body: some View {
        VStack(spacing: 0) {
            RepeatButton(image: "chevron.up") {
                value = min(value + 1, range.upperBound)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Rectangle()
                .fill(Color.primary.opacity(ControlMetrics.controlBorderOpacity * 1.8))
                .frame(width: chevronWidth, height: 1)

            RepeatButton(image: "chevron.down") {
                value = max(value - 1, range.lowerBound)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: ControlMetrics.durationAccessoryWidth, height: ControlMetrics.height)
        .background {
            if isHovered {
                Rectangle()
                    .fill(Color.primary.opacity(ControlMetrics.hoverOpacity))
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovered = hovering
            onHoverChanged?(hovering)
        }
    }
}

private struct DigitsOnlyNumberField: View {
    @Binding var value: Int
    let range: ClosedRange<Int>
    let onFocusChanged: (Bool) -> Void
    @State private var isFocused = false

    var body: some View {
        NumberEntryField(value: $value, range: range, onFocusChanged: { isFocused = $0 })
            .onChange(of: isFocused) { _, focused in
                onFocusChanged(focused)
            }
    }
}

private struct NumberEntryField: NSViewRepresentable {
    @Binding var value: Int
    let range: ClosedRange<Int>
    let onFocusChanged: (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(value: $value, range: range, onFocusChanged: onFocusChanged)
    }

    func makeNSView(context: Context) -> FocusTrackingTextField {
        let field = FocusTrackingTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.alignment = .center
        field.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        field.focusPreservationRightInset = ControlMetrics.durationAccessoryWidth
        field.focusRingType = .none
        field.delegate = context.coordinator
        field.onFocusChange = context.coordinator.setFocus
        field.stringValue = String(value)
        return field
    }

    func updateNSView(_ field: FocusTrackingTextField, context: Context) {
        context.coordinator.range = range
        context.coordinator.onFocusChanged = onFocusChanged
        field.onFocusChange = context.coordinator.setFocus
        guard !context.coordinator.isEditing, field.stringValue != String(value) else { return }
        field.stringValue = String(value)
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        @Binding private var value: Int
        var range: ClosedRange<Int>
        var onFocusChanged: (Bool) -> Void
        var isEditing = false

        init(value: Binding<Int>, range: ClosedRange<Int>, onFocusChanged: @escaping (Bool) -> Void) {
            _value = value
            self.range = range
            self.onFocusChanged = onFocusChanged
        }

        func setFocus(_ focused: Bool) { onFocusChanged(focused) }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            let digits = String(field.stringValue.filter(\.isNumber).prefix(String(range.upperBound).count))
            isEditing = true
            if field.stringValue != digits { field.stringValue = digits }
            if let entered = Int(digits) {
                value = min(max(entered, range.lowerBound), range.upperBound)
            }
            isEditing = false
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            field.stringValue = String(value)
        }
    }
}

private struct RepeatButton: View {
    let image: String
    let action: () -> Void
    @State private var repeatTask: Task<Void, Never>?

    var body: some View {
        Image(systemName: image)
            .font(.system(size: 16, weight: .medium))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in startRepeating() }
                    .onEnded { _ in stopRepeating() }
            )
            .onDisappear(perform: stopRepeating)
    }

    private func startRepeating() {
        guard repeatTask == nil else { return }
        action()
        repeatTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(175))
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(40))
                guard !Task.isCancelled else { return }
                action()
            }
        }
    }

    private func stopRepeating() {
        repeatTask?.cancel()
        repeatTask = nil
    }
}

private struct PersistentListScroller: NSViewRepresentable {
    let scrollerStyle: NSScroller.Style
    let onConfigured: (Bool) -> Void

    init(scrollerStyle: NSScroller.Style = .legacy, onConfigured: @escaping (Bool) -> Void) {
        self.scrollerStyle = scrollerStyle
        self.onConfigured = onConfigured
    }

    final class Coordinator {
        weak var scrollView: NSScrollView?
        var needsScroller: Bool?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> ScrollViewConfigurationView {
        let view = ScrollViewConfigurationView()
        view.configure = { hostView in
            configureScrollView(containing: hostView, coordinator: context.coordinator)
        }
        return view
    }

    func updateNSView(_ view: ScrollViewConfigurationView, context: Context) {
        view.configure = { hostView in
            configureScrollView(containing: hostView, coordinator: context.coordinator)
        }
        view.configureNow()
    }

    private func configureScrollView(containing view: NSView, coordinator: Coordinator) {
        var candidate: NSView? = view
        while let current = candidate {
            if let scrollView = findScrollView(in: current) {
                if scrollView.scrollerStyle != scrollerStyle { scrollView.scrollerStyle = scrollerStyle }
                let needsVerticalScroller = (scrollView.documentView?.frame.height ?? 0)
                    > scrollView.contentView.bounds.height
                if scrollView.hasVerticalScroller != needsVerticalScroller { scrollView.hasVerticalScroller = needsVerticalScroller }
                if scrollView.autohidesScrollers { scrollView.autohidesScrollers = false }
                if scrollView.verticalScroller?.isHidden != !needsVerticalScroller {
                    scrollView.verticalScroller?.isHidden = !needsVerticalScroller
                }
                if coordinator.scrollView !== scrollView || coordinator.needsScroller != needsVerticalScroller {
                    coordinator.scrollView = scrollView
                    coordinator.needsScroller = needsVerticalScroller
                    DispatchQueue.main.async { onConfigured(needsVerticalScroller) }
                }
                return
            }
            candidate = current.superview
        }
    }

    private func findScrollView(in view: NSView) -> NSScrollView? {
        if let scrollView = view as? NSScrollView {
            return scrollView
        }
        for subview in view.subviews {
            if let scrollView = findScrollView(in: subview) {
                return scrollView
            }
        }
        return nil
    }
}

private final class ScrollViewConfigurationView: NSView {
    var configure: ((NSView) -> Void)?

    override func viewWillMove(toSuperview newSuperview: NSView?) {
        if let newSuperview {
            configure?(newSuperview)
        }
        super.viewWillMove(toSuperview: newSuperview)
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        configureNow()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        configureNow()
    }

    override func layout() {
        super.layout()
        configureNow()
    }

    func configureNow() {
        configure?(self)
    }
}

private struct ManageStreamsSearchField: NSViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = "Search"
        field.controlSize = .large
        field.delegate = context.coordinator
        field.sendsSearchStringImmediately = true
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text {
            field.stringValue = text
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: ManageStreamsSearchField

        init(parent: ManageStreamsSearchField) {
            self.parent = parent
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            parent.text = field.stringValue
        }
    }
}


private struct StreamOrganisationDrag: Codable, Sendable {
    enum Content: Codable, Sendable {
        case streams([String])
        case group(UUID)
    }
    static let pasteboardType = NSPasteboard.PasteboardType("uk.co.bbcd4.stream-organisation")
    let sessionID: UUID
    let content: Content

    static func decode(_ data: Data, sessionID: UUID) -> Self? {
        guard let payload = try? JSONDecoder().decode(Self.self, from: data), payload.sessionID == sessionID else { return nil }
        return payload
    }
}

private enum StreamOrganisationRow: Hashable {
    enum Key: Hashable {
        case group(UUID), ungrouped, stream(String)
    }
    case group(StreamGroup, count: Int, collapsed: Bool)
    case ungrouped(Int)
    case stream(Stream)

    var key: Key {
        switch self {
        case .group(let group, _, _): .group(group.id)
        case .ungrouped: .ungrouped
        case .stream(let stream): .stream(stream.id)
        }
    }
    var stream: Stream? { if case .stream(let stream) = self { stream } else { nil } }
    var groupID: UUID? {
        switch self {
        case .group(let group, _, _): group.id
        case .stream(let stream): stream.groupID
        case .ungrouped: nil
        }
    }
    var title: String {
        switch self {
        case .group(let group, _, _): group.name
        case .ungrouped: "Ungrouped"
        case .stream(let stream): stream.name
        }
    }
}

private struct StreamOrganisationDrop {
    let payload: StreamOrganisationDrag
    let groupID: UUID?
    let anchor: String?
    let after: Bool
    let indicatorRow: Int
    let operation: NSTableView.DropOperation

    static func resolve(payload: StreamOrganisationDrag, rows: [StreamOrganisationRow], row: Int, lowerHalf: Bool) -> Self? {
        guard row >= 0 else { return nil }
        let target = rows.indices.contains(row) ? rows[row] : nil
        switch payload.content {
        case .streams(let ids):
            guard !ids.isEmpty else { return nil }
            if let stream = target?.stream {
                guard !ids.contains(stream.id) else { return nil }
                return Self(payload: payload, groupID: stream.groupID, anchor: stream.id, after: lowerHalf,
                            indicatorRow: row + (lowerHalf ? 1 : 0), operation: .above)
            }
            return Self(payload: payload, groupID: target?.groupID, anchor: nil, after: false,
                        indicatorRow: min(row, rows.count), operation: target == nil ? .above : .on)
        case .group(let id):
            guard rows.contains(where: { if case .group(let group, _, _) = $0 { return group.id == id }; return false }) else { return nil }
            let targetID = target?.groupID
            guard id != targetID else { return nil }
            if let targetID, let header = rows.firstIndex(where: {
                if case .group(let group, _, _) = $0 { return group.id == targetID }; return false
            }) {
                let after = target?.stream != nil || lowerHalf
                let boundary = after
                    ? (rows[(header + 1)...].firstIndex(where: { $0.stream == nil }) ?? rows.count)
                    : header
                return Self(payload: payload, groupID: targetID, anchor: nil, after: after,
                            indicatorRow: boundary, operation: .above)
            }
            let boundary = rows.firstIndex(where: { if case .ungrouped = $0 { return true }; return false }) ?? rows.count
            return Self(payload: payload, groupID: nil, anchor: nil, after: false, indicatorRow: boundary, operation: .above)
        }
    }
}

private final class StreamListMenuItem: NSMenuItem {
    private let invoke: () -> Void
    init(_ title: String, enabled: Bool = true, selected: Bool = false, action: @escaping () -> Void) {
        invoke = action
        super.init(title: title, action: #selector(choose), keyEquivalent: "")
        target = self
        isEnabled = enabled
        state = selected ? .on : .off
    }
    required init(coder: NSCoder) {
        invoke = {}
        super.init(coder: coder)
    }
    @objc private func choose() { invoke() }
}

private struct StreamOrganisationList: NSViewRepresentable {
    let rows: [StreamOrganisationRow]
    @Binding var selection: Set<String>
    let editingGroupID: UUID?
    let editingGroupName: String
    let availability: [String: StreamAvailabilityResult]
    let checkingURLs: Set<String>
    let showsStatus: Bool
    let sessionID: UUID
    let onToggleGroup: (UUID) -> Void
    let onNameChange: (UUID, String) -> Void
    let onNameCommit: (UUID, String) -> Void
    let onNameCancel: (UUID) -> Void
    let onDelete: (Set<String>) -> Void
    let onMenu: (StreamOrganisationRow, Set<String>) -> NSMenu
    let onMove: (StreamOrganisationDrop) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .legacy
        let table = StreamOrganisationTable()
        table.headerView = nil
        table.style = .inset
        table.backgroundColor = .clear
        table.rowSizeStyle = .custom
        table.rowHeight = 26
        table.intercellSpacing = .zero
        table.draggingDestinationFeedbackStyle = .regular
        table.allowsExpansionToolTips = false
        table.allowsMultipleSelection = true
        table.allowsEmptySelection = true
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("streams"))
        column.resizingMask = .autoresizingMask
        column.width = 480
        table.addTableColumn(column)
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        table.registerForDraggedTypes([StreamOrganisationDrag.pasteboardType])
        table.coordinator = context.coordinator
        table.autoresizingMask = [.width]
        scroll.documentView = table
        context.coordinator.table = table
        context.coordinator.update(self)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.update(self)
    }

    @MainActor final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
        var parent: StreamOrganisationList
        weak var table: StreamOrganisationTable?
        var rows: [StreamOrganisationRow] = []
        private var synchronising = false
        private var lastEditingID: UUID?
        private var dragCache: (sequence: Int, payload: StreamOrganisationDrag)?

        init(_ parent: StreamOrganisationList) { self.parent = parent }

        func update(_ parent: StreamOrganisationList) {
            let previousEditingID = self.parent.editingGroupID
            self.parent = parent
            guard let table else { return }
            if let previousEditingID, previousEditingID != parent.editingGroupID,
               let row = rows.firstIndex(where: { $0.groupID == previousEditingID && $0.stream == nil }),
               let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? StreamOrganisationCell,
               cell.nameField.currentEditor() != nil {
                table.window?.makeFirstResponder(table)
            }
            synchronising = true
            let oldKeys = rows.map(\.key)
            rows = parent.rows
            if oldKeys != rows.map(\.key) { table.reloadData() }
            else {
                for row in table.rows(in: table.visibleRect).location..<(NSMaxRange(table.rows(in: table.visibleRect))) where rows.indices.contains(row) {
                    if let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? StreamOrganisationCell { configure(cell, row: row) }
                }
            }
            let selected = IndexSet(rows.indices.filter { rows[$0].stream.map { parent.selection.contains($0.id) } ?? false })
            if table.selectedRowIndexes != selected { table.selectRowIndexes(selected, byExtendingSelection: false) }
            synchronising = false
            if let id = parent.editingGroupID, id != lastEditingID {
                lastEditingID = id
                DispatchQueue.main.async { [weak self] in self?.focusName(id) }
            } else if parent.editingGroupID == nil { lastEditingID = nil }
        }

        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { rows.indices.contains(row) && rows[row].stream != nil }
        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            let id = NSUserInterfaceItemIdentifier("stream-row")
            let cell = tableView.makeView(withIdentifier: id, owner: self) as? StreamOrganisationCell ?? StreamOrganisationCell()
            cell.identifier = id
            cell.nameField.delegate = self
            configure(cell, row: row)
            return cell
        }
        private func configure(_ cell: StreamOrganisationCell, row: Int) {
            guard rows.indices.contains(row) else { return }
            cell.configure(rows[row], editingID: parent.editingGroupID, editingName: parent.editingGroupName,
                           status: rows[row].stream.flatMap { parent.availability[$0.url] },
                           checking: rows[row].stream.map { parent.checkingURLs.contains($0.url) } ?? false,
                           showsStatus: parent.showsStatus)
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !synchronising, let table else { return }
            parent.selection = selectedIDs(table)
        }
        func selectedIDs(_ table: NSTableView) -> Set<String> {
            Set(table.selectedRowIndexes.compactMap { rows.indices.contains($0) ? rows[$0].stream?.id : nil })
        }
        func focusName(_ id: UUID) {
            guard parent.editingGroupID == id, let table,
                  let row = rows.firstIndex(where: { $0.groupID == id && $0.stream == nil }) else { return }
            table.scrollRowToVisible(row)
            guard let cell = table.view(atColumn: 0, row: row, makeIfNecessary: true) as? StreamOrganisationCell else { return }
            configure(cell, row: row)
            if cell.nameField.currentEditor() == nil { table.window?.makeFirstResponder(cell.nameField) }
            cell.nameField.currentEditor()?.selectedRange = NSRange(location: 0, length: cell.nameField.stringValue.utf16.count)
        }
        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? StreamGroupNameField, let id = field.groupID else { return }
            parent.onNameChange(id, field.currentEditor()?.string ?? field.stringValue)
        }
        func controlTextDidEndEditing(_ notification: Notification) {
            guard let field = notification.object as? StreamGroupNameField, let id = field.groupID, parent.editingGroupID == id else { return }
            parent.onNameCommit(id, field.currentEditor()?.string ?? field.stringValue)
        }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard let field = control as? StreamGroupNameField, let id = field.groupID else { return false }
            if selector == #selector(NSResponder.insertNewline(_:)) {
                parent.onNameCommit(id, textView.string)
                table?.window?.makeFirstResponder(table)
                return true
            }
            if selector == #selector(NSResponder.cancelOperation(_:)) {
                parent.onNameCancel(id)
                table?.window?.makeFirstResponder(table)
                return true
            }
            return false
        }

        func payload(_ info: NSDraggingInfo) -> StreamOrganisationDrag? {
            if let dragCache, dragCache.sequence == info.draggingSequenceNumber { return dragCache.payload }
            guard let data = info.draggingPasteboard.data(forType: StreamOrganisationDrag.pasteboardType),
                  let payload = StreamOrganisationDrag.decode(data, sessionID: parent.sessionID) else { return nil }
            dragCache = (info.draggingSequenceNumber, payload)
            return payload
        }
        func drop(_ info: NSDraggingInfo, proposedRow row: Int) -> StreamOrganisationDrop? {
            guard let table, let payload = payload(info) else { return nil }
            let point = table.convert(info.draggingLocation, from: nil)
            let lower = rows.indices.contains(row) && point.y >= table.rect(ofRow: row).midY
            return StreamOrganisationDrop.resolve(payload: payload, rows: rows, row: row, lowerHalf: lower)
        }
        func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int, proposedDropOperation operation: NSTableView.DropOperation) -> NSDragOperation {
            guard let drop = drop(info, proposedRow: row) else { return [] }
            tableView.setDropRow(drop.indicatorRow, dropOperation: drop.operation)
            return .move
        }
        func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation operation: NSTableView.DropOperation) -> Bool {
            // AppKit passes the adjusted indicator row here; retain the pointer's actual target.
            let pointer = tableView.convert(info.draggingLocation, from: nil)
            let hit = tableView.row(at: pointer)
            let target = hit >= 0 ? hit : rows.count
            guard let drop = drop(info, proposedRow: target) else { return false }
            parent.onMove(drop)
            dragCache = nil
            return true
        }
    }
}

private final class StreamGroupNameField: NSTextField {
    var groupID: UUID?
}

private final class StreamOrganisationCell: NSTableCellView {
    private struct Presentation: Equatable {
        let row: StreamOrganisationRow
        let editingID: UUID?
        let editingName: String
        let status: String?
        let checking: Bool
        let showsStatus: Bool
    }
    private var presentation: Presentation?
    let nameField = StreamGroupNameField(frame: .zero)
    private let leading = NSImageView()
    private let disclosure = NSButton()
    private let spinner = NSProgressIndicator()
    private let favourite = NSImageView()
    private let typeIcon = NSImageView()
    private let count = NSTextField(labelWithString: "")
    private let metadata = NSStackView()
    private var leadingInset: NSLayoutConstraint!
    private var leadingWidth: NSLayoutConstraint!
    private var nameGap: NSLayoutConstraint!

    override init(frame: NSRect) {
        super.init(frame: frame)
        for view in [leading, disclosure, spinner, nameField, metadata] { view.translatesAutoresizingMaskIntoConstraints = false; addSubview(view) }
        nameField.lineBreakMode = .byTruncatingTail
        nameField.isBezeled = false
        nameField.drawsBackground = false
        nameField.isEnabled = true
        nameField.usesSingleLineMode = true
        nameField.allowsExpansionToolTips = false
        nameField.cell?.isScrollable = true
        nameField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        nameField.focusRingType = .none
        textField = nameField
        metadata.orientation = .horizontal
        metadata.distribution = .fill
        metadata.spacing = 4
        metadata.detachesHiddenViews = true
        metadata.setHuggingPriority(.required, for: .horizontal)
        for view in [favourite, typeIcon, count] { metadata.addArrangedSubview(view) }
        disclosure.setButtonType(.momentaryPushIn)
        disclosure.isBordered = false
        disclosure.imagePosition = .imageOnly
        disclosure.imageScaling = .scaleNone
        disclosure.contentTintColor = .secondaryLabelColor
        disclosure.title = ""
        disclosure.controlSize = .small
        disclosure.refusesFirstResponder = true
        disclosure.target = self
        disclosure.action = #selector(toggleGroup)
        favourite.image = NSImage(systemSymbolName: "star.fill", accessibilityDescription: "Favourite")
        for icon in [favourite, typeIcon] {
            icon.translatesAutoresizingMaskIntoConstraints = false
            icon.imageScaling = .scaleProportionallyDown
            NSLayoutConstraint.activate([icon.widthAnchor.constraint(equalToConstant: 18), icon.heightAnchor.constraint(equalToConstant: 18)])
        }
        spinner.style = .spinning
        spinner.controlSize = .mini
        spinner.isDisplayedWhenStopped = false
        count.font = .systemFont(ofSize: 11)
        count.setContentCompressionResistancePriority(.required, for: .horizontal)
        count.setContentHuggingPriority(.required, for: .horizontal)
        leadingInset = leading.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4)
        leadingWidth = leading.widthAnchor.constraint(equalToConstant: 8)
        nameGap = nameField.leadingAnchor.constraint(equalTo: leading.trailingAnchor, constant: 8)
        NSLayoutConstraint.activate([
            leadingInset, leadingWidth, nameGap,
            leading.heightAnchor.constraint(equalToConstant: 12), leading.centerYAnchor.constraint(equalTo: centerYAnchor),
            disclosure.widthAnchor.constraint(equalToConstant: 13), disclosure.heightAnchor.constraint(equalToConstant: 13),
            disclosure.centerXAnchor.constraint(equalTo: leading.centerXAnchor), disclosure.centerYAnchor.constraint(equalTo: centerYAnchor),
            spinner.widthAnchor.constraint(equalToConstant: 10), spinner.heightAnchor.constraint(equalToConstant: 10),
            spinner.centerXAnchor.constraint(equalTo: leading.centerXAnchor), spinner.centerYAnchor.constraint(equalTo: leading.centerYAnchor),
            nameField.centerYAnchor.constraint(equalTo: centerYAnchor),
            nameField.trailingAnchor.constraint(equalTo: metadata.leadingAnchor, constant: -8),
            metadata.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            metadata.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }
    required init?(coder: NSCoder) { nil }

    func configure(_ row: StreamOrganisationRow, editingID: UUID?, editingName: String, status: StreamAvailabilityResult?, checking: Bool, showsStatus: Bool) {
        let updated = Presentation(row: row, editingID: editingID, editingName: row.stream == nil ? editingName : "",
                                   status: status?.state.title, checking: checking, showsStatus: showsStatus)
        guard presentation != updated else { return }
        presentation = updated
        let editing = row.stream == nil && row.groupID != nil && row.groupID == editingID
        let title = editing ? editingName : row.title
        if nameField.currentEditor() == nil && nameField.stringValue != title { nameField.stringValue = title }
        nameField.groupID = row.stream == nil ? row.groupID : nil
        if nameField.isEditable != editing { nameField.isEditable = editing }
        if nameField.isSelectable != editing { nameField.isSelectable = editing }
        nameField.font = .systemFont(ofSize: 13, weight: row.stream == nil ? .semibold : .regular)
        leadingInset.constant = row.stream?.groupID == nil ? 4 : 22
        leading.isHidden = false
        disclosure.isHidden = true
        spinner.stopAnimation(nil)
        favourite.isHidden = true
        typeIcon.isHidden = true
        count.isHidden = true
        switch row {
        case .group(_, let members, let collapsed):
            leadingWidth.constant = 13
            nameGap.constant = 8
            leading.isHidden = true
            disclosure.isHidden = false
            disclosure.image = NSImage(systemSymbolName: collapsed ? "chevron.right" : "chevron.down", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 11, weight: .bold))
            disclosure.setAccessibilityValue(collapsed ? "Collapsed" : "Expanded")
            disclosure.setAccessibilityLabel(row.title)
            count.stringValue = "\(members)"
            count.isHidden = false
        case .ungrouped(let members):
            leadingWidth.constant = 0
            nameGap.constant = 0
            leading.image = nil
            count.stringValue = "\(members)"
            count.isHidden = false
        case .stream(let stream):
            leadingWidth.constant = showsStatus ? 8 : 0
            nameGap.constant = showsStatus ? 8 : 0
            leading.image = showsStatus ? Self.dot : nil
            leading.isHidden = checking || !showsStatus
            leading.contentTintColor = status?.state == .online ? .systemGreen : status?.state == .offline ? .systemRed : .secondaryLabelColor
            if checking && showsStatus { spinner.startAnimation(nil) }
            favourite.isHidden = !stream.isFavourite
            typeIcon.isHidden = false
            typeIcon.image = NSImage(systemSymbolName: stream.category.iconName, accessibilityDescription: stream.category.title)
        }
        updateColours()
    }
    private static let dot: NSImage = {
        let image = NSImage(size: NSSize(width: 8, height: 8), flipped: false) { bounds in
            NSColor.white.setFill()
            NSBezierPath(ovalIn: bounds).fill()
            return true
        }
        image.isTemplate = true
        return image
    }()
    override var backgroundStyle: NSView.BackgroundStyle { didSet { updateColours() } }
    private func updateColours() {
        let selected = backgroundStyle == .emphasized
        nameField.textColor = selected ? .selectedMenuItemTextColor : .labelColor
        count.textColor = selected ? .selectedMenuItemTextColor : .secondaryLabelColor
        favourite.contentTintColor = selected ? .selectedMenuItemTextColor : .labelColor
        typeIcon.contentTintColor = selected ? .selectedMenuItemTextColor : .labelColor
    }

    private var table: StreamOrganisationTable? { enclosingScrollView?.documentView as? StreamOrganisationTable }
    @objc private func toggleGroup() {
        guard let id = presentation?.row.groupID else { return }
        table?.coordinator?.parent.onToggleGroup(id)
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        if !disclosure.isHidden, disclosure.frame.contains(local) { return super.hitTest(point) }
        if nameField.isEditable, nameField.frame.contains(local) { return super.hitTest(point) }
        return self
    }
    override func mouseDown(with event: NSEvent) { table?.mouseDown(with: event) }
    override func mouseDragged(with event: NSEvent) { table?.mouseDragged(with: event) }
    override func mouseUp(with event: NSEvent) { table?.mouseUp(with: event) }
    override func rightMouseDown(with event: NSEvent) { table?.rightMouseDown(with: event) }
}

private final class StreamOrganisationTable: NSTableView {
    weak var coordinator: StreamOrganisationList.Coordinator?
    private var pressedRow: StreamOrganisationRow.Key?
    private var pressLocation = NSPoint.zero
    private var collapseSelectionOnRelease = false
    private var anchor: StreamOrganisationRow.Key?
    private var dragging = false

    override func mouseDown(with event: NSEvent) {
        guard let coordinator else { return }
        let point = convert(event.locationInWindow, from: nil)
        let index = row(at: point)
        guard coordinator.rows.indices.contains(index) else {
            if event.modifierFlags.intersection([.command, .shift]).isEmpty { deselectAll(nil) }
            pressedRow = nil
            return
        }
        window?.makeFirstResponder(self)
        let item = coordinator.rows[index]
        pressedRow = item.key
        pressLocation = point
        dragging = false
        collapseSelectionOnRelease = false
        guard item.stream != nil else {
            if event.modifierFlags.intersection([.command, .shift]).isEmpty { deselectAll(nil) }
            return
        }
        let modifiers = event.modifierFlags.intersection([.command, .shift])
        if modifiers.contains(.shift) {
            let start = anchor.flatMap { key in coordinator.rows.firstIndex { $0.key == key } } ?? index
            let range = IndexSet((min(start, index)...max(start, index)).filter { coordinator.rows[$0].stream != nil })
            selectRowIndexes(range, byExtendingSelection: modifiers.contains(.command))
        } else if modifiers.contains(.command) {
            if isRowSelected(index) { deselectRow(index) }
            else { selectRowIndexes(IndexSet(integer: index), byExtendingSelection: true) }
            anchor = item.key
        } else if isRowSelected(index) {
            collapseSelectionOnRelease = selectedRowIndexes.count > 1
            anchor = item.key
        } else {
            selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            anchor = item.key
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard !dragging, let coordinator, let key = pressedRow,
              let row = coordinator.rows.firstIndex(where: { $0.key == key }) else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x - pressLocation.x, point.y - pressLocation.y) >= 3 else { return }
        let content: StreamOrganisationDrag.Content
        switch coordinator.rows[row] {
        case .group(let group, _, _): content = .group(group.id)
        case .stream(let stream):
            let selected = coordinator.selectedIDs(self)
            guard selected.contains(stream.id) else { return }
            let ids = coordinator.rows.compactMap { $0.stream }.filter { selected.contains($0.id) }.map(\.id)
            guard !ids.isEmpty else { return }
            content = .streams(ids)
        case .ungrouped: return
        }
        guard window?.isVisible == true else { return }
        let payload = StreamOrganisationDrag(sessionID: coordinator.parent.sessionID, content: content)
        guard let data = try? JSONEncoder().encode(payload) else { return }
        let writer = NSPasteboardItem()
        writer.setData(data, forType: StreamOrganisationDrag.pasteboardType)
        let item = NSDraggingItem(pasteboardWriter: writer)
        let title: String
        if case .streams(let ids) = content, ids.count > 1 { title = "\(ids.count) streams" }
        else { title = coordinator.rows[row].title }
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.white]
        let size = NSSize(width: min(300, (title as NSString).size(withAttributes: attributes).width + 24), height: 28)
        let image = NSImage(size: size, flipped: false) { bounds in
            NSColor.controlAccentColor.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
            (title as NSString).draw(in: bounds.insetBy(dx: 12, dy: 5), withAttributes: attributes)
            return true
        }
        item.setDraggingFrame(NSRect(x: point.x - 12, y: point.y - 14, width: size.width, height: size.height), contents: image)
        dragging = true
        beginDraggingSession(with: [item], event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        defer { pressedRow = nil; collapseSelectionOnRelease = false }
        guard !dragging, let coordinator, let key = pressedRow,
              let index = coordinator.rows.firstIndex(where: { $0.key == key }) else { return }
        if collapseSelectionOnRelease { selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false) }
        if case .group(let group, _, _) = coordinator.rows[index],
           event.modifierFlags.intersection([.command, .shift]).isEmpty {
            coordinator.parent.onToggleGroup(group.id)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let coordinator else { return }
        let index = row(at: convert(event.locationInWindow, from: nil))
        guard coordinator.rows.indices.contains(index) else { return }
        if coordinator.rows[index].stream != nil, !isRowSelected(index) {
            selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        }
        let menu = coordinator.parent.onMenu(coordinator.rows[index], coordinator.selectedIDs(self))
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
    override func keyDown(with event: NSEvent) {
        if [51, 117].contains(event.keyCode), let coordinator {
            coordinator.parent.onDelete(coordinator.selectedIDs(self))
        } else { super.keyDown(with: event) }
    }
    override func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { context == .withinApplication ? .move : [] }
    override func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }
    override func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        dragging = false
        pressedRow = nil
    }
}

struct StreamManagementView: View {
    @EnvironmentObject private var streamStore: StreamStore
    @EnvironmentObject private var streamAvailability: StreamAvailabilityMonitor
    @AppStorage(StreamAvailabilityPreferences.enabledKey) private var checkStreamAvailability = StreamAvailabilityPreferences.defaultEnabled
    @AppStorage(StreamAvailabilityPreferences.startInAppKey) private var showStreamCheckStartInAppNotification = true
    @State private var streamCheckNotification: StreamStatusCheckStarted?

    @State private var showingAddStream = false
    @State private var collapsedGroupIDs: Set<UUID> = []
    @State private var editingGroupID: UUID?
    @State private var editingGroupName = ""
    @State private var groupToDelete: StreamGroup?
    @State private var dragSessionID = UUID()
    @State private var groupError: String?
    @State private var showingEditStream = false
    @State private var showingDeleteConfirmation = false
    @State private var pendingDeletionIDs: Set<String> = []
    @State private var selectedStreamIDs: Set<String> = []
    @State private var showingResetConfirmation = false
    @State private var searchText = ""
    @State private var categoryFilter: StreamCategory?
    @State private var favouritesOnly = false
    @State private var onlineOnly = false
    @AppStorage("skipDeleteConfirmation") private var skipDeleteConfirmation = false
    @AppStorage("activeStreamCategoryFilter") private var activeStreamCategoryFilter = ""
    @AppStorage("activeFavouritesOnly") private var activeFavouritesOnly = false
    @AppStorage(StreamAvailabilityPreferences.activeOnlineOnlyKey) private var activeOnlineOnly = false
    @AppStorage(AppKeybinding.editSelectedItem.rawValue) private var editSelectedItemKey = AppKeybinding.editSelectedItem.defaultShortcut.storedValue
    @AppStorage(AppKeybinding.toggleFavourite.rawValue) private var toggleFavouriteKey = AppKeybinding.toggleFavourite.defaultShortcut.storedValue
    @AppStorage(AppKeybinding.setTelevision.rawValue) private var setTelevisionKey = AppKeybinding.setTelevision.defaultShortcut.storedValue
    @AppStorage(AppKeybinding.setRadio.rawValue) private var setRadioKey = AppKeybinding.setRadio.defaultShortcut.storedValue
    @AppStorage(AppKeybinding.setLiveStream.rawValue) private var setLiveStreamKey = AppKeybinding.setLiveStream.defaultShortcut.storedValue
    @AppStorage(AppKeybinding.editSelectedItem.enabledStorageKey) private var editSelectedItemShortcutEnabled = true
    @AppStorage(AppKeybinding.toggleFavourite.enabledStorageKey) private var toggleFavouriteShortcutEnabled = true
    @AppStorage(AppKeybinding.setTelevision.enabledStorageKey) private var setTelevisionShortcutEnabled = true
    @AppStorage(AppKeybinding.setRadio.enabledStorageKey) private var setRadioShortcutEnabled = true
    @AppStorage(AppKeybinding.setLiveStream.enabledStorageKey) private var setLiveStreamShortcutEnabled = true
    @State private var shortcutEventMonitor: Any?

    private var canCheckStreamStatus: Bool {
        checkStreamAvailability && !streamAvailability.isChecking && !streamStore.streams.isEmpty
    }

    private var checkStreamStatusButton: some View {
        Button {
            streamAvailability.requestRefresh()
        } label: {
            ZStack {
                if streamAvailability.isChecking {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise.circle")
                        .resizable()
                        .scaledToFit()
                }
            }
            .frame(width: 18, height: 18)
            .frame(width: 24, height: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!canCheckStreamStatus)
        .buttonCursor(isEnabled: canCheckStreamStatus)
        .accessibilityLabel("Check stream status")
        .hoverHint("Check stream status", alignment: .topTrailing, below: true)
    }

    private var streamFilterMenu: some View {
        StreamFilterButton(category: $categoryFilter, favouritesOnly: $favouritesOnly, onlineOnly: $onlineOnly, showsOnline: checkStreamAvailability)
        .frame(width: 24, height: 24)
        .overlay {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .resizable()
                .scaledToFit()
                .frame(width: 18, height: 18)
                .allowsHitTesting(false)
        }
        .hoverHint("Filter streams", alignment: .topTrailing, below: true)
        .zIndex(1)
    }

    private var streamFilter: StreamListFilter {
        StreamListFilter(
            category: categoryFilter,
            favouritesOnly: favouritesOnly,
            onlineOnly: checkStreamAvailability && onlineOnly
        )
    }

    private var streamSections: [StreamGroupSection] {
        let eligible = streamStore.streams.filter {
            streamFilter.matches($0, availability: streamAvailability.results[$0.url]?.state)
        }
        return StreamGrouping.searchSections(for: eligible, groups: streamStore.groups, query: searchText)
    }
    private var filteredStreams: [Stream] { streamSections.flatMap(\.streams) }

    private var visibleStreams: [Stream] {
        streamSections.filter { section in
            section.id.map { !collapsedGroupIDs.contains($0) } ?? true
        }.flatMap(\.streams)
    }

    private var organisationRows: [StreamOrganisationRow] {
        streamSections.flatMap { section -> [StreamOrganisationRow] in
            if let id = section.id, let group = streamStore.groups.first(where: { $0.id == id }) {
                let header = StreamOrganisationRow.group(group, count: section.streams.count, collapsed: collapsedGroupIDs.contains(id))
                return [header] + (collapsedGroupIDs.contains(id) ? [] : section.streams.map(StreamOrganisationRow.stream))
            }
            return (section.title == nil ? [] : [.ungrouped(section.streams.count)]) + section.streams.map(StreamOrganisationRow.stream)
        }
    }

    private func applyActiveFilter() {
        favouritesOnly = activeFavouritesOnly
        onlineOnly = activeOnlineOnly
        categoryFilter = StreamCategory.allCases.first { $0.title == activeStreamCategoryFilter }
    }

    private func saveActiveFilter() {
        activeFavouritesOnly = favouritesOnly
        activeOnlineOnly = onlineOnly
        activeStreamCategoryFilter = categoryFilter?.title ?? ""
        let matchingStreams = streamStore.streams.filter { stream in
            streamFilter.matches(stream, availability: streamAvailability.results[stream.url]?.state)
        }
        if !matchingStreams.contains(where: { $0.id == streamStore.selectedStreamID }) {
            streamStore.selectedStreamID = matchingStreams.first?.id
        }
    }
    private var selectedStreams: [Stream] {
        visibleStreams.filter { selectedStreamIDs.contains($0.id) }
    }

    private func handleStreamShortcut(_ shortcut: AppShortcut) -> Bool {
        guard !isTextInputOrMenuActive, !selectedStreams.isEmpty else {
            return false
        }

        switch AppKeybinding.streamManagementActions.first(where: {
            shortcutIsEnabled($0) && $0.shortcut(from: keybindValue(for: $0)).matches(shortcut)
        }) {
        case .editSelectedItem:
            guard selectedStreams.count == 1 else { return false }
            streamStore.selectedStreamID = selectedStreams[0].id
            showSecondaryWindow(title: "Edit stream", isPresented: $showingEditStream)
        case .toggleFavourite:
            streamStore.setFavourite(!selectedStreams.allSatisfy(\.isFavourite), for: selectedStreamIDs)
        case .setTelevision:
            streamStore.setCategory(.television, for: selectedStreamIDs)
        case .setRadio:
            streamStore.setCategory(.radio, for: selectedStreamIDs)
        case .setLiveStream:
            streamStore.setCategory(.liveStream, for: selectedStreamIDs)
        default:
            return false
        }

        return true
    }

    private func keybindValue(for keybinding: AppKeybinding) -> String {
        switch keybinding {
        case .editSelectedItem: editSelectedItemKey
        case .toggleFavourite: toggleFavouriteKey
        case .setTelevision: setTelevisionKey
        case .setRadio: setRadioKey
        case .setLiveStream: setLiveStreamKey
        default: keybinding.defaultShortcut.storedValue
        }
    }

    private func shortcutIsEnabled(_ keybinding: AppKeybinding) -> Bool {
        switch keybinding {
        case .editSelectedItem: editSelectedItemShortcutEnabled
        case .toggleFavourite: toggleFavouriteShortcutEnabled
        case .setTelevision: setTelevisionShortcutEnabled
        case .setRadio: setRadioShortcutEnabled
        case .setLiveStream: setLiveStreamShortcutEnabled
        default: false
        }
    }

    private func installShortcutEventMonitor() {
        guard shortcutEventMonitor == nil else { return }
        shortcutEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard isSecondaryWindowFocused(title: "Manage streams") else {
                return event
            }

            let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
            if [36, 76].contains(event.keyCode), modifiers.isEmpty, !isTextInputOrMenuActive {
                closeSecondaryWindow()
                return nil
            }

            guard let shortcut = AppShortcut(event: event),
                  handleStreamShortcut(shortcut) else {
                return event
            }
            return nil
        }
    }

    private func removeShortcutEventMonitor() {
        guard let shortcutEventMonitor else { return }
        NSEvent.removeMonitor(shortcutEventMonitor)
        self.shortcutEventMonitor = nil
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                HStack(alignment: .center) {
                    Text("Manage streams")
                        .font(.largeTitle.weight(.bold))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                    Spacer()
                    ManageStreamsSearchField(text: $searchText)
                    .frame(width: 210 - SettingsLayout.scrollbarReserve)
                }
                .padding(.leading, SettingsLayout.horizontalInset)
                .padding(.trailing, SettingsLayout.horizontalInset + SettingsLayout.scrollbarReserve)
                HStack(alignment: .center, spacing: 12) {
                    Text("Displaying \(filteredStreams.count) of \(streamStore.streams.count) streams")
                        .foregroundStyle(.secondary)
                    Spacer()

                    HStack(spacing: 6) {
                        if checkStreamAvailability { checkStreamStatusButton }
                        streamFilterMenu
                    }
                }
                .padding(.leading, SettingsLayout.horizontalInset)
                .padding(.trailing, SettingsLayout.horizontalInset + SettingsLayout.scrollbarReserve)
            }
            .padding(.top, SettingsLayout.horizontalInset)
            .padding(.bottom, 10)
            .zIndex(1)
            StreamOrganisationList(
                rows: organisationRows, selection: $selectedStreamIDs,
                editingGroupID: editingGroupID, editingGroupName: editingGroupName,
                availability: streamAvailability.results, checkingURLs: streamAvailability.checkingURLs,
                showsStatus: checkStreamAvailability, sessionID: dragSessionID,
                onToggleGroup: { id in
                    guard editingGroupID == nil else { return }
                    groupExpansion(id).wrappedValue.toggle()
                },
                onNameChange: { id, name in
                    if editingGroupID == id { editingGroupName = name }
                },
                onNameCommit: { id, name in
                    guard editingGroupID == id else { return }
                    editingGroupName = name
                    saveGroupName()
                },
                onNameCancel: { id in
                    if editingGroupID == id { editingGroupID = nil }
                },
                onDelete: requestStreamDeletion,
                onMenu: organisationMenu,
                onMove: { drop in
                    handleOrganisationDrop(drop.payload, toGroup: drop.groupID, relativeTo: drop.anchor, after: drop.after)
                }
            )
            .frame(minWidth: 500, minHeight: 440)
            .padding(.horizontal, 6)

            Divider()

            HStack {
                Button("Restore defaults", role: .destructive) {
                    showingResetConfirmation = true
                }
                Spacer()
                Button("Create group", action: createGroup)
                Button("Add stream") {
                    showSecondaryWindow(title: "Add stream", isPresented: $showingAddStream)
                }
                Button("Done") {
                    if saveGroupName() { closeSecondaryWindow() }
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.vertical, SettingsLayout.horizontalInset)
                        .padding(.horizontal, SettingsLayout.horizontalInset)
        }
        .navigationTitle("Streams")
        .overlay(alignment: .bottom) {
            if let streamCheckNotification {
                InAppNotificationMessage(message: streamCheckNotification.message)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 88)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: streamCheckNotification?.id)
        .onChange(of: streamAvailability.lastCheckStarted?.id) { _, _ in
            guard checkStreamAvailability, showStreamCheckStartInAppNotification,
                  isSecondaryWindowFocused(title: "Manage streams"),
                  let event = streamAvailability.lastCheckStarted else { return }
            streamCheckNotification = event
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                if streamCheckNotification?.id == event.id { streamCheckNotification = nil }
            }
        }
        .onAppear {
            applyActiveFilter()
            if let id = streamStore.selectedStreamID, filteredStreams.contains(where: { $0.id == id }) {
                selectedStreamIDs = [id]
            }
            installShortcutEventMonitor()
        }
        .onChange(of: selectedStreamIDs) { _, ids in
            if !ids.contains(streamStore.selectedStreamID ?? ""), let first = filteredStreams.first(where: { ids.contains($0.id) }) {
                streamStore.selectedStreamID = first.id
            }
        }
        .onChange(of: visibleStreams.map(\.id)) { _, ids in
            selectedStreamIDs.formIntersection(ids)
        }
        .onChange(of: streamStore.groups.map(\.id)) { _, ids in
            collapsedGroupIDs.formIntersection(ids)
            if let editingGroupID, !ids.contains(editingGroupID) { self.editingGroupID = nil }
        }
        .onChange(of: searchText) { _, query in
            if !query.isEmpty { collapsedGroupIDs.removeAll() }
        }
        .onChange(of: streamStore.selectedStreamID) { _, id in
            guard !isSecondaryWindowFocused(title: "Manage streams"), let id,
                  !selectedStreamIDs.contains(id),
                  filteredStreams.contains(where: { $0.id == id }) else { return }
            if let groupID = streamStore.streams.first(where: { $0.id == id })?.groupID {
                collapsedGroupIDs.remove(groupID)
            }
            selectedStreamIDs = [id]
        }
        .onDisappear {
            removeShortcutEventMonitor()
            saveActiveFilter()
        }
        .childWindow(
            isPresented: $showingAddStream,
            title: "Add stream",
            size: NSSize(width: 520, height: 420)
        ) {
            StreamEditorView(title: "Add stream") { name, url, category, groupID in
                try streamStore.add(name: name, url: url, category: category, groupID: groupID)
                if let groupID { collapsedGroupIDs.remove(groupID) }
                if let id = streamStore.selectedStreamID { selectedStreamIDs = [id] }
            }
            .environmentObject(streamStore)
        }
        .childWindow(
            isPresented: $showingEditStream,
            title: "Edit stream",
            size: NSSize(width: 520, height: 420)
        ) {
            if let stream = streamStore.selectedStream {
                StreamEditorView(title: "Edit stream", stream: stream) { name, url, category, groupID in
                    try streamStore.update(
                        originalName: stream.name,
                        name: name,
                        url: url,
                        category: category,
                        groupID: groupID
                    )
                    if let groupID { collapsedGroupIDs.remove(groupID) }
                    if let id = streamStore.selectedStreamID { selectedStreamIDs = [id] }
                }
                .environmentObject(streamStore)
            }
        }
        .alert("Delete group?", isPresented: Binding(
            get: { groupToDelete != nil },
            set: { if !$0 { groupToDelete = nil } }
        )) {
            Button("Delete", role: .destructive) {
                if let groupToDelete { streamStore.deleteGroup(groupToDelete.id) }
                groupToDelete = nil
            }
            Button("Cancel", role: .cancel) { groupToDelete = nil }
        } message: {
            Text("This group will be removed. Any streams within it will be moved to Ungrouped.")
        }
        .alert("Couldn't change group", isPresented: Binding(
            get: { groupError != nil },
            set: { if !$0 { groupError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(groupError ?? "")
        }
        .alert(pendingDeletionIDs.count == 1 ? "Delete stream?" : "Delete \(pendingDeletionIDs.count) streams?", isPresented: $showingDeleteConfirmation) {
            Button("Delete", role: .destructive) {
                deleteStreams(pendingDeletionIDs)
                pendingDeletionIDs.removeAll()
            }
            Button("Cancel", role: .cancel) { pendingDeletionIDs.removeAll() }
        } message: {
            Text(pendingDeletionIDs.count == 1 ? "This stream will be removed from the list." : "The selected streams will be removed from the list.")
        }
        .alert("Restore default stream list?", isPresented: $showingResetConfirmation) {
            Button("Restore", role: .destructive) {
                streamStore.resetToDefaults()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The default list of streams will be restored, including ordering and categorisation. Any changes you've made will be lost.")
        }
    }


    private func groupExpansion(_ id: UUID) -> Binding<Bool> {
        Binding(
            get: { !collapsedGroupIDs.contains(id) },
            set: { expanded in
                if expanded { collapsedGroupIDs.remove(id) }
                else { collapsedGroupIDs.insert(id) }
            }
        )
    }

    private func createGroup() {
        guard saveGroupName() else { return }
        searchText = ""
        var name = "New group"
        var suffix = 2
        while streamStore.groups.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            name = "New group \(suffix)"
            suffix += 1
        }
        do {
            let id = try streamStore.addGroup(name: name)
            editingGroupID = id
            editingGroupName = name
            collapsedGroupIDs.remove(id)
        } catch { groupError = error.localizedDescription }
    }

    private func renameGroup(_ id: UUID) {
        guard saveGroupName(), let group = streamStore.groups.first(where: { $0.id == id }) else { return }
        editingGroupName = group.name
        editingGroupID = id
    }

    @discardableResult
    private func saveGroupName() -> Bool {
        guard let id = editingGroupID else { return true }
        do {
            try streamStore.renameGroup(id, name: editingGroupName)
            editingGroupID = nil
            return true
        } catch {
            editingGroupName = streamStore.groups.first(where: { $0.id == id })?.name ?? ""
            editingGroupID = nil
            groupError = error.localizedDescription
            return false
        }
    }

    private func handleOrganisationDrop(_ payload: StreamOrganisationDrag, toGroup groupID: UUID?, relativeTo anchor: String? = nil, after: Bool) {
        do {
            switch payload.content {
            case .streams(let ids):
                if try streamStore.moveStreams(ids, toGroup: groupID, relativeTo: anchor, after: after) {
                    if let groupID { collapsedGroupIDs.remove(groupID) }
                    selectedStreamIDs = Set(ids).intersection(visibleStreams.map(\.id))
                }
            case .group(let id):
                streamStore.moveGroup(id, relativeTo: groupID, after: after)
            }
        } catch { groupError = error.localizedDescription }
    }

    private func requestStreamDeletion(_ ids: Set<String>) {
        guard !ids.isEmpty else { return }
        if skipDeleteConfirmation {
            deleteStreams(ids)
        } else {
            pendingDeletionIDs = ids
            showingDeleteConfirmation = true
        }
    }

    private func requestGroupDeletion(_ group: StreamGroup) {
        if skipDeleteConfirmation {
            streamStore.deleteGroup(group.id)
        } else {
            groupToDelete = group
        }
    }

    private func deleteStreams(_ ids: Set<String>) {
        streamStore.deleteStreams(ids)
        selectedStreamIDs.subtract(ids)
        if selectedStreamIDs.isEmpty, let id = streamStore.selectedStreamID,
           filteredStreams.contains(where: { $0.id == id }) { selectedStreamIDs = [id] }
    }

    private func organisationMenu(_ row: StreamOrganisationRow, selected: Set<String>) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        if case .group(let group, _, _) = row {
            menu.addItem(StreamListMenuItem("Rename group") { renameGroup(group.id) })
            menu.addItem(.separator())
            menu.addItem(StreamListMenuItem("Delete group") { requestGroupDeletion(group) })
            return menu
        }
        guard let stream = row.stream else { return menu }
        let targets = selected.contains(stream.id) ? visibleStreams.filter { selected.contains($0.id) } : [stream]
        let ids = Set(targets.map(\.id))
        if checkStreamAvailability {
            menu.addItem(StreamListMenuItem(targets.count == 1 ? "Check stream status" : "Check selected streams",
                                            enabled: !targets.allSatisfy { streamAvailability.checkingURLs.contains($0.url) }) {
                for target in targets { streamAvailability.requestCheck(for: target.url) }
            })
            menu.addItem(.separator())
        }
        let allFavourites = targets.allSatisfy(\.isFavourite)
        menu.addItem(StreamListMenuItem(allFavourites ? "Unfavourite" : "Favourite") {
            streamStore.setFavourite(!allFavourites, for: ids)
        })
        let groups = NSMenu()
        groups.autoenablesItems = false
        func addGroup(_ title: String, id: UUID?) {
            groups.addItem(StreamListMenuItem(title, selected: targets.allSatisfy { $0.groupID == id }) {
                do {
                    try streamStore.setGroup(id, for: ids)
                    if let id { collapsedGroupIDs.remove(id) }
                    selectedStreamIDs = ids
                } catch { groupError = error.localizedDescription }
            })
        }
        addGroup("Ungrouped", id: nil)
        if !streamStore.groups.isEmpty { groups.addItem(.separator()) }
        for group in streamStore.groups { addGroup(group.name, id: group.id) }
        let groupsItem = NSMenuItem(title: "Group", action: nil, keyEquivalent: "")
        groupsItem.submenu = groups
        menu.addItem(groupsItem)
        menu.addItem(.separator())
        menu.addItem(StreamListMenuItem("Edit", enabled: targets.count == 1) {
            selectedStreamIDs = ids
            streamStore.selectedStreamID = stream.id
            showSecondaryWindow(title: "Edit stream", isPresented: $showingEditStream)
        })
        menu.addItem(.separator())
        menu.addItem(StreamListMenuItem("Delete") {
            selectedStreamIDs = ids
            requestStreamDeletion(ids)
        })
        return menu
    }
}


struct StreamEditorView: View {
    @EnvironmentObject private var streamStore: StreamStore
    let title: String
    let save: (String, String, StreamCategory, UUID?) throws -> Void
    @State private var name: String
    @State private var url: String
    @State private var category: StreamCategory
    @State private var groupID: UUID?
    @State private var errorMessage: String?
    @State private var primaryActionEventMonitor: Any?

    init(
        title: String,
        stream: Stream? = nil,
        save: @escaping (String, String, StreamCategory, UUID?) throws -> Void
    ) {
        self.title = title
        self.save = save
        _name = State(initialValue: stream?.name ?? "")
        _url = State(initialValue: stream?.url ?? "")
        _category = State(initialValue: stream?.category ?? .television)
        _groupID = State(initialValue: stream?.groupID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.title2.bold())
            TextField("Choose a stream name (e.g. BBC World News Europe UHD)", text: $name)
            TextField("Paste a stream URL (.mpd or .m3u8 only)", text: $url)
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 16) {
                    Text("Stream type")
                        .font(.headline)
                        .frame(width: 86, alignment: .leading)
                    Picker("", selection: $category) {
                        ForEach(StreamCategory.allCases) { category in
                            Text(category.title).tag(category)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.radioGroup)
                    .horizontalRadioGroupLayout()
                }
                HStack(spacing: 16) {
                    Text("Group")
                        .font(.headline)
                        .frame(width: 86, alignment: .leading)
                    SettingsPopupMenu(
                        values: [nil] + streamStore.groups.map { Optional($0.id) },
                        selection: $groupID,
                        title: { id in streamStore.groups.first { $0.id == id }?.name ?? "Ungrouped" },
                        maximumWidth: 300
                    )
                    .frame(width: 300, height: 22, alignment: .leading)
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { closeSecondaryWindow() }
                Button("Save", action: saveStream)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 520)
        .onSubmit(of: .text, saveStream)
        .onChange(of: streamStore.groups.map(\.id)) { _, ids in
            if let groupID, !ids.contains(groupID) { self.groupID = nil }
        }
        .onAppear(perform: installPrimaryActionEventMonitor)
        .onDisappear {
            removeEventMonitor(primaryActionEventMonitor)
            primaryActionEventMonitor = nil
        }
        .alert("Couldn't save stream", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func saveStream() {
        do {
            try save(name, url, category, groupID)
            closeSecondaryWindow()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func installPrimaryActionEventMonitor() {
        guard primaryActionEventMonitor == nil else { return }
        primaryActionEventMonitor = makePrimaryActionEventMonitor(for: title) {
            saveStream()
        }
    }
}

struct SettingsView: View {
    @AppStorage(StreamAvailabilityPreferences.activeOnlineOnlyKey) private var activeOnlineOnly = false
    @AppStorage(EncodingConfiguration.preferenceKey) private var encodingConfigurationData = Data()
    @ObservedObject var timeOptionsStore: TimeOptionsStore
    @AppStorage("dateFormat") private var dateFormat = "dd/MM/yyyy"
    @AppStorage("downloadFolder") private var downloadFolderPath = ""
    @AppStorage("downloadDefaultHours") private var defaultHours = 0
    @AppStorage("downloadDefaultMinutes") private var defaultMinutes = 1
    @AppStorage("downloadDefaultSeconds") private var defaultSeconds = 0
    @AppStorage("encodeH265") private var defaultEncodeH265 = EncodingConfiguration.defaultEnabled
    @AppStorage("revealFinishedVideo") private var revealFinishedMedia = false
    @AppStorage("completionPlaybackMode") private var completionPlaybackMode = CompletionPlaybackMode.each.rawValue
    @AppStorage("downloadAttempts") private var downloadAttempts = 3
    @AppStorage("retryDelay") private var retryDelay = 2.0
    @AppStorage(UpdateCheckFrequency.preferenceKey) private var updateCheckFrequency = UpdateCheckFrequency.onLaunch.rawValue
    @AppStorage("skipDeleteConfirmation") private var skipDeleteConfirmation = false
    @AppStorage("sequentialDownloads") private var sequentialDownloads = false
    @AppStorage("segmentDownloadLimit") private var segmentDownloadLimit = 5
    @AppStorage(StreamAvailabilityPreferences.enabledKey) private var checkStreamAvailability = StreamAvailabilityPreferences.defaultEnabled
    @AppStorage(StreamAvailabilityPreferences.intervalKey) private var streamAvailabilityInterval = StreamAvailabilityPreferences.defaultInterval
    @AppStorage(StreamAvailabilityPreferences.startInAppKey) private var showStreamCheckStartInAppNotification = true
    @AppStorage(StreamAvailabilityPreferences.startSystemKey) private var showStreamCheckStartSystemNotification = false
    @AppStorage("streamLaunchFilter") private var launchStreamFilter = "All"
    @AppStorage("activeStreamCategoryFilter") private var activeStreamCategoryFilter = ""
    @AppStorage("activeFavouritesOnly") private var activeFavouritesOnly = false
    @AppStorage("downloadFilenameFormat") private var downloadFilenameFormat = DownloadFilenameFormat.defaultFormat.rawValue
    @AppStorage("appearanceMode") private var appearanceMode = AppAppearance.system.rawValue
    @AppStorage("downloadStartInAppNotification") private var showDownloadStartInAppNotification = true
    @AppStorage("downloadStartSystemNotification") private var showDownloadStartSystemNotification = false
    @AppStorage("downloadCompletionInAppNotification") private var showDownloadCompletionInAppNotification = true
    @AppStorage("downloadCompletionSystemNotification") private var showDownloadCompletionSystemNotification = false
    @AppStorage("downloadFailureInAppNotification") private var showDownloadFailureInAppNotification = true
    @AppStorage("downloadFailureSystemNotification") private var showDownloadFailureSystemNotification = false
    @State private var isShowingDefaultDurationEditor = false
    @State private var isManagingStartTimes = false
    @State private var isManagingKeyboardShortcuts = false
    @State private var settingsNeedsScrollbar = true
    @State private var isSettingsScrollReady = false
    @State private var primaryActionEventMonitor: Any?

    private var streamFilterChoices: [String] {
        ["All", "Favourites", "Online"] + StreamCategory.allCases.map(\.title)
    }

    private var encodingConfiguration: EncodingConfiguration {
        (try? JSONDecoder().decode(EncodingConfiguration.self, from: encodingConfigurationData)) ?? .defaults
    }

    private func encodingBinding<Value>(_ keyPath: WritableKeyPath<EncodingConfiguration, Value>) -> Binding<Value> {
        Binding(
            get: { encodingConfiguration[keyPath: keyPath] },
            set: { value in
                var updated = encodingConfiguration
                updated[keyPath: keyPath] = value
                if let data = try? JSONEncoder().encode(updated) {
                    encodingConfigurationData = data
                }
            }
        )
    }

    private var filenameFormatBinding: Binding<DownloadFilenameFormat> {
        Binding(
            get: { DownloadFilenameFormat(rawValue: downloadFilenameFormat) ?? .defaultFormat },
            set: { downloadFilenameFormat = $0.rawValue }
        )
    }

    private var completionPlaybackBinding: Binding<CompletionPlaybackMode> {
        Binding(
            get: { CompletionPlaybackMode(rawValue: completionPlaybackMode) ?? .each },
            set: { completionPlaybackMode = $0.rawValue }
        )
    }

    private var appearanceBinding: Binding<AppAppearance> {
        Binding(
            get: { AppAppearance(rawValue: appearanceMode) ?? .system },
            set: { appearanceMode = $0.rawValue }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Settings")
                        .font(.largeTitle.weight(.bold))
                    SettingsSection(title: "Downloading") {
                        SettingsCard {
                            HStack {
                                Text("Download folder")
                                Spacer()
                                Button("Choose folder…", action: chooseDownloadFolder)
                                .buttonStyle(HoverGlassButtonStyle(minimumHeight: 22))
                            }
                            .frame(height: ControlMetrics.settingsRowHeight)
                            Divider()
                            HStack {
                                Text("Attempts to retry failed segments")
                                Spacer()
                                SettingsMenuPicker(
                                    values: Array(1...10),
                                    selection: $downloadAttempts,
                                    title: { attempts in
                                        "\(attempts) \(attempts == 1 ? "retry" : "retries")"
                                    }
                                )
                            }
                            .frame(height: ControlMetrics.settingsRowHeight)
                            Divider()
                            HStack {
                                Text("Time between each retry attempt")
                                Spacer()
                                SettingsMenuPicker(
                                    values: Array(1...10),
                                    selection: Binding(
                                        get: { Int(DownloadLimits.retryDelay(retryDelay).rounded()) },
                                        set: { retryDelay = Double($0) }
                                    ),
                                    title: { seconds in
                                        "\(seconds) \(seconds == 1 ? "second" : "seconds")"
                                    }
                                )
                            }
                            .frame(height: ControlMetrics.settingsRowHeight)
                            Divider()
                            HStack {
                                Text("Download segments")
                                Spacer()
                                SettingsPopupMenu(
                                    values: ["Simultaneously", "Sequentially"],
                                    selection: Binding(
                                        get: { sequentialDownloads ? "Sequentially" : "Simultaneously" },
                                        set: { sequentialDownloads = $0 == "Sequentially" }
                                    ),
                                    title: { $0 }
                                )
                            }
                            .frame(height: ControlMetrics.settingsRowHeight)
                            if !sequentialDownloads {
                                Divider()
                                HStack {
                                    Text("Number of simultaneous downloads")
                                    Spacer()
                                    SettingsMenuPicker(
                                        values: [2, 5, 10, 15, 20, 25],
                                        selection: $segmentDownloadLimit,
                                        title: { count in "\(count) segments" }
                                    )
                                }
                                .frame(height: ControlMetrics.settingsRowHeight)
                            }
                        }
                    }

                    SettingsSection(title: "Streams") {
                        SettingsCard {
                            SettingsToggleRow("Check if streams are active", isOn: $checkStreamAvailability)
                                .onChange(of: checkStreamAvailability) { _, enabled in
                                    if enabled { DownloadNotifications.requestPermission() }
                                }
                            if checkStreamAvailability {
                                Divider()
                                HStack {
                                    Text("Stream check frequency")
                                    Spacer()
                                    SettingsMenuPicker(
                                        values: StreamAvailabilityPreferences.intervals,
                                        selection: $streamAvailabilityInterval,
                                        title: StreamAvailabilityPreferences.intervalTitle
                                    )
                                }
                                .frame(height: ControlMetrics.settingsRowHeight)
                            }
                        }
                    }

                    SettingsSection(title: "Encoding") {
                        SettingsCard {
                            HStack {
                                Text("Encoding method")
                                Spacer()
                                SettingsPopupMenu(
                                    values: EncodingMethod.allCases,
                                    selection: encodingBinding(\.method),
                                    title: { $0.title }
                                )
                            }
                            .frame(height: ControlMetrics.settingsRowHeight)
                            Divider()
                            HStack {
                                Text("Quality")
                                Spacer()
                                SettingsPopupMenu(
                                    values: EncodingQuality.allCases,
                                    selection: encodingBinding(\.quality),
                                    title: { $0.title }
                                )
                            }
                            .frame(height: ControlMetrics.settingsRowHeight)
                        }
                    }

                    SettingsSection(title: "Defaults") {
                        SettingsCard {
                            HStack {
                                Text("Stream filter")
                                Spacer()
                                SettingsPopupMenu(
                                    values: streamFilterChoices,
                                    selection: $launchStreamFilter,
                                    title: { $0 == "Online" ? "Active" : $0 }
                                )
                            }
                            .frame(height: ControlMetrics.settingsRowHeight)
                            Divider()
                            SettingsToggleRow("Encoding enabled", isOn: $defaultEncodeH265)
                            Divider()
                            HStack {
                                Text("Download duration")
                                Spacer()
                                Button("Set duration…") {
                                    isShowingDefaultDurationEditor = true
                                }
                                .buttonStyle(HoverGlassButtonStyle(minimumHeight: 22))
                                .popover(isPresented: $isShowingDefaultDurationEditor) {
                                    VStack(alignment: .leading, spacing: 16) {
                                        Text("Default duration")
                                            .font(.headline)
                                        HStack(spacing: ControlMetrics.fieldGap) {
                                            DurationControl(title: "Hours", value: $defaultHours, range: 0...350)
                                            DurationControl(title: "Minutes", value: $defaultMinutes, range: 0...59)
                                            DurationControl(title: "Seconds", value: $defaultSeconds, range: 0...59)
                                        }
                                        HStack {
                                            Spacer()
                                            Button("Done") { isShowingDefaultDurationEditor = false }
                                                .buttonStyle(.borderedProminent)
                                                .keyboardShortcut(.defaultAction)
                                        }
                                    }
                                    .padding(20)
                                    .background(InitialKeyboardFocusReset())
                                }
                            }
                            .frame(height: ControlMetrics.settingsRowHeight)
                        }
                    }

                    SettingsSection(title: "Notifications") {
                        SettingsCard {
                            HStack {
                                Text("Receive notifications")
                                Spacer()
                                Text("In-app")
                                    .frame(width: 52)
                                Text("System")
                                    .frame(width: 52)
                            }
                            .frame(height: ControlMetrics.settingsRowHeight)

                            Divider()

                            VStack(spacing: 6) {
                                notificationCheckboxRow(
                                    "when a download starts",
                                    inApp: $showDownloadStartInAppNotification,
                                    system: $showDownloadStartSystemNotification
                                )
                                Divider()
                                notificationCheckboxRow(
                                    "when a download completes",
                                    inApp: $showDownloadCompletionInAppNotification,
                                    system: $showDownloadCompletionSystemNotification
                                )
                                Divider()
                                notificationCheckboxRow(
                                    "when a download fails",
                                    inApp: $showDownloadFailureInAppNotification,
                                    system: $showDownloadFailureSystemNotification
                                )
                                if checkStreamAvailability {
                                    Divider()
                                    notificationCheckboxRow(
                                        "when a stream status check starts",
                                        inApp: $showStreamCheckStartInAppNotification,
                                        system: $showStreamCheckStartSystemNotification
                                    )
                                }
                            }
                            .padding(.leading, 24)
                            .onChange(of: showDownloadStartSystemNotification) { _, _ in
                                DownloadNotifications.requestPermission()
                            }
                            .onChange(of: showDownloadCompletionSystemNotification) { _, _ in
                                DownloadNotifications.requestPermission()
                            }
                            .onChange(of: showDownloadFailureSystemNotification) { _, _ in
                                requestNotificationPermissionIfNeeded()
                            }
                            .onChange(of: showStreamCheckStartSystemNotification) { _, _ in
                                DownloadNotifications.requestPermission()
                            }
                        }
                    }

                    SettingsSection(title: "Preferences") {
                        SettingsCard {
                            HStack {
                                Text("Date format")
                                Spacer()
                                SettingsPopupMenu(
                                    values: DateFormats.choices.map(\.pattern),
                                    selection: $dateFormat,
                                    title: { pattern in
                                        DateFormats.label(for: DateFormats.choices.first(where: { $0.pattern == pattern }) ?? DateFormats.choices[0])
                                    }
                                )
                            }
                            .frame(height: ControlMetrics.settingsRowHeight)
                            Divider()
                            HStack {
                                Text("File name format")
                                Spacer()
                                SettingsPopupMenu(
                                    values: DownloadFilenameFormat.allCases,
                                    selection: filenameFormatBinding,
                                    title: { $0.title }
                                )
                            }
                            .frame(height: ControlMetrics.settingsRowHeight)
                            Divider()
                            HStack {
                                Text("Keyboard shortcuts")
                                Spacer()
                                Button("Keyboard shortcuts…") {
                                    showSecondaryWindow(
                                        title: "Keyboard shortcuts",
                                        isPresented: $isManagingKeyboardShortcuts
                                    )
                                }
                                .buttonStyle(HoverGlassButtonStyle(minimumHeight: 22))
                            }
                            .frame(height: ControlMetrics.settingsRowHeight)
                            Divider()
                            HStack {
                                Text("Preset start times")
                                Spacer()
                                Button("Manage times…") {
                                    showSecondaryWindow(title: "Manage start times", isPresented: $isManagingStartTimes)
                                }
                                .buttonStyle(HoverGlassButtonStyle(minimumHeight: 22))
                            }
                            .frame(height: ControlMetrics.settingsRowHeight)
                            Divider()
                            HStack {
                                Text("Theme")
                                Spacer()
                                SettingsPopupMenu(
                                    values: AppAppearance.allCases,
                                    selection: appearanceBinding,
                                    title: { $0.title }
                                )
                            }
                            .frame(height: ControlMetrics.settingsRowHeight)
                            Divider()
                            SettingsToggleRow("Play media when download completes", isOn: $revealFinishedMedia)
                            if revealFinishedMedia {
                                Divider()
                                HStack {
                                    Text("Queue autoplay behaviour")
                                    Spacer()
                                    SettingsPopupMenu(
                                        values: CompletionPlaybackMode.allCases,
                                        selection: completionPlaybackBinding,
                                        title: { $0.title }
                                    )
                                }
                                .frame(height: ControlMetrics.settingsRowHeight)
                            }
                            Divider()
                            SettingsToggleRow("Skip delete confirmations", isOn: $skipDeleteConfirmation)
                            Divider()
                            HStack {
                                Text("Check for updates")
                                Spacer()
                                SettingsPopupMenu(
                                    values: UpdateCheckFrequency.allCases.map(\.rawValue),
                                    selection: $updateCheckFrequency,
                                    title: { (UpdateCheckFrequency(rawValue: $0) ?? .onLaunch).title }
                                )
                            }
                            .frame(height: ControlMetrics.settingsRowHeight)
                        }
                    }

                    Color.clear
                        .frame(height: 17)
                        .overlay {
                            GeometryReader { proxy in
                                Text("Version \(appVersion)")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .position(
                                        x: (SettingsLayout.sheetWidth / 2) - proxy.frame(in: .named("settingsPage")).minX,
                                        y: proxy.size.height / 2
                                    )
                            }
                        }
                        .padding(.top, 8)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, SettingsLayout.horizontalInset)
                .padding(.horizontal, SettingsLayout.horizontalInset)
                .padding(.trailing, settingsNeedsScrollbar ? -SettingsLayout.scrollbarReserve : 0)

            }
            .scrollIndicators(.visible)
            .background(PersistentListScroller { needsScrollbar in
                settingsNeedsScrollbar = needsScrollbar
                isSettingsScrollReady = true
            })
            .opacity(isSettingsScrollReady ? 1 : 0)

            Divider()

            HStack {
                Button("Restore defaults", action: resetToDefaults)
                Spacer()
                Button("Done") { closeSecondaryWindow() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.vertical, SettingsLayout.horizontalInset)
            .padding(.horizontal, SettingsLayout.horizontalInset)
        }
        .frame(width: SettingsLayout.sheetWidth, height: SettingsLayout.sheetHeight)
        .coordinateSpace(name: "settingsPage")
        .onAppear {
            prepareSettings()
            installPrimaryActionEventMonitor()
        }
        .onChange(of: launchStreamFilter) { _, filter in
            if filter == "Online" { checkStreamAvailability = true }
        }
        .onDisappear {
            removeEventMonitor(primaryActionEventMonitor)
            primaryActionEventMonitor = nil
        }
        .childWindow(
            isPresented: $isManagingStartTimes,
            title: "Manage start times",
            size: NSSize(width: 400, height: 680)
        ) {
            StartTimeManagementView(timeOptionsStore: timeOptionsStore)
        }
        .childWindow(
            isPresented: $isManagingKeyboardShortcuts,
            title: "Keyboard shortcuts",
            size: NSSize(width: 560, height: 540),
            showsWindowTitle: true
        ) {
            KeyboardShortcutsView()
        }
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "3.1"
    }

    private func chooseDownloadFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = downloadFolder
        guard panel.runModal() == .OK, let url = panel.url else { return }
        downloadFolderPath = url.path
    }

    private var downloadFolder: URL {
        guard !downloadFolderPath.isEmpty else {
            return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        }
        return URL(fileURLWithPath: downloadFolderPath)
    }

    private func normaliseMenuSettings() {
        if UpdateCheckFrequency(rawValue: updateCheckFrequency) == nil {
            updateCheckFrequency = UpdateCheckFrequency.onLaunch.rawValue
        }
        if !StreamAvailabilityPreferences.intervals.contains(streamAvailabilityInterval) {
            streamAvailabilityInterval = StreamAvailabilityPreferences.defaultInterval
        }
        if ![2, 5, 10, 15, 20, 25].contains(segmentDownloadLimit) {
            segmentDownloadLimit = 5
        }
        if !(1...10).contains(downloadAttempts) {
            downloadAttempts = 3
        }
        if !retryDelay.isFinite || !(1...10).contains(retryDelay) {
            retryDelay = 2
        }
        if DownloadFilenameFormat(rawValue: downloadFilenameFormat) == nil {
            downloadFilenameFormat = DownloadFilenameFormat.defaultFormat.rawValue
        }
        if AppAppearance(rawValue: appearanceMode) == nil {
            appearanceMode = AppAppearance.system.rawValue
        }
    }

    private func resetToDefaults() {
        UserDefaults.standard.removeObject(forKey: EncodingConfiguration.preferenceKey)
        dateFormat = "dd/MM/yyyy"
        defaultHours = 0
        defaultMinutes = 1
        defaultSeconds = 0
        defaultEncodeH265 = EncodingConfiguration.defaultEnabled
        revealFinishedMedia = false
        completionPlaybackMode = CompletionPlaybackMode.each.rawValue
        downloadAttempts = 3
        retryDelay = 2
        updateCheckFrequency = UpdateCheckFrequency.onLaunch.rawValue
        skipDeleteConfirmation = false
        launchStreamFilter = "All"
        activeOnlineOnly = false
        activeStreamCategoryFilter = ""
        activeFavouritesOnly = false
        sequentialDownloads = false
        segmentDownloadLimit = 5
        checkStreamAvailability = StreamAvailabilityPreferences.defaultEnabled
        streamAvailabilityInterval = StreamAvailabilityPreferences.defaultInterval
        downloadFolderPath = ""
        downloadFilenameFormat = DownloadFilenameFormat.defaultFormat.rawValue
        appearanceMode = AppAppearance.system.rawValue
        showDownloadStartInAppNotification = true
        showDownloadStartSystemNotification = false
        showDownloadCompletionInAppNotification = true
        showDownloadCompletionSystemNotification = false
        showDownloadFailureInAppNotification = true
        showDownloadFailureSystemNotification = false
        showStreamCheckStartInAppNotification = true
        showStreamCheckStartSystemNotification = false
        for keybinding in AppKeybinding.allCases {
            UserDefaults.standard.set(keybinding.defaultShortcut.storedValue, forKey: keybinding.rawValue)
            UserDefaults.standard.set(true, forKey: keybinding.enabledStorageKey)
        }
    }

    private func prepareSettings() {
        DownloadNotifications.migrateLegacyPreferenceIfNeeded()
        normaliseMenuSettings()
        DispatchQueue.main.async {
            NSApp.keyWindow?.makeFirstResponder(nil)
        }
    }

    private func installPrimaryActionEventMonitor() {
        guard primaryActionEventMonitor == nil else { return }
        primaryActionEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
            guard [36, 76].contains(event.keyCode), modifiers.isEmpty else {
                return event
            }

            if isShowingDefaultDurationEditor {
                isShowingDefaultDurationEditor = false
                return nil
            }

            guard isSecondaryWindowFocused(title: "Settings"), !isTextInputOrMenuActive else {
                return event
            }
            closeSecondaryWindow()
            return nil
        }
    }

    private func requestNotificationPermissionIfNeeded() {
        DownloadNotifications.requestPermission()
    }

    private func notificationCheckboxRow(
        _ title: String,
        inApp: Binding<Bool>,
        system: Binding<Bool>
    ) -> some View {
        HStack {
            Text(title)
            Spacer()
            Toggle("", isOn: inApp)
                .labelsHidden()
                .toggleStyle(.checkbox)
                .frame(width: 52)
            Toggle("", isOn: system)
                .labelsHidden()
                .toggleStyle(.checkbox)
                .frame(width: 52)
        }
        .frame(height: ControlMetrics.settingsRowHeight)
    }

}

private struct KeyboardShortcutsView: View {
    @AppStorage(AppKeybinding.editSelectedItem.rawValue) private var editSelectedItemKey = AppKeybinding.editSelectedItem.defaultShortcut.storedValue
    @AppStorage(AppKeybinding.toggleFavourite.rawValue) private var toggleFavouriteKey = AppKeybinding.toggleFavourite.defaultShortcut.storedValue
    @AppStorage(AppKeybinding.setTelevision.rawValue) private var setTelevisionKey = AppKeybinding.setTelevision.defaultShortcut.storedValue
    @AppStorage(AppKeybinding.setRadio.rawValue) private var setRadioKey = AppKeybinding.setRadio.defaultShortcut.storedValue
    @AppStorage(AppKeybinding.setLiveStream.rawValue) private var setLiveStreamKey = AppKeybinding.setLiveStream.defaultShortcut.storedValue
    @AppStorage(AppKeybinding.addDownloadToQueue.rawValue) private var addDownloadToQueueKey = AppKeybinding.addDownloadToQueue.defaultShortcut.storedValue
    @AppStorage(AppKeybinding.showDownloadQueue.rawValue) private var showDownloadQueueKey = AppKeybinding.showDownloadQueue.defaultShortcut.storedValue
    @AppStorage(AppKeybinding.toggleEncode.rawValue) private var toggleEncodeKey = AppKeybinding.toggleEncode.defaultShortcut.storedValue
    @AppStorage(AppKeybinding.openSettings.rawValue) private var openSettingsKey = AppKeybinding.openSettings.defaultShortcut.storedValue
    @AppStorage(AppKeybinding.openManageStreams.rawValue) private var openManageStreamsKey = AppKeybinding.openManageStreams.defaultShortcut.storedValue
    @AppStorage(AppKeybinding.download.rawValue) private var downloadKey = AppKeybinding.download.defaultShortcut.storedValue
    @AppStorage(AppKeybinding.editSelectedItem.enabledStorageKey) private var editSelectedItemShortcutEnabled = true
    @AppStorage(AppKeybinding.toggleFavourite.enabledStorageKey) private var toggleFavouriteShortcutEnabled = true
    @AppStorage(AppKeybinding.setTelevision.enabledStorageKey) private var setTelevisionShortcutEnabled = true
    @AppStorage(AppKeybinding.setRadio.enabledStorageKey) private var setRadioShortcutEnabled = true
    @AppStorage(AppKeybinding.setLiveStream.enabledStorageKey) private var setLiveStreamShortcutEnabled = true
    @AppStorage(AppKeybinding.addDownloadToQueue.enabledStorageKey) private var addDownloadToQueueShortcutEnabled = true
    @AppStorage(AppKeybinding.showDownloadQueue.enabledStorageKey) private var showDownloadQueueShortcutEnabled = true
    @AppStorage(AppKeybinding.toggleEncode.enabledStorageKey) private var toggleEncodeShortcutEnabled = true
    @AppStorage(AppKeybinding.openSettings.enabledStorageKey) private var openSettingsShortcutEnabled = true
    @AppStorage(AppKeybinding.openManageStreams.enabledStorageKey) private var openManageStreamsShortcutEnabled = true
    @AppStorage(AppKeybinding.download.enabledStorageKey) private var downloadShortcutEnabled = true
    @State private var recordingKeybinding: AppKeybinding?
    @State private var keybindEventMonitor: Any?
    @State private var primaryActionEventMonitor: Any?

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                Text("To change a shortcut, double-click the key combination, then type the new keys.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                shortcutCategory(
                    title: "Main menu",
                    actions: AppKeybinding.mainWindowActions,
                    indexOffset: 0
                )

                shortcutCategory(
                    title: "Other",
                    actions: AppKeybinding.otherActions,
                    indexOffset: AppKeybinding.mainWindowActions.count
                )
            }
            .padding(.horizontal, 24)
            .padding(.top, 18)

            Spacer()
            Divider()

            HStack {
                Button("Restore defaults", action: restoreDefaults)
                Spacer()
                Button("Done") { closeSecondaryWindow() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
        .frame(width: 560, height: 540)
        .onAppear {
            normaliseShortcuts()
            installPrimaryActionEventMonitor()
        }
        .onDisappear {
            stopKeybindRecording()
            removeEventMonitor(primaryActionEventMonitor)
            primaryActionEventMonitor = nil
        }
    }

    private func shortcutRow(
        _ keybinding: AppKeybinding,
        index: Int,
        rowIndex: Int,
        rowCount: Int
    ) -> some View {
        let isEnabled = keybindEnabled(for: keybinding).wrappedValue
        let isRecording = recordingKeybinding == keybinding

        return HStack(spacing: 12) {
            Toggle("", isOn: keybindEnabled(for: keybinding))
                .labelsHidden()
                .toggleStyle(.checkbox)
                .controlSize(.small)
                .frame(width: 22)
            Text(keybinding.title)
            Spacer()
            Text(shortcutDisplayValue(for: keybinding, isEnabled: isEnabled, isRecording: isRecording))
                .foregroundStyle(isRecording || !isEnabled ? .secondary : .primary)
                .frame(minWidth: 100, alignment: .trailing)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) {
                    beginKeybindRecording(keybinding)
                }
        }
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background {
            shortcutRowBackground(
                isAlternate: !index.isMultiple(of: 2),
                rowIndex: rowIndex,
                rowCount: rowCount
            )
        }
    }

    @ViewBuilder
    private func shortcutRowBackground(
        isAlternate: Bool,
        rowIndex: Int,
        rowCount: Int
    ) -> some View {
        let fill = isAlternate ? Color.primary.opacity(0.045) : Color.primary.opacity(0.001)

        if rowIndex == 0 {
            UnevenRoundedRectangle(
                topLeadingRadius: ControlMetrics.cornerRadius,
                bottomLeadingRadius: 0,
                bottomTrailingRadius: 0,
                topTrailingRadius: ControlMetrics.cornerRadius
            )
            .fill(fill)
        } else if rowIndex == rowCount - 1 {
            UnevenRoundedRectangle(
                topLeadingRadius: 0,
                bottomLeadingRadius: ControlMetrics.cornerRadius,
                bottomTrailingRadius: ControlMetrics.cornerRadius,
                topTrailingRadius: 0
            )
            .fill(fill)
        } else {
            Rectangle()
                .fill(fill)
        }
    }

    private func shortcutCategory(
        title: String,
        actions: [AppKeybinding],
        indexOffset: Int
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.headline)

            VStack(spacing: 0) {
                ForEach(Array(actions.enumerated()), id: \.element) { index, keybinding in
                    shortcutRow(
                        keybinding,
                        index: index + indexOffset,
                        rowIndex: index,
                        rowCount: actions.count
                    )
                }
            }
            .background(Color.primary.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: ControlMetrics.cornerRadius, style: .continuous))
        }
    }

    private func shortcutDisplayValue(
        for keybinding: AppKeybinding,
        isEnabled: Bool,
        isRecording: Bool
    ) -> String {
        if isRecording { return "Type shortcut" }
        if !isEnabled { return "none" }
        return keybinding.shortcut(from: keybindValue(for: keybinding).wrappedValue).displayValue
    }

    private func keybindValue(for keybinding: AppKeybinding) -> Binding<String> {
        switch keybinding {
        case .editSelectedItem: $editSelectedItemKey
        case .toggleFavourite: $toggleFavouriteKey
        case .setTelevision: $setTelevisionKey
        case .setRadio: $setRadioKey
        case .setLiveStream: $setLiveStreamKey
        case .addDownloadToQueue: $addDownloadToQueueKey
        case .showDownloadQueue: $showDownloadQueueKey
        case .toggleEncode: $toggleEncodeKey
        case .openSettings: $openSettingsKey
        case .openManageStreams: $openManageStreamsKey
        case .download: $downloadKey
        }
    }

    private func keybindEnabled(for keybinding: AppKeybinding) -> Binding<Bool> {
        switch keybinding {
        case .editSelectedItem: $editSelectedItemShortcutEnabled
        case .toggleFavourite: $toggleFavouriteShortcutEnabled
        case .setTelevision: $setTelevisionShortcutEnabled
        case .setRadio: $setRadioShortcutEnabled
        case .setLiveStream: $setLiveStreamShortcutEnabled
        case .addDownloadToQueue: $addDownloadToQueueShortcutEnabled
        case .showDownloadQueue: $showDownloadQueueShortcutEnabled
        case .toggleEncode: $toggleEncodeShortcutEnabled
        case .openSettings: $openSettingsShortcutEnabled
        case .openManageStreams: $openManageStreamsShortcutEnabled
        case .download: $downloadShortcutEnabled
        }
    }

    private func beginKeybindRecording(_ keybinding: AppKeybinding) {
        stopKeybindRecording()
        recordingKeybinding = keybinding

        keybindEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard recordingKeybinding != nil else { return event }

            if event.keyCode == 53 {
                stopKeybindRecording()
                return nil
            }

            guard let shortcut = AppShortcut(event: event) else {
                return nil
            }

            assignShortcut(shortcut)
            return nil
        }
    }

    private func assignShortcut(_ shortcut: AppShortcut) {
        guard let recordingKeybinding else { return }

        let destination = keybindValue(for: recordingKeybinding)
        destination.wrappedValue = shortcut.storedValue
        stopKeybindRecording()
    }

    private func normaliseShortcuts() {
        for keybinding in AppKeybinding.allCases {
            let binding = keybindValue(for: keybinding)
            binding.wrappedValue = keybinding.shortcut(from: binding.wrappedValue).storedValue
        }
    }

    private func restoreDefaults() {
        for keybinding in AppKeybinding.allCases {
            keybindValue(for: keybinding).wrappedValue = keybinding.defaultShortcut.storedValue
            keybindEnabled(for: keybinding).wrappedValue = true
        }
    }

    private func stopKeybindRecording() {
        if let keybindEventMonitor {
            NSEvent.removeMonitor(keybindEventMonitor)
            self.keybindEventMonitor = nil
        }
        recordingKeybinding = nil
    }

    private func installPrimaryActionEventMonitor() {
        guard primaryActionEventMonitor == nil else { return }
        primaryActionEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
            guard recordingKeybinding == nil,
                  [36, 76].contains(event.keyCode),
                  modifiers.isEmpty,
                  isSecondaryWindowFocused(title: "Keyboard shortcuts"),
                  !isTextInputOrMenuActive else {
                return event
            }

            closeSecondaryWindow()
            return nil
        }
    }
}

private struct DownloadQueueView: View {
    @ObservedObject var downloadController: DownloadController
    @AppStorage("dateFormat") private var dateFormat = "dd/MM/yyyy"
    @AppStorage("skipDeleteConfirmation") private var skipDeleteConfirmation = false
    @State private var pendingQueueDeletion: [QueuedDownload] = []
    @State private var isShowingClearQueueConfirmation = false
    @State private var primaryActionEventMonitor: Any?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Download queue")
                    .font(.largeTitle.weight(.bold))
                Spacer()
                Text("\(downloadController.queue.count) queued")
                    .foregroundStyle(.secondary)
            }
            .padding(24)

            List {
                if let request = downloadController.currentRequest, downloadController.isDownloading {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Currently downloading")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Divider()
                        requestDetails(for: request)
                        Text(downloadController.status)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        DownloadProgressTrack(
                            progress: downloadController.progress,
                            isActive: downloadController.isDownloading
                        )
                    }
                    .listRowSeparator(.hidden)
                }

                Text("Queued downloads")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .listRowBackground(Color.clear)

                if downloadController.queue.isEmpty {
                    Text("No downloads are queued.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(downloadController.queue) { item in
                        HStack(spacing: 12) {
                            requestDetails(for: item.request)
                            Spacer()
                            Button(role: .destructive) {
                                confirmQueueDeletion([item])
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .help("Remove from queue")
                        }
                        .contextMenu {
                            Button("Remove from queue", role: .destructive) {
                                confirmQueueDeletion([item])
                            }
                        }
                    }
                    .onMove(perform: downloadController.moveQueuedDownloads)
                    .onDelete { offsets in
                        confirmQueueDeletion(offsets.map { downloadController.queue[$0] })
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .padding(.horizontal, SettingsLayout.horizontalInset - 8)
            .frame(minHeight: 360)

            Divider()

            HStack {
                Button("Clear queue", role: .destructive) {
                    confirmClearQueue()
                }
                .disabled(downloadController.queue.isEmpty)
                Button(downloadController.isQueuePaused ? "Resume queue" : "Pause queue") {
                    downloadController.toggleQueuePaused()
                }
                .disabled(downloadController.queue.isEmpty)
                Spacer()
                Button("Done") { closeSecondaryWindow() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(24)
        }
        .frame(width: ControlMetrics.mainWindowWidth, height: 520)
        .onAppear(perform: installPrimaryActionEventMonitor)
        .onDisappear {
            removeEventMonitor(primaryActionEventMonitor)
            primaryActionEventMonitor = nil
        }
        .alert("Remove queued download?", isPresented: Binding(
            get: { !pendingQueueDeletion.isEmpty },
            set: { if !$0 { pendingQueueDeletion = [] } }
        )) {
            Button("Remove", role: .destructive) {
                let items = pendingQueueDeletion
                pendingQueueDeletion = []
                items.forEach(downloadController.removeQueuedDownload)
            }
            Button("Cancel", role: .cancel) {
                pendingQueueDeletion = []
            }
        } message: {
            Text(queueDeletionMessage)
        }
        .alert("Clear download queue?", isPresented: $isShowingClearQueueConfirmation) {
            Button("Clear queue", role: .destructive) {
                downloadController.clearQueue()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("All queued downloads will be removed.")
        }
    }

    private var queueDeletionMessage: String {
        if pendingQueueDeletion.count == 1, let item = pendingQueueDeletion.first {
            return "Remove \(item.request.stream.name) from the download queue?"
        }
        return "Remove \(pendingQueueDeletion.count) queued downloads?"
    }

    private func confirmQueueDeletion(_ items: [QueuedDownload]) {
        guard !items.isEmpty else { return }
        if skipDeleteConfirmation {
            items.forEach(downloadController.removeQueuedDownload)
        } else {
            pendingQueueDeletion = items
        }
    }

    private func confirmClearQueue() {
        if skipDeleteConfirmation {
            downloadController.clearQueue()
        } else {
            isShowingClearQueueConfirmation = true
        }
    }

    private func installPrimaryActionEventMonitor() {
        guard primaryActionEventMonitor == nil else { return }
        primaryActionEventMonitor = makePrimaryActionEventMonitor(for: "Download queue") {
            closeSecondaryWindow()
        }
    }

    private func requestDetails(for request: DownloadRequest) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(request.stream.name)
                .lineLimit(1)
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "clock").fixedSize()
                    Text(Self.durationText(request.duration))
                }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Duration: \(Self.durationText(request.duration))")
                HStack(spacing: 6) {
                    Image(systemName: "calendar").fixedSize()
                    Text(DateFormats.displayDateTime(request.start, format: dateFormat))
                }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Start: \(DateFormats.displayDateTime(request.start, format: dateFormat))")
                if request.encodeH265 {
                    Text("Encoded")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
                        .accessibilityLabel("Encoded")
                        .help("Encoding enabled")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
        }
    }

    private static func durationText(_ seconds: Int) -> String {
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        let remainingSeconds = seconds % 60
        var parts: [String] = []

        if hours > 0 {
            parts.append("\(hours)h")
        }
        if minutes > 0 {
            parts.append("\(minutes)m")
        }
        if remainingSeconds > 0 || parts.isEmpty {
            parts.append("\(remainingSeconds)s")
        }

        return parts.joined(separator: " ")
    }
}

private struct StartTimeManagementView: View {
    @ObservedObject var timeOptionsStore: TimeOptionsStore
    @AppStorage("skipDeleteConfirmation") private var skipDeleteConfirmation = false
    @AppStorage(AppKeybinding.editSelectedItem.rawValue) private var editSelectedItemKey = AppKeybinding.editSelectedItem.defaultShortcut.storedValue
    @AppStorage(AppKeybinding.editSelectedItem.enabledStorageKey) private var editSelectedItemShortcutEnabled = true
    @State private var selectedTime: String?
    @State private var isShowingAddTime = false
    @State private var isShowingEditTime = false
    @State private var isShowingResetConfirmation = false
    @State private var pendingTimeDeletion: String?
    @FocusState private var isTimeListFocused: Bool
    @State private var shortcutEventMonitor: Any?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Manage start times")
                    .font(.largeTitle.weight(.bold))
                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.top, 16)
            .padding(.bottom, 4)

            List(selection: $selectedTime) {
                ForEach(timeOptionsStore.options, id: \.self) { time in
                    Text(time)
                        .tag(time)
                        .contextMenu {
                            Button("Edit") {
                                selectedTime = time
                                showSecondaryWindow(title: "Edit start time", isPresented: $isShowingEditTime)
                            }
                            Divider()
                            Button("Delete", role: .destructive) {
                                confirmTimeDeletion(time)
                            }
                        }
                }
                .onMove { offsets, destination in
                    let movedTime = offsets.first.map { timeOptionsStore.options[$0] }
                    timeOptionsStore.move(fromOffsets: offsets, toOffset: destination)
                    selectedTime = movedTime ?? selectedTime
                    restoreTimeListFocus()
                }
                .onDelete { offsets in
                    confirmTimeDeletion(offsets.first.map { timeOptionsStore.options[$0] })
                }
            }
            .padding(.leading, SettingsLayout.horizontalInset - 16)
            .focusable()
            .focusEffectDisabled()
            .focused($isTimeListFocused)
            .onKeyPress(characters: .alphanumerics) { handleTimeKeyPress($0) }
            .onDeleteCommand { confirmTimeDeletion(selectedTime) }
            .frame(minHeight: 280)

            Divider()

            HStack {
                Button("Restore defaults", role: .destructive) {
                    isShowingResetConfirmation = true
                }
                Spacer()
                Button("Add time") {
                    showSecondaryWindow(title: "Add start times", isPresented: $isShowingAddTime)
                }
                Button("Done") { closeSecondaryWindow() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(24)
        }
        .frame(width: 400, height: 680)
        .onAppear {
            isTimeListFocused = true
            installShortcutEventMonitor()
        }
        .onDisappear(perform: removeShortcutEventMonitor)
        .childWindow(
            isPresented: $isShowingAddTime,
            title: "Add start times",
            size: NSSize(width: 420, height: 460)
        ) {
            AddStartTimesView(timeOptionsStore: timeOptionsStore)
        }
        .childWindow(
            isPresented: $isShowingEditTime,
            title: "Edit start time",
            size: NSSize(width: 360, height: 170)
        ) {
            if let selectedTime {
                TimeOptionEditorView(title: "Edit start time", value: selectedTime) { value in
                    try timeOptionsStore.update(selectedTime, to: value)
                }
            }
        }
        .alert("Restore default start times?", isPresented: $isShowingResetConfirmation) {
            Button("Restore", role: .destructive) {
                timeOptionsStore.resetToDefaults()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your list will be replaced with the default times of :00 and :30 for each hour.")
        }
        .alert("Delete start time?", isPresented: Binding(
            get: { pendingTimeDeletion != nil },
            set: { if !$0 { pendingTimeDeletion = nil } }
        )) {
            Button("Delete", role: .destructive) {
                if let time = pendingTimeDeletion {
                    pendingTimeDeletion = nil
                    deleteSelectedTime(time)
                }
            }
            Button("Cancel", role: .cancel) {
                pendingTimeDeletion = nil
            }
        } message: {
            Text("Remove \(pendingTimeDeletion ?? "this time") from the start time list?")
        }
    }

    private func confirmTimeDeletion(_ time: String?) {
        guard let time else { return }
        if skipDeleteConfirmation {
            deleteSelectedTime(time)
        } else {
            pendingTimeDeletion = time
        }
    }

    private func handleTimeShortcut(_ shortcut: AppShortcut) -> Bool {
        guard !isTextInputOrMenuActive,
              selectedTime != nil,
              editSelectedItemShortcutEnabled,
              AppKeybinding.editSelectedItem.shortcut(from: editSelectedItemKey).matches(shortcut) else {
            return false
        }

        showSecondaryWindow(title: "Edit start time", isPresented: $isShowingEditTime)
        return true
    }

    private func handleTimeKeyPress(_ keyPress: KeyPress) -> KeyPress.Result {
        guard let shortcut = AppShortcut(keyPress: keyPress),
              handleTimeShortcut(shortcut) else {
            return .ignored
        }
        return .handled
    }

    private func installShortcutEventMonitor() {
        guard shortcutEventMonitor == nil else { return }
        shortcutEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard isSecondaryWindowFocused(title: "Manage start times") else {
                return event
            }

            let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
            if [36, 76].contains(event.keyCode), modifiers.isEmpty, !isTextInputOrMenuActive {
                closeSecondaryWindow()
                return nil
            }

            guard let shortcut = AppShortcut(event: event),
                  handleTimeShortcut(shortcut) else {
                return event
            }
            return nil
        }
    }

    private func removeShortcutEventMonitor() {
        guard let shortcutEventMonitor else { return }
        NSEvent.removeMonitor(shortcutEventMonitor)
        self.shortcutEventMonitor = nil
    }

    private func deleteSelectedTime(_ time: String?) {
        guard let time else { return }
        let index = timeOptionsStore.options.firstIndex(of: time)
        timeOptionsStore.delete(time)

        let nextSelection: String?
        if let index, !timeOptionsStore.options.isEmpty {
            nextSelection = timeOptionsStore.options[min(index, timeOptionsStore.options.count - 1)]
        } else {
            nextSelection = nil
        }

        DispatchQueue.main.async {
            selectedTime = nextSelection
            restoreTimeListFocus()
        }
    }

    private func restoreTimeListFocus() {
        DispatchQueue.main.async {
            focusSecondaryWindow(title: "Manage start times")

            DispatchQueue.main.async {
                isTimeListFocused = true
                focusSecondaryList(title: "Manage start times")
            }
        }
    }
}

private struct TimeOptionEditorView: View {
    let title: String
    let save: (String) throws -> Void
    @State private var value: String
    @State private var errorMessage: String?
    @State private var primaryActionEventMonitor: Any?

    init(title: String, value: String = "", save: @escaping (String) throws -> Void) {
        self.title = title
        self.save = save
        _value = State(initialValue: value)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(.title2.bold())
            TextField("HH:mm:ss", text: $value)
            HStack {
                Spacer()
                Button("Cancel") { closeSecondaryWindow() }
                Button("Save", action: saveTime)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 360)
        .onAppear(perform: installPrimaryActionEventMonitor)
        .onDisappear {
            removeEventMonitor(primaryActionEventMonitor)
            primaryActionEventMonitor = nil
        }
        .alert("Couldn't save start time", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func saveTime() {
        do {
            try save(value)
            closeSecondaryWindow()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func installPrimaryActionEventMonitor() {
        guard primaryActionEventMonitor == nil else { return }
        primaryActionEventMonitor = makePrimaryActionEventMonitor(for: title) {
            saveTime()
        }
    }
}

private struct AddStartTimesView: View {
    @ObservedObject var timeOptionsStore: TimeOptionsStore
    @State private var times = ""
    @State private var errorMessage: String?
    @State private var primaryActionEventMonitor: Any?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add start times")
                .font(.title2.bold())
            Text("Enter one time per line, for example 14:45 or 14:45:50.")
                .foregroundStyle(.secondary)
            AutoHidingTextEditor(text: $times)
                .padding(8)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: ControlMetrics.cornerRadius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: ControlMetrics.cornerRadius, style: .continuous)
                        .stroke(Color.primary.opacity(ControlMetrics.controlBorderOpacity), lineWidth: 1)
                }
                .frame(height: 280)
            HStack {
                Spacer()
                Button("Cancel") { closeSecondaryWindow() }
                Button("Add times", action: addTimes)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(times.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 420)
        .onAppear(perform: installPrimaryActionEventMonitor)
        .onDisappear {
            removeEventMonitor(primaryActionEventMonitor)
            primaryActionEventMonitor = nil
        }
        .alert("Couldn't add start times", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func addTimes() {
        guard !times.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        do {
            try timeOptionsStore.add(lines: times)
            closeSecondaryWindow()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func installPrimaryActionEventMonitor() {
        guard primaryActionEventMonitor == nil else { return }
        primaryActionEventMonitor = makePrimaryActionEventMonitor(for: "Add start times") {
            addTimes()
        }
    }
}

private struct AutoHidingTextEditor: NSViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> AutoHidingTextScrollView {
        let scrollView = AutoHidingTextScrollView()
        scrollView.drawsBackground = false
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay

        let textView = NSTextView()
        textView.delegate = context.coordinator
        textView.string = text
        textView.font = .systemFont(ofSize: NSFont.systemFontSize)
        textView.drawsBackground = false
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: 4, height: 4)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)

        scrollView.documentView = textView
        scrollView.updateVerticalScrollerVisibility()
        return scrollView
    }

    func updateNSView(_ scrollView: AutoHidingTextScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        if textView.string != text {
            textView.string = text
        }
        DispatchQueue.main.async {
            scrollView.updateVerticalScrollerVisibility()
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text.wrappedValue = textView.string
            (textView.enclosingScrollView as? AutoHidingTextScrollView)?.updateVerticalScrollerVisibility()
        }
    }
}

private final class AutoHidingTextScrollView: NSScrollView {
    override func layout() {
        super.layout()
        updateVerticalScrollerVisibility()
    }

    func updateVerticalScrollerVisibility() {
        guard let textView = documentView as? NSTextView,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else { return }

        let usedHeight = layoutManager.usedRect(for: textContainer).height + (textView.textContainerInset.height * 2)
        let needsScroller = usedHeight > contentView.bounds.height
        if hasVerticalScroller != needsScroller {
            hasVerticalScroller = needsScroller
        }
        if verticalScroller?.isHidden != !needsScroller {
            verticalScroller?.isHidden = !needsScroller
        }
    }
}

private struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.title3.weight(.semibold))
            content
        }
    }
}

private struct SettingsCard<Content: View>: View {
    let compact: Bool
    @ViewBuilder let content: Content

    init(compact: Bool = true, @ViewBuilder content: () -> Content) {
        self.compact = compact
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 6 : 12) {
            content
        }
        .padding(.horizontal, compact ? 8 : 16)
        .padding(.vertical, compact ? 6 : 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: ControlMetrics.cornerRadius, style: .continuous))
    }
}

private struct SettingsToggleRow: View {
    let title: String
    @Binding var isOn: Bool

    init(_ title: String, isOn: Binding<Bool>) {
        self.title = title
        _isOn = isOn
    }

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
        .frame(height: ControlMetrics.settingsRowHeight)
    }
}

private struct SettingsMenuPicker<Value: Hashable>: View {
    let values: [Value]
    @Binding var selection: Value
    let title: (Value) -> String

    init(
        values: [Value],
        selection: Binding<Value>,
        title: @escaping (Value) -> String = { String(describing: $0) }
    ) {
        self.values = values
        _selection = selection
        self.title = title
    }

    var body: some View {
        SettingsPopupMenu(values: values, selection: $selection, title: title)
    }
}

private struct SettingsPopupMenu<Value: Hashable>: NSViewRepresentable {
    let values: [Value]
    @Binding var selection: Value
    let title: (Value) -> String
    var maximumWidth: CGFloat? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> SettingsPopupControl {
        let control = SettingsPopupControl()
        control.onSelection = { context.coordinator.select($0) }
        return control
    }

    func updateNSView(_ control: SettingsPopupControl, context: Context) {
        context.coordinator.parent = self
        control.displayTitle = title(selection)
        if control.maximumWidth != maximumWidth { control.maximumWidth = maximumWidth }
        control.itemTitles = values.map(title)
        control.selectedIndex = values.firstIndex(of: selection) ?? 0
        control.onSelection = { context.coordinator.select($0) }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: SettingsPopupControl, context: Context) -> CGSize? {
        nsView.intrinsicContentSize
    }

    @MainActor
    final class Coordinator {
        var parent: SettingsPopupMenu

        init(parent: SettingsPopupMenu) {
            self.parent = parent
        }

        func select(_ index: Int) {
            guard parent.values.indices.contains(index) else { return }
            parent.selection = parent.values[index]
        }
    }
}

@MainActor
private final class SettingsPopupControl: NSControl {
    private static let controlHeight: CGFloat = 22
    var maximumWidth: CGFloat? {
        didSet {
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }
    var displayTitle = "" {
        didSet {
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }
    var itemTitles: [String] = []
    var selectedIndex = 0
    var onSelection: ((Int) -> Void)?

    private var isHovered = false {
        didSet { needsDisplay = true }
    }
    private var trackingArea: NSTrackingArea?
    private let chevronImageView = NSImageView()

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override var intrinsicContentSize: NSSize {
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 14)]
        let titleWidth = (displayTitle as NSString).size(withAttributes: attributes).width
        return NSSize(width: min(ceil(titleWidth) + 44, maximumWidth ?? .infinity), height: Self.controlHeight)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        configureChevronImage()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        configureChevronImage()
    }

    private func configureChevronImage() {
        let configuration = NSImage.SymbolConfiguration(pointSize: 11, weight: .bold)
        let image = NSImage(systemSymbolName: "chevron.up.chevron.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
        image?.isTemplate = true
        chevronImageView.image = image
        chevronImageView.contentTintColor = .labelColor
        chevronImageView.imageScaling = .scaleAxesIndependently
        chevronImageView.imageAlignment = .alignCenter
        chevronImageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(chevronImageView)
        NSLayoutConstraint.activate([
            chevronImageView.widthAnchor.constraint(equalToConstant: 10),
            chevronImageView.heightAnchor.constraint(equalToConstant: 6),
            chevronImageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            chevronImageView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6)
        ])
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
    }

    override func scrollWheel(with event: NSEvent) {
        isHovered = false
        super.scrollWheel(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        let menu = NSMenu()
        for (index, title) in itemTitles.enumerated() {
            let item = NSMenuItem(title: title, action: #selector(selectMenuItem(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            item.state = index == selectedIndex ? .on : .off
            menu.addItem(item)
        }
        let position = NSPoint(x: 0, y: bounds.maxY)
        menu.popUp(positioning: menu.item(at: selectedIndex), at: position, in: self)
    }

    override func keyDown(with event: NSEvent) {
        if event.charactersIgnoringModifiers == " " || event.keyCode == 36 {
            mouseDown(with: event)
        } else {
            super.keyDown(with: event)
        }
    }

    @objc private func selectMenuItem(_ sender: NSMenuItem) {
        selectedIndex = sender.tag
        onSelection?(sender.tag)
    }

    override func draw(_ dirtyRect: NSRect) {
        let roundedBounds = NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6)
        if isHovered {
            NSColor.labelColor.withAlphaComponent(CGFloat(ControlMetrics.hoverOpacity)).setFill()
            roundedBounds.fill()
        }

        let circleDiameter: CGFloat = 18
        let circleRect = NSRect(
            x: bounds.maxX - 20,
            y: (bounds.height - circleDiameter) / 2,
            width: circleDiameter,
            height: circleDiameter
        )
        if !isHovered {
            NSColor.labelColor.withAlphaComponent(CGFloat(ControlMetrics.controlBorderOpacity)).setFill()
            NSBezierPath(ovalIn: circleRect).fill()
        }

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14),
            .foregroundColor: NSColor.labelColor
        ]
        let textSize = (displayTitle as NSString).size(withAttributes: attributes)
        let textOrigin = NSPoint(
            x: max(4, circleRect.minX - 15 - textSize.width),
            y: floor((bounds.height - textSize.height) / 2)
        )
        if textSize.width > circleRect.minX - 19 {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byTruncatingTail
            var truncatedAttributes = attributes
            truncatedAttributes[.paragraphStyle] = paragraph
            (displayTitle as NSString).draw(
                in: NSRect(x: 4, y: textOrigin.y, width: max(0, circleRect.minX - 19), height: textSize.height),
                withAttributes: truncatedAttributes
            )
        } else {
            (displayTitle as NSString).draw(at: textOrigin, withAttributes: attributes)
        }

    }
}
