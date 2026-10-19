import AppKit

/// Watches for a file drag in any app and a tap of the configured modifier combination during it.
///
/// Polls mouse/modifier state instead of using global key monitors, so it needs no
/// Accessibility permission. The drag pasteboard's change count tells a real file drag
/// apart from an ordinary mouse drag.
@MainActor
final class DragGestureMonitor {
    var onTrigger: (_ urls: [URL], _ location: NSPoint) -> Void = { _, _ in }

    private var timer: Timer?
    private let dragPasteboard = NSPasteboard(name: .drag)
    private var mouseWasDown = false
    private var changeCountAtMouseDown = 0
    private var comboDownAt: Date?
    private var comboWasPressed = false
    private var firedThisDrag = false

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func tick() {
        let mouseDown = NSEvent.pressedMouseButtons & 1 != 0
        if mouseDown && !mouseWasDown {
            changeCountAtMouseDown = dragPasteboard.changeCount
            firedThisDrag = false
            comboDownAt = nil
        }
        mouseWasDown = mouseDown
        guard mouseDown, !firedThisDrag, dragPasteboard.changeCount != changeCountAtMouseDown else {
            comboWasPressed = false
            return
        }

        let relevant: NSEvent.ModifierFlags = [.control, .option, .command, .shift]
        let flags = NSEvent.modifierFlags.intersection(relevant)
        let pressed = flags == Settings.shared.shortcut.flags

        if pressed && !comboWasPressed { comboDownAt = Date() }
        // A tap: the combination goes down and comes back up quickly.
        if !pressed && comboWasPressed && flags.isEmpty, let down = comboDownAt, Date().timeIntervalSince(down) < 0.8 {
            let urls = draggedFileURLs()
            if !urls.isEmpty {
                firedThisDrag = true
                onTrigger(urls, NSEvent.mouseLocation)
            }
        }
        comboWasPressed = pressed
    }

    private func draggedFileURLs() -> [URL] {
        let objs = dragPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
        return (objs as? [URL]) ?? []
    }
}
