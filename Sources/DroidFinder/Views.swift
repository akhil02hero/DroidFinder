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
            if ADB.path == nil {
                ContentUnavailableView(
                    "adb is not installed", systemImage: "wrench.and.screwdriver",
                    description: Text("Open Terminal and run:\nbrew install android-platform-tools"))
            } else if b.device != nil {
                FileBrowser()
            } else if let d = b.devices.first(where: { $0.state == "unauthorized" }) {
                ContentUnavailableView(
                    "Allow access on your phone", systemImage: "lock.shield",
                    description: Text("Unlock \(d.displayName) and tap Allow on the “Allow USB debugging?” prompt.\nTick “Always allow from this computer”."))
            } else {
                ContentUnavailableView(
                    "Connect your Android phone", systemImage: "cable.connector",
                    description: Text("Plug it in with a USB cable.\nOn the phone, turn on Settings → Developer options → USB debugging."))
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

// MARK: - File browser

struct FileBrowser: View {
    @EnvironmentObject var b: Browser
    // @State needs a compiler plugin that only ships with full Xcode, so view state lives here.
    @StateObject private var ui = FileBrowserState()

    private var rows: [RemoteFile] {
        let q = b.search.trimmingCharacters(in: .whitespaces)
        let list = b.files
            .filter { b.showHidden || !$0.name.hasPrefix(".") }
            .filter { q.isEmpty || $0.name.localizedCaseInsensitiveContains(q) }
            .sorted(using: ui.sort)
        return list.filter(\.isDirectory) + list.filter { !$0.isDirectory }
    }

    var body: some View {
        Table(of: RemoteFile.self, selection: $b.selection, sortOrder: $ui.sort) {
            TableColumn("Name", value: \.name) { f in
                HStack(spacing: 6) {
                    Image(nsImage: Icons.icon(for: f)).resizable().frame(width: 16, height: 16)
                    Text(f.name).lineLimit(1).truncationMode(.middle)
                }
            }
            .width(min: 220, ideal: 380)
            TableColumn("Date Modified", value: \.modified) { f in
                Text(f.modified, format: .dateTime.day().month(.abbreviated).year().hour().minute())
                    .foregroundStyle(.secondary)
            }
            .width(min: 120, ideal: 170)
            TableColumn("Size", value: \.size) { f in
                Text(f.isDirectory ? "--" : bytes(f.size)).foregroundStyle(.secondary)
            }
            .width(min: 60, ideal: 80)
            TableColumn("Kind", value: \.kind) { f in
                Text(f.kind).foregroundStyle(.secondary)
            }
            .width(min: 80, ideal: 130)
        } rows: {
            ForEach(rows) { f in
                TableRow(f).itemProvider { b.dragProvider(for: f, serial: b.selected ?? "") }
            }
        }
        .contextMenu(forSelectionType: RemoteFile.ID.self) { ids in
            menu(for: b.files.filter { ids.contains($0.id) })
        } primaryAction: { ids in
            if ids.count == 1, let f = b.files.first(where: { ids.contains($0.id) }) { b.openItem(f) }
        }
        .onDeleteCommand { ui.pendingDelete = b.selectedFiles }
        .overlay {
            if b.loading && b.files.isEmpty {
                ProgressView()
            } else if !b.loading && rows.isEmpty {
                Text(b.search.isEmpty ? "This folder is empty" : "No matches").foregroundStyle(.secondary)
            }
        }
        .overlay {
            if ui.dropTargeted {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .background(Color.accentColor.opacity(0.08))
                    .overlay(Text("Drop to copy to phone").font(.title3).padding(8)
                        .background(.regularMaterial, in: Capsule()))
                    .padding(4)
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $ui.dropTargeted) { b.handleDrop($0) }
        .safeAreaInset(edge: .bottom, spacing: 0) { PathBar(count: rows.count) }
        .navigationTitle(title)
        .navigationSubtitle(b.device?.displayName ?? "")
        .searchable(text: $b.search, placement: .toolbar, prompt: "Search this folder")
        .toolbar { toolbar }
        .alert("New Folder", isPresented: $ui.askNewFolder) {
            TextField("Name", text: $ui.folderName)
            Button("Create") { b.newFolder(ui.folderName) }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Rename", isPresented: Binding(get: { ui.renaming != nil }, set: { if !$0 { ui.renaming = nil } })) {
            TextField("Name", text: $ui.renameText)
            Button("Rename") { if let f = ui.renaming { b.rename(f, to: ui.renameText) } }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(
            deleteTitle,
            isPresented: Binding(get: { !ui.pendingDelete.isEmpty }, set: { if !$0 { ui.pendingDelete = [] } })
        ) {
            Button("Delete", role: .destructive) { b.delete(ui.pendingDelete) }
        } message: {
            Text("This deletes it from the phone permanently. It can't be undone.")
        }
    }

    private var title: String {
        b.path == "/sdcard" ? "Internal Storage" : (b.path as NSString).lastPathComponent
    }

    private var deleteTitle: String {
        ui.pendingDelete.count == 1 ? "Delete “\(ui.pendingDelete[0].name)”?" : "Delete \(ui.pendingDelete.count) items?"
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button { b.goBack() } label: { Image(systemName: "chevron.left") }
                .disabled(b.back.isEmpty).help("Back").keyboardShortcut("[", modifiers: .command)
            Button { b.goForward() } label: { Image(systemName: "chevron.right") }
                .disabled(b.forward.isEmpty).help("Forward").keyboardShortcut("]", modifiers: .command)
            Button { b.goUp() } label: { Image(systemName: "arrow.up") }
                .disabled(b.path == "/").help("Enclosing Folder").keyboardShortcut(.upArrow, modifiers: .command)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button { ui.askNewFolder = true; ui.folderName = "untitled folder" } label: {
                Label("New Folder", systemImage: "folder.badge.plus")
            }
            .help("New Folder").keyboardShortcut("n", modifiers: [.command, .shift])
            Button { b.chooseUpload() } label: { Label("Copy to Phone", systemImage: "square.and.arrow.up") }
                .help("Copy files from your Mac to this folder")
            Button { b.copyToMac(b.selectedFiles) } label: { Label("Copy to Mac", systemImage: "square.and.arrow.down") }
                .disabled(b.selection.isEmpty).help("Copy the selected items to your Mac")
            Button { ui.pendingDelete = b.selectedFiles } label: { Label("Delete", systemImage: "trash") }
                .disabled(b.selection.isEmpty).help("Delete")
            Button { b.showHidden.toggle() } label: {
                Label("Hidden Files", systemImage: b.showHidden ? "eye" : "eye.slash")
            }
            .help(b.showHidden ? "Hide hidden files" : "Show hidden files")
            Button { b.reload() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                .help("Refresh").keyboardShortcut("r", modifiers: .command)
        }
    }

    @ViewBuilder
    private func menu(for items: [RemoteFile]) -> some View {
        if items.isEmpty {
            Button("New Folder…") { ui.askNewFolder = true; ui.folderName = "untitled folder" }
            Button("Copy Files from Mac…") { b.chooseUpload() }
            Button("Refresh") { b.reload() }
        } else {
            if items.count == 1 { Button("Open") { b.openItem(items[0]) } }
            Button("Copy to Mac…") { b.copyToMac(items) }
            Button("Copy to Downloads") {
                b.copyToMac(items, to: FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first)
            }
            if items.count == 1 {
                Button("Rename…") { ui.renameText = items[0].name; ui.renaming = items[0] }
            }
            Divider()
            Button("Delete…", role: .destructive) { ui.pendingDelete = items }
        }
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

final class FileBrowserState: ObservableObject {
    @Published var sort = [KeyPathComparator(\RemoteFile.name, comparator: .localizedStandard)]
    @Published var dropTargeted = false
    @Published var askNewFolder = false
    @Published var folderName = "untitled folder"
    @Published var renaming: RemoteFile?
    @Published var renameText = ""
    @Published var pendingDelete: [RemoteFile] = []
}
