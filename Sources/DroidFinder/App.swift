import AppKit
import ServiceManagement
import SwiftUI

@main
struct DroidFinderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @ObservedObject private var browser = Browser.shared

    var body: some Scene {
        Window("DroidFinder", id: "main") {
            ContentView()
                .environmentObject(browser)
                .frame(minWidth: 780, minHeight: 460)
        }
        .defaultSize(width: 1040, height: 660)
        .commands {
            CommandGroup(before: .toolbar) {
                ForEach(ViewMode.allCases) { mode in
                    Button(mode.title) { browser.viewMode = mode }
                        .keyboardShortcut(mode.key, modifiers: .command)
                }
                Divider()
            }
        }

        MenuBarExtra {
            MenuContent().environmentObject(browser)
        } label: {
            MenuLabel().environmentObject(browser)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in Browser.shared.startWatching() }

        // A phone left with an open MTP session refuses the next one until its USB mode is
        // toggled, so close the session even when we're killed (kill, logout, installer).
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler {
                MTP.shared.disconnectNow()
                exit(0)
            }
            source.resume()
            signalSources.append(source)
        }
    }

    // Hand the phone back to macOS (Photos, Image Capture) when quitting.
    func applicationWillTerminate(_ notification: Notification) {
        MTP.shared.disconnectNow()
    }

    // Keep running in the menu bar so we can pop up when a phone is plugged in.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { Task { @MainActor in Browser.shared.bringToFront() } }
        return true
    }
}

struct MenuLabel: View {
    @EnvironmentObject var b: Browser
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(systemName: b.device == nil ? "smartphone" : "externaldrive.connected.to.line.below")
            // The menu bar label lives for the whole app, so it's a reliable place to keep openWindow.
            .onAppear { b.openMain = { openWindow(id: "main") } }
    }
}

struct MenuContent: View {
    @EnvironmentObject var b: Browser

    // Reads the real login-item status each time, so it never drifts out of sync.
    private var openAtLogin: Binding<Bool> {
        Binding(
            get: { SMAppService.mainApp.status == .enabled },
            set: { on in
                do {
                    if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                } catch {
                    b.error = "Couldn't change Open at Login: \(error.localizedDescription)"
                }
                b.objectWillChange.send()
            })
    }

    var body: some View {
        Text(b.device.map { "Connected: \($0.displayName)" } ?? "No phone connected")
        Button("Open DroidFinder") { b.bringToFront() }
        Divider()
        Toggle("Open at Login", isOn: openAtLogin)
        Divider()
        Button("Quit DroidFinder") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}
