import AppKit
import SwiftUI

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
    @AppStorage(MediaTrimPreferences.enabledKey) private var defaultEditOutput = MediaTrimPreferences.defaultEnabled
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
                            SettingsToggleRow("Edit output enabled", isOn: $defaultEditOutput)
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
        if let path = DownloadFolderPicker.choose(currentPath: downloadFolderPath) {
            downloadFolderPath = path
        }
    }

    private var downloadFolder: URL {
        DownloadFolderPicker.folder(for: downloadFolderPath)
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
        defaultEditOutput = MediaTrimPreferences.defaultEnabled
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
    @AppStorage(AppKeybinding.trimPlayback.rawValue) private var trimPlaybackKey = AppKeybinding.trimPlayback.defaultShortcut.storedValue
    @AppStorage(AppKeybinding.trimPlayback.enabledStorageKey) private var trimPlaybackEnabled = true
    @AppStorage(AppKeybinding.trimCut.rawValue) private var trimCutKey = AppKeybinding.trimCut.defaultShortcut.storedValue
    @AppStorage(AppKeybinding.trimReset.rawValue) private var trimResetKey = AppKeybinding.trimReset.defaultShortcut.storedValue
    @AppStorage(AppKeybinding.trimPreviousEditPoint.rawValue) private var trimPreviousKey = AppKeybinding.trimPreviousEditPoint.defaultShortcut.storedValue
    @AppStorage(AppKeybinding.trimNextEditPoint.rawValue) private var trimNextKey = AppKeybinding.trimNextEditPoint.defaultShortcut.storedValue
    @AppStorage(AppKeybinding.trimCut.enabledStorageKey) private var trimCutEnabled = true
    @AppStorage(AppKeybinding.trimReset.enabledStorageKey) private var trimResetEnabled = true
    @AppStorage(AppKeybinding.trimPreviousEditPoint.enabledStorageKey) private var trimPreviousEnabled = true
    @AppStorage(AppKeybinding.trimNextEditPoint.enabledStorageKey) private var trimNextEnabled = true
    @AppStorage(AppKeybinding.trimIn.rawValue) private var trimInKey = AppKeybinding.trimIn.defaultShortcut.storedValue
    @AppStorage(AppKeybinding.trimOut.rawValue) private var trimOutKey = AppKeybinding.trimOut.defaultShortcut.storedValue
    @AppStorage(AppKeybinding.trimIn.enabledStorageKey) private var trimInShortcutEnabled = true
    @AppStorage(AppKeybinding.trimOut.enabledStorageKey) private var trimOutShortcutEnabled = true
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
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("To change a shortcut, double-click the key combination, then type the new key(s).")
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

                    shortcutCategory(
                        title: "Output editing",
                        actions: AppKeybinding.trimActions,
                        indexOffset: AppKeybinding.mainWindowActions.count + AppKeybinding.otherActions.count
                    )
                }
                .padding(.horizontal, 24)
                .padding(.top, 18)
                .padding(.bottom, 18)
            }

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
        case .trimIn: $trimInKey
        case .trimOut: $trimOutKey
        case .trimCut: $trimCutKey
        case .trimReset: $trimResetKey
        case .trimPreviousEditPoint: $trimPreviousKey
        case .trimNextEditPoint: $trimNextKey
        case .trimPlayback: $trimPlaybackKey
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
        case .trimIn: $trimInShortcutEnabled
        case .trimOut: $trimOutShortcutEnabled
        case .trimCut: $trimCutEnabled
        case .trimReset: $trimResetEnabled
        case .trimPreviousEditPoint: $trimPreviousEnabled
        case .trimNextEditPoint: $trimNextEnabled
        case .trimPlayback: $trimPlaybackEnabled
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
        shortcutEventMonitor = makeShortcutEventMonitor(
            isFocused: { isSecondaryWindowFocused(title: "Manage start times") },
            closesOnReturn: true,
            handle: handleTimeShortcut
        )
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
