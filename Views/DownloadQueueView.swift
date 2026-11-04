import AppKit
import SwiftUI

struct DownloadQueueView: View {
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
                Text(downloadController.pendingEdits.isEmpty
                     ? "\(downloadController.queue.count) queued"
                     : "\(downloadController.queue.count) queued · \(downloadController.pendingEdits.count) to edit")
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

                if !downloadController.pendingEdits.isEmpty {
                    Text("Awaiting editing")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                        .listRowBackground(Color.clear)
                    ForEach(downloadController.pendingEdits) { edit in
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                if let request = edit.request { requestDetails(for: request) }
                                else { Text(edit.title).lineLimit(1) }
                                Text(edit.output.lastPathComponent).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            if downloadController.activeEditID == edit.id {
                                Button("Show editor") { MediaTrimWindow.focusCurrent() }
                            } else {
                                Button("Edit") { downloadController.openPendingEdit(edit) }
                                    .disabled(downloadController.activeEditID != nil)
                            }
                        }
                        .contextMenu {
                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([edit.output]) }
                            Button("Keep unedited") { downloadController.keepUneditedOutput(edit) }
                                .disabled(downloadController.activeEditID == edit.id)
                        }
                    }
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
                    Text(DateFormats.duration(request.duration))
                }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Duration: \(DateFormats.duration(request.duration))")
                HStack(spacing: 6) {
                    Image(systemName: "calendar").fixedSize()
                    Text(DateFormats.displayDateTime(request.start, format: dateFormat))
                }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Start: \(DateFormats.displayDateTime(request.start, format: dateFormat))")
                if request.shouldEncodeDownload {
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
}
