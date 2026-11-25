// 怀旧服物品表（Items.json，tools/items 生成）：物品英文名 / 说明原文 → 中文。运行时不联网。
// 说明框标题认错一两个字母也能对上；说明文字对上原文后用表里的中文，没有中文就把干净的英文交给系统翻译。
import Foundation

public struct ItemDesc: Codable, Sendable {
    public var en: [String]     // 一行一句
    public var zh: [String]     // 与 en 一一对应，"" = 没有现成中文（国服整段说明只有一行）
}

public struct ItemEntry: Codable, Sendable {
    public var en: String
    public var zh: String
    public var desc: [ItemDesc]?
    /// 分类：Equip、Use、Etc、Setup、Cash（同名的可能有几类）
    public var cat: [String]? = nil
}

public final class ItemDB: @unchecked Sendable {
    public let items: [ItemEntry]
    private let keys: [[Character]]
    private let byKey: [String: Int]
    private let byLength: [Int: [Int]]

    public static let shared: ItemDB = {
        struct File: Codable { var items: [ItemEntry] }
        if let url = GameData.url("Items") ?? Bundle.main.url(forResource: "Items", withExtension: "json") ?? Bundle.module.url(forResource: "Items", withExtension: "json"),
           let data = try? Data(contentsOf: url), let f = try? JSONDecoder().decode(File.self, from: data) { return ItemDB(f.items) }
        return ItemDB([])
    }()

    init(_ list: [ItemEntry]) {
        items = list
        keys = list.map { Array(Self.key($0.en)) }
        var b: [String: Int] = [:], l: [Int: [Int]] = [:]
        for (i, k) in keys.enumerated() {
            if b[String(k)] == nil { b[String(k)] = i }
            l[k.count, default: []].append(i)
        }
        byKey = b; byLength = l
    }

    static func key(_ s: String) -> String {
        String(s.folding(options: .diacriticInsensitive, locale: nil).lowercased().filter { $0.isLetter || $0.isNumber || $0 == "%" })
    }

    /// 完全一样（不管大小写、空格、标点）才算
    public func exact(_ name: String) -> ItemEntry? { byKey[Self.key(name)].map { items[$0] } }

    /// 说明框标题：允许认错一两个字母（数字必须一样）；两个不同的物品一样接近就不猜
    public func find(_ name: String) -> ItemEntry? {
        if let e = exact(name) { return e }
        let k = Array(Self.key(name))
        let lim = k.count >= 12 ? 2 : (k.count >= 6 ? 1 : 0)
        guard lim > 0 else { return nil }
        let digits = k.filter(\.isNumber)
        var best: (Int, Int)? = nil, tie = false
        for n in (k.count - lim)...(k.count + lim) {
            for i in byLength[n] ?? [] where keys[i].filter(\.isNumber) == digits {
                let d = Fuzzy.distance(k, keys[i], limit: lim)
                guard d <= lim else { continue }
                if best == nil || d < best!.1 { best = (i, d); tie = false }
                else if d == best!.1, items[i].zh != items[best!.0].zh { tie = true }
            }
        }
        guard let b = best, !tie else { return nil }
        return items[b.0]
    }

    /// 标题 → 中文（“(M)”“(F)” 写成男、女）。找不到返回 nil
    public func title(_ raw: String) -> (entry: ItemEntry, zh: String)? {
        if let e = exact(raw) { return (e, e.zh) }
        // 先去掉男女标记再找，否则标记会被当成“认错的一个字母”吃掉
        if let r = raw.range(of: "\\s*[(\\[（]([MF])[)\\]）Il1|]?$", options: .regularExpression), let e = find(String(raw[..<r.lowerBound])) {
            return (e, e.zh + (raw[r].contains("M") ? "（男）" : "（女）"))
        }
        return find(raw).map { ($0, $0.zh) }
    }

    /// 捡东西提示里的名字。太长的会截成 “Green Mushroo...”：按前半截找，只对得上一种才算
    public func pickup(_ raw: String, cat: String? = nil) -> ItemEntry? {
        guard let r = raw.range(of: "\\s*(\\.{2,}|…)\\s*$", options: .regularExpression) else { return title(raw)?.entry }
        let h = raw[..<r.lowerBound].lowercased().filter { $0.isLetter || $0.isNumber }
        guard h.count >= 6 else { return nil }
        let hits = items.filter { $0.en.count > h.count && $0.en.lowercased().filter { $0.isLetter || $0.isNumber }.hasPrefix(h) }
            .filter { i in cat == nil || i.cat == nil || i.cat!.contains { $0.caseInsensitiveCompare(cat!) == .orderedSame } }
        // 名字越短越可能（后面还有别的字的是另一样东西），但要比第二名短不少才敢认
        let names = Set(hits.map(\.en)).sorted { $0.count < $1.count }
        guard let f = names.first, names.count == 1 else { return nil }
        return hits.first { $0.en == f }
    }

    static func numbers(_ s: String) -> [String] {
        var out: [String] = [], cur = ""
        for c in s + " " {
            if c.isASCII, c.isNumber { cur.append(c) } else if c == ",", !cur.isEmpty { continue } else if !cur.isEmpty { out.append(cur); cur = "" }
        }
        return out
    }

    /// 识别出的说明文字是不是这件物品的说明。数字以屏幕上的为准（游戏改过数值时照屏幕写）；数字个数对不上就不用表里的
    public func desc(_ e: ItemEntry, ocr: String) -> ItemDesc? {
        let got = QuestDB.grams(String(ocr.filter { !$0.isNumber }))
        guard got.count >= 4 else { return nil }
        var best: (ItemDesc, Double)? = nil
        for d in e.desc ?? [] {
            let want = QuestDB.grams(String(d.en.joined(separator: " ").filter { !$0.isNumber }))
            guard !want.isEmpty else { continue }
            let s = Double(got.intersection(want).count) / Double(max(got.count, want.count))
            if s >= 0.55, s > (best?.1 ?? 0) { best = (d, s) }
        }
        guard var d = best?.0 else { return nil }
        let on = Self.numbers(ocr), en = Self.numbers(d.en.joined(separator: " "))
        if on == en { return d }
        guard on.count == en.count else { return nil }
        // 只换变了的数字；同一个数字出现多次、或换不准时放弃
        for (o, n) in zip(on, en) where o != n {
            guard en.filter({ $0 == n }).count == 1 else { return nil }
            let pat = "(?<![0-9,])" + n.map(String.init).joined(separator: ",?") + "(?![0-9,]*[0-9])"
            d.en = d.en.map { $0.replacingOccurrences(of: pat, with: o, options: .regularExpression) }
            d.zh = d.zh.map { $0.replacingOccurrences(of: pat, with: o, options: .regularExpression) }
        }
        return d
    }
}

extension ChatTranslator {
    /// 物品说明的中文（一行一句）
    func itemDescZh(_ d: ItemDesc) async -> String {
        if d.zh.count != d.en.count { return d.zh.joined(separator: "\n") }
        var out: [String] = []
        for (e, z) in zip(d.en, d.zh) { out.append(z.isEmpty ? await plain(e) : z) }
        return out.joined(separator: "\n")
    }
}

extension ItemDB {
    /// 屏幕上的物品名（说明框标题、商店一行）。有物品表：要在表里。没有（公开版）：像个名字就用，去掉强化的 (+3)
    public func screenName(_ raw: String) -> String? {
        if !items.isEmpty { return title(raw)?.entry.en }
        return Self.plainName(raw)
    }
    static func plainName(_ raw: String) -> String? {
        let t = raw.replacingOccurrences(of: "\\s*\\(\\+\\s*[0-9]+\\)\\s*$", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\s{2,}", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        guard t.range(of: "^[A-Z0-9][A-Za-z0-9'’.,():%+& -]{2,39}$", options: .regularExpression) != nil, t.filter(\.isLetter).count >= 3 else { return nil }
        return t
    }
    /// 捡到提示里的名字对上取过图标的名字：一样的；太长被截断的（Orange Mushro...）按开头；认错一个字母的（数字要一样）。像好几个的不猜
    public static func same(_ name: String, in known: [String]) -> String? {
        if known.contains(name) { return name }
        var t = name
        while t.hasSuffix(".") || t.hasSuffix("…") { t.removeLast() }
        let hit: [String]
        if t != name {
            guard t.count >= 6 else { return nil }
            hit = known.filter { $0.lowercased().hasPrefix(t.lowercased()) }
        } else {
            let k = Array(key(name)), d = k.filter(\.isNumber)
            guard k.count >= 7 else { return nil }
            hit = known.filter { let o = Array(key($0)); return abs(o.count - k.count) <= 1 && o.filter(\.isNumber) == d && Fuzzy.distance(k, o, limit: 1) <= 1 }
        }
        return hit.count == 1 ? hit[0] : nil
    }
    /// 没有物品表（公开版）：两个名字是不是同一样东西、其中一个认错了（Blue Ove / Blue Dye）。返回拼对的那个；看不出来返回 nil
    public static func better(_ a: String, _ b: String) -> String? {
        let x = Array(key(a)), y = Array(key(b))
        guard a != b, min(x.count, y.count) >= 6, x.filter(\.isNumber) == y.filter(\.isNumber), Fuzzy.distance(x, y, limit: 2) <= 2 else { return nil }
        func bad(_ s: String) -> Int { s.lowercased().split(whereSeparator: { !$0.isLetter && $0 != "'" }).filter { $0.count >= 2 && !SpellCheck.isCorrect(String($0)) }.count }
        let p = bad(a), q = bad(b)
        return p < q ? a : q < p ? b : nil
    }
    static func closeColor(_ a: [Int], _ b: [Int]) -> Bool { a.count != 3 || b.count != 3 ? a.count == b.count : zip(a, b).allSatisfy { abs($0 - $1) <= 8 } }
    /// 认错的名字 → 已有的、图标颜色也一样的正确名字；反过来，这个才是对的：哪些旧的要扔掉
    public static func dedupe(_ name: String, color: [Int], among: [String: [Int]]) -> (use: String, drop: [String]) {
        let twins = among.filter { closeColor($0.value, color) }.keys.compactMap { o in better(name, o).map { (o, $0) } }
        if let t = twins.first(where: { $0.1 != name }) { return (t.0, []) }
        return (name, twins.map(\.0))
    }
    /// 认得可能差一点的名字 → 以前见过的写法（Orange Mushron、Arrows for Cros..）
    public static func seenName(_ name: String, in known: [String]) -> String? {
        if known.contains(name) { return name }
        func bare(_ s: String) -> String { var t = s; while let c = t.last, c == "." || c == "…" || c == " " { t.removeLast() }; return t }
        let cut = known.filter { bare($0) != $0 }, t = bare(name)
        // 截断的写法优先（捡东西的提示里长名字都是截断的）
        if let k = cut.first(where: { bare($0) == t }) { return k }
        if let k = same(name, in: known.filter { !cut.contains($0) }) { return k }
        guard let k = same(t, in: cut.map(bare)) else { return nil }
        return cut.first { bare($0) == k }
    }
    /// 认花的捡东西提示（Fragment of Ma.. X Hearned. (Etc)、Octopus Leg Wil earned）：“earned” 前面去掉一两截，能对上见过的名字就算。数量读不出当 1
    public static func looseEarned(_ text: String, known: [String]) -> (name: String, n: Int)? {
        guard !text.contains(" : "), let e = text.range(of: "\\s[a-zA-Z0-9]{0,2}[ecg]a[a-z]{1,4}[dct]\\b", options: .regularExpression) else { return nil }
        let w = text[..<e.lowerBound].split(separator: " ").map(String.init)
        for drop in 0...2 where w.count > drop {
            let tail = w.suffix(drop)
            guard tail.allSatisfy({ $0.count <= 4 }) else { break }
            let t = w.dropLast(drop).joined(separator: " ")
            guard t.filter(\.isLetter).count >= 7, let k = seenName(t, in: known) ?? cutName(t, in: known) else { continue }
            let d = tail.first(where: { $0.range(of: "^[xX×]?[0-9]{1,4}$", options: .regularExpression) != nil })?.filter(\.isNumber)
            return (k, max(1, d.flatMap { Int($0) } ?? 1))
        }
        return nil
    }
    /// 截断的名字又认错一个字母（Fragment or Ma...）：和全名的开头比
    static func cutName(_ t: String, in known: [String]) -> String? {
        let k = Array(key(t))
        guard k.count >= 10 else { return nil }
        let hit = known.filter { let o = Array(key($0)); return o.count > k.count && o.filter(\.isNumber) == k.filter(\.isNumber) && Fuzzy.distance(k, Array(o.prefix(k.count)), limit: 1) <= 1 }
        return hit.count == 1 ? hit[0] : nil
    }
    /// 没见过的名字，普通识别读到的写法：每个词都拼得对才用（Milk Jug）。比较用的键不分大小写、空格
    public static func spelled(_ text: String) -> (key: String, name: String, n: Int)? {
        guard let i = HuntLog.item(text), HuntLog.category(text) != nil, !i.name.contains("."), let n = plainName(i.name), n.filter(\.isNumber).isEmpty else { return nil }
        let ok = n.lowercased().split(whereSeparator: { !$0.isLetter && $0 != "'" }).allSatisfy { $0.count >= 2 && SpellCheck.isCorrect(String($0)) }
        return (key(n), ok ? n : "", i.n)
    }
    /// 捡到的东西叫什么。有物品表：要在表里。没有物品表（公开版）：只认按字形逐像素读到的（exact），认花的不要
    public func pickedName(_ text: String, exact: Bool, known: [String] = []) -> (name: String, n: Int)? {
        guard let i = HuntLog.item(text) else { return nil }
        if !items.isEmpty { return pickup(i.name, cat: HuntLog.category(text)).map { ($0.en, i.n) } }
        // 普通识别读到的：以前见过这个名字才算，用见过的写法
        if !exact { return Self.seenName(i.name, in: known).map { ($0, i.n) } }
        guard HuntLog.category(text) != nil, i.name.range(of: "^[A-Z0-9][A-Za-z0-9'’.,():%+& -]{2,39}$", options: .regularExpression) != nil else { return nil }
        return (i.name, i.n)
    }
}
