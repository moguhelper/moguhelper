// 没有地图资料（公开版）的带路：只用自己走过的门、路过时看到的 NPC，和朋友互传的 .mogu。
import CoreGraphics
import Foundation

/// 路过时看到的 NPC：黄字名牌
public enum NpcTags {
    static func yellow(_ c: (Int, Int, Int)) -> Bool { c.0 >= 225 && c.1 >= 225 && c.2 <= 110 }
    /// 只留黄字（白底黑字）；黄点太少返回 nil，不用识别
    public static func isolate(_ im: CGImage) -> CGImage? {
        guard let p = MiniMap.Pix(im) else { return nil }
        var out = [UInt8](repeating: 255, count: p.w * p.h), n = 0
        for y in 0..<p.h { for x in 0..<p.w where yellow(p.rgb(x, y)) { out[y * p.w + x] = 0; n += 1 } }
        guard n >= 150, n < p.w * p.h / 20, let d = CGDataProvider(data: Data(out) as CFData) else { return nil }
        return CGImage(width: p.w, height: p.h, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: p.w, space: CGColorSpaceCreateDeviceGray(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue), provider: d, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
    /// 像 NPC 名字的：大写开头、没有句子的样子
    public static func name(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard t.range(of: "^[A-Z][A-Za-z.'’&-]+( (the|of|and|[A-Z][A-Za-z.'’&-]*)){0,4}$", options: .regularExpression) != nil, t.filter(\.isLetter).count >= 3, t.count <= 28 else { return nil }
        // 伤害、提示之类的大写词
        return t.uppercased() == t && t.count <= 5 ? nil : t
    }
}

/// 看到的 NPC：图 → 名字 → 在小地图画面里的左右位置、看到几次
public struct NpcBook: Codable, Sendable, Equatable {
    public struct Spot: Codable, Sendable, Equatable { public var fx: Double, n: Int, ax: Double? = nil, ay: Double? = nil; public var list: [Double] { if let ax, let ay { return [fx, ax, ay] }; return [fx] } }
    public var maps: [String: [String: Spot]] = [:]
    private var pending: [String: (fx: Double, at: Date)] = [:]
    private enum CodingKeys: String, CodingKey { case maps }
    public init() {}
    public static func == (a: NpcBook, b: NpcBook) -> Bool { a.maps == b.maps }
    /// 两次（隔 2 秒以上）在差不多的位置看到才算；talk：和他说过话，一次就算。有变化返回 true
    public mutating func see(_ name: String, map: String, fx: Double, ax: Double? = nil, ay: Double? = nil, at t: Date, talk: Bool = false) -> Bool {
        guard fx > -0.02, fx < 1.02 else { return false }
        let x = min(1, max(0, fx))
        // 认错一个字母的并到见过的
        let k = Array(QuestDB.norm(name))
        let known = maps[map]?.keys.first { $0 == name || k.count >= 5 && Fuzzy.distance(k, Array(QuestDB.norm($0)), limit: 1) <= 1 }
        if let o = known, var s = maps[map]?[o] {
            // 整张图的位置以前没有、现在有了：补上（大图滚动时画面里的位置会变，不比）
            if s.ax == nil, let ax, let ay { s.ax = ax; s.ay = ay; s.fx = x; maps[map]![o] = s; return true }
            if s.ax != nil { return false }
            guard abs(s.fx - x) < 0.12, s.n < 50 else { return false }
            s.fx = (s.fx * Double(s.n) + x) / Double(s.n + 1); s.n += 1
            maps[map]![o] = s
            return s.n <= 3
        }
        let id = map + "#" + name
        guard talk || pending[id].map({ abs($0.fx - x) < 0.08 && t.timeIntervalSince($0.at) >= 2 }) == true else {
            if pending[id] == nil || abs(pending[id]!.fx - x) >= 0.08 { pending[id] = (x, t) }
            if pending.count > 300 { pending.removeAll() }
            return false
        }
        pending[id] = nil
        maps[map, default: [:]][name] = Spot(fx: x, n: 1, ax: ax, ay: ay)
        return true
    }
    public func find(_ name: String) -> [(map: String, fx: Double)] {
        maps.compactMap { k, d in d[name].map { (k, $0.fx) } }.sorted { $0.0 < $1.0 }
    }
}

public enum WalkNav {
    public struct Goal: Codable, Sendable, Equatable, Hashable {
        public var label: String, map: String, fx: Double?, ax: Double?, ay: Double?
        /// 到了这张图再找去哪张图的门
        public var next: String? = nil
        public init(label: String, map: String, fx: Double? = nil, ax: Double? = nil, ay: Double? = nil) { self.label = label; self.map = map; self.fx = fx; self.ax = ax; self.ay = ay }
        public var isNpc: Bool { label.hasPrefix("找 ") }
        public var isItem: Bool { label.hasPrefix("捡 ") }
        func same(_ o: Goal) -> Bool { label == o.label && map == o.map }
    }
    /// 任务文字里提到的、自己见过的 NPC 和地图；再加上捡到过的要交的东西
    public static func goals(text: String, items: [String], pack: MoguPack) -> [Goal] {
        var out: [Goal] = []
        func has(_ w: String) -> Bool {
            text.range(of: "(?<![A-Za-z])" + NSRegularExpression.escapedPattern(for: w) + "(?![A-Za-z])", options: .regularExpression) != nil
        }
        let names = Set((pack.npcs ?? [:]).values.flatMap(\.keys))
        // “Nella” 已经算在 “Nella the Elder” 里的不重复
        for n in names.sorted(by: { ($0.count, $1) > ($1.count, $0) }) where has(n) && !out.contains(where: { $0.label.hasPrefix("找 ") && $0.label.contains(n) }) {
            for (k, d) in (pack.npcs ?? [:]).sorted(by: { $0.key < $1.key }) { if let x = d[n], let m = pack.maps[k] { out.append(Goal(label: "找 \(n)（\(m.name)）", map: k, fx: x.first, ax: x.count == 3 ? x[1] : nil, ay: x.count == 3 ? x[2] : nil)) } }
        }
        for i in items { for p in ([i] + QuestTips.drops(of: i)).flatMap({ pack.places($0) }).sorted(by: { ($0.n, $1.key) > ($1.n, $0.key) }).prefix(1) { if let m = pack.maps[p.key] { out.append(Goal(label: "捡 \(i)（\(m.name)）", map: p.key)) } } }
        // 没捡到过：经验里说的图自己走过，也能带去
        for i in items where !out.contains(where: { $0.label.hasPrefix("捡 \(i)（") }) {
            if let m = QuestTips.spots(i).lazy.compactMap({ s in pack.maps.first { $0.value.name == s } }).first { out.append(Goal(label: "捡 \(i)（\(m.value.name)）", map: m.key)) }
        }
        // 只是提到的地名不算要去（用户不要）
        return Array(out.prefix(6))
    }
    /// 去一张图：走过的直接去；没走过的，去攻略里那条路上离它最近、走过的那张
    public static func place(_ n: String, pack: MoguPack) -> Goal? {
        if let m = pack.maps.first(where: { $0.value.name == n }) { return Goal(label: "去 \(n)", map: m.key) }
        let way = QuestTips.way(n)
        for (i, w) in way.enumerated().reversed() {
            guard let m = pack.maps.first(where: { $0.value.name == w }) else { continue }
            var g = Goal(label: "去 \(n)", map: m.key); g.next = i + 1 < way.count ? way[i + 1] : n
            return g
        }
        return nil
    }
    /// 打开任务就自动带路去哪：没接、东西齐了 → 找人；还差东西 → 去捡到过的地方
    public static func auto(_ goals: [Goal], accepted: Bool, ready: Bool) -> Goal? {
        let npc = goals.first(where: \.isNpc), item = goals.first(where: \.isItem)
        return accepted && !ready ? item ?? npc : npc ?? item
    }
    /// 任务文字里像人名、地名，但自己没见过的：告诉用户要找谁、去哪
    public static func unknown(text: String, pack: MoguPack) -> [String] {
        let seen = Set((pack.npcs ?? [:]).values.flatMap(\.keys)).union(pack.maps.values.map(\.name))
        guard let re = try? NSRegularExpression(pattern: "\\b(?:(talk to|speak to|speak with|meet|visit|find|see|return to|go to|travel to|in|at|near|from) )((?:the )?[A-Z][A-Za-z'’]+(?: (?:of |the )?[A-Z][A-Za-z'’]+){0,3})") else { return [] }
        var out: [String] = []
        for m in re.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let r = Range(m.range(at: 2), in: text) else { continue }
            let w = text[r].replacingOccurrences(of: "^the ", with: "", options: .regularExpression).replacingOccurrences(of: "['’]s$", with: "", options: .regularExpression)
            if w.count >= 4, !seen.contains(w), !out.contains(w), !["Maple", "Level", "Quest"].contains(w) { out.append(w) }
        }
        return Array(out.prefix(3))
    }
    /// 现在往哪走。me：自己在小地图画面里的左右位置
    public static func hint(_ pack: MoguPack, from: String, goal g: Goal, me: Double?, at: (x: Double?, y: Double?)? = nil) -> NavHint? {
        func arrow(_ fx: Double, _ ax: Double?, _ ay: Double?, _ what: String, _ here: String) -> NavHint {
            // 整张图里的位置都知道：1 点 = 游戏里 16 点，大图滚动也准
            let abs2 = ax.flatMap { a in at?.x.map { a - $0 } }
            let dy = ay.flatMap { a in at?.y.map { a - $0 } } ?? 0
            let v = abs(dy) < 7 ? "" : dy < 0 ? "上" : "下"
            guard abs2 != nil || me != nil else { return NavHint(dir: .none, text: "\(what)在\(MoguPack.side(fx))") }
            let d = abs2 ?? (fx - me!) * 100
            if abs(d) < 3.5 {
                return v.isEmpty ? NavHint(dir: .here, text: here) : NavHint(dir: v == "上" ? .up : .down, text: "往\(v)，\(what)")
            }
            let dir: NavHint.Dir = v.isEmpty ? (d < 0 ? .left : .right) : v == "上" ? (d < 0 ? .upLeft : .upRight) : (d < 0 ? .downLeft : .downRight)
            return NavHint(dir: dir, text: "往\(d < 0 ? "左" : "右")\(v)，\(what)")
        }
        if from == g.map {
            guard let x = g.fx else {
                // 目的地没走过：带到它前面的图，再找门
                if let n = g.next { return NavHint(dir: .none, text: "在这张图找去 \(n) 的门" + (QuestTips.hiddenDoor(n) ? "（隐藏门）" : "")) }
                return NavHint(dir: .here, text: "到了，就在这张图")
            }
            return arrow(x, g.ax, g.ay, g.label.components(separatedBy: "（")[0], "就在这一带")
        }
        guard let r = pack.route(from: from, to: g.map), let s = r.first, let m = pack.maps[s.to] else { return nil }
        let left = r.count > 1 ? "（还有 \(r.count) 张图）" : ""
        if let e = pack.maps[from]?.exits.first(where: { $0.to == s.to }) { return arrow(e.fx, e.ax, e.ay, "进门去 \(m.name)\(left)", "到了，按 ↑ 去 \(m.name)\(left)") }
        if let x = m.exits.first(where: { $0.to == from })?.lx { return arrow(x, nil, nil, "回 \(m.name) 的门（推测）\(left)", "门应该在这一带，按 ↑ 试试") }
        return NavHint(dir: .none, text: "找去 \(m.name) 的门（位置没记下）")
    }
}
