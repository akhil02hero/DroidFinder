import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class Browser: ObservableObject {
    static let shared = Browser()

    @Published var devices: [ADBDevice] = []
    @Published var selected: String?
    @Published var path = "/sdcard"
    @Published var files: [RemoteFile] = []
    @Published var selection = Set<RemoteFile.ID>()
    @Published var back: [String] = []
    @Published var forward: [String] = []
    @Published var loading = false
    @Published var busy: String?
    @Published var error: String?
    @Published var search = ""
    @Published var showHidden = false
    @Published var storage: (free: Int64, total: Int64)?
    @Published var viewMode = ViewMode(rawValue: UserDefaults.standard.string(forKey: "viewMode") ?? "") ?? .list {
        didSet { UserDefaults.standard.set(viewMode.rawValue, forKey: "viewMode") }
    }
    /// Folder contents by path, so column view can show every level at once.
    @Published var listings: [String: [RemoteFile]] = [:]

    /// Set by a view that can open the main window; called when a phone is plugged in.
    var openMain: (() -> Void)?
    private var knownReady = Set<String>()
    private var watching = false

    var device: ADBDevice? { devices.first { $0.serial == selected && $0.isReady } }
    var selectedFiles: [RemoteFile] { files.filter { selection.contains($0.id) } }

    // MARK: Devices

    func startWatching() {
        guard !watching else { return }
        watching = true
        Task {
            while true {
                await refreshDevices()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    func refreshDevices() async {
        guard let list = try? await ADB.devices() else { return }
        if list != devices { devices = list }

        let ready = Set(list.filter(\.isReady).map(\.serial))
        let newlyReady = ready.subtracting(knownReady)
        knownReady = ready

        if let s = selected, !ready.contains(s) {
            selected = nil
            files = []
            storage = nil
        }
        // Prefer a phone on the cable over anything on Wi-Fi.
        if selected == nil,
           let pick = list.first(where: { $0.isReady && !$0.isWireless }) ?? list.first(where: \.isReady) {
            open(pick.serial)
        }
        if !newlyReady.isEmpty { bringToFront() }
    }

    func bringToFront() {
        openMain?()
        NSApp.activate(ignoringOtherApps: true)
    }

    func open(_ serial: String) {
        selected = serial
        back = []
        forward = []
        path = "/sdcard"
        selection = []
        listings = [:]
        reload()
        Task {
            if let s = try? await ADB.storage(serial) { storage = (s.0, s.1) }
        }
    }

    // MARK: Navigation

    func reload() {
        guard let serial = selected else { return }
        let p = path
        loading = true
        Task {
            do {
                let list = try await ADB.list(serial, p)
                listings[p] = list
                if path == p { files = list }
            } catch {
                if path == p { files = []; self.error = error.localizedDescription }
            }
            loading = false
        }
    }

    /// Loads a folder's contents into `listings` if they aren't there yet.
    func ensureListing(_ dir: String) {
        guard let serial = selected, listings[dir] == nil else { return }
        listings[dir] = []
        Task {
            if let list = try? await ADB.list(serial, dir) { listings[dir] = list }
        }
    }

    /// Finder-style click: plain click selects one item, ⌘-click toggles it.
    func click(_ f: RemoteFile) {
        if NSEvent.modifierFlags.contains(.command) {
            if selection.contains(f.id) { selection.remove(f.id) } else { selection.insert(f.id) }
        } else {
            selection = [f.id]
        }
    }

    func navigate(to p: String) {
        guard p != path else { return }
        back.append(path)
        forward.removeAll()
        go(p)
    }

    func goBack() {
        guard let p = back.popLast() else { return }
        forward.append(path)
        go(p)
    }

    func goForward() {
        guard let p = forward.popLast() else { return }
        back.append(path)
        go(p)
    }

    func goUp() {
        let parent = (path as NSString).deletingLastPathComponent
        navigate(to: parent.isEmpty ? "/" : parent)
    }

    private func go(_ p: String) {
        path = p
        selection = []
        search = ""
        files = listings[p] ?? []
        reload()
    }

    func openItem(_ f: RemoteFile) {
        if f.isDirectory { navigate(to: f.path); return }
        guard let serial = selected else { return }
        Task {
            await withBusy("Opening \(f.name)…") {
                let target = Self.tempDir().appendingPathComponent(f.name)
                try await ADB.pull(serial, f.path, to: target)
                NSWorkspace.shared.open(target)
            }
        }
    }

    // MARK: Transfers

    func copyToMac(_ items: [RemoteFile], to dest: URL? = nil) {
        guard let serial = selected, !items.isEmpty else { return }
        guard let folder = dest ?? chooseFolder() else { return }
        Task {
            var copied: [URL] = []
            for (i, f) in items.enumerated() {
                let ok = await withBusy("Copying \(i + 1) of \(items.count): \(f.name)…") {
                    let target = Self.uniqueURL(in: folder, name: f.name)
                    try await ADB.pull(serial, f.path, to: target)
                    copied.append(target)
                }
                if !ok { break }
            }
            if !copied.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(copied) }
        }
    }

    func chooseUpload() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.prompt = "Copy to Phone"
        panel.message = "Choose files or folders to copy to \(device?.displayName ?? "the phone")"
        if panel.runModal() == .OK { upload(panel.urls) }
    }

    func upload(_ urls: [URL]) {
        guard let serial = selected, !urls.isEmpty else { return }
        let dir = path
        var taken = Set(files.map(\.name))
        Task {
            for (i, url) in urls.enumerated() {
                let name = Self.uniqueName(url.lastPathComponent, taken: taken)
                taken.insert(name)
                let ok = await withBusy("Copying \(i + 1) of \(urls.count) to phone: \(url.lastPathComponent)…") {
                    try await ADB.push(serial, url, to: (dir as NSString).appendingPathComponent(name))
                }
                if !ok { break }
            }
            reload()
        }
    }

    func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        let group = DispatchGroup()
        let lock = NSLock()
        var urls: [URL] = []
        for provider in providers where provider.canLoadObject(ofClass: URL.self) {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url, url.isFileURL { lock.lock(); urls.append(url); lock.unlock() }
                group.leave()
            }
        }
        group.notify(queue: .main) { self.upload(urls) }
        return true
    }

    /// Lets a row be dragged straight into Finder; the file is pulled when it's dropped.
    nonisolated func dragProvider(for f: RemoteFile, serial: String) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.suggestedName = f.name
        let type: UTType = f.isDirectory ? .folder : (UTType(filenameExtension: f.ext) ?? .data)
        provider.registerFileRepresentation(forTypeIdentifier: type.identifier, fileOptions: [], visibility: .all) { done in
            Task.detached {
                do {
                    let target = Browser.tempDir().appendingPathComponent(f.name)
                    try await ADB.pull(serial, f.path, to: target)
                    done(target, false, nil)
                } catch {
                    done(nil, false, error)
                }
            }
            return nil
        }
        return provider
    }

    // MARK: File operations

    func newFolder(_ name: String) {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard let serial = selected, !name.isEmpty else { return }
        let target = (path as NSString).appendingPathComponent(name)
        Task {
            await withBusy("Creating \(name)…") { try await ADB.shell(serial, "mkdir -p \(ADB.quote(target))") }
            reload()
        }
    }

    func rename(_ f: RemoteFile, to name: String) {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard let serial = selected, !name.isEmpty, name != f.name, !name.contains("/") else { return }
        let target = ((f.path as NSString).deletingLastPathComponent as NSString).appendingPathComponent(name)
        Task {
            await withBusy("Renaming…") { try await ADB.shell(serial, "mv -n \(ADB.quote(f.path)) \(ADB.quote(target))") }
            reload()
        }
    }

    func delete(_ items: [RemoteFile]) {
        guard let serial = selected, !items.isEmpty else { return }
        Task {
            for f in items {
                let ok = await withBusy("Deleting \(f.name)…") { try await ADB.shell(serial, "rm -rf \(ADB.quote(f.path))") }
                if !ok { break }
            }
            selection = []
            reload()
        }
    }

    // MARK: Helpers

    @discardableResult
    private func withBusy(_ message: String, _ work: () async throws -> Void) async -> Bool {
        busy = message
        defer { busy = nil }
        do {
            try await work()
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    private func chooseFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Copy Here"
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        return panel.runModal() == .OK ? panel.url : nil
    }

    nonisolated static func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DroidFinder", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func uniqueURL(in folder: URL, name: String) -> URL {
        var taken = Set<String>()
        let existing = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        taken.formUnion(existing)
        return folder.appendingPathComponent(uniqueName(name, taken: taken))
    }

    /// "photo.jpg" -> "photo 2.jpg" when the name is already used.
    static func uniqueName(_ name: String, taken: Set<String>) -> String {
        guard taken.contains(name) else { return name }
        let ext = (name as NSString).pathExtension
        let stem = (name as NSString).deletingPathExtension
        var n = 2
        while true {
            let candidate = ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)"
            if !taken.contains(candidate) { return candidate }
            n += 1
        }
    }
}
