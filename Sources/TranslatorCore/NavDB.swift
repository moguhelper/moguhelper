// 任务导航：地图表（Maps.json，开发时整理好打包，运行时不联网）+ 认地图 + 找路。
// 只给文字路线，不碰游戏。
import Foundation

public struct NavMap: Decodable, Sendable {
    public var id: Int, street: String, name: String
    public var box: [Double]            // 左 上 右 下（地图坐标，y 向下）
    public var portals: [[Double]]      // 目标图, x, y, 类型（-1 = 位置未知，推测的反向连接）
    public var npcs: [[Double]]         // 编号, x, y
    public var mobs: [[Int]]            // 怪物编号, 几个刷新点
    public var ret: Int                 // 在这里用回城卷会到哪张图
    public var mini: [Double]           // 小地图整张的宽、高（像素），没有就是空的
    /// 同一张图里的隐藏传送点：入口 x, y, 出口 x, y, 类型（3 = 踩上去自动传）
    public var warps: [[Double]]? = nil
}
public struct NavQuest: Decodable, Sendable {
    public struct Need: Decodable, Sendable {
        public var name: String, count: Int
        public init(from d: Decoder) throws { var c = try d.unkeyedContainer(); name = try c.decode(String.self); count = try c.decode(Int.self) }
    }
    public var id: Int, start: Int?, end: Int?
    public var mobs: [Need], items: [Need]
    /// 几级能交、几级能接；给多少金币、经验
    public var level: Int?, slevel: Int?, meso: Int?, exp: Int?
}
/// 现在要导航的任务
public struct NavTarget: Codable, Sendable, Equatable {
    public var title: String
    public var start: Int?, end: Int?
    /// 任务编号；同名任务（“Donating to …”）分不清是哪个时为 nil，不显示要交什么
    public var questId: Int?
    /// 还没接（正文是接任务前的那段）
    public var notStarted = false
    /// 要打的怪（英文名）；guess = 从说明文字、物品名猜的
    public var mobs: [String] = []
    public var mobGuess = false
    /// 已经接了（看到进度、追踪里有、或正文是接了以后的那段）
    public var accepted: Bool? = nil
    /// 资料里没有的任务：屏幕上目标的中文、系统翻译的一句说明
    public var zh: [String: String]? = nil
    public var brief: String? = nil
    /// 资料里没有的任务：刚和谁说完话接的
    public var giver: String? = nil
    /// 资料里没有的任务：屏幕上的英文（找人名、地名用，只存本机）
    public var en: String? = nil
    /// 资料里没有的任务：要的东西（屏幕上的英文名，排好序）。同名的几个任务（“Nella & Kerning City Citizens” 里 Don Hwang、Shumi 的委托）靠它分开
    public var part: String? = nil
    /// 没有要收集的东西（只要找人说话的一步）：用正文开头区分是系列里的哪一步（“说:idelivered…”）
    public static func talkPart(_ paragraphs: [String]) -> String? {
        let s = String(paragraphs.joined(separator: " ").lowercased().filter(\.isLetter).prefix(40))
        return s.count >= 20 ? "说:" + s : nil
    }
    /// 两个“说:”是不是同一步（识别有一两个字母出入）
    public static func samePart(_ a: String, _ b: String) -> Bool {
        guard a.hasPrefix("说:"), b.hasPrefix("说:") else { return a == b }
        return Fuzzy.distance(Array(a), Array(b), limit: 6) <= 6
    }
    /// 几级才能交（屏幕上写的“Reaching Level 10”，或资料里的）
    public var level: Int? = nil
    public init(title: String, start: Int? = nil, end: Int? = nil, questId: Int? = nil, notStarted: Bool = false) { self.title = title; self.start = start; self.end = end; self.questId = questId; self.notStarted = notStarted }
}
public struct NavPoint: Sendable, Equatable {
    public var x: Double, y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
}
public struct NavRoute: Sendable, Equatable {
    public var steps: [String]
    public var arrived: Bool
    /// 路线里有“入口位置未知”的一段
    public var uncertain: Bool
    /// 现在这张图里要去的点（同一张目标图可能有几个门，哪个近去哪个）；空 = 没有具体位置
    public var next: [NavPoint] = []
    public enum Kind: Sendable { case portalUp, portalAuto, hidden, npc, mob, unknown }
    public var kind: Kind = .unknown
    /// 走过去要过几张图、到哪张图、在那张图的什么位置（找 NPC 才有）
    public var hops = 0
    public var goalMap = 0
    public var goalSide = ""
    /// 要找的 NPC 叫什么（箭头条上写）
    public var npcName = ""
    /// 找这个 NPC 是为了坐船、传送
    public var ride = ""
    public init(steps: [String], arrived: Bool, uncertain: Bool, next: [NavPoint] = [], kind: Kind = .unknown) {
        self.steps = steps; self.arrived = arrived; self.uncertain = uncertain; self.next = next; self.kind = kind
    }
}

public final class NavDB: @unchecked Sendable {
    private struct File: Decodable { var maps: [NavMap]; var npcs: [String: String]; var mobs: [String: String]; var quests: [NavQuest] }
    public let maps: [Int: NavMap]
    private let npcNames: [Int: String]
    private let quests: [Int: NavQuest]
    /// 自己走出来的门（隐藏门、表里没位置的入口）：图 → [目标图, x, y, 5]
    private let extraLock = NSLock()
    private var extra: [Int: [[Double]]] = [:]
    public func setWalked(_ links: [WalkedLink]) {
        var e: [Int: [[Double]]] = [:]
        let towns = Set(cabTowns)
        for l in links where maps[l.from] != nil && maps[l.to] != nil && l.from != l.to {
            // 城和城之间多半是坐车
            if towns.contains(l.from), towns.contains(l.to) { continue }
            // 表里已经有位置的门不重复加
            if maps[l.from]!.portals.contains(where: { Int($0[0]) == l.to && $0[3] >= 0 }) { continue }
            // 坐船过去的不是门
            if rides(l.from).contains(where: { Int($0.door[0]) == l.to && $0.npc != 0 }) { continue }
            // 站在蓝圈上记的是普通传送门，别的可能是隐藏门
            e[l.from, default: []].append([Double(l.to), l.x, l.y, l.door == true ? 2 : 5])
        }
        extraLock.lock(); extra = e; extraLock.unlock()
    }
    /// 找 NPC 坐船：图 → [目标图, NPC 的 x, y, 8]（资料里的 + 自己坐过的）。没写 NPC 的是位置不明的入口
    private var rideDoors: [Int: [(door: [Double], npc: Int, how: String)]] = [:]
    private func loadRides() {
        for r in QuestTips.rides {
            guard let to = maps.values.filter({ $0.name == r.to }).min(by: { $0.id < $1.id })?.id else { continue }
            for m in maps.values where m.name == r.from {
                if r.npc.isEmpty { rideDoors[m.id, default: []].append(([Double(to), 0, 0, -1], 0, "")); continue }
                guard let n = m.npcs.first(where: { npcNames[Int($0[0])] == r.npc }) else { continue }
                rideDoors[m.id, default: []].append(([Double(to), n[1], n[2], 8], Int(n[0]), r.how))
            }
        }
    }
    /// 和 NPC 说完话被送走了：记成一条路
    public func addRide(from: Int, npc: Int, to: Int) {
        extraLock.lock(); defer { extraLock.unlock() }
        guard maps[to] != nil, let n = maps[from]?.npcs.first(where: { Int($0[0]) == npc }), rideDoors[from]?.contains(where: { Int($0.door[0]) == to }) != true else { return }
        rideDoors[from, default: []].append(([Double(to), n[1], n[2], 8], npc, "送你去"))
    }
    /// 这张图里叫这个名字的 NPC（出租车不算：路线另外提示）
    public func rider(_ name: String, in id: Int) -> Int? {
        let hit = (maps[id]?.npcs ?? []).map { Int($0[0]) }.filter { n in let s = npcName(n); return !s.hasSuffix("Cab") && Fuzzy.similar(s, name, tolerance: 0.15) }
        return Set(hit).count == 1 ? hit[0] : nil
    }
    private func rides(_ id: Int) -> [(door: [Double], npc: Int, how: String)] { extraLock.lock(); defer { extraLock.unlock() }; return rideDoors[id] ?? [] }
    /// 表里的门 + 自己走出来的
    func doors(_ id: Int) -> [[Double]] {
        extraLock.lock(); defer { extraLock.unlock() }
        let mine = extra[id] ?? []      // 自己走出来的最准，有了就不用推算的
        return (maps[id]?.portals ?? []).filter { p in p[3] >= 0 || !mine.contains { $0[0] == p[0] } }.map { p in p[3] < 0 ? found[id]?[Int(p[0])].map { [p[0], $0.x, $0.y, 2] } ?? p : p } + mine + (rideDoors[id] ?? []).map(\.door)
    }
    /// 资料里没位置的门，从小地图蓝圈对出来的位置：图 → 目标图 → 位置
    private var found: [Int: [Int: NavPoint]] = [:]
    public func setDoors(_ id: Int, _ d: [Int: NavPoint]) { extraLock.lock(); found[id] = d; extraLock.unlock() }
    /// 这张图有没有还不知道位置的门
    public func unplaced(_ id: Int) -> Bool { doors(id).contains { $0[3] < 0 } }
    /// 小地图上看到的蓝圈里，去掉位置已知的门，剩下的和“没位置的门”对上号；个数对不上就不猜。
    /// 几个门分哪个：对面那扇门在图的左边，这边多半在右边，反过来也是；在中间就算中间
    public func placeDoors(_ id: Int, rings: [NavPoint]) -> [Int: NavPoint]? {
        guard let m = maps[id], m.box[2] > m.box[0] else { return nil }
        let w = m.box[2] - m.box[0]
        let known = m.portals.filter { $0[3] >= 0 }
        let lost = m.portals.filter { $0[3] < 0 }.map { Int($0[0]) }
        let free = rings.filter { r in !known.contains { abs($0[1] - r.x) < 70 && abs($0[2] - r.y) < 110 } }
        guard !lost.isEmpty, lost.count <= 3, free.count == lost.count else { return nil }
        if lost.count == 1 { return [lost[0]: free[0]] }
        func want(_ t: Int) -> Double {
            guard let o = maps[t], o.box[2] > o.box[0], let p = o.portals.first(where: { Int($0[0]) == id && $0[3] >= 0 }) else { return 0.5 }
            let f = (p[1] - o.box[0]) / (o.box[2] - o.box[0])
            return f < 0.2 ? 1 : f > 0.8 ? 0 : 0.5
        }
        // 几个门想要的位置要分得开
        let t = lost.map { ($0, want($0)) }.sorted { $0.1 < $1.1 }, r = free.sorted { $0.x < $1.x }
        guard zip(t, t.dropFirst()).allSatisfy({ $1.1 - $0.1 >= 0.4 }), zip(r, r.dropFirst()).allSatisfy({ ($1.x - $0.x) / w > 0.1 }) else { return nil }
        return Dictionary(uniqueKeysWithValues: zip(t.map(\.0), r))
    }
    private let npcAt: [Int: [(map: Int, x: Double, y: Double)]]
    private let mobAt: [String: [(map: Int, n: Int)]]      // 怪物英文名 → 哪些图
    private let keys: [(id: Int, name: [Character], roman: String, street: [Character])]
    private let zhMap: [String: String], zhMob: [String: String], zhItem: [String: String]

    public static let shared: NavDB = {
        func load(_ n: String) -> Data? {
            (GameData.url(n) ?? Bundle.main.url(forResource: n, withExtension: "json") ?? Bundle.module.url(forResource: n, withExtension: "json")).flatMap { try? Data(contentsOf: $0) }
        }
        let f = load("Maps").flatMap { try? JSONDecoder().decode(File.self, from: $0) } ?? File(maps: [], npcs: [:], mobs: [:], quests: [])
        let names = load("QuestNames").flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        return NavDB(f, zh: names?["map"] as? [String: String] ?? [:], mob: names?["mob"] as? [String: String] ?? [:], item: names?["item"] as? [String: String] ?? [:])
    }()

    private init(_ f: File, zh: [String: String], mob: [String: String], item: [String: String]) {
        maps = Dictionary(f.maps.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        npcNames = Dictionary(f.npcs.compactMap { k, v in Int(k).map { ($0, v) } }, uniquingKeysWith: { a, _ in a })
        quests = Dictionary(f.quests.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var at: [Int: [(Int, Double, Double)]] = [:]
        for m in f.maps { for n in m.npcs { at[Int(n[0]), default: []].append((m.id, n[1], n[2])) } }
        npcAt = at.mapValues { $0.map { (map: $0.0, x: $0.1, y: $0.2) } }
        var ma: [String: [(map: Int, n: Int)]] = [:]
        for m in f.maps { for x in m.mobs { if let n = f.mobs[String(x[0])] { ma[n, default: []].append((m.id, x[1])) } } }
        mobAt = ma
        // 和街道名同名的图（“Victoria Road”）不参与：标题被挡时会把街道名那行认成它
        let streets = Set(f.maps.map { String(Self.norm($0.street)) })
        keys = f.maps.filter { !streets.contains(String(Self.norm($0.name))) }.map { (id: $0.id, name: Self.norm($0.name), roman: Self.roman($0.name), street: Self.norm($0.street)) }
        zhMap = zh; zhMob = mob; zhItem = item
        loadRides()
    }

    /// 这张图有哪些怪（英文名）
    public func mobs(in id: Int) -> [String] { mobAt.filter { $0.value.contains { $0.map == id } }.map(\.key).sorted() }
    /// 这张图里这种怪有几个刷新点
    func mobCount(_ en: String, in id: Int) -> Int { mobAt[en]?.first { $0.map == id }?.n ?? 0 }
    public func quest(_ id: Int) -> NavQuest? { quests[id] }
    var allQuests: [NavQuest] { Array(quests.values) }
    func npcIds(_ name: String) -> [Int] { npcNames.filter { $0.value == name && npcAt[$0.key] != nil }.map(\.key).sorted() }
    public func npcName(_ id: Int) -> String { npcNames[id] ?? "?" }
    /// “射手村 Henesys”：中英都写，和游戏里的字对得上
    public func mapName(_ id: Int) -> String {
        guard let m = maps[id] else { return "?" }
        guard let z = zhMap[m.name], !z.contains(m.name) else { return zhMap[m.name] ?? m.name }
        return "\(z) \(m.name)"
    }
    /// 怪物名（头顶显示英文，中英都写）
    public func mobName(_ en: String) -> String { zhMob[en].map { "\($0) \(en)" } ?? en }
    /// 任务物品名：先用任务名字表（和任务窗口译文一致），再查物品表
    public func itemName(_ en: String) -> String { zhItem[en] ?? ItemDB.shared.exact(en)?.zh ?? ItemNames.zh(en) ?? en }
    /// 整段就是一个怪物、NPC、地图名，只认错一个字母（Stume → Stump）：改回来。本来就是名字、是普通单词、像好几个名字的不动
    public func fixName(_ s: String) -> String {
        let k = Fuzzy.normalize(s)
        guard k.count >= 5 else { return s }
        var hit = Set<String>()
        for n in Array(mobAt.keys) + Array(npcNames.values) + maps.values.map(\.name) {
            let m = Fuzzy.normalize(n)
            if m == k { return s }
            if abs(m.count - k.count) <= 1, Fuzzy.distance(k, m, limit: 1) <= 1 { hit.insert(n) }
        }
        guard hit.count == 1, let n = hit.first else { return s }
        let words = s.split(separator: " ").map { $0.lowercased() }
        return words.count == 1 && SpellCheck.isCorrect(words[0]) ? s : n
    }
    public func hasMob(_ en: String) -> Bool { mobAt[en] != nil }
    public func npcMaps(_ id: Int) -> [Int] { (npcAt[id] ?? []).map(\.map) }

    // MARK: 认任务

    /// 从任务详情认出是哪个任务。游戏里大标题可能是系列名（“Legend of the Snail”），表里只有每一步的名字，
    /// 所以先看小标题、正文，再看大标题；都认不出就用摘要里提到的 NPC。认不出返回 nil。
    /// summary：详情上方灰框里的任务摘要（当前这一步要做什么，最准）
    /// “Reaching Level 10”“Only characters at Level 12 or higher can complete this quest.”
    public static func needLevel(_ texts: [String]) -> Int? {
        for t in texts {
            guard let r = t.range(of: "(^\\W{0,3}reach(ing)? (level|lv\\.?) ?[0-9]{1,3}\\W{0,3}$|level [0-9]{1,3} or higher can complete)", options: [.regularExpression, .caseInsensitive]) else { continue }
            if let n = Int(t[r].filter(\.isNumber)), (2...250).contains(n) { return n }
        }
        return nil
    }
    /// 在这张图交、给这么多金币（可能顺带捡了一点）的任务奖励：只有一种可能才算
    public func reward(in map: Int, atMost d: Int, loose: Int = 30) -> Int? {
        let here = Set((maps[map]?.npcs ?? []).map { Int($0[0]) })
        let v = Set(quests.values.compactMap { q in q.end.map(here.contains) == true ? q.meso : nil }.filter { $0 <= d && $0 >= d - loose })
        return v.count == 1 ? v.first : nil
    }
    public func target(title: String, paragraphs: [String], summary: String, objectives: [(name: String, count: String)] = [], db: QuestDB = .shared) -> NavTarget? {
        guard var t = baseTarget(title: title, paragraphs: paragraphs, summary: summary, objectives: objectives, db: db) else { return nil }
        let q = t.questId.flatMap { quest($0) }
        t.level = Self.needLevel([summary] + paragraphs) ?? q?.level
        let listed = (q?.mobs ?? []).map(\.name).filter { mobAt[$0] != nil }
        if !listed.isEmpty { t.mobs = listed; return t }
        // 没写打什么怪、但要交东西（或表里没有的任务）：先看物品名开头（Slime Bubble → Slime），再看文字里说打谁
        guard q == nil || q?.items.isEmpty == false else { return t }
        var m: [String] = []
        let told = t.questId.map { itemMobs($0, db: db) } ?? [:]
        for i in q?.items ?? [] { if let x = told[i.name] ?? describedMob(i.name), !m.contains(x) { m.append(x) } }
        for i in q?.items ?? [] { if let x = mobAt.keys.filter({ i.name.hasPrefix($0 + " ") || i.name.hasPrefix($0 + "'s ") }).max(by: { $0.count < $1.count }), !m.contains(x) { m.append(x) } }
        if m.isEmpty, t.questId != nil || q == nil {
            // 同名任务分不清是哪个时，表里的正文不能用
            let en = [summary] + (t.questId.flatMap { id in db.entries.first { $0.id == id }?.en } ?? paragraphs)
            let sentences = en.flatMap { $0.components(separatedBy: CharacterSet(charactersIn: ".!?")) }
                .filter { $0.range(of: "take out|defeat|kill|hunt|eliminat|slay|get rid|taken? care of|carried by|dropped by|drop(s|ped)? from|beat", options: [.regularExpression, .caseInsensitive]) != nil }
            m = mobsMentioned(sentences.joined(separator: ". "))
        }
        t.mobs = Array(m.prefix(4)); t.mobGuess = !m.isEmpty
        return t
    }

    /// 任务原文里写明的“东西 → 哪种怪”：“20 each of Wooden Board and Slate that Wooden Mask and Rocky Mask use”。
    /// 要求同一句里先列东西、后面用 that / from / by 接怪，两边个数一样，按顺序配对
    public func itemMobs(_ questId: Int, db: QuestDB = .shared) -> [String: String] {
        cacheLock.lock(); if let c = itemMobCache[questId] { cacheLock.unlock(); return c }; cacheLock.unlock()
        var out: [String: String] = [:]
        let items = (quest(questId)?.items ?? []).map(\.name)
        for s in (db.entries.first { $0.id == questId }?.en ?? []).flatMap({ $0.components(separatedBy: CharacterSet(charactersIn: ".!?")) }) {
            let at = items.compactMap { n in s.range(of: "\\b" + NSRegularExpression.escapedPattern(for: n) + "(e?s)?\\b", options: [.regularExpression, .caseInsensitive]).map { (n, $0) } }
                .sorted { $0.1.lowerBound < $1.1.lowerBound }
            // 名字互相包含的分不清，不猜
            guard let last = at.last, !zip(at, at.dropFirst()).contains(where: { $0.1.overlaps($1.1) }) else { continue }
            let tail = String(s[last.1.upperBound...])
            guard let c = tail.range(of: "^,? *(that|which|from|carried by|dropped by|used by)\\b", options: [.regularExpression, .caseInsensitive]) else { continue }
            let m = mobsMentioned(String(tail[c.upperBound...]))
            guard m.count == at.count else { continue }
            for (i, x) in zip(at, m) where out[i.0] == nil { out[i.0] = x }
        }
        cacheLock.lock(); itemMobCache[questId] = out; cacheLock.unlock()
        return out
    }
    /// 物品说明里写明的怪：“A wooden board that Wooden Mask wears.”。只看材料；说明里正好一种怪才算，信件、做出来的东西不算
    public func describedMob(_ item: String) -> String? {
        cacheLock.lock(); if let c = describedCache[item] { cacheLock.unlock(); return c.isEmpty ? nil : c }; cacheLock.unlock()
        var out = ""
        if let e = ItemDB.shared.exact(item), e.cat?.contains("Etc") == true {
            let text = (e.desc ?? []).map { $0.en.joined(separator: " ") }.filter { $0.range(of: "deliver|made of|made out of|shown to|crafted|preserved|a book", options: [.regularExpression, .caseInsensitive]) == nil }
            let all = Set(text.flatMap { mobsMentioned($0) })
            if all.count == 1 { out = all.first! }
        }
        cacheLock.lock(); describedCache[item] = out; cacheLock.unlock()
        return out.isEmpty ? nil : out
    }
    private var describedCache: [String: String] = [:]
    private let cacheLock = NSLock()
    private var itemMobCache: [Int: [String: String]] = [:]

    /// 文字里提到的怪（单复数都算）。前面还有大写词的（“the Oldest Snail”）多半是别的名字，不算
    func mobsMentioned(_ text: String) -> [String] {
        var found: [(Range<String.Index>, String)] = []
        for n in mobAt.keys.sorted(by: { ($0.count, $1) > ($1.count, $0) }) where n.count >= 3 {
            var from = text.startIndex
            while let r = text.range(of: "(?<![A-Za-z-])" + NSRegularExpression.escapedPattern(for: n) + "(e?s)?(?![A-Za-z])", options: .regularExpression, range: from..<text.endIndex) {
                from = r.upperBound
                if found.contains(where: { $0.0.overlaps(r) }) { continue }
                let before = text[..<r.lowerBound].split(separator: " ", omittingEmptySubsequences: true).last.map(String.init) ?? ""
                let verb = ["Defeat", "Kill", "Hunt", "Eliminate", "Slay", "The", "A", "An"].contains(before)
                if before.first?.isUppercase == true, !verb, before.last?.isLetter == true { continue }
                found.append((r, n))
            }
        }
        var out: [String] = []
        for f in found.sorted(by: { $0.0.lowerBound < $1.0.lowerBound }) where !out.contains(f.1) { out.append(f.1) }
        return out
    }

    private func baseTarget(title: String, paragraphs: [String], summary: String, objectives: [(name: String, count: String)], db: QuestDB) -> NavTarget? {
        // 标题：同名的任务全部算候选
        let first = db.candidates(forTitle: title)
        let names = Set(first.map { QuestDB.norm($0.name) })
        let titled = db.entries.filter { names.contains(QuestDB.norm($0.name)) }
        let heads = paragraphs.filter { $0.split(separator: " ").count <= 12 }.compactMap { db.entry(forHeading: $0) }
        let hits = paragraphs.compactMap { p in
            p.split(separator: " ").count <= 12 && db.entry(forHeading: p) != nil ? nil : db.message(for: p, prefer: titled.count == 1 ? titled[0].id : nil) }
        var pick: QuestEntry?, sure = true
        let ids = Set(titled.map(\.id))
        if titled.count == 1 { pick = titled[0] }
        else if titled.count > 1, case let text = (paragraphs + [summary]).joined(separator: " "),
                case let byItem = titled.filter({ e in (quest(e.id)?.items ?? []).contains { text.localizedCaseInsensitiveContains($0.name) } }), byItem.count == 1 {
            pick = byItem[0]        // 同名任务（“Donating to …”）：正文提到要交的东西就能分清
        }
        else if titled.count > 1, Set(titled.map { QuestDB.norm($0.name) }).count > 1, let h = hits.first(where: { ids.contains($0.entry.id) }) { pick = h.entry }
        else if Set(titled.map { QuestDB.norm($0.name) }).count == 1, let t = titled.first {
            // 同名任务分不清：要找的 NPC 都一样才用
            let qs = titled.compactMap { quest($0.id) }
            if Set(qs.map(\.start)).count == 1, Set(qs.map(\.end)).count == 1 { pick = t; sure = false }
        } else if titled.count > 1, let h = (heads + hits.map(\.entry)).filter({ ids.contains($0.id) }).max(by: { $0.id < $1.id }) {
            pick = h        // 编号没写全的系列任务：正文里最后一步
        } else if titled.isEmpty {
            // 系列任务：详情里会列出好几步，最后一步（编号最大）是现在这一步
            let all = hits.map(\.entry) + heads
            pick = all.filter { quest($0.id) != nil }.max { $0.id < $1.id }
        }
        // 系列任务的大标题一直是第一步的名字（“Shawn the Excavator's Request” 其实已经到 “Eliminate Monsters from the Site”）：
        // 屏幕上的目标、正文对得上同一地区后面不远的一步，就是那一步
        if titled.count == 1, let first = pick {
            func later(_ e: QuestEntry) -> Bool { e.area == first.area && e.id > first.id && e.id - first.id <= 10 && quest(e.id) != nil }
            func fits(_ id: Int) -> Bool {
                guard let q = quest(id) else { return false }
                let known = q.mobs + q.items
                return !objectives.isEmpty && objectives.allSatisfy { o in
                    let n = o.count.split(separator: "/").last.flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
                    return known.contains { Fuzzy.similar($0.name, o.name, tolerance: 0.2) && ($0.count == 0 || $0.count == n) }
                }
            }
            if !objectives.isEmpty, fits(first.id) {}        // 就是第一步
            else if let e = hits.map(\.entry).filter(later).max(by: { $0.id < $1.id }), objectives.isEmpty || fits(e.id) || !fits(first.id) { pick = e }
            else if !objectives.isEmpty, case let c = db.entries.filter({ later($0) && fits($0.id) }), c.count == 1 { pick = c[0] }
        }
        let said = npcsMentioned(summary)
        if let e = pick, let q = quest(e.id) {
            // 几个任务共用同一句话（五子棋、配对卡的开头）：那句在这个任务里是第几段就算第几段
            let idx = hits.compactMap { h in h.entry.id == e.id ? h.index : e.en.firstIndex(of: h.entry.en[h.index]) }.max()
            var t = NavTarget(title: e.zhName ?? e.name, start: q.start, end: q.end, questId: sure ? e.id : nil, notStarted: idx == 0)
            if let idx, idx > 0 { t.accepted = true }
            // “可接”页的详情写着 “! Talk to NPC Roger”，没有别的正文：还没接
            if idx == nil, objectives.isEmpty, q.start != nil,
               (paragraphs + [summary]).contains(where: { $0.range(of: "^\\W{0,3}Talk to NPC\\b", options: [.regularExpression, .caseInsensitive]) != nil }) { t.notStarted = true }
            // 已经在做：摘要只提到一个 NPC，就以摘要为准（游戏更新后改过的任务）
            if idx != 0, said.count == 1 { t.end = said[0] }
            return t
        }
        guard let n = said.last ?? paragraphs.lazy.compactMap({ self.npcsMentioned($0).last }).first else { return nil }
        return NavTarget(title: title, start: nil, end: n, questId: nil)
    }

    /// 一段话里提到的 NPC（按出现顺序，有位置资料的才算；名字包含在更长名字里的不算）
    public func npcsMentioned(_ text: String) -> [Int] {
        guard !text.isEmpty else { return [] }
        var found: [(Range<String.Index>, Int)] = []
        for (id, n) in npcNames.sorted(by: { ($0.value.count, $1.key) > ($1.value.count, $0.key) }) where n.count >= 3 && npcAt[id] != nil {
            guard let r = text.range(of: "\\b" + NSRegularExpression.escapedPattern(for: n) + "(?![A-Za-z])", options: .regularExpression),
                  !found.contains(where: { $0.0.overlaps(r) }) else { continue }
            found.append((r, id))
        }
        return found.sorted { $0.0.lowerBound < $1.0.lowerBound }.map(\.1)
    }

    // MARK: 进度（任务详情里的 “75 / 75”）

    /// 这一屏看到的目标 → 进度。表里有要几个的，数对不上的（认错）不要；名字统一成表里的写法
    public func progress(_ objectives: [(name: String, count: String)], target t: NavTarget) -> [String: [Int]] {
        let q = t.questId.flatMap { quest($0) }
        let known = (q?.mobs ?? []) + (q?.items ?? [])
        var out: [String: [Int]] = [:]
        for o in objectives {
            let n = o.count.split(separator: "/").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            guard n.count == 2 else { continue }
            // “1 / 0”：要用掉的东西，手上剩 0 个才算完（记成 0/1、1/1）
            if n[1] == 0 {
                if let k = (q?.items ?? []).first(where: { $0.count == 0 && Fuzzy.similar($0.name, o.name, tolerance: 0.2) }) { out[k.name] = [n[0] == 0 ? 1 : 0, 1] }
                continue
            }
            if let k = known.first(where: { Fuzzy.similar($0.name, o.name, tolerance: 0.2) }) {
                guard k.count == 0 || k.count == n[1] else { continue }
                out[k.name] = n
            } else if known.isEmpty, QuestHelper.plausible(o.name) { out[o.name] = n }
        }
        return out
    }

    /// 任务给你、要你用掉的东西（要求剩 0 个）
    public func useUp(_ name: String, target t: NavTarget) -> Bool {
        t.questId.flatMap { quest($0) }?.items.contains { $0.name == name && $0.count == 0 } == true
    }

    /// 这个目标要打哪种怪（打怪目标就是它；交物品的按物品名开头猜）
    public func mob(forObjective name: String, target t: NavTarget) -> String? {
        if let m = t.mobs.first(where: { Fuzzy.similar($0, name, tolerance: 0.15) }) { return m }
        if mobAt[name] != nil { return name }
        if let q = t.questId, let m = itemMobs(q)[name] { return m }
        return mobAt.keys.filter { name.hasPrefix($0 + " ") || name.hasPrefix($0 + "'s ") }.max { $0.count < $1.count } ?? describedMob(name)
    }

    public enum Next: Sendable, Equatable { case mob(String), end, keep }
    /// 按进度决定接下来去哪：全够了 → 去交；有没打够的怪 → 去打它；剩下的不知道打谁 → 不动
    public func next(_ p: [String: [Int]], target t: NavTarget) -> Next {
        guard !p.isEmpty else { return .keep }
        let q = t.questId.flatMap { quest($0) }
        let order = (q?.mobs ?? []).map(\.name) + (q?.items ?? []).map(\.name)
        let names = order.filter { p[$0] != nil } + p.keys.filter { !order.contains($0) }.sorted()
        for n in names where p[n]![0] < p[n]![1] { if let m = mob(forObjective: n, target: t) { return .mob(m) } }
        // 表里要的每一样都看到了、都够了才算完（没滚到的不算够）
        let all = order.allSatisfy { p[$0] != nil } && p.values.allSatisfy { $0[0] >= $0[1] }
        if all { return .end }
        // 还没看到的里面有要打的怪
        for n in order where p[n] == nil { if let m = mob(forObjective: n, target: t) { return .mob(m) } }
        return .keep
    }

    // MARK: 认地图

    /// 只留字母数字；像 I 的（! | l 1）都当 i，免得 “Tunnel II” 认成 “Tunnel !!” 对不上
    static func norm(_ s: String) -> [Character] {
        s.lowercased().compactMap { c in
            if "!|l1".contains(c) { return "i" }
            return c.isLetter || c.isNumber ? c : nil
        }
    }
    /// 末尾的编号（II、III、<Area 2>…）。差一个字就是另一张图，必须一模一样，不能容错
    static func roman(_ s: String) -> String {
        guard let w = s.split(whereSeparator: { " <>()".contains($0) }).last else { return "" }
        let t = String(norm(String(w)))
        return t.allSatisfy({ "ivx".contains($0) }) || t.allSatisfy(\.isNumber) ? t : ""
    }

    /// lines：小地图标题附近识别到的行。near：上一次在的地图（同名的图取挨着的那张）
    public func locate(_ lines0: [String], near: Int? = nil) -> Int? {
        // 没有小地图（室内）或小地图收起时，标题是一行：“Victoria Road : Perion Weapon Store”
        let lines = lines0.flatMap { l -> [String] in
            let p = l.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            return p.count == 2 && p[0].count >= 4 && p[1].count >= 4 ? p : [l]
        }
        if let id = match(lines, near: near) { return id }
        // 整行对不上：标题右边可能被队伍血条压住，后面连着队友名字（“Kerning City Construction Site Hespers”）或缺了尾巴
        for line in lines {
            let w = line.split(separator: " ").map(String.init)
            guard w.count >= 2 else { continue }
            for k in stride(from: w.count - 1, through: 1, by: -1) {
                let head = w[0..<k].joined(separator: " ")
                guard let id = match(lines.filter { $0 != line } + [head], only: head, near: near) else { continue }
                // 去掉的那个词要是像更长地名的下一个词，说明是长地名认花了，不能当成短的那个
                let hn = Self.norm(maps[id]!.name), rest = Self.norm(w[k...].joined())
                let longer = keys.contains { x in
                    guard x.name.count > hn.count, Array(x.name.prefix(hn.count)) == hn else { return false }
                    let t = Array(x.name.dropFirst(hn.count)), m = min(4, t.count, rest.count)
                    return m > 0 && Fuzzy.distance(Array(t.prefix(m)), Array(rest.prefix(m)), limit: m) <= m / 2
                }
                if longer { break }
                return id
            }
        }
        // 缺了尾巴：够长、而且只有一个地名这样开头
        for line in lines {
            let n = Self.norm(line)
            guard n.count >= 14 else { continue }
            let hit = keys.filter { $0.roman.isEmpty && $0.name.count > n.count && $0.name.count - n.count <= 6 && Array($0.name.prefix(n.count)) == n }
            if Set(hit.map { String($0.name) }).count == 1, hit.count == 1 { return hit[0].id }
        }
        return nil
    }

    /// 同街道、同名的图（“Mushroom Town” 有两张）：标题分不清，要看小地图
    public func twins(_ id: Int) -> [Int] {
        guard let m = maps[id] else { return [] }
        return maps.values.filter { $0.name == m.name && $0.street == m.street }.map(\.id).sorted()
    }

    /// only：只拿这一行当地名（其余的行只用来核对街道名）
    private func match(_ lines: [String], only: String? = nil, near: Int?) -> Int? {
        var best: [Int] = [], bestD = Int.max
        for line in only.map({ [$0] }) ?? lines {
            let n = Self.norm(line), r = Self.roman(line)
            guard n.count >= 4 else { continue }
            for k in keys where k.name.count >= 4 && k.roman == r {
                let allowed = max(0, min(3, k.name.count / 6))
                guard abs(k.name.count - n.count) <= allowed else { continue }
                var d = k.name == n ? 0 : Fuzzy.distance(n, k.name, limit: allowed)
                guard d <= allowed else { continue }
                d *= 10
                // 街道名也对得上的优先
                if !k.street.isEmpty, !lines.contains(where: { Fuzzy.distance(Self.norm($0), k.street, limit: 3) <= 3 }) { d += 5 }
                if d < bestD { bestD = d; best = [k.id] } else if d == bestD, !best.contains(k.id) { best.append(k.id) }
            }
        }
        guard !best.isEmpty else { return nil }
        if best.count == 1 { return best[0] }
        guard Set(best.map { maps[$0]!.name }).count == 1 else { return nil }      // 两张不同名的图一样像：不猜
        if let near {
            if best.contains(near) { return near }
            if let b = best.first(where: { b in maps[near]?.portals.contains { Int($0[0]) == b } == true }) { return b }
        }
        return best.max { maps[$0]!.portals.count + maps[$0]!.npcs.count < maps[$1]!.portals.count + maps[$1]!.npcs.count }
    }

    // MARK: 找路

    func side(_ m: NavMap, _ x: Double, _ y: Double) -> String {
        let w = m.box[2] - m.box[0], h = m.box[3] - m.box[1]
        guard w > 0 else { return "本图" }
        let fx = (x - m.box[0]) / w
        let hs: String
        switch fx { case ..<0.12: hs = "最左边"; case ..<0.4: hs = "左边"; case ..<0.6: hs = "中间"; case ..<0.88: hs = "右边"; default: hs = "最右边" }
        // 矮的图（不到一屏半）不说上下
        guard h > 900 else { return hs }
        let fy = (y - m.box[1]) / h
        return hs + (fy < 0.35 ? "上层" : fy > 0.7 ? "下层" : "中层")
    }

    /// 从 from 走到 npc：没路返回 nil
    public func route(from: Int, npc: Int) -> NavRoute? {
        let goals = npcAt[npc] ?? []
        guard let start = maps[from], !goals.isEmpty else { return nil }
        let here = goals.filter { $0.map == from }
        if let g = here.first {
            var r = NavRoute(steps: ["\(npcName(npc)) 就在这张图：\(side(start, g.x, g.y))"], arrived: true, uncertain: false,
                             next: here.map { NavPoint(x: $0.x, y: $0.y) }, kind: .npc)
            r.goalMap = from; r.goalSide = side(start, g.x, g.y)
            r.npcName = npcName(npc)
            return r
        }
        guard var (r, end) = walk(from: from, goals: Dictionary(goals.map { ($0.map, 0) }, uniquingKeysWith: { a, _ in a })) else { return nil }
        let g = goals.first { $0.map == end }!
        r.goalSide = side(maps[end]!, g.x, g.y)
        r.steps.append("\(npcName(npc)) 在\(r.goalSide)")
        return r
    }

    /// 去有这个怪的最近的图
    public func route(from: Int, mob: String) -> NavRoute? {
        let at = mobAt[mob] ?? []
        guard maps[from] != nil, !at.isEmpty else { return nil }
        if at.contains(where: { $0.map == from }) {
            var r = NavRoute(steps: ["这张图就有 \(mobName(mob))"], arrived: true, uncertain: false, kind: .mob)
            r.goalMap = from
            return r
        }
        // 只有一两只的图（别的图多的话）宁可多走几步
        let many = at.contains { $0.n >= 5 }
        guard var (r, end) = walk(from: from, goals: Dictionary(at.map { ($0.map, many && $0.n < 3 ? 4 : 0) }, uniquingKeysWith: min)) else { return nil }
        r.steps.append("在 \(mapName(end)) 打 \(mobName(mob))")
        return r
    }

    /// 有出租车的城（数据里有 Cab 的那几张）
    private var cabTowns: [Int] {
        let cabs = Set(npcNames.filter { $0.value.hasSuffix("Cab") }.keys)
        return maps.values.filter { m in m.npcs.contains { cabs.contains(Int($0[0])) } }.map(\.id).sorted()
    }
    /// 先坐车 / 用回城卷到哪个城会更近。walk：现在走过去的路线（nil = 走不到）。不划算返回 nil
    public func shortcut(from: Int, npc: Int?, mob: String?, walk: NavRoute?) -> String? {
        guard let here = maps[from], walk?.arrived != true else { return nil }
        let towns = cabTowns
        var best: (town: Int, r: NavRoute, cost: Int)?
        for t in towns where t != from {
            guard let r = npc.flatMap({ route(from: t, npc: $0) }) ?? mob.flatMap({ route(from: t, mob: $0) }), !r.uncertain || walk == nil else { continue }
            let c = r.hops + (here.ret == t || towns.contains(from) ? 1 : 2)
            if best == nil || c < best!.cost { best = (t, r, c) }
        }
        guard let b = best else { return nil }
        // 省下两张图以上才提
        if let w = walk, !w.uncertain, w.hops - b.cost < 2 { return nil }
        let town = mapName(b.town)
        let how: String
        if here.ret == b.town { how = "用回城卷就到「\(town)」" }
        else if towns.contains(from) { how = "坐出租车到「\(town)」" }
        else if towns.contains(here.ret) { how = "用去「\(town)」的回城卷；没有就先回城到「\(mapName(here.ret))」再坐出租车" }
        else { how = "用去「\(town)」的回城卷" }
        return how + (b.r.hops == 0 ? "，就在城里" : "，再走 \(b.r.hops) 张图")
    }

    /// 最短路：一道门算 1，位置未知的门算 6（有正经路就不走它）。goals：目标图 → 附加代价。返回路线和到达的图
    func walk(from: Int, goals: [Int: Int]) -> (NavRoute, Int)? {
        var dist = [from: 0], prev: [Int: (map: Int, portal: [Double])] = [:], done = Set<Int>()
        while let cur = dist.filter({ !done.contains($0.key) }).min(by: { ($0.value, $0.key) < ($1.value, $1.key) }) {
            done.insert(cur.key)
            for p in doors(cur.key) {
                let t = Int(p[0]), d = cur.value + (p[3] < 0 ? 6 : 1)
                if d < dist[t] ?? .max { dist[t] = d; prev[t] = (cur.key, p) }
            }
        }
        guard let goal = goals.filter({ dist[$0.key] != nil }).min(by: { (dist[$0.key]! + $0.value, $0.key) < (dist[$1.key]! + $1.value, $1.key) })?.key else { return nil }
        var hops: [(Int, [Double], Int)] = [], at = goal
        while at != from, let p = prev[at] { hops.append((p.map, p.portal, at)); at = p.map }
        hops.reverse()
        var steps: [String] = [], uncertain = false
        for (m, p, t) in hops {
            let name = mapName(t)
            switch Int(p[3]) {
            case -1: steps.append("在本图找通往「\(name)」的入口（位置没有资料，可能要和 NPC 说话）"); uncertain = true
            case 8:
                let v = rides(m).first { $0.door == p }
                steps.append("找 \(npcName(v?.npc ?? 0)) \(v?.how ?? "")（\(side(maps[m]!, p[1], p[2]))）→ \(name)")
            case 5: steps.append("\(side(maps[m]!, p[1], p[2]))的隐藏门（你走过），站上去按 ↑ → \(name)")
            case 3: steps.append("\(side(maps[m]!, p[1], p[2]))的自动传送点 → \(name)")
            case 1: steps.append("\(side(maps[m]!, p[1], p[2]))的门或洞口，站上去按 ↑ → \(name)")
            default: steps.append("\(side(maps[m]!, p[1], p[2]))的传送门，按 ↑ → \(name)")
            }
        }
        var r = NavRoute(steps: steps, arrived: false, uncertain: uncertain)
        if let h = hops.first, h.1[3] >= 0 {
            r.next = doors(from).filter { Int($0[0]) == h.2 && $0[3] >= 0 }.map { NavPoint(x: $0[1], y: $0[2]) }
            r.kind = h.1[3] == 3 ? .portalAuto : h.1[3] == 8 ? .npc : .portalUp
            if h.1[3] == 8, let v = rides(from).first(where: { $0.door == h.1 }) { r.npcName = npcName(v.npc); r.ride = v.how }
        }
        r.hops = hops.count; r.goalMap = goal
        return (r, goal)
    }
}

extension NavDB {
    /// “Squishy Liquid 49 730”：斜杠认成了 7、1、l 这类竖的字。任务表里要 30 个，就能认出是 “49 / 30”。
    /// 已经有斜杠、名字不是任务要的东西、或有两种拆法都说得通的，原样返回
    public func fixCount(_ s: String) -> String {
        guard !s.contains("/"), let r = s.range(of: "\\s[0-9Oo]+\\s*[71lI|][0-9 ]+$", options: .regularExpression) else { return s }
        let name = s[..<r.lowerBound].trimmingCharacters(in: .whitespaces)
        let tail = s[r].replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "[Oo]", with: "0", options: .regularExpression)
        guard name.filter(\.isLetter).count >= 3 else { return s }
        var hits = Set<String>()
        for q in quests.values { for n in q.mobs + q.items where n.count > 0 && Fuzzy.similar(n.name, name, tolerance: 0.15) {
            let need = String(n.count)
            guard tail.hasSuffix(need), let slash = tail.dropLast(need.count).last, "71lI|".contains(slash) else { continue }
            let have = String(tail.dropLast(need.count + 1))
            if let v = Int(have), String(v) == have { hits.insert("\(v) / \(need)") }
        } }
        // 没有任务表（公开版）：斜杠可能在哪几个位置，拆出来“有几个 ≤ 要几个”、都不以 0 开头的只有一种才算（O730 → 0 / 30）
        if quests.isEmpty {
            let d = Array(tail)
            for i in 1..<max(1, d.count - 1) where "71lI|".contains(d[i]) {
                let have = String(d[..<i]), need = String(d[(i + 1)...])
                guard let a = Int(have), let b = Int(need), String(a) == have, String(b) == need, b > 0, a <= b, b <= 999 else { continue }
                hits.insert("\(a) / \(b)")
            }
        }
        return hits.count == 1 ? "\(name) \(hits.first!)" : s
    }
}
