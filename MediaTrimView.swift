import AppKit
import AVFoundation
import AVKit
import SwiftUI

@MainActor
final class MediaTrimModel: ObservableObject {
    let source: URL
    let player = AVPlayer()
    @Published private(set) var duration = 0.0
    @Published private(set) var isAudioOnly = false
    @Published private(set) var selection = MediaTrimSelection(start: 0, end: 0)
    @Published private(set) var cuts: [MediaTrimSelection] = []
    @Published private(set) var cutStart: Double?
    @Published private(set) var selectedCutIndex: Int?
    @Published private(set) var position = 0.0
    @Published private(set) var isPlaying = false
    @Published private(set) var isPlaybackRequested = false
    @Published private(set) var playbackSpeed: Float = 1
    @Published private(set) var isSaving = false
    @Published private(set) var isEncoding = false
    @Published private(set) var encodingProgress = 0.0
    @Published private(set) var isCapturingFrame = false
    @Published private(set) var frameCaptureMessage: String?
    var encodingPercentage: Int { Int((encodingProgress * 100).rounded(.down)) }
    var hasUnsavedChanges: Bool {
        guard duration > 0 else { return false }
        return selection != MediaTrimSelection(start: 0, end: duration)
            || !cuts.isEmpty || cutStart != nil
            || startText != timecode(selection.start) || endText != timecode(selection.end)
    }
    @Published private(set) var isPreparingPreview = true
    @Published private(set) var waveform: AudioWaveform = .loading
    @Published private(set) var timelineViewport = MediaTrimTimelineViewport()
    @Published private var waveformDetail: (range: MediaTrimSelection, waveform: AudioWaveform)?
    @Published var startText = "00:00:00:00"
    @Published var endText = "00:00:00:00"
    @Published var errorMessage: String?
    private var observer: Any?
    private var playbackEndObserver: NSObjectProtocol?
    private var itemObservation: NSKeyValueObservation?
    private var previewSource: MediaTrimPreviewSource?
    private var saveTask: Task<Void, Never>?
    private var frameCaptureTask: Task<Void, Never>?
    private var frameCaptureMessageTask: Task<Void, Never>?
    private var lastFrameCaptureError: String?
    private var wheelFinishTask: Task<Void, Never>?
    private var handleDragTask: Task<Void, Never>?
    private var handleDrag: MediaTrimHandleDrag?
    private var waveformTask: Task<Void, Never>?
    private var waveformDetailTask: Task<Void, Never>?
    private var wheelMotion = MediaTrimWheelMotion()
    private(set) var isWheelScrolling = false
    private var isStopped = false
    private var isScrubbing = false
    private var appliedPlaybackRange: MediaTrimSelection?
    private var playAfterSeeking = false
    private struct EditState: Equatable {
        let selection: MediaTrimSelection
        let cuts: [MediaTrimSelection]
        let cutStart: Double?
        let selectedCutIndex: Int?
        let position: Double
        let viewport: MediaTrimTimelineViewport
    }
    private let history = EditHistory<EditState>()
    var undoManager: UndoManager { history.undoManager }
    private var handleEditStart: EditState?
    private var restoringEdit = false
    private var editState: EditState {
        EditState(selection: selection, cuts: cuts, cutStart: cutStart, selectedCutIndex: selectedCutIndex,
                  position: position, viewport: timelineViewport)
    }

    private func recordEdit(_ previous: EditState, name: String) {
        guard !restoringEdit, handleEditStart == nil else { return }
        let current = editState
        guard previous.selection != current.selection || previous.cuts != current.cuts || previous.cutStart != current.cutStart else { return }
        history.record(previous, current: current, name: name) { [weak self] state in self?.restoreEdit(state) }
    }

    private func restoreEdit(_ state: EditState) {
        guard !isStopped, !isSaving else { return }
        restoringEdit = true
        cancelPendingScrubbing()
        pausePlayback()
        selection = state.selection
        cuts = state.cuts
        cutStart = state.cutStart
        selectedCutIndex = state.selectedCutIndex
        timelineViewport = state.viewport
        syncFields()
        validateCuts()
        releasePlaybackRange()
        seek(state.position)
        requestWaveformDetail()
        restoringEdit = false
    }
    private(set) var frameDuration = 1.0 / 30
    private lazy var seeker: MediaPreviewSeeker = {
        let seeker = MediaPreviewSeeker { [weak self] request, completion in
            guard let self, !self.isStopped else { completion(false); return }
            let tolerance = request.precise ? 0.0 : 0.04
            let before = CMTime(seconds: min(tolerance, max(0, request.time - self.selection.start)), preferredTimescale: 600_000)
            let after = CMTime(seconds: min(tolerance, max(0, self.selection.end - request.time - 1.0 / 600_000)), preferredTimescale: 600_000)
            self.player.seek(to: CMTime(value: Int64((request.time * 600_000).rounded()), timescale: 600_000),
                             toleranceBefore: before, toleranceAfter: after) { finished in
                Task { @MainActor in completion(finished) }
            }
        }
        seeker.onSettled = { [weak self] finished in
            guard let self, !self.isStopped else { return }
            if self.playAfterSeeking && finished {
                self.playAfterSeeking = false
                self.resumePlayback()
            }
            if !finished { self.pausePlayback() }
        }
        return seeker
    }()

    init(source: URL) {
        self.source = source
        isAudioOnly = source.pathExtension.lowercased() == "m4a"
        if isAudioOnly { frameDuration = 0.001; startText = "00:00:00.000"; endText = "00:00:00.000" }
        player.automaticallyWaitsToMinimizeStalling = false
    }

    var timelineRange: MediaTrimSelection {
        .init(start: timelineViewport.start * duration, end: timelineViewport.end * duration)
    }

    var visibleWaveform: (waveform: AudioWaveform, range: ClosedRange<Double>) {
        let range = timelineRange
        if let detail = waveformDetail, detail.range.start <= range.start, detail.range.end >= range.end {
            return (detail.waveform, ((range.start - detail.range.start) / detail.range.duration)...((range.end - detail.range.start) / detail.range.duration))
        }
        return (waveform, timelineViewport.start...timelineViewport.end)
    }

    @discardableResult
    func scrollTimeline(delta: Double, horizontal: Double = 0, precise: Bool, pan: Bool = false, anchor: Double) -> Bool {
        guard !isStopped, !isSaving, duration > 0, delta.isFinite, horizontal.isFinite else { return false }
        if pan || abs(horizontal) > abs(delta) {
            timelineViewport.pan(-(pan ? delta : horizontal) * (precise ? 0.002 : 0.05))
        } else {
            timelineViewport.zoom(delta: delta, precise: precise, anchor: anchor, duration: duration, frameDuration: frameDuration)
        }
        requestWaveformDetail()
        return true
    }

    func panTimeline(to fraction: Double) {
        guard !isStopped, !isSaving else { return }
        timelineViewport.move(to: fraction)
        requestWaveformDetail()
    }

    private func revealPlayhead() {
        guard !isScrubbing else { return }
        let previous = timelineViewport
        timelineViewport.reveal(position / max(duration, 0.001))
        if previous != timelineViewport { requestWaveformDetail() }
    }

    private func requestWaveformDetail() {
        waveformDetailTask?.cancel()
        waveformDetailTask = nil
        guard timelineViewport.isZoomed, let source = previewSource?.url else {
            waveformDetail = nil
            return
        }
        let range = timelineRange
        if let detail = waveformDetail, detail.range == range { return }
        waveformDetailTask = Task { [weak self, duration] in
            do {
                try await Task.sleep(for: .milliseconds(180))
                let waveform = try await AudioWaveform.generate(source: source, duration: duration, range: range)
                guard let self, !self.isStopped, !Task.isCancelled, self.timelineRange == range else { return }
                self.waveformDetail = (range, waveform)
            } catch {}
        }
    }

    func timecode(_ time: Double, rounding: FloatingPointRoundingRule = .toNearestOrAwayFromZero) -> String {
        if isAudioOnly { return AudioTimecode.format(time, rounding: rounding) }
        return FrameTimecode.format(time, frameDuration: frameDuration, rounding: rounding)
    }

    var timecodeHelp: String {
        if isAudioOnly { return "Hours:minutes:seconds.milliseconds · HH:MM:SS.mmm" }
        let rate = 1 / frameDuration
        let fractional = abs(rate - rate.rounded()) > 0.0001
        return "Hours:minutes:seconds:frames · \(String(format: "%g", rate)) fps" + (fractional ? " · non-drop-frame" : "")
    }

    var parsedSelection: MediaTrimSelection? {
        guard let start = parsedTimecode(startText), let end = parsedTimecode(endText) else { return nil }
        let value = MediaTrimSelection(
            start: startText == timecode(selection.start) ? selection.start : start,
            end: endText == timecode(selection.end) ? selection.end : end
        )
        guard let range = try? value.validated(for: duration) else { return nil }
        return MediaTrimSelection(start: range.start.seconds, end: range.end.seconds)
    }

    private func parsedTimecode(_ value: String) -> Double? {
        isAudioOnly ? AudioTimecode.parse(value) : FrameTimecode.parse(value, frameDuration: frameDuration)
    }

    var keptSelections: [MediaTrimSelection]? {
        guard let parsedSelection else { return nil }
        return try? MediaTrimPlan.keptSelections(in: parsedSelection, removing: cuts, duration: duration)
    }

    var outputDuration: Double { keptSelections?.reduce(0) { $0 + $1.duration } ?? 0 }
    var canSave: Bool { !isStopped && !isSaving && !isCapturingFrame && cutStart == nil && keptSelections != nil }
    var canCaptureFrame: Bool { !isStopped && !isSaving && !isCapturingFrame && !isAudioOnly && duration > 0 }
    var requiresCutEncoding: Bool { !isAudioOnly && !cuts.isEmpty }
    var canSaveLossless: Bool { canSave && !requiresCutEncoding }

    var pendingCut: MediaTrimSelection? {
        guard let cutStart else { return nil }
        return MediaTrimPlan.inclusiveCut(from: cutStart, through: position, within: selection, frameDuration: frameDuration)
    }

    func toggleCut() {
        guard !isStopped, !isSaving, duration > 0, commitFields() else { return }
        let previous = editState
        defer { recordEdit(previous, name: "Mark cut") }
        let time = min(selection.end, max(selection.start, floor(playheadTime / frameDuration + 0.000_000_1) * frameDuration))
        cancelPendingScrubbing()
        pausePlayback()
        if let cutStart {
            guard let cut = MediaTrimPlan.inclusiveCut(from: cutStart, through: time, within: selection,
                                                       frameDuration: frameDuration) else { return }
            cuts.append(cut)
            cuts.sort { $0.start < $1.start }
            self.cutStart = nil
            validateCuts()
        } else {
            selectedCutIndex = nil
            cutStart = time
            errorMessage = nil
        }
    }

    func cancelCut() {
        guard !isStopped, !isSaving else { return }
        let previous = editState
        defer { recordEdit(previous, name: "Cancel cut") }
        cutStart = nil
        validateCuts()
    }

    func removeCut(at index: Int) {
        guard !isStopped, !isSaving, cuts.indices.contains(index) else { return }
        let previous = editState
        defer { recordEdit(previous, name: "Remove cut") }
        cuts.remove(at: index)
        if let selected = selectedCutIndex {
            if selected == index { selectedCutIndex = nil }
            else if selected > index { selectedCutIndex = selected - 1 }
        }
        validateCuts()
    }

    func selectCut(at index: Int?) {
        guard !isStopped, !isSaving, selectedCutIndex != index else { return }
        if let index, !cuts.indices.contains(index) { return }
        selectedCutIndex = index
    }

    @discardableResult
    func removeSelectedCut() -> Bool {
        guard !isStopped, !isSaving else { return false }
        if cutStart != nil { cancelCut(); return true }
        guard let selectedCutIndex else { return false }
        removeCut(at: selectedCutIndex)
        return true
    }

    func removeAllCuts() {
        guard !isStopped, !isSaving else { return }
        let previous = editState
        defer { recordEdit(previous, name: "Remove cuts") }
        cuts.removeAll()
        cutStart = nil
        selectedCutIndex = nil
        validateCuts()
    }

    private func validateCuts() {
        errorMessage = !cuts.isEmpty && keptSelections == nil ? MediaTrimError.emptySelection.localizedDescription : nil
        if isPlaybackRequested { resumePlayback() }
    }

    func load() async {
        do {
            let prepared = try await MediaTrimPreviewSource.prepare(source: source)
            guard !isStopped, !Task.isCancelled else { prepared.removeTemporaryFiles(); return }
            previewSource = prepared
            let asset = AVURLAsset(url: prepared.url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
            let duration = try await asset.load(.duration).seconds
            let tracks = try await asset.loadTracks(withMediaType: .video)
            let audioTracks = try await asset.loadTracks(withMediaType: .audio)
            guard duration.isFinite, duration > 0, duration <= FrameTimecode.maximumTime,
                  !tracks.isEmpty || !audioTracks.isEmpty else { throw MediaTrimError.noMedia }
            isAudioOnly = tracks.isEmpty
            if let track = tracks.first {
                frameDuration = await MediaTrimTiming.frameDuration(asset: asset, track: track)
            } else { frameDuration = 0.001 }
            try Task.checkCancellation()
            guard !isStopped else { return }
            self.duration = duration
            selection = MediaTrimSelection(start: 0, end: duration)
            syncFields()
            let item = AVPlayerItem(asset: asset)
            item.allowedAudioSpatializationFormats = []
            player.replaceCurrentItem(with: item)
            playbackEndObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.updatePlaybackPosition(self.player.currentTime().seconds)
                }
            }
            itemObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
                let status = item.status
                let error = item.error?.localizedDescription
                Task { @MainActor [weak self] in
                    guard let self, !self.isStopped else { return }
                    self.seeker.isReady = status == .readyToPlay
                    if self.isAudioOnly, status == .readyToPlay { self.isPreparingPreview = false }
                    if status == .failed {
                        self.isPreparingPreview = false
                        self.errorMessage = error ?? MediaTrimError.previewUnavailable.localizedDescription
                    }
                }
            }
            observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.05, preferredTimescale: 600), queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.updatePlaybackPosition(self.player.currentTime().seconds)
                }
            }
            startWaveform(source: prepared.url)
        } catch is CancellationError {} catch {
            guard !isStopped else { return }
            waveform = .unavailable
            isPreparingPreview = false
            errorMessage = error.localizedDescription
        }
    }

    private func startWaveform(source: URL) {
        waveformTask = Task { [weak self, duration] in
            do {
                let result = try await AudioWaveform.generate(source: source, duration: duration)
                guard let self, !self.isStopped, !Task.isCancelled else { return }
                self.waveform = result
            } catch is CancellationError {} catch {
                guard let self, !self.isStopped else { return }
                self.waveform = .unavailable
            }
        }
    }

    func previewDisplayed() { if !isStopped { isPreparingPreview = false } }

    func beginScrubbing() {
        cancelPendingScrubbing()
        guard !isScrubbing else { return }
        isScrubbing = true
        pausePlayback()
        releasePlaybackRange()
    }

    private func releasePlaybackRange() {
        guard appliedPlaybackRange != nil else { return }
        player.currentItem?.reversePlaybackEndTime = .zero
        player.currentItem?.forwardPlaybackEndTime = .invalid
        appliedPlaybackRange = nil
    }

    func endScrubbing(withinSelection: Bool = true) {
        let wasDraggingHandle = handleDrag != nil
        if let drag = handleDrag, duration > 0 {
            let boundary = (drag.isStart ? selection.start : selection.end) / duration
            let offset = boundary - min(timelineViewport.end, max(timelineViewport.start, boundary))
            if offset != 0 {
                timelineViewport.pan(offset / timelineViewport.length)
                requestWaveformDetail()
            }
        }
        wheelFinishTask?.cancel()
        wheelFinishTask = nil
        isWheelScrolling = false
        wheelMotion = MediaTrimWheelMotion()
        cancelHandleDragging()
        guard isScrubbing else { return }
        isScrubbing = false
        seek(position, withinSelection: withinSelection, revealInTimeline: !wasDraggingHandle)
    }

    private func cancelPendingScrubbing() {
        if handleDrag != nil { isScrubbing = false }
        cancelHandleDragging()
        wheelFinishTask?.cancel()
        wheelFinishTask = nil
        if isWheelScrolling { isScrubbing = false }
        isWheelScrolling = false
        wheelMotion = MediaTrimWheelMotion()
    }

    func dragHandle(start: Bool, location: Double, width: Double) {
        guard !isStopped, !isSaving, duration > 0, location.isFinite, width.isFinite, width > 0 else { return }
        if handleDrag?.isStart != start {
            beginScrubbing()
            handleEditStart = editState
            handleDrag = MediaTrimHandleDrag(isStart: start, location: location, width: width)
            handleDragTask = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .milliseconds(33)) } catch { return }
                    guard let self, !self.isStopped, !self.isSaving else { return }
                    self.advanceHandleDrag()
                }
            }
        }
        handleDrag?.location = location
        handleDrag?.width = width
        applyHandleDrag()
    }

    func advanceHandleDrag() {
        guard let drag = handleDrag, isScrubbing, timelineViewport.isZoomed else { return }
        let delta = drag.panPerTick
        guard delta != 0 else { return }
        let lastStart = max(0, ceil(selection.end / frameDuration - 0.000_000_1) - 1) * frameDuration
        let firstEnd = min(duration, (floor(selection.start / frameDuration + 0.000_000_1) + 1) * frameDuration)
        if drag.isStart && delta > 0 && selection.start >= lastStart { return }
        if !drag.isStart && delta < 0 && selection.end <= firstEnd { return }
        let previous = timelineViewport
        timelineViewport.pan(delta)
        if timelineViewport != previous {
            applyHandleDrag()
            requestWaveformDetail()
        }
    }

    private func applyHandleDrag() {
        guard let drag = handleDrag else { return }
        let range = timelineRange
        let time = range.start + drag.fraction * range.duration
        if drag.isStart { setStart(time) }
        else { setEnd(time) }
    }

    func isDraggingHandle(start: Bool) -> Bool { handleDrag?.isStart == start }

    func finishHandleDrag(start: Bool, location: Double, width: Double) {
        guard isDraggingHandle(start: start) else { return }
        dragHandle(start: start, location: location, width: width)
        endScrubbing()
    }

    private func cancelHandleDragging() {
        handleDragTask?.cancel()
        handleDragTask = nil
        handleDrag = nil
        if let previous = handleEditStart {
            handleEditStart = nil
            recordEdit(previous, name: "Move trim point")
        }
    }

    func setStart(_ value: Double) {
        guard !isStopped, !isSaving, duration > 0, value.isFinite else { return }
        let previous = editState
        defer { recordEdit(previous, name: "Set start point") }
        let time = (value / frameDuration).rounded() * frameDuration
        let lastStart = max(0, ceil(selection.end / frameDuration - 0.000_000_1) - 1) * frameDuration
        selection.start = min(max(0, time), lastStart)
        changedSelection(preview: selection.start)
    }

    func setEnd(_ value: Double) {
        guard !isStopped, !isSaving, duration > 0, value.isFinite else { return }
        let previous = editState
        defer { recordEdit(previous, name: "Set end point") }
        let time = (value / frameDuration).rounded() * frameDuration
        let firstEnd = (floor(selection.start / frameDuration + 0.000_000_1) + 1) * frameDuration
        selection.end = max(min(duration, time), min(duration, firstEnd))
        changedSelection(preview: selection.end)
    }

    @discardableResult
    func commitFields(previewEnd: Bool = false) -> Bool {
        guard let parsedSelection else { errorMessage = MediaTrimError.invalidRange.localizedDescription; return false }
        guard selection != parsedSelection else { syncFields(); validateCuts(); return true }
        let previous = editState
        defer { recordEdit(previous, name: "Change trim times") }
        selection = parsedSelection
        changedSelection(preview: previewEnd ? selection.end : selection.start)
        return true
    }

    func reset() {
        guard !isStopped, !isSaving, duration > 0 else { return }
        cancelPendingScrubbing()
        let previous = editState
        defer { recordEdit(previous, name: "Reset edits") }
        cuts.removeAll()
        cutStart = nil
        selectedCutIndex = nil
        timelineViewport = MediaTrimTimelineViewport()
        requestWaveformDetail()
        selection = MediaTrimSelection(start: 0, end: duration)
        changedSelection(preview: 0)
    }

    private func changedSelection(preview: Double) {
        if isWheelScrolling { cancelPendingScrubbing() }
        pausePlayback()
        syncFields()
        validateCuts()
        if !isScrubbing { releasePlaybackRange() }
        seek(preview, precise: !isScrubbing)
    }

    private func syncFields() {
        startText = timecode(selection.start)
        endText = timecode(selection.end)
    }

    private var playbackRanges: [MediaTrimSelection] {
        (try? MediaTrimPlan.keptSelections(in: selection, removing: cuts, duration: duration)) ?? []
    }

    private func resumePlayback() {
        guard let range = MediaTrimPlayback.range(atOrAfter: position, in: playbackRanges) else { pausePlayback(); return }
        if position < range.start {
            player.pause()
            isPlaying = false
            playAfterSeeking = true
            releasePlaybackRange()
            seek(range.start)
            return
        }
        if appliedPlaybackRange != range {
            player.currentItem?.reversePlaybackEndTime = CMTime(seconds: range.start, preferredTimescale: 600_000)

            let end = range.end - min(1.0 / 600_000, range.duration / 2)
            player.currentItem?.forwardPlaybackEndTime = CMTime(seconds: end, preferredTimescale: 600_000)
            appliedPlaybackRange = range
        }
        player.playImmediately(atRate: playbackSpeed)
        isPlaying = true
    }

    func updatePlaybackPosition(_ time: Double) {
        guard !isStopped, time.isFinite, !isScrubbing, !seeker.isSeeking else { return }
        if isPlaybackRequested, let range = appliedPlaybackRange, time < range.start { return }
        if isPlaybackRequested, let range = appliedPlaybackRange, time >= range.end - 2.0 / 600_000 {
            player.pause()
            isPlaying = false
            let next = MediaTrimPlayback.range(atOrAfter: range.end, in: playbackRanges)
            if let next {
                playAfterSeeking = true
                releasePlaybackRange()
                seek(next.start)
            } else {
                position = range.end
                pausePlayback()
                revealPlayhead()
            }
            return
        }
        position = min(duration, max(0, time))
        isPlaying = player.rate != 0
        if isPlaybackRequested { revealPlayhead() }
    }

    func seek(_ value: Double, precise: Bool = true, withinSelection: Bool = true, revealInTimeline: Bool = true) {
        guard value.isFinite, !isStopped else { return }

        let lowerBound = withinSelection ? selection.start : 0
        let upperBound = withinSelection ? selection.end : duration
        let lastIncludedTime = max(lowerBound, upperBound - min(1.0 / 600_000, (upperBound - lowerBound) / 2))
        let time = min(max(lowerBound, value), lastIncludedTime)
        position = time
        if revealInTimeline { revealPlayhead() }
        seeker.seek(to: time, precise: precise)
    }

    private var playheadTime: Double {
        let time = player.currentTime().seconds
        return player.rate != 0 && !seeker.isSeeking && time.isFinite ? time : position
    }

    @discardableResult
    func stepFrame(_ direction: Int) -> Bool {
        guard !isStopped, !isSaving,
              let time = MediaTrimTiming.step(from: playheadTime, direction: direction, duration: duration, frameDuration: frameDuration) else { return false }
        cancelPendingScrubbing()
        pausePlayback()
        releasePlaybackRange()
        seek(time, withinSelection: false)
        return true
    }

    @discardableResult
    func scrollWheel(delta: Double, precise: Bool, timestamp: Double) -> Bool {
        guard !isStopped, !isSaving, duration > 0 else { return false }
        let frames = wheelMotion.frames(delta: delta, precise: precise, timestamp: timestamp)
        guard frames != 0,
              let time = MediaTrimTiming.step(from: playheadTime, direction: frames, duration: duration, frameDuration: frameDuration) else { return true }
        if !isWheelScrolling {

            let motion = wheelMotion
            beginScrubbing()
            wheelMotion = motion
            isWheelScrolling = true
        }
        seek(time, precise: false)
        wheelFinishTask?.cancel()
        wheelFinishTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(160)) } catch { return }
            guard let self, !self.isStopped else { return }
            self.endScrubbing()
        }
        return true
    }

    @discardableResult
    func markBoundaryAtPlayhead(start: Bool) -> Bool {
        guard !isStopped, !isSaving, duration > 0 else { return false }
        let time = floor(playheadTime / frameDuration + 0.000_000_1) * frameDuration
        if start {
            if time >= selection.end { selection.end = duration }
            setStart(time)
        } else {
            if time <= selection.start { selection.start = 0 }
            setEnd(time)
        }
        return true
    }

    @discardableResult
    func performTrimAction(_ action: AppKeybinding) -> Bool {
        guard !isStopped, !isSaving, duration > 0 else { return false }
        switch action {
        case .trimIn: return markBoundaryAtPlayhead(start: true)
        case .trimOut: return markBoundaryAtPlayhead(start: false)
        case .trimCut: toggleCut()
        case .trimReset: reset()
        case .trimPreviousEditPoint: jumpToEditPoint(forward: false)
        case .trimNextEditPoint: jumpToEditPoint(forward: true)
        case .trimPlayback: togglePlayback()
        case .captureFrame:
            guard canCaptureFrame else { return false }
            let destination = FrameCaptureDestination(rawValue: UserDefaults.standard.string(forKey: FrameCaptureDestination.preferenceKey) ?? "")
                ?? .defaultDestination
            captureFrame(to: destination)
        default: return false
        }
        return true
    }

    func jumpToEditPoint(forward: Bool) {
        guard !isStopped, !isSaving, duration > 0, commitFields(),
              let time = MediaTrimTiming.editPoint(from: playheadTime, forward: forward, selection: selection,
                                                       cuts: cuts, frameDuration: frameDuration) else { return }
        cancelPendingScrubbing()
        pausePlayback()
        releasePlaybackRange()
        seek(time)
    }

    private func pausePlayback() {
        player.pause()
        isPlaying = false
        isPlaybackRequested = false
        playAfterSeeking = false
    }

    func togglePlayback() {
        guard !isStopped, !isSaving, duration > 0 else { return }
        if isPlaybackRequested || player.rate != 0 || playAfterSeeking {
            pausePlayback()
            return
        }
        guard commitFields() else { return }
        endScrubbing()
        guard let first = playbackRanges.first else { errorMessage = MediaTrimError.emptySelection.localizedDescription; return }
        isPlaybackRequested = true
        if position < first.start || MediaTrimPlayback.range(atOrAfter: position, in: playbackRanges) == nil {
            releasePlaybackRange()
            seek(first.start)
        }
        if seeker.isSeeking { playAfterSeeking = true }
        else { resumePlayback() }
    }

    func cyclePlaybackSpeed() {
        guard !isStopped, !isSaving, duration > 0 else { return }
        switch playbackSpeed {
        case 1: playbackSpeed = 2
        case 2: playbackSpeed = 3
        case 3: playbackSpeed = 0.25
        case 0.25: playbackSpeed = 0.5
        default: playbackSpeed = 1
        }
        if isPlaybackRequested, player.rate != 0, !seeker.isSeeking, !playAfterSeeking {
            resumePlayback()
        }
    }

    var playbackSpeedLabel: String { String(format: "%g×", playbackSpeed) }

    func captureFrame(to destination: FrameCaptureDestination, pasteboard: NSPasteboard? = nil) {
        guard canCaptureFrame else { return }
        var time = playheadTime
        if let range = appliedPlaybackRange, player.rate == 0, time >= range.end {
            time = range.end - min(1.0 / 600_000, range.duration / 2)
        }
        let lastFrame = max(0, ceil(duration / frameDuration - 0.000_000_1) - 1)
        time = min(lastFrame, max(0, floor(time / frameDuration + 0.000_000_1))) * frameDuration
        let interval = frameDuration
        let folder = DownloadFolderPicker.folder(for: UserDefaults.standard.string(forKey: "downloadFolder") ?? "")
        isCapturingFrame = true
        if let previous = lastFrameCaptureError, errorMessage == previous { errorMessage = nil }
        lastFrameCaptureError = nil
        frameCaptureMessageTask?.cancel()
        frameCaptureMessage = nil
        frameCaptureTask = Task { [weak self, source, time] in
            do {
                let data = try await MediaFrameCapture.imageData(source: source, time: time)
                guard let self, !self.isStopped, !Task.isCancelled else { return }
                switch destination {
                case .clipboard:
                    guard let image = NSImage(data: data), let tiff = image.tiffRepresentation else {
                        throw MediaFrameCapture.CaptureError.invalidImage
                    }
                    let item = NSPasteboardItem()
                    item.setData(data, forType: .png)
                    item.setData(tiff, forType: .tiff)
                    let pasteboard = pasteboard ?? .general
                    pasteboard.clearContents()
                    guard pasteboard.writeObjects([item]) else { throw MediaFrameCapture.CaptureError.clipboardUnavailable }
                case .videoFolder:
                    _ = try await MediaFrameCapture.saveImage(data, source: source, folder: folder, time: time, frameDuration: interval)
                }
                guard !self.isStopped, !Task.isCancelled else { return }
                self.frameCaptureMessage = destination == .clipboard ? "Frame copied" : "Frame saved"
                self.frameCaptureMessageTask = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(3)) } catch { return }
                    self?.frameCaptureMessage = nil
                }
            } catch is CancellationError {} catch {
                if let self, !self.isStopped {
                    self.lastFrameCaptureError = error.localizedDescription
                    self.errorMessage = error.localizedDescription
                }
            }
            self?.isCapturingFrame = false
            self?.frameCaptureTask = nil
        }
    }

    func save(encoding: EncodingConfiguration? = nil, completion: @escaping (URL) -> Void) {
        guard !isStopped, !isSaving, !isCapturingFrame, commitFields() else { return }
        guard cutStart == nil else { errorMessage = MediaTrimError.unfinishedCut.localizedDescription; return }
        guard keptSelections != nil else { errorMessage = MediaTrimError.emptySelection.localizedDescription; return }
        guard encoding != nil || !requiresCutEncoding else { errorMessage = MediaTrimError.cutsRequireEncoding.localizedDescription; return }
        cancelPendingScrubbing()
        pausePlayback()
        isEncoding = encoding != nil
        encodingProgress = 0
        isSaving = true
        let selection = selection
        let cuts = cuts
        saveTask = Task { [weak self, source] in
            do {
                let output = try await MediaTrimmer.export(source: source, selection: selection, cuts: cuts, encoding: encoding) { [weak self] progress in
                    await self?.updateEncodingProgress(progress)
                }
                guard let self, !self.isStopped, !Task.isCancelled else { return }
                self.isSaving = false
                self.saveTask = nil
                completion(output)
            } catch is CancellationError {
                self?.isSaving = false
                self?.saveTask = nil
            } catch {
                self?.isSaving = false
                self?.saveTask = nil
                self?.errorMessage = error.localizedDescription
            }
        }
    }

    func updateEncodingProgress(_ progress: Double) {
        guard !isStopped, isSaving, isEncoding, progress.isFinite else { return }
        encodingProgress = max(encodingProgress, min(1, max(0, progress)))
    }

    func stop() {
        playbackSpeed = 1
        isStopped = true
        cancelPendingScrubbing()
        seeker.stop()
        saveTask?.cancel()
        saveTask = nil
        frameCaptureTask?.cancel()
        frameCaptureTask = nil
        isCapturingFrame = false
        frameCaptureMessageTask?.cancel()
        frameCaptureMessageTask = nil
        waveformTask?.cancel()
        waveformTask = nil
        waveformDetailTask?.cancel()
        waveformDetailTask = nil
        if let playbackEndObserver { NotificationCenter.default.removeObserver(playbackEndObserver); self.playbackEndObserver = nil }
        pausePlayback()
        itemObservation = nil
        if let observer { player.removeTimeObserver(observer); self.observer = nil }
        player.replaceCurrentItem(with: nil)
        previewSource?.removeTemporaryFiles()
        previewSource = nil
    }
}

private struct VideoPreviewPlayer: NSViewRepresentable {
    let player: AVPlayer
    let onReady: () -> Void

    @MainActor final class Coordinator {
        var observation: NSKeyValueObservation?
        let onReady: () -> Void
        init(onReady: @escaping () -> Void) { self.onReady = onReady }
    }
    func makeCoordinator() -> Coordinator { Coordinator(onReady: onReady) }
    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .none
        view.videoGravity = .resizeAspect
        view.player = player
        context.coordinator.observation = view.observe(\.isReadyForDisplay, options: [.initial, .new]) { [weak coordinator = context.coordinator] _, change in
            guard change.newValue == true else { return }
            Task { @MainActor in coordinator?.onReady() }
        }
        return view
    }
    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }

    static func dismantleNSView(_ view: AVPlayerView, coordinator: Coordinator) {
        coordinator.observation = nil
        view.player = nil
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: AVPlayerView, context: Context) -> CGSize? {
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? 640
        let height = proposal.height.flatMap { $0.isFinite ? $0 : nil } ?? 210
        return CGSize(width: max(0, width), height: max(0, height))
    }
}

struct MediaTrimView: View {
    @ObservedObject var model: MediaTrimModel
    @AppStorage(FrameCaptureDestination.preferenceKey) private var frameCaptureDestination = FrameCaptureDestination.defaultDestination.rawValue
    @AppStorage(AppKeybinding.captureFrame.rawValue) private var captureFrameShortcut = AppKeybinding.captureFrame.defaultShortcut.storedValue
    @AppStorage(AppKeybinding.captureFrame.enabledStorageKey) private var captureFrameEnabled = true
    @AppStorage(AppKeybinding.trimPlayback.rawValue) private var trimPlaybackShortcut = AppKeybinding.trimPlayback.defaultShortcut.storedValue
    @AppStorage(AppKeybinding.trimPlayback.enabledStorageKey) private var trimPlaybackEnabled = true
    @AppStorage(AppKeybinding.trimCut.rawValue) private var trimCutShortcut = AppKeybinding.trimCut.defaultShortcut.storedValue
    @AppStorage(AppKeybinding.trimReset.rawValue) private var trimResetShortcut = AppKeybinding.trimReset.defaultShortcut.storedValue
    @AppStorage(AppKeybinding.trimPreviousEditPoint.rawValue) private var trimPreviousShortcut = AppKeybinding.trimPreviousEditPoint.defaultShortcut.storedValue
    @AppStorage(AppKeybinding.trimNextEditPoint.rawValue) private var trimNextShortcut = AppKeybinding.trimNextEditPoint.defaultShortcut.storedValue
    @AppStorage(AppKeybinding.trimCut.enabledStorageKey) private var trimCutEnabled = true
    @AppStorage(AppKeybinding.trimReset.enabledStorageKey) private var trimResetEnabled = true
    @AppStorage(AppKeybinding.trimPreviousEditPoint.enabledStorageKey) private var trimPreviousEnabled = true
    @AppStorage(AppKeybinding.trimNextEditPoint.enabledStorageKey) private var trimNextEnabled = true
    @AppStorage(AppKeybinding.trimIn.rawValue) private var trimInShortcut = AppKeybinding.trimIn.defaultShortcut.storedValue
    @AppStorage(AppKeybinding.trimOut.rawValue) private var trimOutShortcut = AppKeybinding.trimOut.defaultShortcut.storedValue
    @AppStorage(AppKeybinding.trimIn.enabledStorageKey) private var trimInEnabled = true
    @AppStorage(AppKeybinding.trimOut.enabledStorageKey) private var trimOutEnabled = true
    let mediaName: String
    let finish: (URL?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Edit output").font(.title.bold())
                Spacer()
                Text(mediaName).foregroundStyle(.secondary).lineLimit(1)
            }
            editorPreview

            HStack(spacing: 10) {
                HStack(spacing: 8) {
                    if !model.isAudioOnly {
                        trimButton("Playback speed", icon: .text(model.playbackSpeedLabel),
                                   hint: "Playback speed",
                                   action: model.cyclePlaybackSpeed)
                            .accessibilityValue(model.playbackSpeedLabel)
                    }
                    trimButton("Reset edits", icon: .system("arrow.counterclockwise"), hint: shortcutHint(.trimReset, "Reset edits"), action: model.reset)
                    trimButton("Previous edit point", icon: .system("backward.end"), hint: shortcutHint(.trimPreviousEditPoint, "Previous edit point")) { model.jumpToEditPoint(forward: false) }
                    trimButton("Set start at playhead", icon: .character("["), hint: shortcutHint(.trimIn, "Set start at playhead")) {
                        _ = model.markBoundaryAtPlayhead(start: true)
                    }
                    trimButton(model.isAudioOnly ? "Back 1 ms" : "Previous frame", icon: .character("<"), hint: model.isAudioOnly ? "Back 1 ms (←)" : "Previous frame (←)") { _ = model.stepFrame(-1) }
                        .buttonRepeatBehavior(.enabled)
                }
                .frame(maxWidth: .infinity, alignment: .trailing)

                Button(action: model.togglePlayback) {
                    Image(systemName: model.isPlaybackRequested ? "pause.fill" : "play.fill")
                        .font(.system(size: 22, weight: .semibold))
                        .frame(width: 48, height: 48)
                        .contentShape(Circle())
                }
                .buttonStyle(TrimPlaybackButtonStyle())
                .accessibilityLabel(model.isPlaybackRequested ? "Pause selection" : "Play selection")
                .accessibilityHint(shortcutHint(.trimPlayback, model.isPlaybackRequested ? "Pause" : "Play"))
                .hoverHint(shortcutHint(.trimPlayback, model.isPlaybackRequested ? "Pause" : "Play"),
                           isEnabled: model.duration > 0 && !model.isSaving)

                HStack(spacing: 8) {
                    trimButton(model.isAudioOnly ? "Forward 1 ms" : "Next frame", icon: .character(">"), hint: model.isAudioOnly ? "Forward 1 ms (→)" : "Next frame (→)", alignment: .topTrailing) { _ = model.stepFrame(1) }
                        .buttonRepeatBehavior(.enabled)
                    trimButton("Set end at playhead", icon: .character("]"), hint: shortcutHint(.trimOut, "Set end at playhead"), alignment: .topTrailing) {
                        _ = model.markBoundaryAtPlayhead(start: false)
                    }
                    trimButton("Next edit point", icon: .system("forward.end"), hint: shortcutHint(.trimNextEditPoint, "Next edit point"), alignment: .topTrailing) { model.jumpToEditPoint(forward: true) }
                    trimButton(model.cutStart == nil ? "Start cut at playhead" : "Finish cut at playhead",
                               icon: .system("scissors"), hint: shortcutHint(.trimCut, model.cutStart == nil ? "Start cut at playhead" : "Finish cut at playhead"), alignment: .topTrailing, action: model.toggleCut)
                        .foregroundStyle(model.cutStart == nil ? Color.primary : Color.red)
                        .contextMenu {
                            if model.cutStart != nil { Button("Cancel cut", action: model.cancelCut) }
                            if !model.cuts.isEmpty { Button("Remove all cuts", role: .destructive, action: model.removeAllCuts) }
                        }
                    if !model.isAudioOnly {
                        trimButton("Capture frame", icon: .system("camera"), hint: shortcutHint(.captureFrame, captureDestination.actionTitle), alignment: .topTrailing) {
                            model.captureFrame(to: captureDestination)
                        }
                        .contextMenu {
                            ForEach(FrameCaptureDestination.allCases, id: \.self) { destination in
                                Button(destination.actionTitle) { model.captureFrame(to: destination) }
                            }
                        }
                        .disabled(!model.canCaptureFrame)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .disabled(model.duration == 0 || model.isSaving)
            .zIndex(1)

            HStack(spacing: 32) {
                timeField("Start", text: $model.startText, previewEnd: false)
                timeField("End", text: $model.endText, previewEnd: true)
            }
            .frame(maxWidth: .infinity)
            .hoverHint(model.timecodeHelp, alignment: .topTrailing, below: true)
            .disabled(model.duration == 0 || model.isSaving)
            if let error = model.errorMessage {
                Text(error).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            Text(model.isAudioOnly
                 ? "Saving replaces this file and keeps its filename. Save trims and cuts without re-encoding. Boundaries may shift slightly. Use Encode and save for precise timing."
                 : "Saving without encoding is faster, but some media players may briefly show hidden frames outside the selection. Most platforms like Discord and YouTube will display the video as intended. Encode and save prevents this and makes the video more compatible with Apple devices, but is slower.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                if model.isSaving {
                    ProgressView().controlSize(.small)
                    Text(model.isEncoding ? "Encoding… (\(model.encodingPercentage)%)" : "Saving…")
                        .monospacedDigit().foregroundStyle(.secondary)
                } else if model.isCapturingFrame {
                    ProgressView().controlSize(.small)
                    Text("Capturing frame…").font(.caption).foregroundStyle(.secondary)
                } else if let message = model.frameCaptureMessage {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                } else if model.cutStart != nil {
                    Text("Select cut end").font(.caption).foregroundStyle(.red)
                } else if model.requiresCutEncoding {
                    Text("Cuts require encoding").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { finish(nil) }.keyboardShortcut(.cancelAction)
                Button("Encode and save") { model.save(encoding: EncodingConfiguration.load()) { finish($0) } }
                    .disabled(!model.canSave)
                Button("Save") { model.save { finish($0) } }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(!model.canSaveLossless)
                    .hoverHint(model.isAudioOnly ? "Save audio without re-encoding. Cut points may shift slightly." : "Remove all cuts to save without encoding.",
                               alignment: .topTrailing, isEnabled: !model.cuts.isEmpty && !model.isSaving)
            }
        }
        .padding(24)
        .frame(minWidth: 640, idealWidth: 760, minHeight: 660, idealHeight: 760)
        .task { await model.load() }
        .onDisappear { model.stop() }
    }

    private var captureDestination: FrameCaptureDestination {
        FrameCaptureDestination(rawValue: frameCaptureDestination) ?? .defaultDestination
    }

    @ViewBuilder private var editorPreview: some View {
        if model.isAudioOnly {
            VStack(spacing: 12) {
                playheadInformation
                GeometryReader { geometry in
                    TrimTimeline(model: model, height: max(64, geometry.size.height - 15))
                }
                .frame(minHeight: 140)
                .disabled(model.duration == 0 || model.isSaving)
            }
        } else {
            videoPreview
            TrimTimeline(model: model).disabled(model.duration == 0 || model.isSaving)
        }
    }

    private var playheadInformation: some View {
        HStack {
            Text(model.timecode(model.position, rounding: .down))
                .accessibilityLabel("Playhead: \(model.timecode(model.position, rounding: .down))")
            Spacer()
            Text("Length: \(model.timecode(model.outputDuration))")
        }
        .monospacedDigit().foregroundStyle(.secondary)
        .hoverHint(model.timecodeHelp, alignment: .topTrailing, below: true)
    }

    private var videoPreview: some View {
        GeometryReader { geometry in
            let width = max(1, min(geometry.size.width, (geometry.size.height - 24) * 16 / 9))
            VStack(spacing: 8) {
                VideoPreviewPlayer(player: model.player, onReady: model.previewDisplayed)
                    .frame(width: width, height: width * 9 / 16)
                    .background(.black, in: RoundedRectangle(cornerRadius: 8))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay { if model.isPreparingPreview && model.errorMessage == nil { ProgressView() } }
                playheadInformation
            }
            .frame(width: width)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func shortcutHint(_ binding: AppKeybinding, _ message: String) -> String {
        let preference: (String, Bool)
        switch binding {
        case .trimIn: preference = (trimInShortcut, trimInEnabled)
        case .trimOut: preference = (trimOutShortcut, trimOutEnabled)
        case .trimCut: preference = (trimCutShortcut, trimCutEnabled)
        case .trimReset: preference = (trimResetShortcut, trimResetEnabled)
        case .trimPreviousEditPoint: preference = (trimPreviousShortcut, trimPreviousEnabled)
        case .trimNextEditPoint: preference = (trimNextShortcut, trimNextEnabled)
        case .trimPlayback: preference = (trimPlaybackShortcut, trimPlaybackEnabled)
        case .captureFrame: preference = (captureFrameShortcut, captureFrameEnabled)
        default: return message
        }
        return binding.hint(message, storedValue: preference.0, enabled: preference.1)
    }

    private enum TrimButtonIcon {
        case system(String)
        case character(String)
        case text(String)
    }

    private func trimButton(_ title: String, icon: TrimButtonIcon, hint: String? = nil,
                            alignment: Alignment = .topLeading, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Group {
                switch icon {
                case .system(let name): Image(systemName: name).font(.system(size: 16, weight: .medium))
                case .character(let character): Text(character).font(.system(size: 17, weight: .medium, design: .monospaced))
                case .text(let text): Text(text).font(.system(size: 13, weight: .medium)).monospacedDigit().fixedSize()
                }
            }
            .frame(width: 20, height: 22)
        }
        .accessibilityLabel(title)
        .accessibilityHint(hint ?? title)
        .hoverHint(hint ?? title, alignment: alignment, isEnabled: model.duration > 0 && !model.isSaving)
    }

    private func timeField(_ label: String, text: Binding<String>, previewEnd: Bool) -> some View {
        let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        let width = (model.timecode(model.duration) as NSString).size(withAttributes: [.font: font]).width
        return HStack(spacing: 8) {
            if !previewEnd { Text(label).frame(width: 40, alignment: .trailing) }
            MediaTrimTimeField(value: text, label: label, isAudio: model.isAudioOnly) { model.commitFields(previewEnd: previewEnd) }
                .frame(width: ceil(width) + 14, height: 22)
            if previewEnd { Text(label).frame(width: 40, alignment: .leading) }
        }
    }
}

private struct TrimPlaybackButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white)
            .background(Color.accentColor.opacity(configuration.isPressed ? 0.75 : 1), in: Circle())
            .opacity(isEnabled ? 1 : 0.4)
    }
}

final class MediaTimecodeFormatter: Formatter, @unchecked Sendable {
    let isAudio: Bool

    init(isAudio: Bool = false) { self.isAudio = isAudio; super.init() }
    required init?(coder: NSCoder) { isAudio = false; super.init(coder: coder) }

    private func allowsEditing(_ value: String) -> Bool {
        if isAudio { return value.allSatisfy { $0.isASCII && ($0.isNumber || $0 == ":" || $0 == ".") } }
        return FrameTimecode.allowsEditing(value)
    }
    override func string(for obj: Any?) -> String? { obj as? String }

    override func getObjectValue(_ obj: AutoreleasingUnsafeMutablePointer<AnyObject?>?, for string: String,
                                 errorDescription error: AutoreleasingUnsafeMutablePointer<NSString?>?) -> Bool {
        guard allowsEditing(string) else { return false }
        obj?.pointee = string as NSString
        return true
    }

    override func isPartialStringValid(_ partialString: String, newEditingString newString: AutoreleasingUnsafeMutablePointer<NSString?>?,
                                      errorDescription error: AutoreleasingUnsafeMutablePointer<NSString?>?) -> Bool {
        allowsEditing(partialString)
    }
}

private struct MediaTrimTimeField: NSViewRepresentable {
    @Binding var value: String
    let label: String
    let isAudio: Bool
    let onCommit: () -> Bool

    func makeCoordinator() -> Coordinator { Coordinator(value: $value, onCommit: onCommit) }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: value)
        field.bezelStyle = .roundedBezel
        field.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        field.usesSingleLineMode = true
        field.formatter = MediaTimecodeFormatter(isAudio: isAudio)
        field.delegate = context.coordinator
        field.setAccessibilityLabel(label)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.value = $value
        context.coordinator.onCommit = onCommit
        if (field.formatter as? MediaTimecodeFormatter)?.isAudio != isAudio {
            field.formatter = MediaTimecodeFormatter(isAudio: isAudio)
        }
        if field.stringValue != value { field.stringValue = value }
        field.isEnabled = context.environment.isEnabled
    }

    static func dismantleNSView(_ field: NSTextField, coordinator: Coordinator) { field.delegate = nil }

    @MainActor final class Coordinator: NSObject, NSTextFieldDelegate {
        var value: Binding<String>
        var onCommit: () -> Bool
        init(value: Binding<String>, onCommit: @escaping () -> Bool) { self.value = value; self.onCommit = onCommit }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            value.wrappedValue = field.stringValue
        }

        func controlTextDidEndEditing(_ notification: Notification) { _ = onCommit() }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard commandSelector == #selector(NSResponder.insertNewline(_:)) else { return false }
            if onCommit() { control.window?.makeFirstResponder(nil) }
            return true
        }
    }
}

private struct TrimTimeline: View {
    @ObservedObject var model: MediaTrimModel
    var height: CGFloat = 64

    var body: some View {
        VStack(spacing: 3) {
            TrimTimelineCanvas(model: model)
                .frame(height: height)
                .background(TimelineScrollRegion())
            Group {
                if model.timelineViewport.isZoomed {
                    TimelineScroller(position: model.timelineViewport.start / (1 - model.timelineViewport.length),
                                     proportion: model.timelineViewport.length, onChange: model.panTimeline)
                } else {
                    Color.clear
                }
            }
            .frame(height: 12)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Selected media range")
        .accessibilityHint("Scroll to zoom. Shift-scroll or scroll horizontally to pan.")
    }
}

private struct TimelineScrollRegion: NSViewRepresentable {
    func makeNSView(context: Context) -> TimelineScrollRegionView { TimelineScrollRegionView() }
    func updateNSView(_ view: TimelineScrollRegionView, context: Context) {}
}

private final class TimelineScrollRegionView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private struct TimelineScroller: NSViewRepresentable {
    let position: Double
    let proportion: Double
    let onChange: (Double) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onChange: onChange) }
    func makeNSView(context: Context) -> NSScroller {
        let scroller = NSScroller(frame: NSRect(x: 0, y: 0, width: 200, height: 12))
        scroller.scrollerStyle = .legacy
        scroller.controlSize = .small
        scroller.target = context.coordinator
        scroller.action = #selector(Coordinator.scroll(_:))
        return scroller
    }
    func updateNSView(_ view: NSScroller, context: Context) {
        context.coordinator.onChange = onChange
        view.knobProportion = proportion
        view.doubleValue = position
        view.isEnabled = context.environment.isEnabled
    }
    @MainActor final class Coordinator: NSObject {
        var onChange: (Double) -> Void
        init(onChange: @escaping (Double) -> Void) { self.onChange = onChange }
        @objc func scroll(_ sender: NSScroller) {
            let page = sender.knobProportion / max(0.000_001, 1 - sender.knobProportion)
            let step: Double
            switch sender.hitPart {
            case .decrementPage: step = -page * 0.9
            case .incrementPage: step = page * 0.9
            case .decrementLine: step = -page * 0.1
            case .incrementLine: step = page * 0.1
            default: step = 0
            }
            onChange(min(1, max(0, sender.doubleValue + step)))
        }
    }
}

private struct TrimTimelineCanvas: View {
    @ObservedObject var model: MediaTrimModel

    var body: some View {
        GeometryReader { geometry in
            let width = max(1, geometry.size.width - 14)
            let window = model.timelineRange
            let start = x(model.selection.start, width: width, window: window)
            let end = x(model.selection.end, width: width, window: window)
            let waveform = model.visibleWaveform
            ZStack(alignment: .leading) {
                AudioWaveformView(waveform: waveform.waveform, range: waveform.range)
                    .padding(.horizontal, 7)
                    .background(.quaternary)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .contentShape(Rectangle())
                    .gesture(scrubbingGesture(width: width, window: window))
                ForEach(Array(model.cuts.enumerated()), id: \.offset) { entry in
                    cutArea(entry.element, width: width, window: window, selected: model.selectedCutIndex == entry.offset)
                        .gesture(scrubbingGesture(width: width, window: window, cutIndex: entry.offset))
                        .contextMenu { Button("Remove cut", role: .destructive) { model.removeCut(at: entry.offset) } }
                        .accessibilityLabel("Cut from \(model.timecode(entry.element.start)) to \(model.timecode(entry.element.end))")
                        .accessibilityAction(named: "Remove cut") { model.removeCut(at: entry.offset) }
                }
                if let pending = model.pendingCut {
                    cutArea(pending, width: width, window: window).allowsHitTesting(false)
                }
                if let cutStart = model.cutStart {
                    Rectangle().fill(.red).frame(width: 2).offset(x: x(cutStart, width: width, window: window)).allowsHitTesting(false)
                }
                Rectangle().fill(.black.opacity(0.6)).frame(width: min(geometry.size.width, max(0, start - 7))).allowsHitTesting(false)
                Rectangle().fill(.black.opacity(0.6)).frame(width: min(geometry.size.width, max(0, geometry.size.width - end - 7)))
                    .offset(x: max(0, end + 7)).allowsHitTesting(false)
                Path { path in
                    path.addRoundedRect(in: CGRect(x: start - 5.5, y: 1.5, width: max(11, end - start + 11),
                                                   height: max(0, geometry.size.height - 3)), cornerSize: CGSize(width: 4, height: 4))
                }
                .stroke(.yellow, lineWidth: 3).allowsHitTesting(false)
                Rectangle().fill(.white).frame(width: 2).offset(x: x(model.position, width: width, window: window))
                    .allowsHitTesting(false)
                if model.isDraggingHandle(start: true) || (start >= 0 && start <= geometry.size.width) {
                    handle(start: true).position(x: min(width + 7, max(7, start)), y: geometry.size.height / 2)
                        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("trim-timeline"))
                            .onChanged { model.dragHandle(start: true, location: $0.location.x - 7, width: width) }
                            .onEnded { model.finishHandleDrag(start: true, location: $0.location.x - 7, width: width) })
                }
                if model.isDraggingHandle(start: false) || (end >= 0 && end <= geometry.size.width) {
                    handle(start: false).position(x: min(width + 7, max(7, end)), y: geometry.size.height / 2)
                        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("trim-timeline"))
                            .onChanged { model.dragHandle(start: false, location: $0.location.x - 7, width: width) }
                            .onEnded { model.finishHandleDrag(start: false, location: $0.location.x - 7, width: width) })
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .leading)
            .coordinateSpace(name: "trim-timeline")
            .clipped()
        }
    }

    private func x(_ time: Double, width: Double, window: MediaTrimSelection) -> Double {
        7 + width * (time - window.start) / max(0.001, window.duration)
    }

    private func scrubbingGesture(width: Double, window: MediaTrimSelection, cutIndex: Int? = nil) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("trim-timeline"))
            .onChanged {
                model.selectCut(at: cutIndex)
                model.beginScrubbing()
                model.seek(window.start + ($0.location.x - 7) / width * window.duration, precise: false)
            }
            .onEnded { model.seek(window.start + ($0.location.x - 7) / width * window.duration, precise: false); model.endScrubbing() }
    }

    private func cutArea(_ cut: MediaTrimSelection, width: Double, window: MediaTrimSelection, selected: Bool = false) -> some View {
        let start = max(window.start, model.selection.start, cut.start)
        let end = min(window.end, model.selection.end, cut.end)
        return Rectangle().fill(.red.opacity(selected ? 0.55 : 0.4))
            .overlay { Rectangle().strokeBorder(.red, lineWidth: selected ? 2 : 1) }
            .frame(width: max(0, x(end, width: width, window: window) - x(start, width: width, window: window)))
            .offset(x: x(start, width: width, window: window))
    }

    private func handle(start: Bool) -> some View {
        RoundedRectangle(cornerRadius: 4).fill(.yellow).frame(width: 14)
            .overlay { Capsule().fill(.black.opacity(0.7)).frame(width: 2, height: 20) }
            .contentShape(Rectangle())
            .accessibilityLabel(start ? "Trim start" : "Trim end")
            .accessibilityValue(model.timecode(start ? model.selection.start : model.selection.end))
            .accessibilityAdjustableAction { direction in
                let step = direction == .increment ? model.frameDuration : -model.frameDuration
                if start { model.setStart(model.selection.start + step) }
                else { model.setEnd(model.selection.end + step) }
            }
    }
}

private struct AudioWaveformView: View {
    let waveform: AudioWaveform
    let range: ClosedRange<Double>

    var body: some View {
        Canvas { context, size in
            var path = Path()
            if case .ready(let samples) = waveform, !samples.isEmpty {
                let count = max(1, Int(size.width / 2))
                let maximum = max(0.000_001, samples.max() ?? 0)
                for index in 0..<count {
                    let lower = min(samples.count - 1, max(0, Int((range.lowerBound + Double(index) / Double(count) * (range.upperBound - range.lowerBound)) * Double(samples.count))))
                    let upper = min(samples.count, max(lower + 1, Int((range.lowerBound + Double(index + 1) / Double(count) * (range.upperBound - range.lowerBound)) * Double(samples.count))))
                    let peak = samples[lower..<upper].max() ?? 0
                    let height = max(1, (size.height - 10) * pow(Double(peak / maximum), 0.6))
                    path.addRect(CGRect(x: Double(index) * size.width / Double(count), y: (size.height - height) / 2,
                                        width: max(1, size.width / Double(count) - 1), height: height))
                }
            } else {
                path.addRect(CGRect(x: 0, y: size.height / 2, width: size.width, height: 1))
            }
            context.fill(path, with: .color(.primary.opacity(0.65)))
        }
        .background(.quaternary)
        .overlay {
            if let message {
                Text(message).font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 8).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 4))
                    .allowsHitTesting(false)
            }
        }
    }

    private var message: String? {
        switch waveform {
        case .loading: "Generating waveform…"
        case .noAudio: "No audio track"
        case .unavailable: "Audio waveform unavailable"
        case .ready: nil
        }
    }
}

@MainActor
final class MediaTrimInputWindow: EditingWindow {
    weak var trimModel: MediaTrimModel?
    var shortcutDefaults: UserDefaults = .standard

    override var undoManager: UndoManager? {
        if trimModel?.isSaving == true { return nil }
        contentUndoManager = trimModel?.undoManager
        return super.undoManager
    }

    override func sendEvent(_ event: NSEvent) {
        if [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(event.type), let contentView {
            if !containsTextInput(at: event.locationInWindow, in: contentView) { makeFirstResponder(nil) }
        }
        if attachedSheet == nil {
            let editingText = firstResponder is NSTextView || firstResponder is NSTextField
            let modifiers = event.modifierFlags.intersection([.command, .option, .control])
            if event.type == .keyDown, !editingText, let shortcut = AppShortcut(event: event),
               let action = AppKeybinding.trimActions.first(where: { $0.matches(shortcut, defaults: shortcutDefaults) }),
               let trimModel {
                if !event.isARepeat { _ = trimModel.performTrimAction(action) }
                return
            }
            if event.type == .keyDown, !editingText, modifiers.isEmpty {
                if event.keyCode == 123, trimModel?.stepFrame(-1) == true { return }
                if event.keyCode == 124, trimModel?.stepFrame(1) == true { return }
                if [51, 117].contains(event.keyCode), trimModel?.removeSelectedCut() == true { return }
            }
            if event.type == .scrollWheel, modifiers.isEmpty, let contentView,
               let region = timelineRegion(at: event.locationInWindow, in: contentView) {
                if event.momentumPhase.isEmpty {
                    let point = region.convert(event.locationInWindow, from: nil)
                    _ = trimModel?.scrollTimeline(delta: event.scrollingDeltaY, horizontal: event.scrollingDeltaX,
                        precise: event.hasPreciseScrollingDeltas, pan: event.modifierFlags.contains(.shift),
                        anchor: (point.x - 7) / max(1, region.bounds.width - 14))
                }
                return
            }
            if event.type == .scrollWheel, modifiers.isEmpty, event.scrollingDeltaY != 0,
               event.momentumPhase.isEmpty,
               trimModel?.scrollWheel(delta: event.scrollingDeltaY, precise: event.hasPreciseScrollingDeltas, timestamp: event.timestamp) == true { return }
        }
        super.sendEvent(event)
    }

    private func timelineRegion(at point: NSPoint, in view: NSView) -> TimelineScrollRegionView? {
        guard !view.isHidden, view.alphaValue > 0 else { return nil }
        if let region = view as? TimelineScrollRegionView, region.bounds.contains(region.convert(point, from: nil)) { return region }
        return view.subviews.lazy.compactMap { self.timelineRegion(at: point, in: $0) }.first
    }

    private func containsTextInput(at point: NSPoint, in view: NSView) -> Bool {
        guard !view.isHidden, view.alphaValue > 0 else { return false }

        if (view as? NSTextField)?.isEditable == true || (view as? NSTextView)?.isEditable == true,
           view.bounds.contains(view.convert(point, from: nil)) { return true }
        return view.subviews.contains { containsTextInput(at: point, in: $0) }
    }
}

@MainActor
final class MediaTrimWindow: NSObject, NSWindowDelegate {
    private static weak var current: MediaTrimWindow?
    private var window: NSWindow?
    private var model: MediaTrimModel?
    private var continuation: CheckedContinuation<URL?, Never>?

    static func present(source: URL, mediaName: String) async -> URL? {
        let presenter = MediaTrimWindow()
        return await presenter.run(source: source, mediaName: mediaName)
    }

    static func focusCurrent() {
        current?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    static var quitWarning: String? {
        guard let model = current?.model else { return nil }
        if model.isSaving { return "Saving in the editor will be cancelled." }
        return model.hasUnsavedChanges ? "Unsaved changes in the editor will be discarded." : nil
    }

    private func run(source: URL, mediaName: String) async -> URL? {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                guard !Task.isCancelled else { finish(nil); return }
                let model = MediaTrimModel(source: source)
                self.model = model
                let content = MediaTrimView(model: model, mediaName: mediaName) { [weak self] output in
                    if let output { self?.finish(output) }
                    else { self?.requestClose() }
                }
                let window = MediaTrimInputWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 760),
                                      styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
                window.trimModel = model
                window.title = "Edit output"
                window.titleVisibility = .hidden
                window.isReleasedWhenClosed = false
                window.appearance = NSApp.appearance
                window.contentMinSize = NSSize(width: 640, height: 660)
                window.contentViewController = NSHostingController(rootView: content)
                window.setContentSize(NSSize(width: 760, height: 760))
                window.delegate = self
                window.center()
                self.window = window
                Self.current = self
                window.makeKeyAndOrderFront(nil)
                window.makeFirstResponder(nil)
                NSApp.activate(ignoringOtherApps: true)
            }
        } onCancel: {
            Task { @MainActor in self.finish(nil) }
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool { requestClose(); return false }

    private func requestClose() {
        guard continuation != nil, let window, let model, window.attachedSheet == nil else { return }
        guard model.hasUnsavedChanges || model.isSaving else { finish(nil); return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = model.isSaving ? "Cancel saving and close editor?" : "Discard changes and close editor?"
        alert.informativeText = model.isSaving
            ? "Saving will be cancelled. Any unsaved changes will be discarded."
            : "Your unsaved trim and cut changes will be discarded. The file will remain unchanged."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: model.isSaving ? "Cancel Saving and Close" : "Discard Changes")
            .hasDestructiveAction = true
        alert.beginSheetModal(for: window) { [weak self] response in
            if response == .alertSecondButtonReturn { self?.finish(nil) }
        }
    }

    private func finish(_ output: URL?) {
        guard let continuation else { return }
        self.continuation = nil
        if Self.current === self { Self.current = nil }
        model?.stop()
        if let window, let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .abort) }
        window?.delegate = nil
        window?.contentViewController = nil
        window?.close()
        window = nil
        model = nil
        continuation.resume(returning: output)
    }
}
