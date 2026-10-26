import AppKit
import Darwin
import SwiftUI
import UserNotifications

enum AppResources {
    static func url(forResource name: String, withExtension fileExtension: String) -> URL? {
        let bundledResource = Bundle.main.resourceURL?
            .appendingPathComponent("BBCD4Mac_BBCD4Mac.bundle", isDirectory: true)
        let resourceBundle = bundledResource.flatMap(Bundle.init(url:))

        return Bundle.main.url(forResource: name, withExtension: fileExtension)
            ?? resourceBundle?.url(forResource: name, withExtension: fileExtension)
            ?? Bundle.allBundles.lazy
                .compactMap { $0.url(forResource: name, withExtension: fileExtension) }
                .first
    }
}

enum AppAppearance: String, CaseIterable, Hashable {
    case system, light, dark

    var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    @MainActor func apply() {
        let appearance: NSAppearance?
        switch self {
        case .system: appearance = nil
        case .light: appearance = NSAppearance(named: .aqua)
        case .dark: appearance = NSAppearance(named: .darkAqua)
        }
        NSApp.appearance = appearance
        for window in NSApp.windows {
            window.appearance = appearance
        }
    }
}

@main
struct BBCD4Mac {
    static func main() {
        let isAppBundle = Bundle.main.bundleURL.pathExtension.lowercased() == "app"

        if isAppBundle,
           let bundleIdentifier = Bundle.main.bundleIdentifier,
           !SingleInstance.claim(bundleIdentifier: bundleIdentifier) {
            SingleInstance.activateExistingApp()
            exit(0)
        }

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        let showInFinderAction = UNNotificationAction(
            identifier: DownloadNotificationAction.showInFinderIdentifier,
            title: "Show in Finder",
            options: []
        )
        let completionCategory = UNNotificationCategory(
            identifier: DownloadNotificationAction.completionCategoryIdentifier,
            actions: [showInFinderAction],
            intentIdentifiers: [],
            options: []
        )
        UNUserNotificationCenter.current().setNotificationCategories([completionCategory])
        if isAppBundle {
            UNUserNotificationCenter.current().delegate = delegate
        }
        app.setActivationPolicy(.regular)
        app.run()
    }
}

private enum SingleInstance {
    static let activationNotification = Notification.Name("uk.co.bbcd4.activateExistingInstance")
    private nonisolated(unsafe) static var lockFileDescriptor: Int32 = -1

    static func claim(bundleIdentifier: String) -> Bool {
        let fileManager = FileManager.default
        let supportDirectory = fileManager
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(bundleIdentifier, isDirectory: true)
        try? fileManager.createDirectory(at: supportDirectory, withIntermediateDirectories: true)

        let lockURL = supportDirectory.appendingPathComponent("instance.lock")
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { return true }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            return false
        }

        lockFileDescriptor = descriptor
        return true
    }

    static func activateExistingApp() {
        DistributedNotificationCenter.default().post(
            name: activationNotification,
            object: nil,
            userInfo: nil
        )
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var window: NSWindow?
    private let streamStore = StreamStore()
    private let downloadController = DownloadController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(activateExistingApp),
            name: SingleInstance.activationNotification,
            object: nil,
            suspensionBehavior: .deliverImmediately
        )

        UpdateCheckFrequency.migratePreferences()
        DownloadNotifications.migrateLegacyPreferenceIfNeeded()
        (AppAppearance(rawValue: UserDefaults.standard.string(forKey: "appearanceMode") ?? "") ?? .system).apply()
        installMainMenu()
        let rootView = ContentView(downloadController: downloadController)
            .environmentObject(streamStore)
        let controller = NSHostingController(rootView: rootView)
        let contentSize = NSSize(width: ControlMetrics.mainWindowWidth, height: 520)
        let window = MainInputWindow(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "BBCD4"
        window.titleVisibility = .hidden
        window.collectionBehavior = [.managed]
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.contentMinSize = contentSize
        window.contentMaxSize = contentSize
        window.contentViewController = controller
        window.appearance = NSApp.appearance
        window.setContentSize(contentSize)
        window.delegate = self
        window.center()
        controller.view.layoutSubtreeIfNeeded()
        window.initialFirstResponder = controller.view
        window.makeFirstResponder(controller.view)
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func activateExistingApp() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
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

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        activateExistingApp()
        return true
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        return confirmCancellationBeforeQuitting()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        return confirmCancellationBeforeQuitting() ? .terminateNow : .terminateCancel
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

extension AppDelegate: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        guard response.actionIdentifier == DownloadNotificationAction.showInFinderIdentifier else {
            completionHandler()
            return
        }

        let completedOutputPath = response.notification.request.content.userInfo["completedOutputPath"] as? String
        Task { @MainActor in
            if let completedOutputPath,
               FileManager.default.fileExists(atPath: completedOutputPath) {
                NSWorkspace.shared.activateFileViewerSelecting([
                    URL(fileURLWithPath: completedOutputPath)
                ])
            }
        }
        completionHandler()
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

/// Clear editing only when the click is outside a text input. Field-to-field
/// clicks stay under AppKit's normal responder handling.
@MainActor
private final class MainInputWindow: NSWindow {
    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown, let contentView {
            let point = contentView.convert(event.locationInWindow, from: nil)
            var hit = contentView.hitTest(point)
            var clickedTextInput = false
            while let view = hit {
                if view is NSTextField || view is NSTextView {
                    clickedTextInput = true
                    break
                }
                hit = view.superview
            }
            let editingField = (firstResponder as? NSTextView)?.delegate as? FocusTrackingTextField
            let clickedEditingAccessory = editingField?.containsEditingAccessory(at: event.locationInWindow) == true
            if !clickedTextInput && !clickedEditingAccessory { makeFirstResponder(nil) }
        }
        super.sendEvent(event)
    }
}
