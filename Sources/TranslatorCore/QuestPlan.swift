// 顺路一起做：已接的任务放一起，同一种怪、同一张图的合并，从近到远排。只给文字，不碰游戏。
import Foundation

/// 已接的一个任务和它的进度
public struct QuestOpen: Codable, Sendable, Equatable {
    public var target: NavTarget
    public var progress: [String: [Int]]
    public var seen: Date
    public init(_ t: NavTarget, progress: [String: [Int]] = [:], seen: Date = Date()) { target = t; self.progress = progress; self.seen = seen }
    public var key: String { Self.key(target) }
    public static func key(_ t: NavTarget) -> String { t.questId.map(String.init) ?? cleanTitle(t.title) + (t.part.map { "#" + $0 } ?? "") }
    /// 标题前面认花的符号（“› Nella 和废弃都市…”）不算：不然同一个任务会存成两份
    public static func cleanTitle(_ s: String) -> String {
        String(s.drop { !($0.isLetter || $0.isNumber || $0 == "[" || $0 == "【") }).trimmingCharacters(in: .whitespaces)
    }
}
/// 已接任务的清单
public struct QuestBook: Codable, Sendable, Equatable {
    public private(set) var open: [QuestOpen] = []
    public init() {}
    public subscript(_ key: String) -> QuestOpen? { open.first { $0.key == key } }
    /// 看到一个已接的任务。接的是同一串的下一个（上一个正好交给它的 NPC）：上一个算做完
    public mutating func put(_ t: NavTarget, progress: [String: [Int]], now: Date = Date(), db: NavDB = .shared) {
        let k = QuestOpen.key(t)
        if let i = open.firstIndex(where: { $0.key == k }) {
            open[i].target = t; open[i].seen = now
            open[i].progress.merge(progress) { _, b in b }
            return
        }
        if let id = t.questId, let s = t.start { open.removeAll { $0.target.questId == id - 1 && $0.target.end == s && Self.series($0, t, db) } }
        // 没有资料（公开版）：同一个任务的标题两次译得不一样（Teo 的收藏 / 茶叶收藏），大意一样就是同一个
        if let i = open.firstIndex(where: { Self.twin($0, QuestOpen(t, progress: progress)) }) {
            open[i].target = t; open[i].seen = now; open[i].progress.merge(progress) { _, b in b }
            return
        }
        // 之前没认全名字、当成资料里没有的：换成认准的这个
        if let n = t.questId.flatMap({ QuestDB.shared.name($0) }) { open.removeAll { $0.target.questId == nil && n.hasPrefix($0.target.title) } }
        open.append(QuestOpen(t, progress: progress, seen: now))
    }
    /// 编号挨着、东西已经齐了（或本来就不用交东西）才当成同一串
    private static func series(_ a: QuestOpen, _ b: NavTarget, _ db: NavDB) -> Bool { QuestPlan.jobs(a, db: db).allSatisfy { if case .npc = $0.kind { true } else { false } } || a.progress.isEmpty }
    public mutating func remove(_ key: String) { open.removeAll { $0.key == key } }
    private static func twin(_ a: QuestOpen, _ b: QuestOpen) -> Bool {
        guard a.target.questId == nil, b.target.questId == nil, let x = a.target.brief, let y = b.target.brief, !x.isEmpty, x == y else { return false }
        return a.progress.isEmpty || b.progress.isEmpty || !Set(a.progress.keys).isDisjoint(with: b.progress.keys)
    }
    /// 没有资料（公开版）：追踪框里是英文任务名，清单里是中文的，靠目标名字和要几个对上（像两个任务的不猜）
    public func match(_ it: QuestHelperItem) -> QuestOpen? {
        func score(_ o: QuestOpen) -> Int { it.objectives.filter { x in
            guard let p = o.progress[x.name], p.count == 2, let n = x.count.split(separator: "/").last.flatMap({ Int($0) }) else { return false }
            return p[1] == n
        }.count }
        let hit = open.filter { $0.target.questId == nil && score($0) > 0 }
        guard let best = hit.map(score).max() else { return nil }
        // 对上几个：对上的目标多的；一样多的取最近看到的（重复存下的旧的不挡路）
        let top = hit.filter { score($0) == best }
        if top.count == 1 { return top[0] }
        let parts = Set(top.map { QuestOpen.cleanTitle($0.target.title) })
        return parts.count == 1 ? top.max { $0.seen < $1.seen } : nil
    }
    /// 以前记下的认花的目标去掉（资料里没有的任务才会有）
    public mutating func clean() {
        for i in open.indices where open[i].target.questId == nil { open[i].progress = open[i].progress.filter { QuestHelper.plausible($0.key) }
            let u = QuestHelper.unify(open[i].progress, with: [:]); open[i].progress = u.read.filter { !u.drop.contains($0.key) }
            open[i].target.title = QuestOpen.cleanTitle(open[i].target.title)
            // 知道这个任务要哪几样的：别的任务留下的进度去掉
            if let p = open[i].target.part { let want = Set(p.split(separator: "|").map(String.init)); open[i].progress = open[i].progress.filter { want.contains($0.key) } }
        }
        // 同一个标题：要的东西有重叠（或有一份没记要什么）的是同一个任务，留最近的
        let sorted = open.sorted { $0.seen > $1.seen }
        var kept: [QuestOpen] = []
        for o in sorted {
            let same = kept.contains { k in
                guard k.target.questId == nil, o.target.questId == nil, k.target.title == o.target.title else { return false }
                let a = Set((k.target.part ?? "").split(separator: "|").map(String.init)), b = Set((o.target.part ?? "").split(separator: "|").map(String.init))
                return o.target.part == nil || a.isEmpty || !a.isDisjoint(with: b) || a.contains { x in b.contains { Fuzzy.distance(Array(x), Array($0), limit: 2) <= 2 } }
            }
            if !same { kept.append(o) }
        }
        open = open.filter { o in kept.contains { $0.key == o.key && $0.seen == o.seen } }
        let all = open.sorted { $0.seen > $1.seen }
        var keep: [QuestOpen] = []
        for o in all where !keep.contains(where: { Self.twin($0, o) }) { keep.append(o) }
        let ids = Set(keep.map(\.key))
        open.removeAll { !ids.contains($0.key) }
    }
    /// 太久没看到的不留
    public mutating func prune(now: Date = Date()) { open.removeAll { now.timeIntervalSince($0.seen) > 30 * 86400 } }
}

public struct QuestJob: Sendable, Equatable, Hashable {
    public enum Kind: Sendable, Hashable { case mob(String), item(String), use(String), npc(Int), level(Int) }
    public struct Part: Sendable, Hashable { public var key: String, title: String, note: String }
    public var kind: Kind
    public var text: String
    public var parts: [Part]
}
public struct QuestStop: Sendable, Equatable, Hashable {
    /// nil = 不知道在哪、或走不到
    public var map: Int?
    /// 从上一站走几张图
    public var hops: Int
    public var jobs: [QuestJob]
}

public enum QuestPlan {
    /// 一个任务现在还要做的事；都够了就是去交
    static func jobs(_ o: QuestOpen, db: NavDB, level: Int? = nil) -> [QuestJob] {
        let t = o.target, q = t.questId.flatMap { db.quest($0) }
        var out: [QuestJob] = []
        func add(_ k: QuestJob.Kind, _ text: String, _ note: String) {
            let p = QuestJob.Part(key: o.key, title: t.title, note: note)
            if let i = out.firstIndex(where: { $0.kind == k }) { out[i].parts.append(p) } else { out.append(QuestJob(kind: k, text: text, parts: [p])) }
        }
        let table = (q?.mobs ?? []) + (q?.items ?? [])
        let needs: [(name: String, count: Int)] = table.isEmpty ? o.progress.keys.sorted().map { ($0, o.progress[$0]![1]) } : table.map { ($0.name, $0.count) }
        for n in needs {
            let p = o.progress[n.name]
            if let p, p[0] >= p[1] { continue }
            let count = p.map { "\($0[0])/\($0[1])" } ?? "要 \(n.count)"
            if db.useUp(n.name, target: t) { add(.use(n.name), "用掉 \(db.itemName(n.name))", ""); continue }
            if let m = db.mob(forObjective: n.name, target: t) {
                add(.mob(m), "打 \(db.mobName(m))", (n.name == m ? "" : (t.zh?[n.name] ?? db.itemName(n.name)) + " ") + count)
            } else { add(.item(n.name), "找 \(t.zh?[n.name] ?? db.itemName(n.name))", count) }
        }
        if needs.isEmpty { for m in t.mobs where db.hasMob(m) { add(.mob(m), "打 \(db.mobName(m))", "") } }
        if out.isEmpty, let need = t.level, let level, level < need { add(.level(need), "升到 \(need) 级", t.end.map { "再找 " + db.npcName($0) } ?? "") }
        if out.isEmpty, let e = t.end { add(.npc(e), "找 \(db.npcName(e))", table.isEmpty ? "说话" : "交任务") }
        return out
    }

    /// found：自己捡到过、买得到的图（东西 → 图）
    public static func make(_ open: [QuestOpen], from: Int?, found: [String: Int] = [:], level: Int? = nil, db: NavDB = .shared) -> [QuestStop] {
        var left: [QuestJob] = []
        for j in open.flatMap({ jobs($0, db: db, level: level) }) {
            if let i = left.firstIndex(where: { $0.kind == j.kind }) { left[i].parts += j.parts } else { left.append(j) }
        }
        func route(_ j: QuestJob, _ m: Int) -> (hops: Int, map: Int)? {
            let r: NavRoute?
            switch j.kind {
            case .mob(let n): r = db.route(from: m, mob: n)
            case .npc(let n): r = db.route(from: m, npc: n)
            case .item(let n): r = found[n].flatMap { db.route(from: m, map: $0, item: n) } ?? db.sourceRoute(from: m, item: n)
            case .use: return (0, m)
            case .level: return nil
            }
            return r.map { ($0.hops, $0.goalMap) }
        }
        var out: [QuestStop] = [], at = from
        while let m = at, !left.isEmpty {
            let rs = left.compactMap { j in route(j, m).map { (j, $0) } }
            guard let hops = rs.map(\.1.hops).min() else { break }
            // 一样近的：能同时做得多的那张图先去
            let near = rs.filter { $0.1.hops == hops }
            func share(_ map: Int) -> Int { left.filter { can($0, map, db, found) }.reduce(0) { $0 + $1.parts.count } }
            let goal = near.map(\.1.map).max { (share($0), -$0) < (share($1), -$1) }!
            let here = left.filter { j in can(j, goal, db, found) || near.contains { $0.0 == j && $0.1.map == goal } }
            out.append(QuestStop(map: goal, hops: hops, jobs: here))
            left.removeAll { here.contains($0) }
            at = goal
        }
        if !left.isEmpty { out.append(QuestStop(map: nil, hops: 0, jobs: left)) }
        return out
    }
    private static func can(_ j: QuestJob, _ map: Int, _ db: NavDB, _ found: [String: Int]) -> Bool {
        switch j.kind {
        case .mob(let n): db.mobCount(n, in: map) >= 3
        case .npc(let n): db.npcMaps(n).contains(map)
        case .item(let n): found[n] == map
        case .use: true
        case .level: false
        }
    }
}
