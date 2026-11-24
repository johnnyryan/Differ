import SwiftUI
import AppKit
import WebKit

enum Credit {
    static let text = "Differ. Johnny Ryan 2026"
}

@main
enum Main {
    static func main() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--compare") {
            CLI.run(Array(args[(i + 1)...]))
        } else if let i = args.firstIndex(of: "--captures"), i + 1 < args.count {
            CLI.captures(args[i + 1], changedOnly: !args.contains("--daily"))
        } else {
            PDFDiffApp.main()
        }
    }
}

struct PDFDiffApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        // The main window is created by AppDelegate (see showMainWindow) so that it also opens
        // when the app is launched by dropping files on its icon or via "Open With".
        Settings {
            SettingsView().environmentObject(model)
        }
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Differ") {
                    NSApp.orderFrontStandardAboutPanel(options: [
                        .credits: NSAttributedString(string: Credit.text, attributes: [
                            .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]),
                    ])
                }
            }
            CommandGroup(replacing: .newItem) {
                Button("Choose Original PDF…") { delegate.showMainWindow(); model.choosePDF(original: true) }.keyboardShortcut("o")
                Button("Choose Revised PDF…") { delegate.showMainWindow(); model.choosePDF(original: false) }.keyboardShortcut("o", modifiers: [.command, .shift])
                Button("Enter Web Addresses…") { delegate.showMainWindow(); model.showingSources = true }.keyboardShortcut("l")
                Divider()
                Button("Compare") { model.compare() }.keyboardShortcut("r")
                    .disabled(model.original == nil || model.revised == nil)
                Button("Swap Original and Revised") { model.swap() }
            }
            CommandGroup(after: .saveItem) {
                Button("Export Word Document with Tracked Changes…") { model.exportDocx() }
                    .keyboardShortcut("e").disabled(model.comparison == nil)
                Button("Export PDF of Tracked Changes…") { model.exportPDF() }
                    .keyboardShortcut("e", modifiers: [.command, .shift]).disabled(model.comparison == nil)
            }
            CommandMenu("Changes") {
                Button("Next Change") { model.step(1) }.keyboardShortcut("]")
                Button("Previous Change") { model.step(-1) }.keyboardShortcut("[")
                Divider()
                Picker("View", selection: $model.mode) {
                    Text("Tracked Changes").tag(ViewMode.tracked).keyboardShortcut("1")
                    Text("Side by Side").tag(ViewMode.sideBySide).keyboardShortcut("2")
                    Text("On Page").tag(ViewMode.onPage).keyboardShortcut("3")
                }
                Toggle("Reflow Lines into Paragraphs", isOn: $model.reflow)
            }
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        Form {
            Toggle("Ignore differences in letter case", isOn: $model.ignoreCase)
            Toggle("Annotate changes with dates from the Wayback Machine", isOn: $model.annotateDates)
            Toggle("Reflow PDF lines into paragraphs", isOn: $model.reflow)
            Picker("Render web pages with JavaScript", selection: $model.renderMode) {
                ForEach(RenderMode.allCases) { Text($0.label).tag($0) }
            }
            Text("Text inside collapsed sections is always included. Rendering additionally runs the page and clicks every expand control, for sites that load hidden text only on demand. It is slower.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .formStyle(.grouped)
        .frame(width: 460)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?

    func showMainWindow() {
        if let w = window { w.makeKeyAndOrderFront(nil); NSApp.activate(); return }
        let root = ContentView()
            .environmentObject(AppModel.shared)
            .frame(minWidth: 960, minHeight: 620)
        let hc = NSHostingController(rootView: root)
        hc.sceneBridgingOptions = [.toolbars, .title]
        let w = NSWindow(contentViewController: hc)
        w.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        w.toolbarStyle = .unified
        w.title = "Differ"
        w.isReleasedWhenClosed = false
        w.setContentSize(NSSize(width: 1320, height: 860))
        w.center()
        w.setFrameAutosaveName("PDFDiffMainWindow")
        window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    // AppKit routes file paths given at launch, Dock drops and "Open With" here.
    func application(_ application: NSApplication, open urls: [URL]) {
        showMainWindow()
        AppModel.shared.accept(urls, preferOriginal: nil)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow(); return true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        showMainWindow()
        // Sources on the command line, unless AppKit already delivered them through application(_:open:).
        let m = AppModel.shared
        if m.original == nil && m.revised == nil {
            let urls = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") }.compactMap { a -> URL? in
                a.contains("://") ? URL(string: a) : (FileManager.default.fileExists(atPath: a) ? URL(fileURLWithPath: a) : nil)
            }
            if !urls.isEmpty { m.accept(urls, preferOriginal: nil) }
        }

        // Debug aid: PDFDIFF_SNAPSHOT_WEB=/path/prefix captures the Web Page view (WebKit draws out of process).
        if let prefix = ProcessInfo.processInfo.environment["PDFDIFF_SNAPSHOT_WEB"] {
            let delay = Double(ProcessInfo.processInfo.environment["PDFDIFF_SNAPSHOT_DELAY"] ?? "") ?? 60
            AppModel.shared.mode = .onPage
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                Self.snapshot(prefix + "-window.png")
                Self.snapshotWeb(prefix + "-1.png") {
                    let m = AppModel.shared
                    let target = m.comparison?.infos.first { $0.kind == .replacement && $0.removed.count > 8 }?.id
                    m.selectedChangeID = target
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                        Self.snapshotWeb(prefix + "-2.png") { NSApp.terminate(nil) }
                    }
                }
            }
            return
        }

        // Debug aid: PDFDIFF_SNAPSHOT=/path/prefix renders the window to PNGs (no screen-recording permission needed).
        if let prefix = ProcessInfo.processInfo.environment["PDFDIFF_SNAPSHOT"] {
            let delay = Double(ProcessInfo.processInfo.environment["PDFDIFF_SNAPSHOT_DELAY"] ?? "") ?? 6
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                let m = AppModel.shared
                Self.snapshot(prefix + "-1.png")
                m.step(1); m.step(1)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    Self.snapshot(prefix + "-2.png")
                    m.mode = .sideBySide
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        Self.snapshot(prefix + "-3.png")
                        m.mode = .tracked
                        m.showingSources = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            Self.snapshot(prefix + "-4.png")
                            guard let page = ProcessInfo.processInfo.environment["PDFDIFF_SNAPSHOT_ARCHIVE"] else {
                                NSApp.terminate(nil); return
                            }
                            // Render the archive picker offscreen.
                            let host = NSHostingView(rootView: ArchivePicker(page: page, defaultOriginal: true) { _, _ in })
                            let w = NSWindow(contentRect: NSRect(x: -3000, y: 0, width: 560, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
                            w.contentView = host
                            w.orderBack(nil)
                            DispatchQueue.main.asyncAfter(deadline: .now() + 35) {
                                if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                                    host.cacheDisplay(in: host.bounds, to: rep)
                                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: prefix + "-5.png"))
                                }
                                NSApp.terminate(nil)
                            }
                        }
                    }
                }
            }
        }
    }

    static func snapshotWeb(_ path: String, then: @escaping () -> Void) {
        func find(_ v: NSView) -> WKWebView? {
            if let w = v as? WKWebView { return w }
            for s in v.subviews { if let w = find(s) { return w } }
            return nil
        }
        guard let root = NSApp.windows.first(where: { $0.isVisible })?.contentView, let wv = find(root) else { then(); return }
        wv.takeSnapshot(with: nil) { img, _ in
            if let img, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            }
            then()
        }
    }

    static func snapshot(_ path: String) {
        guard let w = NSApp.windows.filter({ $0.contentView != nil }).max(by: { $0.frame.width < $1.frame.width }),
              let view = w.contentView?.superview ?? w.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        do { try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path)) }
        catch { FileHandle.standardError.write("snapshot failed: \(error)\n".data(using: .utf8)!) }
    }
}

/// Headless mode for scripting and testing:
///   Differ --compare <original> <revised> [--dates] [--render] [--docx out.docx] [--text out.txt]
enum CLI {
    /// Differ --captures URL [--daily]: list Wayback captures of a page.
    static func captures(_ s: String, changedOnly: Bool) {
        guard let page = WaybackIndex.pageURL(for: SourceRef(string: s)) else { print("Not a web address"); exit(2) }
        Task {
            do {
                let caps = try await WaybackIndex.captures(page: page, changedOnly: changedOnly)
                print("\(caps.count) captures of \(page)")
                for c in caps.suffix(8) { print(c.timestamp, DateText.medium(c.date)) }
                exit(0)
            } catch { print("Error: \(error.localizedDescription)"); exit(1) }
        }
        RunLoop.main.run()
    }

    static func run(_ args: [String]) {
        var positional: [String] = []
        var docx: String?, text: String?, annotated: String?, onPage: String?
        var dates = false, render = false
        var i = 0
        while i < args.count {
            switch args[i] {
            case "--docx", "--text", "--annotated", "--onpage":
                guard i + 1 < args.count else { print("\(args[i]) needs a file path"); exit(2) }
                let v = args[i + 1]
                switch args[i] { case "--docx": docx = v; case "--text": text = v; case "--onpage": onPage = v; default: annotated = v }
                i += 1
            case "--dates": dates = true
            case "--render": render = true
            default: positional.append(args[i])
            }
            i += 1
        }
        guard positional.count == 2 else {
            print("usage: Differ --compare <original> <revised> [--dates] [--render] [--docx out.docx] [--text out.txt]")
            exit(2)
        }
        func ref(_ s: String) -> SourceRef? {
            s.contains("://") || s.hasPrefix("web.archive.org") ? SourceRef(string: s) : SourceRef(url: URL(fileURLWithPath: s))
        }
        guard let o = ref(positional[0]), let r = ref(positional[1]) else { print("Unsupported source"); exit(2) }

        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        Task { @MainActor in
            do {
                let t0 = Date()
                let a = try await SourceLoader.load(o, render: render ? .always : .auto)
                let b = try await SourceLoader.load(r, render: render ? .always : .auto)
                print("Original: \(a.title) — \(a.tokens.count) tokens\(a.rendered ? " (rendered)" : "")\(a.date.map { ", " + DateText.medium($0) } ?? "")")
                print("Revised:  \(b.title) — \(b.tokens.count) tokens\(b.rendered ? " (rendered)" : "")\(b.date.map { ", " + DateText.medium($0) } ?? "")")
                let t1 = Date()
                let c = Comparison.run(original: a, revised: b, ignoreCase: false)
                print(String(format: "Loaded in %.1fs, diffed in %.2fs", t1.timeIntervalSince(t0), Date().timeIntervalSince(t1)))
                print("\(c.changes.count) changes: \(c.insertions) insertions, \(c.deletions) deletions, \(c.replacements) replacements")
                var found: [Int: ChangeDating] = [:]
                if dates {
                    if let why = ChangeDater.check(c) { print("Dating unavailable: \(why.rawValue)") }
                    else {
                        await ChangeDater.run(c, render: render ? .always : .auto,
                                              progress: { s in if let s { print("  · \(s)") } },
                                              update: { found = $0 })
                    }
                }
                for info in c.infos.prefix(40) {
                    var line = "#\(info.id) "
                    if !info.removed.isEmpty { line += "[-\(info.removed.prefix(90))-]" }
                    if !info.added.isEmpty { line += "{+\(info.added.prefix(90))+}" }
                    if let d = found[info.id] { line += "  @ \(d.label)" }
                    print(line)
                }
                if c.infos.count > 40 { print("… \(c.infos.count - 40) more") }
                if let docx {
                    try DocxExporter.export(c, dates: found, to: URL(fileURLWithPath: docx))
                    print("Wrote \(docx)")
                }
                if let onPage, let m = c.buildOnPage(dates: found) {
                    _ = m.document.write(to: URL(fileURLWithPath: onPage))
                    print("Wrote \(onPage) (\(m.marked) of \(c.changes.count) changes marked)")
                }
                if let annotated {
                    try AnnotatedPDFExporter.export(c.revised, to: URL(fileURLWithPath: annotated + "-revised.pdf"))
                    try AnnotatedPDFExporter.export(c.original, to: URL(fileURLWithPath: annotated + "-original.pdf"))
                    print("Wrote \(annotated)-original.pdf and -revised.pdf")
                }
                if let text {
                    var s = ""
                    var cur: PieceKind = .equal
                    for p in c.pieces() {
                        let sep: String = { switch p.sep { case .none: return ""; case .space, .softBreak: return " "; case .hardBreak: return "\n\n" } }()
                        if p.kind != cur {
                            if cur == .delete { s += "-]" } else if cur == .insert { s += "+}" }
                            s += sep
                            if p.kind == .delete { s += "[-" } else if p.kind == .insert { s += "{+" }
                            cur = p.kind
                        } else { s += sep }
                        s += p.text
                    }
                    if cur == .delete { s += "-]" } else if cur == .insert { s += "+}" }
                    try s.write(toFile: text, atomically: true, encoding: .utf8)
                    print("Wrote \(text)")
                }
                exit(0)
            } catch {
                print("Error: \(error.localizedDescription)")
                exit(1)
            }
        }
        RunLoop.main.run()
    }
}
