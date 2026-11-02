import AppKit
import SwiftUI

/// A file's preview picture when there is one, otherwise its Finder icon.
/// `side: nil` fills the space it's given (gallery's big preview).
struct Thumb: View {
    let file: RemoteFile
    let side: CGFloat?
    let pixels: Int
    @ObservedObject private var thumbs = Thumbnails.shared

    var body: some View {
        Group {
            if let image = thumbs.image(for: file, size: pixels) {
                Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
                    .shadow(color: .black.opacity(side ?? 99 > 24 ? 0.25 : 0), radius: 2, y: 1)
            } else {
                Image(nsImage: Icons.icon(for: file)).resizable().scaledToFit()
                    .frame(maxWidth: 256, maxHeight: 256)
            }
        }
        .frame(width: side, height: side)
        .onAppear { thumbs.request(file, size: pixels, urgent: pixels >= 500) }
        .onChange(of: file) { old, new in
            thumbs.cancel(old, size: pixels)
            thumbs.request(new, size: pixels, urgent: pixels >= 500)
        }
        .onDisappear { thumbs.cancel(file, size: pixels) }
    }
}

/// Plain click selects, ⌘-click adds, double-click opens — without the delay a
/// separate double-tap gesture would add to every single click.
private extension View {
    func fileClicks(_ f: RemoteFile, _ b: Browser, single: @escaping () -> Void = {}) -> some View {
        contentShape(Rectangle()).onTapGesture {
            if NSApp.currentEvent?.clickCount ?? 1 >= 2 {
                b.openItem(f)
            } else {
                b.click(f)
                single()
            }
        }
    }

    func fileMenuAndDrag(_ f: RemoteFile, _ b: Browser) -> some View {
        contextMenu { ItemMenu(items: b.selection.contains(f.id) ? b.selectedFiles : [f]) }
            .onDrag { b.dragProvider(for: f, serial: b.selected ?? "") }
    }
}

// MARK: - Icons

struct IconsView: View {
    @EnvironmentObject var b: Browser
    let rows: [RemoteFile]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 112, maximum: 132), spacing: 6)], spacing: 14) {
                ForEach(rows) { f in IconCell(file: f) }
            }
            .padding(14)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .contentShape(Rectangle())
        .onTapGesture { b.selection = [] }
        .contextMenu { ItemMenu(items: []) }
    }
}

private struct IconCell: View {
    @EnvironmentObject var b: Browser
    let file: RemoteFile

    var body: some View {
        let selected = b.selection.contains(file.id)
        VStack(spacing: 4) {
            Thumb(file: file, side: 72, pixels: 160)
                .padding(5)
                .background(selected ? Color.primary.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 7))
            Text(file.name)
                .font(.callout)
                .lineLimit(2)
                .truncationMode(.middle)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .foregroundColor(selected ? .white : .primary)
                .background(selected ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 4))
        }
        .frame(width: 112)
        .fileClicks(file, b)
        .fileMenuAndDrag(file, b)
    }
}

// MARK: - Columns

struct ColumnsView: View {
    @EnvironmentObject var b: Browser
    let rows: [RemoteFile]

    /// Every folder from the top of storage down to the current one, one column each.
    private var columnPaths: [String] {
        let root = b.path.hasPrefix("/sdcard") ? "/sdcard" : "/"
        var paths = [root]
        var current = root
        let rest = b.path == root ? "" : String(b.path.dropFirst(root == "/" ? 1 : root.count + 1))
        for part in rest.split(separator: "/") {
            current = current == "/" ? "/\(part)" : "\(current)/\(part)"
            paths.append(current)
        }
        return paths
    }

    private var previewFile: RemoteFile? {
        guard b.selection.count == 1, let id = b.selection.first else { return nil }
        return rows.first { $0.id == id && !$0.isDirectory }
    }

    var body: some View {
        let paths = columnPaths
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: 0) {
                    ForEach(Array(paths.enumerated()), id: \.element) { i, p in
                        ColumnList(
                            dir: p,
                            items: p == b.path ? rows : tidy(b.listings[p] ?? []),
                            onPath: i + 1 < paths.count ? paths[i + 1] : nil)
                            .frame(width: 240)
                        Divider()
                    }
                    if let f = previewFile {
                        PreviewPane(file: f, big: false).frame(width: 300)
                    }
                    Color.clear.frame(width: 1).id("end")
                }
            }
            .background(Color(nsColor: .textBackgroundColor))
            .onAppear {
                paths.forEach(b.ensureListing)
                proxy.scrollTo("end", anchor: .trailing)
            }
            .onChange(of: b.path) {
                columnPaths.forEach(b.ensureListing)
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("end", anchor: .trailing) }
            }
            .onChange(of: b.selection) { proxy.scrollTo("end", anchor: .trailing) }
        }
    }

    private func tidy(_ list: [RemoteFile]) -> [RemoteFile] {
        let shown = list.filter { b.showHidden || !$0.name.hasPrefix(".") }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return shown.filter(\.isDirectory) + shown.filter { !$0.isDirectory }
    }
}

private struct ColumnList: View {
    @EnvironmentObject var b: Browser
    let dir: String
    let items: [RemoteFile]
    /// The child folder that the next column is showing, highlighted like Finder does.
    let onPath: String?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(items) { f in row(f) }
            }
            .padding(.vertical, 4)
        }
        .overlay {
            if items.isEmpty && b.loadingPaths.contains(dir) {
                ProgressView().controlSize(.small).allowsHitTesting(false)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if dir != b.path { b.navigate(to: dir) }
            b.selection = []
        }
    }

    private func row(_ f: RemoteFile) -> some View {
        let highlighted = f.path == onPath || (dir == b.path && b.selection.contains(f.id))
        return HStack(spacing: 6) {
            Thumb(file: f, side: 16, pixels: 64)
            Text(f.name).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 4)
            if f.isDirectory {
                Image(systemName: "chevron.right").font(.caption2.weight(.semibold))
                    .foregroundColor(highlighted ? .white : .secondary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .foregroundColor(highlighted ? .white : .primary)
        .background(highlighted ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 5))
        .padding(.horizontal, 5)
        .contentShape(Rectangle())
        .onTapGesture {
            if f.isDirectory {
                b.navigate(to: f.path)
            } else if NSApp.currentEvent?.clickCount ?? 1 >= 2 {
                b.openItem(f)
            } else {
                if dir != b.path { b.navigate(to: dir) }
                b.click(f)
            }
        }
        .fileMenuAndDrag(f, b)
    }
}

// MARK: - Gallery

struct GalleryView: View {
    @EnvironmentObject var b: Browser
    let rows: [RemoteFile]

    private var current: RemoteFile? { rows.first { b.selection.contains($0.id) } ?? rows.first }

    var body: some View {
        VStack(spacing: 0) {
            if let f = current {
                PreviewPane(file: f, big: true)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Spacer()
            }
            Divider()
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 6) {
                        ForEach(rows) { f in
                            let selected = f.id == current?.id
                            Thumb(file: f, side: 58, pixels: 160)
                                .padding(4)
                                .background(selected ? Color.accentColor.opacity(0.25) : .clear,
                                            in: RoundedRectangle(cornerRadius: 6))
                                .overlay(RoundedRectangle(cornerRadius: 6)
                                    .strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 2))
                                .help(f.name)
                                .id(f.id)
                                .fileClicks(f, b)
                                .fileMenuAndDrag(f, b)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                }
                .frame(height: 86)
                .onAppear { if let id = current?.id { proxy.scrollTo(id, anchor: .center) } }
                .onChange(of: b.selection) {
                    if let id = current?.id { withAnimation { proxy.scrollTo(id, anchor: .center) } }
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .focusable()
        .focusEffectDisabled()
        .onMoveCommand { direction in
            switch direction {
            case .left, .up: step(-1)
            case .right, .down: step(1)
            @unknown default: break
            }
        }
    }

    private func step(_ delta: Int) {
        guard let c = current, let i = rows.firstIndex(of: c) else { return }
        let j = max(0, min(rows.count - 1, i + delta))
        b.selection = [rows[j].id]
    }
}

// MARK: - Preview

/// Large preview with the file's details, used by gallery and by column view.
struct PreviewPane: View {
    @EnvironmentObject var b: Browser
    let file: RemoteFile
    let big: Bool

    var body: some View {
        let layout = big ? AnyLayout(HStackLayout(spacing: 24)) : AnyLayout(VStackLayout(spacing: 14))
        layout {
            Thumb(file: file, side: big ? nil : 220, pixels: big ? 1200 : 500)
                .frame(maxWidth: big ? .infinity : nil, maxHeight: big ? .infinity : nil)
                .contentShape(Rectangle())
                .onTapGesture { if NSApp.currentEvent?.clickCount ?? 1 >= 2 { b.openItem(file) } }
                .fileMenuAndDrag(file, b)
            VStack(alignment: big ? .leading : .center, spacing: 6) {
                Text(file.name).font(.headline).lineLimit(3).multilineTextAlignment(big ? .leading : .center)
                Text(file.isDirectory ? "Folder" : "\(file.kind) — \(bytes(file.size))")
                    .foregroundStyle(.secondary)
                Text(file.modified, format: .dateTime.day().month(.wide).year().hour().minute())
                    .foregroundStyle(.secondary)
                Button(file.isDirectory ? "Open Folder" : "Open") { b.openItem(file) }
                    .padding(.top, 6)
            }
            .font(.callout)
            .frame(width: big ? 220 : nil)
        }
        .padding(big ? 24 : 16)
    }
}
