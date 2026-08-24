import AppKit
import SwiftUI

@main
struct BBCD4Mac {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var window: NSWindow?
    private let streamStore = StreamStore()
    private let downloadController = DownloadController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()
        let rootView = ContentView(downloadController: downloadController)
            .environmentObject(streamStore)
        let controller = NSHostingController(rootView: rootView)
        let window = NSWindow(contentViewController: controller)
        window.title = "BBCD4"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.collectionBehavior = [.managed]
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.setContentSize(NSSize(width: 520, height: 520))
        window.minSize = NSSize(width: 520, height: 520)
        window.maxSize = NSSize(width: 520, height: 520)
        window.delegate = self
        window.center()
        window.initialFirstResponder = nil
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
    }

    private func installMainMenu() {
        let mainMenu = NSMenu()

        let applicationItem = NSMenuItem()
        let applicationMenu = NSMenu()
        applicationMenu.addItem(
            withTitle: "Quit BBCD4",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        applicationItem.submenu = applicationMenu
        mainMenu.addItem(applicationItem)

        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: #selector(UndoManager.undo), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: #selector(UndoManager.redo), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSResponder.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        NSApp.mainMenu = mainMenu
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        confirmCancellationBeforeQuitting()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        confirmCancellationBeforeQuitting() ? .terminateNow : .terminateCancel
    }

    private func confirmCancellationBeforeQuitting() -> Bool {
        guard downloadController.isDownloading else { return true }

        let alert = NSAlert()
        alert.messageText = "Cancel download and quit?"
        alert.informativeText = "The current download will be cancelled."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Keep Downloading")

        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        downloadController.cancelCurrentDownload()
        return true
    }
}

@MainActor
final class DockDownloadProgress {
    static let shared = DockDownloadProgress()

    private let progressView = DockDownloadProgressView()
    private var isVisible = false

    func show(progress: Double) {
        let dockTile = NSApp.dockTile

        if !isVisible {
            progressView.frame = NSRect(origin: .zero, size: dockTile.size)
            dockTile.contentView = progressView
            isVisible = true
        }

        progressView.progress = min(1, max(0, progress))
        dockTile.display()
    }

    func hide() {
        guard isVisible else { return }

        NSApp.dockTile.contentView = nil
        NSApp.dockTile.display()
        isVisible = false
    }
}

private final class DockDownloadProgressView: NSView {
    var progress = 0.0 {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSApp.applicationIconImage.draw(
            in: bounds,
            from: .zero,
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: true,
            hints: [.interpolation: NSImageInterpolation.high]
        )

        let height = max(8, bounds.height * 0.150)
        let horizontalInset = max(2, bounds.width * 0.015)
        let track = NSRect(
            x: horizontalInset,
            y: bounds.height * 0.010,
            width: bounds.width - (horizontalInset * 2),
            height: height
        )

        let trackPath = NSBezierPath(roundedRect: track, xRadius: height / 2, yRadius: height / 2)
        NSColor.black.withAlphaComponent(0.65).setFill()
        trackPath.fill()
        NSColor.white.withAlphaComponent(0.20).setStroke()
        trackPath.lineWidth = 4
        trackPath.stroke()

        let completed = NSRect(
            x: track.minX,
            y: track.minY,
            width: track.width * progress,
            height: track.height
        )
        guard !completed.isEmpty else { return }

        NSColor.systemBlue.setFill()
        NSBezierPath(roundedRect: completed, xRadius: height / 2, yRadius: height / 2).fill()
    }
}
