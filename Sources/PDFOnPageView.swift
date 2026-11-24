import SwiftUI
import AppKit
import PDFKit

/// The newer PDF's own pages, marked up like a reviewed document: added text highlighted in green on
/// the page, removed text shown in red notes in a markup margin added to the right of each page,
/// with a leader line to the spot where it was removed.
struct OnPageMarks {
    let document: PDFDocument
    let targets: [Int: (page: Int, rect: CGRect)]
    let annotationIDs: [ObjectIdentifier: Int]
    let marked: Int
}

extension Comparison {
    static let markupMargin: CGFloat = 220

    func buildOnPage(dates: [Int: ChangeDating]) -> OnPageMarks? {
        guard let src = revised.pdf, let data = src.dataRepresentation(), let doc = PDFDocument(data: data) else { return nil }
        // Start from the clean pages: drop the Side by Side highlights carried over in the copy.
        for p in 0..<doc.pageCount {
            guard let page = doc.page(at: p) else { continue }
            for a in page.annotations where a.userName == "Differ" { page.removeAnnotation(a) }
        }
        // Widen every page with a markup margin on the right.
        var column: [Int: (x: CGFloat, top: CGFloat, bottom: CGFloat)] = [:]
        for p in 0..<doc.pageCount {
            guard let page = doc.page(at: p) else { continue }
            let media = page.bounds(for: .mediaBox)
            let crop = page.bounds(for: .cropBox)
            let newMaxX = crop.maxX + Self.markupMargin
            page.setBounds(NSRect(x: media.minX, y: media.minY, width: max(media.width, newMaxX - media.minX), height: media.height), for: .mediaBox)
            page.setBounds(NSRect(x: crop.minX, y: crop.minY, width: crop.width + Self.markupMargin, height: crop.height), for: .cropBox)
            column[p] = (crop.maxX + 14, crop.maxY - 18, crop.minY + 18)
        }

        let green = NSColor(srgbRed: 0.2, green: 0.78, blue: 0.35, alpha: 0.42)
        let red = NSColor(srgbRed: 0.78, green: 0.1, blue: 0.1, alpha: 1)
        let noteWidth = Self.markupMargin - 26
        var targets: [Int: (page: Int, rect: CGRect)] = [:]
        var ids: [ObjectIdentifier: Int] = [:]
        struct Note { let id: Int; let anchor: CGPoint; let label: String; let removed: String; let date: String? }
        var notes: [Int: [Note]] = [:]
        var marked = 0

        func tag(_ a: PDFAnnotation, _ id: Int) { a.userName = "Differ"; ids[ObjectIdentifier(a)] = id }
        func bounds(_ tokens: [Token], _ r: Range<Int>) -> [(Int, CGRect)] {
            var out: [(Int, CGRect)] = []
            var i = r.lowerBound
            while i < r.upperBound {
                let pIndex = tokens[i].page
                var j = i
                while j + 1 < r.upperBound && tokens[j + 1].page == pIndex { j += 1 }
                let nr = NSRange(location: tokens[i].range.location, length: NSMaxRange(tokens[j].range) - tokens[i].range.location)
                // Measure on the original pages: token offsets refer to their text, which re-saving the copy can reorder.
                if let page = src.page(at: pIndex) {
                    for b in PDFGeometry.rects(page, nr) { out.append((pIndex, b)) }
                }
                i = j + 1
            }
            return out
        }

        let toks = revised.tokens
        for c in changes {
            var didMark = false
            // Added text: green highlight on the page.
            if !c.b.isEmpty {
                for (p, b) in bounds(toks, c.b) {
                    guard let page = doc.page(at: p) else { continue }
                    let a = PDFAnnotation(bounds: b, forType: .highlight, withProperties: nil)
                    a.color = green
                    a.quadrilateralPoints = [NSValue(point: NSPoint(x: 0, y: b.height)), NSValue(point: NSPoint(x: b.width, y: b.height)),
                                             NSValue(point: .zero), NSValue(point: NSPoint(x: b.width, y: 0))]
                    a.contents = "Added: " + Comparison.join(toks[c.b])
                    tag(a, c.id)
                    page.addAnnotation(a)
                    if targets[c.id] == nil { targets[c.id] = (p, b) }
                    didMark = true
                }
            }
            // Removed text: caret where it was, note in the margin.
            if !c.a.isEmpty, !toks.isEmpty {
                let atEnd = c.b.lowerBound >= toks.count
                let t = toks[min(c.b.lowerBound, toks.count - 1)]
                let tokenRects = src.page(at: t.page).map { PDFGeometry.rects($0, t.range) } ?? []
                if let page = doc.page(at: t.page), let b = (atEnd ? tokenRects.last : tokenRects.first) {
                    let x = atEnd ? b.maxX + 1 : b.minX - 1.5
                    let caret = PDFAnnotation(bounds: NSRect(x: x - 1, y: b.minY - 1, width: 2.2, height: b.height + 2), forType: .square, withProperties: nil)
                    caret.color = red
                    caret.interiorColor = red
                    let border = PDFBorder(); border.lineWidth = 0; caret.border = border
                    tag(caret, c.id)
                    page.addAnnotation(caret)
                    if targets[c.id] == nil { targets[c.id] = (t.page, b) }
                    let removed = Comparison.join(original.tokens[c.a])
                    notes[t.page, default: []].append(Note(id: c.id, anchor: CGPoint(x: x, y: b.midY),
                                                           label: c.b.isEmpty ? "Removed: " : "Replaced: ",
                                                           removed: removed, date: dates[c.id]?.label))
                    didMark = true
                }
            }
            if didMark { marked += 1 }
        }

        // Lay the notes out down the margin, near their anchors, never overlapping and never off the page.
        // When a page has more removals than the margin can hold, notes are shortened, then set smaller,
        // then neighbouring notes are merged into one (each keeps its own leader line).
        struct Box { var items: [Note] }
        func noteText(_ box: Box, maxChars: Int) -> String {
            box.items.map { n in
                let body = n.removed.count > maxChars ? String(n.removed.prefix(maxChars)).trimmingCharacters(in: .whitespaces) + "…" : n.removed
                return (box.items.count > 1 ? "• " : "") + n.label + body + (n.date.map { "  [\($0)]" } ?? "")
            }.joined(separator: "\n")
        }
        func height(_ text: String, _ font: NSFont) -> CGFloat {
            let r = NSAttributedString(string: text, attributes: [.font: font])
                .boundingRect(with: NSSize(width: noteWidth - 12, height: 10_000), options: [.usesLineFragmentOrigin, .usesFontLeading])
            // Free-text notes add their own inset and line spacing; leave room so nothing is clipped.
            return ceil(r.height * 1.18) + 10
        }
        let gap: CGFloat = 4
        for (p, list) in notes {
            guard let page = doc.page(at: p), let col = column[p] else { continue }
            let available = col.top - col.bottom
            var boxes = list.sorted { $0.anchor.y > $1.anchor.y }.map { Box(items: [$0]) }
            let steps: [(Int, CGFloat)] = [(420, 7.5), (160, 7.5), (80, 7), (40, 6.5), (24, 6)]
            var chosen = steps.last!
            var heights: [CGFloat] = []
            func measure(_ step: (Int, CGFloat)) -> CGFloat {
                let f = NSFont.systemFont(ofSize: step.1)
                heights = boxes.map { height(noteText($0, maxChars: step.0), f) }
                return heights.reduce(0, +) + gap * CGFloat(max(0, boxes.count - 1))
            }
            var fits = false
            for step in steps where measure(step) <= available { chosen = step; fits = true; break }
            // Still too tall at the smallest setting: merge neighbours until it fits.
            while !fits && boxes.count > 1 {
                var merged: [Box] = []
                var i = 0
                while i < boxes.count {
                    if i + 1 < boxes.count { merged.append(Box(items: boxes[i].items + boxes[i + 1].items)); i += 2 }
                    else { merged.append(boxes[i]); i += 1 }
                }
                boxes = merged
                fits = measure(chosen) <= available
            }
            _ = measure(chosen)
            let font = NSFont.systemFont(ofSize: chosen.1)
            // Space still needed below each box, so earlier boxes never push later ones off the page.
            var below = [CGFloat](repeating: 0, count: boxes.count + 1)
            for k in stride(from: boxes.count - 1, through: 0, by: -1) { below[k] = below[k + 1] + heights[k] + gap }
            var nextTop = col.top
            for (k, box) in boxes.enumerated() {
                let h = heights[k]
                let anchorY = box.items.map(\.anchor.y).reduce(0, +) / CGFloat(box.items.count)
                var top = min(anchorY + h / 2, nextTop)
                top = max(top, col.bottom + below[k] - gap)          // leave room for the rest
                top = min(top, nextTop)
                let rect = NSRect(x: col.x, y: top - h, width: noteWidth, height: h)
                nextTop = rect.minY - gap

                let note = PDFAnnotation(bounds: rect, forType: .freeText, withProperties: nil)
                note.contents = noteText(box, maxChars: chosen.0)
                note.font = font
                note.fontColor = red
                note.color = NSColor(srgbRed: 1, green: 0.93, blue: 0.93, alpha: 1)
                note.alignment = .left
                let nb = PDFBorder(); nb.lineWidth = 0.6; note.border = nb
                tag(note, box.items[0].id)
                page.addAnnotation(note)

                // A leader line from each removal point to its note.
                for n in box.items {
                    let start = n.anchor, end = CGPoint(x: rect.minX, y: min(max(n.anchor.y, rect.minY + 4), rect.maxY - 4))
                    let lb = NSRect(x: min(start.x, end.x) - 2, y: min(start.y, end.y) - 2,
                                    width: abs(end.x - start.x) + 4, height: abs(end.y - start.y) + 4)
                    let line = PDFAnnotation(bounds: lb, forType: .line, withProperties: nil)
                    line.startPoint = NSPoint(x: start.x - lb.minX, y: start.y - lb.minY)
                    line.endPoint = NSPoint(x: end.x - lb.minX, y: end.y - lb.minY)
                    line.color = red.withAlphaComponent(0.5)
                    let lbd = PDFBorder(); lbd.lineWidth = 0.5; lbd.style = .dashed; lbd.dashPattern = [2, 2]; line.border = lbd
                    tag(line, n.id)
                    page.addAnnotation(line)
                }
            }
        }
        return OnPageMarks(document: doc, targets: targets, annotationIDs: ids, marked: marked)
    }
}

struct PDFOnPageView: View {
    @EnvironmentObject var model: AppModel
    let c: Comparison
    @State private var marks: OnPageMarks?

    var body: some View {
        ZStack(alignment: .top) {
            if let m = marks {
                OnPagePDFRepresentable(marks: m, selectedID: model.selectedChangeID,
                                       onClick: { model.selectedChangeID = $0 })
            } else {
                VStack(spacing: 10) { ProgressView(); Text("Marking changes on the pages…").foregroundStyle(.secondary) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            HStack(spacing: 14) {
                Label("Added", systemImage: "highlighter").foregroundStyle(Color(nsColor: Palette.insert))
                Label("Removed – notes in the margin", systemImage: "text.badge.minus").foregroundStyle(Color(nsColor: Palette.delete))
                if let m = marks, m.marked < c.changes.count {
                    Text("\(m.marked) of \(c.changes.count) changes placed").foregroundStyle(.secondary)
                }
            }
            .font(.caption)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(.regularMaterial, in: Capsule())
            .padding(8)
        }
        .task(id: [AnyHashable(ObjectIdentifier(c)), AnyHashable(model.datesVersion)]) {
            let dates = model.dates
            let comparison = c
            let built = await Task.detached(priority: .userInitiated) { comparison.buildOnPage(dates: dates) }.value
            if !Task.isCancelled { marks = built }
        }
    }
}

final class MarkupPDFView: PDFView {
    var onAnnotation: ((PDFAnnotation) -> Bool)?
    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let page = page(for: p, nearest: false) {
            let pp = convert(p, to: page)
            if let a = page.annotation(at: pp), onAnnotation?(a) == true { return }
        }
        super.mouseDown(with: event)
    }
}

struct OnPagePDFRepresentable: NSViewRepresentable {
    let marks: OnPageMarks
    let selectedID: Int?
    let onClick: (Int) -> Void

    final class Coordinator: NSObject, PDFViewDelegate {
        var shown: Int?
        var document: PDFDocument?
        /// Clicking a web link in the PDF does nothing.
        func pdfViewWillClick(onLink sender: PDFView, with url: URL) {}
    }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> MarkupPDFView {
        let v = MarkupPDFView()
        v.autoScales = true
        v.displayMode = .singlePageContinuous
        v.displaysPageBreaks = true
        v.backgroundColor = .underPageBackgroundColor
        v.delegate = context.coordinator
        return v
    }

    func updateNSView(_ v: MarkupPDFView, context: Context) {
        let co = context.coordinator
        if co.document !== marks.document {
            co.document = marks.document
            v.document = marks.document
            co.shown = nil
        }
        let ids = marks.annotationIDs
        v.onAnnotation = { a in
            guard let id = ids[ObjectIdentifier(a)] else { return false }
            co.shown = id   // already where the user clicked; no jump
            onClick(id)
            return true
        }
        guard co.shown != selectedID else { return }
        co.shown = selectedID
        guard let id = selectedID, let t = marks.targets[id], let page = marks.document.page(at: t.page) else { return }
        DispatchQueue.main.async {
            v.go(to: NSRect(x: t.rect.minX, y: t.rect.minY - 140, width: t.rect.width, height: t.rect.height + 280), on: page)
            // Brief flash of the change.
            let flash = PDFAnnotation(bounds: t.rect.insetBy(dx: -3, dy: -3), forType: .square, withProperties: nil)
            flash.color = NSColor.systemOrange
            let b = PDFBorder(); b.lineWidth = 2; flash.border = b
            page.addAnnotation(flash)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { page.removeAnnotation(flash) }
        }
    }
}
