import Foundation
import AppKit
import PDFKit

// MARK: - Tokens

enum Separator: Equatable {
    case none, space, softBreak, hardBreak
}

struct Token {
    let text: String
    var key: Int = 0
    let page: Int
    let range: NSRange      // UTF-16 range inside page.string
    var sep: Separator      // whitespace preceding this token
    var style: Int32 = 0    // index into the owning document's style table
    /// Set when this word was rejoined across a line-end hyphen; lets the comparison split it back
    /// into a hyphenated compound ("long-term") when the documents show that is the real word.
    var hyphen: HyphenParts? = nil
}

struct HyphenParts {
    let first: String, second: String
    let firstRange: NSRange, markRange: NSRange, secondRange: NSRange
}

/// Visual formatting carried from the source document, per token.
struct TextStyle: Hashable {
    var family: String? = nil       // font family used in the source (PDF)
    var relSize: CGFloat = 1        // size relative to the document's body text
    var bold = false
    var italic = false
    var mono = false
    var link = false
    var heading = 0                 // 1–6 for HTML headings
    var listLevel = 0
    var ordered = false
    var ordinal = 0                 // item number within its list
    var item = 0                    // unique id of the list item (HTML), so adjacent items never merge
    var quote = 0
    var centered = false
    var indent: CGFloat = 0         // left indent in points (PDF)
}

struct StyleTable {
    private(set) var styles: [TextStyle] = [TextStyle()]
    private var index: [TextStyle: Int32] = [TextStyle(): 0]
    mutating func id(_ s: TextStyle) -> Int32 {
        if let i = index[s] { return i }
        let i = Int32(styles.count)
        styles.append(s); index[s] = i
        return i
    }
}

/// Per-page line statistics used to tell paragraph ends from ordinary line wraps:
/// a short last line, or (for PDFs) extra vertical space / indentation before the next line.
struct PageLines {
    var lineLenAtNewline: [Int: Int] = [:]
    var hardAtNewline = Set<Int>()
    var typical = 0
    var lineRanges: [NSRange] = []
    var lineRects: [NSRect?] = []

    init(_ ns: NSString, page: PDFPage? = nil) {
        var lens: [Int] = []
        var lines: [(newline: Int, range: NSRange)] = []
        var start = 0
        let len = ns.length
        var i = 0
        while i <= len {
            let atEnd = i == len
            let c: unichar = atEnd ? 10 : ns.character(at: i)
            if c == 10 || c == 13 || c == 0x2028 || c == 0x2029 {
                let r = NSRange(location: start, length: i - start)
                let l = ns.substring(with: r).trimmingCharacters(in: .whitespaces).count
                if !atEnd { lineLenAtNewline[i] = l }
                if l > 0 { lens.append(l); lines.append((atEnd ? -1 : i, r)) }
                start = i + 1
            }
            i += 1
        }
        lens.sort()
        typical = lens.isEmpty ? 0 : lens[min(lens.count - 1, Int(Double(lens.count) * 0.9))]

        // Geometry: compare the step between consecutive lines with the typical line pitch.
        guard let page else { return }
        let rects: [NSRect?] = lines.map { l in
            guard let sel = page.selection(for: l.range) else { return nil }
            let b = sel.bounds(for: page)
            return b.isEmpty ? nil : b
        }
        lineRanges = lines.map(\.range)
        lineRects = rects
        guard lines.count > 2 else { return }
        var steps: [CGFloat] = []
        for k in 0..<(lines.count - 1) {
            if let a = rects[k], let b = rects[k + 1], a.minY > b.minY, a.maxX > b.minX, b.maxX > a.minX {
                steps.append(a.minY - b.minY)
            }
        }
        guard steps.count >= 2 else { return }
        steps.sort()
        let pitch = steps[steps.count / 4]   // ordinary line spacing; paragraph gaps sit above this
        let colRight = rects.compactMap { $0?.maxX }.max() ?? 0
        for k in 0..<(lines.count - 1) where lines[k].newline >= 0 {
            guard let a = rects[k], let b = rects[k + 1] else { continue }
            let step = a.minY - b.minY
            let sameColumn = a.maxX > b.minX && b.maxX > a.minX
            // First-line indent: b is indented and the line after it returns to a's margin
            // (a hanging indent, where later lines stay indented, is not a new paragraph).
            var firstLineIndent = false
            if b.minX > a.minX + 6 && b.minX - a.minX < 60, a.maxX < colRight - 20,
               k + 2 < lines.count, let c = rects[k + 2] {
                firstLineIndent = abs(c.minX - a.minX) < 3 && (b.minY - c.minY) <= pitch * 1.4
            }
            if !sameColumn || step > pitch * 1.4 || step < 0 || firstLineIndent {
                hardAtNewline.insert(lines[k].newline)
            }
        }
    }
}

enum TextExtractor {
    static let tokenRegex = try! NSRegularExpression(
        pattern: #"[\p{L}\p{N}\p{M}]+(?:['’][\p{L}\p{N}\p{M}]+)*|[^\s\p{L}\p{N}\p{M}]"#)

    /// Tokens for every page of a PDF, the number of pages with no text layer, and the style table
    /// (font family, relative size, bold/italic, centring and indentation taken from the page).
    static func pdfTokens(_ doc: PDFDocument) -> ([Token], Int, [TextStyle]) {
        struct Raw { var family: String?; var size: CGFloat; var bold: Bool; var italic: Bool; var mono: Bool
                     var centered: Bool; var indent: CGFloat }
        var tokens: [Token] = []
        var raws: [Raw] = []
        var empty = 0
        var lastLineShort: [Int: Bool] = [:]   // page → its last text line ends well short of the column
        for p in 0..<doc.pageCount {
            guard let page = doc.page(at: p) else { continue }
            let s = blankBulletOnlyLines(page.string ?? "")
            let ns = s as NSString
            let lines = PageLines(ns, page: page)
            let before = tokens.count
            if !appendTokens(from: s, page: p, to: &tokens, lines: lines) { empty += 1; continue }

            let attr = page.attributedString
            let attrOK = attr != nil && attr!.length == ns.length
            // Text column of this page, for centring and indentation.
            let rects = lines.lineRects.compactMap { $0 }
            let colMin = rects.map(\.minX).min() ?? 0
            let colMax = rects.map(\.maxX).max() ?? 0
            if let last = rects.last { lastLineShort[p] = last.maxX < colMax - 40 }
            var li = 0
            for t in tokens[before...] {
                var raw = Raw(family: nil, size: 12, bold: false, italic: false, mono: false, centered: false, indent: 0)
                if attrOK, t.range.location < attr!.length,
                   let f = attr!.attribute(.font, at: t.range.location, effectiveRange: nil) as? NSFont {
                    raw.size = f.pointSize
                    let name = f.fontName.lowercased()
                    let traits = f.fontDescriptor.symbolicTraits
                    raw.bold = traits.contains(.bold) || ["bold", "black", "heavy", "semibold", "demi"].contains { name.contains($0) }
                    raw.italic = traits.contains(.italic) || name.contains("italic") || name.contains("oblique")
                    raw.mono = traits.contains(.monoSpace)
                    var fam = f.familyName ?? f.fontName
                    if let plus = fam.firstIndex(of: "+"), fam.distance(from: fam.startIndex, to: plus) == 6 {
                        fam = String(fam[fam.index(after: plus)...])
                    }
                    raw.family = fam
                }
                while li + 1 < lines.lineRanges.count && NSMaxRange(lines.lineRanges[li]) <= t.range.location { li += 1 }
                if li < lines.lineRects.count, let r = lines.lineRects[li], colMax - colMin > 100 {
                    let left = r.minX - colMin, right = colMax - r.maxX
                    if left > 15 && right > 15 && abs(left - right) < max(8, (colMax - colMin) * 0.06) {
                        raw.centered = true
                    } else if left > 6 {
                        raw.indent = (left / 6).rounded() * 6
                    }
                }
                raws.append(raw)
            }
        }
        // Body size = the size used by most words.
        var hist: [Int: Int] = [:]
        for r in raws { hist[Int((r.size * 2).rounded()), default: 0] += 1 }
        let body = CGFloat(hist.max { $0.value < $1.value }?.key ?? 24) / 2
        var table = StyleTable()
        for i in tokens.indices {
            let r = raws[i]
            let rel = body > 0 ? ((r.size / body) * 20).rounded() / 20 : 1
            tokens[i].style = table.id(TextStyle(family: r.family, relSize: rel, bold: r.bold, italic: r.italic,
                                                 mono: r.mono, centered: r.centered, indent: r.indent))
        }
        // A page's first word starts a new paragraph when the formatting changes (e.g. a heading) or
        // when the previous page ended with a short line closing a sentence.
        for i in tokens.indices.dropFirst() where tokens[i].page != tokens[i - 1].page {
            let a = table.styles[Int(tokens[i - 1].style)], b = table.styles[Int(tokens[i].style)]
            let styleChange = abs(a.relSize - b.relSize) > 0.1 || a.bold != b.bold
            let sentenceEnd = [".", "?", "!", ":"].contains(tokens[i - 1].text)
            if styleChange || (sentenceEnd && lastLineShort[tokens[i - 1].page] == true) { tokens[i].sep = .hardBreak }
        }
        return (tokens, empty, table.styles)
    }

    private static var wordCache: [String: Bool] = [:]
    private static let wordLock = NSLock()

    /// Whether the spell checker knows `w` (cached; NSSpellChecker is used on the main thread).
    static func isKnownWord(_ w: String) -> Bool {
        let key = w.lowercased()
        wordLock.lock(); let cached = wordCache[key]; wordLock.unlock()
        if let cached { return cached }
        let check: () -> Bool = {
            // Pin the language: automatic multi-language checking accepts fragments such as "ple".
            ["en_GB", "en_US"].contains { lang in
                var wc = 0
                return NSSpellChecker.shared.checkSpelling(of: key, startingAt: 0, language: lang, wrap: false,
                                                           inSpellDocumentWithTag: 0, wordCount: &wc).location == NSNotFound
            }
        }
        let ok = Thread.isMainThread ? check() : DispatchQueue.main.sync(execute: check)
        wordLock.lock(); wordCache[key] = ok; wordLock.unlock()
        return ok
    }

    /// Decides, using both documents, whether each word rejoined across a line-end hyphen is really one
    /// word ("exam-ple" → "example") or a hyphenated compound ("long-term"). Evidence from the documents
    /// wins; the English spell checker breaks ties.
    static func resolveHyphenation(_ docs: inout [[Token]]) {
        var words = Set<String>(), compounds = Set<String>()
        for t in docs {
            for i in t.indices where t[i].hyphen == nil {
                words.insert(t[i].text.lowercased())
                if i + 2 < t.count, t[i + 1].text == "-", t[i + 1].sep == .none, t[i + 2].sep == .none {
                    compounds.insert((t[i].text + "-" + t[i + 2].text).lowercased())
                }
            }
        }
        for d in docs.indices where docs[d].contains(where: { $0.hyphen != nil }) {
            var out: [Token] = []
            out.reserveCapacity(docs[d].count + 16)
            for t in docs[d] {
                guard let h = t.hyphen else { out.append(t); continue }
                let joined = t.text.lowercased(), compound = (h.first + "-" + h.second).lowercased()
                let split: Bool
                if words.contains(joined) { split = false }
                else if compounds.contains(compound) { split = true }
                else if isKnownWord(joined) { split = false }
                else { split = isKnownWord(h.first) && isKnownWord(h.second) }
                if split {
                    out.append(Token(text: h.first, page: t.page, range: h.firstRange, sep: t.sep, style: t.style))
                    out.append(Token(text: "-", page: t.page, range: h.markRange, sep: .none, style: t.style))
                    out.append(Token(text: h.second, page: t.page, range: h.secondRange, sep: .none, style: t.style))
                } else {
                    var j = t; j.hyphen = nil; out.append(j)
                }
            }
            docs[d] = out
        }
    }

    /// List markers drawn as separate glyphs come back from PDFKit as lines holding only "•",
    /// often out of reading order. Blank them (same length, so offsets stay valid).
    static func blankBulletOnlyLines(_ s: String) -> String {
        let bullets: Set<String> = ["•", "◦", "▪", "‣", "●", "○", "■", "□", "-", "–", "*", "·", "⁃"]
        let ns = NSMutableString(string: s)
        var changed = false
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: .byLines) { sub, r, _, _ in
            if let t = sub?.trimmingCharacters(in: .whitespaces), bullets.contains(t) {
                ns.replaceCharacters(in: r, with: String(repeating: " ", count: r.length))
                changed = true
            }
        }
        return changed ? ns as String : s
    }

    /// Tokenises one page of text. Returns false if the page had no tokens.
    @discardableResult
    static func appendTokens(from s: String, page p: Int, to tokens: inout [Token], dehyphenate: Bool = true,
                             lines precomputed: PageLines? = nil) -> Bool {
        let ns = s as NSString
        let matches = tokenRegex.matches(in: s, range: NSRange(location: 0, length: ns.length))
        if matches.isEmpty { return false }
        let lines = precomputed ?? PageLines(ns)
        var prevEnd = 0
        var first = true
        var i = 0
        while i < matches.count {
            var r = matches[i].range
            var text = ns.substring(with: r)
            var sep: Separator = first ? .softBreak : classify(ns, from: prevEnd, to: r.location, lines: lines)
            var hyphen: HyphenParts?

            // Rejoin words hyphenated across a line break: "exam-\nple" -> "example".
            // PDFKit sometimes reports the break as "author- -\nisation", so accept a short run of hyphen marks.
            if dehyphenate, i + 2 < matches.count, text.first?.isLetter == true,
               matches[i + 1].range.location == r.location + r.length {
                let hyphens: Set<String> = ["-", "\u{00AD}", "‐"]
                var j = i + 1
                var lastEnd = r.location + r.length
                while j < matches.count, j <= i + 3, hyphens.contains(ns.substring(with: matches[j].range)) {
                    let gap = ns.substring(with: NSRange(location: lastEnd, length: matches[j].range.location - lastEnd))
                    if gap.contains(where: \.isNewline) || !gap.allSatisfy(\.isWhitespace) { break }
                    lastEnd = NSMaxRange(matches[j].range)
                    j += 1
                }
                if j > i + 1, j < matches.count {
                    let n = matches[j].range
                    let gap = ns.substring(with: NSRange(location: lastEnd, length: n.location - lastEnd))
                    let nText = ns.substring(with: n)
                    if gap.contains(where: \.isNewline), gap.allSatisfy(\.isWhitespace),
                       nText.first?.isLowercase == true {
                        hyphen = HyphenParts(first: text, second: nText, firstRange: r,
                                             markRange: matches[i + 1].range, secondRange: n)
                        text += nText
                        r = NSRange(location: r.location, length: NSMaxRange(n) - r.location)
                        i = j
                    }
                }
            }
            if first && tokens.isEmpty { sep = .none }
            tokens.append(Token(text: text, page: p, range: r, sep: sep, hyphen: hyphen))
            prevEnd = r.location + r.length
            first = false
            i += 1
        }
        return true
    }

    private static func classify(_ ns: NSString, from: Int, to: Int, lines: PageLines) -> Separator {
        if to <= from { return .none }
        var newlines = 0, firstNL = -1, prevCR = false
        for i in from..<to {
            let c = ns.character(at: i)
            if c == 10 && prevCR { prevCR = false; continue }
            if c == 10 || c == 13 || c == 0x2028 || c == 0x2029 {
                newlines += 1
                if firstNL < 0 { firstNL = i }
            }
            prevCR = c == 13
        }
        if newlines == 0 { return .space }
        if newlines >= 2 || ns.character(at: firstNL) == 0x2029 { return .hardBreak }
        if lines.hardAtNewline.contains(firstNL) { return .hardBreak }
        let l = lines.lineLenAtNewline[firstNL] ?? 0
        if lines.typical > 20 && Double(l) < Double(lines.typical) * 0.7 { return .hardBreak }
        return .softBreak
    }

    static func normalize(_ s: String, ignoreCase: Bool) -> String {
        var t = s.precomposedStringWithCompatibilityMapping
        t = String(t.map { c -> Character in
            switch c {
            case "’", "‘", "‛", "′", "`": return "'"
            case "“", "”", "„", "″": return "\""
            case "–", "—", "‐", "‑", "‒", "−": return "-"
            default: return c
            }
        })
        return ignoreCase ? t.lowercased() : t
    }
}

// MARK: - Diff

struct Change: Identifiable, Hashable {
    enum Kind { case insertion, deletion, replacement }
    let id: Int
    let a: Range<Int>   // token range in original
    let b: Range<Int>   // token range in revised
    var kind: Kind { a.isEmpty ? .insertion : (b.isEmpty ? .deletion : .replacement) }
}

enum Segment {
    case equal(a: Range<Int>, b: Range<Int>)
    case change(Change)
}

enum Differ {
    /// Histogram-style diff: anchor on the longest run seeded by a low-frequency token,
    /// recurse on both sides. Returns matched index pairs in increasing order.
    static func matches(_ a: [Int], _ b: [Int]) -> [(Int, Int)] {
        var out: [(Int, Int)] = []
        out.reserveCapacity(min(a.count, b.count))
        var stack: [(Int, Int, Int, Int)] = [(0, a.count, 0, b.count)]

        while let (aLo0, aHi0, bLo0, bHi0) = stack.popLast() {
            var aLo = aLo0, aHi = aHi0, bLo = bLo0, bHi = bHi0
            while aLo < aHi && bLo < bHi && a[aLo] == b[bLo] { out.append((aLo, bLo)); aLo += 1; bLo += 1 }
            while aLo < aHi && bLo < bHi && a[aHi - 1] == b[bHi - 1] { aHi -= 1; bHi -= 1; out.append((aHi, bHi)) }
            if aLo >= aHi || bLo >= bHi { continue }

            var occ: [Int: [Int]] = [:]
            for i in aLo..<aHi { occ[a[i], default: []].append(i) }

            var bestLen = 0, bestA = 0, bestB = 0, bestCount = Int.max
            var diagEnd: [Int: Int] = [:]
            for bi in bLo..<bHi {
                guard let list = occ[b[bi]], list.count <= 64 else { continue }
                for ai in list {
                    let d = ai - bi
                    if let e = diagEnd[d], e > bi { continue }
                    var s = ai, t = bi
                    while s > aLo && t > bLo && a[s - 1] == b[t - 1] { s -= 1; t -= 1 }
                    var e1 = ai + 1, e2 = bi + 1
                    while e1 < aHi && e2 < bHi && a[e1] == b[e2] { e1 += 1; e2 += 1 }
                    diagEnd[d] = e2
                    let len = e1 - s
                    if len > bestLen || (len == bestLen && list.count < bestCount) {
                        bestLen = len; bestA = s; bestB = t; bestCount = list.count
                    }
                }
            }

            if bestLen == 0 {
                let n = aHi - aLo, m = bHi - bLo
                if n * m <= 4_000_000 { out += lcs(a, aLo, aHi, b, bLo, bHi) }
                continue
            }
            for k in 0..<bestLen { out.append((bestA + k, bestB + k)) }
            stack.append((aLo, bestA, bLo, bestB))
            stack.append((bestA + bestLen, aHi, bestB + bestLen, bHi))
        }
        out.sort { $0.0 < $1.0 }
        return out
    }

    private static func lcs(_ a: [Int], _ aLo: Int, _ aHi: Int, _ b: [Int], _ bLo: Int, _ bHi: Int) -> [(Int, Int)] {
        let n = aHi - aLo, m = bHi - bLo
        let w = m + 1
        var t = [UInt16](repeating: 0, count: (n + 1) * w)
        if n == 0 || m == 0 { return [] }
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                t[i * w + j] = a[aLo + i] == b[bLo + j]
                    ? t[(i + 1) * w + j + 1] + 1
                    : max(t[(i + 1) * w + j], t[i * w + j + 1])
            }
        }
        var res: [(Int, Int)] = []
        var i = 0, j = 0
        while i < n && j < m {
            if a[aLo + i] == b[bLo + j] { res.append((aLo + i, bLo + j)); i += 1; j += 1 }
            else if t[(i + 1) * w + j] >= t[i * w + j + 1] { i += 1 } else { j += 1 }
        }
        return res
    }

    static func segments(_ a: [Int], _ b: [Int]) -> [Segment] {
        let m = matches(a, b)
        enum Raw { case eq(Range<Int>, Range<Int>), ch(Range<Int>, Range<Int>) }
        var raw: [Raw] = []
        var ai = 0, bi = 0, k = 0
        while k < m.count || ai < a.count || bi < b.count {
            if k < m.count {
                let (ma, mb) = m[k]
                if ma == ai && mb == bi {
                    var len = 0
                    while k < m.count && m[k].0 == ai + len && m[k].1 == bi + len { len += 1; k += 1 }
                    raw.append(.eq(ai..<ai + len, bi..<bi + len))
                    ai += len; bi += len
                } else {
                    raw.append(.ch(ai..<ma, bi..<mb))
                    ai = ma; bi = mb
                }
            } else {
                raw.append(.ch(ai..<a.count, bi..<b.count))
                ai = a.count; bi = b.count
            }
        }

        // Semantic cleanup: absorb tiny equalities sandwiched between larger edits,
        // so rewritten sentences read as one replacement rather than confetti.
        var merged = true
        while merged {
            merged = false
            var i = 0
            while i + 2 < raw.count {
                if case let .ch(a1, b1) = raw[i], case let .eq(ea, _) = raw[i + 1], case let .ch(a2, b2) = raw[i + 2] {
                    let s1 = max(a1.count, b1.count), s2 = max(a2.count, b2.count)
                    if ea.count <= 2 && ea.count < min(s1, s2) {
                        raw[i] = .ch(a1.lowerBound..<a2.upperBound, b1.lowerBound..<b2.upperBound)
                        raw.removeSubrange(i + 1...i + 2)
                        merged = true
                        continue
                    }
                }
                i += 1
            }
        }

        var id = 0
        return raw.map {
            switch $0 {
            case let .eq(x, y): return .equal(a: x, b: y)
            case let .ch(x, y): id += 1; return .change(Change(id: id, a: x, b: y))
            }
        }
    }
}

// MARK: - PDF geometry

/// Rectangles (one per text line) covering a character range on a PDF page.
///
/// PDFKit's per-character positions can drift on lines whose glyphs are stored out of reading order
/// (list bullets are the common case): whole lines are placed correctly but words inside them are
/// shifted. Each line is therefore checked against the line's true extent plus the measured width of
/// the text before the word, in the PDF's own font. When the line measures true (not justified, fonts
/// available) and PDFKit disagrees, the measured position is used.
enum PDFGeometry {
    static func rects(_ page: PDFPage, _ range: NSRange) -> [CGRect] {
        let ns = (page.string ?? "") as NSString
        guard range.length > 0, NSMaxRange(range) <= ns.length else { return [] }
        let attr = page.attributedString
        guard let attr, attr.length == ns.length else { return kitRects(page, range) }
        var out: [CGRect] = []
        var loc = range.location
        let end = NSMaxRange(range)
        // Walk the text lines the range covers; place each piece within its own line.
        while loc < end {
            let lineWithBreak = ns.lineRange(for: NSRange(location: loc, length: 0))
            let line = trimmed(ns, lineWithBreak)
            let piece = trimmed(ns, NSRange(location: loc, length: min(end, NSMaxRange(lineWithBreak)) - loc))
            if piece.length > 0 {
                if let r = measured(page, ns, attr, piece, line) { out.append(r) } else { out += kitRects(page, piece) }
            }
            loc = NSMaxRange(lineWithBreak)
        }
        return out
    }

    private static func kitRects(_ page: PDFPage, _ r: NSRange) -> [CGRect] {
        guard let sel = page.selection(for: r) else { return [] }
        return sel.selectionsByLine().map { $0.bounds(for: page) }.filter { !$0.isEmpty }
    }

    private static func trimmed(_ ns: NSString, _ r0: NSRange) -> NSRange {
        var r = r0
        func ws(_ i: Int) -> Bool { Unicode.Scalar(ns.character(at: i)).map { CharacterSet.whitespacesAndNewlines.contains($0) } ?? false }
        while r.length > 0 && ws(NSMaxRange(r) - 1) { r.length -= 1 }
        while r.length > 0 && ws(r.location) { r.location += 1; r.length -= 1 }
        return r
    }

    /// The whole line's rectangle comes from PDFKit (reliable); the piece's offset and width within it
    /// are measured in the PDF's font, scaled to the real line width.
    private static func measured(_ page: PDFPage, _ ns: NSString, _ attr: NSAttributedString, _ piece: NSRange, _ line: NSRange) -> CGRect? {
        guard line.length > 0, piece.location >= line.location, NSMaxRange(piece) <= NSMaxRange(line),
              let lineSel = page.selection(for: line) else { return nil }
        let visualLines = lineSel.selectionsByLine()
        guard visualLines.count == 1 else { return nil }
        let lineRect = lineSel.bounds(for: page)
        let measuredLine = attr.attributedSubstring(from: line).size().width
        guard lineRect.width > 4, measuredLine > 0 else { return nil }
        let k = lineRect.width / measuredLine
        guard k > 0.5 && k < 1.6 else { return nil }
        if piece == line { return lineRect }
        let prefix = attr.attributedSubstring(from: NSRange(location: line.location, length: piece.location - line.location)).size().width * k
        let width = attr.attributedSubstring(from: piece).size().width * k
        return CGRect(x: lineRect.minX + prefix, y: lineRect.minY, width: max(width, 1), height: lineRect.height)
    }
}
