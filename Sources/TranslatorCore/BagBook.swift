// 双复核：捡东西的提示先记；背包格子里的数量、任务追踪里的数量再来核对，漏的补、多的撤。
import Foundation

public struct BagBook: Sendable {
    public struct Cell: Sendable, Equatable {
        /// nil = 没看清；"" = 空格
        public var name: String?, n: Int
        public init(_ name: String?, _ n: Int) { self.name = name; self.n = n }
    }
    /// 核对出来要改的：n > 0 补记，n < 0 撤回
    public struct Fix: Sendable, Equatable { public var name: String, n: Int; public init(name: String, n: Int) { self.name = name; self.n = n } }
    private struct Page: Sendable { var cells: [Cell]; var time: [Date] }
    private var pages: [String: Page] = [:], last: [Cell] = []
    private var picks: [(name: String, n: Int, t: Date)] = [], used: [(name: String, n: Int, t: Date)] = []
    private var kills: [Date] = [], shop: Date?
    private var credit: [String: (n: Int, t: Date)] = [:]
    private var quest: [String: (n: Int, t: Date, again: Int?)] = [:]
    public init() {}
    /// 背包某个页签最后看到的那一屏：名字 → 几个
    public func seen(_ cat: String) -> [String: Int] {
        (pages[cat]?.cells ?? []).reduce(into: [:]) { d, c in if let n = c.name, !n.isEmpty { d[n, default: 0] += c.n } }
    }

    /// 提示里捡到的。返回该记几个（背包先看到、已经补记过的不重记）
    public mutating func pick(_ name: String, _ n: Int, at t: Date) -> Int {
        if let c = credit[name], t.timeIntervalSince(c.t) < 4 {
            let k = min(c.n, n)
            credit[name] = c.n > k ? (c.n - k, c.t) : nil
            guard n > k else { return 0 }
            picks.append((name, n - k, t)); return n - k
        }
        picks.append((name, n, t))
        if picks.count > 3000 { picks.removeFirst(1000) }
        return n
    }
    public mutating func kill(at t: Date) { kills.append(t); if kills.count > 3000 { kills.removeFirst(1000) } }
    public mutating func usedUp(_ name: String, _ n: Int, at t: Date) { used.append((name, n, t)) }
    /// 商店开着：买卖会让数量变，这段不核对，以后从新的数量算
    public mutating func shopOpen(at t: Date) { shop = t }

    /// 数量从 t0 到现在变了 delta。返回要改多少；nil = 现在还不能定（提示刚出来）
    private mutating func check(_ name: String, _ delta: Int, since t0: Date, at t: Date, limit: Int) -> Int? {
        if let s = shop, s >= t0 { return 0 }
        // 刚捡的：提示和背包哪个先看到说不准，等两秒
        if picks.contains(where: { $0.name == name && $0.t > t.addingTimeInterval(-2) }) { return nil }
        let told = picks.filter { $0.name == name && $0.t > t0 }.reduce(0) { $0 + $1.n }
        let drunk = used.filter { $0.name == name && $0.t > t0 }.reduce(0) { $0 + $1.n }
        let d = delta + drunk - told
        if d > 0 {
            // 没打怪就多出来的（任务奖励、别人给的）不算捡的；一次多出很多的也不算
            let k = kills.filter { $0 > t0 }.count
            guard k > 0 || told > 0, d <= min(limit, max(3, k)) else { return 0 }
            picks.append((name, d, t)); credit[name] = (d, t)
            return d
        }
        // 提示记得比实际多：数量没变少（没卖、没交）才撤
        if d < 0, delta >= 0, told > 0, drunk == 0 {
            let back = max(d, -told)
            picks.append((name, back, t))
            return back
        }
        return 0
    }

    /// 背包一整页（5 列）。cat：哪个页签
    public mutating func see(_ cells: [Cell], cat: String, at t: Date) -> [Fix] {
        defer { last = cells }
        // 连着两次都这么认才算
        guard last.count == cells.count else { return [] }
        let now = zip(cells, last).map { $0 == $1 ? $0 : Cell(nil, 0) }
        guard let old = pages[cat], old.cells.count == now.count else { pages[cat] = Page(cells: now, time: now.map { _ in t }); return [] }
        // 可能滚动过几行：找对得上最多的错位
        var best = (score: -1, off: 0)
        let rows = now.count / 5
        for off in (-(rows - 1))...(rows - 1) {
            var ok = 0, bad = 0
            for i in now.indices {
                let j = i + off * 5
                guard old.cells.indices.contains(j), let a = now[i].name, let b = old.cells[j].name, !(a.isEmpty && b.isEmpty) else { continue }
                if a == b { ok += 1 } else { bad += 1 }
            }
            let s = ok * 2 - bad * 3
            if s > best.score || (s == best.score && abs(off) < abs(best.off)) { best = (s, off) }
        }
        // 正在滚动、翻页（和上一次不一样）：先别动，等稳定
        guard best.score > 0 || cells == last else { return [] }
        guard best.score > 0 else { pages[cat] = Page(cells: now, time: now.map { _ in t }); return [] }
        var delta: [String: (n: Int, t0: Date)] = [:], moved = 0
        var next = Page(cells: now, time: now.map { _ in t })
        for i in now.indices {
            let j = i + best.off * 5
            guard old.cells.indices.contains(j) else { continue }
            let o = old.cells[j]
            guard let a = now[i].name else { next.cells[i] = o; next.time[i] = old.time[j]; continue }   // 没看清：沿用旧的
            guard let b = o.name else { continue }                                                        // 以前没看清：当起点
            if a == b {
                if a.isEmpty { continue }
                let d = delta[a] ?? (0, old.time[j])
                delta[a] = (d.n + now[i].n - o.n, min(d.t0, old.time[j]))
            } else if b.isEmpty { let d = delta[a] ?? (0, old.time[j]); delta[a] = (d.n + now[i].n, min(d.t0, old.time[j])) }
            else { moved += 1 }
        }
        // 整理过、搬动过：对不准，重新当起点
        guard moved == 0 else { pages[cat] = next; return [] }
        var out: [Fix] = []
        for (name, d) in delta.sorted(by: { $0.key < $1.key }) {
            guard let f = check(name, d.n, since: d.t0, at: t, limit: 60) else {
                // 还不能定：这样东西的格子不更新，下次再比
                for i in now.indices { let j = i + best.off * 5; if old.cells.indices.contains(j), now[i].name == name { next.cells[i] = old.cells[j]; next.time[i] = old.time[j] } }
                continue
            }
            if f != 0 { out.append(Fix(name: name, n: f)) }
        }
        pages[cat] = next
        return out
    }

    /// 任务追踪 “67/30 Squishy Liquid” 里的数量（不用开背包）
    public mutating func track(_ name: String, _ n: Int, at t: Date) -> Fix? {
        guard let q = quest[name] else { quest[name] = (n, t, nil); return nil }
        if q.n == n { quest[name] = (n, t, nil); return nil }
        // 新数字连着看到两次才信
        guard q.again == n else { quest[name] = (q.n, q.t, n); return nil }
        guard let f = check(name, n - q.n, since: q.t, at: t, limit: 5) else { return nil }
        quest[name] = (n, t, nil)
        return f == 0 ? nil : Fix(name: name, n: f)
    }
    public mutating func reset() { self = BagBook() }
}
