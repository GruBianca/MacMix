import AppKit
import ApplicationServices
import CoreAudio
import CoreGraphics
import Foundation

/// UI automation for choosing a *system-wide* AirPlay output.
///
/// Accessibility identifiers were measured on macOS with the Chinese
/// Control Center UI. This is intentionally separate from AVRoutePickerView:
/// the latter can route app media without necessarily changing the Mac's
/// system-wide default output.
///
/// The caller must initiate this explicitly. A successful AXPress is not
/// evidence of a connected audio route: Core Audio confirmation is required.
@MainActor
enum ControlCenterAirPlayAutomation {
    enum Outcome {
        case connected(panelClosed: Bool)
        case permissionRequired
        case failed(String)
    }

    static func connect(
        to receiverName: String,
        isTargetOutput: @escaping @MainActor () -> Bool,
        isAirPlayDefault: @escaping @MainActor () -> Bool
    ) async -> Outcome {
        guard AXIsProcessTrusted() else {
            // The prompt registers this app in Accessibility settings.
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
            return .permissionRequired
        }

        guard let menuItem = findMenuBarControl() else {
            return .failed("Cannot find the Control Center menu bar item.")
        }

        if !isControlCenterOpen() {
            guard press(menuItem) else {
                return .failed("Could not open Control Center.")
            }
        }

        guard let airPlayButton = await waitForControl("controlcenter-airplay") else {
            return .failed("The Control Center AirPlay button was not found.")
        }
        guard press(airPlayButton) else {
            return .failed("Could not open the AirPlay output list.")
        }

        guard let target = await waitForControl("sound-device-\(receiverName)") else {
            return .failed("The AirPlay receiver is no longer listed: \(receiverName)")
        }
        guard press(target) else {
            return .failed("Could not request the AirPlay output: \(receiverName)")
        }

        // A slow HomePod handshake must finish before dismissing Control Center.
        // Poll instead of sleeping a fixed 20 seconds; require a stable route.
        var stableSamples = 0
        for _ in 0..<80 {
            let confirmed = isTargetOutput()
                || (isAirPlayDefault() && isReceiverSelected(receiverName))
            stableSamples = confirmed ? stableSamples + 1 : 0
            if stableSamples >= 3 {
                let closed = await dismissControlCenter(menuItem: menuItem, receiverName: receiverName)
                return .connected(panelClosed: closed)
            }
            try? await Task.sleep(for: .milliseconds(250))
            if Task.isCancelled {
                return .failed("AirPlay connection was cancelled.")
            }
        }

        return .failed("Timed out waiting for the Mac to confirm the AirPlay output.")
    }

    private static func cf(_ text: String) -> CFString {
        text.withCString {
            CFStringCreateWithCString(nil, $0, CFStringBuiltInEncodings.UTF8.rawValue)!
        }
    }

    private static func read(_ element: AXUIElement, _ attribute: String) -> String? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, cf(attribute), &result) == .success else {
            return nil
        }
        return result as? String
    }

    private static func children(_ element: AXUIElement, attribute: String = kAXChildrenAttribute) -> [AXUIElement] {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, cf(attribute), &result) == .success else {
            return []
        }
        return result as? [AXUIElement] ?? []
    }

    private static func controlCenterApplication() -> AXUIElement? {
        guard let app = NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.apple.controlcenter"
        ).first else {
            return nil
        }
        return AXUIElementCreateApplication(app.processIdentifier)
    }

    private static func windows() -> [AXUIElement] {
        guard let app = controlCenterApplication() else { return [] }
        return children(app, attribute: kAXWindowsAttribute)
    }

    private static func findInTree(_ identifier: String) -> AXUIElement? {
        var queue = windows()
        var index = 0
        while index < queue.count && index < 500 {
            let element = queue[index]
            index += 1
            if read(element, kAXIdentifierAttribute) == identifier {
                return element
            }
            queue.append(contentsOf: children(element))
        }
        return nil
    }

    private static func isControlCenterOpen() -> Bool {
        if windows().contains(where: {
            read($0, kAXSubroleAttribute) == "AXSystemDialog"
        }) {
            return true
        }
        return findInTree("controlcenter-airplay") != nil
            || findInTree("module-Sound") != nil
    }

    private static func isReceiverSelected(_ name: String) -> Bool {
        guard let row = findInTree("sound-device-\(name)") else { return false }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            row, cf(kAXValueAttribute), &value
        ) == .success else {
            return false
        }
        return (value as? NSNumber)?.intValue == 1
    }

    private static func matchingAncestor(_ element: AXUIElement, identifier: String) -> AXUIElement? {
        var current = element
        for _ in 0..<6 {
            if read(current, kAXIdentifierAttribute) == identifier {
                return current
            }
            var parent: CFTypeRef?
            guard AXUIElementCopyAttributeValue(
                current, cf(kAXParentAttribute), &parent
            ) == .success,
            let parent,
            CFGetTypeID(parent) == AXUIElementGetTypeID() else {
                break
            }
            current = parent as! AXUIElement
        }
        return nil
    }

    /// The menu bar lives outside Control Center's dialog window tree.
    /// This bounded hit-test is only used for its entrance/exit item.
    private static func findMenuBarControl() -> AXUIElement? {
        let bounds = CGDisplayBounds(CGMainDisplayID())
        let system = AXUIElementCreateSystemWide()
        for offset in [12, 19, 25] {
            let y = bounds.minY + CGFloat(offset)
            for x in stride(
                from: bounds.maxX - 700,
                through: bounds.maxX - 10,
                by: CGFloat(10)
            ) {
                var element: AXUIElement?
                guard AXUIElementCopyElementAtPosition(
                    system, Float(x), Float(y), &element
                ) == .success,
                let element else {
                    continue
                }
                if let match = matchingAncestor(
                    element, identifier: "com.apple.menuextra.controlcenter"
                ) {
                    return match
                }
            }
        }
        return nil
    }

    private static func fallbackFind(_ identifier: String) -> AXUIElement? {
        let bounds = CGDisplayBounds(CGMainDisplayID())
        let system = AXUIElementCreateSystemWide()
        let minX = max(bounds.minX + 10, bounds.maxX - 550)
        let maxY = min(bounds.maxY - 30, bounds.minY + 800)
        for y in stride(
            from: bounds.minY + 50,
            through: maxY,
            by: CGFloat(20)
        ) {
            for x in stride(
                from: minX,
                through: bounds.maxX - 10,
                by: CGFloat(20)
            ) {
                var element: AXUIElement?
                guard AXUIElementCopyElementAtPosition(
                    system, Float(x), Float(y), &element
                ) == .success,
                let element else {
                    continue
                }
                if let match = matchingAncestor(element, identifier: identifier) {
                    return match
                }
            }
        }
        return nil
    }

    private static func waitForControl(_ identifier: String) async -> AXUIElement? {
        for _ in 0..<12 {
            if let found = findInTree(identifier) { return found }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return fallbackFind(identifier)
    }

    private static func dismissControlCenter(
        menuItem: AXUIElement,
        receiverName: String
    ) async -> Bool {
        func isPanelVisible() -> Bool {
            isControlCenterOpen()
                || findInTree("sound-device-\(receiverName)") != nil
                || findInTree("module-Sound") != nil
        }

        // The audio detail and the parent Control Center are two levels.
        // Do not blindly press twice if the first press dismisses both.
        for _ in 0..<2 {
            guard isPanelVisible() else { return true }
            if !press(menuItem) {
                guard let fresh = findMenuBarControl(), press(fresh) else {
                    return false
                }
            }
            try? await Task.sleep(for: .milliseconds(130))
        }

        for _ in 0..<4 {
            if !isPanelVisible() { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return !isPanelVisible()
    }

    private static func press(_ element: AXUIElement) -> Bool {
        AXUIElementPerformAction(element, cf(kAXPressAction)) == .success
    }
}
