import AppKit
import SwiftUI

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
        table.rowHeight = 22
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
        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            rows.indices.contains(row) && rows[row].stream != nil ? 22 : 26
        }
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
        nameField.font = .systemFont(ofSize: row.stream == nil ? 14 : 12, weight: row.stream == nil ? .semibold : .regular)
        leadingInset.constant = row.stream?.groupID == nil ? 4 : showsStatus ? 22 : 25
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
            leading.setAccessibilityLabel(status?.state.title ?? StreamAvailabilityState.unknown.title)
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
            streamStore.selectedStreamID = StreamGrouping.firstStream(in: matchingStreams, groups: streamStore.groups)?.id
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
        shortcutEventMonitor = makeShortcutEventMonitor(
            isFocused: { isSecondaryWindowFocused(title: "Manage streams") },
            closesOnReturn: true,
            handle: handleStreamShortcut
        )
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
            guard let id,
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
        menu.addItem(StreamListMenuItem("Edit…", enabled: targets.count == 1) {
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
