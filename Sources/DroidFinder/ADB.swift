import Foundation
import UniformTypeIdentifiers

struct ADBDevice: Identifiable, Hashable {
    let serial: String
    let state: String   // "device", "unauthorized", "offline"
    let model: String

    var id: String { serial }
    var isReady: Bool { state == "device" }
    var isWireless: Bool { serial.contains(":") }
    var isMTP: Bool { serial == MTP.serial }
    var displayName: String { model.isEmpty ? serial : model.replacingOccurrences(of: "_", with: " ") }
    var stateText: String {
        switch state {
        case "unauthorized": return "Tap Allow on the phone"
        case "offline": return "Offline"
        case "mtp-locked": return "Unlock it and choose File transfer"
        default: return state
        }
    }
}

struct RemoteFile: Identifiable, Hashable {
    let path: String
    let name: String
    let isDirectory: Bool
    let size: Int64
    let modified: Date

    var id: String { path }
    var ext: String { (name as NSString).pathExtension }
    var kind: String {
        if isDirectory { return "Folder" }
        return UTType(filenameExtension: ext)?.localizedDescription ?? "Document"
    }
}

enum ADBError: LocalizedError {
    case notFound
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .notFound: return "adb was not found. Install it with: brew install android-platform-tools"
        case .failed(let message): return message
        }
    }
}

enum ADB {
    // GUI apps don't inherit the shell PATH, so look in the usual install spots.
    static let path: String? = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "/opt/homebrew/bin/adb",
            "/usr/local/bin/adb",
            "\(home)/Library/Android/sdk/platform-tools/adb",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }()

    @discardableResult
    static func run(_ args: [String]) async throws -> String {
        guard let path else { throw ADBError.notFound }
        return try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: path)
                process.arguments = args
                let out = Pipe(), err = Pipe()
                process.standardOutput = out
                process.standardError = err
                do { try process.run() } catch { cont.resume(throwing: error); return }

                // Drain both pipes at once so a chatty stderr can't block the process.
                var errData = Data()
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global().async {
                    errData = err.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
                let outData = out.fileHandleForReading.readDataToEndOfFile()
                group.wait()
                process.waitUntilExit()

                let output = String(decoding: outData, as: UTF8.self)
                if process.terminationStatus == 0 {
                    cont.resume(returning: output)
                } else {
                    let message = String(decoding: errData, as: UTF8.self)
                    let text = (message.isEmpty ? output : message).trimmingCharacters(in: .whitespacesAndNewlines)
                    cont.resume(throwing: ADBError.failed(text.isEmpty ? "adb failed" : text))
                }
            }
        }
    }

    /// Single-quotes a string for the phone's shell.
    static func quote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    @discardableResult
    static func shell(_ serial: String, _ command: String) async throws -> String {
        try await run(["-s", serial, "shell", command])
    }

    static func devices() async throws -> [ADBDevice] {
        let out = try await run(["devices", "-l"])
        return out.split(separator: "\n").compactMap { line in
            if line.hasPrefix("List of") || line.hasPrefix("*") { return nil }
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 2 else { return nil }
            let model = parts.first { $0.hasPrefix("model:") }.map { String($0.dropFirst(6)) } ?? ""
            return ADBDevice(serial: String(parts[0]), state: String(parts[1]), model: model)
        }
    }

    static func list(_ serial: String, _ dir: String) async throws -> [RemoteFile] {
        let base = dir.hasSuffix("/") ? dir : dir + "/"
        // The trailing slash makes find follow /sdcard, which is a symlink.
        let cmd = "find \(quote(base)) -mindepth 1 -maxdepth 1 -exec stat -L -c '%F|%s|%Y|%n' {} + 2>/dev/null; true"
        let out = try await shell(serial, cmd)
        return out.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "|", maxSplits: 3, omittingEmptySubsequences: false)
            guard parts.count == 4 else { return nil }
            let name = String(parts[3].split(separator: "/").last ?? "")
            guard !name.isEmpty else { return nil }
            return RemoteFile(
                path: base + name,
                name: name,
                isDirectory: parts[0].contains("directory"),
                size: Int64(parts[1]) ?? 0,
                modified: Date(timeIntervalSince1970: TimeInterval(parts[2]) ?? 0)
            )
        }
    }

    static func pull(_ serial: String, _ remote: String, to local: URL) async throws {
        try await run(["-s", serial, "pull", "-a", remote, local.path])
    }

    static func push(_ serial: String, _ local: URL, to remote: String) async throws {
        try await run(["-s", serial, "push", local.path, remote])
        // Let the Gallery and other apps see the new file; harmless if it fails.
        let uri = URL(fileURLWithPath: remote).absoluteString
        _ = try? await shell(serial, "am broadcast -a android.intent.action.MEDIA_SCANNER_SCAN_FILE -d \(quote(uri)) >/dev/null 2>&1")
    }

    /// Returns (free, total) bytes for the phone's internal storage.
    static func storage(_ serial: String) async throws -> (Int64, Int64)? {
        let out = try await shell(serial, "df -k /sdcard/ | tail -1")
        let f = out.split(separator: " ", omittingEmptySubsequences: true)
        guard f.count >= 4, let total = Int64(f[1]), let free = Int64(f[3]) else { return nil }
        return (free * 1024, total * 1024)
    }
}

/// Sends each file operation over adb or MTP, depending on how the phone is connected.
enum Phone {
    static func list(_ serial: String, _ dir: String) async throws -> [RemoteFile] {
        serial == MTP.serial ? try await MTP.shared.list(dir) : try await ADB.list(serial, dir)
    }

    static func pull(_ serial: String, _ remote: String, to local: URL) async throws {
        if serial == MTP.serial { try await MTP.shared.pull(remote, to: local) } else { try await ADB.pull(serial, remote, to: local) }
    }

    static func push(_ serial: String, _ local: URL, to remote: String) async throws {
        if serial == MTP.serial { try await MTP.shared.push(local, to: remote) } else { try await ADB.push(serial, local, to: remote) }
    }

    static func storage(_ serial: String) async throws -> (Int64, Int64)? {
        serial == MTP.serial ? try await MTP.shared.storage() : try await ADB.storage(serial)
    }

    static func makeFolder(_ serial: String, _ path: String) async throws {
        if serial == MTP.serial {
            try await MTP.shared.makeFolder(path)
        } else {
            try await ADB.shell(serial, "mkdir -p \(ADB.quote(path))")
        }
    }

    static func rename(_ serial: String, _ path: String, to newPath: String) async throws {
        if serial == MTP.serial {
            try await MTP.shared.rename(path, to: newPath)
        } else {
            try await ADB.shell(serial, "mv -n \(ADB.quote(path)) \(ADB.quote(newPath))")
        }
    }

    static func delete(_ serial: String, _ path: String) async throws {
        if serial == MTP.serial {
            try await MTP.shared.delete(path)
        } else {
            try await ADB.shell(serial, "rm -rf \(ADB.quote(path))")
        }
    }
}
