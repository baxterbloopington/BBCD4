import AppKit
import SwiftUI

private enum AppAppearance: String, CaseIterable, Hashable {
    case system
    case light
    case dark

    var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

struct ContentView: View {
    @EnvironmentObject private var streamStore: StreamStore
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("encodeH265") private var encodeH265 = false
    @AppStorage("downloadDefaultHours") private var defaultHours = 0
    @AppStorage("downloadDefaultMinutes") private var defaultMinutes = 1
    @AppStorage("downloadDefaultSeconds") private var defaultSeconds = 0
    @AppStorage("dateFormat") private var dateFormat = "dd/MM/yyyy"
    @AppStorage("downloadFolder") private var downloadFolderPath = ""
    @AppStorage("revealFinishedVideo") private var revealFinishedMedia = false
    @AppStorage("checkForUpdates") private var checkForUpdates = true
    @AppStorage("downloadAttempts") private var downloadAttempts = 3
    @AppStorage("retryDelay") private var retryDelay = 2.0
    @AppStorage("sequentialDownloads") private var sequentialDownloads = false
    @AppStorage("segmentDownloadLimit") private var segmentDownloadLimit = 5
    @AppStorage("streamLaunchFilter") private var launchStreamFilter = "All"
    @AppStorage("activeStreamCategoryFilter") private var activeStreamCategoryFilter = ""
    @AppStorage("activeFavouritesOnly") private var activeFavouritesOnly = false
    @AppStorage("downloadFilenameFormat") private var downloadFilenameFormat = DownloadFilenameFormat.startDateTime.rawValue
    @AppStorage("appearanceMode") private var appearanceMode = AppAppearance.system.rawValue
    @AppStorage("downloadCompletionNotificationStyle")
    private var completionNotificationStyle = CompletionNotificationStyle.inApp.rawValue
    
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
    @State private var isShowingUpdate = false
    @State private var isShowingCancelConfirmation = false
    @StateObject private var updateChecker = UpdateChecker()
    @ObservedObject private var downloadController: DownloadController
    
    init(downloadController: DownloadController) {
        _downloadController = ObservedObject(wrappedValue: downloadController)
    }

    private var activeFilteredStreams: [Stream] {
        let category = StreamCategory.allCases.first { $0.title == activeStreamCategoryFilter }
        return streamStore.streams.filter { stream in
            (!activeFavouritesOnly || stream.isFavourite)
                && (category == nil || stream.category == category)
        }
    }

    private var completionNotificationPreference: CompletionNotificationStyle {
        CompletionNotificationStyle(rawValue: completionNotificationStyle) ?? .inApp
    }

    private func applyLaunchFilterToActiveFilter() {
        activeFavouritesOnly = launchStreamFilter == "Favourites"
        activeStreamCategoryFilter = StreamCategory.allCases
            .first { $0.title == launchStreamFilter }?
            .title ?? ""
        streamStore.selectedStreamID = activeFilteredStreams.first?.id
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: ControlMetrics.formSectionSpacing) {
                HStack(alignment: .center) {
                    Text("Stream downloaderer IV")
                        .font(.largeTitle.weight(.bold))
                    Spacer()
                    if updateChecker.release != nil {
                        Button {
                            isShowingUpdate = true
                        } label: {
                            Label("Update available!", systemImage: "arrow.down.circle.fill")
                        }
                        .buttonStyle(HoverUpdateButtonStyle())
                    }
                }
                
                VStack(alignment: .leading, spacing: ControlMetrics.labelToControlSpacing) {
                    MainFormLabel("Choose stream")
                    HStack(spacing: ControlMetrics.iconButtonGap) {
                        StreamSelector(
                            streams: activeFilteredStreams,
                            selection: $streamStore.selectedStreamID
                        )
                        .frame(width: ControlMetrics.streamSelectorWidth, height: ControlMetrics.height)
                        Button {
                            isManagingStreams = true
                        } label: {
                            Image(systemName: "slider.horizontal.3")
                                .font(.system(size: 16, weight: .medium))
                        }
                        .buttonStyle(HoverGlassButtonStyle())
                        .frame(width: 44, height: ControlMetrics.height)
                        .hoverHint("Manage streams", alignment: .topTrailing)
                    }
                }
                
                HStack(alignment: .top, spacing: ControlMetrics.fieldGap) {
                    VStack(alignment: .leading, spacing: ControlMetrics.labelToControlSpacing) {
                        MainFormLabel("Start date")
                        DateSelector(value: $dateInput, dateFormat: dateFormat, onCommit: commitDate) {
                            isShowingCalendar.toggle()
                        }
                        .frame(width: ControlMetrics.dateWidth, height: ControlMetrics.height, alignment: .leading)
                        .popover(isPresented: $isShowingCalendar, arrowEdge: .bottom) {
                            DatePicker("", selection: Binding(
                                get: { startDate },
                                set: { newDate in applyCalendarDate(newDate) }
                            ), displayedComponents: .date)
                            .labelsHidden()
                            .datePickerStyle(.graphical)
                            .padding()
                        }
                    }
                    VStack(alignment: .leading, spacing: ControlMetrics.labelToControlSpacing) {
                        MainFormLabel("Start time")
                        TimeSelector(value: $timeInput, onCommit: commitTime)
                            .frame(width: ControlMetrics.timeWidth, height: ControlMetrics.height, alignment: .leading)
                    }
                }
                
                VStack(alignment: .leading, spacing: ControlMetrics.labelToControlSpacing) {
                    MainFormLabel("Duration")
                    HStack(spacing: ControlMetrics.fieldGap) {
                        DurationControl(title: "Hours", value: $hours, range: 0...350)
                        DurationControl(title: "Minutes", value: $minutes, range: 0...59)
                        DurationControl(title: "Seconds", value: $seconds, range: 0...59)
                    }
                }
                .frame(width: ControlMetrics.durationRowWidth, alignment: .leading)
                
                HStack(spacing: 24) {
                    Button(downloadController.isDownloading ? "Cancel" : "Download") {
                        if downloadController.isDownloading {
                            isShowingCancelConfirmation = true
                        } else {
                            requestDownload()
                        }
                    }
                    .buttonStyle(HoverPrimaryButtonStyle())
                    .frame(width: ControlMetrics.durationWidth, height: ControlMetrics.height)
                    .disabled(!downloadController.isDownloading && (streamStore.selectedStream == nil || duration == 0))
                    if !selectedStreamIsRadio {
                        Toggle("Encode", isOn: $encodeH265)
                            .toggleStyle(.checkbox)
                            .hoverHint("Encode to H.265 for better compatibility with Apple devices.\nThis can be a slow process.")
                    }
                    Spacer()
                    HStack(spacing: ControlMetrics.iconButtonGap) {
                        Button(action: openDiscord) {
                            if let discord = loadImage(named: colorScheme == .light ? "Discord-Symbol-Black" : "Discord-Symbol-White") {
                                Image(nsImage: discord)
                                    .resizable()
                                    .interpolation(.high)
                                    .scaledToFit()
                                    .frame(width: 22, height: 22)
                            } else {
                                Image(systemName: "bubble.left.and.bubble.right.fill")
                            }
                        }
                        .buttonStyle(HoverGlassButtonStyle())
                        .frame(width: 44, height: 44)
                        .hoverHint("BBC Fans Discord server", alignment: .topTrailing)
                        Button {
                            isShowingSettings = true
                        } label: {
                            Image(systemName: "gearshape")
                                .font(.system(size: 16, weight: .medium))
                                .frame(width: 22, height: 22)
                        }
                        .buttonStyle(HoverGlassButtonStyle())
                        .frame(width: 44, height: 44)
                        .hoverHint("Settings", alignment: .topTrailing)
                    }
                }
                .frame(width: ControlMetrics.mainContentWidth)
                .padding(.top, 12)
            }
            .frame(width: ControlMetrics.mainContentWidth, alignment: .leading)
            .padding(24)
            
            Spacer(minLength: 16)
            
            Divider()
            
            VStack(spacing: 10) {
                HStack {
                    Text(downloadController.status)
                        .font(.headline)
                        .lineLimit(1)
                    Spacer()
                    Text("Saves to \(downloadFolderSummary)")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
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
        .sheet(isPresented: $isManagingStreams) {
            StreamManagementView()
                .environmentObject(streamStore)
        }
        .sheet(isPresented: $isShowingSettings) {
            SettingsView()
        }
        .onAppear {
            DownloadNotifications.migrateLegacyPreferenceIfNeeded()
            completionNotificationStyle = UserDefaults.standard.string(
                forKey: "downloadCompletionNotificationStyle"
            ) ?? CompletionNotificationStyle.inApp.rawValue
            applyLaunchFilterToActiveFilter()
            applyDefaultDuration()
            syncDateInputs()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                NSApp.keyWindow?.makeFirstResponder(nil)
            }
        }
        .onChange(of: startDate) { _, _ in syncDateInputs() }
        .onChange(of: dateFormat) { _, _ in syncDateInputs() }
        .onChange(of: defaultHours) { _, _ in applyDefaultDuration() }
        .onChange(of: defaultMinutes) { _, _ in applyDefaultDuration() }
        .onChange(of: defaultSeconds) { _, _ in applyDefaultDuration() }
        .onChange(of: downloadController.completedOutput) { _, output in
            guard let output else { return }
            if revealFinishedMedia {
                NSWorkspace.shared.open(output)
                downloadController.completedOutput = nil
                downloadController.completedRequest = nil
            } else if !completionNotificationPreference.usesInAppPopup {
                downloadController.completedOutput = nil
                downloadController.completedRequest = nil
            }
        }
        .onChange(of: completionNotificationStyle) { _, rawValue in
            let style = CompletionNotificationStyle(rawValue: rawValue) ?? .inApp
            if !style.usesInAppPopup {
                downloadController.completedOutput = nil
                downloadController.completedRequest = nil
            }
        }
        .task {
            if checkForUpdates {
                await updateChecker.check()
            }
        }
        .preferredColorScheme((AppAppearance(rawValue: appearanceMode) ?? .system).colorScheme)
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded {
            NSApp.keyWindow?.makeFirstResponder(nil)
        })
        .modifier(BBCD4DialogModifier(
            downloadController: downloadController,
            validationMessage: $validationMessage,
            isShowingCancelConfirmation: $isShowingCancelConfirmation,
            isShowingUpdate: $isShowingUpdate,
            release: updateChecker.release,
            completionNotificationStyle: completionNotificationStyle
        ))
    }
    
    private var duration: Int {
        hours * 3600 + minutes * 60 + seconds
    }
    
    private var downloadFolder: URL {
        guard !downloadFolderPath.isEmpty else {
            return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        }
        return URL(fileURLWithPath: downloadFolderPath)
    }
    
    private var downloadFolderSummary: String {
        let folder = downloadFolder
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        guard folder.path.hasPrefix(home) else { return folder.path }
        
        let relativeParts = folder.path.dropFirst(home.count)
            .split(separator: "/")
            .map(String.init)
        switch relativeParts.count {
        case 0:
            return folder.lastPathComponent
        case 1:
            return relativeParts[0]
        case 2:
            return "\(relativeParts[0])/\(relativeParts[1])"
        default:
            return "\(relativeParts[0])/…/\(relativeParts.last!)"
        }
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
    
    private func requestDownload() {
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
            retryDelay: max(1, min(10, retryDelay)),
            maximumConcurrentSegments: sequentialDownloads ? 1 : max(1, min(50, segmentDownloadLimit)),
            filenameFormat: DownloadFilenameFormat(rawValue: downloadFilenameFormat) ?? .firstSegment
        )
        downloadController.start(request)
    }
    
    private func syncDateInputs() {
        dateInput = DateFormats.formatter(for: dateFormat).string(from: startDate)
        timeInput = Self.timeFormatter.string(from: startDate)
    }
    
    private func applyDefaultDuration() {
        hours = defaultHours
        minutes = defaultMinutes
        seconds = defaultSeconds
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
    
    private func loadImage(named name: String) -> NSImage? {
        guard let url = AppResources.url(forResource: name, withExtension: "svg") else { return nil }
        return NSImage(contentsOf: url)
    }
    
    private func openDiscord() {
        guard let url = URL(string: "https://discord.gg/KRWsWmFS5r") else { return }
        NSWorkspace.shared.open(url)
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
    let completionNotificationStyle: String

    private var completionNotificationPreference: CompletionNotificationStyle {
        CompletionNotificationStyle(rawValue: completionNotificationStyle) ?? .inApp
    }

    private var isDownloadCompletePresented: Binding<Bool> {
        Binding(
            get: {
                completionNotificationPreference.usesInAppPopup &&
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
            get: { downloadController.errorMessage != nil },
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
            .overlay {
                if let incomplete = downloadController.incompleteDownload {
                    ZStack {
                        Color.black.opacity(0.38)
                            .ignoresSafeArea()
                        IncompleteDownloadDialog(
                            incomplete: incomplete,
                            save: { downloadController.savePartialDownload() },
                            abort: { downloadController.discardIncompleteDownload() },
                            retry: { downloadController.retryIncompleteDownload() }
                        )
                    }
                }
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
}

private enum ControlMetrics {
    static let height: CGFloat = 32
    static let formSectionSpacing: CGFloat = 22
    static let formLabelHeight: CGFloat = 24
    static let labelToControlSpacing: CGFloat = 9
    static let durationCaptionHeight: CGFloat = 14
    static let cornerRadius: CGFloat = 10
    static let hoverOpacity = 0.08
    static let controlBorderOpacity = 0.10
    static let accessoryWidth: CGFloat = 44
    static let dateTimeAccessoryWidth: CGFloat = 44
    static let timeChevronOffset: CGFloat = 0
    static let timeChevronHitWidth: CGFloat = 38
    static let timeChevronHitHeight: CGFloat = 32
    static let durationAccessoryWidth: CGFloat = 28
    static let durationArrowOffset: CGFloat = 10
    static let fieldGap: CGFloat = 16
    static let iconButtonGap: CGFloat = 8
    static let settingsRowHeight: CGFloat = 24
    static let dateWidth: CGFloat = 160
    static let timeWidth: CGFloat = 160
    static let mainContentWidth: CGFloat = 472
    static let streamSelectorWidth = mainContentWidth - accessoryWidth - iconButtonGap
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
                    Text("Release notes")
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

private enum SettingsLayout {
    static let sheetWidth: CGFloat = 560
    static let sheetHeight: CGFloat = 720
    static let horizontalInset: CGFloat = 24
    static let scrollbarReserve: CGFloat = 18
    static let contentWidth = sheetWidth - (horizontalInset * 2) - scrollbarReserve
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
            .frame(minHeight: 36)
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

private struct DelayedHoverHint: ViewModifier {
    let message: String
    let alignment: Alignment
    @State private var isVisible = false
    @State private var pendingWork: DispatchWorkItem?
    
    func body(content: Content) -> some View {
        content
            .onHover { isHovering in
                pendingWork?.cancel()
                if isHovering {
                    let work = DispatchWorkItem { isVisible = true }
                    pendingWork = work
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
                } else {
                    isVisible = false
                }
            }
            .overlay(alignment: alignment) {
                if isVisible {
                    Text(message)
                        .font(.caption)
                        .lineLimit(nil)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: true, vertical: true)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .stroke(.white.opacity(0.14), lineWidth: 1)
                        }
                        .offset(y: message.contains("\n") ? -45 : -34)
                        .zIndex(1)
                        .allowsHitTesting(false)
                }
            }
            .onDisappear { pendingWork?.cancel() }
    }
}
private extension View {
    func hoverHint(_ message: String, alignment: Alignment = .topLeading) -> some View {
        modifier(DelayedHoverHint(message: message, alignment: alignment))
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
private struct IncompleteDownloadDialog: View {
    @Environment(\.colorScheme) private var colorScheme
    let incomplete: IncompleteDownload
    let save: () -> Void
    let abort: () -> Void
    let retry: () -> Void
    
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Failed to download \(incomplete.failedSegments.count) of \(incomplete.segments.count) segments")
                .font(.headline.weight(.semibold))
            
            Text("""
            You can either:
            • Retry download from the failed segment
            • Abort without saving
            • Save any successfully downloaded segments
            """)
            .font(.body)
            .foregroundStyle(Color.primary.opacity(0.68))
            .fixedSize(horizontal: false, vertical: true)
            
            VStack(spacing: 9) {
                DialogActionButton(title: "Retry", style: .primary, action: retry)
                DialogActionButton(title: "Abort", style: .destructive, action: abort)
                DialogActionButton(title: "Save", style: .secondary, action: save)
            }
        }
        .padding(22)
        .frame(width: 350)
        .background(
            Color(nsColor: .windowBackgroundColor),
            in: RoundedRectangle(cornerRadius: 22, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.primary.opacity(colorScheme == .light ? 0.16 : 0.20), lineWidth: 1)
        }
        .shadow(
            color: .black.opacity(colorScheme == .light ? 0.22 : 0.4),
            radius: 30,
            y: 12
        )
    }
}

private struct DialogActionButton: View {
    enum Style { case primary, destructive, secondary }
    let title: String
    let style: Style
    let action: () -> Void
    @State private var isHovered = false
    
    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.body.weight(.medium))
                .frame(maxWidth: .infinity)
                .frame(height: 42)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .foregroundStyle(foreground)
        .background(background, in: Capsule())
        .contentShape(Capsule())
        .onHover { isHovered = $0 }
    }
    
    private var foreground: Color {
        switch style {
        case .primary:
            return .white
        case .destructive:
            return Color(nsColor: .systemRed)
        case .secondary:
            return .primary
        }
    }
    
    private var background: Color {
        switch style {
        case .primary:
            return isHovered
            ? Color.accentColor.opacity(0.82)
            : .accentColor
            
        case .destructive, .secondary:
            return isHovered
            ? Color.primary.opacity(0.16)
            : Color.primary.opacity(0.10)
        }
    }
}
private struct StreamSelector: View {
    let streams: [Stream]
    @Binding var selection: String?
    
    var body: some View {
        ZStack {
            HStack {
                Text(streams.first(where: { $0.id == selection })?.name ?? "Choose a stream")
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer()
                Image(systemName: "chevron.down")
                    .font(.headline)
            }
            .padding(.horizontal, 12)
            .frame(width: 420, height: ControlMetrics.height)
            .contentShape(Rectangle())

            StreamMenuTrigger(streams: streams, selection: $selection)
                .frame(width: 420, height: ControlMetrics.height)
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
    @Binding var selection: String?
    
    func makeNSView(context: Context) -> StreamMenuTriggerView {
        let view = StreamMenuTriggerView()
        view.onSelect = { streamID in selection = streamID }
        return view
    }
    
    func updateNSView(_ view: StreamMenuTriggerView, context: Context) {
        view.streams = streams
        view.selectedID = selection
        view.onSelect = { streamID in selection = streamID }
    }
}

private final class StreamMenuTriggerView: NSView {
    var streams: [Stream] = []
    var selectedID: String?
    var onSelect: ((String) -> Void)?
    
    override func mouseDown(with event: NSEvent) {
        let menu = NSMenu()
        for stream in streams {
            let item = NSMenuItem(title: stream.name, action: #selector(selectStream(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = stream.id
            item.state = stream.id == selectedID ? .on : .off
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.height), in: self)
    }

    override func scrollWheel(with event: NSEvent) {
        guard !streams.isEmpty, event.scrollingDeltaY != 0 else { return }
        let currentIndex = streams.firstIndex { $0.id == selectedID } ?? 0
        let step = event.scrollingDeltaY > 0 ? -1 : 1
        let nextIndex = min(max(currentIndex + step, 0), streams.count - 1)
        guard nextIndex != currentIndex else { return }
        onSelect?(streams[nextIndex].id)
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
    @FocusState private var isFocused: Bool
    @State private var isHovered = false
    @State private var isHoveringCalendar = false
    
    var body: some View {
        HStack(spacing: 0) {
            TextField(DateFormats.numericPlaceholder(for: dateFormat), text: $value)
                .multilineTextAlignment(.center)
                .textFieldStyle(.plain)
                .frame(width: ControlMetrics.dateTimeValueWidth,
                       height: ControlMetrics.height)
                .focused($isFocused)
                .onSubmit(onCommit)
                .onChange(of: value) { _, text in
                    guard DateFormats.supportsNumericEntry(for: dateFormat) else { return }
                    let sanitized = DateFormats.sanitizedNumericInput(text, format: dateFormat)
                    if value != sanitized { value = sanitized }
                }

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

private struct TimeSelector: View {
    @Binding var value: String
    let onCommit: () -> Void
    @State private var isFocused = false
    @State private var isHovered = false
    @State private var isHoveringMenu = false

    private let timeOptions = (0..<48).map { index in
        String(format: "%02d:%02d:00", index / 2, index.isMultiple(of: 2) ? 0 : 30)
    }

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
                    options: timeOptions,
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
        .onChange(of: isFocused) { _, focused in
            if !focused { onCommit() }
        }
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
    
    final class Coordinator: NSObject, NSSearchFieldDelegate {
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

        func controlTextDidBeginEditing(_ notification: Notification) {
            setFocus(true)
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            setFocus(false)
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
            
            let removedText = text.substring(with: affectedCharRange)
            if !removedText.isEmpty {
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
            
            let formatted = proposed
            
            isNormalizing = true
            value = formatted
            lastAcceptedValue = formatted
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

private final class FocusTrackingTextField: NSTextField {
    var onFocusChange: ((Bool) -> Void)?

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .iBeam)
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted {
            onFocusChange?(true)
        }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted {
            onFocusChange?(false)
        }
        return accepted
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
    @State private var text = ""
    @FocusState private var isFocused: Bool
    
    private var maximumDigits: Int {
        String(range.upperBound).count
    }

    var body: some View {
        TextField("", text: $text)
            .multilineTextAlignment(.center)
            .textFieldStyle(.plain)
            .monospacedDigit()
            .focused($isFocused)
            .onAppear { text = String(value) }
            .onChange(of: text) { _, newText in
                let digits = String(newText.filter(\.isNumber).prefix(maximumDigits))
                if text != digits {
                    text = digits
                    return
                }
                guard let enteredValue = Int(digits) else { return }
                let clampedValue = min(max(enteredValue, range.lowerBound), range.upperBound)
                if enteredValue != clampedValue {
                    text = String(clampedValue)
                }
                value = clampedValue
            }
            .onChange(of: value) { _, newValue in
                let formatted = String(newValue)
                if text != formatted { text = formatted }
            }
            .onChange(of: isFocused) { _, focused in
                onFocusChanged(focused)
                if !focused { text = String(value) }
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

    func makeNSView(context: Context) -> ScrollViewConfigurationView {
        let view = ScrollViewConfigurationView()
        view.configure = { hostView in
            configureScrollView(containing: hostView)
        }
        return view
    }

    func updateNSView(_ view: ScrollViewConfigurationView, context: Context) {
        view.configure = { hostView in
            configureScrollView(containing: hostView)
        }
        view.configureNow()
    }

    private func configureScrollView(containing view: NSView) {
        var candidate: NSView? = view
        while let current = candidate {
            if let scrollView = findScrollView(in: current) {
                scrollView.scrollerStyle = scrollerStyle
                let needsVerticalScroller = (scrollView.documentView?.frame.height ?? 0)
                    > scrollView.contentView.bounds.height
                scrollView.hasVerticalScroller = needsVerticalScroller
                scrollView.autohidesScrollers = false
                scrollView.verticalScroller?.isHidden = !needsVerticalScroller
                DispatchQueue.main.async {
                    onConfigured(needsVerticalScroller)
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


struct StreamManagementView: View {
    private enum FocusTarget: Hashable {
        case streamList
        case search
    }

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var streamStore: StreamStore

    @State private var showingAddStream = false
    @State private var showingEditStream = false
    @State private var showingDeleteConfirmation = false
    @State private var showingResetConfirmation = false
    @State private var searchText = ""
    @State private var categoryFilter: StreamCategory?
    @State private var favouritesOnly = false
    @State private var isStreamListReady = false
    @State private var listNeedsScrollbar = true
    @AppStorage("skipDeleteConfirmation") private var skipDeleteConfirmation = false
    @AppStorage("activeStreamCategoryFilter") private var activeStreamCategoryFilter = ""
    @AppStorage("activeFavouritesOnly") private var activeFavouritesOnly = false
    @FocusState private var focusedTarget: FocusTarget?

    private var filteredStreams: [Stream] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return streamStore.streams.filter { stream in
            (categoryFilter == nil || stream.category == categoryFilter)
                && (!favouritesOnly || stream.isFavourite)
                && (query.isEmpty || stream.name.localizedCaseInsensitiveContains(query))
        }
    }


    private var allStreamsFilterBinding: Binding<Bool> {
        Binding(
            get: { categoryFilter == nil && !favouritesOnly },
            set: { isAllStreams in
                guard isAllStreams else { return }
                categoryFilter = nil
                favouritesOnly = false
            }
        )
    }

    private func categoryFilterBinding(for category: StreamCategory) -> Binding<Bool> {
        Binding(
            get: { categoryFilter == category },
            set: { isSelected in
                categoryFilter = isSelected ? category : nil
            }
        )
    }

    private func applyActiveFilter() {
        favouritesOnly = activeFavouritesOnly
        categoryFilter = StreamCategory.allCases.first { $0.title == activeStreamCategoryFilter }
    }

    private func saveActiveFilter() {
        activeFavouritesOnly = favouritesOnly
        activeStreamCategoryFilter = categoryFilter?.title ?? ""
        let matchingStreams = streamStore.streams.filter { stream in
            (!favouritesOnly || stream.isFavourite)
                && (categoryFilter == nil || stream.category == categoryFilter)
        }
        if !matchingStreams.contains(where: { $0.id == streamStore.selectedStreamID }) {
            streamStore.selectedStreamID = matchingStreams.first?.id
        }
    }
    private func dismissSearchFocus() {
        NSApp.keyWindow?.makeFirstResponder(nil)
    }

    private func handleStreamShortcut(_ keyPress: KeyPress) -> KeyPress.Result {
        guard focusedTarget == .streamList,
              let selectedStreamID = streamStore.selectedStreamID else {
            return .ignored
        }

        switch keyPress.characters.lowercased() {
        case "f":
            streamStore.toggleFavourite(selectedStreamID)
        case "t":
            streamStore.setCategory(.television, for: selectedStreamID)
        case "r":
            streamStore.setCategory(.radio, for: selectedStreamID)
        case "l":
            streamStore.setCategory(.liveStream, for: selectedStreamID)
        default:
            return .ignored
        }

        return .handled
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

                    Menu {
                        Toggle("All", isOn: allStreamsFilterBinding)
                        Divider()
                        Toggle("Favourites", isOn: $favouritesOnly)
                        Divider()
                        ForEach(StreamCategory.allCases) { category in
                            Toggle(category.title, isOn: categoryFilterBinding(for: category))
                        }
                    } label: {
                        ZStack {
                            RoundedRectangle(cornerRadius: ControlMetrics.cornerRadius, style: .continuous)
                                .fill(Color.primary.opacity(0.001))
                            Image(systemName: "line.3.horizontal.decrease.circle")
                                .resizable()
                                .scaledToFit()
                                .frame(width: 18, height: 18)
                        }
                        .frame(width: 40, height: 40)
                        .contentShape(Rectangle())
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .help("Filter streams")
                    .zIndex(1)
                }
                .padding(.leading, SettingsLayout.horizontalInset)
                .padding(.trailing, SettingsLayout.horizontalInset + SettingsLayout.scrollbarReserve - 10)
            }
            .padding(.top, SettingsLayout.horizontalInset)
            .padding(.bottom, 10)
            List(selection: $streamStore.selectedStreamID) {
                ForEach(filteredStreams) { stream in
                    streamRow(stream)
                }
                .onMove { source, destination in
                    streamStore.moveFiltered(
                        fromOffsets: source,
                        toOffset: destination,
                        in: filteredStreams
                    )
                    focusedTarget = .streamList
                }
            }
            .simultaneousGesture(TapGesture().onEnded {
                dismissSearchFocus()
            })
            .background(PersistentListScroller { needsScrollbar in
                listNeedsScrollbar = needsScrollbar
                isStreamListReady = true
            })
            .padding(.trailing, listNeedsScrollbar ? 0 : SettingsLayout.scrollbarReserve)
            .opacity(isStreamListReady ? 1 : 0)
            .frame(minWidth: 500, minHeight: 440)
            .padding(.leading, SettingsLayout.horizontalInset - 16)
            .focusable()
            .focusEffectDisabled()
            .focused($focusedTarget, equals: .streamList)
            .onKeyPress(characters: .letters) { handleStreamShortcut($0) }
            .onDeleteCommand {
                deleteSelectedStream()
            }

            Divider()

            HStack {
                Button("Restore default list", role: .destructive) {
                    showingResetConfirmation = true
                }
                Spacer()
                Button("Add stream") { showingAddStream = true }
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.vertical, SettingsLayout.horizontalInset)
                        .padding(.horizontal, SettingsLayout.horizontalInset)
        }
        .navigationTitle("Streams")
        .onAppear {
            applyActiveFilter()
            DispatchQueue.main.async {
                focusedTarget = .streamList
            }
        }
        .onDisappear(perform: saveActiveFilter)
        .sheet(isPresented: $showingAddStream) {
            StreamEditorView(title: "Add stream") { name, url, category in
                try streamStore.add(name: name, url: url, category: category)
            }
        }
        .sheet(isPresented: $showingEditStream) {
            if let stream = streamStore.selectedStream {
                StreamEditorView(title: "Edit stream", stream: stream) { name, url, category in
                    try streamStore.update(
                        originalName: stream.name,
                        name: name,
                        url: url,
                        category: category
                    )
                }
            }
        }
        .alert("Delete stream?", isPresented: $showingDeleteConfirmation) {
            Button("Delete", role: .destructive) { streamStore.deleteSelected() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This stream will be removed from the list.")
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


    private func deleteSelectedStream() {
        if skipDeleteConfirmation {
            streamStore.deleteSelected()
        } else {
            showingDeleteConfirmation = true
        }
    }

    @ViewBuilder
    private func streamRow(_ stream: Stream) -> some View {
        HStack(spacing: 8) {
            Text(stream.name)
                .lineLimit(1)
            Spacer(minLength: 8)
            if stream.isFavourite {
                Image(systemName: "star.fill")
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 18, height: 18)
                    .accessibilityLabel("Favourite")
            }
            Image(systemName: stream.category.iconName)
                .font(.system(size: 14, weight: .medium))
                .frame(width: 18, height: 18)
                .accessibilityLabel(stream.category.title)
        }
        .tag(Optional(stream.id))
        .contentShape(Rectangle())
        .contextMenu {
            Button(stream.isFavourite ? "Unfavourite" : "Favourite") {
                streamStore.selectedStreamID = stream.id
                streamStore.toggleFavourite(stream.id)
            }
            Divider()
            Button("Edit") {
                streamStore.selectedStreamID = stream.id
                showingEditStream = true
            }
            Divider()
            Button("Delete", role: .destructive) {
                streamStore.selectedStreamID = stream.id
                deleteSelectedStream()
            }
        }
    }
}

struct StreamEditorView: View {
    @Environment(\.dismiss) private var dismiss

    let title: String
    let save: (String, String, StreamCategory) throws -> Void
    @State private var name: String
    @State private var url: String
    @State private var category: StreamCategory
    @State private var errorMessage: String?

    init(
        title: String,
        stream: Stream? = nil,
        save: @escaping (String, String, StreamCategory) throws -> Void
    ) {
        self.title = title
        self.save = save
        _name = State(initialValue: stream?.name ?? "")
        _url = State(initialValue: stream?.url ?? "")
        _category = State(initialValue: stream?.category ?? .television)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.title2.bold())
            TextField("Choose a stream name (e.g. BBC World News Europe UHD)", text: $name)
            TextField("Paste a stream URL (.mpd or .m3u8 only)", text: $url)
            VStack(alignment: .leading, spacing: 8) {
                Text("Stream type")
                    .font(.headline)

                Picker("", selection: $category) {
                    ForEach(StreamCategory.allCases) { category in
                        Text(category.title).tag(category)
                    }
                }
                .labelsHidden()
                .pickerStyle(.radioGroup)
                .horizontalRadioGroupLayout()
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save", action: saveStream)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 520)
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
            try save(name, url, category)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("dateFormat") private var dateFormat = "dd/MM/yyyy"
    @AppStorage("downloadFolder") private var downloadFolderPath = ""
    @AppStorage("downloadDefaultHours") private var defaultHours = 0
    @AppStorage("downloadDefaultMinutes") private var defaultMinutes = 1
    @AppStorage("downloadDefaultSeconds") private var defaultSeconds = 0
    @AppStorage("encodeH265") private var encodeH265 = false
    @AppStorage("revealFinishedVideo") private var revealFinishedMedia = false
    @AppStorage("downloadAttempts") private var downloadAttempts = 3
    @AppStorage("retryDelay") private var retryDelay = 2.0
    @AppStorage("checkForUpdates") private var checkForUpdates = true
    @AppStorage("skipDeleteConfirmation") private var skipDeleteConfirmation = false
    @AppStorage("sequentialDownloads") private var sequentialDownloads = false
    @AppStorage("segmentDownloadLimit") private var segmentDownloadLimit = 5
    @AppStorage("streamLaunchFilter") private var launchStreamFilter = "All"
    @AppStorage("activeStreamCategoryFilter") private var activeStreamCategoryFilter = ""
    @AppStorage("activeFavouritesOnly") private var activeFavouritesOnly = false
    @AppStorage("downloadFilenameFormat") private var downloadFilenameFormat = DownloadFilenameFormat.firstSegment.rawValue
    @AppStorage("appearanceMode") private var appearanceMode = AppAppearance.system.rawValue
    @AppStorage("downloadCompletionNotificationStyle")
    private var completionNotificationStyle = CompletionNotificationStyle.inApp.rawValue
    @State private var isShowingDefaultDurationEditor = false
    @State private var settingsNeedsScrollbar = true
    @State private var isSettingsScrollReady = false
    
    private var streamFilterChoices: [String] {
        ["All", "Favourites"] + StreamCategory.allCases.map(\.title)
    }

    private var filenameFormatBinding: Binding<DownloadFilenameFormat> {
        Binding(
            get: { DownloadFilenameFormat(rawValue: downloadFilenameFormat) ?? .firstSegment },
            set: { downloadFilenameFormat = $0.rawValue }
        )
    }

    private var appearanceBinding: Binding<AppAppearance> {
        Binding(
            get: { AppAppearance(rawValue: appearanceMode) ?? .system },
            set: { appearanceMode = $0.rawValue }
        )
    }

    private var completionNotificationStyleBinding: Binding<CompletionNotificationStyle> {
        Binding(
            get: { CompletionNotificationStyle(rawValue: completionNotificationStyle) ?? .inApp },
            set: { completionNotificationStyle = $0.rawValue }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Settings")
                        .font(.largeTitle.weight(.bold))
                    SettingsSection(title: "Download defaults") {
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
                                Text("Default download duration")
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
                                            Button("Done") {
                                                isShowingDefaultDurationEditor = false
                                            }
                                            .buttonStyle(.borderedProminent)
                                        }
                                    }
                                    .padding(20)
                                }
                            }
                            .frame(height: ControlMetrics.settingsRowHeight)
                            Divider()
                            SettingsToggleRow("Encode to H.265 enabled by default", isOn: $encodeH265)
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
                        }
                    }

                    SettingsSection(title: "Stream management") {
                        SettingsCard {
                            HStack {
                                Text("Default stream filter")
                                Spacer()
                                SettingsPopupMenu(
                                    values: streamFilterChoices,
                                    selection: $launchStreamFilter,
                                    title: { $0 }
                                )
                            }
                            .frame(height: ControlMetrics.settingsRowHeight)
                            Divider()
                            SettingsToggleRow("Skip confirmation when deleting streams", isOn: $skipDeleteConfirmation)
                        }
                    }
                    
                    SettingsSection(title: "Download behaviour") {
                        SettingsCard {
                            SettingsToggleRow("Play media when download completes", isOn: $revealFinishedMedia)
                            Divider()
                            HStack {
                                Text("Download status notifications")
                                Spacer()
                                SettingsPopupMenu(
                                    values: CompletionNotificationStyle.allCases,
                                    selection: completionNotificationStyleBinding,
                                    title: { $0.rawValue }
                                )
                            }
                            .frame(height: ControlMetrics.settingsRowHeight)
        .onChange(of: completionNotificationStyle) { _, rawValue in
            let style = CompletionNotificationStyle(rawValue: rawValue) ?? .inApp
            if style.usesSystemNotification {
                DownloadNotifications.requestPermission()
            }
        }
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
                                        title: { count in
                                            "\(count) segments"
                                        }
                                    )
                                }
                                .frame(height: ControlMetrics.settingsRowHeight)
                            }
                        }
                    }
                    
                    SettingsSection(title: "Retry failed segments") {
                        SettingsCard {
                            HStack {
                                Text("Number of retry attempts")
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
                                Text("Time between attempts")
                                Spacer()
                                SettingsMenuPicker(
                                    values: Array(1...10),
                                    selection: Binding(
                                        get: { min(10, max(1, Int(retryDelay.rounded()))) },
                                        set: { retryDelay = Double($0) }
                                    ),
                                    title: { seconds in
                                        "\(seconds) \(seconds == 1 ? "second" : "seconds")"
                                    }
                                )
                            }
                            .frame(height: ControlMetrics.settingsRowHeight)
                        }
                    }
                    SettingsSection(title: "Date display") {
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
                        }
                    }

                    SettingsSection(title: "Appearance") {
                        SettingsCard {
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
                        }
                    }

                    SettingsSection(title: "Updates") {
                        SettingsCard {
                            SettingsToggleRow("Check for updates on app launch", isOn: $checkForUpdates)
                        }
                    }
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
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.vertical, SettingsLayout.horizontalInset)
            .padding(.horizontal, SettingsLayout.horizontalInset)
        }
        .frame(width: SettingsLayout.sheetWidth, height: SettingsLayout.sheetHeight)
        .onAppear(perform: prepareSettings)
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
        if ![2, 5, 10, 15, 20, 25].contains(segmentDownloadLimit) {
            segmentDownloadLimit = 5
        }
        if !(1...10).contains(downloadAttempts) {
            downloadAttempts = 3
        }
        if !(1...10).contains(Int(retryDelay.rounded())) {
            retryDelay = 2
        }
        if DownloadFilenameFormat(rawValue: downloadFilenameFormat) == nil {
            downloadFilenameFormat = DownloadFilenameFormat.firstSegment.rawValue
        }
        if AppAppearance(rawValue: appearanceMode) == nil {
            appearanceMode = AppAppearance.system.rawValue
        }
        if CompletionNotificationStyle(rawValue: completionNotificationStyle) == nil {
            completionNotificationStyle = CompletionNotificationStyle.inApp.rawValue
        }
    }
    
    private func resetToDefaults() {
        dateFormat = "dd/MM/yyyy"
        defaultHours = 0
        defaultMinutes = 1
        defaultSeconds = 0
        encodeH265 = false
        revealFinishedMedia = false
        downloadAttempts = 3
        retryDelay = 2
        checkForUpdates = true
        skipDeleteConfirmation = false
        launchStreamFilter = "All"
        activeStreamCategoryFilter = ""
        activeFavouritesOnly = false
        sequentialDownloads = false
        segmentDownloadLimit = 5
        downloadFolderPath = ""
        downloadFilenameFormat = DownloadFilenameFormat.firstSegment.rawValue
        appearanceMode = AppAppearance.system.rawValue
        completionNotificationStyle = CompletionNotificationStyle.inApp.rawValue
    }
    
    private func prepareSettings() {
        DownloadNotifications.migrateLegacyPreferenceIfNeeded()
        completionNotificationStyle = UserDefaults.standard.string(
            forKey: "downloadCompletionNotificationStyle"
        ) ?? CompletionNotificationStyle.inApp.rawValue
        normaliseMenuSettings()
        DispatchQueue.main.async {
            NSApp.keyWindow?.makeFirstResponder(nil)
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
        return NSSize(width: ceil(titleWidth) + 44, height: Self.controlHeight)
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
        // Scrolling does not move the pointer, so there is no mouse-exit event
        // to clear the custom hover state as the settings move underneath it.
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
        (displayTitle as NSString).draw(at: textOrigin, withAttributes: attributes)
        
    }
}
