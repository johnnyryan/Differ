import AppKit
import PDFKit

struct ChangeInfo: Identifiable, Hashable {
    let id: Int
    let kind: Change.Kind
    let removed: String
    let added: String
    let page: Int?       // 1-based page in the revised PDF (or original for pure deletions)
}

/// When a change first appeared, bracketed by Wayback Machine snapshots.
struct ChangeDating: Hashable {
    let lastAbsent: Date?        // newest snapshot known not to contain the change
    let firstSeen: Date          // oldest snapshot known to contain it
    let firstSeenURL: URL?
    let exact: Bool              // true once bisection has finished for this change
    var label: String {
        if let a = lastAbsent { return "\(DateText.short(a)) – \(DateText.short(firstSeen))" }
        return "by \(DateText.short(firstSeen))"
    }
    var longLabel: String {
        if let a = lastAbsent { return "Changed between \(DateText.medium(a)) and \(DateText.medium(firstSeen))" }
        return "Present by \(DateText.medium(firstSeen))"
    }
}

enum PieceKind { case equal, insert, delete }

struct Piece {
    let text: String
    let sep: Separator
    let kind: PieceKind
    let change: Int?
    let page: Int        // page in its own document
    let style: TextStyle
    let fromPDF: Bool
    /// Which version the paragraph break before this piece belongs to (equal when both have it).
    var breakKind: PieceKind? = nil
}

enum PieceSide { case merged, original, revised }

/// Resolves source formatting to fonts, caching by style.
final class FontBook {
    let base: CGFloat
    let serifDefault: Bool
    private var cache: [TextStyle: NSFont] = [:]
    init(base: CGFloat, serifDefault: Bool) { self.base = base; self.serifDefault = serifDefault }

    func font(_ st: TextStyle) -> NSFont {
        if let f = cache[st] { return f }
        let size = max(7, base * min(max(st.relSize, 0.7), 2.4))
        var f: NSFont
        if st.mono {
            f = NSFont.monospacedSystemFont(ofSize: size * 0.92, weight: st.bold ? .semibold : .regular)
        } else {
            var traits: NSFontTraitMask = []
            if st.bold { traits.insert(.boldFontMask) }
            if st.italic { traits.insert(.italicFontMask) }
            if let fam = st.family,
               let g = NSFontManager.shared.font(withFamily: fam, traits: traits, weight: st.bold ? 9 : 5, size: size) {
                f = g
            } else {
                let sys = NSFont.systemFont(ofSize: size, weight: st.bold ? .bold : .regular)
                var d = sys.fontDescriptor
                if serifDefault, let sd = d.withDesign(.serif) { d = sd }
                if st.italic { d = d.withSymbolicTraits(d.symbolicTraits.union(.italic)) }
                f = NSFont(descriptor: d, size: size) ?? sys
            }
        }
        cache[st] = f
        return f
    }
}

enum Palette {
    static let insert = NSColor(name: nil) { a in
        a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.42, green: 0.86, blue: 0.55, alpha: 1) : NSColor(srgbRed: 0.0, green: 0.47, blue: 0.2, alpha: 1)
    }
    static let delete = NSColor(name: nil) { a in
        a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 1.0, green: 0.48, blue: 0.46, alpha: 1) : NSColor(srgbRed: 0.75, green: 0.08, blue: 0.08, alpha: 1)
    }
    static let insertBG = NSColor(name: nil) { a in
        a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.2, green: 0.6, blue: 0.3, alpha: 0.22) : NSColor(srgbRed: 0.2, green: 0.7, blue: 0.35, alpha: 0.13)
    }
    static let deleteBG = NSColor(name: nil) { a in
        a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.8, green: 0.2, blue: 0.2, alpha: 0.22) : NSColor(srgbRed: 0.9, green: 0.2, blue: 0.2, alpha: 0.10)
    }
    static let printInsert = NSColor(srgbRed: 0.0, green: 0.45, blue: 0.18, alpha: 1)
    static let printDelete = NSColor(srgbRed: 0.75, green: 0.08, blue: 0.08, alpha: 1)
    static let dateTag = NSColor(name: nil) { a in
        a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.55, green: 0.7, blue: 1.0, alpha: 1) : NSColor(srgbRed: 0.1, green: 0.32, blue: 0.7, alpha: 1)
    }
}

extension NSAttributedString.Key {
    static let pdfDiffChange = NSAttributedString.Key("PDFDiffChangeID")
    static let pdfDiffDateTag = NSAttributedString.Key("PDFDiffDateTag")
}

final class Comparison {
    let original: SourceDoc
    let revised: SourceDoc
    let segments: [Segment]
    let changes: [Change]
    let infos: [ChangeInfo]
    let interner: [String: Int]
    let ignoreCase: Bool
    let insertions: Int, deletions: Int, replacements: Int

    private init(original: SourceDoc, revised: SourceDoc, segments: [Segment], interner: [String: Int], ignoreCase: Bool) {
        self.original = original
        self.revised = revised
        self.segments = segments
        self.interner = interner
        self.ignoreCase = ignoreCase
        let changes = segments.compactMap { if case .change(let c) = $0 { return c } else { return nil } }
        self.changes = changes
        insertions = changes.filter { $0.kind == .insertion }.count
        deletions = changes.filter { $0.kind == .deletion }.count
        replacements = changes.filter { $0.kind == .replacement }.count
        infos = changes.map { c in
            let page: Int?
            if revised.isPDF, !c.b.isEmpty { page = revised.tokens[c.b.lowerBound].page + 1 }
            else if revised.isPDF, c.b.lowerBound < revised.tokens.count { page = revised.tokens[c.b.lowerBound].page + 1 }
            else if original.isPDF, !c.a.isEmpty { page = original.tokens[c.a.lowerBound].page + 1 }
            else { page = nil }
            return ChangeInfo(id: c.id, kind: c.kind,
                              removed: Comparison.join(original.tokens[c.a]),
                              added: Comparison.join(revised.tokens[c.b]), page: page)
        }
    }

    static func run(original o: SourceDoc, revised r: SourceDoc, ignoreCase: Bool) -> Comparison {
        var o = o, r = r
        // Compare like with like: if only one web version could be narrowed to its <main> region, use whole pages.
        if o.text != nil && r.text != nil && (o.fullPage == nil) != (r.fullPage == nil) {
            o = o.usingFullPage(); r = r.usingFullPage()
        }
        var both = [o.tokens, r.tokens]
        TextExtractor.resolveHyphenation(&both)
        o.tokens = both[0]; r.tokens = both[1]
        var interner: [String: Int] = [:]
        func intern(_ t: inout [Token]) {
            for i in t.indices {
                let k = TextExtractor.normalize(t[i].text, ignoreCase: ignoreCase)
                if let id = interner[k] { t[i].key = id } else { let id = interner.count; interner[k] = id; t[i].key = id }
            }
        }
        intern(&o.tokens)
        intern(&r.tokens)
        let segs = Differ.segments(o.tokens.map(\.key), r.tokens.map(\.key))
        let c = Comparison(original: o, revised: r, segments: segs, interner: interner, ignoreCase: ignoreCase)
        c.applyPDFHighlights()
        return c
    }

    static func join<S: Sequence>(_ tokens: S) -> String where S.Element == Token {
        var s = ""
        for t in tokens {
            if !s.isEmpty && t.sep != .none { s += " " }
            s += t.text
        }
        return s
    }

    var datable: Bool { original.date != nil && revised.date != nil && !(original.ref.wayback == nil && revised.ref.wayback == nil) }

    // MARK: Merged stream

    /// The token stream to render. `.merged` interleaves deletions and insertions; `.original` and
    /// `.revised` give one version with its own changes marked (zero-width markers where the other
    /// version has text and this one does not).
    func pieces(_ side: PieceSide = .merged) -> [Piece] {
        var out: [Piece] = []
        out.reserveCapacity(original.tokens.count + revised.tokens.count)
        func piece(_ t: Token, _ doc: SourceDoc, _ kind: PieceKind, _ change: Int?, sep: Separator? = nil) -> Piece {
            let st = Int(t.style) < doc.styles.count ? doc.styles[Int(t.style)] : TextStyle()
            return Piece(text: t.text, sep: sep ?? t.sep, kind: kind, change: change, page: t.page, style: st, fromPDF: doc.isPDF)
        }
        func marker(_ id: Int) -> Piece {
            Piece(text: "", sep: .none, kind: .equal, change: id, page: 0, style: TextStyle(), fromPDF: false)
        }
        for seg in segments {
            switch seg {
            case let .equal(a, b):
                if side == .original { for t in original.tokens[a] { out.append(piece(t, original, .equal, nil)) } }
                else { for t in revised.tokens[b] { out.append(piece(t, revised, .equal, nil)) } }
            case let .change(c):
                // A paragraph break present at the start of both versions is unchanged: keep one, mark it equal.
                let sharedBreak = side == .merged && !c.a.isEmpty && !c.b.isEmpty
                    && original.tokens[c.a.lowerBound].sep == .hardBreak && revised.tokens[c.b.lowerBound].sep == .hardBreak
                if side != .revised {
                    for (i, t) in original.tokens[c.a].enumerated() {
                        var pc = piece(t, original, .delete, c.id)
                        if i == 0 && sharedBreak { pc.breakKind = .equal }
                        out.append(pc)
                    }
                    if side == .original && c.a.isEmpty { out.append(marker(c.id)) }
                }
                if side != .original {
                    for (i, t) in revised.tokens[c.b].enumerated() {
                        var sep: Separator = (i == 0 && !c.a.isEmpty && t.sep == .none && side == .merged) ? .none : t.sep
                        if i == 0 && sharedBreak { sep = .space }
                        out.append(piece(t, revised, .insert, c.id, sep: sep))
                    }
                    if side == .revised && c.b.isEmpty { out.append(marker(c.id)) }
                }
            }
        }
        return out
    }

    struct RenderOptions {
        var reflow = true
        var forPrint = false
        var showPageMarkers = true
        var dates: [Int: ChangeDating] = [:]
        var side: PieceSide = .merged
    }

    static func bullet(level: Int) -> String { ["•", "◦", "▪"][(max(level, 1) - 1) % 3] }

    static func paragraphStyle(_ st: TextStyle, minIndent: CGFloat, base: CGFloat, newItem: Bool, fromPDF: Bool) -> NSParagraphStyle {
        let ps = NSMutableParagraphStyle()
        ps.lineHeightMultiple = 1.2
        ps.paragraphSpacing = base * 0.6
        if st.heading > 0 || st.relSize >= 1.2 { ps.paragraphSpacingBefore = base * 0.55 }
        if st.centered { ps.alignment = .center }
        var left = CGFloat(st.quote) * 24
        if fromPDF, minIndent.isFinite { left += min(minIndent, 180) * base / 11 }
        if st.listLevel > 0 && !fromPDF {
            let step: CGFloat = base * 1.6
            let l = left + step * CGFloat(st.listLevel)
            ps.headIndent = l
            ps.firstLineHeadIndent = newItem ? l - step : l
            ps.tabStops = [NSTextTab(textAlignment: .left, location: l)]
            ps.defaultTabInterval = step
        } else {
            ps.headIndent = left
            ps.firstLineHeadIndent = left
        }
        return ps
    }

    /// Renders the merged "tracked changes" document (or one side of it) with the source formatting:
    /// fonts, relative sizes, bold/italic, headings, lists, alignment and indents. Deletions are struck
    /// through in red, insertions underlined in green, and dated changes carry a date tag.
    func trackedText(_ opt: RenderOptions) -> (NSAttributedString, [Int: NSRange]) {
        let base: CGFloat = opt.forPrint ? 11 : 15
        let books = [true: FontBook(base: base, serifDefault: true), false: FontBook(base: base, serifDefault: false)]
        let textColor: NSColor = opt.forPrint ? .black : .textColor
        let plainFont = books[revised.isPDF]!.font(TextStyle())

        func attrs(_ p: Piece) -> [NSAttributedString.Key: Any] {
            var a: [NSAttributedString.Key: Any] = [.font: books[p.fromPDF]!.font(p.style), .foregroundColor: textColor]
            if p.style.link && p.kind == .equal && !opt.forPrint { a[.foregroundColor] = NSColor.linkColor }
            switch p.kind {
            case .equal: break
            case .insert:
                a[.foregroundColor] = opt.forPrint ? Palette.printInsert : Palette.insert
                a[.underlineStyle] = NSUnderlineStyle.single.rawValue
                if !opt.forPrint { a[.backgroundColor] = Palette.insertBG }
            case .delete:
                a[.foregroundColor] = opt.forPrint ? Palette.printDelete : Palette.delete
                a[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
                if !opt.forPrint { a[.backgroundColor] = Palette.deleteBG }
            }
            if let id = p.change {
                a[.pdfDiffChange] = id
                if let d = opt.dates[id] { a[.toolTip] = d.longLabel }
            }
            return a
        }
        let markerAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: base * 0.68, weight: .medium),
            .foregroundColor: opt.forPrint ? NSColor.gray : NSColor.tertiaryLabelColor,
        ]
        let dateFont = NSFont.monospacedDigitSystemFont(ofSize: base * 0.7, weight: .semibold)

        let out = NSMutableAttributedString()
        var ranges: [Int: NSRange] = [:]
        let ps = pieces(opt.side)

        var paraStart = 0
        var paraFirst: Piece?
        var paraMinIndent = CGFloat.infinity
        var paraNewItem = false
        var lastItem: (Int, Int, Bool)?
        func closeParagraph() {
            guard let f = paraFirst, out.length > paraStart else { return }
            let style = Comparison.paragraphStyle(f.style, minIndent: paraMinIndent, base: base,
                                                  newItem: paraNewItem, fromPDF: f.fromPDF)
            out.addAttribute(.paragraphStyle, value: style, range: NSRange(location: paraStart, length: out.length - paraStart))
        }

        var lastPage = -1
        for (idx, p) in ps.enumerated() {
            if p.text.isEmpty, let id = p.change {
                ranges[id] = ranges[id] ?? NSRange(location: out.length, length: 0)
                continue
            }
            if p.sep == .hardBreak && out.length > 0 {
                out.append(NSAttributedString(string: "\n", attributes: [.font: plainFont, .foregroundColor: textColor]))
                closeParagraph()
                paraStart = out.length
                paraFirst = nil
                paraMinIndent = .infinity
            }
            if paraFirst == nil {
                paraFirst = p
                paraNewItem = false
                if p.style.listLevel > 0 && !p.fromPDF {
                    let item = (p.style.listLevel, p.style.item, p.kind == .delete)   // item ids differ per version
                    paraNewItem = lastItem.map { $0 != item } ?? true
                    lastItem = item
                    if paraNewItem {
                        let marker = p.style.ordered ? "\(p.style.ordinal).\t" : Comparison.bullet(level: p.style.listLevel) + "\t"
                        out.append(NSAttributedString(string: marker, attributes: [.font: books[false]!.font(TextStyle()),
                                                                                    .foregroundColor: textColor]))
                    }
                } else if p.style.listLevel == 0 {
                    lastItem = nil
                }
            }
            paraMinIndent = min(paraMinIndent, p.style.indent)

            if opt.showPageMarkers && revised.isPDF && opt.side != .original && p.kind != .delete && p.fromPDF && p.page != lastPage {
                if lastPage >= 0 { out.append(NSAttributedString(string: " ⟨p. \(p.page + 1)⟩", attributes: markerAttrs)) }
                lastPage = p.page
            }
            let start = out.length
            let a = attrs(p)
            let atParagraphStart = out.length == paraStart
            if !atParagraphStart {
                var sepAttrs = a
                if p.kind == .equal { sepAttrs[.underlineStyle] = nil; sepAttrs[.strikethroughStyle] = nil }
                switch p.sep {
                case .none, .hardBreak: break
                case .space: out.append(NSAttributedString(string: " ", attributes: sepAttrs))
                case .softBreak: out.append(NSAttributedString(string: opt.reflow ? " " : "\u{2028}", attributes: sepAttrs))
                }
            }
            out.append(NSAttributedString(string: p.text, attributes: a))
            if let id = p.change {
                let r = NSRange(location: start, length: out.length - start)
                ranges[id] = ranges[id].map { NSUnionRange($0, r) } ?? r
                let next = idx + 1 < ps.count ? ps[idx + 1].change : nil
                if next != id, let d = opt.dates[id] {
                    var da: [NSAttributedString.Key: Any] = [
                        .font: dateFont,
                        .foregroundColor: opt.forPrint ? NSColor(srgbRed: 0.1, green: 0.3, blue: 0.65, alpha: 1) : Palette.dateTag,
                        .baselineOffset: base * 0.3,
                        .pdfDiffChange: id,
                        .toolTip: d.longLabel,
                        .pdfDiffDateTag: true,
                    ]
                    if !d.exact { da[.foregroundColor] = opt.forPrint ? NSColor.gray : NSColor.secondaryLabelColor }
                    out.append(NSAttributedString(string: " [\(d.label)]", attributes: da))
                }
            }
        }
        closeParagraph()
        return (out, ranges)
    }

    /// One version, formatted, with its own changes highlighted (used for web pages in Side by Side).
    func sideText(original side: Bool) -> (NSAttributedString, [Int: NSRange]) {
        trackedText(.init(reflow: true, forPrint: false, showPageMarkers: false, dates: [:], side: side ? .original : .revised))
    }

    // MARK: PDF geometry

    /// Splits a token range into per-page character ranges.
    private func spans(_ doc: SourceDoc, _ r: Range<Int>) -> [(Int, NSRange)] {
        var out: [(Int, NSRange)] = []
        var i = r.lowerBound
        while i < r.upperBound {
            let page = doc.tokens[i].page
            let start = doc.tokens[i].range.location
            var j = i
            while j + 1 < r.upperBound && doc.tokens[j + 1].page == page { j += 1 }
            out.append((page, NSRange(location: start, length: NSMaxRange(doc.tokens[j].range) - start)))
            i = j + 1
        }
        return out
    }

    func selection(original side: Bool, change c: Change) -> (PDFSelection, Bool)? {
        let doc = side ? original : revised
        guard let pdf = doc.pdf else { return nil }
        var r = side ? c.a : c.b
        var exact = true
        if r.isEmpty {
            exact = false
            guard !doc.tokens.isEmpty else { return nil }
            let i = min(r.lowerBound, doc.tokens.count - 1)
            r = i..<(i + 1)
        }
        var result: PDFSelection?
        for (p, nr) in spans(doc, r) {
            guard let page = pdf.page(at: p), let sel = page.selection(for: nr) else { continue }
            if let res = result { res.add(sel) } else { result = sel }
        }
        return result.map { ($0, exact) }
    }

    private func applyPDFHighlights() {
        for side in [true, false] {
            let doc = side ? original : revised
            guard let pdf = doc.pdf else { continue }
            let color = side ? NSColor(srgbRed: 0.95, green: 0.25, blue: 0.25, alpha: 0.38)
                             : NSColor(srgbRed: 0.2, green: 0.8, blue: 0.35, alpha: 0.38)
            let caretColor = side ? NSColor(srgbRed: 0.1, green: 0.65, blue: 0.25, alpha: 0.9)
                                  : NSColor(srgbRed: 0.85, green: 0.15, blue: 0.15, alpha: 0.9)
            for c in changes {
                let r = side ? c.a : c.b
                if r.isEmpty {
                    // Caret where text exists only in the other version.
                    guard !doc.tokens.isEmpty else { continue }
                    let atEnd = r.lowerBound >= doc.tokens.count
                    let t = doc.tokens[min(r.lowerBound, doc.tokens.count - 1)]
                    guard let page = pdf.page(at: t.page),
                          let b = (atEnd ? PDFGeometry.rects(page, t.range).last : PDFGeometry.rects(page, t.range).first) else { continue }
                    let x = atEnd ? b.maxX + 1 : b.minX - 2
                    let ann = PDFAnnotation(bounds: NSRect(x: x - 1, y: b.minY - 1, width: 2.5, height: b.height + 2),
                                            forType: .square, withProperties: nil)
                    ann.color = caretColor
                    ann.interiorColor = caretColor
                    let border = PDFBorder(); border.lineWidth = 0
                    ann.border = border
                    ann.userName = "Differ"
                    ann.contents = side ? "Inserted in revised: \(Comparison.join(revised.tokens[c.b]))"
                                        : "Deleted from original: \(Comparison.join(original.tokens[c.a]))"
                    page.addAnnotation(ann)
                    continue
                }
                for (p, nr) in spans(doc, r) {
                    guard let page = pdf.page(at: p) else { continue }
                    for b in PDFGeometry.rects(page, nr) {
                        let ann = PDFAnnotation(bounds: b, forType: .highlight, withProperties: nil)
                        ann.color = color
                        ann.quadrilateralPoints = [
                            NSValue(point: NSPoint(x: 0, y: b.height)), NSValue(point: NSPoint(x: b.width, y: b.height)),
                            NSValue(point: NSPoint(x: 0, y: 0)), NSValue(point: NSPoint(x: b.width, y: 0)),
                        ]
                        ann.userName = "Differ"
                        page.addAnnotation(ann)
                    }
                }
            }
        }
    }
}
