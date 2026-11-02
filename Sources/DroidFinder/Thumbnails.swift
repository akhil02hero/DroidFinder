import AppKit
import CryptoKit
import QuickLookThumbnailing
import UniformTypeIdentifiers

/// Fetches previews of photos, short videos and PDFs from the phone. Files are pulled
/// into ~/Library/Caches/DroidFinder (keyed by path, size and date) and Quick Look
/// draws the thumbnail, a few at a time so scrolling a big Camera folder stays smooth.
@MainActor
final class Thumbnails: ObservableObject {
    static let shared = Thumbnails()

    @Published private(set) var images: [String: NSImage] = [:]
    private var requested = Set<String>()
    private var queue: [(RemoteFile, String)] = []
    private var running = 0
    private let maxRunning = 3

    nonisolated static let cacheDir: URL = {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DroidFinder", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// Only fetch kinds Quick Look can preview, and skip files too big to pull just for a picture.
    static func canPreview(_ f: RemoteFile) -> Bool {
        guard !f.isDirectory, let type = UTType(filenameExtension: f.ext) else { return false }
        if type.conforms(to: .image) { return f.size <= 60_000_000 }
        if type.conforms(to: .pdf) { return f.size <= 30_000_000 }
        if type.conforms(to: .movie) { return f.size <= 15_000_000 }
        return false
    }

    static func key(_ f: RemoteFile, _ size: Int) -> String { "\(f.id)#\(size)" }

    func image(for f: RemoteFile, size: Int) -> NSImage? { images[Self.key(f, size)] }

    /// `urgent` jumps the queue — used for the big preview the person is looking at.
    func request(_ f: RemoteFile, size: Int, urgent: Bool = false) {
        guard Self.canPreview(f), let serial = Browser.shared.selected else { return }
        let key = Self.key(f, size)
        guard !requested.contains(key) else { return }
        requested.insert(key)
        let item = (f, "\(serial)|\(size)")
        if urgent { queue.insert(item, at: 0) } else { queue.append(item) }
        pump()
    }

    /// Drops a request that hasn't started, e.g. a cell scrolled out of view.
    func cancel(_ f: RemoteFile, size: Int) {
        guard let i = queue.firstIndex(where: { $0.0.id == f.id && $0.1.hasSuffix("|\(size)") }) else { return }
        queue.remove(at: i)
        requested.remove(Self.key(f, size))
    }

    private func pump() {
        while running < maxRunning, !queue.isEmpty {
            let (f, tag) = queue.removeFirst()
            let parts = tag.split(separator: "|")
            let serial = String(parts[0]), size = Int(parts[1]) ?? 128
            running += 1
            Task {
                if let image = await Self.render(f, serial: serial, size: size) {
                    images[Self.key(f, size)] = image
                }
                running -= 1
                pump()
            }
        }
    }

    /// The phone file copied to the Mac cache, pulling it only the first time.
    nonisolated static func localCopy(of f: RemoteFile, serial: String) async throws -> URL {
        let digest = SHA256.hash(data: Data("\(serial)\(f.path)\(f.size)\(f.modified.timeIntervalSince1970)".utf8))
        let name = digest.prefix(16).map { String(format: "%02x", $0) }.joined()
        let url = cacheDir.appendingPathComponent(f.ext.isEmpty ? name : "\(name).\(f.ext)")
        if !FileManager.default.fileExists(atPath: url.path) {
            let partial = url.appendingPathExtension("part")
            try await ADB.pull(serial, f.path, to: partial)
            try? FileManager.default.removeItem(at: url)
            try FileManager.default.moveItem(at: partial, to: url)
        }
        return url
    }

    nonisolated private static func render(_ f: RemoteFile, serial: String, size: Int) async -> NSImage? {
        guard let url = try? await localCopy(of: f, serial: serial) else { return nil }
        let request = QLThumbnailGenerator.Request(
            fileAt: url, size: CGSize(width: size, height: size), scale: 2, representationTypes: .thumbnail)
        return try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).nsImage
    }
}
