import SwiftUI
import AppKit
import WebKit

/// "Web Page" view: the newer version rendered with its own styling, with deletions and insertions
/// written into the page. The page's own words are tokenised in the browser, aligned with the compared
/// text, and the changes are wrapped in <ins>/<del> at the matching places. Collapsed containers that
/// hold a change are forced open.
@MainActor
final class WebDiffState: ObservableObject {
    enum Phase: Equatable { case loading, expanding, marking, ready(placed: Int, total: Int), failed(String) }
    @Published var phase: Phase = .loading
}

struct WebPageView: View {
    @EnvironmentObject var model: AppModel
    let c: Comparison
    @StateObject private var state = WebDiffState()

    var body: some View {
        ZStack(alignment: .top) {
            WebDiffRepresentable(comparison: c, state: state,
                                 selectedID: model.selectedChangeID,
                                 dates: model.dates, datesVersion: model.datesVersion,
                                 onClick: { model.selectedChangeID = $0 })
            banner
                .padding(8)
        }
    }

    @ViewBuilder private var banner: some View {
        switch state.phase {
        case .loading: status("Loading the page…", busy: true)
        case .expanding: status("Opening collapsed sections…", busy: true)
        case .marking: status("Marking changes on the page…", busy: true)
        case .failed(let m): status(m, busy: false, warning: true)
        case .ready(let placed, let total):
            if placed < total {
                status("\(placed) of \(total) changes marked on the page. The rest are in text the page did not show (see Tracked Changes).",
                       busy: false).transition(.opacity)
            }
        }
    }

    private func status(_ s: String, busy: Bool, warning: Bool = false) -> some View {
        HStack(spacing: 8) {
            if busy { ProgressView().controlSize(.small) }
            if warning { Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange) }
            Text(s).font(.caption)
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(.regularMaterial, in: Capsule())
        .shadow(radius: 2, y: 1)
    }
}

struct WebDiffRepresentable: NSViewRepresentable {
    let comparison: Comparison
    let state: WebDiffState
    let selectedID: Int?
    let dates: [Int: ChangeDating]
    let datesVersion: Int
    let onClick: (Int) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(comparison: comparison, state: state) }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.userContentController.add(WeakHandler(context.coordinator), contentWorld: .defaultClient, name: "pdfdiff")
        let wv = WKWebView(frame: .zero, configuration: config)
        wv.navigationDelegate = context.coordinator
        wv.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
        context.coordinator.webView = wv
        context.coordinator.start()
        return wv
    }

    func updateNSView(_ wv: WKWebView, context: Context) {
        let co = context.coordinator
        co.onClick = onClick
        co.pendingSelection = selectedID
        co.pendingDates = (datesVersion, dates)
        co.flush()
    }

    static func dismantleNSView(_ wv: WKWebView, coordinator: Coordinator) {
        wv.stopLoading()
        wv.configuration.userContentController.removeAllScriptMessageHandlers()
    }

    /// Avoids the retain cycle WKUserContentController creates with its handlers.
    final class WeakHandler: NSObject, WKScriptMessageHandler {
        weak var target: Coordinator?
        init(_ t: Coordinator) { target = t }
        func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
            if let id = m.body as? Int { target?.onClick?(id) }
            else if let n = m.body as? NSNumber { target?.onClick?(n.intValue) }
        }
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        let comparison: Comparison
        let state: WebDiffState
        weak var webView: WKWebView?
        var onClick: ((Int) -> Void)?
        var pendingSelection: Int?
        var pendingDates: (Int, [Int: ChangeDating]) = (-1, [:])
        private var shownSelection: Int?
        private var shownDatesVersion = -2
        private var loaded = false
        private var ready = false

        init(comparison: Comparison, state: WebDiffState) {
            self.comparison = comparison
            self.state = state
        }

        var pageURL: URL {
            let u = comparison.revised.ref.url
            return WaybackRef(u)?.frameURL ?? u
        }

        func start() {
            state.phase = .loading
            webView?.load(URLRequest(url: pageURL))
            DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in
                guard let self, !self.loaded else { return }
                self.loaded = true
                Task { await self.markUp() }   // mark what has loaded so far
            }
        }

        // MARK: Navigation

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard !loaded else { return }
            loaded = true
            Task { await markUp() }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failIfNotLoaded(error) }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failIfNotLoaded(error) }

        private func failIfNotLoaded(_ error: Error) {
            guard !loaded else { return }
            if (error as NSError).code == NSURLErrorCancelled { return }
            state.phase = .failed("The page could not be loaded: \(error.localizedDescription)")
        }

        /// Clicking the page never loads anything: links are ignored. Only the initial load (and its
        /// redirects, plus sub-frames before mark-up) may navigate.
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if action.navigationType == .linkActivated || action.navigationType == .formSubmitted {
                decisionHandler(.cancel); return
            }
            if loaded && action.targetFrame?.isMainFrame != false { decisionHandler(.cancel); return }
            decisionHandler(.allow)
        }

        // MARK: Mark-up

        private func js(_ body: String, _ args: [String: Any] = [:]) async throws -> Any? {
            guard let wv = webView else { return nil }
            return try await wv.callAsyncJavaScript(body, arguments: args, in: nil, contentWorld: .defaultClient)
        }

        private func markUp() async {
            do {
                try await Task.sleep(nanoseconds: 1_200_000_000)
                state.phase = .expanding
                for _ in 0..<4 {
                    let n = (try? await js("return " + PageRenderer.expandScript)) as? Int ?? 0
                    try await Task.sleep(nanoseconds: 700_000_000)
                    if n == 0 { break }
                }
                state.phase = .marking
                _ = try await js(Self.engine + "\nreturn 1;")
                guard let words = try await js("return window.__pdfdiff.tokenize();") as? [String] else {
                    state.phase = .failed("The page's text could not be read.")
                    return
                }
                let (ops, placed) = buildOps(pageWords: words)
                _ = try await js("return window.__pdfdiff.apply(ops);", ["ops": ops])
                ready = true
                state.phase = .ready(placed: placed, total: comparison.changes.count)
                shownSelection = nil
                shownDatesVersion = -2
                flush()
            } catch {
                state.phase = .failed("Marking the page failed: \(error.localizedDescription)")
            }
        }

        /// Aligns the revised document's words with the words the page actually shows, then turns every
        /// change into an operation on page word indices.
        private func buildOps(pageWords: [String]) -> ([[String: Any]], Int) {
            var interner = comparison.interner
            func key(_ s: String) -> Int {
                let k = TextExtractor.normalize(s, ignoreCase: comparison.ignoreCase)
                if let id = interner[k] { return id }
                let id = interner.count; interner[k] = id; return id
            }
            let r = comparison.revised.tokens.map(\.key)
            let d = pageWords.map(key)
            var map = [Int: Int]()
            for (a, b) in Differ.matches(r, d) { map[a] = b }

            var ops: [[String: Any]] = []
            var placed = 0
            for ch in comparison.changes {
                var did = false
                let insIdx = ch.b.compactMap { map[$0] }
                if !insIdx.isEmpty {
                    ops.append(["type": "ins", "c": ch.id, "d": insIdx])
                    did = true
                }
                if !ch.a.isEmpty {
                    var anchor: (Int, Bool)?
                    if let first = insIdx.first { anchor = (first, false) }
                    else if ch.b.lowerBound < r.count, let x = map[ch.b.upperBound < r.count ? ch.b.upperBound : ch.b.lowerBound] {
                        anchor = (x, false)
                    } else if ch.b.lowerBound > 0, let x = map[ch.b.lowerBound - 1] {
                        anchor = (x, true)
                    }
                    if let (at, after) = anchor {
                        let text = Comparison.join(comparison.original.tokens[ch.a])
                        ops.append(["type": "del", "c": ch.id, "text": text, "at": at, "after": after])
                        did = true
                    }
                }
                if did { placed += 1 }
            }
            return (ops, placed)
        }

        /// Applies the latest selection and date tags once the page is ready.
        func flush() {
            guard ready else { return }
            if pendingDates.0 != shownDatesVersion {
                shownDatesVersion = pendingDates.0
                var labels: [String: String] = [:]
                for (id, d) in pendingDates.1 { labels[String(id)] = "[\(d.label)]" }
                Task { _ = try? await js("return window.__pdfdiff.setDates(labels);", ["labels": labels]) }
            }
            if pendingSelection != shownSelection {
                shownSelection = pendingSelection
                if let id = pendingSelection {
                    Task { _ = try? await js("return window.__pdfdiff.select(id);", ["id": id]) }
                }
            }
        }

        // MARK: In-page engine (runs in an isolated content world; shares the page's DOM)

        static let engine = #"""
        if (!window.__pdfdiff) window.__pdfdiff = (() => {
          const SKIP = new Set(['SCRIPT','STYLE','NOSCRIPT','TEMPLATE','SVG','SELECT','IFRAME','CANVAS','OBJECT','MATH','VIDEO','AUDIO','MAP','HEAD','TITLE','TEXTAREA','INS','DEL']);
          const RE = /[\p{L}\p{N}\p{M}]+(?:['’][\p{L}\p{N}\p{M}]+)*|[^\s\p{L}\p{N}\p{M}]/gu;
          let toks = [], order = new Map();

          function tokenize() {
            toks = []; order = new Map();
            const w = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, { acceptNode(n) {
              for (let p = n.parentElement; p && p !== document.body; p = p.parentElement)
                if (SKIP.has(p.tagName.toUpperCase())) return NodeFilter.FILTER_REJECT;
              return NodeFilter.FILTER_ACCEPT; } });
            let n, k = 0;
            while ((n = w.nextNode())) {
              order.set(n, k++);
              const s = n.nodeValue; RE.lastIndex = 0; let m;
              while ((m = RE.exec(s))) toks.push({ n, s: m.index, e: m.index + m[0].length, t: m[0] });
            }
            return toks.map(x => x.t);
          }

          function reveal(el) {
            for (let p = el.parentElement; p && p !== document.documentElement; p = p.parentElement) {
              if (p.tagName === 'DETAILS') p.open = true;
              if (p.hasAttribute('hidden')) p.removeAttribute('hidden');
              const cs = getComputedStyle(p);
              if (cs.display === 'none') p.style.setProperty('display', 'block', 'important');
              if (cs.visibility === 'hidden' || cs.visibility === 'collapse') p.style.setProperty('visibility', 'visible', 'important');
              if (parseFloat(cs.opacity) === 0) p.style.setProperty('opacity', '1', 'important');
              if (cs.maxHeight === '0px') p.style.setProperty('max-height', 'none', 'important');
              if ((cs.height === '0px' || parseFloat(cs.height) < 2) && cs.overflow !== 'visible') {
                p.style.setProperty('height', 'auto', 'important');
                p.style.setProperty('overflow', 'visible', 'important');
              }
              if (cs.clipPath && cs.clipPath !== 'none') p.style.setProperty('clip-path', 'none', 'important');
            }
          }

          function apply(ops) {
            if (!document.getElementById('pdfdiff-style')) {
              const st = document.createElement('style'); st.id = 'pdfdiff-style';
              st.textContent = `
                ins.pdfdiff-ins{background:rgba(46,160,67,.22)!important;color:#0a6b2a!important;text-decoration:underline!important;text-decoration-color:#0a6b2a!important;cursor:pointer}
                del.pdfdiff-del{background:rgba(220,40,40,.14)!important;color:#b0191b!important;text-decoration:line-through!important;margin-right:.3em;cursor:pointer}
                .pdfdiff-date{font:600 10px -apple-system,system-ui,sans-serif!important;color:#1f4fa8!important;margin-left:3px;vertical-align:super;white-space:nowrap}
                .pdfdiff-flash{outline:3px solid #ffb300!important;outline-offset:2px}`;
              document.head.appendChild(st);
              document.addEventListener('click', e => {
                const t = e.target.closest && e.target.closest('[data-pdfdiff]');
                if (t) { e.preventDefault(); e.stopPropagation(); window.webkit.messageHandlers.pdfdiff.postMessage(parseInt(t.dataset.pdfdiff)); return; }
                if (e.target.closest && e.target.closest('a[href], area[href]')) { e.preventDefault(); }
              }, true);
            }
            const work = [];
            for (const op of ops) {
              if (op.type === 'ins') {
                let g = null;
                for (const i of op.d) {
                  const t = toks[i]; if (!t) continue;
                  if (g && g.node === t.n && i === g.last + 1) { g.end = t.e; g.last = i; }
                  else { if (g) work.push(g); g = { node: t.n, start: t.s, end: t.e, last: i, kind: 0, c: op.c }; }
                }
                if (g) work.push(g);
              } else {
                const t = toks[op.at]; if (!t) continue;
                const off = op.after ? t.e : t.s;
                work.push({ node: t.n, start: off, end: off, kind: 1, c: op.c, text: op.text });
              }
            }
            // Last node first, highest offset first, so earlier offsets stay valid while splitting.
            work.sort((a, b) => (order.get(b.node) - order.get(a.node)) || (b.start - a.start) || (a.kind - b.kind));
            const made = [];
            for (const w of work) {
              const node = w.node;
              if (!node.parentNode) continue;
              if (w.kind === 0) {
                if (w.end < node.length) node.splitText(w.end);
                const mid = w.start > 0 ? node.splitText(w.start) : node;
                const el = document.createElement('ins');
                el.className = 'pdfdiff-ins'; el.dataset.pdfdiff = w.c;
                mid.parentNode.insertBefore(el, mid); el.appendChild(mid);
                made.push(el);
              } else {
                const right = node.splitText(Math.min(w.start, node.length));
                const el = document.createElement('del');
                el.className = 'pdfdiff-del'; el.dataset.pdfdiff = w.c; el.textContent = w.text;
                right.parentNode.insertBefore(el, right);
                made.push(el);
              }
            }
            made.forEach(reveal);
            return made.length;
          }

          function setDates(labels) {
            document.querySelectorAll('.pdfdiff-date').forEach(e => e.remove());
            for (const id in labels) {
              const els = document.querySelectorAll(`[data-pdfdiff="${id}"]`);
              if (!els.length) continue;
              const sup = document.createElement('span');
              sup.className = 'pdfdiff-date'; sup.dataset.pdfdiff = id; sup.textContent = labels[id];
              els[els.length - 1].insertAdjacentElement('afterend', sup);
            }
            return 1;
          }

          function select(id) {
            document.querySelectorAll('.pdfdiff-flash').forEach(e => e.classList.remove('pdfdiff-flash'));
            const els = document.querySelectorAll(`[data-pdfdiff="${id}"]`);
            if (!els.length) return 0;
            els.forEach(e => e.classList.add('pdfdiff-flash'));
            els[0].scrollIntoView({ block: 'center', behavior: 'smooth' });
            setTimeout(() => els.forEach(e => e.classList.remove('pdfdiff-flash')), 1600);
            return 1;
          }

          return { tokenize, apply, setDates, select };
        })();
        """#
    }
}
