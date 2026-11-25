// 快捷栏上的数量（药水还剩几个）：固定的像素字，系统识别读不出，按字形和每行固定的颜色精确对。只看截图。
import CoreGraphics
import Foundation

public enum QuickSlot {
    /// 一个数：在图里的位置（点）、图标的平均颜色（认是不是换了东西）
    public struct Count: Sendable, Equatable {
        public var value: Int, x: Int, y: Int, color: [Int]
        public init(value: Int, x: Int, y: Int, color: [Int]) { self.value = value; self.x = x; self.y = y; self.color = color }
    }
    /// 画数字用：某个数字的 9 行点阵、每行颜色
    public static func pixels(_ d: Int) -> [[Bool]] { glyphs[d].g }
    public static func rowColor(_ r: Int) -> (Int, Int, Int) { rows[r] }
    static let rows: [(Int, Int, Int)] = [(255, 255, 255), (255, 255, 255), (255, 255, 255), (255, 255, 255), (238, 255, 255), (221, 238, 255), (187, 221, 255), (170, 204, 255), (153, 204, 255)]
    static let glyphs: [(d: Int, g: [[Bool]])] = {
        let r: [[String]] = [
            [".####.", "#....#", "#....#", "#....#", "#....#", "#....#", "#....#", "#....#", ".####."],
            [".#", "##", ".#", ".#", ".#", ".#", ".#", ".#", ".#"],
            [".####.", "#....#", ".....#", ".....#", "....#.", "..##..", ".#....", "#.....", "######"],
            [".####.", "#....#", ".....#", ".....#", "..###.", ".....#", ".....#", "#....#", ".####."],
            ["....#.", "...##.", "..#.#.", ".#..#.", "#...#.", "######", "....#.", "....#.", "....#."],
            ["######", "#.....", "#.....", "#####.", ".....#", ".....#", ".....#", "#....#", ".####."],
            ["..###.", ".#....", "#.....", "#####.", "#....#", "#....#", "#....#", "#....#", ".####."],
            ["######", ".....#", "....#.", "....#.", "...#..", "...#..", "..#...", "..#...", ".#...."],
            [".####.", "#....#", "#....#", "#....#", ".####.", "#....#", "#....#", "#....#", ".####."],
            [".####.", "#....#", "#....#", "#....#", "#....#", ".#####", ".....#", ".....#", ".####."]]
        return r.enumerated().map { ($0.offset, $0.element.map { $0.map { $0 == "#" } }) }
    }()

    /// 背包现在是不是 Use 页（第二个页签是粉红色）。im：从金币框往上截的那块，左边比金币图标多 8 点、下边在金币框中线上方 13 点
    public static func onUseTab(_ im: CGImage, scale s: Int) -> Bool {
        guard let p = MiniMap.Pix(im) else { return false }
        func pink(_ x0: Int, _ x1: Int) -> Int {
            var n = 0
            for y in 25..<55 { for x in x0..<x1 where x * s < p.w && y * s < p.h { let c = p.rgb(x * s, y * s); if c.0 > 190, c.1 < 130, c.2 > 70, c.2 < 175 { n += 1 } } }
            return n
        }
        let use = pink(38, 72)
        return use > 120 && use > pink(4, 36) * 2
    }

    /// im：含快捷栏的截图，s：每点几像素
    public static func read(_ im: CGImage, scale s: Int) -> [Count] {
        guard let p = MiniMap.Pix(im) else { return [] }
        var best: [Count] = []
        // 截图可能差一个像素，哪个对得上用哪个
        for oy in 0..<s { for ox in 0..<s { let c = scan(p, s, ox, oy); if c.count > best.count { best = c } } }
        return best
    }
    private static func scan(_ p: MiniMap.Pix, _ s: Int, _ ox: Int, _ oy: Int) -> [Count] {
        let w = (p.w - ox) / s, h = (p.h - oy) / s
        guard w > 10, h > 12 else { return [] }
        @inline(__always) func at(_ x: Int, _ y: Int) -> (Int, Int, Int) { p.rgb(ox + x * s, oy + y * s) }
        func lit(_ x: Int, _ y: Int, _ r: Int) -> Bool { let c = at(x, y), k = rows[r]; return abs(c.0 - k.0) <= 8 && abs(c.1 - k.1) <= 8 && abs(c.2 - k.2) <= 8 }
        func dark(_ x: Int, _ y: Int) -> Bool { guard x >= 0, y >= 0, x < w, y < h else { return true }; let c = at(x, y); return max(c.0, c.1, c.2) < 60 }
        var found: [(d: Int, x: Int, y: Int, w: Int)] = []
        for y in 1..<(h - 10) { for x in 1..<(w - 7) {
            for (d, g) in glyphs {
                let gw = g[0].count
                var ok = true, miss = 0
                check: for r in 0..<9 { for c in 0..<gw where g[r][c] {
                    if !lit(x + c, y + r, r) { ok = false; break check }
                    // 笔画四周是黑边
                    for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                        let rr = r + dy, cc = c + dx
                        if rr >= 0, rr < 9, cc >= 0, cc < gw, g[rr][cc] { continue }
                        if !dark(x + cc, y + rr) { miss += 1; if miss > 1 { ok = false; break check } }
                    }
                } }
                if ok { found.append((d, x, y, gw)) }
            }
        } }
        // 同一行挨着的拼成一个数
        var out: [Count] = []
        for f in found.sorted(by: { ($0.y, $0.x) < ($1.y, $1.x) }) {
            if let l = out.indices.last, out[l].y == f.y, f.x - (out[l].color[0]) >= 1, f.x - out[l].color[0] <= 4 {
                out[l].value = out[l].value * 10 + f.d; out[l].color[0] = f.x + f.w
            } else { out.append(Count(value: f.d, x: f.x, y: f.y, color: [f.x + f.w])) }
        }
        // 图标颜色：数字上面那块里鲜艳的像素（格子底色在快捷栏和背包里不一样，不算）
        return out.map { o in
            var sum = [0, 0, 0], n = 0
            for yy in max(0, o.y - 14)..<max(1, o.y - 1) { for xx in stride(from: o.x + 10, to: min(w, o.x + 30), by: 1) {
                let c = at(xx, yy)
                guard max(c.0, c.1, c.2) - min(c.0, c.1, c.2) > 45 else { continue }
                sum[0] += c.0; sum[1] += c.1; sum[2] += c.2; n += 1
            } }
            return Count(value: o.value, x: o.x, y: o.y, color: n >= 12 ? sum.map { $0 / n } : [0, 0, 0])
        }
    }
}

/// 药水用量：某一格连着少 1～3 个算用掉；一下少很多（卖掉、丢掉、被鼠标挡住认短了）、变多（买、捡）都只更新数字
public struct PotionLog: Codable, Sendable, Equatable {
    public struct Slot: Codable, Sendable, Equatable {
        public var id: Int, color: [Int]
        public var name = "", price = 0
        /// 快捷栏上的数、背包里的总数（没看到过为 nil）
        public var last: Int? = nil, bag: Int? = nil
        /// 不算药水（飞镖、箭之类可以不算）
        public var ignored = false
        /// 物品英文名（认出来的）
        public var en: String? = nil
        /// 手改过名字或单价
        public var manual = false
    }
    public var slots: [Slot] = []
    /// 分钟 → 花的钱（按当时的单价）
    public var spent: [Int: Int] = [:]
    /// 格子编号 → 分钟 → 用了几个
    public var used: [Int: [Int: Int]] = [:]
    private var pending: [Int: Int] = [:], bagPending: [Int: Int] = [:]
    private var quickSeen: [Int: Date] = [:], bagAt = Date.distantPast, bagCells = 0
    public init() {}

    private func find(_ c: QuickSlot.Count) -> Int? {
        // 同一种东西图标颜色一样（快捷栏和背包里都是）；取最像的
        func d(_ a: [Int]) -> Int { zip(a, c.color).map { abs($0 - $1) }.max() ?? 999 }
        return slots.indices.filter { slots[$0].color.count == 3 && d(slots[$0].color) <= 14 }.min { d(slots[$0].color) < d(slots[$1].color) }
    }
    /// 这一次看到的。返回这次确认用掉的 [(格子编号, 几个, 花多少)]
    public mutating func feed(_ counts: [QuickSlot.Count], at t: Date) -> [(id: Int, n: Int, cost: Int)] {
        var out: [(id: Int, n: Int, cost: Int)] = []
        for c in counts where c.color.count == 3 && c.color != [0, 0, 0] {
            guard let i = find(c) else {
                // 新东西：连看两次再记
                let k = -(c.color[0] * 65536 + c.color[1] * 256 + c.color[2])
                if pending[k] == c.value { pending[k] = nil; add(c.color); slots[slots.count - 1].last = c.value; quickSeen[slots.last!.id] = t } else { pending[k] = c.value }
                continue
            }
            let id = slots[i].id
            quickSeen[id] = t
            guard let old = slots[i].last else { slots[i].last = c.value; continue }
            guard c.value != old else { pending[id] = nil; continue }
            // 连看两次才算；连着喝时数字一次比一次小，上一次看到的那个数就当确认了（等它停下来会超过 3 个、漏掉）
            guard let p = pending[id], p == c.value || (p < old && c.value < p && p - c.value <= 3) else { pending[id] = c.value; continue }
            pending[id] = p == c.value ? nil : c.value
            let n = old - p
            slots[i].last = p
            if let u = use(i, n, t) { out.append(u) }
        }
        return out
    }
    private mutating func add(_ color: [Int]) { slots.append(Slot(id: (slots.map(\.id).max() ?? 0) + 1, color: color)) }
    private mutating func use(_ i: Int, _ n: Int, _ t: Date) -> (id: Int, n: Int, cost: Int)? {
        guard (1...3).contains(n), !slots[i].ignored else { return nil }
        let id = slots[i].id, m = ExpStore.minute(t), cost = n * slots[i].price
        used[id, default: [:]][m, default: 0] += n
        if cost > 0 { spent[m, default: 0] += cost }
        return (id, n, cost)
    }
    /// 背包 Use 页看到的（同一种的几堆加起来）。快捷栏上有的以快捷栏为准，这里只记数；
    /// 没放快捷栏的，背包一直开着时少了 1～3 个算用掉（双击用的）。格子数变了（翻页、卖东西）只更新数
    public mutating func feedBag(_ counts: [QuickSlot.Count], at t: Date) -> [(id: Int, n: Int, cost: Int)] {
        let good = counts.filter { $0.color.count == 3 && $0.color != [0, 0, 0] }
        guard !good.isEmpty else { return [] }
        let same = good.count == bagCells && t.timeIntervalSince(bagAt) < 3.5
        bagCells = good.count; bagAt = t
        var total: [Int: Int] = [:]
        for c in good {
            if find(c) == nil { add(c.color) }
            total[find(c)!, default: 0] += c.value
        }
        var out: [(id: Int, n: Int, cost: Int)] = []
        for (i, v) in total {
            let id = slots[i].id
            guard let old = slots[i].bag else { slots[i].bag = v; continue }
            guard v != old else { bagPending[id] = nil; continue }
            guard bagPending[id] == v else { bagPending[id] = v; continue }
            bagPending[id] = nil; slots[i].bag = v
            let onQuick = quickSeen[id].map { t.timeIntervalSince($0) < 30 } ?? false
            if same, !onQuick, let u = use(i, old - v, t) { out.append(u) }
        }
        return out
    }
    /// 这一刻在快捷栏上的排前面
    public func sorted() -> [Slot] { slots.sorted { (($0.last == nil ? 1 : 0), $0.id) < (($1.last == nil ? 1 : 0), $1.id) } }
    /// 这一格以后、以前用的都按新单价算
    public mutating func setPrice(_ id: Int, _ p: Int) {
        guard let i = slots.firstIndex(where: { $0.id == id }) else { return }
        slots[i].price = max(0, p); slots[i].manual = true; recount()
    }
    public mutating func setIgnored(_ id: Int, _ v: Bool) { if let i = slots.firstIndex(where: { $0.id == id }) { slots[i].ignored = v; slots[i].manual = true; recount() } }
    mutating func recount() {
        spent = [:]
        for s in slots where !s.ignored && s.price > 0 { for (m, n) in used[s.id] ?? [:] { spent[m, default: 0] += n * s.price } }
    }
    public func count(_ id: Int, since m: Int) -> Int { (used[id] ?? [:]).filter { $0.key >= m }.values.reduce(0, +) }
    public mutating func prune(now: Date) {
        let a = ExpStore.minute(now) - 35 * 1440
        for k in used.keys { used[k] = used[k]!.filter { $0.key >= a } }
        spent = spent.filter { $0.key >= a }
    }
}
