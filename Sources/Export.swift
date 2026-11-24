import AppKit
import PDFKit

// MARK: - Word document with real tracked changes

enum DocxExporter {
    static func export(_ c: Comparison, dates: [Int: ChangeDating], to url: URL) throws {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        let now = iso.string(from: Date())
        var revID = 1

        func esc(_ s: String) -> String {
            var o = ""
            o.reserveCapacity(s.count)
            for u in s.unicodeScalars {
                switch u {
                case "&": o += "&amp;"
                case "<": o += "&lt;"
                case ">": o += "&gt;"
                case "\"": o += "&quot;"
                default:
                    if u.value < 0x20 && u.value != 9 { continue }
                    if (0xFFFE...0xFFFF).contains(u.value) || (0xD800...0xDFFF).contains(u.value) { continue }
                    o.unicodeScalars.append(u)
                }
            }
            return o
        }
        func meta(_ change: Int?) -> String {
            let date = change.flatMap { dates[$0] }.map { iso.string(from: $0.firstSeen) } ?? now
            let author = (change.flatMap { dates[$0] } != nil) ? "Wayback Machine" : "Differ"
            defer { revID += 1 }
            return "w:id=\"\(revID)\" w:author=\"\(author)\" w:date=\"\(date)\""
        }

        var body = ""
        var paraRuns = ""
        var buf = ""
        var bufKind: PieceKind = .equal
        var bufChange: Int?
        var bufStyle = TextStyle()
        var paraFirst: Piece?
        var paraMinIndent = CGFloat.infinity
        var paraNewItem = false
        var lastItem: (Int, Int, Bool)?
        var paraHasLiveText = false   // equal or inserted text already written in this paragraph
        var lastMarkKind: PieceKind = .equal   // tracked state of the previous paragraph mark

        func rPr(_ st: TextStyle) -> String {
            var r = ""
            if st.mono { r += "<w:rFonts w:ascii=\"Courier New\" w:hAnsi=\"Courier New\" w:cs=\"Courier New\"/>" }
            else if let f = st.family { let e = esc(f); r += "<w:rFonts w:ascii=\"\(e)\" w:hAnsi=\"\(e)\" w:cs=\"\(e)\"/>" }
            if st.bold { r += "<w:b/><w:bCs/>" }
            if st.italic { r += "<w:i/><w:iCs/>" }
            if st.link { r += "<w:color w:val=\"1F5FBF\"/>" }
            let sz = Int((22 * min(max(st.relSize, 0.7), 2.4)).rounded())
            if sz != 22 { r += "<w:sz w:val=\"\(sz)\"/><w:szCs w:val=\"\(sz)\"/>" }
            return r.isEmpty ? "" : "<w:rPr>\(r)</w:rPr>"
        }
        func wrap(_ run: String, _ kind: PieceKind, _ change: Int?) -> String {
            switch kind {
            case .equal: return run
            case .insert: return "<w:ins \(meta(change))>\(run)</w:ins>"
            case .delete: return "<w:del \(meta(change))>\(run)</w:del>"
            }
        }
        func flush() {
            guard !buf.isEmpty else { return }
            let t = esc(buf)
            let tag = bufKind == .delete ? "w:delText" : "w:t"
            paraRuns += wrap("<w:r>\(rPr(bufStyle))<\(tag) xml:space=\"preserve\">\(t)</\(tag)></w:r>", bufKind, bufChange)
            buf = ""
        }
        func closeParagraph(markKind: PieceKind, change: Int?) {
            flush()
            var ppr = ""
            if let f = paraFirst {
                let st = f.style
                if st.heading > 0 { ppr += "<w:pStyle w:val=\"Heading\(st.heading)\"/>" }
                var left = st.quote * 720
                var hanging = 0
                if f.fromPDF, paraMinIndent.isFinite { left += Int(min(paraMinIndent, 180) * 20) }
                if st.listLevel > 0 && !f.fromPDF {
                    left += 360 * st.listLevel + 360
                    if paraNewItem { hanging = 360 }
                }
                if left > 0 { ppr += "<w:ind w:left=\"\(left)\"" + (hanging > 0 ? " w:hanging=\"\(hanging)\"" : "") + "/>" }
                if st.centered { ppr += "<w:jc w:val=\"center\"/>" }
            }
            switch markKind {
            case .equal: break
            case .insert: ppr += "<w:rPr><w:ins \(meta(change))/></w:rPr>"
            case .delete: ppr += "<w:rPr><w:del \(meta(change))/></w:rPr>"
            }
            body += "<w:p>" + (ppr.isEmpty ? "" : "<w:pPr>\(ppr)</w:pPr>") + paraRuns + "</w:p>"
            lastMarkKind = markKind
            paraRuns = ""
            paraHasLiveText = false
            paraFirst = nil
            paraMinIndent = .infinity
        }

        var started = false
        for p in c.pieces() {
            if p.sep == .hardBreak && started {
                // The paragraph mark belongs to whichever version introduced the break.
                let mark = p.breakKind ?? p.kind
                closeParagraph(markKind: mark, change: mark == .equal ? nil : p.change)
            }
            if paraFirst == nil {
                paraFirst = p
                paraNewItem = false
                if p.style.listLevel > 0 && !p.fromPDF {
                    let item = (p.style.listLevel, p.style.item, p.kind == .delete)   // item ids differ per version
                    paraNewItem = lastItem.map { $0 != item } ?? true
                    lastItem = item
                    if paraNewItem {
                        let marker = p.style.ordered ? "\(p.style.ordinal)." : Comparison.bullet(level: p.style.listLevel)
                        // The marker is tracked only when its whole paragraph was inserted or deleted,
                        // i.e. when the paragraph break itself belongs to one version.
                        let markerKind: PieceKind = p.sep == .hardBreak ? (p.breakKind ?? p.kind) : .equal
                        let textTag = markerKind == .delete ? "w:delText" : "w:t"
                        paraRuns += wrap("<w:r><\(textTag)>\(marker)</\(textTag)><w:tab/></w:r>", markerKind, p.change)
                    }
                } else if p.style.listLevel == 0 {
                    lastItem = nil
                }
            }
            paraMinIndent = min(paraMinIndent, p.style.indent)
            let atStart = paraRuns.isEmpty && buf.isEmpty
            if p.kind != bufKind || p.change != bufChange || p.style != bufStyle {
                flush(); bufKind = p.kind; bufChange = p.change; bufStyle = p.style
            }
            // No leading space for an insertion that opens its paragraph – unless the previous paragraph
            // mark is deleted, in which case accepting joins the paragraphs and the space is needed.
            let leadingInsert = p.kind == .insert && !paraHasLiveText && lastMarkKind != .delete
            if started && !atStart && !leadingInsert && (p.sep == .space || p.sep == .softBreak) { buf += " " }
            buf += p.text
            if p.kind != .delete { paraHasLiveText = true }
            started = true
        }
        closeParagraph(markKind: .equal, change: nil)

        let ns = "xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\""
        let document = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document \(ns) xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><w:body>\(body)<w:sectPr><w:footerReference w:type="default" r:id="rId3"/><w:pgSz w:w="11906" w:h="16838"/><w:pgMar w:top="1440" w:right="1440" w:bottom="1440" w:left="1440" w:header="708" w:footer="708" w:gutter="0"/></w:sectPr></w:body></w:document>
        """
        let styles = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:styles \(ns)><w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:ascii="Calibri" w:hAnsi="Calibri" w:eastAsia="Calibri" w:cs="Calibri"/><w:sz w:val="22"/><w:szCs w:val="22"/></w:rPr></w:rPrDefault><w:pPrDefault><w:pPr><w:spacing w:after="160" w:line="276" w:lineRule="auto"/></w:pPr></w:pPrDefault></w:docDefaults><w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/><w:qFormat/></w:style><w:style w:type="paragraph" w:styleId="Heading1"><w:name w:val="heading 1"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:qFormat/><w:pPr><w:keepNext/><w:spacing w:before="360" w:after="80"/><w:outlineLvl w:val="0"/></w:pPr><w:rPr><w:b/><w:bCs/></w:rPr></w:style><w:style w:type="paragraph" w:styleId="Heading2"><w:name w:val="heading 2"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:qFormat/><w:pPr><w:keepNext/><w:spacing w:before="280" w:after="80"/><w:outlineLvl w:val="1"/></w:pPr><w:rPr><w:b/><w:bCs/></w:rPr></w:style><w:style w:type="paragraph" w:styleId="Heading3"><w:name w:val="heading 3"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:qFormat/><w:pPr><w:keepNext/><w:spacing w:before="240" w:after="80"/><w:outlineLvl w:val="2"/></w:pPr><w:rPr><w:b/><w:bCs/></w:rPr></w:style><w:style w:type="paragraph" w:styleId="Heading4"><w:name w:val="heading 4"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:qFormat/><w:pPr><w:keepNext/><w:spacing w:before="200" w:after="80"/><w:outlineLvl w:val="3"/></w:pPr><w:rPr><w:b/><w:bCs/></w:rPr></w:style><w:style w:type="paragraph" w:styleId="Heading5"><w:name w:val="heading 5"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:qFormat/><w:pPr><w:keepNext/><w:spacing w:before="160" w:after="80"/><w:outlineLvl w:val="4"/></w:pPr><w:rPr><w:b/><w:bCs/></w:rPr></w:style><w:style w:type="paragraph" w:styleId="Heading6"><w:name w:val="heading 6"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:qFormat/><w:pPr><w:keepNext/><w:spacing w:before="160" w:after="80"/><w:outlineLvl w:val="5"/></w:pPr><w:rPr><w:b/><w:bCs/></w:rPr></w:style></w:styles>
        """
        let footer = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:ftr \(ns)><w:p><w:pPr><w:jc w:val="center"/></w:pPr><w:r><w:rPr><w:color w:val="808080"/><w:sz w:val="16"/></w:rPr><w:t xml:space="preserve">\(esc(Credit.text))</w:t></w:r></w:p></w:ftr>
        """
        let settings = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:settings \(ns)><w:trackRevisions/></w:settings>
        """
        let contentTypes = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/><Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/><Override PartName="/word/footer1.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.footer+xml"/><Override PartName="/word/settings.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.settings+xml"/><Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/></Types>
        """
        let rels = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/></Relationships>
        """
        let docRels = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/settings" Target="settings.xml"/><Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/footer" Target="footer1.xml"/></Relationships>
        """
        let title = esc("Comparison: \(c.original.title) → \(c.revised.title)")
        let core = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:dcterms="http://purl.org/dc/terms/" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"><dc:title>\(title)</dc:title><dc:creator>Differ</dc:creator><dc:description>\(esc(Credit.text))</dc:description><dcterms:created xsi:type="dcterms:W3CDTF">\(now)</dcterms:created></cp:coreProperties>
        """
        var zip = ZipWriter()
        zip.add("[Content_Types].xml", contentTypes)
        zip.add("_rels/.rels", rels)
        zip.add("docProps/core.xml", core)
        zip.add("word/document.xml", document)
        zip.add("word/styles.xml", styles)
        zip.add("word/settings.xml", settings)
        zip.add("word/footer1.xml", footer)
        zip.add("word/_rels/document.xml.rels", docRels)
        try zip.finish().write(to: url, options: .atomic)
    }
}

/// Minimal ZIP writer (stored entries). Sufficient for Office Open XML packages.
struct ZipWriter {
    private var data = Data()
    private var central = Data()
    private var count: UInt16 = 0

    private static let crcTable: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1 }
        return c
    }
    private static func crc32(_ d: Data) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for b in d { c = crcTable[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }
    private static func le16(_ v: UInt16, _ d: inout Data) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
    private static func le32(_ v: UInt32, _ d: inout Data) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }

    mutating func add(_ name: String, _ text: String) {
        let content = Data(text.utf8)
        let nameData = Data(name.utf8)
        let crc = Self.crc32(content)
        let offset = UInt32(data.count)
        let (dosTime, dosDate): (UInt16, UInt16) = (0, (2026 - 1980) << 9 | 1 << 5 | 1)

        Self.le32(0x04034b50, &data)
        Self.le16(20, &data); Self.le16(0x0800, &data); Self.le16(0, &data)
        Self.le16(dosTime, &data); Self.le16(dosDate, &data)
        Self.le32(crc, &data); Self.le32(UInt32(content.count), &data); Self.le32(UInt32(content.count), &data)
        Self.le16(UInt16(nameData.count), &data); Self.le16(0, &data)
        data.append(nameData); data.append(content)

        Self.le32(0x02014b50, &central)
        Self.le16(20, &central); Self.le16(20, &central); Self.le16(0x0800, &central); Self.le16(0, &central)
        Self.le16(dosTime, &central); Self.le16(dosDate, &central)
        Self.le32(crc, &central); Self.le32(UInt32(content.count), &central); Self.le32(UInt32(content.count), &central)
        Self.le16(UInt16(nameData.count), &central); Self.le16(0, &central); Self.le16(0, &central)
        Self.le16(0, &central); Self.le16(0, &central); Self.le32(0, &central); Self.le32(offset, &central)
        central.append(nameData)
        count += 1
    }

    mutating func finish() -> Data {
        var out = data
        let cdOffset = UInt32(out.count)
        out.append(central)
        Self.le32(0x06054b50, &out)
        Self.le16(0, &out); Self.le16(0, &out)
        Self.le16(count, &out); Self.le16(count, &out)
        Self.le32(UInt32(central.count), &out); Self.le32(cdOffset, &out)
        Self.le16(0, &out)
        return out
    }
}

// MARK: - PDF of the tracked-changes view

enum TrackedPDFExporter {
    @MainActor
    static func export(_ c: Comparison, dates: [Int: ChangeDating], reflow: Bool, to url: URL) throws {
        let (body, _) = c.trackedText(.init(reflow: reflow, forPrint: true, showPageMarkers: false, dates: dates))
        let doc = NSMutableAttributedString()
        let h = NSFont.boldSystemFont(ofSize: 15)
        let small = NSFont.systemFont(ofSize: 9.5)
        func src(_ d: SourceDoc) -> String {
            var s = d.title
            if case .web(let u) = d.ref { s += " — \(u.absoluteString)" }
            if let dt = d.date { s += " (\(DateText.medium(dt)))" }
            return s
        }
        doc.append(NSAttributedString(string: "Comparison\n", attributes: [.font: h, .foregroundColor: NSColor.black]))
        var head = "Original: \(src(c.original))\nRevised: \(src(c.revised))\n"
        head += "\(c.insertions) insertions · \(c.deletions) deletions · \(c.replacements) replacements"
        if !dates.isEmpty { head += " · dates in [brackets] show when each change first appeared in the Wayback Machine" }
        doc.append(NSAttributedString(string: head + "\n\n", attributes: [.font: small, .foregroundColor: NSColor.darkGray]))
        doc.append(body)
        let creditPara = NSMutableParagraphStyle()
        creditPara.alignment = .center
        creditPara.paragraphSpacingBefore = 18
        doc.append(NSAttributedString(string: "\n" + Credit.text, attributes: [
            .font: NSFont.systemFont(ofSize: 8.5), .foregroundColor: NSColor.gray, .paragraphStyle: creditPara]))

        let info = NSPrintInfo()
        info.paperSize = NSPrintInfo.shared.paperSize
        info.topMargin = 54; info.bottomMargin = 54; info.leftMargin = 60; info.rightMargin = 60
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isVerticallyCentered = false
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url

        let width = info.paperSize.width - info.leftMargin - info.rightMargin
        let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 100))
        tv.isEditable = false
        tv.drawsBackground = false
        tv.textContainerInset = .zero
        tv.textContainer?.lineFragmentPadding = 0
        tv.textStorage?.setAttributedString(doc)
        tv.isVerticallyResizable = true
        tv.layoutManager?.ensureLayout(for: tv.textContainer!)
        tv.sizeToFit()
        tv.appearance = NSAppearance(named: .aqua)

        let op = NSPrintOperation(view: tv, printInfo: info)
        op.showsPrintPanel = false
        op.showsProgressPanel = false
        if !op.run() { throw CocoaError(.fileWriteUnknown) }
    }
}

enum AnnotatedPDFExporter {
    static func export(_ doc: SourceDoc, to url: URL) throws {
        guard let pdf = doc.pdf else { return }
        if !pdf.write(to: url) { throw CocoaError(.fileWriteUnknown) }
    }
}
