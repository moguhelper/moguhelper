// 没有怪物资料（公开版）时，自己记“哪张图有哪种怪”：
// 打怪时怪头上会出 “Lv. 5 Stump” 这样的名牌（白字、深色底，一下打死的不出），读到就记；
// 任务追踪框里打怪的数在这张图涨了，也算这张图有它。只存名字、等级和次数。
import CoreGraphics
import Foundation

/// 怪物名牌：白字配深色底
public enum MobTags {
    static func white(_ c: (Int, Int, Int)) -> Bool { min(c.0, c.1, c.2) >= 205 && max(c.0, c.1, c.2) - min(c.0, c.1, c.2) <= 40 }
    static func dark(_ c: (Int, Int, Int)) -> Bool { max(c.0, c.1, c.2) <= 85 }
    /// 只留旁边贴着深色底的白点（天上的云、白色界面旁边不是深色，丢掉），变成白底黑字；太少返回 nil，不用识别
    /// skip：不要的一块（像素，自己的名牌：怪贴着自己时会和它读成一行）
    public static func isolate(_ im: CGImage, skip: CGRect? = nil) -> CGImage? {
        guard let p = MiniMap.Pix(im) else { return nil }
        var isDark = [Bool](repeating: false, count: p.w * p.h)
        for y in 0..<p.h { for x in 0..<p.w where dark(p.rgb(x, y)) { isDark[y * p.w + x] = true } }
        var out = [UInt8](repeating: 255, count: p.w * p.h), n = 0
        let r = 4
        for y in r..<max(r, p.h - r) {
            for x in r..<max(r, p.w - r) where white(p.rgb(x, y)) {
                if let k = skip, k.contains(CGPoint(x: x, y: y)) { continue }
                let i = y * p.w + x
                guard isDark[i - r] || isDark[i + r] || isDark[i - r * p.w] || isDark[i + r * p.w] else { continue }
                out[i] = 0; n += 1
            }
        }
        guard n >= 40, n < p.w * p.h / 25, let d = CGDataProvider(data: Data(out) as CFData) else { return nil }
        return CGImage(width: p.w, height: p.h, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: p.w, space: CGColorSpaceCreateDeviceGray(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue), provider: d, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
    // “Lv.” 字小，常读成 “L”、“Lv”、“LV.”；名字后面可能粘着血条、别人的名牌读出的乱码
    private static let whole = try! NSRegularExpression(pattern: "^L[vV]?[.,:]?\\s*(\\d{1,3})\\s+([A-Z].*)$")
    private static let lvOnly = try! NSRegularExpression(pattern: "^L[vV]?[.,:]?\\s*(\\d{1,3})$")
    private static func groups(_ re: NSRegularExpression, _ s: String) -> [String]? {
        guard let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return nil }
        return (1..<m.numberOfRanges).compactMap { Range(m.range(at: $0), in: s).map { String(s[$0]) } }
    }
    /// 名字：从头取像单词的（大写开头、后面小写；of、the 也行），碰到乱码就停；再按见过的怪名补全、纠正
    /// skip：自己、宠物的名字（会和怪的名牌读成一行）：读到它（错一个字母也算）就截断
    static func cleanName(_ s: String, known: [String] = [], skip: [String] = []) -> (name: String, sure: Bool)? {
        let bad = skip.flatMap { $0.split(separator: " ").map { Array($0.lowercased()) } }.filter { $0.count >= 4 }
        var words: [String] = []
        for w in s.split(separator: " ").map(String.init) {
            if bad.contains(where: { Fuzzy.distance(Array(w.lowercased()), $0, limit: 1) <= 1 }) { break }
            // “KittSomeName”：粘着的名字从中间截
            if let c = skip.first(where: { $0.count >= 4 && w.contains($0) }), let r = w.range(of: c) { let head = String(w[..<r.lowerBound]); if head.count >= 3, words.isEmpty || head.first!.isUppercase { words.append(head) }; break }
            if w.range(of: "^([A-Z][a-z'’.-]*|of|the|Jr\\.)$", options: .regularExpression) != nil { words.append(w) } else {
                // “PigSomeName”：前面一截像单词就留下
                if let r = w.range(of: "^[A-Z][a-z]{2,}", options: .regularExpression) { words.append(String(w[r])) }
                break
            }
            if words.count == 4 { break }
        }
        let t = words.joined(separator: " ")
        guard t.filter(\.isLetter).count >= 3, t.count <= 30 else { return nil }
        let names = known + QuestTips.mobNames
        if names.contains(t) { return (t, true) }
        // 后面粘着别的字：取见过的怪名里最长的那个开头
        if let a = names.filter({ t.hasPrefix($0 + " ") }).max(by: { $0.count < $1.count }) { return (a, true) }
        // 只读到前半截（“Ribbon”）：见过的怪里只有一个这样开头的就是它
        let head = names.filter { $0.hasPrefix(t + " ") }
        if Set(head).count == 1 { return (head[0], true) }
        if let c = QuestTips.snap(t) { return (c, true) }
        return (t, false)
    }
    /// 一行文字 → (等级, 名字)。必须有 “Lv.”，自己和别人的角色名牌没有
    /// sure：名字是见过的怪（任务经验里有、这台机器记过）；不是的要多看到几次才记
    public static func parse(_ s: String, known: [String] = [], skip: [String] = []) -> (lv: Int, name: String, sure: Bool)? {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard let g = groups(whole, t), g.count == 2, let lv = Int(g[0]), (1...250).contains(lv), let n = cleanName(g[1], known: known, skip: skip) else { return nil }
        return (lv, n.name, n.sure)
    }
    /// 识别出的几行 → 名牌。“Lv. 5” 和名字有时被分成两行：同一高度、紧挨在右边的接上
    public static func read(_ lines: [OCRLine], known: [String] = [], skip: [String] = []) -> [(lv: Int, name: String, sure: Bool)] {
        var out: [(lv: Int, name: String, sure: Bool)] = []
        for l in lines where l.confidence >= 0.3 {
            if let m = parse(l.text, known: known, skip: skip) { out.append(m); continue }
            guard let g = groups(lvOnly, l.text.trimmingCharacters(in: .whitespaces)), let lv = Int(g[0]), (1...250).contains(lv) else { continue }
            let h = l.maxY - l.minY, mid = (l.minY + l.maxY) / 2
            let right = lines.filter { $0.minX >= l.maxX - 0.005 && $0.minX - l.maxX < 0.06 && abs(($0.minY + $0.maxY) / 2 - mid) < max(h, 0.01) * 0.6 }.min { $0.minX < $1.minX }
            if let r = right, let n = cleanName(r.text, known: known, skip: skip) { out.append((lv, n.name, n.sure)) }
        }
        return out
    }
}

/// 每张图见过的怪：图 key（街道|地名）→ 怪物英文名 → 等级、名牌看到几次、追踪框里在这里打了几只
public struct MobSeen: Codable, Sendable, Equatable {
    public struct Mob: Codable, Sendable, Equatable {
        public var lv: Int?, seen: Int, kills: Int
        public init(lv: Int?, seen: Int, kills: Int) { self.lv = lv; self.seen = seen; self.kills = kills }
    }
    public var maps: [String: [String: Mob]] = [:]
    private var pending: [String: (at: Date, n: Int)] = [:]
    /// 等级读到和记下的不一样：要连着两次一样才改
    private var lvVote: [String: Int] = [:]
    private enum CodingKeys: String, CodingKey { case maps }
    public init() {}
    public init(maps: [String: [String: Mob]]) { self.maps = maps }
    public static func == (a: MobSeen, b: MobSeen) -> Bool { a.maps == b.maps }
    /// 认错一个字母的并到见过的（任何一张图上见过的都算）
    public func known(_ name: String) -> String? {
        let k = Array(QuestDB.norm(name))
        var best: String?
        for d in maps.values { for o in d.keys {
            if o == name { return o }
            if best == nil, k.count >= 5, Fuzzy.distance(k, Array(QuestDB.norm(o)), limit: 1) <= 1 { best = o }
        } }
        return best
    }
    /// 看到一个名牌：同一张图、同一个名字隔 1.5 秒以上看到两次才算（一帧认花的不记）。有变化返回 true
    /// sure = false（不认识的名字）：要看到 3 次
    public mutating func saw(_ name: String, lv: Int, map: String, at t: Date, sure: Bool = true) -> Bool {
        let n = known(name) ?? name
        if var m = maps[map]?[n] {
            m.seen = min(m.seen + 1, 99_999)
            // “Lv.” 认成数字：14 读成 214。只是前面多了一位的不要；别的新数字连着两次一样才改
            let id = map + "#" + n
            var changed = false
            if let old = m.lv, lv != old {
                if lv >= 100, String(lv).hasSuffix(String(old)) { lvVote[id] = nil }
                else if lvVote[id] == lv { changed = true; lvVote[id] = nil }
                else { lvVote[id] = lv }
            } else { lvVote[id] = nil }
            if m.lv == nil || changed { m.lv = lv }
            maps[map]![n] = m
            return m.seen <= 3 || changed
        }
        let id = map + "#" + n
        let p = pending[id]
        if let p, t.timeIntervalSince(p.at) >= 1.5 { pending[id] = (t, p.n + 1) } else if p == nil { pending[id] = (t, 1) }
        if pending.count > 300 { pending.removeAll() }
        guard let q = pending[id], q.n >= (sure || known(name) != nil ? 2 : 3) else { return false }
        pending[id] = nil
        maps[map, default: [:]][n] = Mob(lv: lv, seen: 2, kills: 0)
        return true
    }
    /// 任务追踪框里打这种怪的数在这张图涨了 n（n = 0：只知道这张图有它，比如捡到了它掉的东西）
    public mutating func killed(_ name: String, map: String, n: Int) {
        let k = known(name) ?? name
        var m = maps[map]?[k] ?? Mob(lv: nil, seen: 0, kills: 0)
        m.kills = min(m.kills + max(0, n), 99_999)
        maps[map, default: [:]][k] = m
    }
    /// 这张图的怪，等级低的在前
    public func list(_ map: String) -> [(name: String, mob: Mob)] {
        (maps[map] ?? [:]).map { (name: $0.key, mob: $0.value) }.sorted { ($0.mob.lv ?? 999, $0.name) < ($1.mob.lv ?? 999, $1.name) }
    }
    /// 存进 .mogu 的样子：图 → 名字 → [等级（0 = 不知道）, 名牌次数, 打了几只]
    public var packed: [String: [String: [Int]]] { maps.mapValues { $0.mapValues { [$0.lv ?? 0, $0.seen, $0.kills] } } }
}

extension MoguPack {
    /// 有这种怪的图：图 key 和“打过几只、看到几次”
    public func haunts(_ mob: String) -> [(key: String, kills: Int, seen: Int)] {
        (mobs ?? [:]).compactMap { k, d in d[mob].flatMap { v in v.count == 3 ? (key: k, kills: v[2], seen: v[1]) : nil } }
    }
    /// 做任务去哪打：离现在最近的、有这种怪的图（资料里的只数和现服不一样，不按只数筛；一样近的挑打过多、见得多的）
    public func nearestHaunt(_ mob: String, from: String?) -> String? {
        guard let f = from else { return bestHaunt(mob, from: nil) }
        func hops(_ k: String) -> Int { f == k ? 0 : route(from: f, to: k)?.count ?? 99 }
        return haunts(mob).min { (hops($0.key), -$0.kills, -$0.seen, $0.key) < (hops($1.key), -$1.kills, -$1.seen, $1.key) }?.key
    }
    /// 去哪张图打它：先挑走得最近的，一样近的挑打得多的（打得快、怪多）
    public func bestHaunt(_ mob: String, from: String?) -> String? {
        // 只刷一两只的图不算（攻略资料里有刷新点个数）：留打过的、或刷新点不少于最多那张一半的
        let top = haunts(mob).map(\.seen).max() ?? 0
        let all = haunts(mob).filter { $0.kills > 0 || $0.seen * 2 >= top }
        func hops(_ k: String) -> Int { guard let f = from else { return 0 }; return f == k ? 0 : route(from: f, to: k)?.count ?? 99 }
        return all.min { (hops($0.key), -$0.kills, -$0.seen, $0.key) < (hops($1.key), -$1.kills, -$1.seen, $1.key) }?.key
    }
}
