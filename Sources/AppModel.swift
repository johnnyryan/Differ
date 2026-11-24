import SwiftUI
import AppKit
import UniformTypeIdentifiers

enum ViewMode: String, CaseIterable, Identifiable {
    case tracked = "Tracked Changes", sideBySide = "Side by Side", onPage = "On Page"
    var id: String { rawValue }
}

enum ChangeFilter: String, CaseIterable, Identifiable {
    case all = "All", added = "Added", removed = "Removed", replaced = "Replaced"
    var id: String { rawValue }
}

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published var original: SourceRef?
    @Published var revised: SourceRef?
    @Published var comparison: Comparison?
    @Published var showingSources = true
    @Published var isWorking = false
    @Published var status: String?
    @Published var errorMessage: String?
    @Published var selectedChangeID: Int?
    @Published var mode: ViewMode = .tracked
    @Published var ignoreCase = false
    @Published var reflow = true
    @Published var renderMode: RenderMode = .auto
    @Published var dates: [Int: ChangeDating] = [:]
    @Published var datesVersion = 0
    @Published var datingStatus: String?
    @Published var isDating = false
    /// Date each change from intermediate Wayback captures and tag it inline. Off by default; remembered.
    @Published var annotateDates = UserDefaults.standard.bool(forKey: "annotateDates") {
        didSet {
            guard annotateDates != oldValue else { return }
            UserDefaults.standard.set(annotateDates, forKey: "annotateDates")
            if annotateDates {
                if let c = comparison, !isDating { startDating(c) }
            } else {
                datingTask?.cancel()
                isDating = false
                dates = [:]
                datesVersion += 1
                datingStatus = nil
            }
        }
    }
    @Published var filter: ChangeFilter = .all
    @Published var search = ""
    @Published var originalURLText = ""
    @Published var revisedURLText = ""

    private var task: Task<Void, Never>?
    private var datingTask: Task<Void, Never>?

    // MARK: Sources

    func set(_ ref: SourceRef, original isOriginal: Bool) {
        if isOriginal { original = ref } else { revised = ref }
    }

    /// Accepts dropped/opened URLs. Two at once fill both sides, ordered oldest → newest where dates are known.
    func accept(_ urls: [URL], preferOriginal: Bool?) {
        let refs = urls.compactMap(SourceRef.init(url:))
        if refs.isEmpty {
            if !urls.isEmpty { errorMessage = "Only PDF files and web addresses (http/https) can be compared." }
            return
        }
        if refs.count >= 2 {
            var pair = Array(refs.prefix(2))
            func when(_ r: SourceRef) -> Date? {
                if let w = r.wayback { return w.date }
                if case .web = r { return .distantFuture }
                return nil
            }
            if let d0 = when(pair[0]), let d1 = when(pair[1]), d0 > d1 { pair.swapAt(0, 1) }
            original = pair[0]; revised = pair[1]
        } else if let p = preferOriginal {
            set(refs[0], original: p)
        } else if original == nil {
            original = refs[0]
        } else {
            revised = refs[0]
        }
        if original != nil && revised != nil { compare() } else { showingSources = true }
    }

    /// Uses whatever is typed in the URL fields, even if Return was not pressed. Returns false on an invalid entry.
    func applyURLFields() -> Bool {
        for (text, isOriginal) in [(originalURLText, true), (revisedURLText, false)] {
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.isEmpty { continue }
            guard let r = SourceRef(string: t) else {
                errorMessage = "“\(t)” doesn't look like a web address or a PDF path."
                return false
            }
            let current = isOriginal ? original : revised
            if current != r { set(r, original: isOriginal) }
        }
        return true
    }

    /// Fills one side with a Wayback capture of `page`, comparing straight away if both sides are set.
    func useArchiveCapture(_ c: ArchiveCapture, page: String, original isOriginal: Bool) {
        let ref = SourceRef.web(WaybackRef(timestamp: c.timestamp, original: page).viewURL)
        set(ref, original: isOriginal)
        if isOriginal { originalURLText = ref.url.absoluteString } else { revisedURLText = ref.url.absoluteString }
        if original != nil && revised != nil { compare() }
    }

    func choosePDF(original isOriginal: Bool) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = true
        panel.message = isOriginal ? "Choose the original (older) PDF" : "Choose the revised (newer) PDF"
        guard panel.runModal() == .OK else { return }
        if panel.urls.count >= 2 { accept(panel.urls, preferOriginal: nil) }
        else if let u = panel.urls.first { accept([u], preferOriginal: isOriginal) }
    }

    func swap() {
        (original, revised) = (revised, original)
        if original != nil && revised != nil { compare() }
    }

    // MARK: Comparing

    func compare() {
        guard let o = original, let r = revised else { return }
        task?.cancel(); datingTask?.cancel()
        isWorking = true; isDating = false
        errorMessage = nil
        status = "Loading \(o.displayName) and \(r.displayName)…"
        dates = [:]; datesVersion += 1; datingStatus = nil
        let ic = ignoreCase, rm = renderMode
        task = Task {
            do {
                async let od = SourceLoader.load(o, render: rm)
                async let rd = SourceLoader.load(r, render: rm)
                let (a, b) = try await (od, rd)
                if Task.isCancelled { return }
                self.status = "Comparing…"
                let comp = await Task.detached(priority: .userInitiated) {
                    Comparison.run(original: a, revised: b, ignoreCase: ic)
                }.value
                if Task.isCancelled { return }
                self.comparison = comp
                self.dates = [:]
                self.datesVersion += 1
                self.datingStatus = nil
                self.selectedChangeID = nil
                self.isWorking = false
                self.status = nil
                self.showingSources = false
                if self.annotateDates { self.startDating(comp) }
            } catch {
                if Task.isCancelled { return }
                self.errorMessage = error.localizedDescription
                self.isWorking = false
                self.status = nil
            }
        }
    }

    private func startDating(_ c: Comparison) {
        if let reason = ChangeDater.check(c) {
            // Only worth mentioning for web comparisons.
            if reason != .notWeb { datingStatus = reason.rawValue }
            return
        }
        isDating = true
        let rm = renderMode
        datingTask = Task {
            await ChangeDater.run(c, render: rm,
                progress: { [weak self] s in
                    guard let self, self.comparison === c, !Task.isCancelled else { return }
                    self.datingStatus = s
                },
                update: { [weak self] d in
                    guard let self, self.comparison === c, !Task.isCancelled else { return }
                    self.dates = d
                    self.datesVersion += 1
                })
            if self.comparison === c { self.isDating = false }
        }
    }

    func cancelDating() {
        datingTask?.cancel()
        isDating = false
        datingStatus = "Dating stopped."
    }

    /// On Page shows the newer version's own rendering: its PDF pages, or the web page itself.
    var availableModes: [ViewMode] { ViewMode.allCases }

    // MARK: Navigation

    var visibleInfos: [ChangeInfo] {
        guard let c = comparison else { return [] }
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return c.infos.filter { i in
            switch filter {
            case .all: break
            case .added: if i.kind != .insertion { return false }
            case .removed: if i.kind != .deletion { return false }
            case .replaced: if i.kind != .replacement { return false }
            }
            if q.isEmpty { return true }
            return i.added.lowercased().contains(q) || i.removed.lowercased().contains(q)
        }
    }

    func step(_ delta: Int) {
        let list = visibleInfos
        guard !list.isEmpty else { return }
        if let cur = selectedChangeID, let i = list.firstIndex(where: { $0.id == cur }) {
            selectedChangeID = list[max(0, min(list.count - 1, i + delta))].id
        } else {
            selectedChangeID = (delta >= 0 ? list.first : list.last)?.id
        }
    }

    // MARK: Export

    private func savePanel(_ name: String, _ type: UTType) -> URL? {
        let p = NSSavePanel()
        p.nameFieldStringValue = name
        p.allowedContentTypes = [type]
        p.canCreateDirectories = true
        return p.runModal() == .OK ? p.url : nil
    }

    private var baseName: String {
        guard let c = comparison else { return "Comparison" }
        let n = c.revised.title.replacingOccurrences(of: "/", with: "-")
        let trimmed = (n as NSString).deletingPathExtension
        return String(trimmed.prefix(80)) + " – compared"
    }

    func exportDocx() {
        guard let c = comparison, let url = savePanel(baseName + ".docx", UTType(filenameExtension: "docx") ?? .data) else { return }
        do { try DocxExporter.export(c, dates: dates, to: url); NSWorkspace.shared.activateFileViewerSelecting([url]) }
        catch { errorMessage = "Export failed: \(error.localizedDescription)" }
    }

    func exportPDF() {
        guard let c = comparison, let url = savePanel(baseName + ".pdf", .pdf) else { return }
        do { try TrackedPDFExporter.export(c, dates: dates, reflow: reflow, to: url); NSWorkspace.shared.activateFileViewerSelecting([url]) }
        catch { errorMessage = "Export failed: \(error.localizedDescription)" }
    }

    /// The newer PDF with additions highlighted and removals as margin notes (the On Page view).
    func exportOnPage() {
        guard let c = comparison, c.revised.isPDF else { return }
        let name = (c.revised.title as NSString).deletingPathExtension + " – changes marked.pdf"
        guard let url = savePanel(name, .pdf) else { return }
        guard let marks = c.buildOnPage(dates: dates), marks.document.write(to: url) else {
            errorMessage = "Export failed."; return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func exportAnnotated(original side: Bool) {
        guard let c = comparison else { return }
        let doc = side ? c.original : c.revised
        let name = (doc.title as NSString).deletingPathExtension + " – highlighted.pdf"
        guard let url = savePanel(name, .pdf) else { return }
        do { try AnnotatedPDFExporter.export(doc, to: url); NSWorkspace.shared.activateFileViewerSelecting([url]) }
        catch { errorMessage = "Export failed: \(error.localizedDescription)" }
    }
}

// MARK: - Drag and drop

enum DropHelper {
    static let types: [UTType] = [.fileURL, .url, .plainText]

    static func load(_ providers: [NSItemProvider], completion: @escaping @MainActor ([URL]) -> Void) {
        let group = DispatchGroup()
        let lock = NSLock()
        var found: [(Int, Int, URL)] = []
        for (i, p) in providers.enumerated() {
            if p.canLoadObject(ofClass: URL.self) {
                group.enter()
                _ = p.loadObject(ofClass: URL.self) { u, _ in
                    if let u { lock.lock(); found.append((i, 0, u)); lock.unlock() }
                    group.leave()
                }
            } else if p.canLoadObject(ofClass: String.self) {
                group.enter()
                _ = p.loadObject(ofClass: String.self) { s, _ in
                    let parts = (s ?? "").split(whereSeparator: { $0.isWhitespace })
                    for (k, part) in parts.enumerated() {
                        if let ref = SourceRef(string: String(part)) { lock.lock(); found.append((i, k, ref.url)); lock.unlock() }
                    }
                    group.leave()
                }
            }
        }
        group.notify(queue: .main) {
            let urls = found.sorted { ($0.0, $0.1) < ($1.0, $1.1) }.map(\.2)
            MainActor.assumeIsolated { completion(urls) }
        }
    }
}
