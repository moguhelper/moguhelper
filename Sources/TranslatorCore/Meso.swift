// 金币：背包窗口底部的金币框（白底、数字右对齐、左边是金币图标、右边写着 MESOS）。
// 只在背包打开时看得到；两次看到的差就是这段时间赚的 / 花的。只用截图识别出的文字。
import CoreGraphics
import Foundation

public enum MesoReader {
    /// 在整窗截图的识别结果里找背包金币数。scale：截图每点多少像素。
    /// 只认“纯数字（带千位逗号）+ 左边一长段白底 + 白底左边有金色金币图标”的，聊天、气泡里的数字不算
    public static func find(lines: [OCRLine], in img: CGImage, scale s: CGFloat) -> Int? { locate(lines: lines, in: img, scale: s)?.value }

    /// 同 find，另外返回金币框的位置（像素，从金币图标到数字右边）。
    /// 人物走动时背包会变半透明，这时数字会稳定认错（18,996 → 16,996），所以白底必须是不透明的（≥ 235）才认
    public static func locate(lines: [OCRLine], in img: CGImage, scale s: CGFloat) -> (value: Int, box: CGRect)? {
        guard let (buf, w, h) = TooltipDetector.rgba(img) else { return nil }
        @inline(__always) func px(_ x: Int, _ y: Int) -> (Int, Int, Int) {
            let i = (min(h - 1, max(0, y)) * w + min(w - 1, max(0, x))) * 4
            return (Int(buf[i]), Int(buf[i + 1]), Int(buf[i + 2]))
        }
        for l in lines {
            let t = l.text.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: ".", with: ",")
            guard t.range(of: "^[0-9]{1,3}(,[0-9]{3})*$", options: .regularExpression) != nil, let v = Int(t.filter(\.isNumber)) else { continue }
            let x0 = Int(l.minX * Double(w)), yMid = Int((l.minY + l.maxY) / 2 * Double(h))
            // 往左走白底，金币框至少有 60 点宽
            var x = x0 - Int(3 * s), white = 0, gap = 0
            while x > 0 {
                let (r, g, b) = px(x, yMid)
                if min(r, g, b) >= 235 { white += 1; gap = 0 } else { gap += 1; if gap > Int(3 * s) { break } }
                x -= 1
            }
            guard CGFloat(white) >= 60 * s else { continue }
            // 白底左边 25 点内有金色（金币图标）
            var coin = false
            for dx in 0..<Int(25 * s) {
                for dy in stride(from: -Int(5 * s), through: Int(5 * s), by: max(1, Int(s))) {
                    let (r, g, b) = px(x - dx, yMid + dy)
                    if r >= 170, g >= 100, g <= 230, b <= 80 { coin = true; break }
                }
                if coin { break }
            }
            guard coin else { continue }
            let right = l.maxX * Double(w)
            let box = CGRect(x: Double(x) - Double(25 * s), y: l.minY * Double(h), width: right - Double(x) + Double(25 * s), height: (l.maxY - l.minY) * Double(h))
            return (v, box)
        }
        return nil
    }
}

/// 金币变化：同一个数连续看到两次才算（防止认错一次就记成一大笔进出）
public struct MesoTracker: Sendable {
    public private(set) var confirmed: Int?
    private var candidate: Int?
    public init() {}

    /// 返回这次确认的变化（正 = 赚，负 = 花）；没变或还没确认返回 nil
    public mutating func feed(_ v: Int) -> Int? {
        guard v != confirmed else { candidate = nil; return nil }
        guard v == candidate else { candidate = v; return nil }
        candidate = nil
        defer { confirmed = v }
        guard let c = confirmed else { return nil }      // 第一次看到：只记下来
        return v - c
    }
}

/// 金币账本：捡钱提示先记着，背包里的真实数字一出来就以它为准校正
/// 背包两次读数之间开过哪些窗口：决定差额算谁的
public enum MesoContext {
    /// at：每种最近一次看到的时间（NPC 商店、个人商店、坐车）。
    /// 上次读数时还开着、之后没再看到的（读数前 4 秒到读数后 2 秒）只在没有别的可能时才算
    public static func pick(_ at: [Date?], since bag: Date?) -> [Bool] {
        guard let bag else { return at.map { _ in false } }
        let near = at.map { $0.map { $0 > bag.addingTimeInterval(-4) } ?? false }
        let sure = at.map { $0.map { $0 > bag.addingTimeInterval(2) } ?? false }
        return sure.contains(true) ? sure : near
    }
}

public struct MesoLedger: Codable, Sendable {
    public struct Pick: Codable, Sendable { public var time: Date; public var amount: Int; public var quest: Bool? = nil }
    /// 上次背包确认的数、时间，以及之后靠捡钱提示记的每一笔
    public private(set) var bag: Int?
    public private(set) var bagTime: Date?
    public private(set) var picks: [Pick] = []
    /// 背包比捡钱提示先看到的钱：几秒内补到的提示从这里抵掉，不重复记
    private var credit = 0
    private var creditTime = Date.distantPast
    public init() {}

    /// 现在应该有多少
    public var expected: Int? { bag.map { $0 + picks.reduce(0) { $0 + $1.amount } } }

    /// 捡钱提示新出现一笔
    public mutating func pick(_ v: Int, at t: Date, store: inout ExpStore) {
        var v = v
        if t.timeIntervalSince(creditTime) <= 5, credit > 0 { let used = min(credit, v); credit -= used; v -= used }
        guard v > 0 else { return }
        // 任务奖励右下角也会冒一条的话：同一笔，不记两次
        if let q = questPending, q.amount == v, t.timeIntervalSince(q.time) <= 6 { questPending = nil; return }
        store.record(.gain(v), at: t)
        picks.append(Pick(time: t, amount: v))
    }

    /// 聊天框写了花掉多少、又正好换了图：交通费。背包已经先对过账的不再记
    public mutating func ride(_ v: Int, at t: Date, store: inout ExpStore) -> Bool {
        guard v > 0, store.travelled(near: t) < v else { return false }
        store.payTravel(v, at: t)
        picks.append(Pick(time: t, amount: -v, quest: true))
        return true
    }
    private var questPending: Pick?
    /// 聊天框里看到的任务奖励
    public mutating func quest(_ v: Int, at t: Date, store: inout ExpStore) {
        guard v > 0 else { return }
        // 右下角已经当捡钱记过：改成任务奖励
        if let i = picks.lastIndex(where: { $0.quest != true && $0.amount == v && abs($0.time.timeIntervalSince(t)) <= 6 }) {
            picks[i].quest = true; store.markQuest(v, at: picks[i].time); return
        }
        // 背包已经先对过账（记在“没认出来”里）：只改类别
        if t.timeIntervalSince(creditTime) <= 8, credit >= v {
            credit -= v
            if store.moveToQuest(v, at: creditTime) { return }
        }
        store.earnQuest(v, at: t)
        picks.append(Pick(time: t, amount: v, quest: true)); questPending = picks.last
    }

    /// shop：上次确认以后开过 NPC 商店：差额是买卖，不摊到打怪里、也不倒扣捡到的。
    /// 背包确认了真实数字（t：截图的时间，之后才记的捡钱留到下次对）。返回校正了多少
    @discardableResult
    public mutating func confirm(_ v: Int, at t: Date, shop: Bool = false, stall: Bool = false, travel: Bool = false, store: inout ExpStore) -> Int {
        let before = picks.filter { $0.time <= t }, later = picks.filter { $0.time > t }
        defer { bag = v; bagTime = t; picks = later }
        guard let b = bag else {
            // 第一次看到：当起点。但捡的不会比身上的还多：多出来的是重复记的，撤回
            var left = max(0, before.reduce(0) { $0 + $1.amount } - v)
            let total = left
            for p in before.reversed() where left > 0 && p.quest != true {
                let x = min(left, p.amount); left -= x
                store.retract(x, at: p.time)
            }
            return left - total
        }
        let picked = before.reduce(0) { $0 + $1.amount }
        let d = v - b - picked
        // 两种店都逛过分不清：当其他，不硬归类
        if [shop, stall, travel].filter({ $0 }).count > 1, d < 0 || (shop && stall), d != 0 { if d > 0 { store.earnOther(d, at: t) } else { store.record(.loss(-d), at: t) }; return d }
        if stall, d != 0 { store.stall(d, at: t); return d }
        if shop, d != 0 {
            if d > 0 { store.sell(d, at: t) } else { store.buy(-d, at: t) }
            return d
        }
        if travel, d < 0 { store.payTravel(-d, at: t); return d }
        let hunts = before.filter { $0.quest != true }, hunted = hunts.reduce(0) { $0 + $1.amount }
        if d > 0 {                                          // 漏记的捡钱、卖东西、任务奖励
            // 多半是这段时间漏认的捡钱：按已记的每一笔的比例摊回去，别堆在打开背包这一分钟。
            // 多出来的比捡的还多得多（卖东西、任务奖励），或隔太久，才记在这一刻
            if let bt = bagTime, t.timeIntervalSince(bt) < 3600, hunted > 0, Double(d) <= Double(hunted) * 2 {
                var left = d
                for (i, p) in hunts.enumerated() {
                    let x = i == hunts.count - 1 ? left : min(left, Int((Double(d) * Double(p.amount) / Double(hunted)).rounded()))
                    if x > 0 { store.record(.gain(x), at: p.time) }
                    left -= x
                }
            } else {
                store.earnOther(d, at: t)
            }
            credit = d; creditTime = t
        } else if d < 0, -d <= hunted {                     // 比记的少：捡钱多记了，从最近的开始撤回
            var left = -d
            for p in hunts.reversed() where left > 0 {
                let x = min(left, p.amount); left -= x
                store.retract(x, at: p.time)
            }
        } else if d < 0 {                                   // 少得比捡的还多：是花掉的
            store.record(.loss(-d), at: t)
        }
        return d
    }
}

/// 捡钱提示 “You have gained mesos (+10)”：画面右下方，新的在最下面，旧的往上推、几秒后消失。
/// 同一列里还有“获得经验”“获得物品”，也会把金币行往上推，所以位移不能只数金币行：
/// 用所有提示行一起找“整列往上移了多少”，移完还对不上位置的才是新的一条。
public struct PickupTracker: Sendable {
    public struct Line: Sendable, Equatable {
        /// 金币数；0 = 其他提示（经验、物品），只用来对位置
        public var value: Int
        public var y: Double
        public var key: String
        /// 原文（经验、物品行用）
        public var text = ""
        public init(value: Int, y: Double, key: String? = nil, text: String = "") { self.value = value; self.y = y; self.key = key ?? "m\(value)"; self.text = text }
    }
    private struct Seen: Sendable { var line: Line; var time: Date }
    private var seen: [Seen] = []
    /// 这一次新出现的提示（经验、物品行也在里面）
    public private(set) var fresh: [Line] = []
    /// 整列都对不上的一次：先存着，下一次还是这样才算（认错一次不会把整列重记一遍）
    private var pending: [Line] = []
    private var pendingTime = Date.distantPast
    private let tol: Double
    private let keep = 6.0
    public init(defaultLineHeight: Double = 13) { tol = defaultLineHeight * 0.35 }

    /// 聊天框里任务给的金币：“You have gained / received mesos (+100)”。括号要齐
    public static func questValue(_ text: String) -> Int? {
        let t = text.lowercased().replacingOccurrences(of: " ", with: "")
        guard let r = t.range(of: "^you(have)?(gained|received)mesos?\\(\\+[0-9,.]+\\)\\.?$", options: .regularExpression) else { return nil }
        return Int(t[r].filter(\.isNumber))
    }
    /// 识别文字里的捡钱数（认不出返回 nil）
    public static func value(_ text: String) -> Int? {
        let t = text.lowercased().replacingOccurrences(of: " ", with: "")
        guard t.contains("meso"), t.contains("ained") || t.contains("gain") else { return nil }
        // 括号要齐：右括号认不出来时常被当成数字 1（“(+19)” → “(+191”），宁可等下一次
        guard let r = t.range(of: "\\(\\+([0-9,.]+)\\)", options: .regularExpression) else { return nil }
        return Int(t[r].filter(\.isNumber))
    }

    /// 只留提示文字的颜色（新提示是纯白、黄），背景全去掉，变成白底黑字。背景花的时候比直接认准很多
    public static func isolate(_ img: CGImage) -> CGImage? {
        guard let (buf, w, h) = TooltipDetector.rgba(img) else { return nil }
        var out = [UInt8](repeating: 255, count: w * h)
        for i in 0..<(w * h) {
            let r = Int(buf[i * 4]), g = Int(buf[i * 4 + 1]), b = Int(buf[i * 4 + 2])
            let white = min(r, g, b) >= 200 && max(r, g, b) - min(r, g, b) <= 15
            if white || (r >= 170 && g >= 170 && b <= 110) { out[i] = 0 }
        }
        guard let p = CGDataProvider(data: Data(out) as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue), provider: p, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    /// 经验、物品行认清楚了没有（物品名要在表里）
    static func clear(_ l: Line) -> Bool {
        guard !l.text.isEmpty else { return false }
        if HuntLog.killExp(l.text) != nil { return true }
        return ItemDB.shared.pickedName(l.text, exact: true) != nil
    }
    /// 两次识别（去背景的、原图的）合并：同一高度只留一条，数字认全的优先
    public static func combine(_ a: [Line], _ b: [Line]) -> [Line] {
        func rank(_ l: Line) -> Int { l.value > 0 ? 3 : clear(l) ? 2 : l.key == "m?" ? 1 : 0 }
        var out = a
        for l in b {
            if let i = out.firstIndex(where: { abs($0.y - l.y) < 5 }) { if rank(l) > rank(out[i]) { out[i] = l } }
            else { out.append(l) }
        }
        return out
    }

    /// 按字形逐像素读（截图要 2 倍原始像素）。新提示是纯色，读得准；变淡的读不到，靠另外两次识别
    public static func glyphs(_ im: CGImage, scale s: Int) -> [GlyphLine] {
        guard let p = MiniMap.Pix(im) else { return [] }
        return Glyphs.shared.read(w: p.w / s, h: p.h / s, size: 12, minLetters: 6) { x, y in
            let c = p.rgb(x * s, y * s)
            return (min(c.0, c.1, c.2) >= 200 && max(c.0, c.1, c.2) - min(c.0, c.1, c.2) <= 15) || (c.0 >= 170 && c.1 >= 170 && c.2 <= 110)
        }
    }
    /// 识别行 → 提示行（不是“获得…”提示返回 nil）
    public static func line(_ text: String, y: Double) -> Line? {
        if let v = value(text) { return Line(value: v, y: y) }
        let t = text.lowercased().filter { $0.isLetter || $0.isNumber }
        // “You received EXP (+23)”“Octopus Leg x1 earned. (Etc)”
        // 金币提示但数字没认清：先占个位置，认清了再记
        if t.contains("meso") { return Line(value: 0, y: y, key: "m?") }
        guard t.contains("gained") || t.contains("earned") || t.range(of: "x[0-9li]{1,4}[ec]a[a-z]{1,4}d", options: .regularExpression) != nil || t.contains("received") || t.contains("bonusexp") || t.contains("forparty") else { return nil }
        return Line(value: 0, y: y, key: (t.contains("exp") ? "e" : "o") + t.filter(\.isNumber), text: text)
    }

    /// 整列往上移了多少（找不到返回 nil）
    private func shift(from old: [Line], to new: [Line]) -> Double? {
        guard let bottom = old.map(\.y).max() else { return nil }
        var best: (score: Int, shift: Double)?
        for o in old { for n in new where n.key == o.key && o.y - n.y >= -tol {
            let d = o.y - n.y
            var score = 0
            for l in new {
                let at = l.y + d
                if old.contains(where: { $0.key == l.key && abs($0.y - at) <= tol }) { score += 3 }
                else if old.contains(where: { abs($0.y - at) <= tol }) { score -= 2 }    // 同一位置换了内容
                else if at < bottom { score -= 1 }                                       // 旧的中间多出一条，不太可能
            }
            // 一样好时取移动最少的（宁可少记，打开背包会补上）
            if best == nil || score > best!.score || (score == best!.score && d < best!.shift) { best = (score, d) }
        } }
        guard let b = best, b.score > 0 else { return nil }
        return b.shift
    }

    /// lines：这一次看到的提示（y 越大越靠下）。返回新捡的几笔
    public mutating func feed(_ lines0: [Line], at now: Date = Date()) -> [Int] {
        let lines = lines0.sorted { $0.y < $1.y }
        let keep = self.keep
        fresh = []
        seen.removeAll { now.timeIntervalSince($0.time) > keep }
        if now.timeIntervalSince(pendingTime) > keep { pending = [] }
        guard !lines.isEmpty else { return [] }
        if seen.isEmpty {
            pending = []
            seen = lines.map { Seen(line: $0, time: now) }
            fresh = lines
            return lines.map(\.value).filter { $0 > 0 }
        }
        if let d = shift(from: seen.map(\.line), to: lines) {
            pending = []
            return merge(lines, d, now)
        }
        // 和上次对不上：和“待定的那次”能对上，才认定整列真的换了
        if !pending.isEmpty, let d = shift(from: pending, to: lines) {
            let first = pending.map(\.value).filter { $0 > 0 }
            fresh = pending
            seen = pending.map { Seen(line: $0, time: now) }
            pending = []
            return first + merge(lines, d, now)
        }
        pending = lines; pendingTime = now
        return []
    }

    private mutating func merge(_ lines: [Line], _ d: Double, _ now: Date) -> [Int] {
        // 没看到的旧行也一起上移留着：偶尔漏认一次，再出现时不会当新的
        for i in seen.indices { seen[i].line.y -= d }
        var out: [Int] = []
        for l in lines {
            if let i = seen.firstIndex(where: { abs($0.line.y - l.y) <= tol }) {
                // 位置对上就是同一条，数字认得不一样也不重记；之前没认清数字的，这次认清了补记
                if seen[i].line.key == "m?", l.value > 0 { out.append(l.value); seen[i].line = l }
                // 物品行第一眼认花了（背景太乱），后面认清了补记一次
                else if seen[i].line.value == 0, seen[i].line.key != "m?", !l.text.isEmpty, !Self.clear(seen[i].line), Self.clear(l) { fresh.append(l); seen[i].line = l }
                seen[i].line.y = l.y; seen[i].time = now
            } else {
                seen.append(Seen(line: l, time: now)); fresh.append(l)
                if l.value > 0 { out.append(l.value) }
            }
        }
        return out
    }
}
