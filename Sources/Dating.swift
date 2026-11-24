import Foundation

/// Works out when each change first appeared, using Wayback Machine captures that lie
/// between the two compared versions. For every change, a short "signature" (the new
/// wording plus a few words of unchanged context) is checked against snapshots, and the
/// snapshot list is bisected until the change is bracketed by two adjacent captures.
enum ChangeDater {
    struct Point { let date: Date; let timestamp: String?; let viewURL: URL? }

    enum Ineligible: String {
        case notWeb = "Change dates are available when comparing web pages."
        case noArchive = "Change dates need at least one Wayback Machine (web.archive.org) version."
        case differentPages = "The two versions are different pages, so change dates cannot be traced."
        case order = "The original is newer than the revised version, so change dates cannot be traced. Use Swap."
    }

    static func check(_ c: Comparison) -> Ineligible? {
        guard case .web = c.original.ref, case .web = c.revised.ref else { return .notWeb }
        guard c.original.ref.wayback != nil || c.revised.ref.wayback != nil else { return .noArchive }
        guard let p1 = c.original.pageURL, let p2 = c.revised.pageURL,
              pageKey(p1.absoluteString) == pageKey(p2.absoluteString) else { return .differentPages }
        guard let d1 = c.original.date, let d2 = c.revised.date, d1 < d2 else { return .order }
        return nil
    }

    static func cdx(page: String, from: Date, to: Date?) async throws -> [(String, Date)] {
        var comps = URLComponents(string: "https://web.archive.org/cdx/search/cdx")!
        var q = [
            URLQueryItem(name: "url", value: page),
            URLQueryItem(name: "output", value: "json"),
            URLQueryItem(name: "fl", value: "timestamp,digest,statuscode"),
            URLQueryItem(name: "filter", value: "statuscode:200"),
            URLQueryItem(name: "collapse", value: "digest"),
            URLQueryItem(name: "from", value: DateText.waybackStamp(from.addingTimeInterval(1))),
        ]
        if let to { q.append(URLQueryItem(name: "to", value: DateText.waybackStamp(to.addingTimeInterval(-1)))) }
        comps.queryItems = q
        let (data, _) = try await Fetcher.get(comps.url!)
        guard !data.isEmpty, let rows = try JSONSerialization.jsonObject(with: data) as? [[String]] else { return [] }
        return rows.dropFirst().compactMap { r in
            guard let ts = r.first else { return nil }
            let d = WaybackRef(timestamp: ts, original: page).date
            if d <= from { return nil }
            if let to, d >= to { return nil }
            return (ts, d)
        }
    }

    private static func contains(_ h: [Int], _ n: [Int]) -> Bool {
        guard let f = n.first, n.count <= h.count else { return false }
        let last = h.count - n.count
        var i = 0
        while i <= last {
            if h[i] == f {
                var ok = true
                var t = 1
                while t < n.count { if h[i + t] != n[t] { ok = false; break }; t += 1 }
                if ok { return true }
            }
            i += 1
        }
        return false
    }

    static func run(_ c: Comparison, render: RenderMode, maxSnapshots: Int = 48,
                    progress: @escaping @MainActor (String?) -> Void,
                    update: @escaping @MainActor ([Int: ChangeDating]) -> Void) async {
        guard check(c) == nil, let oDate = c.original.date, let rDate = c.revised.date,
              let page = (c.original.pageURL ?? c.revised.pageURL)?.absoluteString else { return }
        if c.changes.isEmpty { return }

        await progress("Looking up Wayback Machine captures…")
        var snaps: [(String, Date)]
        do {
            snaps = try await cdx(page: page, from: oDate, to: c.revised.ref.wayback != nil ? rDate : nil)
        } catch {
            if !Task.isCancelled { await progress("Could not query the Wayback Machine: \(error.localizedDescription)") }
            return
        }
        if snaps.count > maxSnapshots {
            let n = snaps.count
            snaps = (0..<maxSnapshots).map { snaps[Int((Double($0) * Double(n - 1) / Double(maxSnapshots - 1)).rounded())] }
        }

        let points: [Point] = [Point(date: oDate, timestamp: nil, viewURL: c.original.ref.url)]
            + snaps.map { Point(date: $0.1, timestamp: $0.0, viewURL: WaybackRef(timestamp: $0.0, original: page).viewURL) }
            + [Point(date: rDate, timestamp: nil, viewURL: c.revised.ref.url)]
        let last = points.count - 1

        var interner = c.interner
        func intern(_ s: String) -> Int {
            if let id = interner[s] { return id }
            let id = interner.count; interner[s] = id; return id
        }
        var cache: [Int: [Int]] = [0: c.original.tokens.map(\.key), last: c.revised.tokens.map(\.key)]
        var bad = Set<Int>()

        // Signatures: changed wording plus up to four words of context, without crossing neighbouring changes.
        let b = c.revised.tokens
        var sig: [Int: [Int]] = [:]
        var prevEnd = 0
        for (k, ch) in c.changes.enumerated() {
            let nextStart = k + 1 < c.changes.count ? c.changes[k + 1].b.lowerBound : b.count
            let lo = max(prevEnd, ch.b.lowerBound - 4)
            let hi = min(nextStart, ch.b.upperBound + 4)
            prevEnd = ch.b.upperBound
            guard lo < hi else { continue }
            let s = b[lo..<hi].map(\.key)
            if ch.b.isEmpty && s.count < 3 { continue }      // too little context to trace a deletion
            if contains(cache[0]!, s) || !contains(cache[last]!, s) { continue }
            sig[ch.id] = s
        }

        var lo: [Int: Int] = [:], hi: [Int: Int] = [:]
        for id in sig.keys { lo[id] = 0; hi[id] = last }

        func publish(exact: Bool) async {
            var out: [Int: ChangeDating] = [:]
            for id in sig.keys {
                let l = points[lo[id]!], h = points[hi[id]!]
                out[id] = ChangeDating(lastAbsent: l.date, firstSeen: h.date, firstSeenURL: h.viewURL, exact: exact)
            }
            if Task.isCancelled { return }
            await update(out)
        }

        func pickMid(_ l: Int, _ h: Int) -> Int? {
            guard h - l > 1 else { return nil }
            let target = (l + h) / 2
            var best: Int?
            for i in (l + 1)..<h where !bad.contains(i) {
                if best == nil || abs(i - target) < abs(best! - target) { best = i }
            }
            return best
        }

        let renderSnapshots: RenderMode = (c.original.rendered || c.revised.rendered) ? .always : .auto
        func fetch(_ idx: Int) async -> [String]? {
            guard let ts = points[idx].timestamp else { return nil }
            let ref = WaybackRef(timestamp: ts, original: page)
            guard let (data, resp) = try? await Fetcher.get(ref.rawURL),
                  let content = try? await SourceLoader.content(data: data, response: resp, name: page,
                                                                render: renderSnapshots, renderURL: ref.frameURL)
            else { return nil }
            return content.tokens.map { TextExtractor.normalize($0.text, ignoreCase: c.ignoreCase) }
        }

        await publish(exact: false)
        var fetched = 0
        var round = 0
        while !Task.isCancelled {
            var mids: [Int: Int] = [:]
            var needed = Set<Int>()
            for id in sig.keys {
                if let m = pickMid(lo[id]!, hi[id]!) {
                    mids[id] = m
                    if cache[m] == nil { needed.insert(m) }
                }
            }
            if mids.isEmpty { break }
            round += 1
            let list = needed.sorted()
            var i = 0
            while i < list.count && !Task.isCancelled {
                let chunk = Array(list[i..<min(i + 2, list.count)])
                await progress("Dating \(sig.count) changes from \(snaps.count) captures – round \(round), fetched \(fetched + i)/\(fetched + list.count)…")
                let results = await withTaskGroup(of: (Int, [String]?).self) { g -> [(Int, [String]?)] in
                    for idx in chunk { g.addTask { (idx, await fetch(idx)) } }
                    var r: [(Int, [String]?)] = []
                    for await x in g { r.append(x) }
                    return r
                }
                for (idx, strs) in results {
                    if let strs { cache[idx] = strs.map(intern) } else { bad.insert(idx) }
                }
                i += chunk.count
            }
            fetched += list.count
            for (id, m) in mids {
                guard let keys = cache[m], let s = sig[id] else { continue }
                if contains(keys, s) { hi[id] = m } else { lo[id] = m }
            }
            await publish(exact: false)
        }
        if Task.isCancelled { return }
        await publish(exact: true)
        let undated = c.changes.count - sig.count
        var msg = "Dated \(sig.count) of \(c.changes.count) changes using \(cache.count - 2) of \(snaps.count) Wayback captures."
        if undated > 0 { msg += " \(undated) could not be traced (too little unique context)." }
        if !bad.isEmpty { msg += " \(bad.count) captures failed to load." }
        if !Task.isCancelled { await progress(msg) }
    }
}
