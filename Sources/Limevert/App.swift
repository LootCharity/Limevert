import AppKit
import SwiftUI

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    private let monitor = DragGestureMonitor()
    private var menuBar: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        menuBar = MenuBarController()
        monitor.onTrigger = { urls, point in ConversionWheelController.shared.show(for: urls, at: point) }
        monitor.start()
        if !Settings.shared.hasSeenWelcome { WelcomeWindow.show() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        SettingsWindowController.shared.show()
        return false
    }
}

@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

    override init() {
        super.init()
        if let button = item.button {
            button.image = LimeMark.menuBarImage()
            button.toolTip = "Limevert"
            let drop = StatusDropView(frame: button.bounds)
            drop.autoresizingMask = [.width, .height]
            button.addSubview(drop)
        }
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let header = NSMenuItem(title: "Drag files, then tap \(Settings.shared.shortcut.label)", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Convert Files…", action: #selector(convertFiles), keyEquivalent: "o").target = self
        menu.addItem(withTitle: "Create a New Float", action: #selector(newFloat), keyEquivalent: "n").target = self
        if FloatShelf.count > 0 {
            menu.addItem(withTitle: "Close All Floats", action: #selector(closeFloats), keyEquivalent: "").target = self
        }

        let history = TaskHistory.shared.entries
        if !history.isEmpty {
            menu.addItem(.separator())
            let title = NSMenuItem(title: "Recent", action: nil, keyEquivalent: "")
            title.isEnabled = false
            menu.addItem(title)
            for entry in history {
                let name = entry.outputs.count == 1 ? entry.outputs[0].lastPathComponent : "\(entry.outputs.count) files"
                let mi = NSMenuItem(title: "\(entry.failed ? "⚠︎ " : "")\(entry.title) → \(name)",
                                    action: #selector(reveal(_:)), keyEquivalent: "")
                mi.target = self
                mi.representedObject = entry.outputs
                mi.isEnabled = !entry.outputs.isEmpty
                menu.addItem(mi)
            }
        }

        menu.addItem(.separator())
        menu.addItem(withTitle: "Getting Started", action: #selector(welcome), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Settings…", action: #selector(settings), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Limevert", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    @objc private func convertFiles() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.message = "Choose files to convert"
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        ActionMenu.pop(for: panel.urls)
    }

    @objc private func newFloat() { FloatShelf.create() }
    @objc private func closeFloats() { FloatShelf.closeAll() }
    @objc private func settings() { SettingsWindowController.shared.show() }
    @objc private func welcome() { WelcomeWindow.show() }
    @objc private func reveal(_ sender: NSMenuItem) {
        if let urls = sender.representedObject as? [URL] { NSWorkspace.shared.activateFileViewerSelecting(urls) }
    }
}

/// Dropping files onto the menu bar icon opens the wheel just below it.
final class StatusDropView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }   // let clicks reach the button

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let urls = (sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                          options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        guard !urls.isEmpty, let window else { return [] }
        let iconFrame = window.convertToScreen(convert(bounds, to: nil))
        MainActor.assumeIsolated {
            // Anchor just below the icon; placement slides the wheel down until it clears the menu bar.
            ConversionWheelController.shared.show(for: urls, at: NSPoint(x: iconFrame.midX, y: iconFrame.minY - 8))
        }
        return .copy
    }
}

/// Click-driven alternative to the wheel: a menu of the same actions.
@MainActor
enum ActionMenu {
    @MainActor private final class Target: NSObject {
        let urls: [URL]
        init(urls: [URL]) { self.urls = urls }
        @objc func pick(_ sender: NSMenuItem) {
            guard let box = sender.representedObject as? ActionBox else { return }
            ActionRunner.run(box.value, on: urls)
        }
    }
    private final class ActionBox: NSObject {
        let value: WheelAction
        init(_ value: WheelAction) { self.value = value }
    }
    private static var target: Target?

    static func pop(for urls: [URL]) {
        let t = Target(urls: urls)
        target = t
        let menu = NSMenu()
        var lastWasConvert = true
        for action in ActionCatalog.actions(for: urls) {
            let isConvert: Bool
            if case .convert = action { isConvert = true } else { isConvert = false }
            if lastWasConvert && !isConvert && menu.numberOfItems > 0 { menu.addItem(.separator()) }
            lastWasConvert = isConvert
            let mi = NSMenuItem(title: isConvert ? "Convert to \(action.label)" : action.label,
                                action: #selector(Target.pick(_:)), keyEquivalent: "")
            mi.target = t
            mi.representedObject = ActionBox(action)
            if let symbol = action.symbol { mi.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
            menu.addItem(mi)
        }
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }
}
