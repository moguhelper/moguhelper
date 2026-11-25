// 打怪记录：每张图打了多久、多少经验金币、约多少只、捡到什么；由此推测是哪种怪掉的。只读右下角的提示文字，只存数字和名字。
import Foundation

public struct HuntMap: Codable, Sendable, Equatable {
    /// 有经验或击杀的分钟数
    public var minutes = 0
    public var exp = 0, mesos = 0, kills = 0
    /// 物品英文名 → 捡到几个
    public var drops: [String: Int] = [:]
    /// 药水花的钱（按当时的单价）
    public var potion: Int? = nil
    var lastMinute = -1
    public init() {}
}

public struct HuntLog: Codable, Sendable, Equatable {
    /// 地图 key（街道|地名）→ 记录
    public var maps: [String: HuntMap] = [:]
    public init() {}

    private mutating func active(_ k: String, _ t: Date) {
        let m = Int(t.timeIntervalSince1970 / 60)
        var x = maps[k] ?? HuntMap()
        if x.lastMinute != m { x.lastMinute = m; x.minutes += 1 }
        maps[k] = x
    }
    public mutating func exp(_ n: Int, map k: String, at t: Date) { active(k, t); maps[k, default: HuntMap()].exp += n }
    public mutating func kill(_ n: Int, map k: String, at t: Date) { active(k, t); maps[k, default: HuntMap()].kills += n }
    public mutating func mesos(_ n: Int, map k: String) { maps[k, default: HuntMap()].mesos += n }
    public mutating func potion(_ n: Int, map k: String) { maps[k, default: HuntMap()].potion = (maps[k]?.potion ?? 0) + n }
    public mutating func drop(_ name: String, _ n: Int, map k: String) { maps[k, default: HuntMap()].drops[name, default: 0] += n; if maps[k]!.drops[name]! <= 0 { maps[k]!.drops[name] = nil } }

    /// “Octopus Leg x1 earned. (Etc)” → 名字、几个
    public static func item(_ text: String) -> (name: String, n: Int)? {
        // x1 会认成 xl、al、xI、×1：数量位置上 l I | i 当 1，O o 当 0
        guard let e = text.range(of: "\\s+[ecg]a[a-z]{1,4}[dct]\\b", options: [.regularExpression, .caseInsensitive]) else { return nil }
        let s = text[..<e.lowerBound]
        guard let c = s.range(of: "(\\s+[xX×a%]\\s*[0-9lI|iOot]{1,4}|x[0-9]{1,4})$", options: .regularExpression) else {
            // “x1” 整个认花了（y、at…）：没有数字的一小截当作 1 个，名字对不对由物品表把关
            guard let j = s.range(of: "\\s+[^0-9\\s.]{1,2}$", options: .regularExpression) else { return nil }
            let name = s[..<j.lowerBound].trimmingCharacters(in: .whitespaces)
            return name.count >= 3 ? (name, 1) : nil
        }
        let d = s[c].trimmingCharacters(in: .whitespaces).dropFirst().map { "lI|it".contains($0) ? "1" : "oO".contains($0) ? "0" : String($0) }.joined()
        guard let n = Int(d.filter(\.isNumber)), n > 0 else { return nil }
        let name = s[..<c.lowerBound].trimmingCharacters(in: .whitespaces)
        return name.filter(\.isLetter).count >= 3 ? (name, n) : nil
    }
    /// 聊天框的物品提示：前面的杂点去掉，x1 认成 xt、xl 的改回来。别的话原样
    public static func fixItemLine(_ s: String) -> String {
        guard let r = s.range(of: "\\s([xX×] ?[0-9lI|it]{1,4}|[^0-9\\s.]{2})(?=\\s+(ea[a-z]{1,3}ed|has been [l1I]ost))", options: .regularExpression), !s.contains(" : ") else { return s }
        // 两个字都认花了（ki、KZ）：几个不知道，写 x?
        let body = s[r].dropFirst(2).filter { $0 != " " }
        let n = "xX×".contains(s[r].dropFirst().first!) ? body.map { "lI|it".contains($0) ? "1" : String($0) }.joined() : "?"
        let out = s[..<r.lowerBound] + " x" + n + s[r.upperBound...]
        return String(out).replacingOccurrences(of: "^[^A-Za-z0-9\\[(]+", with: "", options: .regularExpression)
    }
    /// “Maria's Letter x1 has been lost. (Etc)” → 名字、几个（0 = 数量没认出来）
    public static func lost(_ text: String) -> (name: String, n: Int)? {
        let s = fixItemLine(text)
        guard !s.contains(" : "), let r = s.range(of: " x([0-9]{1,4}|\\?)(?=\\s+has been [l1I]ost)", options: .regularExpression) else { return nil }
        let n = Int(s[r].dropFirst(2)) ?? 0
        return (String(s[..<r.lowerBound]), n)
    }
    /// 提示末尾的分类：“(Etc)” → Etc
    public static func category(_ text: String) -> String? {
        let t = text.lowercased()
        guard let r = t.range(of: "\\([a-z-]+[^a-z]*$", options: .regularExpression) else { return nil }
        let w = t[r].filter(\.isLetter)
        return [("etc", "Etc"), ("use", "Use"), ("equip", "Equip"), ("set", "Setup"), ("cash", "Cash")].first { w.hasPrefix($0.0) }?.1 ?? (w.hasPrefix("et") ? "Etc" : nil)
    }
    /// 打死怪的经验提示（组队分的、加成的不算）→ 经验数
    public static func killExp(_ text: String) -> Int? {
        let t = text.lowercased()
        guard t.contains("exp"), !t.contains("bonus"), !t.contains("party"), !t.contains("meso"), t.contains("received") || t.contains("gained") || t.contains("eived"),
              let r = t.range(of: "\\(\\+[0-9,.]+\\)", options: .regularExpression) else { return nil }
        return Int(t[r].filter(\.isNumber))
    }

    /// 推测哪种怪掉：捡到过它的图里共有的怪。一种 = 很可能；几种 = 只能说是其中之一。
    /// mobs：每张图有哪些怪；捡得太少（只有一次）的图不拿来排除
    public func sources(of item: String, mobs: (String) -> [String]) -> [String] {
        let at = maps.filter { ($0.value.drops[item] ?? 0) > 0 }
        let sets = at.sorted { ($0.value.drops[item]!, $1.key) > ($1.value.drops[item]!, $0.key) }.map { Set(mobs($0.key)) }.filter { !$0.isEmpty }
        guard var c = sets.first else { return [] }
        for s in sets.dropFirst() { let i = c.intersection(s); if !i.isEmpty { c = i } }
        return c.sorted()
    }
}

/// 击杀：太大的一笔多半是任务奖励，不算
public struct KillFilter: Sendable {
    private var recent: [Int] = []
    public init() {}
    public mutating func accept(_ v: Int) -> Bool {
        let s = recent.sorted(), mid = s.isEmpty ? v : s[s.count / 2]
        if recent.count >= 8, v > mid * 6 { return false }
        recent.append(v); if recent.count > 40 { recent.removeFirst() }
        return true
    }
}
