import Foundation
import PDFKit
import WebKit
import UniformTypeIdentifiers

// MARK: - Source references

enum SourceRef: Hashable {
    case file(URL)
    case web(URL)

    init?(url: URL) {
        if url.isFileURL {
            if url.pathExtension.lowercased() == "webloc",
               let data = try? Data(contentsOf: url),
               let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
               let s = plist["URL"] as? String, let u = URL(string: s) {
                self.init(url: u); return
            }
            let type = UTType(filenameExtension: url.pathExtension)
            guard type?.conforms(to: .pdf) == true else { return nil }
            self = .file(url)
        } else if let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
            self = .web(url)
        } else {
            return nil
        }
    }

    init?(string: String) {
        var s = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return nil }
        if s.hasPrefix("/") || s.hasPrefix("~") {
            self.init(url: URL(fileURLWithPath: (s as NSString).expandingTildeInPath)); return
        }
        if !s.lowercased().hasPrefix("http://") && !s.lowercased().hasPrefix("https://") { s = "https://" + s }
        guard let u = URL(string: s) else { return nil }
        self.init(url: u)
    }

    var url: URL { switch self { case .file(let u), .web(let u): return u } }
    var wayback: WaybackRef? { if case .web(let u) = self { return WaybackRef(u) } else { return nil } }

    var displayName: String {
        switch self {
        case .file(let u): return u.lastPathComponent
        case .web(let u):
            if let w = WaybackRef(u) { return w.originalDisplay }
            return (u.host ?? "") + u.path
        }
    }

    var kindLabel: String {
        switch self {
        case .file: return "PDF file"
        case .web(let u):
            if let w = WaybackRef(u) { return "Wayback Machine · " + DateText.medium(w.date) }
            return "Live web page"
        }
    }

    var symbol: String {
        switch self {
        case .file: return "doc.richtext"
        case .web(let u): return WaybackRef(u) != nil ? "clock.arrow.circlepath" : "globe"
        }
    }
}

struct WaybackRef: Hashable {
    let timestamp: String       // 1–14 digits
    let original: String        // original page URL

    private static let regex = try! NSRegularExpression(
        pattern: #"^https?://(?:www\.)?(?:web\.)?archive\.org/web/(\d{1,14})(?:[a-z]{2}_)?/+(.+)$"#,
        options: [.caseInsensitive])

    init?(_ url: URL) {
        let s = url.absoluteString
        guard let m = Self.regex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              let tsR = Range(m.range(at: 1), in: s), let oR = Range(m.range(at: 2), in: s) else { return nil }
        timestamp = String(s[tsR])
        var o = String(s[oR])
        if let r = o.range(of: #"^(https?):/+"#, options: [.regularExpression, .caseInsensitive]) {
            let scheme = o[r].lowercased().hasPrefix("https") ? "https" : "http"
            o = scheme + "://" + o[r.upperBound...]
        } else {
            o = "http://" + o
        }
        original = o
    }

    init(timestamp: String, original: String) { self.timestamp = timestamp; self.original = original }

    var date: Date {
        let padded = timestamp + "19700101000000".dropFirst(timestamp.count)
        return DateText.waybackParser.date(from: String(padded)) ?? Date.distantPast
    }
    /// Raw archived bytes, without the Wayback toolbar or URL rewriting.
    var rawURL: URL { URL(string: "https://web.archive.org/web/\(timestamp)id_/\(original)")! }
    /// Rewritten page without toolbar – suitable for rendering with JavaScript.
    var frameURL: URL { URL(string: "https://web.archive.org/web/\(timestamp)if_/\(original)")! }
    /// Normal viewer URL for people.
    var viewURL: URL { URL(string: "https://web.archive.org/web/\(timestamp)/\(original)")! }

    var originalDisplay: String {
        guard let u = URL(string: original) else { return original }
        return (u.host ?? "") + u.path
    }
}

enum DateText {
    static let waybackParser: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMddHHmmss"
        return f
    }()
    static func waybackStamp(_ d: Date) -> String { waybackParser.string(from: d) }
    private static let mediumF: DateFormatter = { let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .none; return f }()
    private static let shortF: DateFormatter = { let f = DateFormatter(); f.dateFormat = "d MMM yyyy"; return f }()
    static func medium(_ d: Date) -> String { mediumF.string(from: d) }
    static func short(_ d: Date) -> String { shortF.string(from: d) }
}

/// Loose identity of a page: host without www, path without trailing slash.
func pageKey(_ s: String) -> String {
    guard let u = URL(string: s) else { return s.lowercased() }
    var host = (u.host ?? "").lowercased()
    if host.hasPrefix("www.") { host.removeFirst(4) }
    var path = u.path
    while path.hasSuffix("/") { path.removeLast() }
    return host + path
}

// MARK: - Loaded documents

struct SourceDoc {
    let ref: SourceRef
    let title: String
    let pdf: PDFDocument?
    var text: String?            // extracted web text (single "page" 0)
    var tokens: [Token]
    var styles: [TextStyle]      // formatting table referenced by Token.style
    /// For web pages read from their <main> region: the whole page, used when the other version has no usable <main>.
    var fullPage: WebText?
    let pagesWithoutText: Int
    let date: Date?              // capture date (Wayback) or fetch date (live)
    let pageURL: URL?            // the underlying page, for Wayback lookups
    let rendered: Bool           // text came from a JavaScript-rendered DOM

    var isPDF: Bool { pdf != nil }
}

enum LoadError: LocalizedError {
    case cannotOpen(String), locked(String), noText(String), http(Int, String), unsupported(String)
    var errorDescription: String? {
        switch self {
        case .cannotOpen(let n): return "“\(n)” could not be opened as a PDF."
        case .locked(let n): return "“\(n)” is password-protected. Unlock it in Preview first."
        case .noText(let n): return "“\(n)” has no extractable text (it may be a scanned image). Run OCR on it first."
        case .http(let c, let n): return "Fetching “\(n)” failed with HTTP status \(c)."
        case .unsupported(let n): return "“\(n)” is neither a PDF nor an HTML page."
        }
    }
}

enum RenderMode: String, CaseIterable, Identifiable {
    case auto, always
    var id: String { rawValue }
    var label: String { self == .auto ? "Only when needed" : "Always" }
}

struct WebText {
    let text: String
    let tokens: [Token]
    let styles: [TextStyle]
}

extension SourceDoc {
    /// Switches a web document from its <main> region to the whole page.
    func usingFullPage() -> SourceDoc {
        guard let f = fullPage else { return self }
        var d = self
        d.text = f.text; d.tokens = f.tokens; d.styles = f.styles; d.fullPage = nil
        return d
    }
}

struct LoadedContent {
    var pdf: PDFDocument?
    var text: String?
    var title: String?
    var tokens: [Token]
    var styles: [TextStyle]
    var fullPage: WebText? = nil
    var emptyPages: Int
    var rendered: Bool
}

enum Fetcher {
    static let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 60
        c.timeoutIntervalForResource = 180
        c.httpAdditionalHeaders = [
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15",
            "Accept-Language": "en-GB,en;q=0.9",
        ]
        return URLSession(configuration: c)
    }()

    static func get(_ url: URL) async throws -> (Data, HTTPURLResponse) {
        var attempt = 0
        while true {
            try Task.checkCancellation()
            do {
                let (d, r) = try await session.data(from: url)
                guard let h = r as? HTTPURLResponse else { throw URLError(.badServerResponse) }
                if (h.statusCode == 429 || h.statusCode >= 500) && attempt < 4 {
                    attempt += 1
                    try await Task.sleep(nanoseconds: UInt64(5_000_000_000 * attempt))
                    continue
                }
                guard (200..<300).contains(h.statusCode) else { throw LoadError.http(h.statusCode, url.host ?? url.absoluteString) }
                return (d, h)
            } catch let e as URLError where attempt < 3 && [.timedOut, .networkConnectionLost, .cannotConnectToHost].contains(e.code) {
                attempt += 1
                try await Task.sleep(nanoseconds: UInt64(2_000_000_000 * attempt))
            }
        }
    }
}

enum SourceLoader {
    static func load(_ ref: SourceRef, render: RenderMode) async throws -> SourceDoc {
        switch ref {
        case .file(let url):
            let name = url.lastPathComponent
            guard let doc = PDFDocument(url: url) else { throw LoadError.cannotOpen(name) }
            if doc.isLocked { throw LoadError.locked(name) }
            let (tokens, empty, styles) = TextExtractor.pdfTokens(doc)
            if tokens.isEmpty { throw LoadError.noText(name) }
            return SourceDoc(ref: ref, title: name, pdf: doc, text: nil, tokens: tokens, styles: styles, fullPage: nil, pagesWithoutText: empty,
                             date: nil, pageURL: nil, rendered: false)

        case .web(let url):
            if let w = WaybackRef(url) {
                let (data, resp) = try await Fetcher.get(w.rawURL)
                // Wayback redirects to the closest capture; record the real timestamp.
                let actual = resp.url.flatMap { WaybackRef($0) } ?? w
                let c = try await content(data: data, response: resp, name: actual.originalDisplay,
                                          render: render, renderURL: actual.frameURL)
                return SourceDoc(ref: .web(actual.viewURL), title: c.title ?? actual.originalDisplay, pdf: c.pdf, text: c.text,
                                 tokens: c.tokens, styles: c.styles, fullPage: c.fullPage, pagesWithoutText: c.emptyPages, date: actual.date,
                                 pageURL: URL(string: actual.original), rendered: c.rendered)
            } else {
                let (data, resp) = try await Fetcher.get(url)
                let c = try await content(data: data, response: resp, name: url.host ?? url.absoluteString,
                                          render: render, renderURL: url)
                return SourceDoc(ref: ref, title: c.title ?? ((url.host ?? "") + url.path), pdf: c.pdf, text: c.text,
                                 tokens: c.tokens, styles: c.styles, fullPage: c.fullPage, pagesWithoutText: c.emptyPages, date: Date(),
                                 pageURL: resp.url ?? url, rendered: c.rendered)
            }
        }
    }

    /// Turns fetched bytes into tokens. HTML is parsed directly, so text hidden by CSS
    /// (collapsed accordions, "read more" panels, tabs) is included. If the static HTML is
    /// thin – content injected by JavaScript – the page is rendered and every collapsible
    /// element is expanded before the DOM is read.
    static func content(data: Data, response: HTTPURLResponse?, name: String,
                        render: RenderMode, renderURL: URL?) async throws -> LoadedContent {
        let mime = response?.mimeType?.lowercased() ?? ""
        if mime == "application/pdf" || data.starts(with: Array("%PDF".utf8)) {
            guard let doc = PDFDocument(data: data) else { throw LoadError.cannotOpen(name) }
            let (tokens, empty, styles) = TextExtractor.pdfTokens(doc)
            if tokens.isEmpty { throw LoadError.noText(name) }
            return LoadedContent(pdf: doc, text: nil, title: nil, tokens: tokens, styles: styles, emptyPages: empty, rendered: false)
        }
        guard mime.isEmpty || mime.contains("html") || mime.contains("xml") || mime.hasPrefix("text/") else {
            throw LoadError.unsupported(name)
        }
        let html = HTMLText.decode(data, encodingName: response?.textEncodingName)
        var (page, full) = HTMLText.extractBoth(html)
        var rendered = false
        let thin = page.text.count < 600
        if let renderURL, render == .always || thin {
            if let dom = try? await PageRenderer.renderExpandedDOM(url: renderURL) {
                let (r, rFull) = HTMLText.extractBoth(dom)
                // Only trust the rendering when it reveals substantially more text (it may also mis-decode).
                if render == .always || r.text.count > page.text.count + max(200, page.text.count / 5) {
                    let oldTitle = page.title
                    page = r
                    full = rFull
                    if page.title == nil { page.title = oldTitle }
                    rendered = true
                }
            }
        }
        let tokens = HTMLText.tokens(page)
        if tokens.isEmpty { throw LoadError.noText(name) }
        let fullText = full.map { WebText(text: $0.text, tokens: HTMLText.tokens($0), styles: $0.styles) }
        return LoadedContent(pdf: nil, text: page.text, title: page.title, tokens: tokens, styles: page.styles,
                             fullPage: fullText, emptyPages: 0, rendered: rendered)
    }
}

// MARK: - HTML → text

enum HTMLText {
    struct Page {
        var text: String
        var title: String?
        var styles: [TextStyle] = [TextStyle()]
        var runs: [(loc: Int, len: Int, style: Int32)] = []
    }

    static func decode(_ data: Data, encodingName: String?) -> String {
        var enc: String.Encoding?
        if let n = encodingName {
            let cf = CFStringConvertIANACharSetNameToEncoding(n as CFString)
            if cf != kCFStringEncodingInvalidId { enc = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf)) }
        }
        if enc == nil {
            let head = String(decoding: data.prefix(4096), as: UTF8.self)
            if let r = head.range(of: #"charset=["']?([A-Za-z0-9_\-]+)"#, options: [.regularExpression, .caseInsensitive]) {
                let n = head[r].replacingOccurrences(of: #"charset=["']?"#, with: "", options: [.regularExpression, .caseInsensitive])
                let cf = CFStringConvertIANACharSetNameToEncoding(n as CFString)
                if cf != kCFStringEncodingInvalidId { enc = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf)) }
            }
        }
        // A Latin-1/ASCII label is often a server default; valid UTF-8 with non-ASCII bytes is almost certainly UTF-8.
        if let e = enc, [.isoLatin1, .windowsCP1252, .ascii].contains(e),
           data.contains(where: { $0 >= 0x80 }), let s = String(data: data, encoding: .utf8) { return s }
        if let e = enc, let s = String(data: data, encoding: e) { return s }
        if let s = String(data: data, encoding: .utf8) { return s }
        return String(data: data, encoding: .windowsCP1252) ?? String(decoding: data, as: UTF8.self)
    }

    private static let skipTags: Set<String> = ["svg", "noscript", "template", "select", "iframe", "canvas",
                                                "object", "math", "video", "audio", "map"]
    private static let rawTags: Set<String> = ["script", "style", "title", "textarea", "xmp"]
    private static let blockTags: Set<String> = [
        "address", "article", "aside", "blockquote", "dd", "details", "dialog", "div", "dl", "dt", "fieldset",
        "figcaption", "figure", "footer", "form", "h1", "h2", "h3", "h4", "h5", "h6", "header", "hr", "li",
        "main", "nav", "ol", "p", "pre", "section", "summary", "table", "tbody", "thead", "tfoot", "tr", "ul",
        "caption", "legend", "body", "html", "center", "menu", "hgroup", "search",
    ]

    private struct Builder {
        var chunks: [(text: String, style: Int32)] = []   // style -1 = separator
        var pendingBreak = 0
        var needSpace = false
        var style: Int32 = 0

        mutating func block() { pendingBreak = 2 }
        mutating func line() { pendingBreak = max(pendingBreak, 1) }
        mutating func space() { needSpace = true }

        mutating func text(_ raw: String, pre: Bool) {
            if pre {
                let lines = raw.components(separatedBy: .newlines)
                for (i, l) in lines.enumerated() {
                    if i > 0 { line() }
                    emit(l)
                }
                return
            }
            emit(raw)
        }

        private mutating func emit(_ raw: String) {
            var collapsed = ""
            collapsed.reserveCapacity(raw.count)
            var lastWasSpace = false
            for ch in raw {
                if ch.isWhitespace {
                    if !lastWasSpace { collapsed.append(" ") }
                    lastWasSpace = true
                } else {
                    collapsed.append(ch); lastWasSpace = false
                }
            }
            if collapsed.isEmpty || collapsed == " " { if !collapsed.isEmpty { needSpace = true }; return }
            if collapsed.hasPrefix(" ") { needSpace = true }
            let trimmed = collapsed.trimmingCharacters(in: .whitespaces)
            if !chunks.isEmpty {
                if pendingBreak == 2 { chunks.append(("\n\n", -1)) }
                else if pendingBreak == 1 { chunks.append(("\n", -1)) }
                else if needSpace { chunks.append((" ", -1)) }
            }
            chunks.append((trimmed, style))
            pendingBreak = 0
            needSpace = collapsed.hasSuffix(" ")
        }
    }

    /// Lenient streaming HTML-to-text conversion. Ignores CSS entirely, so content in
    /// collapsed/hidden sections is kept. Prefers the page's <main> region when it holds
    /// most of the text, to drop site navigation and footers.
    /// Tokens of an extracted page, each carrying its formatting from the HTML runs.
    static func tokens(_ page: Page) -> [Token] {
        var tokens: [Token] = []
        TextExtractor.appendTokens(from: page.text, page: 0, to: &tokens, dehyphenate: false)
        var ri = 0
        for i in tokens.indices {
            let loc = tokens[i].range.location
            while ri + 1 < page.runs.count && page.runs[ri].loc + page.runs[ri].len <= loc { ri += 1 }
            if ri < page.runs.count, page.runs[ri].loc <= loc { tokens[i].style = page.runs[ri].style }
        }
        return tokens
    }

    static func extract(_ html: String) -> Page { extractBoth(html).chosen }

    /// The page text to compare (its <main> region when that holds most of the text) and,
    /// when <main> was chosen, the whole page as well.
    static func extractBoth(_ html: String) -> (chosen: Page, full: Page?) {
        let b = Array(html.utf8)
        let n = b.count
        var out = Builder()
        var title: String?
        var skipTag: String?
        var skipDepth = 0
        var pre = 0
        var mainDepth = 0
        var mainStart: Int?
        var mainEnd: Int?
        var i = 0
        // Formatting state.
        var table = StyleTable()
        var bold = 0, italic = 0, mono = 0, link = 0, quoteDepth = 0, center = 0
        var headings: [Int] = []
        var lists: [(ordered: Bool, counter: Int, item: Int)] = []
        var itemCounter = 0
        func refreshStyle() {
            let h = headings.last ?? 0
            let sizes: [CGFloat] = [1, 1.75, 1.45, 1.25, 1.1, 1.0, 0.95]
            out.style = table.id(TextStyle(
                relSize: sizes[h], bold: bold > 0 || h > 0, italic: italic > 0, mono: mono > 0 || pre > 0,
                link: link > 0, heading: h, listLevel: lists.count, ordered: lists.last?.ordered ?? false,
                ordinal: lists.last?.counter ?? 0, item: lists.last?.item ?? 0, quote: quoteDepth, centered: center > 0))
        }

        @inline(__always) func lower(_ c: UInt8) -> UInt8 { (c >= 65 && c <= 90) ? c + 32 : c }
        func find(_ needle: [UInt8], from: Int, caseInsensitive: Bool) -> Int? {
            guard !needle.isEmpty, from < n else { return nil }
            var k = from
            let last = n - needle.count
            while k <= last {
                var ok = true
                for t in 0..<needle.count {
                    let c = caseInsensitive ? lower(b[k + t]) : b[k + t]
                    if c != needle[t] { ok = false; break }
                }
                if ok { return k }
                k += 1
            }
            return nil
        }

        while i < n {
            if b[i] == 60 /* < */ {
                // Comments, doctype, processing instructions.
                if i + 3 < n && b[i + 1] == 33 && b[i + 2] == 45 && b[i + 3] == 45 {
                    i = (find(Array("-->".utf8), from: i + 4, caseInsensitive: false) ?? n - 3) + 3
                    continue
                }
                if i + 1 < n && (b[i + 1] == 33 || b[i + 1] == 63) {
                    while i < n && b[i] != 62 { i += 1 }
                    i += 1; continue
                }
                var j = i + 1
                let closing = j < n && b[j] == 47
                if closing { j += 1 }
                let nameStart = j
                let startsWithLetter = j < n && ((b[j] >= 65 && b[j] <= 90) || (b[j] >= 97 && b[j] <= 122))
                while startsWithLetter, j < n, (b[j] >= 65 && b[j] <= 90) || (b[j] >= 97 && b[j] <= 122) || (b[j] >= 48 && b[j] <= 57) || b[j] == 45 || b[j] == 58 { j += 1 }
                if j == nameStart {
                    // A literal "<" in text.
                    if skipTag == nil { out.text("<", pre: pre > 0) }
                    i += 1; continue
                }
                let name = String(decoding: b[nameStart..<j].map(lower), as: UTF8.self)
                let nameEnd = j
                // Scan to end of tag, respecting quoted attribute values.
                var quote: UInt8 = 0
                while j < n {
                    let c = b[j]
                    if quote != 0 { if c == quote { quote = 0 } }
                    else if c == 34 || c == 39 { quote = c }
                    else if c == 62 { break }
                    j += 1
                }
                var selfClosing = false
                if j - 1 < n, j - 1 >= nameEnd, b[j - 1] == 47 {
                    let prev = j - 2
                    selfClosing = prev < nameEnd || [32, 9, 10, 13, 34, 39].contains(b[prev])
                }
                i = j + 1

                if let st = skipTag {
                    if name == st && !selfClosing { skipDepth += closing ? -1 : 1 }
                    if skipDepth <= 0 { skipTag = nil }
                    continue
                }
                if !closing && rawTags.contains(name) {
                    let end = find(Array("</\(name)".utf8), from: i, caseInsensitive: true) ?? n
                    if name == "title" && title == nil {
                        title = decodeEntities(String(decoding: b[i..<end], as: UTF8.self))
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                    } else if name == "textarea" || name == "xmp" {
                        out.text(decodeEntities(String(decoding: b[i..<end], as: UTF8.self)), pre: false)
                    }
                    i = end
                    while i < n && b[i] != 62 { i += 1 }
                    i += 1
                    continue
                }
                if !closing && skipTags.contains(name) && !selfClosing {
                    skipTag = name; skipDepth = 1; continue
                }
                if name == "main" {
                    if !closing {
                        if mainDepth == 0 && mainStart == nil { out.block(); mainStart = out.chunks.count }
                        mainDepth += 1
                    } else if mainDepth > 0 {
                        mainDepth -= 1
                        if mainDepth == 0 && mainEnd == nil { mainEnd = out.chunks.count }
                    }
                }
                if name == "pre" { pre = max(0, pre + (closing ? -1 : 1)) }
                if !selfClosing {
                    let d = closing ? -1 : 1
                    switch name {
                    case "b", "strong", "th": bold = max(0, bold + d)
                    case "i", "em", "cite", "var", "dfn": italic = max(0, italic + d)
                    case "code", "kbd", "samp", "tt": mono = max(0, mono + d)
                    case "a": link = max(0, link + d)
                    case "blockquote": quoteDepth = max(0, quoteDepth + d)
                    case "center": center = max(0, center + d)
                    case "h1", "h2", "h3", "h4", "h5", "h6":
                        if closing { if !headings.isEmpty { headings.removeLast() } }
                        else { headings.append(Int(String(name.last!)) ?? 1) }
                    case "ul", "ol", "menu":
                        if closing { if !lists.isEmpty { lists.removeLast() } }
                        else { lists.append((name == "ol", 0, 0)) }
                    case "li":
                        if !closing && !lists.isEmpty {
                            itemCounter += 1
                            lists[lists.count - 1].counter += 1
                            lists[lists.count - 1].item = itemCounter
                        }
                    default: break
                    }
                }
                refreshStyle()
                if blockTags.contains(name) { out.block() }
                else if name == "br" { out.line() }
                else if name == "td" || name == "th" { out.space() }
                else if name == "img" && !closing { out.space() }
                continue
            }
            var j = i
            while j < n && b[j] != 60 { j += 1 }
            if skipTag == nil {
                let raw = String(decoding: b[i..<j], as: UTF8.self)
                out.text(raw.contains("&") ? decodeEntities(raw) : raw, pre: pre > 0)
            }
            i = j
        }

        let chunks = out.chunks
        func assemble(_ r: Range<Int>) -> Page {
            var lo = r.lowerBound, hi = r.upperBound
            while lo < hi && chunks[lo].style < 0 { lo += 1 }
            while hi > lo && chunks[hi - 1].style < 0 { hi -= 1 }
            var text = ""
            var runs: [(loc: Int, len: Int, style: Int32)] = []
            var loc = 0
            for c in chunks[lo..<hi] {
                let n = c.text.utf16.count
                if c.style >= 0 { runs.append((loc, n, c.style)) }
                text += c.text
                loc += n
            }
            return Page(text: text, title: title, styles: table.styles, runs: runs)
        }
        let all = assemble(0..<chunks.count)
        if let s = mainStart {
            let main = assemble(s..<max(s, mainEnd ?? chunks.count))
            if main.text.count >= 500 && Double(main.text.count) >= Double(all.text.count) * 0.3 { return (main, all) }
        }
        return (all, nil)
    }

    private static let entities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ", "ensp": " ", "emsp": " ",
        "thinsp": " ", "ndash": "–", "mdash": "—", "hellip": "…", "lsquo": "‘", "rsquo": "’", "sbquo": "‚",
        "ldquo": "“", "rdquo": "”", "bdquo": "„", "laquo": "«", "raquo": "»", "copy": "©", "reg": "®",
        "trade": "™", "sect": "§", "para": "¶", "middot": "·", "bull": "•", "deg": "°", "euro": "€",
        "pound": "£", "yen": "¥", "cent": "¢", "times": "×", "divide": "÷", "shy": "\u{00AD}", "zwj": "",
        "zwnj": "", "lrm": "", "rlm": "", "eacute": "é", "egrave": "è", "ecirc": "ê", "euml": "ë",
        "aacute": "á", "agrave": "à", "acirc": "â", "auml": "ä", "aring": "å", "atilde": "ã", "aelig": "æ",
        "iacute": "í", "igrave": "ì", "icirc": "î", "iuml": "ï", "oacute": "ó", "ograve": "ò", "ocirc": "ô",
        "ouml": "ö", "otilde": "õ", "oslash": "ø", "uacute": "ú", "ugrave": "ù", "ucirc": "û", "uuml": "ü",
        "ccedil": "ç", "ntilde": "ñ", "szlig": "ß", "Eacute": "É", "Aacute": "Á", "Ouml": "Ö", "Uuml": "Ü",
        "Auml": "Ä", "Ccedil": "Ç", "Ntilde": "Ñ", "rarr": "→", "larr": "←", "check": "✓",
    ]

    /// Numeric character references as browsers decode them: 0x80–0x9F through Windows-1252,
    /// NUL, surrogates and out-of-range values to U+FFFD.
    static func numericEntity(_ v: UInt32) -> String {
        if (0x80...0x9F).contains(v) {
            let bytes = [UInt8(v)]
            return String(bytes: bytes, encoding: .windowsCP1252) ?? "\u{FFFD}"
        }
        if v == 0 { return "\u{FFFD}" }
        guard let u = Unicode.Scalar(v) else { return "\u{FFFD}" }
        return String(Character(u))
    }

    static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = ""
        out.reserveCapacity(s.count)
        var idx = s.startIndex
        while idx < s.endIndex {
            let c = s[idx]
            if c == "&", let semi = s[idx...].prefix(12).firstIndex(of: ";") {
                let body = s[s.index(after: idx)..<semi]
                var rep: String?
                if body.hasPrefix("#x") || body.hasPrefix("#X") {
                    if let v = UInt32(body.dropFirst(2), radix: 16) { rep = numericEntity(v) }
                } else if body.hasPrefix("#") {
                    if let v = UInt32(body.dropFirst()) { rep = numericEntity(v) }
                } else {
                    rep = entities[String(body)]
                }
                if let rep { out += rep; idx = s.index(after: semi); continue }
            }
            out.append(c)
            idx = s.index(after: idx)
        }
        return out
    }
}

// MARK: - JavaScript rendering with everything expanded

@MainActor
final class PageRenderer: NSObject, WKNavigationDelegate {
    private let webView: WKWebView
    private let window: NSWindow
    private var loadContinuation: CheckedContinuation<Void, Error>?
    private var loaded = false

    static let expandScript = """
    (() => {
      window.__pdfdiffClicked = window.__pdfdiffClicked || new WeakSet();
      let n = 0;
      document.querySelectorAll('details:not([open])').forEach(d => { d.open = true; n++; });
      const sel = '[aria-expanded="false"], .collapsed[data-toggle], .collapsed[data-bs-toggle], [data-toggle="collapse"], [data-bs-toggle="collapse"], .accordion-button.collapsed';
      document.querySelectorAll(sel).forEach(el => {
        if (window.__pdfdiffClicked.has(el)) return;
        window.__pdfdiffClicked.add(el);
        try { el.click(); n++; } catch (e) {}
      });
      document.querySelectorAll('[hidden]').forEach(el => el.removeAttribute('hidden'));
      document.querySelectorAll('[aria-hidden="true"]').forEach(el => el.removeAttribute('aria-hidden'));
      document.querySelectorAll('button, a').forEach(el => {
        const t = (el.innerText || '').trim().toLowerCase();
        if (/^(expand all|show all|show more|read more|see more|view more|open all)$/.test(t) && !window.__pdfdiffClicked.has(el)) {
          window.__pdfdiffClicked.add(el);
          try { el.click(); n++; } catch (e) {}
        }
      });
      return n;
    })()
    """

    private init(size: NSSize = NSSize(width: 1280, height: 1600)) {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: NSRect(origin: .zero, size: size), configuration: config)
        window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: size.width, height: size.height),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        super.init()
        window.contentView = webView
        window.orderBack(nil)
        window.alphaValue = 0
        webView.navigationDelegate = self
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
    }

    static func renderExpandedDOM(url: URL, timeout: TimeInterval = 45) async throws -> String {
        let r = PageRenderer()
        defer { r.window.orderOut(nil); r.webView.stopLoading() }
        try await withTaskCancellationHandler {
            try await r.load(url, timeout: timeout)
        } onCancel: {
            Task { @MainActor in r.cancelLoad() }
        }
        try Task.checkCancellation()
        try await Task.sleep(nanoseconds: 1_500_000_000)
        for _ in 0..<5 {
            let clicked = (try? await r.webView.evaluateJavaScript(expandScript)) as? Int ?? 0
            try await Task.sleep(nanoseconds: 800_000_000)
            if clicked == 0 { break }
        }
        // Scroll through the page to trigger lazy-loaded content.
        _ = try? await r.webView.evaluateJavaScript("window.scrollTo(0, document.body.scrollHeight); 0")
        try await Task.sleep(nanoseconds: 600_000_000)
        let html = try await r.webView.evaluateJavaScript("document.documentElement.outerHTML") as? String
        return html ?? ""
    }

    private func load(_ url: URL, timeout: TimeInterval) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            loadContinuation = c
            webView.load(URLRequest(url: url))
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
                self?.finish(.failure(URLError(.timedOut)))
            }
        }
    }

    func cancelLoad() {
        webView.stopLoading()
        finish(.failure(CancellationError()))
    }

    private func finish(_ result: Result<Void, Error>) {
        guard let c = loadContinuation else { return }
        loadContinuation = nil
        loaded = true
        c.resume(with: result)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish(.success(())) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(.failure(error)) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish(.failure(error)) }

    /// Once loaded, block navigations so that clicking toggles cannot leave the page.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if loaded && navigationAction.targetFrame?.isMainFrame == true { decisionHandler(.cancel) } else { decisionHandler(.allow) }
    }
}
