import AppKit
import SwiftUI

enum ViewMode: String, CaseIterable, Identifiable {
    case icons, list, columns, gallery

    var id: String { rawValue }
    var title: String {
        switch self {
        case .icons: return "as Icons"
        case .list: return "as List"
        case .columns: return "as Columns"
        case .gallery: return "as Gallery"
        }
    }
    var symbol: String {
        switch self {
        case .icons: return "square.grid.2x2"
        case .list: return "list.bullet"
        case .columns: return "rectangle.split.3x1"
        case .gallery: return "rectangle.bottomhalf.inset.filled"
        }
    }
    var key: KeyEquivalent {
        switch self {
        case .icons: return "1"
        case .list: return "2"
        case .columns: return "3"
        case .gallery: return "4"
        }
    }
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
        content
            .onDeleteCommand { ui.pendingDelete = b.selectedFiles }
            .overlay {
                if b.viewMode != .columns {
                    if b.loading && b.files.isEmpty {
                        ProgressView()
                    } else if !b.loading && rows.isEmpty {
                        Text(b.search.isEmpty ? "This folder is empty" : "No matches").foregroundStyle(.secondary)
                    }
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
            .environmentObject(ui)
    }

    @ViewBuilder
    private var content: some View {
        switch b.viewMode {
        case .icons: IconsView(rows: rows)
        case .list: listView
        case .columns: ColumnsView(rows: rows)
        case .gallery: GalleryView(rows: rows)
        }
    }

    private var listView: some View {
        Table(of: RemoteFile.self, selection: $b.selection, sortOrder: $ui.sort) {
            TableColumn("Name", value: \.name) { f in
                HStack(spacing: 6) {
                    Thumb(file: f, side: 16, pixels: 64)
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
            ItemMenu(items: b.files.filter { ids.contains($0.id) })
        } primaryAction: { ids in
            if ids.count == 1, let f = b.files.first(where: { ids.contains($0.id) }) { b.openItem(f) }
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
                .disabled(b.path == b.rootPath).help("Enclosing Folder").keyboardShortcut(.upArrow, modifiers: .command)
        }
        ToolbarItem(placement: .primaryAction) {
            Picker("View", selection: $b.viewMode) {
                ForEach(ViewMode.allCases) { m in
                    Label(m.title, systemImage: m.symbol).tag(m)
                }
            }
            .pickerStyle(.segmented)
            .labelStyle(.iconOnly)
            .help("Show items as icons, list, columns or gallery (⌘1–⌘4)")
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
}

/// Right-click menu shared by every view mode.
struct ItemMenu: View {
    @EnvironmentObject var b: Browser
    @EnvironmentObject var ui: FileBrowserState
    let items: [RemoteFile]

    var body: some View {
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
