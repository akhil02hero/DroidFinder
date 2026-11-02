import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var b: Browser
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 190, ideal: 220)
        } detail: {
            if b.device != nil {
                FileBrowser()
            } else if ADB.path == nil && !MTP.shared.isAvailable {
                ContentUnavailableView(
                    "adb is not installed", systemImage: "wrench.and.screwdriver",
                    description: Text("Open Terminal and run:\nbrew install android-platform-tools"))
            } else if let d = b.devices.first(where: { $0.state == "unauthorized" }) {
                ContentUnavailableView(
                    "Allow access on your phone", systemImage: "lock.shield",
                    description: Text("Unlock \(d.displayName) and tap Allow on the “Allow USB debugging?” prompt.\nTick “Always allow from this computer”."))
            } else if let d = b.devices.first(where: { $0.state == "mtp-locked" }) {
                ContentUnavailableView(
                    "Unlock your phone", systemImage: "lock.iphone",
                    description: Text("Unlock \(d.displayName). If it still doesn't appear, pull down the notifications, tap the USB notification and choose “File transfer”."))
            } else {
                ContentUnavailableView(
                    "Connect your Android phone", systemImage: "cable.connector",
                    description: Text("Plug it in with a USB cable and choose “File transfer” on the phone.\nFor full access, also turn on Settings → Developer options → USB debugging."))
            }
        }
        .alert("Something went wrong", isPresented: Binding(get: { b.error != nil }, set: { if !$0 { b.error = nil } })) {
            Button("OK") {}
        } message: {
            Text(b.error ?? "")
        }
        .onAppear { b.openMain = { openWindow(id: "main") } }
    }
}

// MARK: - Sidebar

private struct Place: Identifiable {
    let name: String
    let symbol: String
    let path: String
    var id: String { path }
}

private let places = [
    Place(name: "Internal Storage", symbol: "internaldrive", path: "/sdcard"),
    Place(name: "Camera", symbol: "camera", path: "/sdcard/DCIM/Camera"),
    Place(name: "Screenshots", symbol: "camera.viewfinder", path: "/sdcard/DCIM/Screenshots"),
    Place(name: "Downloads", symbol: "arrow.down.circle", path: "/sdcard/Download"),
    Place(name: "Pictures", symbol: "photo", path: "/sdcard/Pictures"),
    Place(name: "Documents", symbol: "doc", path: "/sdcard/Documents"),
    Place(name: "Movies", symbol: "film", path: "/sdcard/Movies"),
    Place(name: "Music", symbol: "music.note", path: "/sdcard/Music"),
    Place(name: "WhatsApp Media", symbol: "message", path: "/sdcard/Android/media/com.whatsapp/WhatsApp/Media"),
]

struct Sidebar: View {
    @EnvironmentObject var b: Browser

    var body: some View {
        List {
            Section("Devices") {
                if b.devices.isEmpty {
                    Text("No phone connected").foregroundStyle(.secondary)
                }
                ForEach(b.devices) { d in
                    Button {
                        if d.isReady { b.open(d.serial) }
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(d.displayName)
                                    .fontWeight(d.serial == b.selected ? .semibold : .regular)
                                if !d.isReady {
                                    Text(d.stateText).font(.caption).foregroundStyle(.secondary)
                                } else if d.isMTP {
                                    Text("File transfer mode").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        } icon: {
                            Image(systemName: d.isWireless ? "wifi" : "smartphone")
                        }
                    }
                    .buttonStyle(.plain)
                }
            }

            if b.device != nil {
                Section("Locations") {
                    ForEach(places) { p in
                        Button { b.navigate(to: p.path) } label: {
                            Label(p.name, systemImage: p.symbol)
                                .fontWeight(b.path == p.path ? .semibold : .regular)
                        }
                        .buttonStyle(.plain)
                    }
                }
                if let s = b.storage {
                    Section("Storage") {
                        VStack(alignment: .leading, spacing: 4) {
                            ProgressView(value: Double(s.total - s.free), total: Double(max(s.total, 1)))
                            Text("\(bytes(s.free)) free of \(bytes(s.total))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }
}

// MARK: - Path bar

struct PathBar: View {
    @EnvironmentObject var b: Browser
    let count: Int

    private var crumbs: [(name: String, path: String)] {
        var result: [(String, String)] = []
        var current = ""
        for part in b.path.split(separator: "/") {
            current += "/" + part
            result.append((current == "/sdcard" ? "Internal Storage" : String(part), current))
        }
        // Hide the levels above internal storage when we're inside it.
        if b.path.hasPrefix("/sdcard") { result.removeAll { !$0.1.hasPrefix("/sdcard") } }
        return result
    }

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(crumbs.enumerated()), id: \.offset) { i, c in
                if i > 0 { Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary) }
                Button(c.name) { b.navigate(to: c.path) }
                    .buttonStyle(.plain)
                    .foregroundStyle(i == crumbs.count - 1 ? .primary : .secondary)
            }
            Spacer()
            if let busy = b.busy {
                ProgressView().controlSize(.small)
                Text(busy).lineLimit(1).foregroundStyle(.secondary)
            } else {
                Text(b.selection.isEmpty ? "\(count) items" : "\(b.selection.count) of \(count) selected")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}

// MARK: - Helpers

enum Icons {
    private static var cache: [String: NSImage] = [:]

    static func icon(for f: RemoteFile) -> NSImage {
        let key = f.isDirectory ? "/" : f.ext.lowercased()
        if let image = cache[key] { return image }
        let type: UTType = f.isDirectory ? .folder : (UTType(filenameExtension: key) ?? .data)
        let image = NSWorkspace.shared.icon(for: type)
        cache[key] = image
        return image
    }
}

func bytes(_ n: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
}
