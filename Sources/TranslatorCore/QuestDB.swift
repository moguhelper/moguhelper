// 怀旧服任务原文表（Quests.json）：开发时从公开数据整理好、打包进程序，运行时不联网。
// 作用：用识别出的（可能认错、被截断、只看到一半的）文字找到任务的完整英文原文；
// 表里有人工 / 预先翻好的中文（zh）就直接用，没有就把干净的英文交给系统翻译。
import Foundation

public struct QuestEntry: Codable, Sendable {
    public var id: Int
    public var name: String
    public var area: String
    /// 任务说明原文（编号已换成名字）
    public var en: [String]
    /// 任务名中文（可手改；空就用系统翻译）
    public var zhName: String?
    /// 与 en 一一对应的中文（可手改；空就用系统翻译）
    public var zh: [String]?
}

public final class QuestDB: @unchecked Sendable {
    public let entries: [QuestEntry]
    private let nameKeys: [String]                       // 归一化的任务名
    private let msgWords: [(q: Int, m: Int, words: [String], set: Set<String>)]
    /// 每条原文的“4 个字母一组”集合（去掉空格标点）：识别把单词粘在一起（“backits”“getto”）也照样对得上
    private let msgGrams: [Set<String>]
    private let nameNorm: [String]

    public static let shared: QuestDB = {
        // 打包的 app 里放在 Contents/Resources（和 Glossary.json 一样）；测试程序用 SwiftPM 的资源包
        if let url = GameData.url("Quests") ?? Bundle.main.url(forResource: "Quests", withExtension: "json") ?? Bundle.module.url(forResource: "Quests", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let list = try? JSONDecoder().decode([QuestEntry].self, from: data) {
            return QuestDB(list)
        }
        return QuestDB([])
    }()

    public init(_ list: [QuestEntry]) {
        entries = list
        nameKeys = list.map { Self.norm($0.name) }
        var mw: [(Int, Int, [String], Set<String>)] = []
        for (qi, q) in list.enumerated() {
            for (mi, m) in q.en.enumerated() {
                let w = Self.words(m)
                mw.append((qi, mi, w, Set(w)))
            }
        }
        msgWords = mw
        msgGrams = mw.map { Self.grams(list[$0.0].en[$0.1]) }
        nameNorm = list.map { Self.letters($0.name) }
    }

    static func letters(_ s: String) -> String {
        String(s.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }
    static func gramList(_ s: String) -> [String] {
        let c = Array(letters(s))
        guard c.count >= 4 else { return [] }
        return (0...(c.count - 4)).map { String(c[$0..<$0 + 4]) }
    }
    static func grams(_ s: String) -> Set<String> { Set(gramList(s)) }

    /// 短行是不是某个任务名（小标题）：完全一样，或认错一两个字（“chainbow snail…”）且只像一个任务名
    public func name(_ id: Int) -> String? { entries.first { $0.id == id }?.name }
    public func entry(forHeading text: String) -> QuestEntry? {
        if let e = entry(forTitle: text, allowTruncated: false) { return e }
        let k = Self.letters(text)
        guard k.count >= 6 else { return nil }
        let hits = nameNorm.indices.filter { Fuzzy.similar(nameNorm[$0], k, tolerance: 0.2) }
        return Set(hits.map { nameNorm[$0] }).count == 1 ? entries[hits[0]] : nil
    }

    /// 小写、只留字母数字，按空白切词
    static func words(_ s: String) -> [String] {
        let lowered = s.lowercased().replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: "'s\\b", with: "", options: .regularExpression)
        return lowered.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
    }
    static func norm(_ s: String) -> String { words(s).joined(separator: " ") }

    /// 任务名（可能末尾被截断成 “...”）：完全一样的优先；截断的用前缀找，唯一才算
    public func entry(forTitle title: String, allowTruncated: Bool = true) -> QuestEntry? {
        let c = candidates(forTitle: title, allowTruncated: allowTruncated)
        return c.count == 1 ? c[0] : nil
    }

    /// 截断的标题可能对上几个任务（“Chrishrama in Need of...”）：全部返回，由正文来定
    public func candidates(forTitle title: String, allowTruncated: Bool = true) -> [QuestEntry] {
        var t = title.trimmingCharacters(in: .whitespaces)
        var truncated = false
        while t.hasSuffix(".") || t.hasSuffix("…") { t.removeLast(); truncated = true }
        let key = Self.norm(t)
        guard key.count >= 3 else { return [] }
        if let i = nameKeys.firstIndex(of: key) { return [entries[i]] }
        // 系列任务的标题末尾没有编号（“Rain's Maple Quiz” 1～7）：全部算候选
        if allowTruncated, key.count >= 8, case let n = nameKeys.indices.filter({ nameKeys[$0].hasPrefix(key + " ") && Int(nameKeys[$0].dropFirst(key.count + 1)) != nil }), n.count > 1 { return n.map { entries[$0] } }
        guard truncated, allowTruncated else { return [] }
        // 截断处最后一个词多半只剩半个：前缀匹配就能包含这种情况
        var seen = Set<String>(), out: [QuestEntry] = []
        for i in nameKeys.indices where nameKeys[i].hasPrefix(key) && seen.insert(nameKeys[i]).inserted { out.append(entries[i]) }
        return out
    }

    /// 一段识别出的说明文字对应哪条原文。识别文字可能只是原文的一部分（滚动只看到一截）、有个别字认错。
    /// 打分：识别出的词有多少出现在原文里（按词序贪心对齐），需要 ≥ 75% 且至少 5 个词。
    /// 一段文字的词有多少出现在这些任务的原文里（0~1）。滚动拼接时认花的重复片段，大部分词都在已对上的原文里。
    public func overlap(_ text: String, with es: [QuestEntry]) -> Double {
        let w = Self.words(text)
        guard !w.isEmpty else { return 0 }
        let ids = Set(es.map(\.id))
        var all = Set<String>()
        for c in msgWords where ids.contains(entries[c.q].id) { all.formUnion(c.set) }
        return Double(w.filter { all.contains($0) }.count) / Double(w.count)
    }

    /// prefer：标题认出的任务编号；分数一样时优先这个任务。
    /// 多个任务都有的套话（“Only characters at Level 10 or higher…”）对上好几条又分不出高下：不算命中。
    public func message(for text: String, prefer: Int? = nil) -> (entry: QuestEntry, index: Int)? {
        let w = Self.words(text)
        guard w.count >= 5 else { return nil }
        var cands: [(score: Double, q: Int, m: Int)] = []
        for c in msgWords {
            // 先粗筛：词集合重合不够就跳过
            let common = w.reduce(0) { $0 + (c.set.contains($1) ? 1 : 0) }
            guard Double(common) / Double(w.count) >= 0.6 else { continue }
            // 再按顺序对齐（识别文字应是原文里连续的一段）
            var j = 0, hit = 0
            for x in w {
                var k = j
                while k < c.words.count, k < j + 4, c.words[k] != x { k += 1 }
                if k < c.words.count, c.words[k] == x { hit += 1; j = k + 1 }
                else if j == 0, let f = c.words.firstIndex(of: x) { hit += 1; j = f + 1 }
            }
            let score = Double(hit) / Double(w.count)
            if score >= 0.75 { cands.append((score, c.q, c.m)) }
        }
        // 单词被粘连 / 拆开时按词对不上：改按字母 4-gram 覆盖率再算一遍（识别出的 4-gram 有多少出现在原文里）
        let g = Self.gramList(text)
        if g.count >= 12 {
            for (k, c) in msgWords.enumerated() {
                let hit = g.reduce(0) { $0 + (msgGrams[k].contains($1) ? 1 : 0) }
                let score = Double(hit) / Double(g.count)
                guard score >= 0.8 else { continue }
                if let i = cands.firstIndex(where: { $0.q == c.q && $0.m == c.m }) { cands[i].score = max(cands[i].score, score) }
                else { cands.append((score, c.q, c.m)) }
            }
        }
        guard let top = cands.map(\.score).max() else { return nil }
        let near = cands.filter { $0.score >= top - 0.05 }
        if let p = prefer, let c = near.first(where: { entries[$0.q].id == p }) { return (entries[c.q], c.m) }
        // 分不出高下的几条原文完全一样（同一句话出现在几个任务里）也行；不一样就放弃
        let texts = Set(near.map { entries[$0.q].en[$0.m] })
        guard texts.count == 1, let b = near.max(by: { $0.score < $1.score }) else { return nil }
        return (entries[b.q], b.m)
    }
}
