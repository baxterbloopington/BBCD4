import AppKit
import SwiftUI

@MainActor
func closeSecondaryWindow() {
    NSApp.keyWindow?.close()
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
                let window = NSWindow(
                    contentRect: NSRect(origin: .zero, size: contentSize),
                    styleMask: [.titled, .closable, .miniaturizable],
                    backing: .buffered,
                    defer: false
                )
                window.title = title
                window.contentMinSize = contentSize
                window.contentMaxSize = contentSize
                window.standardWindowButton(.zoomButton)?.isHidden = true
                window.isReleasedWhenClosed = false
                window.delegate = context.coordinator

                window.contentViewController = NSHostingController(rootView: windowContent())

                if let parentWindow = view.window {
                    parentWindow.addChildWindow(window, ordered: .above)
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
            } else {
                context.coordinator.window?.makeKeyAndOrderFront(nil)
            }
        } else {
            context.coordinator.window?.close()
        }
    }

    final class Coordinator: NSObject, NSWindowDelegate {
        var isPresented: Binding<Bool>
        let title: String
        weak var window: NSWindow?
        weak var parentWindow: NSWindow?
        var parentCloseObserver: NSObjectProtocol?

        init(isPresented: Binding<Bool>, title: String) {
            self.isPresented = isPresented
            self.title = title
        }

        func watch(parentWindow: NSWindow, closing childWindow: NSWindow) {
            self.parentWindow = parentWindow
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
            if let window = notification.object as? NSWindow {
                parentWindow?.removeChildWindow(window)
            }
            if let parentCloseObserver {
                NotificationCenter.default.removeObserver(parentCloseObserver)
                self.parentCloseObserver = nil
            }
            parentWindow = nil
            isPresented.wrappedValue = false
            SecondaryWindowRegistry.shared.unregister(title: title)
            window = nil
        }
    }
}

extension View {
    func childWindow<WindowContent: View>(
        isPresented: Binding<Bool>,
        title: String,
        size: NSSize,
        @ViewBuilder content: @escaping () -> WindowContent
    ) -> some View {
        background(
            ChildWindow(
                isPresented: isPresented,
                title: title,
                contentSize: size,
                windowContent: content
            )
            .frame(width: 0, height: 0)
        )
    }
}
