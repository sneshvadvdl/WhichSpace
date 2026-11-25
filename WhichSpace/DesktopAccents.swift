import AppKit
import CoreGraphics

@MainActor
final class DesktopAccentController {
    private var windows: [String: DesktopAccentWindow] = [:]
    private var currentDisplays: [DisplaySpaceInfo] = []
    private var enabled = false
    private var screenChanges: Task<Void, Never>?

    init() {
        screenChanges = Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: NSApplication.didChangeScreenParametersNotification) {
                guard let self else { return }
                update(displays: currentDisplays, enabled: enabled)
            }
        }
    }

    deinit {
        screenChanges?.cancel()
    }

    func update(displays: [DisplaySpaceInfo], enabled: Bool) {
        currentDisplays = displays
        self.enabled = enabled
        guard enabled else {
            for window in windows.values {
                window.close()
            }
            windows.removeAll()
            return
        }

        var screensByID: [String: NSScreen] = [:]
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                  let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue(),
                  let identifier = CFUUIDCreateString(nil, uuid) as String?
            else {
                NSLog("DesktopAccents: cannot identify an attached screen")
                continue
            }
            screensByID[identifier.uppercased()] = screen
            if CGDisplayIsMain(number.uint32Value) != 0 {
                screensByID["MAIN"] = screen
            }
        }

        var liveDisplayIDs: Set<String> = []
        for (index, display) in displays.enumerated() {
            let identifier = display.displayID.uppercased()
            guard let screen = screensByID[identifier] else {
                NSLog("DesktopAccents: no attached screen for display %@", display.displayID)
                continue
            }
            liveDisplayIDs.insert(identifier)
            let color = StatusBarRenderer.displayBackgroundColors[index % StatusBarRenderer.displayBackgroundColors.count]
            if let window = windows[identifier] {
                if window.frame != screen.frame {
                    window.setFrame(screen.frame, display: true)
                }
                window.accentView.color = color
            } else {
                let window = DesktopAccentWindow(frame: screen.frame, color: color)
                windows[identifier] = window
                window.orderFrontRegardless()
            }
        }
        for identifier in Set(windows.keys).subtracting(liveDisplayIDs) {
            windows.removeValue(forKey: identifier)?.close()
        }
    }
}

@MainActor
final class DesktopAccentWindow: NSWindow {
    let accentView: DesktopAccentView

    init(frame: NSRect, color: NSColor) {
        accentView = DesktopAccentView(frame: NSRect(origin: .zero, size: frame.size), color: color)
        super.init(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        title = "WhichSpace Desktop Accent"
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isRestorable = false
        ignoresMouseEvents = true
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1)
        // Desktop decoration must not be scaled like an application window.
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .transient]
        animationBehavior = .none
        contentView = accentView
        accentView.autoresizingMask = [.width, .height]
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

}

@MainActor
final class DesktopAccentView: NSView {
    var color: NSColor {
        didSet {
            if color != oldValue {
                needsDisplay = true
            }
        }
    }

    init(frame: NSRect, color: NSColor) {
        self.color = color
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_: NSRect) {
        guard let glow = NSGradient(starting: color.withAlphaComponent(0.4), ending: color.withAlphaComponent(0)) else {
            NSLog("DesktopAccents: cannot create the desktop accent gradient")
            return
        }
        let width = min(bounds.width * 0.15, 220)
        let height = min(bounds.height * 0.1, 100)
        glow.draw(in: NSRect(x: 0, y: 0, width: width, height: bounds.height), angle: 0)
        glow.draw(in: NSRect(x: bounds.width - width, y: 0, width: width, height: bounds.height), angle: 180)
        glow.draw(in: NSRect(x: 0, y: 0, width: bounds.width, height: height), angle: 90)
        glow.draw(in: NSRect(x: 0, y: bounds.height - height, width: bounds.width, height: height), angle: 270)
        let border = NSBezierPath(rect: bounds.insetBy(dx: 2, dy: 2))
        border.lineWidth = 4
        color.withAlphaComponent(0.85).setStroke()
        border.stroke()
    }
}
