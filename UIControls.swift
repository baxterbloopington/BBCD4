import AppKit
import SwiftUI

@MainActor
enum DownloadFolderPicker {
    static func folder(for path: String) -> URL {
        path.isEmpty
            ? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
            : URL(fileURLWithPath: path)
    }

    static func choose(currentPath: String) -> String? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = folder(for: currentPath)
        guard panel.runModal() == .OK else { return nil }
        return panel.url?.path
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

                let work = DispatchWorkItem { isVisible = true }
                pendingWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
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
            .zIndex(isVisible ? 1 : 0)
            .onDisappear { pendingWork?.cancel() }
    }
}

extension View {
    func hoverHint(
        _ message: String,
        alignment: Alignment = .topLeading,
        below: Bool = false,
        isEnabled: Bool = true
    ) -> some View {
        modifier(DelayedHoverHint(message: message, alignment: alignment, below: below, isEnabled: isEnabled))
    }
}

struct ScrollStepAccumulator {
    private var accumulated = 0.0
    private var lastTimestamp: TimeInterval?

    mutating func consume(delta: Double, precise: Bool, timestamp: TimeInterval, momentum: Bool = false) -> Int {
        guard !momentum, delta.isFinite, delta != 0, timestamp.isFinite else { return 0 }
        if !precise {
            accumulated = 0
            lastTimestamp = timestamp
            return delta > 0 ? 1 : -1
        }
        if lastTimestamp.map({ timestamp < $0 || timestamp - $0 > 0.25 }) ?? true
            || (accumulated != 0 && accumulated.sign != delta.sign) {
            accumulated = 0
        }
        lastTimestamp = timestamp
        accumulated += delta
        guard abs(accumulated) >= 10 else { return 0 }
        accumulated.formTruncatingRemainder(dividingBy: 10)
        return delta > 0 ? 1 : -1
    }
}

struct ScrollStepControl<Content: View>: NSViewRepresentable {
    let onStep: (Int) -> Void
    let content: Content

    init(onStep: @escaping (Int) -> Void, @ViewBuilder content: () -> Content) {
        self.onStep = onStep
        self.content = content()
    }

    func makeNSView(context: Context) -> ScrollStepHostingView<AnyView> {
        let view = ScrollStepHostingView(rootView: hostedContent(context: context))
        view.sizingOptions = []
        return view
    }

    func updateNSView(_ view: ScrollStepHostingView<AnyView>, context: Context) {
        view.rootView = hostedContent(context: context)
        view.onStep = context.environment.isEnabled ? onStep : nil
    }

    private func hostedContent(context: Context) -> AnyView {
        AnyView(content
            .environment(\.isEnabled, context.environment.isEnabled)
            .environment(\.colorScheme, context.environment.colorScheme)
            .environment(\.controlSize, context.environment.controlSize)
            .environment(\.font, context.environment.font)
            .environment(\.layoutDirection, context.environment.layoutDirection))
    }
}

final class ScrollStepHostingView<Content: View>: NSHostingView<Content> {
    var onStep: ((Int) -> Void)?
    private var motion = ScrollStepAccumulator()

    override func scrollWheel(with event: NSEvent) {
        guard let onStep, event.scrollingDeltaY != 0 else { super.scrollWheel(with: event); return }
        let step = motion.consume(delta: event.scrollingDeltaY, precise: event.hasPreciseScrollingDeltas,
                                  timestamp: event.timestamp, momentum: !event.momentumPhase.isEmpty)
        if step != 0 { onStep(step) }
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
    static let mainWindowHeight: CGFloat = 500
    static let streamSelectorWidth = durationRowWidth
    static var dateTimeValueWidth: CGFloat { dateWidth - dateTimeAccessoryWidth }
    static var timeValueWidth: CGFloat { timeWidth - timeChevronHitWidth }
    static let durationWidth = (dateWidth + timeWidth - fieldGap) / 3
    static let durationRowWidth = durationWidth * 3 + fieldGap * 2
}

struct InAppNotificationMessage: View {
    let message: String

    var body: some View {
        Text(message)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(Color.primary.opacity(ControlMetrics.controlBorderOpacity), lineWidth: 1)
            }
    }
}

enum SettingsLayout {
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

extension View {
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

struct DownloadProgressTrack: View {
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
struct HoverGlassButtonStyle: ButtonStyle {
    let minimumHeight: CGFloat

    init(minimumHeight: CGFloat = ControlMetrics.height) {
        self.minimumHeight = minimumHeight
    }

    func makeBody(configuration: Configuration) -> some View {
        HoverGlassButton(configuration: configuration, minimumHeight: minimumHeight)
    }

}
struct HoverGlassIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverGlassIconButton(configuration: configuration)
    }
}
struct HoverPrimaryButtonStyle: ButtonStyle {
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
struct HoverUpdateButtonStyle: ButtonStyle {
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

private struct GlassButtonSurface: ViewModifier {
    let isPressed: Bool
    var disabledOpacity: Double? = nil
    @Environment(\.isEnabled) private var isEnabled

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: ControlMetrics.cornerRadius, style: .continuous)
        let pressedOpacity = isPressed ? 0.72 : 1.0
        content
            .background(.quaternary, in: shape)
            .sharedControlHover()
            .overlay { shape.stroke(Color.primary.opacity(ControlMetrics.controlBorderOpacity), lineWidth: 1) }
            .opacity(isEnabled ? pressedOpacity : disabledOpacity ?? pressedOpacity)
            .contentShape(shape)
    }
}

private struct HoverGlassButton: View {
    let configuration: ButtonStyle.Configuration
    let minimumHeight: CGFloat

    var body: some View {
        configuration.label
            .padding(.horizontal, 12)
            .frame(minHeight: minimumHeight)
            .modifier(GlassButtonSurface(isPressed: configuration.isPressed))
    }
}

private struct HoverGlassIconButton: View {
    let configuration: ButtonStyle.Configuration

    var body: some View {
        configuration.label
            .frame(maxWidth: .infinity, minHeight: ControlMetrics.height)
            .modifier(GlassButtonSurface(isPressed: configuration.isPressed, disabledOpacity: 0.2))
    }
}
struct StreamFilterButton: NSViewRepresentable {
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

final class StreamFilterControl: NSButton {
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

struct DurationControl: View {
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
        ScrollStepControl(onStep: { step in value = min(max(value + step, range.lowerBound), range.upperBound) }) {
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
        .frame(width: ControlMetrics.durationAccessoryWidth, height: ControlMetrics.height)
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

private struct RepeatButton: NSViewRepresentable {
    let image: String
    let action: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton()
        button.setButtonType(.momentaryPushIn)
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.title = ""
        button.refusesFirstResponder = true
        button.isContinuous = true
        button.setPeriodicDelay(0.175, interval: 0.04)
        (button.cell as? NSButtonCell)?.highlightsBy = []
        button.target = context.coordinator
        button.action = #selector(Coordinator.invoke)
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.action = action
        button.image = NSImage(systemSymbolName: image, accessibilityDescription: image == "chevron.up" ? "Increase" : "Decrease")?
            .withSymbolConfiguration(.init(pointSize: 16, weight: .medium))
        button.contentTintColor = .labelColor
        button.isEnabled = context.environment.isEnabled
    }

    @MainActor final class Coordinator: NSObject {
        var action: () -> Void
        init(action: @escaping () -> Void) { self.action = action }
        @objc func invoke() { action() }
    }
}

struct PersistentListScroller: NSViewRepresentable {
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

final class ScrollViewConfigurationView: NSView {
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

struct AutoHidingTextEditor: NSViewRepresentable {
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

final class AutoHidingTextScrollView: NSScrollView {
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

struct SettingsPopupMenu<Value: Hashable>: NSViewRepresentable {
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
final class SettingsPopupControl: NSControl {
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
