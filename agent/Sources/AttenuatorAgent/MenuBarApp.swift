import AppKit
import SwiftUI

/// Menu bar shell: a status item that toggles a popover holding the mixer UI.
///
/// `LSUIElement` in Info.plist keeps this out of the Dock and the app switcher,
/// which is what makes it read as a menu bar utility rather than an app.
@MainActor
final class MenuBarAppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private let controller = MixerController()
    private var eventMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller.start()

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(
            systemSymbolName: "slider.horizontal.3",
            accessibilityDescription: "Attenuator"
        )
        item.button?.action = #selector(togglePopover)
        item.button?.target = self
        statusItem = item

        popover.behavior = .transient
        popover.contentSize = NSSize(width: 340, height: 460)
        popover.contentViewController = NSHostingController(
            rootView: MenuBarView(controller: controller) { [weak self] in
                self?.quit()
            }
        )

        // Sleep/wake invalidates tap and aggregate object IDs, so the audio
        // graph has to be rebuilt rather than resumed.
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller.stop()
    }

    @objc private func handleWake() {
        controller.stop()
        controller.start()
    }

    @objc private func togglePopover() {
        guard let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func quit() {
        controller.stop()
        NSApplication.shared.terminate(nil)
    }
}

/// Starts the menu bar UI. Returns only when the app quits.
@MainActor
func runMenuBarApp() -> Never {
    let app = NSApplication.shared
    let delegate = MenuBarAppDelegate()
    app.delegate = delegate
    // .accessory rather than .regular: no Dock icon, but still able to show
    // windows and take key focus when the popover opens.
    app.setActivationPolicy(.accessory)
    app.run()
    exit(0)
}
