// 公开版的物品名（没有物品表时用；有物品表的自用版不用它）：
// 中文名：Glossary.json 的 "items"，我们自己翻的（不是游戏原文）；
// 英文名单：知识包 ItemNames.json（攻略站目录里的名字和大类，CC BY 4.0），只用来纠正认错、认残的名字。
// 注意：别把这些塞进 ItemDB（很多地方用 ItemDB.shared.items.isEmpty 判断是不是公开版）。
import Foundation

public enum ItemNames {
    static func key(_ s: String) -> String { String(s.lowercased().filter { $0.isLetter || $0.isNumber }) }
    /// 自己翻的中文名：英文 key → 中文
    static let zhTable: [String: String] = {
        // 打包后的 app 里 Bundle.module 找不到会直接崩溃：先找 app 自己的资源（和 Glossary 加载一样）
        guard let u = Bundle.main.url(forResource: "Glossary", withExtension: "json") ?? Bundle.module.url(forResource: "Glossary", withExtension: "json"), let d = try? Data(contentsOf: u),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let m = j["items"] as? [String: String] else { return [:] }
        var out: [String: String] = [:]
        for (k, v) in m { out[key(k)] = v }
        return out
    }()
    /// 英文名单（知识包）
    public static let all: [String] = {
        struct F: Decodable { struct I: Decodable { var en: String }; var items: [I] }
        let u = ProcessInfo.processInfo.environment["CT_ITEMNAMES"].map { URL(fileURLWithPath: $0) } ?? GameData.url("ItemNames") ?? Bundle.main.url(forResource: "ItemNames", withExtension: "json")
        guard let u, let d = try? Data(contentsOf: u), let f = try? JSONDecoder().decode(F.self, from: d) else { return [] }
        return f.items.map(\.en)
    }()
    private static let byKey: [String: String] = { var m: [String: String] = [:]; for n in all { m[key(n)] = m[key(n)] ?? n }; return m }()
    private static let keyed: [(String, [Character])] = all.map { ($0, Array(key($0))) }

    /// 中文名（我们自己翻的）；没有返回 nil，交给系统翻译
    public static func zh(_ en: String) -> String? { zhTable[key(en)] }
    /// 认错一两个字母的 → 名单里的写法。长的名字可以错 2 个，短的 1 个，4 个字母以下不改；两个一样像不猜
    public static func fix(_ s: String) -> String? {
        let k = Array(key(s))
        if let n = byKey[String(k)] { return n }
        let lim = k.count >= 12 ? 2 : k.count >= 6 ? 1 : 0
        guard lim > 0 else { return nil }
        var best: [String] = [], bd = Int.max
        for (n, nk) in keyed where abs(nk.count - k.count) <= lim && nk.filter(\.isNumber) == k.filter(\.isNumber) {
            let d = Fuzzy.distance(k, nk, limit: lim)
            guard d <= lim else { continue }
            if d < bd { bd = d; best = [n] } else if d == bd { best.append(n) }
        }
        return Set(best).count == 1 ? best[0] : nil
    }
    /// 任务目标名：认错的字母按名单改回（Blue Mushroom Caa），图标边缘粘在前面的杂字去掉（SaPig's Ribbon）。对不上原样返回
    public static func clean(_ s: String) -> String {
        if let f = fix(s) { return f }
        let a = Array(s)
        for n in 1...3 where a.count > n + 4 && a[n].isUppercase {
            if let f = byKey[key(String(a[n...]))] { return f }
        }
        // 最后一个词被挡住认花了（Blue Mushroom aza）：前面的词都对、最后一个词一样长，名单里只有一个
        let w = s.split(separator: " ").map(String.init)
        if w.count >= 3, w.dropLast().joined().count >= 8 {
            let head = w.dropLast().map { $0.lowercased() }, n = w.last!.count
            let hits = all.filter { c in let v = c.split(separator: " ").map(String.init); return v.count == w.count && v.dropLast().map { $0.lowercased() } == head && v.last!.count == n }
            if Set(hits).count == 1 { return hits[0] }
        }
        return s
    }
}
