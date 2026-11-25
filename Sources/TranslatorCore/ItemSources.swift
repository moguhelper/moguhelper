// 少数任务材料从哪来（ItemSources.json）：怪、要找的 NPC、一句说明。
import Foundation

public struct ItemSource: Decodable, Sendable, Equatable {
    public var mobs: [String], npcs: [Int], note: String, src: String
    /// 只有这几张图才算（空 = 哪里都行）
    public var maps: [Int]
}
public enum ItemSources {
    private struct File: Decodable { var items: [String: ItemSource] }
    public static let all: [String: ItemSource] = {
        let u = GameData.url("ItemSources") ?? Bundle.main.url(forResource: "ItemSources", withExtension: "json") ?? Bundle.module.url(forResource: "ItemSources", withExtension: "json")
        return u.flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSONDecoder().decode(File.self, from: $0) }?.items ?? [:]
    }()
}
/// 任务东西怎么弄到（QuestTips.json，自己写的，公开版也带）
public struct QuestTip: Decodable, Sendable { public var tip: String, npc: String?, mobs: [String]? }
/// 组队任务一关的思路（自己的话）。pick：要试的组合（从 of 里挑 n 个）
public struct StageGuide: Decodable, Sendable, Equatable {
    public struct Pick: Decodable, Sendable, Equatable { public var of: [String], n: Int, note: String? }
    public var map: String, title: String, lines: [String], pick: Pick?
    /// 全部组合，从小到大
    public var combos: [String] {
        guard let p = pick, p.n > 0, p.n <= p.of.count else { return [] }
        func go(_ from: Int, _ k: Int) -> [[String]] {
            if k == 0 { return [[]] }
            guard from <= p.of.count - k else { return [] }
            return (from...(p.of.count - k)).flatMap { i in go(i + 1, k - 1).map { [p.of[i]] + $0 } }
        }
        return go(0, p.n).map { $0.joined() }
    }
}
public enum QuestTips {
    private struct File: Decodable { var items: [String: QuestTip], quests: [String: String]?, quiz: [Quiz]?, rides: [Ride]?, guides: [StageGuide]?; var drops: [String: [String]]?; var notes: [Note]?; var spots: [String: [String]]?; var from: [String: String]?; var mobs: [String: String]?; var ways: [String: [String]]?; var hidden: [String]? }
    struct Note: Decodable { var keys: [String], title: String?, npc: String?, town: String?, from: String?, need: [String], text: String, parts: [String: String]? }
    /// 自己玩的经验：这样东西在哪张图捡到过
    public static func places(_ item: String) -> [String] { file?.drops?[item] ?? [] }
    /// 自己玩的经验：这个任务怎么做。任务名里有这个词，或要的东西全对上
    public static func note(text: String, items: [String]) -> String? { match(text, items)?.text }
    /// 这样东西、这种怪去哪：攻略里的在前，再是自己记录里捡到过的
    public static func spots(_ item: String) -> [String] {
        let a = file?.spots?[item] ?? []
        return a + places(item).filter { !a.contains($0) }
    }
    /// 这样东西打谁掉；是怪就是它自己
    public static func mob(_ n: String) -> String? { file?.mobs?[n] != nil ? n : file?.from?[n] }
    /// 这一步的经验：start 接、end 交，其余是怪名、东西名
    public static func part(_ k: String, text: String, items: [String]) -> String? { match(text, items)?.parts?[k] }
    /// 去这张图一路经过哪些图（公开攻略对照过的）
    public static func way(_ place: String) -> [String] { file?.ways?[place] ?? [] }
    /// 进这张图的门是隐藏门
    public static func hiddenDoor(_ place: String) -> Bool { file?.hidden?.contains(place) ?? false }
    /// 这种怪掉的（经验里写过的）
    public static func drops(of m: String) -> [String] { (file?.from ?? [:]).filter { $0.value == m }.keys.sorted() }
    public static func mobZh(_ n: String) -> String? { file?.mobs?[n] }
    public static func title(text: String, items: [String]) -> String? { match(text, items)?.title }
    /// 交任务的 NPC 在哪
    public static func town(text: String, items: [String]) -> String? { match(text, items)?.town }
    /// 找谁接、在哪：Nella（Kerning City）
    public static func from(text: String, items: [String]) -> String? {
        match(text, items).flatMap { n in n.from ?? n.npc.map { $0 + (n.town.map { "（\($0)）" } ?? "") } }
    }
    /// 这个任务交给谁
    public static func npc(text: String, items: [String]) -> String? { match(text, items)?.npc }
    private static func match(_ text: String, _ items: [String]) -> Note? {
        let l = file?.notes ?? []
        if let n = l.first(where: { $0.keys.contains { text.localizedCaseInsensitiveContains($0) } }) { return n }
        return l.first { !$0.need.isEmpty && $0.need.count >= 2 && $0.need.allSatisfy(items.contains) }
    }
    /// 这张图（组队任务的一关）怎么过
    public static func guide(map: String) -> StageGuide? { file?.guides?.first { $0.map == map } }
    /// 找 NPC 坐船、传送（单向；回程另写一条）
    struct Ride: Decodable { var from: String, npc: String, to: String, how: String }
    static var rides: [Ride] { file?.rides ?? [] }
    struct Quiz: Decodable { var npc: String, ids: [Int], keys: [String: [String]], answers: [Answer]? }
    struct Answer: Decodable { var ask: [String], pick: String }
    /// 核实过的答案：题目里的词都有、选项里只有一项对得上才给（按文字认，选项打乱也对）
    public static func answer(body: String, options: [String]) -> Int? {
        func n(_ s: String) -> String { s.lowercased().filter { $0.isLetter || $0.isNumber } }
        let b = n(body)
        for a in (file?.quiz ?? []).flatMap({ $0.answers ?? [] }) where a.ask.allSatisfy({ b.contains(n($0)) }) {
            let hit = options.indices.filter { n(options[$0]).contains(n(a.pick)) }
            if hit.count == 1 { return hit[0] }
            let near = options.indices.filter { Fuzzy.similar(options[$0], a.pick, tolerance: 0.2) }
            if hit.isEmpty, near.count == 1 { return near[0] }
        }
        return nil
    }
    /// 出题的 NPC（名字允许认错一个字母）。是就返回这一题的要点；对不上是哪题时给全部
    public static func quiz(npc: [String], body: String) -> [String]? {
        guard let q = file?.quiz?.first(where: { z in npc.contains { $0.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(z.npc) == .orderedSame || Fuzzy.similar($0, z.npc, tolerance: 0.2) } }) else { return nil }
        // 没写要点的 NPC：平时也有菜单，只有问到认得的题才算考题
        if q.ids.isEmpty {
            let k = body.lowercased().filter { $0.isLetter || $0.isNumber }
            return (q.answers ?? []).contains { $0.ask.allSatisfy { k.contains($0.lowercased().filter { $0.isLetter || $0.isNumber }) } } ? [] : nil
        }
        let b = body.lowercased()
        func hits(_ id: Int) -> Int { (q.keys[String(id)] ?? []).filter { k in b.range(of: "\\b" + NSRegularExpression.escapedPattern(for: k) + "\\b", options: .regularExpression) != nil }.count }
        let best = q.ids.map(hits).max() ?? 0
        return (best > 0 ? q.ids.filter { hits($0) == best } : q.ids).compactMap(quest)
    }
    private static let file: File? = {
        let u = Bundle.main.url(forResource: "QuestTips", withExtension: "json") ?? Bundle.module.url(forResource: "QuestTips", withExtension: "json")
        return u.flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSONDecoder().decode(File.self, from: $0) }
    }()
    public static let all: [String: QuestTip] = file?.items ?? [:]
    /// 这个任务的要点（自己的话）
    public static func quest(_ id: Int) -> String? { file?.quests?[String(id)] }
    private static let keys = all.keys.sorted().map { ($0, Fuzzy.normalize($0)) }
    /// 名字允许认错一两个字母（短名字不许）
    public static func find(_ item: String) -> QuestTip? {
        if let t = all[item] { return t }
        let k = Fuzzy.normalize(item)
        guard k.count >= 5 else { return nil }
        if let h = keys.first(where: { $0.1 == k }) { return all[h.0] }
        let lim = k.count >= 10 ? 2 : 1
        let hits = keys.filter { $0.1.count >= 5 && Fuzzy.distance($0.1, k, limit: lim) <= lim }
        return hits.count == 1 ? all[hits[0].0] : nil
    }
}
/// 背包里的东西任务要不要
public struct ItemNeed: Sendable, Equatable, Identifiable { public var id: Int, title: String, count: Int }
extension NavDB {
    public var hasQuests: Bool { !allQuests.isEmpty }
    /// 哪些任务要这样东西（done：自己标过做完的不算）
    public func needs(_ item: String, done: Set<Int> = []) -> [ItemNeed] {
        allQuests.compactMap { q in
            guard !done.contains(q.id), let n = q.items.first(where: { $0.name == item }) else { return nil }
            let e = QuestDB.shared.entries.first { $0.id == q.id }
            return ItemNeed(id: q.id, title: e?.zhName ?? e?.name ?? "任务 \(q.id)", count: max(1, n.count))
        }.sorted { $0.id < $1.id }
    }
    func tipRoute(from: Int, item: String) -> NavRoute? {
        guard let t = QuestTips.find(item) else { return nil }
        return ((t.mobs ?? []).compactMap { route(from: from, mob: $0) } + (t.npc.map { npcIds($0) } ?? []).compactMap { route(from: from, npc: $0) }).min { $0.hops < $1.hops }
    }
    /// 走得到的出处里最近的
    public func sourceRoute(from: Int, item: String) -> NavRoute? {
        guard let s = ItemSources.all[item] else { return tipRoute(from: from, item: item) }
        if !s.maps.isEmpty {
            return s.maps.compactMap { to -> NavRoute? in
                guard var r = route(from: from, map: to, item: item), !r.steps.isEmpty else { return nil }
                r.steps[r.steps.count - 1] = "在 \(mapName(to)) 打 " + s.mobs.map { mobName($0) }.joined(separator: "、")
                return r
            }.min { $0.hops < $1.hops }
        }
        return (s.mobs.compactMap { route(from: from, mob: $0) } + s.npcs.compactMap { route(from: from, npc: $0) }).min { $0.hops < $1.hops }
    }
    /// “木妖 Stump、斧木妖 Axe Stump（玩家资料）；说明”
    public func sourceText(_ item: String) -> String? {
        guard let s = ItemSources.all[item] else { return QuestTips.find(item)?.tip }
        let m = s.mobs.isEmpty ? "" : "出自 " + s.mobs.prefix(4).map { mobName($0) }.joined(separator: "、") + (s.mobs.count > 4 ? " 等" : "")
        return [m, s.note].filter { !$0.isEmpty }.joined(separator: "；") + (s.src == "玩家资料" ? "（玩家资料，可能不准）" : "")
    }
}
