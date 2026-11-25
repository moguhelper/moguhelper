// NPC 商店：打开时读每行的名字、价格、图标颜色，药水的名字和单价、捡到东西的卖价就不用手填。
// 左边 = 店里卖多少，右边 = 自己的东西能卖多少。只看画面，不点。
import CoreGraphics
import Foundation

public struct PriceBook: Codable, Sendable, Equatable {
    public struct Item: Codable, Sendable, Equatable {
        /// 图标颜色（和快捷栏、背包同一种算法），没量到为空
        public var color: [Int] = []
        public var buy: Int? = nil, sell: Int? = nil
        public init() {}
    }
    /// 物品英文名（物品表里的写法）→ 价格
    public var items: [String: Item] = [:]
    public init() {}

    public struct Row: Sendable, Equatable { public var name: String, price: Int, color: [Int], mine: Bool, row: Int? = nil }
    private var pending: [Row] = []
    private enum CodingKeys: String, CodingKey { case items }

    /// 连着两次读到一样的才记（鼠标、说明框会挡住）。有变化返回 true
    /// 没有物品表：以前存下的认错的名字合到对的上
    public mutating func clean() {
        for k in items.keys.sorted() {
            guard let i = items[k] else { continue }
            let d = ItemDB.dedupe(k, color: i.color, among: items.mapValues(\.color).filter { $0.key != k })
            if d.use != k {
                var m = items[d.use] ?? Item()
                m.buy = m.buy ?? i.buy; m.sell = m.sell ?? i.sell
                items[d.use] = m; items[k] = nil
            }
        }
    }
    public mutating func feed(_ raw: [Row]) -> Bool {
        var changed = false, rows = raw
        if ItemDB.shared.items.isEmpty {
            let colors = items.mapValues(\.color)
            for i in rows.indices {
                let d = ItemDB.dedupe(rows[i].name, color: rows[i].color, among: colors)
                rows[i].name = d.use
                for o in d.drop { items[o] = nil; changed = true }
            }
        }
        for r in rows where pending.contains(where: { $0.name == r.name && $0.price == r.price && $0.mine == r.mine }) {
            var i = items[r.name] ?? Item()
            if r.mine { i.sell = r.price } else { i.buy = r.price }
            if let p = pending.first(where: { $0.name == r.name && $0.mine == r.mine }), r.color.count == 3, p.color == r.color { i.color = r.color }
            if items[r.name] != i { items[r.name] = i; changed = true }
        }
        pending = rows
        return changed
    }
    /// 图标颜色 → 是什么。两样东西差不多像就不猜
    public func name(color c: [Int]) -> String? {
        guard c.count == 3 else { return nil }
        let d = items.compactMap { k, v in v.color.count == 3 ? (k, zip(v.color, c).map { abs($0 - $1) }.max()!) : nil }.filter { $0.1 <= 10 }.sorted { ($0.1, $0.0) < ($1.1, $1.0) }
        guard let a = d.first else { return nil }
        if d.count > 1, d[1].1 - a.1 < 3 { return nil }
        return a.0
    }
    /// 药水、食物（算药钱）；卷轴、宠物食品、回城卷之类不算
    public static func isPotion(_ name: String) -> Bool {
        if name.range(of: "scroll|pet |return|magic powder|throwing|arrow|buff mega|megaphone", options: [.regularExpression, .caseInsensitive]) != nil { return false }
        if name.range(of: "potion|elixir|pill", options: [.regularExpression, .caseInsensitive]) != nil { return true }
        // 没有物品表（公开版）看不出是不是吃的：放在快捷栏、能用掉的就当药算
        if ItemDB.shared.items.isEmpty { return true }
        let d = (ItemDB.shared.exact(name)?.desc ?? []).flatMap(\.en).joined(separator: " ")
        return d.range(of: "(restore|recover|heal)s?", options: [.regularExpression, .caseInsensitive]) != nil
    }
    /// 一批捡到的东西卖给店大概值多少；不知道卖价的返回在 unknown 里
    public func value(_ drops: [String: Int]) -> (mesos: Int, unknown: Int) {
        var m = 0, u = 0
        for (k, n) in drops { if let s = items[k]?.sell { m += s * n } else { u += 1 } }
        return (m, u)
    }
}

public enum ShopWindow {
    public struct Pane: Sendable, Equatable { public var x: Int, y: Int, w: Int }
    /// 找商店的两条红线（左右两栏页签下面），坐标是像素
    public static func find(_ im: CGImage, scale s: Int, from top: Int = 60) -> (left: Pane, right: Pane)? {
        guard let p = MiniMap.Pix(im) else { return nil }
        for y in stride(from: top * s, to: p.h - 120 * s, by: 1) {
            var runs: [(Int, Int)] = [], r = -1
            // 先粗看一遍，免得每行都细扫
            var rough = 0
            for x in stride(from: 0, to: p.w, by: 16 * s) { let c = p.rgb(x, y); if c.0 > 180, c.1 < 45, c.2 < 60 { rough += 1 } }
            guard rough >= 20 else { continue }
            for x in 0...p.w {
                if x < p.w, case let c = p.rgb(x, y), c.0 > 180, c.1 < 45, c.2 < 60 { if r < 0 { r = x } } else if r >= 0 { if x - r > 190 * s { runs.append((r, x)) }; r = -1 }
            }
            if runs.count == 2, runs[1].0 - runs[0].1 < 12 * s, abs((runs[0].1 - runs[0].0) - (runs[1].1 - runs[1].0)) < 6 * s {
                return (Pane(x: runs[0].0, y: y, w: runs[0].1 - runs[0].0), Pane(x: runs[1].0, y: y, w: runs[1].1 - runs[1].0))
            }
        }
        return nil
    }
    /// im：从左栏红线左端、红线那行开始往右下截的图（2 倍），w：一栏宽（像素）
    public static func rows(_ im: CGImage, scale s: Int, lines: [OCRLine], rightX: Int) -> [PriceBook.Row] {
        guard let p = MiniMap.Pix(im) else { return [] }
        let W = Double(im.width), H = Double(im.height)
        var out: [PriceBook.Row] = []
        for l in lines {
            // “50 Mesos”“500 → 475 Mesos”（打折取后面的）
            guard let r = l.text.range(of: "[0-9][0-9,.]*\\s*[Mm]es", options: .regularExpression), let price = Int(l.text[r].filter(\.isNumber)) else { continue }
            let py = (l.minY + l.maxY) / 2 * H, px = l.minX * W
            let mine = px >= Double(rightX)
            let paneX = Double(mine ? rightX : 0)
            // 第几行：第一行从红线下 12 点开始，每行 40 点；价格在一行的下半截
            let k = ((py / Double(s) - 12) / 40).rounded(.down)
            guard k >= 0, let n = lines.filter({ o in
                let y = (o.minY + o.maxY) / 2 * H
                return py - y > 8 * Double(s) && py - y < 26 * Double(s) && (o.minX * W >= Double(rightX)) == mine && o.minX * W > paneX + 30 * Double(s) && o.text.range(of: "[Mm]esos", options: .regularExpression) == nil
            }).min(by: { abs(py - ($0.minY + $0.maxY) / 2 * H - 18 * Double(s)) < abs(py - ($1.minY + $1.maxY) / 2 * H - 18 * Double(s)) }),
                  let en = ItemDB.shared.screenName(n.text) else { continue }
            let cx = Int(paneX) + 5 * s, cy = (12 + Int(k) * 40) * s
            var sum = [0, 0, 0], c = 0
            for yy in 7..<20 { for xx in 12..<32 {
                let X = cx + xx * s, Y = cy + yy * s
                guard X < p.w, Y < p.h, case let q = p.rgb(X, Y), max(q.0, q.1, q.2) - min(q.0, q.1, q.2) > 45 else { continue }
                sum[0] += q.0; sum[1] += q.1; sum[2] += q.2; c += 1
            } }
            out.append(.init(name: en, price: price, color: c >= 12 ? sum.map { $0 / c } : [], mine: mine, row: Int(k)))
        }
        return out
    }
}

extension PotionLog {
    /// 用价格表给每格填名字、单价；不是药水的不算。手填过的不动
    /// icons：从画面取到的图标的颜色（公开版没有图标资料时用）
    public mutating func apply(_ book: PriceBook, icons: [String: [Int]] = [:]) {
        func grabbed(_ c: [Int]) -> String? {
            guard c.count == 3 else { return nil }
            let d = icons.map { ($0.key, zip($0.value, c).map { abs($0 - $1) }.max()!) }.filter { $0.1 <= 8 }.sorted { ($0.1, $0.0) < ($1.1, $1.0) }
            guard let a = d.first, d.count < 2 || d[1].1 - a.1 >= 2 else { return nil }
            return a.0
        }
        let old = slots
        for i in slots.indices where !slots[i].manual {
            guard let n = book.name(color: slots[i].color) ?? ItemIcons.shared.useName(color: slots[i].color) ?? grabbed(slots[i].color) else { continue }
            slots[i].en = n
            slots[i].name = ItemDB.shared.exact(n)?.zh ?? n
            slots[i].ignored = !PriceBook.isPotion(n)
            // 店里买价（买药时货架开着就顺便读到了）；怪掉的、没见过卖的没花钱，算 0
            slots[i].price = book.items[n]?.buy ?? 0
        }
        if slots != old { recount() }
    }
}

/// 状态栏里的角色名：职业下面那行。要连着看到几次一样的才算换了角色
public struct CharName: Sendable {
    public private(set) var candidate: String?
    private var count = 0
    public init() {}
    /// 状态栏截图（中间 800 点、最下面 50 点）里按字形读名字：Arial 12 号白字，系统识别会把 W 认成 “ v”
    public static func read(_ im: CGImage, scale s: Int) -> String? {
        guard s >= 1, let p = MiniMap.Pix(im) else { return nil }
        // 名字那一块：等级牌右边、HP 左边，职业下面
        let x0 = 80, y0 = 30, w = min(130, p.w / s - x0), h = p.h / s - y0
        guard w > 10, h > 10 else { return nil }
        return Glyphs.shared.read(w: w, h: h, size: 12) { x, y in
            let c = p.rgb((x0 + x) * s, (y0 + y) * s); return min(c.0, c.1, c.2) >= 180
        }.max { $0.score < $1.score }.map(\.text).flatMap { $0.range(of: "^[A-Za-z0-9]{4,12}$", options: .regularExpression) != nil && JobName.match($0) == nil ? $0 : nil }
    }
    /// lines：状态栏识别结果；exact：按字形读到的名字（有就用它）。返回确认的角色名（已经是 current 就返回 nil）
    public mutating func feed(_ lines: [OCRLine], exact: String? = nil, current: String, known: [String]) -> String? {
        // 职业那行也要看到，免得把盖在上面的别的字当名字
        guard lines.contains(where: { $0.minX < 0.4 && ($0.minY + $0.maxY) / 2 < 0.64 && JobName.match($0.text) != nil }),
              let n = exact ?? lines.filter({ $0.minX < 0.4 && ($0.minY + $0.maxY) / 2 >= 0.6 }).map({ $0.text.trimmingCharacters(in: .whitespaces) })
                .first(where: { $0.range(of: "^[A-Za-z0-9]{4,12}$", options: .regularExpression) != nil && JobName.match($0) == nil }) else { return nil }
        func like(_ a: String) -> Bool { Fuzzy.distance(Array(a.lowercased()), Array(n.lowercased()), limit: 2) <= (a.count >= 6 ? 2 : 1) }
        if !current.isEmpty, like(current) { candidate = nil; count = 0; return nil }
        // 以前见过的角色：用见过的写法
        let name = known.first(where: { $0 == n }) ?? known.first(where: like) ?? n
        if candidate == name { count += 1 } else { candidate = name; count = 1 }
        guard count >= 4 else { return nil }
        candidate = nil; count = 0
        return name
    }
}
