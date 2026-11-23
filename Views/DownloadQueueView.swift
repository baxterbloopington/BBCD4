import AppKit
import SwiftUI

struct DownloadQueueView: View {
    private static let actionColumnWidth: CGFloat = 24
    @ObservedObject var downloadController: DownloadController
    @AppStorage("dateFormat") private var dateFormat = "dd/MM/yyyy"
    @AppStorage("skipDeleteConfirmation") private var skipDeleteConfirmation = false
    @State private var pendingQueueDeletion: [QueuedDownload] = []
    @State private var isShowingClearQueueConfirmation = false
    @State private var primaryActionEventMonitor: Any?

    private var scheduledDownloads: [QueuedDownload] { downloadController.scheduledDownloads }
    private var queuedDownloads: [QueuedDownload] { downloadController.queue.filter { !$0.request.isScheduled } }
    private var hasActiveDownload: Bool { downloadController.currentRequest != nil && downloadController.isDownloading }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Download queue")
                    .font(.largeTitle.weight(.bold))
                Spacer()
            }
            .padding(24)

            List {
                if let request = downloadController.currentRequest, downloadController.isDownloading {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Currently downloading")
                            .font(.system(size: 15, weight: .semibold))
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

                if !downloadController.pendingEdits.isEmpty {
                    sectionTitle("Awaiting editing", count: downloadController.pendingEdits.count, separated: hasActiveDownload)
                    ForEach(downloadController.pendingEdits) { edit in
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                if let request = edit.request { requestDetails(for: request) }
                                else { Text(edit.title).font(.body).lineLimit(1) }
                                Text(edit.output.lastPathComponent).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            }
                            Spacer()
                            if downloadController.activeEditID == edit.id {
                                Button("Show editor") { MediaTrimWindow.focusCurrent() }
                            } else {
                                Button("Edit") { downloadController.openPendingEdit(edit) }
                                    .disabled(downloadController.activeEditID != nil)
                            }
                        }
                        .controlSize(.small)
                        .contextMenu {
                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([edit.output]) }
                            Button("Keep unedited") { downloadController.keepUneditedOutput(edit) }
                                .disabled(downloadController.activeEditID == edit.id)
                        }
                    }
                }

                if !queuedDownloads.isEmpty || scheduledDownloads.isEmpty {
                    sectionTitle("Queued downloads", count: queuedDownloads.count, separated: hasActiveDownload || !downloadController.pendingEdits.isEmpty)
                    if queuedDownloads.isEmpty {
                        Text("No downloads are queued.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        queuedItems(queuedDownloads, scheduled: false)
                    }
                }
                if !scheduledDownloads.isEmpty {
                    sectionTitle("Scheduled downloads", count: scheduledDownloads.count, separated: hasActiveDownload || !downloadController.pendingEdits.isEmpty || !queuedDownloads.isEmpty)
                    queuedItems(scheduledDownloads, scheduled: true)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .padding(.horizontal, SettingsLayout.horizontalInset - 8)
            .frame(maxHeight: .infinity)

            Divider()

            HStack {
                Button("Clear all", role: .destructive) {
                    confirmClearQueue()
                }
                .disabled(downloadController.queue.isEmpty)
                Button(downloadController.isQueuePaused ? "Resume queue" : "Pause queue") {
                    downloadController.toggleQueuePaused()
                }
                .disabled(queuedDownloads.isEmpty)
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
        .alert(pendingQueueDeletion.allSatisfy { $0.request.isScheduled } ? "Remove scheduled download?" : "Remove queued download?", isPresented: Binding(
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
        .alert("Clear all downloads?", isPresented: $isShowingClearQueueConfirmation) {
            Button("Clear all", role: .destructive) {
                downloadController.clearQueue()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("All queued downloads and scheduled downloads will be removed.")
        }
    }

    private func sectionTitle(_ title: String, count: Int, separated: Bool = false) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.primary)
            Spacer()
            Text(count, format: .number)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(width: Self.actionColumnWidth)
        }
        .padding(.top, separated ? 24 : 8)
        .padding(.bottom, 4)
        .listRowBackground(Color.clear)
    }

    private var queueDeletionMessage: String {
        if pendingQueueDeletion.count == 1, let item = pendingQueueDeletion.first {
            return item.request.isScheduled
                ? "Remove the scheduled download for \(item.request.stream.name)?"
                : "Remove \(item.request.stream.name) from the download queue?"
        }
        return "Remove \(pendingQueueDeletion.count) queued downloads?"
    }

    private func queuedItems(_ items: [QueuedDownload], scheduled: Bool) -> some View {
        ForEach(items) { item in
            HStack(spacing: 12) {
                requestDetails(for: item.request)
                Spacer()
                Button(role: .destructive) { confirmQueueDeletion([item]) } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .frame(width: Self.actionColumnWidth, height: 24)
                .hoverHint("Remove from queue", alignment: .topTrailing)
            }
            .contextMenu {
                Button("Remove from queue", role: .destructive) { confirmQueueDeletion([item]) }
            }
        }
        .onMove(perform: scheduled ? nil : { downloadController.moveQueuedDownloads(fromOffsets: $0, toOffset: $1, scheduled: false) })
        .onDelete { offsets in confirmQueueDeletion(offsets.map { items[$0] }) }
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
                .font(.body)
                .lineLimit(1)
            HStack(spacing: 8) {
                HStack(spacing: 4) {
                    Image(systemName: "clock").fixedSize()
                    Text(DateFormats.duration(request.duration))
                }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Duration: \(DateFormats.duration(request.duration))")
                HStack(spacing: 4) {
                    Image(systemName: "calendar").fixedSize()
                    Text(DateFormats.displayDateTime(request.start, format: dateFormat))
                }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Start: \(DateFormats.displayDateTime(request.start, format: dateFormat))")
                if request.shouldEncodeDownload {
                    DownloadOptionBadge(title: "Encoded")
                }
                if request.editOutput {
                    DownloadOptionBadge(title: "Edit output")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
        }
    }
}
