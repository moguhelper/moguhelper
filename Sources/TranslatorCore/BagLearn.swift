// 没有图标资料（公开版）：背包里只有图、没有名字。捡了 16 个甲，再看背包正好只有一格多了 16 个，那一格就是甲。
// 只记格子的颜色（指纹）和名字，存在本机。
import Foundation

public struct BagLearn: Codable, Sendable {
    public struct Slot: Codable, Sendable, Equatable {
        public var print: [Int], n: Int?      // print 空 = 空格；n 空 = 没读到数字（装备、被压住）
        public init(_ print: [Int], _ n: Int?) { self.print = print; self.n = n }
    }
    struct Known: Codable, Sendable { var name: String, print: [Int] }
    struct Vote: Codable, Sendable { var name: String, print: [Int], n: Int, end: Date? = nil }
    private struct Page: Codable, Sendable { var slots: [Slot?], at: Date }
    private struct Pick: Codable, Sendable { var name: String, n: Int, at: Date }
    var known: [Known] = [], votes: [Vote] = []
    /// 追踪框总数对上过的
    private var marks: [Vote] = [], totals: [String: (n: Int, at: Date)] = [:]
    private var pages: [Page] = [], picks: [Pick] = []
    private var waiting: [Page] = [], now: [Slot?] = [], since = Date.distantPast
    /// 关掉再开也接着比；换角色就不比（背包不是同一个）
    private var owner: String? = nil
    /// 捡的时候提示写的是哪一页（Etc、Use）
    private var tabs: [String: String]? = nil
    /// 已经有图标的：名字 → 按背包格子算的颜色（不存盘，程序给）
    private var icons: [(name: String, print: [Int])] = []
    private var iconNames: Set<String> = []
    public mutating func setIcons(_ l: [(name: String, print: [Int])]) { icons = l; iconNames = Set(l.map(\.name)) }
    /// 图标放在格子里是什么颜色：和 IconGrab.bag 的指纹一样算，最上面一排是格子的暗边，不比
    public static func iconPrint(_ px: [(Int, Int, Int, Int)]) -> [Int] {
        guard px.count == 1024 else { return [] }
        var f: [Int] = []
        for y0 in stride(from: 0, to: 20, by: 5) { for x0 in stride(from: 12, to: 32, by: 4) {
            var s = [0.0, 0.0, 0.0]
            for y in y0..<(y0 + 5) { for x in x0..<(x0 + 4) {
                let c = px[y * 32 + x], a = Double(c.3) / 255
                s[0] += Double(c.0) * a + 225 * (1 - a); s[1] += Double(c.1) * a + 223 * (1 - a); s[2] += Double(c.2) * a + 213 * (1 - a)
            } }
            f += s.map { Int($0 / 20) }
        } }
        return f
    }
    /// 认出来时背包比提示多的（提示认花漏记的），要补记
    private var extra: [(name: String, n: Int)] = []
    public mutating func takeExtra() -> [(name: String, n: Int)] { defer { extra = [] }; return extra }
    /// 捡这样东西时提示写的是哪一页
    public func tabOf(_ n: String) -> String? { tabs?[n] }
    private func iconName(_ p: [Int]) -> String? {
        guard p.count == 60 else { return nil }
        let d = icons.filter { $0.print.count == 60 }.map { i in (i.name, (15..<60).map { k in abs(i.print[k] - p[k]) }.max()!) }.sorted { $0.1 < $1.1 }
        guard let a = d.first, a.1 <= 5, d.count < 2 || d[1].1 - a.1 >= 5 else { return nil }
        return a.0
    }
    enum CodingKeys: CodingKey { case known, votes, pages, picks, owner, tabs }
    public mutating func use(_ name: String) {
        guard name != owner else { return }
        if owner != nil { pages = []; picks = [] }
        owner = name; now = []; waiting = []; totals = [:]
    }
    public private(set) var dirty = false
    public mutating func saved() { dirty = false }
    /// 最后一次比的结果（调试用）
    public private(set) var log = ""
    public init() {}

    static func far(_ a: [Int], _ b: [Int]) -> Int { a.count == b.count ? zip(a, b).map { abs($0 - $1) }.max() ?? 99 : 99 }
    static func like(_ a: [Int], _ b: [Int]) -> Bool { far(a, b) <= 4 }
    /// 学到过的：这一格是什么
    public func name(_ p: [Int]) -> String? {
        if let n = iconName(p) { return n }
        let d = known.map { ($0.name, Self.far($0.print, p)) }.sorted { $0.1 < $1.1 }
        guard let a = d.first, a.1 <= 4, d.count < 2 || d[1].1 - a.1 >= 3 else { return nil }
        return a.0
    }
    public mutating func pick(_ name: String, _ n: Int, tab: String? = nil, at t: Date) {
        dirty = true
        if let tab { tabs = (tabs ?? [:]).merging([name: tab]) { _, b in b } }
        picks.append(Pick(name: name, n: n, at: t))
        if picks.count > 2000 { picks.removeFirst(500) }
    }
    /// 同一页：两次都有东西的格子都一样，至少两格对上
    private func samePage(_ a: [Slot?], _ b: [Slot?]) -> Bool {
        var ok = 0
        for (x, y) in zip(a, b) {
            guard let x, let y, !x.print.isEmpty, !y.print.isEmpty else { continue }
            if !Self.like(x.print, y.print) { return false }
            ok += 1
        }
        return ok >= 2
    }
    /// 看到一屏（30 格，nil = 没看清）。连着两次一样就记下，背包马上关掉也行；过 1.5 秒再比（settle）
    public mutating func see(_ slots: [Slot?], at t: Date) {
        // 一格一格确认：闪一下、半透明的那几格当没看清，别的照样算
        let old = now, near = t.timeIntervalSince(since) < 1.2
        now = slots; since = t
        guard near, old.count == slots.count else { return }
        let slots = zip(slots, old).map { x, y -> Slot? in
            guard let x, let y, x.n == y.n, x.print.isEmpty ? y.print.isEmpty : Self.like(x.print, y.print) else { return nil }
            return x
        }
        guard slots.filter({ $0 != nil }).count >= 12 else { return }
        if let w = waiting.last, t.timeIntervalSince(w.at) < 1, w.slots == slots { return }
        waiting.append(Page(slots: slots, at: t))
        if waiting.count > 20 { waiting.removeFirst() }
    }
    /// 任务追踪框里写的“36/10 Orange Mushroom Cap”：名字和一共几个
    public mutating func total(_ name: String, _ n: Int, at t: Date) {
        guard n > 0, QuestHelper.plausible(name) else { return }
        totals[name] = (n, t)
    }
    /// 定时叫。看到背包 1.5 秒后再比（等捡东西的提示都读到）。返回新学到的
    public mutating func settle(at t: Date) -> [String] {
        var new: [String] = []
        while let w = waiting.first, t.timeIntervalSince(w.at) >= 1.5 {
            waiting.removeFirst()
            new += compare(w.slots, at: w.at)
        }
        return new
    }
    /// 和以前看到的同一页一次次比（不限什么时候看的）
    private mutating func compare(_ slots: [Slot?], at t: Date) -> [String] {
        var new = byTotal(slots, at: t)
        let olds = pages.filter { samePage($0.slots, slots) }.sorted { $0.at > $1.at }
        for o in olds { new += diff(o, slots, at: t) }
        // 隔 5 秒以上、或有变化才多存一份
        if let l = olds.first {
            // 没变化：这一份一直管到现在
            if l.slots == slots, let k = pages.firstIndex(where: { $0.at == l.at }) { pages[k].at = t; dirty = true; return new }
            if t.timeIntervalSince(l.at) < 5 { return new }
        }
        pages.append(Page(slots: slots, at: t)); dirty = true
        // 同一页最多留 6 份，一共 30 份
        if olds.count >= 6, let a = olds.last?.at { pages.removeAll { $0.at == a } }
        if pages.count > 30 { pages.removeFirst() }
        if let a = pages.map(\.at).min() { picks.removeAll { $0.at < a.addingTimeInterval(-3) } }
        return new
    }
    /// 一样东西一共几个：同一种图的几堆加起来；有一堆没读到数就不算
    private func sums(_ slots: [Slot?]) -> [(print: [Int], n: Int)] {
        var out: [(print: [Int], n: Int, bad: Bool)] = []
        for x in slots { if let x, !x.print.isEmpty {
            if let k = out.firstIndex(where: { Self.like($0.print, x.print) }) { out[k].n += x.n ?? 0; out[k].bad = out[k].bad || x.n == nil }
            else { out.append((x.print, x.n ?? 0, x.n == nil)) }
        } }
        return out.filter { !$0.bad }.map { ($0.print, $0.n) }
    }
    /// 追踪框写的总数正好只有一格对得上。碰巧也会对上（杀怪数、别的页签），要两个不同的数都对上同一格
    private mutating func byTotal(_ slots: [Slot?], at t: Date) -> [String] {
        var new: [String] = []
        let all = sums(slots)
        for (w, v) in totals where abs(v.at.timeIntervalSince(t)) < 5 && !known.contains(where: { $0.name == w }) {
            let hit = all.filter { $0.n == v.n }
            guard hit.count == 1, name(hit[0].print) == nil, totals.filter({ $0.value.n == v.n }).count == 1 else { continue }
            if marks.contains(where: { $0.name == w && $0.n != v.n && Self.like($0.print, hit[0].print) }) {
                learn(w, hit[0].print); new.append(w)
            } else if !marks.contains(where: { $0.name == w && $0.n == v.n && Self.like($0.print, hit[0].print) }) {
                marks.append(Vote(name: w, print: hit[0].print, n: v.n)); dirty = true
                if marks.count > 60 { marks.removeFirst() }
            }
        }
        return new
    }
    /// 这一屏是背包哪一页：看认识的东西捡的时候写的是哪一页
    private func tab(_ slots: [Slot?]) -> String? {
        var c: [String: Int] = [:]
        for x in slots { if let x, !x.print.isEmpty, let n = name(x.print), let t = tabs?[n] { c[t, default: 0] += 1 } }
        return c.max { $0.value < $1.value }?.key
    }
    private mutating func learn(_ w: String, _ p: [Int]) {
        known.append(Known(name: w, print: p)); dirty = true
        votes.removeAll { $0.name == w || Self.like($0.print, p) }; marks.removeAll { $0.name == w || Self.like($0.print, p) }
    }
    private mutating func diff(_ old: Page, _ slots: [Slot?], at t: Date) -> [String] {
        // 每样东西捡了几个：离两次看的时刻太近的说不准算不算，记成一个范围
        var got: [String: (lo: Int, hi: Int)] = [:]
        for p in picks {
            let a = p.at.timeIntervalSince(old.at), b = t.timeIntervalSince(p.at)
            guard a > -1.5, b > -1.5 else { continue }
            let sure = a >= 1.5 && b >= 1.5
            let g = got[p.name] ?? (0, 0)
            got[p.name] = (g.lo + (sure ? p.n : 0), g.hi + p.n)
        }
        got = got.filter { !iconNames.contains($0.key) }
        guard !got.isEmpty else { return [] }
        // 每种图（可能占几格）多了几个
        var change: [(print: [Int], n: Int, unsure: Bool)] = []
        for (x, y) in zip(old.slots, slots) {
            guard let p = [y, x].compactMap({ $0 }).first(where: { !$0.print.isEmpty })?.print else { continue }
            // 有一次没看清（鼠标压住、选中的格子）、没读到数字：这种图不算
            let unsure = [x, y].contains { s in s.map { !$0.print.isEmpty && $0.n == nil } ?? true }
            let d = (y?.n ?? 0) - (x?.n ?? 0)
            if let k = change.firstIndex(where: { Self.like($0.print, p) }) { change[k].n += d; change[k].unsure = change[k].unsure || unsure }
            else { change.append((p, d, unsure)) }
        }
        let up = change.filter { !$0.unsure && $0.n > 0 }
        log = "\(Int(t.timeIntervalSince(old.at))) 秒 捡到 \(got.map { "\($0.key) \($0.value.lo)~\($0.value.hi)" }.sorted()) 多了 \(up.map(\.n)) 看不准 \(change.filter(\.unsure).count)"
        guard up.count <= 8 else { return [] }      // 一下变一大片：整理过、搬过东西
        var new: [String] = []
        // 认识的全排除，只有一种不认识的多了、也只捡过一种没图标的：就是它
        let odd = change.filter { name($0.print) == nil && ($0.unsure || $0.n != 0) }
        let here = tab(slots)
        let who = got.filter { w, _ in !known.contains { $0.name == w } && (here == nil || tabs?[w] == nil || tabs?[w] == here) }
        // 这一屏多半都认识，排除才可靠
        let sure = change.filter { name($0.print) != nil }.count * 2 >= change.count && !icons.isEmpty
        if sure, odd.count == 1, let c = odd.first, !c.unsure, c.n > 0, who.count == 1, let w = who.first, w.value.lo <= c.n, c.n <= w.value.hi + 2 {
            learn(w.key, c.print)
            if c.n > w.value.hi { extra.append((w.key, c.n - w.value.hi)) }
            return [w.key]
        }
        for c in up where name(c.print) == nil && !known.contains(where: { Self.far($0.print, c.print) <= 6 }) {
            let names = Set(known.map(\.name))
            // 数量只可能是一样东西、这样东西也只对上一格
            let who = got.filter { !names.contains($0.key) && $0.value.lo <= c.n && c.n <= $0.value.hi }
            guard who.count == 1, let w = who.first, w.value.lo == w.value.hi, up.filter({ $0.n == c.n && name($0.print) == nil }).count == 1 else { continue }
            let same = votes.filter { $0.name == w.key || Self.like($0.print, c.print) }
            if same.contains(where: { $0.name != w.key || !Self.like($0.print, c.print) }) {      // 前后矛盾：都作废重来
                votes.removeAll { $0.name == w.key || Self.like($0.print, c.print) }
            }
            // 和上一票的时间重叠的不算新的一票
            if let l = votes.last(where: { $0.name == w.key }), old.at < l.end ?? .distantPast { if c.n < 5 { continue } }
            votes.append(Vote(name: w.key, print: c.print, n: c.n, end: t)); dirty = true
            // 一次 5 个以上一次就够；一两个的要对上两次
            guard c.n >= 5 || votes.filter({ $0.name == w.key }).count >= 2 else { continue }
            learn(w.key, c.print); new.append(w.key)
        }
        return new
    }
}
