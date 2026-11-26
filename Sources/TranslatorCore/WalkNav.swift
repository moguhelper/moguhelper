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
        /// 去捡东西、去打怪（都是“还差东西”的那一步）
        public var isItem: Bool { label.hasPrefix("捡 ") || label.hasPrefix("打 ") }
        func same(_ o: Goal) -> Bool { label == o.label && map == o.map }
    }
    /// 任务文字里提到的、自己见过的 NPC 和地图；再加上捡到过的要交的东西
    /// from：现在在哪张图（去打怪时挑近的）
    public static func goals(text: String, items: [String], pack: MoguPack, from: String? = nil) -> [Goal] {
        var out: [Goal] = []
        func has(_ w: String) -> Bool {
            text.range(of: "(?<![A-Za-z])" + NSRegularExpression.escapedPattern(for: w) + "(?![A-Za-z])", options: .regularExpression) != nil
        }
        let names = Set((pack.npcs ?? [:]).values.flatMap(\.keys))
        // “Nella” 已经算在 “Nella the Elder” 里的不重复
        for n in names.sorted(by: { ($0.count, $1) > ($1.count, $0) }) where has(n) && !out.contains(where: { $0.label.hasPrefix("找 ") && $0.label.contains(n) }) {
            for k in npcMaps(n, pack: pack, from: from) { if let x = pack.npcs?[k]?[n], let m = pack.maps[k] { out.append(Goal(label: "找 \(n)（\(m.name)）", map: k, fx: x.first, ax: x.count == 3 ? x[1] : nil, ay: x.count == 3 ? x[2] : nil)) } }
        }
        // 任务要的东西、要打的怪一定要告诉玩家（用户定）。顺序：
        // 1. 自己所在的图就有这种怪：就在这里打（资料里的只数不准，玩家看到满图都是）
        // 2. 离现在最近的、有这种怪的图（攻略资料 + 自己见过的；用户定：按远近，不按只数）
        // 3. 自己捡到过的图；4. 经验里写的图
        for i in items {
            let m = mobFor(i, pack: pack)
            if out.contains(where: { $0.label.hasPrefix("打 \(m)（") }) { continue }
            if let f = from, pack.haunts(m).contains(where: { $0.key == f }), let mp = pack.maps[f] { out.append(Goal(label: "打 \(m)（\(mp.name)）", map: f)); continue }
            if let k = pack.nearestHaunt(m, from: from), let mp = pack.maps[k] { out.append(Goal(label: "打 \(m)（\(mp.name)）", map: k)); continue }
            if let p = ([i] + QuestTips.drops(of: i)).flatMap({ pack.places($0) }).sorted(by: { ($0.n, $1.key) > ($1.n, $0.key) }).first, let mp = pack.maps[p.key] { out.append(Goal(label: "捡 \(i)（\(mp.name)）", map: p.key)); continue }
            if let mp = QuestTips.spots(i).lazy.compactMap({ s in pack.maps.first { $0.value.name == s } }).first { out.append(Goal(label: "捡 \(i)（\(mp.value.name)）", map: mp.key)) }
        }
        // 只是提到的地名不算要去（用户不要）
        return Array(out.prefix(6))
    }
    /// 这样东西打谁掉：经验 / 任务卡里写的；资料里本身就是怪；名字是“怪名 + 一个词”的（Blue Mushroom Cap → Blue Mushroom）
    public static func mobFor(_ i: String, pack: MoguPack) -> String {
        if let m = QuestTips.mob(i) { return m }
        if !pack.haunts(i).isEmpty { return i }
        let names = Set((pack.mobs ?? [:]).values.flatMap(\.keys))
        return names.filter { i.count > $0.count + 1 && i.lowercased().hasPrefix($0.lowercased() + " ") }.max { $0.count < $1.count } ?? i
    }
    /// 带路目标里的怪名：“打 Ribbon Pig（L Forest I）” → Ribbon Pig
    public static func mobOf(_ g: Goal) -> String? {
        guard g.label.hasPrefix("打 "), let r = g.label.range(of: "（") else { return nil }
        return String(g.label[g.label.index(g.label.startIndex, offsetBy: 2)..<r.lowerBound])
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
        // 接了、东西没齐：只带去收集；不知道去哪收集就不带（别一直指着交任务的人）
        return accepted && !ready ? item : npc ?? item
    }
    /// 正文写着“什么怪都会掉”（活动道具）：“dropped by monsters Lv. 10 and above”“dropped by all monsters”
    public static func anyMob(_ text: String) -> String? {
        if let r = text.range(of: "(?i)dropped by (?:all |any )?monsters?\\s*(?:of\\s*)?(?:Lv\\.?|level)\\s*(\\d{1,3})\\s*(?:and|or)\\s*(?:above|higher)", options: .regularExpression),
           let n = text[r].range(of: "\\d{1,3}", options: .regularExpression) { return "打 \(text[r][n]) 级以上的怪都会掉，就近打就行" }
        if text.range(of: "(?i)dropped by (?:all|any) monsters", options: .regularExpression) != nil { return "打什么怪都会掉，就近打就行" }
        return nil
    }
    /// 这个 NPC 在哪几张图（组队任务的隐藏图里也有同名的）：近的在前，隐藏街道放最后
    public static func npcMaps(_ n: String, pack: MoguPack, from: String?) -> [String] {
        func hops(_ k: String) -> Int { guard let f = from else { return 0 }; return f == k ? 0 : pack.route(from: f, to: k)?.count ?? 99 }
        func hidden(_ k: String) -> Int { pack.maps[k]?.street == "Hidden Street" ? 1 : 0 }
        return (pack.npcs ?? [:]).filter { $0.value[n] != nil && pack.maps[$0.key] != nil }.keys.sorted { (hidden($0), hops($0), $0) < (hidden($1), hops($1), $1) }
    }
    /// 任务正文里写的交任务的人：“Bring them to the Maple Administrator”“Take it to Shumi”。
    /// names：见过的、资料里有的 NPC 名字。先找 to/bring 后面的；没有就只提到一个的
    public static func endNpc(text: String, names: [String]) -> String? {
        let hit = names.filter { $0.count >= 3 && text.range(of: "\\b" + NSRegularExpression.escapedPattern(for: $0) + "\\b", options: .regularExpression) != nil }
        let to = hit.filter { n in text.range(of: "\\b(to|for|give|bring|tell|see|visit|meet)\\s+(the\\s+)?" + NSRegularExpression.escapedPattern(for: n) + "\\b", options: [.regularExpression, .caseInsensitive]) != nil }
        let pick = to.isEmpty ? hit : to
        // 名字包含在更长名字里的不算（Alex / Alex the Kid）
        let best = pick.filter { n in !pick.contains { $0 != n && $0.contains(n) } }
        return Set(best).count == 1 ? best[0] : nil
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
    /// 坐出租车、用回城卷更快（和自用版一样：省下两张图以上才提）。出租车位置来自资料里的 NPC（Regular Cab），回城回哪来自资料里的“最近的城”
    public static func shortcut(_ pack: MoguPack, from: String, to: String) -> String? {
        guard from != to, pack.maps[to] != nil else { return nil }
        let cabs = Set((pack.npcs ?? [:]).filter { $0.value.keys.contains { $0.hasSuffix("Cab") } }.keys.filter { pack.maps[$0] != nil })
        func hops(_ a: String) -> Int? { a == to ? 0 : pack.route(from: a, to: to)?.count }
        func name(_ k: String) -> String { pack.maps[k]?.name ?? k }
        func rest(_ n: Int) -> String { n == 0 ? "，就在城里" : "，再走 \(n) 张图" }
        var best: (cost: Int, text: String)?
        func consider(_ c: Int, _ t: String) { if c < (best?.cost ?? Int.max) { best = (c, t) } }
        if cabs.contains(from) {
            for t in cabs.sorted() where t != from { if let h = hops(t) { consider(1 + h, "坐出租车到「\(name(t))」" + rest(h)) } }
        }
        if let town = pack.maps[from]?.town, town != from {
            if let h = hops(town) { consider(1 + h, "用回城卷回「\(name(town))」" + rest(h)) }
            if cabs.contains(town) {
                for t in cabs.sorted() where t != town { if let h = hops(t) { consider(2 + h, "用回城卷回「\(name(town))」，坐出租车到「\(name(t))」" + rest(h)) } }
            }
        }
        guard let b = best else { return nil }
        if let walk = pack.route(from: from, to: to), walk.count - b.cost < 2 { return nil }
        return b.text + (b.text.contains("出租车") ? "（出租车要付车费）" : "")
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
