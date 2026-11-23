import AppKit
import SwiftUI

@MainActor
class EditingWindow: NSWindow {
    var contentUndoManager: UndoManager?
    override var undoManager: UndoManager? {
        if firstResponder is NSTextView || firstResponder is NSTextField { return super.undoManager }
        return contentUndoManager ?? super.undoManager
    }

    @objc(undo:) func undoContent(_ sender: Any?) { undoManager?.undo() }
    @objc(redo:) func redoContent(_ sender: Any?) { undoManager?.redo() }

    override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(undoContent(_:)) {
            menuItem.title = undoManager?.undoMenuItemTitle ?? "Undo"
            return undoManager?.canUndo == true
        }
        if menuItem.action == #selector(redoContent(_:)) {
            menuItem.title = undoManager?.redoMenuItemTitle ?? "Redo"
            return undoManager?.canRedo == true
        }
        return super.validateMenuItem(menuItem)
    }
}

@MainActor
func closeSecondaryWindow() {
    guard let window = NSApp.keyWindow as? EditingWindow else { return }
    window.close()
}

@MainActor
func showSecondaryWindow(title: String, isPresented: Binding<Bool>) {
    if isPresented.wrappedValue {
        SecondaryWindowRegistry.shared.focus(title: title)
    } else {
        isPresented.wrappedValue = true
    }
}

@MainActor
func focusSecondaryWindow(title: String) {
    SecondaryWindowRegistry.shared.focus(title: title)
}

@MainActor
func focusSecondaryList(title: String) {
    SecondaryWindowRegistry.shared.focusList(title: title)
}

func isSecondaryWindowFocused(title: String) -> Bool {
    MainActor.assumeIsolated {
        SecondaryWindowRegistry.shared.isFocused(title: title)
    }
}

@MainActor
private final class SecondaryWindowRegistry {
    static let shared = SecondaryWindowRegistry()
    private var windows: [String: NSWindow] = [:]

    func register(_ window: NSWindow, title: String) {
        windows[title] = window
    }

    func unregister(title: String) {
        windows.removeValue(forKey: title)
    }

    func focus(title: String) {
        guard let window = windows[title], window.isVisible else { return }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func focusList(title: String) {
        focus(title: title)

        DispatchQueue.main.async { [weak self] in
            guard let window = self?.windows[title], window.isVisible,
                  let tableView = window.contentView?.firstDescendant(of: NSTableView.self) else {
                return
            }
            window.makeFirstResponder(tableView)
        }
    }

    func isFocused(title: String) -> Bool {
        guard let window = windows[title], window.isVisible else { return false }
        return window === NSApp.keyWindow
    }
}

private extension NSView {
    func firstDescendant<T: NSView>(of type: T.Type) -> T? {
        if let matchingView = self as? T {
            return matchingView
        }
        for subview in subviews {
            if let matchingView = subview.firstDescendant(of: type) {
                return matchingView
            }
        }
        return nil
    }
}

private struct ChildWindow<WindowContent: View>: NSViewRepresentable {
    @Binding var isPresented: Bool
    let title: String
    let contentSize: NSSize
    let showsWindowTitle: Bool
    let undoManager: UndoManager?
    let windowContent: () -> WindowContent

    func makeCoordinator() -> Coordinator {
        Coordinator(isPresented: $isPresented, title: title)
    }

    func makeNSView(context: Context) -> NSView {
        NSView(frame: .zero)
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.isPresented = $isPresented

        if isPresented {
            if context.coordinator.window == nil {
                let window = EditingWindow(
                    contentRect: NSRect(origin: .zero, size: contentSize),
                    styleMask: [.titled, .closable, .miniaturizable],
                    backing: .buffered,
                    defer: false
                )
                window.title = title
                window.titleVisibility = showsWindowTitle ? .visible : .hidden
                window.contentMinSize = contentSize
                window.contentMaxSize = contentSize
                window.standardWindowButton(.zoomButton)?.isHidden = true
                window.isReleasedWhenClosed = false
                window.delegate = context.coordinator
                window.contentUndoManager = undoManager

                window.contentViewController = NSHostingController(rootView: windowContent())
                window.appearance = NSApp.appearance

                if let parentWindow = view.window {
                    context.coordinator.watch(parentWindow: parentWindow, closing: window)
                    let origin = NSPoint(
                        x: parentWindow.frame.midX - (contentSize.width / 2),
                        y: parentWindow.frame.midY - (contentSize.height / 2)
                    )
                    window.setFrameOrigin(origin)
                } else {
                    window.center()
                }

                context.coordinator.window = window
                SecondaryWindowRegistry.shared.register(window, title: title)
                window.makeKeyAndOrderFront(nil)
            }
        } else {
            context.coordinator.window?.close()
        }
    }

    final class Coordinator: NSObject, NSWindowDelegate {
        var isPresented: Binding<Bool>
        let title: String
        weak var window: EditingWindow?
        var parentCloseObserver: NSObjectProtocol?

        init(isPresented: Binding<Bool>, title: String) {
            self.isPresented = isPresented
            self.title = title
        }

        func watch(parentWindow: NSWindow, closing childWindow: NSWindow) {
            parentCloseObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification,
                object: parentWindow,
                queue: .main
            ) { [weak childWindow] _ in
                Task { @MainActor in
                    childWindow?.close()
                }
            }
        }

        func windowWillClose(_ notification: Notification) {
            if let parentCloseObserver {
                NotificationCenter.default.removeObserver(parentCloseObserver)
                self.parentCloseObserver = nil
            }
            isPresented.wrappedValue = false
            SecondaryWindowRegistry.shared.unregister(title: title)
            window?.contentViewController = nil
            window?.contentUndoManager = nil
            window = nil
        }
    }
}

extension View {
    func childWindow<WindowContent: View>(
        isPresented: Binding<Bool>,
        title: String,
        size: NSSize,
        showsWindowTitle: Bool = false,
        undoManager: UndoManager? = nil,
        @ViewBuilder content: @escaping () -> WindowContent
    ) -> some View {
        background(
            ChildWindow(
                isPresented: isPresented,
                title: title,
                contentSize: size,
                showsWindowTitle: showsWindowTitle,
                undoManager: undoManager,
                windowContent: content
            )
            .frame(width: 0, height: 0)
        )
    }
}

var isTextInputOrMenuActive: Bool {
    MainActor.assumeIsolated {
        guard let responder = NSApp.keyWindow?.firstResponder else { return false }
        return responder is NSTextView
            || responder is NSTextField
            || responder is NSComboBox
            || responder is NSPopUpButton
    }
}

@MainActor
func makeShortcutEventMonitor(
    isFocused: @escaping @MainActor () -> Bool,
    closesOnReturn: Bool = false,
    handle: @escaping @MainActor (AppShortcut) -> Bool
) -> Any? {
    NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
        let handled = MainActor.assumeIsolated {
            guard isFocused() else { return false }
            let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
            if closesOnReturn, [36, 76].contains(event.keyCode), modifiers.isEmpty, !isTextInputOrMenuActive {
                closeSecondaryWindow()
                return true
            }
            guard let shortcut = AppShortcut(event: event) else { return false }
            return handle(shortcut)
        }
        return handled ? nil : event
    }
}

func makePrimaryActionEventMonitor(
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

func removeEventMonitor(_ monitor: Any?) {
    if let monitor {
        NSEvent.removeMonitor(monitor)
    }
}

struct InitialKeyboardFocusReset: NSViewRepresentable {
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
