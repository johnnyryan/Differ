import SwiftUI
import AppKit

/// One Wayback Machine capture of a page.
struct ArchiveCapture: Identifiable, Hashable {
    let timestamp: String
    let date: Date
    var id: String { timestamp }
}

enum WaybackIndex {
    /// Captures of `page` from the Wayback CDX index, oldest first. With `changedOnly`, consecutive
    /// captures with identical content are collapsed; otherwise at most one capture per day is listed.
    static func captures(page: String, changedOnly: Bool) async throws -> [ArchiveCapture] {
        var comps = URLComponents(string: "https://web.archive.org/cdx/search/cdx")!
        comps.queryItems = [
            URLQueryItem(name: "url", value: page),
            URLQueryItem(name: "output", value: "json"),
            URLQueryItem(name: "fl", value: "timestamp,digest,statuscode"),
            URLQueryItem(name: "filter", value: "statuscode:200"),
            URLQueryItem(name: "collapse", value: changedOnly ? "digest" : "timestamp:8"),
        ]
        let (data, _) = try await Fetcher.get(comps.url!)
        guard !data.isEmpty, let rows = try JSONSerialization.jsonObject(with: data) as? [[String]] else { return [] }
        return rows.dropFirst().compactMap { r in
            guard let ts = r.first, ts.count >= 8 else { return nil }
            return ArchiveCapture(timestamp: ts, date: WaybackRef(timestamp: ts, original: page).date)
        }
    }

    /// The underlying page address for a source: the original URL of a capture, or the live URL.
    static func pageURL(for ref: SourceRef?) -> String? {
        guard case .web(let u)? = ref else { return nil }
        return WaybackRef(u)?.original ?? u.absoluteString
    }
}

@MainActor
final class ArchiveListModel: ObservableObject {
    @Published var captures: [ArchiveCapture] = []
    @Published var loading = false
    @Published var error: String?
    private var task: Task<Void, Never>?

    func load(page: String, changedOnly: Bool) {
        task?.cancel()
        loading = true
        error = nil
        task = Task {
            do {
                let list = try await WaybackIndex.captures(page: page, changedOnly: changedOnly)
                if Task.isCancelled { return }
                captures = list
            } catch {
                if Task.isCancelled { return }
                self.error = "Could not load the archive index: \(error.localizedDescription)"
                captures = []
            }
            loading = false
        }
    }
}

/// Scrollable, year-grouped list of Wayback captures of a page; picking one fills a comparison side.
struct ArchivePicker: View {
    let page: String
    /// Which side the picked capture fills by default (the side other than the one the URL came from).
    let defaultOriginal: Bool
    let onPick: (ArchiveCapture, Bool) -> Void
    @Environment(\.dismiss) private var dismiss
    @StateObject private var list = ArchiveListModel()
    @State private var changedOnly = true
    @State private var selection: String?
    @State private var filter = ""

    private static let rowDate: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "EEE d MMM yyyy, HH:mm"; return f
    }()
    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter(); f.unitsStyle = .full; return f
    }()

    private var visible: [ArchiveCapture] {
        let q = filter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return list.captures }
        return list.captures.filter { Self.rowDate.string(from: $0.date).lowercased().contains(q) || $0.timestamp.hasPrefix(q) }
    }
    private var years: [Int] {
        Array(Set(visible.map { Calendar.current.component(.year, from: $0.date) })).sorted(by: >)
    }
    private func captures(in year: Int) -> [ArchiveCapture] {
        visible.filter { Calendar.current.component(.year, from: $0.date) == year }.sorted { $0.date > $1.date }
    }
    private var selected: ArchiveCapture? { list.captures.first { $0.id == selection } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Web archive versions").font(.title3.weight(.semibold))
                    Text(page).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                Toggle("Only when content changed", isOn: $changedOnly)
                    .toggleStyle(.checkbox)
                    .help("On: one entry per distinct version of the page. Off: one capture per day.")
            }
            HStack {
                TextField("Filter, e.g. 2024 or Mar 2025", text: $filter).textFieldStyle(.roundedBorder).frame(maxWidth: 220)
                Text(summary).font(.caption).foregroundStyle(.secondary)
            }
            Group {
                if list.loading {
                    VStack(spacing: 10) { ProgressView(); Text("Reading the Wayback Machine index…").foregroundStyle(.secondary) }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let e = list.error {
                    ContentUnavailableView("Archive unavailable", systemImage: "exclamationmark.triangle", description: Text(e))
                } else if list.captures.isEmpty {
                    ContentUnavailableView("No captures", systemImage: "clock.badge.questionmark",
                                           description: Text("The Wayback Machine has no saved copies of this address."))
                } else {
                    ScrollViewReader { proxy in
                        VStack(alignment: .leading, spacing: 6) {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 4) {
                                    Text("Jump to").font(.caption).foregroundStyle(.secondary)
                                    ForEach(years, id: \.self) { y in
                                        Button(String(y)) { withAnimation { proxy.scrollTo("year-\(y)", anchor: .top) } }
                                            .buttonStyle(.bordered).controlSize(.small)
                                    }
                                }
                            }
                            List(selection: $selection) {
                                ForEach(years, id: \.self) { y in
                                    Section(String(y)) {
                                        let caps = captures(in: y)
                                        ForEach(Array(caps.enumerated()), id: \.element.id) { i, c in
                                            row(c).tag(c.id).id(i == 0 ? "year-\(y)" : c.id)
                                        }
                                    }
                                }
                            }
                            .contextMenu(forSelectionType: String.self) { ids in
                                if let id = ids.first, let c = list.captures.first(where: { $0.id == id }) {
                                    Button("Use as Original (Older)") { pick(c, original: true) }
                                    Button("Use as Revised (Newer)") { pick(c, original: false) }
                                    Divider()
                                    Button("Open in Browser") { open(c) }
                                }
                            } primaryAction: { ids in
                                if let id = ids.first, let c = list.captures.first(where: { $0.id == id }) { pick(c, original: defaultOriginal) }
                            }
                        }
                    }
                }
            }
            .frame(minHeight: 340)
            HStack {
                Button("Open in Browser") { if let c = selected { open(c) } }.disabled(selected == nil)
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Use as Original") { if let c = selected { pick(c, original: true) } }
                    .disabled(selected == nil)
                    .keyboardShortcut(defaultOriginal ? .defaultAction : .init("o", modifiers: [.command, .option]))
                Button("Use as Revised") { if let c = selected { pick(c, original: false) } }
                    .disabled(selected == nil)
                    .keyboardShortcut(defaultOriginal ? .init("r", modifiers: [.command, .option]) : .defaultAction)
            }
        }
        .padding(18)
        .frame(width: 560, height: 600)
        .onAppear { list.load(page: page, changedOnly: changedOnly) }
        .onChange(of: changedOnly) { _, v in list.load(page: page, changedOnly: v) }
    }

    private var summary: String {
        guard !list.loading, !list.captures.isEmpty else { return "" }
        let first = list.captures.first!.date, last = list.captures.last!.date
        let n = visible.count
        return "\(n) \(changedOnly ? "versions" : "days") · \(DateText.short(first)) – \(DateText.short(last))"
    }

    private func row(_ c: ArchiveCapture) -> some View {
        HStack {
            Image(systemName: "clock.arrow.circlepath").foregroundStyle(.secondary)
            Text(Self.rowDate.string(from: c.date)).monospacedDigit()
            Spacer()
            Text(Self.relative.localizedString(for: c.date, relativeTo: Date())).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private func pick(_ c: ArchiveCapture, original: Bool) {
        onPick(c, original)
        dismiss()
    }

    private func open(_ c: ArchiveCapture) {
        NSWorkspace.shared.open(WaybackRef(timestamp: c.timestamp, original: page).viewURL)
    }
}
