// 资料互传：走过的地图、捡到过什么（.mogu，就是一个 JSON 文件）。不含角色名、等级、经验、金币、聊天、图片。
// 导入的内容当作不可信：只认固定的几项，超范围的丢掉，不执行、不联网。
import Foundation

public struct MoguPack: Codable, Sendable, Equatable {
    public var format = "mogu", version = 1
    /// 生成日期（只到天）
    public var day: String
    public var maps: [String: WalkedMap]
    /// 地图 key → 物品英文名 → 捡到过几个
    public var drops: [String: [String: Int]]

    /// 地图 key → NPC 名字 → [画面里左右位置 0~1] 或再加 [整张小地图里的 x, y]。旧版没有
    public var npcs: [String: [String: [Double]]]? = nil
    /// 地图 key → 怪物英文名 → [等级（0 = 不知道）, 名牌看到几次, 打了几只]。旧版没有
    public var mobs: [String: [String: [Int]]]? = nil

    public enum Failure: Error, Equatable { case tooBig, notPack, newer, empty
        public var text: String {
            switch self {
            case .tooBig: return "文件太大，不像是 MoguHelper 的资料。"
            case .notPack: return "打不开：不是 MoguHelper 的资料文件，或者文件坏了。"
            case .newer: return "这份资料是新版 MoguHelper 做的，请先更新软件。"
            case .empty: return "里面没有能用的地图或掉落记录。"
            }
        }
    }
    public static let maxBytes = 3_000_000

    /// 从自己的记录导出：认残的图（没有一个走通的门，也没有别的图通到它、没捡到过东西）不放
    public init(maps all: [String: WalkedMap], drops: [String: [String: Int]], npcs met: [String: [String: [Double]]] = [:], mobs seen: [String: [String: [Int]]] = [:], day: String) {
        self.day = day
        self.drops = drops.filter { !$0.value.isEmpty }
        npcs = met.isEmpty ? nil : met
        mobs = seen.isEmpty ? nil : seen
        var keep = Set(self.drops.keys).union(met.filter { !$0.value.isEmpty }.keys).union(seen.filter { !$0.value.isEmpty }.keys)
        for (k, m) in all { for e in m.exits where e.door { keep.insert(k); keep.insert(e.to) } }
        var out: [String: WalkedMap] = [:]
        for (k, m) in all where keep.contains(k) { var x = m; x.exits = m.exits.filter { $0.door && all[$0.to] != nil }; out[k] = x }
        maps = out
        self = cleaned()
    }
    public func data() throws -> Data { let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]; return try e.encode(self) }
    public static func read(_ d: Data) throws -> MoguPack {
        guard d.count <= maxBytes else { throw Failure.tooBig }
        struct Head: Decodable { var format: String, version: Int }
        guard let h = try? JSONDecoder().decode(Head.self, from: d), h.format == "mogu" else { throw Failure.notPack }
        guard h.version == 1 else { throw Failure.newer }
        guard let p = try? JSONDecoder().decode(MoguPack.self, from: d) else { throw Failure.notPack }
        let c = p.cleaned()
        guard !c.maps.isEmpty || !c.drops.isEmpty else { throw Failure.empty }
        return c
    }
    private static func ok(_ s: String, _ n: Int) -> Bool { !s.isEmpty && s.count <= n && s.unicodeScalars.allSatisfy { $0.value >= 32 && $0.value < 127 } }
    private func cleaned() -> MoguPack {
        func unit(_ v: Double) -> Bool { v.isFinite && v >= 0 && v <= 1 }
        func far(_ v: Double) -> Bool { v.isFinite && abs(v) < 5000 }
        var p = self
        p.day = Self.ok(day, 10) ? day : ""
        p.maps = [:]; p.drops = [:]; p.npcs = nil; p.mobs = nil
        for (k, m) in maps.prefix(3000) where Self.ok(k, 130) && Self.ok(m.street, 60) && Self.ok(m.name, 60) && k.split(separator: "|", omittingEmptySubsequences: false).count == 3 {
            var x = m
            x.doors = min(12, max(0, m.doors))
            if let v = x.sx, !far(v) { x.sx = nil }; if let v = x.sy, !far(v) { x.sy = nil }
            if let v = x.h, !far(v) || v <= 0 { x.h = nil }
            if let t = x.town, maps[t] == nil || t == k { x.town = nil }
            x.exits = Array(m.exits.filter { $0.door && $0.to != k && maps[$0.to] != nil && unit($0.fx) && unit($0.fy) && ($0.lx.map(unit) ?? true) }.prefix(40))
            for i in x.exits.indices { x.exits[i].n = min(999, max(1, x.exits[i].n)); if let v = x.exits[i].ax, !far(v) { x.exits[i].ax = nil }; if let v = x.exits[i].ay, !far(v) { x.exits[i].ay = nil } }
            p.maps[k] = x
        }
        let have = Set(p.maps.keys)
        for k in have { p.maps[k]!.exits.removeAll { !have.contains($0.to) } }
        for (k, d) in drops where p.maps[k] != nil {
            let g = d.filter { Self.ok($0.key, 60) && $0.value > 0 }.mapValues { min($0, 99_999) }
            if !g.isEmpty { p.drops[k] = Dictionary(uniqueKeysWithValues: g.sorted { $0.key < $1.key }.prefix(300).map { ($0.key, $0.value) }) }
        }
        var met: [String: [String: [Double]]] = [:]
        for (k, d) in npcs ?? [:] where p.maps[k] != nil {
            let g = d.filter { Self.ok($0.key, 30) && ($0.value.count == 1 || $0.value.count == 3) && unit($0.value[0]) && $0.value.allSatisfy(far) }
            if !g.isEmpty { met[k] = Dictionary(uniqueKeysWithValues: g.sorted { $0.key < $1.key }.prefix(80).map { ($0.key, $0.value) }) }
        }
        if !met.isEmpty { p.npcs = met }
        var seen: [String: [String: [Int]]] = [:]
        for (k, d) in mobs ?? [:] where p.maps[k] != nil {
            let g = d.filter { Self.ok($0.key, 30) && $0.value.count == 3 && (0...250).contains($0.value[0]) && $0.value[1] >= 0 && $0.value[2] >= 0 && $0.value[1] + $0.value[2] > 0 }
                .mapValues { [$0[0], min($0[1], 99_999), min($0[2], 99_999)] }
            if !g.isEmpty { seen[k] = Dictionary(uniqueKeysWithValues: g.sorted { $0.key < $1.key }.prefix(40).map { ($0.key, $0.value) }) }
        }
        if !seen.isEmpty { p.mobs = seen }
        return p
    }
    /// 几份合在一起看：自己的优先，别人的补上没有的门；捡到的数取最多的一份（同一份导两次不会翻倍）
    public static func merged(own: MoguPack, _ packs: [MoguPack]) -> MoguPack {
        var o = own
        for p in packs {
            for (k, m) in p.maps {
                guard o.maps[k] != nil else { o.maps[k] = m; continue }
                if o.maps[k]!.h == nil { o.maps[k]!.h = m.h }
                if o.maps[k]!.town == nil { o.maps[k]!.town = m.town }
                // 自己走过的门没记下整张图里的位置：用资料里的补上（大图上下也能指）
                for i in o.maps[k]!.exits.indices where o.maps[k]!.exits[i].ax == nil {
                    if let e = m.exits.first(where: { $0.to == o.maps[k]!.exits[i].to }), e.ax != nil { o.maps[k]!.exits[i].ax = e.ax; o.maps[k]!.exits[i].ay = e.ay }
                }
                for e in m.exits where !o.maps[k]!.exits.contains(where: { $0.to == e.to }) { o.maps[k]!.exits.append(e) }
            }
            for (k, d) in p.npcs ?? [:] { var n = o.npcs ?? [:]; n[k, default: [:]].merge(d) { a, _ in a }; o.npcs = n }
            for (k, d) in p.drops { o.drops[k, default: [:]].merge(d) { max($0, $1) } }
            // 怪：等级用自己的，次数取多的那份
            for (k, d) in p.mobs ?? [:] { var n = o.mobs ?? [:]; n[k, default: [:]].merge(d) { a, b in [a[0] > 0 ? a[0] : b[0], max(a[1], b[1]), max(a[2], b[2])] }; o.mobs = n }
        }
        return o
    }

    // MARK: 找路
    public struct Step: Equatable, Sendable { public var text: String, to: String }
    /// 走过的门连起来的最短路；没走过的反方向当作推测。走不到返回 nil
    public func route(from: String, to: String) -> [Step]? {
        guard maps[from] != nil, maps[to] != nil else { return nil }
        if from == to { return [] }
        var back: [String: [String]] = [:]
        for (k, m) in maps { for e in m.exits { back[e.to, default: []].append(k) } }
        var prev: [String: (from: String, text: String)] = [:], queue = [from], seen: Set<String> = [from], i = 0
        while i < queue.count {
            let k = queue[i]; i += 1
            if k == to { break }
            let hk = maps[k]!.h
            var next: [(String, String)] = maps[k]!.exits.sorted { $0.to < $1.to }.map { ($0.to, "走\(Self.side($0.fx, ay: $0.ay, h: hk))的门") }
            next += (back[k] ?? []).sorted().map { b in (b, maps[b]!.exits.first { $0.to == k }?.lx.map { "走\(Self.side($0))的门（推测，来的时候走过）" } ?? "原路返回的门（推测）") }
            for (n, t) in next where seen.insert(n).inserted { prev[n] = (k, t); queue.append(n) }
        }
        guard prev[to] != nil else { return nil }
        var out: [Step] = [], k = to
        while k != from { let p = prev[k]!; out.append(Step(text: "\(p.text) → \(maps[k]!.name)", to: k)); k = p.from }
        return out.reversed()
    }
    public static func side(_ f: Double) -> String { f < 0.15 ? "最左边" : f < 0.4 ? "左边" : f < 0.6 ? "中间" : f < 0.85 ? "右边" : "最右边" }
    /// 高的图（超过一屏半，和自用版一样）再说上层、中层、下层
    public static func side(_ f: Double, ay: Double?, h: Double?) -> String {
        guard let y = ay, let h, h > 900 / 16 else { return side(f) }
        let r = y / h
        return side(f) + (r < 0.35 ? "上层" : r > 0.7 ? "下层" : "中层")
    }
    /// 在哪捡到过，多的在前
    public func places(_ item: String) -> [(key: String, n: Int)] {
        drops.compactMap { k, d in d[item].map { (key: k, n: $0) } }.sorted { ($0.n, $1.key) > ($1.n, $0.key) }
    }
}
