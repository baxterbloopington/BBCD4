import AppKit
import SwiftUI

struct ContentView: View {
    let menuController: AppMenuController
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
    @State private var editOutput = MediaTrimPreferences.defaultEnabled
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
    @State private var updateCheckMessage: String?

    init(downloadController: DownloadController, menuController: AppMenuController) {
        self.menuController = menuController
        _downloadController = ObservedObject(wrappedValue: downloadController)
        let defaults = UserDefaults.standard
        _encodeH265 = State(initialValue: defaults.object(forKey: "encodeH265") as? Bool ?? EncodingConfiguration.defaultEnabled)
        _editOutput = State(initialValue: defaults.object(forKey: MediaTrimPreferences.enabledKey) as? Bool ?? MediaTrimPreferences.defaultEnabled)
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
        downloadController.isDownloading || !downloadController.queue.isEmpty || !downloadController.pendingEdits.isEmpty
    }

    private var canRequestDownload: Bool {
        !downloadController.isDownloading
            && streamStore.selectedStream != nil
            && duration > 0
    }

    private var canStartDownload: Bool { canRequestDownload && isValidStartDate(startDate) && isValidEndDate(startDate, duration: duration) }

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
            guard canEncodeSelectedStream else { return false }
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
        streamStore.selectedStreamID = StreamGrouping.firstStream(in: activeFilteredStreams, groups: streamStore.groups)?.id
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
            size: NSSize(width: 560, height: 680),
            undoManager: streamStore.undoManager
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
            .onReceive(menuController.actions, perform: handleMenuCommand)
            .onReceive(updateChecker.$isChecking) { menuController.isCheckingUpdates = $0 }
            .alert("App updates", isPresented: Binding(
                get: { updateCheckMessage != nil }, set: { if !$0 { updateCheckMessage = nil } }
            )) { Button("OK", role: .cancel) {} } message: { Text(updateCheckMessage ?? "") }
    }

    private func handleMenuCommand(_ command: AppMenuCommand) {
        switch command {
        case .downloadQueue: showDownloadQueue()
        case .checkForUpdates:
            Task {
                switch await updateChecker.checkNow() {
                case .available: isShowingUpdate = true
                case .upToDate: updateCheckMessage = "You’re using the latest version of BBCD4."
                case .failed(let message): updateCheckMessage = message
                case .busy, .cancelled: break
                }
            }
        default: break
        }
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
                streamStore.selectedStreamID = StreamGrouping.firstStream(in: activeFilteredStreams, groups: streamStore.groups)?.id
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
        shortcutEventMonitor = makeShortcutEventMonitor(
            isFocused: { NSApp.keyWindow?.title == "BBCD4" },
            handle: handleMainShortcut
        )
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
            DateSelector(value: $dateInput, dateFormat: dateFormat, onCommit: commitDate, onScrollDay: scrollStartDate) {
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
            .frame(maxWidth: .infinity, minHeight: 32, maxHeight: .infinity, alignment: .center)
            .animation(.easeInOut(duration: 0.3), value: isShowingQueueConfirmation)
            .allowsHitTesting(false)
    }

    private var downloadActionControls: some View {
        VStack(alignment: .leading, spacing: ControlMetrics.encodeRowSpacing) {
            downloadOptionToggles
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
                    if !downloadController.queue.isEmpty || !downloadController.pendingEdits.isEmpty {
                        Text("\(downloadController.queue.count + downloadController.pendingEdits.count)")
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .frame(minWidth: 18, minHeight: 18)
                            .background(Color.red, in: Capsule())
                            .overlay {
                                Capsule().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 1)
                            }
                            .offset(x: 12, y: -12)
                            .accessibilityLabel("\(downloadController.queue.count) downloads queued, \(downloadController.pendingEdits.count) awaiting editing")
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

    private var downloadOptionToggles: some View {
        HStack(spacing: ControlMetrics.fieldGap) {
            Toggle("Edit output", isOn: $editOutput)
                .toggleStyle(.checkbox)
                .hoverHint("Trim and cut media after downloading", alignment: .topLeading)
            encodeToggle
        }
    }

    private var encodeToggle: some View {
        Toggle("Encode", isOn: Binding(get: { canEncodeSelectedStream && encodeH265 }, set: { encodeH265 = $0 }))
            .toggleStyle(.checkbox)
            .disabled(!canEncodeSelectedStream)
            .opacity(canEncodeSelectedStream ? 1 : 0.2)
            .hoverHint(
                "Encode to H.265 to improve compatibility",
                alignment: .topLeading,
                isEnabled: canEncodeSelectedStream
            )
    }

    private var canEncodeSelectedStream: Bool {
        MediaTrimPreferences.canEncodeDownload(category: streamStore.selectedStream?.category ?? .television, editing: editOutput)
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
        DownloadFolderPicker.folder(for: downloadFolderPath)
    }

    private var downloadFolderSummary: String {
        downloadFolder.lastPathComponent
    }

    private func chooseDownloadFolder() {
        if let path = DownloadFolderPicker.choose(currentPath: downloadFolderPath) {
            downloadFolderPath = path
        }
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
            encodeH265: canEncodeSelectedStream && encodeH265,
            retryAttempts: max(1, min(10, downloadAttempts)),
            retryDelay: DownloadLimits.retryDelay(retryDelay),
            maximumConcurrentSegments: sequentialDownloads ? 1 : max(1, min(50, segmentDownloadLimit)),
            filenameFormat: DownloadFilenameFormat(rawValue: downloadFilenameFormat) ?? .defaultFormat,
            encodingConfiguration: EncodingConfiguration.load(),
            editOutput: editOutput
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

    private func scrollStartDate(_ step: Int) {
        commitDate()
        guard let date = Calendar.current.date(byAdding: .day, value: step, to: startDate) else { return }
        applyDate(date)
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

private extension StreamAvailabilityState {
    var indicatorColor: Color {
        switch self {
        case .unknown, .checkFailed: .secondary
        case .online: .green
        case .offline: .red
        }
    }

    var menuImage: NSImage {
        let color: NSColor
        switch self {
        case .unknown, .checkFailed: color = .secondaryLabelColor
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
        guard event.scrollingDeltaY != 0,
              let time = TimeOptionsStore.scrollTarget(from: selectedValue, options: options,
                  step: event.scrollingDeltaY > 0 ? 1 : -1) else { return }
        onSelect?(time)
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
    let onScrollDay: (Int) -> Void
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

            ScrollStepControl(onStep: onScrollDay) {
                Button(action: showCalendar) {
                    Image(systemName: "calendar")
                        .font(.system(size: 16, weight: .medium))
                        .frame(width: ControlMetrics.dateTimeAccessoryWidth,
                               height: ControlMetrics.height)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .frame(width: ControlMetrics.dateTimeAccessoryWidth, height: ControlMetrics.height)
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
