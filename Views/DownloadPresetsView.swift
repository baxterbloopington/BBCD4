import AppKit
import SwiftUI

struct DownloadPresetNameView: View {
    let title: String
    let saveName: (String) throws -> Void
    @State private var name: String
    @State private var errorMessage: String?
    @FocusState private var nameFocused: Bool
    @Environment(\.dismiss) private var dismiss

    init(title: String, name: String = "", saveName: @escaping (String) throws -> Void) {
        self.title = title
        self.saveName = saveName
        _name = State(initialValue: name)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.title2.weight(.bold))
            TextField("Preset name", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($nameFocused)
                .onSubmit(save)
            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save", action: save).keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 340)
        .presentationBackground(Color(nsColor: .windowBackgroundColor))
        .onAppear { nameFocused = true }
    }

    private func save() {
        do {
            try saveName(name)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct DownloadPresetsView: View {
    @ObservedObject var store: DownloadPresetStore
    @ObservedObject var timeOptionsStore: TimeOptionsStore
    @EnvironmentObject private var streamStore: StreamStore
    @AppStorage("skipDeleteConfirmation") private var skipDeleteConfirmation = false
    @State private var selection: DownloadPreset.ID?
    @State private var isAddingPreset = false
    @State private var editingPreset: DownloadPreset?
    @State private var deletingPreset: DownloadPreset?

    private var selectedPreset: DownloadPreset? { store.presets.first { $0.id == selection } }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Download presets").font(.largeTitle.weight(.bold))
                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.top, 16)
            .padding(.bottom, 4)
            List(selection: $selection) {
                ForEach(store.presets) { preset in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(preset.name).font(.body.weight(.semibold)).lineLimit(1)
                        presetDetails(preset)
                    }
                    .padding(.vertical, 3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
                    .tag(preset.id)
                    .simultaneousGesture(TapGesture(count: 2).onEnded { editingPreset = preset })
                    .contextMenu {
                        Button("Edit…") { editingPreset = preset }
                        Button("Duplicate") { selection = store.duplicate(preset)?.id }
                        Button("Delete", role: .destructive) { confirmDeletion(preset) }
                    }
                }
                .onMove(perform: store.move)
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            .contentMargins(.vertical, 0, for: .scrollContent)
            .padding(.horizontal, 8)
            .overlay {
                if store.presets.isEmpty {
                    Text(streamStore.streams.isEmpty ? "Add a stream before creating a preset." : "Choose Add preset to create a preset.")
                        .font(.subheadline).foregroundStyle(.secondary)
                        .allowsHitTesting(false)
                }
            }
            .onDeleteCommand { if let selectedPreset { confirmDeletion(selectedPreset) } }
            Divider()
            HStack {
                Spacer()
                Button("Add preset") { isAddingPreset = true }
                    .disabled(streamStore.streams.isEmpty)
                Button("Done") { closeSecondaryWindow() }.keyboardShortcut(.defaultAction)
            }
            .padding(24)
        }
        .frame(width: ControlMetrics.mainWindowWidth, height: 420)
        .sheet(isPresented: $isAddingPreset) {
            DownloadPresetEditorView(store: store, streamStore: streamStore, timeOptionsStore: timeOptionsStore)
        }
        .sheet(item: $editingPreset) { preset in
            DownloadPresetEditorView(preset: preset, store: store, streamStore: streamStore, timeOptionsStore: timeOptionsStore)
        }
        .alert("Delete preset?", isPresented: Binding(
            get: { deletingPreset != nil },
            set: { if !$0 { deletingPreset = nil } }
        )) {
            Button("Delete", role: .destructive) {
                if let deletingPreset { store.remove(deletingPreset) }
                deletingPreset = nil
            }
            Button("Cancel", role: .cancel) { deletingPreset = nil }
        } message: {
            Text("The preset \"\(deletingPreset?.name ?? "")\" will be deleted. This cannot be undone.")
        }
    }

    private func presetDetails(_ preset: DownloadPreset) -> some View {
        let stream = preset.stream(in: streamStore.streams)
        return HStack(spacing: 8) {
            HStack(spacing: 3) {
                Image(systemName: (stream?.category ?? StreamCategory.inferred(from: preset.streamURL)).iconName).fixedSize()
                Text(stream?.name ?? preset.streamName)
                    .lineLimit(1).truncationMode(.tail)
            }
            HStack(spacing: 3) {
                Image(systemName: "calendar").fixedSize()
                Text(preset.time)
            }.fixedSize()
                .accessibilityLabel("Start time: \(preset.time)")
            HStack(spacing: 3) {
                Image(systemName: "clock").fixedSize()
                Text(DateFormats.duration(preset.duration))
            }.fixedSize()
                .accessibilityLabel("Duration: \(DateFormats.duration(preset.duration))")
            if preset.editOutput { DownloadOptionBadge(title: "Edit output").fixedSize() }
            else if preset.encode { DownloadOptionBadge(title: "Encoded").fixedSize() }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func confirmDeletion(_ preset: DownloadPreset) {
        if skipDeleteConfirmation { store.remove(preset) }
        else { deletingPreset = preset }
    }
}

private struct DownloadPresetEditorView: View {
    let preset: DownloadPreset?
    @ObservedObject var store: DownloadPresetStore
    @ObservedObject var streamStore: StreamStore
    @ObservedObject var timeOptionsStore: TimeOptionsStore
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var streamID: String?
    @State private var startTime: String
    @State private var hours: Int
    @State private var minutes: Int
    @State private var seconds: Int
    @State private var editOutput: Bool
    @State private var encode: Bool
    @State private var errorMessage: String?

    init(preset: DownloadPreset? = nil, store: DownloadPresetStore, streamStore: StreamStore, timeOptionsStore: TimeOptionsStore) {
        self.preset = preset
        self.store = store
        self.streamStore = streamStore
        self.timeOptionsStore = timeOptionsStore
        let defaults = UserDefaults.standard
        let initialStream = preset == nil ? streamStore.selectedStream ?? streamStore.streams.first : preset?.stream(in: streamStore.streams)
        _name = State(initialValue: preset?.name ?? "")
        _streamID = State(initialValue: initialStream?.id)
        _startTime = State(initialValue: preset?.time ?? timeOptionsStore.options.first ?? "00:00:00")
        _hours = State(initialValue: min(DownloadLimits.maximumSelectableHours, max(0, preset.map { $0.duration / 3_600 } ?? defaults.integer(forKey: "downloadDefaultHours"))))
        _minutes = State(initialValue: preset.map { $0.duration / 60 % 60 } ?? min(59, max(0, defaults.object(forKey: "downloadDefaultMinutes") as? Int ?? 1)))
        _seconds = State(initialValue: preset.map { $0.duration % 60 } ?? min(59, max(0, defaults.integer(forKey: "downloadDefaultSeconds"))))
        _editOutput = State(initialValue: preset?.editOutput ?? (defaults.object(forKey: MediaTrimPreferences.enabledKey) as? Bool ?? MediaTrimPreferences.defaultEnabled))
        _encode = State(initialValue: preset?.encode ?? (defaults.object(forKey: "encodeH265") as? Bool ?? EncodingConfiguration.defaultEnabled))
    }

    private var selectedStream: Stream? { streamStore.streams.first { $0.id == streamID } }
    private var canEncode: Bool {
        selectedStream.map { MediaTrimPreferences.canEncodeDownload(category: $0.category, editing: editOutput) } ?? false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(preset == nil ? "Add preset" : "Edit preset").font(.title2.weight(.bold))
            TextField("Preset name", text: $name).textFieldStyle(.roundedBorder)
                .accessibilityLabel("Preset name")
            VStack(alignment: .leading, spacing: 8) {
                Text("Stream").font(.headline)
                StreamSelector(streams: streamStore.streams, groups: streamStore.groups, selection: $streamID,
                               availability: nil, checkingURLs: [])
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Start time").font(.headline)
                TimeSelector(value: $startTime, options: timeOptionsStore.options, onCommit: normaliseTime)
                    .frame(width: ControlMetrics.timeWidth, height: ControlMetrics.height)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Duration").font(.headline)
                HStack(spacing: ControlMetrics.fieldGap) {
                    DurationControl(title: "Hours", value: $hours, range: 0...DownloadLimits.maximumSelectableHours)
                    DurationControl(title: "Minutes", value: $minutes, range: 0...59)
                    DurationControl(title: "Seconds", value: $seconds, range: 0...59)
                }
            }
            HStack(spacing: ControlMetrics.fieldGap) {
                Toggle("Edit output", isOn: $editOutput).toggleStyle(.checkbox)
                Toggle("Encode", isOn: Binding(get: { canEncode && encode }, set: { encode = $0 }))
                    .toggleStyle(.checkbox)
                    .disabled(!canEncode)
                    .opacity(canEncode ? 1 : 0.2)
            }
            if let errorMessage { Text(errorMessage).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save", action: save).keyboardShortcut(.defaultAction)
            }
        }
        .frame(width: ControlMetrics.durationRowWidth)
        .padding(24)
        .presentationBackground(Color(nsColor: .windowBackgroundColor))
    }

    private func normaliseTime() {
        if let time = try? TimeOptionsStore.validated(startTime) { startTime = time }
    }

    private func save() {
        do {
            guard let stream = selectedStream else { throw DownloadPresetStore.PresetError.missingStream }
            guard let time = try? TimeOptionsStore.validated(startTime) else { throw DownloadPresetStore.PresetError.invalidTime }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_GB")
            formatter.dateFormat = "HH:mm:ss"
            guard let start = formatter.date(from: time) else { throw DownloadPresetStore.PresetError.invalidTime }
            let duration = hours * 3_600 + minutes * 60 + seconds
            if let preset {
                try store.update(preset, name: name, stream: stream, start: start, duration: duration,
                                 editOutput: editOutput, encode: canEncode && encode)
            } else {
                try store.add(name: name, stream: stream, start: start, duration: duration,
                              editOutput: editOutput, encode: canEncode && encode)
            }
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
