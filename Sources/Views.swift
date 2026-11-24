import SwiftUI
import AppKit
import PDFKit

// MARK: - Root

struct ContentView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 260, ideal: 330, max: 520)
        } detail: {
            DetailView()
        }
        .navigationTitle(title)
        .toolbar { MainToolbar() }
        .onDrop(of: DropHelper.types, isTargeted: nil) { providers in
            DropHelper.load(providers) { model.accept($0, preferOriginal: nil) }
            return true
        }
        .alert("Something went wrong", isPresented: Binding(get: { model.errorMessage != nil },
                                                            set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(model.errorMessage ?? "") }
    }

    private var title: String {
        guard let c = model.comparison, !model.showingSources else { return "Differ" }
        return "\(c.original.title) → \(c.revised.title)"
    }
}

struct MainToolbar: ToolbarContent {
    @EnvironmentObject var model: AppModel

    var body: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button { model.showingSources.toggle() } label: { Label("Sources", systemImage: "doc.on.doc") }
                .help("Choose the versions to compare")
                .disabled(model.comparison == nil)
        }
        ToolbarItem(placement: .principal) {
            Picker("View", selection: $model.mode) {
                ForEach(model.availableModes) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .disabled(model.comparison == nil || model.showingSources)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button { model.step(-1) } label: { Label("Previous Change", systemImage: "chevron.up") }
                .help("Previous change (⌘[)")
                .disabled(model.comparison == nil)
            Button { model.step(1) } label: { Label("Next Change", systemImage: "chevron.down") }
                .help("Next change (⌘])")
                .disabled(model.comparison == nil)
            Button { model.swap() } label: { Label("Swap", systemImage: "arrow.left.arrow.right") }
                .help("Swap original and revised")
                .disabled(model.original == nil || model.revised == nil)
            Menu {
                Toggle("Reflow Lines into Paragraphs", isOn: $model.reflow)
                Toggle("Annotate Changes with Dates (Wayback Machine)", isOn: $model.annotateDates)
                Toggle("Ignore Case", isOn: Binding(get: { model.ignoreCase },
                                                    set: { model.ignoreCase = $0; model.compare() }))
            } label: { Label("Options", systemImage: "slider.horizontal.3") }
            Menu {
                Button("Word Document with Tracked Changes…") { model.exportDocx() }
                Button("PDF of Tracked Changes…") { model.exportPDF() }
                if model.comparison?.original.isPDF == true || model.comparison?.revised.isPDF == true {
                    Divider()
                    if model.comparison?.original.isPDF == true {
                        Button("Original PDF with Highlights…") { model.exportAnnotated(original: true) }
                    }
                    if model.comparison?.revised.isPDF == true {
                        Button("Revised PDF with Highlights…") { model.exportAnnotated(original: false) }
                        Button("Revised PDF with Changes Marked (On Page)…") { model.exportOnPage() }
                    }
                }
            } label: { Label("Export", systemImage: "square.and.arrow.up") }
                .disabled(model.comparison == nil)
        }
    }
}

// MARK: - Detail

struct DetailView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ZStack {
            if model.showingSources || model.comparison == nil {
                ScrollView { SourcesPanel().frame(maxWidth: .infinity) }
            } else if let c = model.comparison {
                VStack(spacing: 0) {
                    HeaderBar(c: c)
                    Divider()
                    switch model.mode {
                    case .tracked: TrackedView(c: c)
                    case .sideBySide: SideBySideView(c: c)
                    case .onPage:
                        if c.revised.isPDF { PDFOnPageView(c: c).id(ObjectIdentifier(c)) }
                        else { WebPageView(c: c).id(ObjectIdentifier(c)) }
                    }
                }
            }
            if model.isWorking {
                VStack(spacing: 12) {
                    ProgressView()
                    Text(model.status ?? "Working…").font(.callout).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(24)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            }
        }
    }
}

struct HeaderBar: View {
    @EnvironmentObject var model: AppModel
    let c: Comparison

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                SourceChip(doc: c.original, tint: Color(nsColor: Palette.delete))
                Image(systemName: "arrow.right").foregroundStyle(.secondary)
                SourceChip(doc: c.revised, tint: Color(nsColor: Palette.insert))
                Spacer(minLength: 12)
                Stat(value: c.insertions, label: "added", color: Color(nsColor: Palette.insert))
                Stat(value: c.deletions, label: "removed", color: Color(nsColor: Palette.delete))
                Stat(value: c.replacements, label: "replaced", color: .orange)
            }
            if !model.annotateDates && ChangeDater.check(c) == nil {
                HStack(spacing: 6) {
                    Image(systemName: "calendar.badge.clock").foregroundStyle(.secondary)
                    Text("Change dates are off.")
                    Button("Date changes from the Wayback Machine") { model.annotateDates = true }
                        .buttonStyle(.link)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            if let s = model.datingStatus {
                HStack(spacing: 6) {
                    if model.isDating { ProgressView().controlSize(.small) }
                    Image(systemName: "calendar.badge.clock").foregroundStyle(Color(nsColor: Palette.dateTag))
                    Text(s).lineLimit(2)
                    if model.isDating { Button("Stop") { model.cancelDating() }.controlSize(.small) }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            let notes = warnings
            if !notes.isEmpty {
                Label(notes.joined(separator: " "), systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .background(.bar)
    }

    private var warnings: [String] {
        var w: [String] = []
        for (d, n) in [(c.original, "original"), (c.revised, "revised")] where d.pagesWithoutText > 0 {
            w.append("\(d.pagesWithoutText) page(s) of the \(n) have no text layer and were skipped.")
        }
        if c.changes.isEmpty { w.append("No differences found.") }
        return w
    }
}

struct SourceChip: View {
    let doc: SourceDoc
    let tint: Color
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: doc.ref.symbol).foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 0) {
                Text(doc.title).font(.callout.weight(.medium)).lineLimit(1).truncationMode(.middle)
                Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .help(doc.ref.url.isFileURL ? doc.ref.url.path : doc.ref.url.absoluteString)
        .frame(maxWidth: 300, alignment: .leading)
    }
    private var subtitle: String {
        var parts: [String] = []
        switch doc.ref {
        case .file: parts.append("PDF · \(doc.pdf?.pageCount ?? 0) pages")
        case .web(let u):
            if WaybackRef(u) != nil { parts.append("Archived \(doc.date.map(DateText.medium) ?? "")") }
            else { parts.append("Live · fetched \(doc.date.map(DateText.medium) ?? "")") }
            if doc.isPDF { parts.append("PDF") }
            if doc.rendered { parts.append("rendered, expanded") }
        }
        return parts.joined(separator: " · ")
    }
}

struct Stat: View {
    let value: Int, label: String, color: Color
    var body: some View {
        HStack(spacing: 3) {
            Text("\(value)").font(.callout.monospacedDigit().weight(.semibold)).foregroundStyle(color)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Sources panel

struct SourcesPanel: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 22) {
            VStack(spacing: 6) {
                Text("Compare two versions").font(.largeTitle.weight(.semibold))
                Text("Drop PDFs or web pages. Drag a link from the browser's address bar, or paste one.\nWayback Machine links (web.archive.org/web/…) work as well as live pages.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
            HStack(alignment: .top, spacing: 14) {
                SourceCard(isOriginal: true)
                Button { model.swap() } label: { Image(systemName: "arrow.left.arrow.right") }
                    .buttonStyle(.borderless).help("Swap").padding(.top, 100)
                SourceCard(isOriginal: false)
            }
            HStack(spacing: 18) {
                Toggle("Ignore case", isOn: $model.ignoreCase)
                Toggle("Date changes", isOn: $model.annotateDates)
                    .help("Check Wayback Machine captures between the two versions and tag each change with when it first appeared. Slower.")
                Picker("Render pages with JavaScript:", selection: $model.renderMode) {
                    ForEach(RenderMode.allCases) { Text($0.label).tag($0) }
                }
                .fixedSize()
                .help("Web pages are read from their HTML, which already includes text in collapsed sections. Rendering also runs the page's scripts and clicks every expand/accordion control, for pages that load hidden text on demand.")
            }
            HStack {
                if model.comparison != nil {
                    Button("Back to Comparison") { model.showingSources = false }
                }
                Button("Compare") { if model.applyURLFields() { model.compare() } }
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.large)
                    .disabled(model.original == nil || model.revised == nil || model.isWorking)
            }
            VStack(alignment: .leading, spacing: 8) {
                Tip(symbol: "rectangle.expand.vertical", text: "Collapsed sections, accordions and “read more” panels are expanded automatically, so the whole text of a page such as a privacy policy is compared.")
                Tip(symbol: "calendar.badge.clock", text: "Optional: with “Date changes” on, Wayback Machine captures between the two versions are checked to tag each change with when it first appeared.")
                Tip(symbol: "doc.badge.arrow.up", text: "Export to Word gives real tracked changes that can be accepted or rejected, dated by when they appeared.")
            }
            .frame(maxWidth: 640, alignment: .leading)
            .padding(14)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
            Text(Credit.text)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.top, 6)
        }
        .padding(32)
        .frame(maxWidth: 940)
    }
}

struct Tip: View {
    let symbol: String, text: String
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 20)
            Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct SourceCard: View {
    @EnvironmentObject var model: AppModel
    let isOriginal: Bool
    private var urlText: Binding<String> { isOriginal ? $model.originalURLText : $model.revisedURLText }
    @State private var showArchive = false

    /// The page whose archive versions can be listed: from the typed address, else from the chosen source.
    private var archivePage: String? {
        if let typed = SourceRef(string: urlText.wrappedValue), let p = WaybackIndex.pageURL(for: typed) { return p }
        return WaybackIndex.pageURL(for: ref)
    }
    @State private var targeted = false

    private var ref: SourceRef? { isOriginal ? model.original : model.revised }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(isOriginal ? "ORIGINAL · OLDER" : "REVISED · NEWER")
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ZStack {
                RoundedRectangle(cornerRadius: 14)
                    .fill(targeted ? Color.accentColor.opacity(0.12) : Color(nsColor: .controlBackgroundColor))
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(style: StrokeStyle(lineWidth: targeted ? 2 : 1.5, dash: ref == nil ? [6, 4] : []))
                    .foregroundStyle(targeted ? Color.accentColor : Color.secondary.opacity(0.45))
                if let ref {
                    VStack(spacing: 8) {
                        Image(systemName: ref.symbol).font(.system(size: 34, weight: .light))
                            .foregroundStyle(Color(nsColor: isOriginal ? Palette.delete : Palette.insert))
                        Text(ref.displayName).font(.headline).lineLimit(2).multilineTextAlignment(.center)
                            .truncationMode(.middle)
                        Text(ref.kindLabel).font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(14)
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "arrow.down.doc").font(.system(size: 34, weight: .light)).foregroundStyle(.tertiary)
                        Text("Drop a PDF or a link here").foregroundStyle(.secondary)
                        Text("or click to choose a PDF").font(.caption).foregroundStyle(.tertiary)
                    }
                }
            }
            .frame(height: 180)
            .contentShape(Rectangle())
            .onTapGesture { model.choosePDF(original: isOriginal) }
            .onDrop(of: DropHelper.types, isTargeted: $targeted) { providers in
                DropHelper.load(providers) { urls in
                    model.accept(urls, preferOriginal: urls.count == 1 ? isOriginal : nil)
                }
                return true
            }
            HStack(spacing: 6) {
                TextField("https://… or web.archive.org/web/…", text: urlText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(apply)
                Button("Use", action: apply).disabled(urlText.wrappedValue.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Button { showArchive = true } label: {
                Label("Web archive versions…", systemImage: "clock.arrow.circlepath")
            }
            .buttonStyle(.link)
            .disabled(archivePage == nil)
            .help("List the Wayback Machine's saved versions of this page and pick one to compare against")
            .sheet(isPresented: $showArchive) {
                if let page = archivePage {
                    ArchivePicker(page: page, defaultOriginal: !isOriginal) { capture, toOriginal in
                        // Keep the typed address for this side, then fill the chosen side with the capture.
                        _ = model.applyURLFields()
                        model.useArchiveCapture(capture, page: page, original: toOriginal)
                    }
                }
            }
        }
        .frame(minWidth: 280, maxWidth: 400)
        .onAppear { syncField(ref) }
        .onChange(of: ref) { _, new in syncField(new) }
    }

    private func syncField(_ r: SourceRef?) {
        switch r {
        case .web(let u)?: urlText.wrappedValue = u.absoluteString
        case .file?: urlText.wrappedValue = ""
        case nil: break
        }
    }

    private func apply() {
        guard let r = SourceRef(string: urlText.wrappedValue) else {
            model.errorMessage = "That doesn't look like a web address or a PDF path."
            return
        }
        model.set(r, original: isOriginal)
    }
}

// MARK: - Sidebar

struct SidebarView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        if model.comparison == nil {
            ContentUnavailableView("No Comparison", systemImage: "doc.on.doc",
                                   description: Text("Choose two versions to see their changes here."))
        } else {
            let list = model.visibleInfos
            VStack(spacing: 0) {
                Picker("Filter", selection: $model.filter) {
                    ForEach(ChangeFilter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, 10).padding(.vertical, 8)
                List(selection: $model.selectedChangeID) {
                    ForEach(list) { info in
                        ChangeRow(info: info, dating: model.dates[info.id]).tag(info.id)
                    }
                }
                .searchable(text: $model.search, placement: .sidebar, prompt: "Search changes")
                Divider()
                Text("\(list.count) change\(list.count == 1 ? "" : "s")")
                    .font(.caption).foregroundStyle(.secondary).padding(6)
            }
        }
    }
}

struct ChangeRow: View {
    let info: ChangeInfo
    let dating: ChangeDating?

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon).foregroundStyle(color).font(.body).frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                if !info.removed.isEmpty {
                    Text(info.removed).strikethrough().foregroundStyle(Color(nsColor: Palette.delete)).lineLimit(3)
                }
                if !info.added.isEmpty {
                    Text(info.added).underline().foregroundStyle(Color(nsColor: Palette.insert)).lineLimit(3)
                }
                HStack(spacing: 8) {
                    if let p = info.page { Text("Page \(p)") }
                    if let d = dating {
                        Label(d.label, systemImage: d.exact ? "calendar" : "hourglass")
                            .foregroundStyle(d.exact ? Color(nsColor: Palette.dateTag) : .secondary)
                            .help(d.longLabel)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
        .contextMenu {
            if let u = dating?.firstSeenURL, !u.isFileURL {
                Button("Open First Version Containing This Change") { NSWorkspace.shared.open(u) }
            }
            Button("Copy Added Text") { copy(info.added) }.disabled(info.added.isEmpty)
            Button("Copy Removed Text") { copy(info.removed) }.disabled(info.removed.isEmpty)
        }
    }

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
    private var icon: String {
        switch info.kind {
        case .insertion: return "plus.circle.fill"
        case .deletion: return "minus.circle.fill"
        case .replacement: return "arrow.triangle.2.circlepath.circle.fill"
        }
    }
    private var color: Color {
        switch info.kind {
        case .insertion: return Color(nsColor: Palette.insert)
        case .deletion: return Color(nsColor: Palette.delete)
        case .replacement: return .orange
        }
    }
}

// MARK: - Tracked changes

struct TrackedView: View {
    @EnvironmentObject var model: AppModel
    let c: Comparison
    var body: some View {
        let dates = model.dates
        let reflow = model.reflow
        ChangeTextView(
            resetKey: ObjectIdentifier(c),
            contentKey: [AnyHashable(ObjectIdentifier(c)), AnyHashable(reflow), AnyHashable(model.datesVersion)],
            build: { c.trackedText(.init(reflow: reflow, dates: dates)) },
            selectedID: model.selectedChangeID,
            readableWidth: 820,
            onClick: { model.selectedChangeID = $0 })
    }
}

struct SideBySideView: View {
    @EnvironmentObject var model: AppModel
    let c: Comparison

    var body: some View {
        HSplitView {
            pane(original: true)
            pane(original: false)
        }
    }

    @ViewBuilder
    private func pane(original side: Bool) -> some View {
        let doc = side ? c.original : c.revised
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Circle().fill(Color(nsColor: side ? Palette.delete : Palette.insert)).frame(width: 8, height: 8)
                Text(side ? "Original" : "Revised").font(.caption.weight(.semibold))
                Text(side ? "removed text highlighted" : "added text highlighted").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(doc.title).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(.bar)
            Divider()
            if let pdf = doc.pdf {
                let change = model.selectedChangeID.flatMap { id in c.changes.first { $0.id == id } }
                PDFPane(document: pdf,
                        target: change.flatMap { c.selection(original: side, change: $0) },
                        targetID: model.selectedChangeID)
            } else {
                ChangeTextView(
                    resetKey: ObjectIdentifier(c),
                    contentKey: [AnyHashable(ObjectIdentifier(c)), AnyHashable(side)],
                    build: { c.sideText(original: side) },
                    selectedID: model.selectedChangeID,
                    readableWidth: nil,
                    onClick: { model.selectedChangeID = $0 })
            }
        }
        .frame(minWidth: 280)
    }
}

// MARK: - AppKit bridges

final class ClickableTextView: NSTextView {
    var onClickChange: ((Int) -> Void)?
    var readableWidth: CGFloat?

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        guard selectedRange().length == 0, let lm = layoutManager, let tc = textContainer,
              let storage = textStorage, storage.length > 0 else { return }
        var p = convert(event.locationInWindow, from: nil)
        p.x -= textContainerOrigin.x; p.y -= textContainerOrigin.y
        let glyph = lm.glyphIndex(for: p, in: tc)
        let rect = lm.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: tc)
        guard rect.insetBy(dx: -2, dy: -2).contains(p) else { return }
        let idx = lm.characterIndexForGlyph(at: glyph)
        guard idx < storage.length, let id = storage.attribute(.pdfDiffChange, at: idx, effectiveRange: nil) as? Int else { return }
        onClickChange?(id)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        let x: CGFloat = readableWidth.map { max(28, (newSize.width - $0) / 2) } ?? 16
        let y: CGFloat = readableWidth == nil ? 12 : 28
        if abs(textContainerInset.width - x) > 0.5 || textContainerInset.height != y {
            textContainerInset = NSSize(width: x, height: y)
        }
    }
}

struct ChangeTextView: NSViewRepresentable {
    let resetKey: AnyHashable
    let contentKey: [AnyHashable]
    let build: () -> (NSAttributedString, [Int: NSRange])
    let selectedID: Int?
    let readableWidth: CGFloat?
    let onClick: (Int) -> Void

    final class Coordinator {
        var resetKey: AnyHashable?
        var contentKey: [AnyHashable]?
        var ranges: [Int: NSRange] = [:]
        var selected: Int?
    }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let storage = NSTextStorage()
        let lm = NSLayoutManager()
        lm.allowsNonContiguousLayout = true
        storage.addLayoutManager(lm)
        let tc = NSTextContainer(containerSize: NSSize(width: 800, height: CGFloat.greatestFiniteMagnitude))
        tc.widthTracksTextView = true
        lm.addTextContainer(tc)
        let tv = ClickableTextView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), textContainer: tc)
        tv.readableWidth = readableWidth
        tv.isEditable = false
        tv.isSelectable = true
        tv.isRichText = true
        tv.drawsBackground = true
        tv.backgroundColor = .textBackgroundColor
        tv.minSize = .zero
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.usesFindBar = true
        tv.isIncrementalSearchingEnabled = true
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.documentView = tv
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? ClickableTextView else { return }
        let coord = context.coordinator
        tv.onClickChange = { id in coord.selected = id; onClick(id) }

        if coord.contentKey != contentKey {
            let sameDoc = coord.resetKey == resetKey
            let origin = scroll.contentView.bounds.origin
            // Anchor on the text at the top of the view, ignoring date tags, so the reading position
            // holds when dating inserts tags above it.
            let anchor = sameDoc ? topAnchor(tv, scroll) : nil
            let (s, r) = build()
            tv.textStorage?.setAttributedString(s)
            coord.ranges = r
            coord.contentKey = contentKey
            coord.resetKey = resetKey
            if sameDoc {
                if let anchor, let y = restoreY(anchor, tv) {
                    scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, y)))
                } else {
                    scroll.contentView.scroll(to: origin)
                }
                scroll.reflectScrolledClipView(scroll.contentView)
            } else {
                tv.scroll(.zero)
                coord.selected = nil
            }
        }
        if coord.selected != selectedID {
            coord.selected = selectedID
            if let id = selectedID, let r = coord.ranges[id] {
                DispatchQueue.main.async { reveal(r, tv: tv, scroll: scroll) }
            }
        }
    }

    /// Content offset (characters excluding date tags) of the first visible character, and how far
    /// its line sits from the top of the view.
    private func topAnchor(_ tv: NSTextView, _ scroll: NSScrollView) -> (content: Int, offset: CGFloat)? {
        guard let lm = tv.layoutManager, let tc = tv.textContainer, let st = tv.textStorage, st.length > 0 else { return nil }
        let top = scroll.contentView.bounds.minY
        let p = NSPoint(x: 1, y: max(0, top - tv.textContainerOrigin.y + 1))
        let g = lm.glyphIndex(for: p, in: tc)
        let ci = min(lm.characterIndexForGlyph(at: g), st.length - 1)
        var tags = 0
        st.enumerateAttribute(.pdfDiffDateTag, in: NSRange(location: 0, length: ci)) { v, r, _ in if v != nil { tags += r.length } }
        let line = lm.lineFragmentRect(forGlyphAt: g, effectiveRange: nil)
        return (ci - tags, line.minY + tv.textContainerOrigin.y - top)
    }

    private func restoreY(_ a: (content: Int, offset: CGFloat), _ tv: NSTextView) -> CGFloat? {
        guard let lm = tv.layoutManager, let st = tv.textStorage, st.length > 0 else { return nil }
        var remaining = a.content
        var index = st.length - 1
        var found = false
        st.enumerateAttribute(.pdfDiffDateTag, in: NSRange(location: 0, length: st.length)) { v, r, stop in
            if v != nil { return }
            if remaining < r.length { index = r.location + remaining; found = true; stop.pointee = true }
            else { remaining -= r.length }
        }
        if !found { index = st.length - 1 }
        lm.ensureLayout(forCharacterRange: NSRange(location: index, length: 1))
        let g = lm.glyphIndexForCharacter(at: index)
        let line = lm.lineFragmentRect(forGlyphAt: g, effectiveRange: nil)
        return line.minY + tv.textContainerOrigin.y - a.offset
    }

    private func reveal(_ r: NSRange, tv: NSTextView, scroll: NSScrollView) {
        guard let lm = tv.layoutManager, let tc = tv.textContainer, let len = tv.textStorage?.length else { return }
        let loc = min(r.location, max(0, len - 1))
        let range = NSRange(location: loc, length: max(1, min(r.length, len - loc)))
        lm.ensureLayout(forCharacterRange: range)
        let g = lm.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        var rect = lm.boundingRect(forGlyphRange: g, in: tc)
        rect.origin.x += tv.textContainerOrigin.x
        rect.origin.y += tv.textContainerOrigin.y
        let visH = scroll.contentView.bounds.height
        let y = max(0, min(rect.midY - visH / 2, tv.frame.height - visH))
        scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
        scroll.reflectScrolledClipView(scroll.contentView)
        if r.length > 0 { tv.showFindIndicator(for: range) }
    }
}

struct PDFPane: NSViewRepresentable {
    let document: PDFDocument
    let target: (PDFSelection, Bool)?
    let targetID: Int?

    final class Coordinator: NSObject, PDFViewDelegate {
        var targetID: Int?
        /// Clicking a web link inside the PDF does nothing (no URLs are opened).
        func pdfViewWillClick(onLink sender: PDFView, with url: URL) {}
    }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> PDFView {
        let v = PDFView()
        v.delegate = context.coordinator
        v.autoScales = true
        v.displayMode = .singlePageContinuous
        v.displaysPageBreaks = true
        v.backgroundColor = .underPageBackgroundColor
        v.document = document
        return v
    }

    func updateNSView(_ v: PDFView, context: Context) {
        if v.document !== document { v.document = document; context.coordinator.targetID = nil }
        guard context.coordinator.targetID != targetID else { return }
        context.coordinator.targetID = targetID
        guard let (sel, exact) = target else { v.clearSelection(); return }
        DispatchQueue.main.async {
            if exact { v.setCurrentSelection(sel, animate: true) } else { v.clearSelection() }
            if let page = sel.pages.first {
                let b = sel.bounds(for: page)
                v.go(to: NSRect(x: b.minX, y: b.minY - 120, width: b.width, height: b.height + 240), on: page)
            }
        }
    }
}
