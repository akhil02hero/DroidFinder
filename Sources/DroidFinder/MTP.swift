import CLibMTP
import Foundation
import IOKit

/// Talks to a phone in "File transfer" (MTP) mode, used when USB debugging is off.
///
/// MTP addresses files by numeric object IDs rather than paths, so this keeps a
/// path → ID map filled in as folders are listed, and presents the phone's main
/// storage at "/sdcard" so the rest of the app sees the same paths as with adb.
/// libmtp isn't thread-safe: every call goes through one serial queue.
final class MTP {
    static let shared = MTP()
    /// The serial DroidFinder uses for the MTP phone; there's only ever one.
    static let serial = "mtp"
    static let root = "/sdcard"
    private static let rootID: UInt32 = 0xFFFF_FFFF

    var isAvailable: Bool { LibMTP.shared != nil }

    private let queue = DispatchQueue(label: "DroidFinder.mtp")
    private var initialized = false
    private var device: LibMTP.Device?
    private var model = ""
    private var vendorID: UInt16 = 0
    private var productID: UInt16 = 0
    private var storageID: UInt32 = 0
    private var ids: [String: UInt32] = [:]
    private var folders = Set<String>()
    private var lastAttempt = Date.distantPast
    private var firstSeen: Date?
    private var lastState = "mtp-locked"

    // MARK: Connection

    /// Called every couple of seconds while no phone is on adb. Opens the phone if one is
    /// plugged in, notices when it's unplugged, and reports what the sidebar should show.
    func poll() async -> ADBDevice? {
        await runQuietly { self.pollLocked() }
    }

    func disconnect() async {
        await runQuietly { self.releaseLocked() }
    }

    /// For app quit, where there's no time to hop through async.
    func disconnectNow() {
        queue.sync { releaseLocked() }
    }

    private func pollLocked() -> ADBDevice? {
        guard let lib = LibMTP.shared else { return nil }
        if !initialized { lib.initialize(); initialized = true }

        if device != nil {
            if usbDevicePresent(vendor: vendorID, product: productID) {
                return ADBDevice(serial: Self.serial, state: "device", model: model)
            }
            releaseLocked()
            return nil
        }

        var raw: UnsafeMutablePointer<LIBMTP_raw_device_t>?
        var count: Int32 = 0
        let result = lib.detectRawDevices(&raw, &count)
        defer { free(raw) }
        guard result == LIBMTP_ERROR_NONE, count > 0, let first = raw else {
            firstSeen = nil
            return nil
        }

        let entry = first.pointee.device_entry
        let name = entry.product.map { String(cString: $0) } ?? "Android phone"
        // Give the phone's file service a moment to start after it's plugged in or its USB
        // mode changes. Every failed open makes libmtp reset the phone's USB connection, so
        // retrying too eagerly can keep it from ever starting: back off further if it's stuck.
        let seen = firstSeen ?? Date()
        firstSeen = seen
        let wait: TimeInterval = lastState == "mtp-stuck" ? 15 : 4
        if Date().timeIntervalSince(seen) < 2 || Date().timeIntervalSince(lastAttempt) < wait {
            return ADBDevice(serial: Self.serial, state: lastState, model: name)
        }
        lastAttempt = Date()

        // macOS's Image Capture helper grabs MTP phones as soon as they're plugged in;
        // stop it so libmtp can claim the phone (launchd restarts it when it's needed).
        stopPhotoImporter()
        // The phone didn't answer at all: its USB connection is stuck, not just locked.
        guard let dev = lib.openRawDevice(first) else {
            lastState = "mtp-stuck"
            return ADBDevice(serial: Self.serial, state: lastState, model: name)
        }
        // A locked phone opens but shows no storage until it's unlocked.
        guard lib.getStorage(dev, 0) == 0, let storage = dev.pointee.storage else {
            lib.releaseDevice(dev)
            lastState = "mtp-locked"
            return ADBDevice(serial: Self.serial, state: lastState, model: name)
        }

        device = dev
        storageID = storage.pointee.id
        vendorID = entry.vendor_id
        productID = entry.product_id
        if let m = lib.getModelname(dev) {
            model = String(cString: m)
            free(m)
        } else {
            model = name
        }
        ids = [Self.root: Self.rootID]
        folders = [Self.root]
        lastState = "device"
        return ADBDevice(serial: Self.serial, state: "device", model: model)
    }

    private func releaseLocked() {
        if let dev = device { LibMTP.shared?.releaseDevice(dev) }
        device = nil
        ids = [:]
        folders = []
        lastAttempt = .distantPast
    }

    private func stopPhotoImporter() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        p.arguments = ["-9", "-x", "ptpcamerad"]
        try? p.run()
        p.waitUntilExit()
        usleep(300_000)
    }

    private func usbDevicePresent(vendor: UInt16, product: UInt16) -> Bool {
        guard let match = IOServiceMatching("IOUSBHostDevice") as NSMutableDictionary? else { return true }
        match["idVendor"] = vendor
        match["idProduct"] = product
        let service = IOServiceGetMatchingService(kIOMainPortDefault, match)
        defer { if service != 0 { IOObjectRelease(service) } }
        return service != 0
    }

    // MARK: File operations

    func list(_ dir: String) async throws -> [RemoteFile] {
        try await run { try self.listLocked(self.normalize(dir)) }
    }

    func storage() async throws -> (Int64, Int64)? {
        try await run {
            let (lib, dev) = try self.open()
            _ = lib.getStorage(dev, 0)
            guard let s = dev.pointee.storage else { return nil }
            return (Int64(s.pointee.FreeSpaceInBytes), Int64(s.pointee.MaxCapacity))
        }
    }

    func pull(_ remote: String, to local: URL) async throws {
        try await run { try self.pullLocked(self.normalize(remote), to: local) }
    }

    func push(_ local: URL, to remote: String) async throws {
        try await run {
            let remote = self.normalize(remote)
            let parent = try self.resolve((remote as NSString).deletingLastPathComponent)
            try self.pushLocked(local, name: (remote as NSString).lastPathComponent,
                                parentID: parent, parentPath: (remote as NSString).deletingLastPathComponent)
        }
    }

    func makeFolder(_ path: String) async throws {
        try await run {
            let path = self.normalize(path)
            let parentPath = (path as NSString).deletingLastPathComponent
            _ = try self.createFolderLocked((path as NSString).lastPathComponent,
                                            parentID: try self.resolve(parentPath), parentPath: parentPath)
        }
    }

    func rename(_ path: String, to newPath: String) async throws {
        try await run {
            let (lib, dev) = try self.open()
            let path = self.normalize(path)
            let id = try self.resolve(path)
            guard let file = lib.getFileMetadata(dev, id) else { throw self.failure("Couldn't rename") }
            defer { lib.destroyFile(file) }
            let name = ((newPath as NSString).lastPathComponent)
            guard lib.setFileName(dev, file, name) == 0 else { throw self.failure("Couldn't rename") }
            self.forget(path)
        }
    }

    func delete(_ path: String) async throws {
        try await run {
            let (lib, dev) = try self.open()
            let path = self.normalize(path)
            guard lib.deleteObject(dev, try self.resolve(path)) == 0 else { throw self.failure("Couldn't delete") }
            self.forget(path)
        }
    }

    /// The small preview the phone keeps for photos — much quicker than copying the photo.
    func thumbnail(_ path: String) async -> Data? {
        try? await run {
            let (lib, dev) = try self.open()
            var data: UnsafeMutablePointer<UInt8>?
            var size: UInt32 = 0
            guard lib.getThumbnail(dev, try self.resolve(self.normalize(path)), &data, &size) == 0,
                  let data, size > 0 else {
                lib.clearErrorstack(dev)
                return nil
            }
            defer { free(data) }
            return Data(bytes: data, count: Int(size))
        }
    }

    // MARK: Locked helpers (run on `queue`)

    private func open() throws -> (LibMTP, LibMTP.Device) {
        guard let lib = LibMTP.shared, let dev = device else {
            throw ADBError.failed("The phone is no longer connected.")
        }
        return (lib, dev)
    }

    private func normalize(_ path: String) -> String {
        path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    private func listLocked(_ dir: String) throws -> [RemoteFile] {
        let (lib, dev) = try open()
        guard dir == Self.root || dir.hasPrefix(Self.root + "/") else { return [] }
        let id = try resolve(dir)
        lib.clearErrorstack(dev)
        var result: [RemoteFile] = []
        var item = lib.getFilesAndFolders(dev, storageID, id)
        while let f = item {
            let next = f.pointee.next
            if let cName = f.pointee.filename {
                let name = String(cString: cName)
                let isDir = f.pointee.filetype == LIBMTP_FILETYPE_FOLDER
                let path = dir + "/" + name
                ids[path] = f.pointee.item_id
                if isDir { folders.insert(path) }
                result.append(RemoteFile(
                    path: path, name: name, isDirectory: isDir,
                    size: Int64(f.pointee.filesize),
                    modified: Date(timeIntervalSince1970: TimeInterval(f.pointee.modificationdate))))
            }
            lib.destroyFile(f)
            item = next
        }
        return result
    }

    /// Path → MTP object ID, listing parent folders as needed to find it.
    private func resolve(_ path: String) throws -> UInt32 {
        if let id = ids[path] { return id }
        guard path.hasPrefix(Self.root + "/") else { throw ADBError.failed("\(path) isn't on the phone.") }
        let parent = (path as NSString).deletingLastPathComponent
        _ = try resolve(parent)
        _ = try listLocked(parent)
        guard let id = ids[path] else { throw ADBError.failed("\((path as NSString).lastPathComponent) wasn't found on the phone.") }
        return id
    }

    private func pullLocked(_ remote: String, to local: URL) throws {
        let (lib, dev) = try open()
        let id = try resolve(remote)
        if folders.contains(remote) {
            try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
            for child in try listLocked(remote) {
                try pullLocked(child.path, to: local.appendingPathComponent(child.name))
            }
        } else if lib.getFileToFile(dev, id, local.path, nil, nil) != 0 {
            throw failure("Couldn't copy \(local.lastPathComponent)")
        }
    }

    private func pushLocked(_ local: URL, name: String, parentID: UInt32, parentPath: String) throws {
        let (lib, dev) = try open()
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: local.path, isDirectory: &isDir)
        if isDir.boolValue {
            let folderID = try createFolderLocked(name, parentID: parentID, parentPath: parentPath)
            let path = parentPath + "/" + name
            let children = try FileManager.default.contentsOfDirectory(at: local, includingPropertiesForKeys: nil)
            for child in children where !child.lastPathComponent.hasPrefix(".") {
                try pushLocked(child, name: child.lastPathComponent, parentID: folderID, parentPath: path)
            }
            return
        }
        guard let file = lib.newFile() else { throw failure("Couldn't copy \(name)") }
        defer { lib.destroyFile(file) }   // also frees the strdup'd filename
        let size = (try? FileManager.default.attributesOfItem(atPath: local.path)[.size] as? NSNumber)?.uint64Value ?? 0
        file.pointee.filename = strdup(name)
        file.pointee.filesize = size
        file.pointee.filetype = LIBMTP_FILETYPE_UNKNOWN
        file.pointee.parent_id = parentID
        file.pointee.storage_id = storageID
        guard lib.sendFileFromFile(dev, local.path, file, nil, nil) == 0 else { throw failure("Couldn't copy \(name)") }
        ids[parentPath + "/" + name] = file.pointee.item_id
    }

    private func createFolderLocked(_ name: String, parentID: UInt32, parentPath: String) throws -> UInt32 {
        let (lib, dev) = try open()
        let cName = strdup(name)
        defer { free(cName) }
        let id = lib.createFolder(dev, cName, parentID == Self.rootID ? 0 : parentID, storageID)
        guard id != 0 else { throw failure("Couldn't create \(name)") }
        let path = parentPath + "/" + name
        ids[path] = id
        folders.insert(path)
        return id
    }

    /// Drops cached IDs for a path and everything inside it after a rename or delete.
    private func forget(_ path: String) {
        for key in ids.keys where key == path || key.hasPrefix(path + "/") { ids[key] = nil }
        folders = folders.filter { $0 != path && !$0.hasPrefix(path + "/") }
    }

    private func failure(_ message: String) -> Error {
        guard let lib = LibMTP.shared, let dev = device else { return ADBError.failed(message) }
        var detail = ""
        if let e = lib.getErrorstack(dev), let text = e.pointee.error_text {
            detail = String(cString: text)
        }
        lib.clearErrorstack(dev)
        return ADBError.failed(detail.isEmpty ? message : "\(message): \(detail)")
    }

    private func run<T>(_ work: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { cont in
            queue.async { cont.resume(with: Result { try work() }) }
        }
    }

    private func runQuietly<T>(_ work: @escaping () -> T) async -> T {
        await withCheckedContinuation { cont in
            queue.async { cont.resume(returning: work()) }
        }
    }
}
