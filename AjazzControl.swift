import AppKit
import WebKit

@main
final class AjazzControl: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var editor: EditorSession?
    private var window: NSWindow?
    private var statusItem: NSStatusItem?

    static func main() {
        let app = NSApplication.shared
        let delegate = AjazzControl()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            guard let root = Bundle.main.resourceURL?.appendingPathComponent("Editor") else {
                throw EditorError("ajazz-mac’s resources could not be found.")
            }
            editor = try EditorSession(root: root)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1030, height: 700),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                  backing: .buffered, defer: false)
            window.title = "ajazz-mac"
            window.minSize = NSSize(width: 700, height: 500)
            window.isReleasedWhenClosed = false
            window.contentView = editor?.webView
            window.setFrameAutosaveName("AjazzControl")
            if !window.setFrameUsingName("AjazzControl") { window.center() }
            self.window = window
            createApplicationMenu()
            createMenu()
            show()
        } catch {
            NSAlert(error: error).runModal()
            NSApp.terminate(nil)
        }
    }

    private func createApplicationMenu() {
        let mainMenu = NSMenu()
        let applicationItem = NSMenuItem()
        mainMenu.addItem(applicationItem)
        let applicationMenu = NSMenu(title: "ajazz-mac")
        applicationMenu.addItem(withTitle: "Quit ajazz-mac",
                                action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        applicationItem.submenu = applicationMenu
        NSApp.mainMenu = mainMenu
    }

    private func createMenu() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "keyboard", accessibilityDescription: "ajazz-mac")
        item.button?.toolTip = "ajazz-mac"
        let menu = NSMenu()
        func add(_ label: String, _ action: Selector, _ key: String = "") {
            let entry = menu.addItem(withTitle: label, action: action, keyEquivalent: key)
            entry.target = self
        }
        add("Open ajazz-mac…", #selector(show))
        menu.addItem(.separator())
        add("Keys…", #selector(keys))
        add("Lights…", #selector(lights))
        add("Music Mode…", #selector(music))
        add("Toggle Lights", #selector(toggleLights))
        add("Settings…", #selector(settings))
        add("Help…", #selector(help))
        menu.addItem(.separator())
        add("Quit ajazz-mac", #selector(quit), "q")
        item.menu = menu
        statusItem = item
    }

    @objc private func show() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func select(_ script: String) {
        show()
        editor?.webView.evaluateJavaScript(script)
    }

    @objc private func keys() { select("irA('teclas')") }
    @objc private func lights() { select("irA('luces')") }
    @objc private func settings() { select("irA('ajustes')") }
    @objc private func help() { select("irA('ayuda')") }
    @objc private func music() { select("irA('luces'); document.querySelector('[data-efecto=musica]')?.click()") }
    @objc private func toggleLights() { select("irA('luces'); apagarLuces()") }
    @objc private func quit() { NSApp.terminate(nil) }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        show()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) { editor?.stopMusic() }
}
