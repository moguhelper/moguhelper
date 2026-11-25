// 经验统计：从窗口底部状态栏识别出的 “EXP 28.119[51.22%]” 算出每分钟获得多少经验。
// 只用截图识别出的文字，不读游戏内存。等级不识别（橙色花体数字认不准），升一级要多少经验用 经验 ÷ 百分比 推算。
import Foundation

public struct ExpReading: Sendable, Equatable {
    public var exp: Int
    public var pct: Double
    public init(exp: Int, pct: Double) { self.exp = exp; self.pct = pct }

    /// 升一级需要的经验（推算）
    public var needEstimate: Double? { pct >= 0.5 ? Double(exp) * 100 / pct : nil }

    /// 状态栏识别文字里的经验。识别常把 “[” 认成 “1”、把 “%” 认丢（“28.119151.22%1”“27.079149.3221”），
    /// 所以返回几种可能的拆法，最可信的排在前面；由 ExpTracker 按“经验 ÷ 百分比 ≈ 升级所需”挑
    public static func candidates(_ text: String) -> [ExpReading] {
        guard let r = text.range(of: "EXP", options: .caseInsensitive) else { return [] }
        var s = String(text[r.upperBound...]).replacingOccurrences(of: " ", with: "")
        // 开头的 “.”“:” 等去掉
        // 新号的 “0[0.00%]” 会认成 “oI0.00%1”
        while let f = s.first, !f.isNumber, !"oO".contains(f) { s.removeFirst() }
        if let f = s.first, "oO".contains(f) { s = "0" + s.dropFirst() }
        let chars = Array(s)
        var out: [(ExpReading, Int)] = []        // (读数, 优先级：越小越可信)
        for i in 1..<max(1, chars.count) {
            var expPart = String(chars[..<i])
            var rest = String(chars[i...])
            // 中间的括号：认成非数字（最可信）、认成 “1”（常见）、或者没认出来
            var rank = 2
            if let l = expPart.last, !l.isNumber, l != "." && l != "," { expPart.removeLast(); rank = 0 }
            else if rest.first.map({ !$0.isNumber && $0 != "." && $0 != "," }) == true { rest.removeFirst(); rank = 0 }
            else if expPart.last == "1", expPart.count >= 2 { expPart.removeLast(); rank = 1 }
            guard expPart.range(of: "^[0-9]{1,3}([.,][0-9]{3})*$", options: .regularExpression) != nil else { continue }
            // 中间没有括号的痕迹（rank 2）不要：“46.765185.18%” 会被拆成 经验 4、6.76%
            guard rank < 2 else { continue }
            guard let m = rest.range(of: "^(100|[0-9]{1,2})[.,][0-9]{2}", options: .regularExpression) else { continue }
            // 百分比后面最多还有 “%]”（可能认成 1、7 之类一两个字符），再多就是拆错了
            guard rest[m.upperBound...].filter(\.isNumber).count <= 2 else { continue }
            let pctStr = rest[m].replacingOccurrences(of: ",", with: ".")
            guard let pct = Double(pctStr), pct <= 100,
                  let exp = Int(expPart.filter(\.isNumber)) else { continue }
            out.append((ExpReading(exp: exp, pct: pct), rank))
        }
        var seen = Set<String>()
        return out.sorted { $0.1 < $1.1 }.map(\.0).filter { seen.insert("\($0.exp)|\($0.pct)").inserted }
    }
}

/// 一次读数带来的变化
public enum ExpEvent: Sendable, Equatable {
    case none                    // 第一次读到 / 没变
    case gain(Int)               // 获得经验
    case levelUp(Int)            // 升级（含升级前后获得的经验）
    case loss(Int)               // 死亡扣经验
    case rejected                // 认错了，丢掉
}

/// 把一串读数变成经验变化。纯逻辑，可离线测试。
/// 原则：每个读数都要和“升级所需”对得上（经验 ÷ 百分比）才算；大涨、死亡、升级都要下一个读数再确认，
/// 认错一次绝不会记进去。升级所需存下来，重启后不用重新猜。
public struct ExpTracker: Sendable {
    public private(set) var last: ExpReading?
    public private(set) var lastTime: Date?
    /// 升级所需的范围（每个读数都把它缩窄一点）；nil = 还没锁定
    public private(set) var range: ClosedRange<Double>?
    public var need: Double? { range.map { ($0.lowerBound + $0.upperBound) / 2 } }
    private var learning: ExpReading?      // 还没锁定时的上一个读数
    private var pendingJump: ExpReading?   // 同一级里的大涨 / 减少，等确认
    private var pendingLevel: ExpReading?  // 像是升级了的读数，等确认
    /// 一直和升级所需对不上、但彼此一致的读数（换角色），攒够了才整个重新开始
    private var strange: [(r: ExpReading, t: Date)] = []

    public init() {}
    /// 接着上次的用（重启程序）
    public init(need: ClosedRange<Double>?, last: ExpReading? = nil, at: Date? = nil) {
        range = need
        if need != nil, let last, let at { self.last = last; lastTime = at }
    }

    /// 超过这么久没有读数（暂停、切到商城、最小化），之后的变化不计入任何一分钟，只重新开始
    public static let maxGap: TimeInterval = 600
    /// 升级所需比这少算低等级：一只怪、一个任务就涨一大截，升级所需也翻倍地涨
    static let low = 1500.0

    /// 这个读数能推出的升级所需范围（百分比只有两位小数）
    static func interval(_ r: ExpReading) -> ClosedRange<Double>? {
        guard r.pct >= 0.02, r.exp > 0 else { return nil }
        return (Double(r.exp) * 100 / (r.pct + 0.011))...(Double(r.exp) * 100 / max(0.005, r.pct - 0.011))
    }
    private static func both(_ a: ClosedRange<Double>, _ b: ClosedRange<Double>) -> ClosedRange<Double>? {
        let lo = max(a.lowerBound, b.lowerBound), hi = min(a.upperBound, b.upperBound)
        return lo <= hi ? lo...hi : nil
    }
    private func fits(_ r: ExpReading) -> ClosedRange<Double>? {
        guard let g = range else { return nil }
        // 刚升级（0.0x%）推不出范围：经验也得小才算对得上
        guard let i = Self.interval(r) else { return Double(r.exp) <= g.upperBound * 0.0015 ? g : nil }
        return Self.both(g, i)
    }

    public mutating func feed(_ cands: [ExpReading], at t: Date) -> ExpEvent {
        guard let first = cands.first else { return .rejected }
        guard let g = range else { return learn(first, t) }
        let old = (g.lowerBound + g.upperBound) / 2
        // 升级：上一级快满了、百分比从高变低、新的升级所需比原来多 2%～60%、补满上一级 + 这一级已有的不太多。
        // 条件这么严，同样的读数再看到一次就算（升级后站着不动，数字不会变）
        if let o = last, let pt = lastTime, t.timeIntervalSince(pt) <= Self.maxGap,
           let r = cands.first(where: { c in
               guard let i = Self.interval(c) else { return false }
               if old < Self.low { return Self.both(i, (old * 1.2)...(old * 3)) != nil && max(0, old - Double(o.exp)) + Double(c.exp) <= old * 3 }
               guard c.pct < o.pct - 20, Self.both(i, (old * 1.02)...(old * 1.6)) != nil else { return false }
               return max(0, old - Double(o.exp)) + Double(c.exp) <= old * 0.2
           }), var n = Self.both(Self.interval(r)!, (old * 1.02)...(old * (old < Self.low ? 3 : 1.6))) {
            guard let p = pendingLevel, r.exp >= p.exp, let pi = Self.interval(p), let both = Self.both(n, pi) else { pendingLevel = r; return .rejected }
            n = both
            pendingLevel = nil; pendingJump = nil; strange = []
            range = n; last = r; lastTime = t
            return .levelUp(max(0, Int((old - Double(o.exp)).rounded())) + r.exp)
        }
        guard let r = cands.first(where: { fits($0) != nil }), let narrowed = fits(r) else {
            // 其他对不上的：多半是认错。只有一分钟以上、5 个不同读数都一致（换了角色、很久没开程序），才重新开始，不计经验
            if let l = strange.last {
                let same = Self.interval(l.r).flatMap { a in Self.interval(first).flatMap { Self.both(a, $0) } } != nil
                if !same || first.exp < l.r.exp || Double(first.exp - l.r.exp) > old * 0.1 { strange = [] }
            }
            if strange.last?.r != first { strange.append((first, t)) }
            if strange.count >= 5, t.timeIntervalSince(strange[0].t) >= 60, let n = Self.interval(first) {
                range = n; last = first; lastTime = t; strange = []; pendingLevel = nil; pendingJump = nil
                return .none
            }
            return .rejected
        }
        strange = []
        pendingLevel = nil
        range = narrowed
        guard let p = last, let pt = lastTime, t.timeIntervalSince(pt) <= Self.maxGap else {
            last = r; lastTime = t; pendingJump = nil
            return .none
        }
        if r == p { lastTime = t; pendingJump = nil; return .none }
        let d = r.exp - p.exp, n = (g.lowerBound + g.upperBound) / 2
        if d > 0, Double(d) <= max(50, n * 0.03) {
            last = r; lastTime = t; pendingJump = nil
            return .gain(d)
        }
        // 大涨（任务奖励）或减少（死亡）：下一个读数还在附近才算
        guard let pj = pendingJump, r.exp >= pj.exp, Double(r.exp - pj.exp) <= max(50, n * 0.03) else {
            pendingJump = r
            return .rejected
        }
        pendingJump = nil; last = r; lastTime = t
        if d >= 0 { return d == 0 ? .none : .gain(d) }
        return Double(-d) <= n * 0.15 ? .loss(-d) : .none
    }

    /// 还不知道升级所需：两个不同的读数推出来一致才锁定
    private mutating func learn(_ r: ExpReading, _ t: Date) -> ExpEvent {
        guard let l = learning else { learning = r; if r.exp == 0, r.pct == 0 { lastTime = t }; return .none }
        // 新号从 0 开始：低等级的读数连着两次一样就锁定
        if l.exp == 0, l.pct == 0, r.exp > 0, let n = Self.interval(r), n.upperBound < Self.low {
            guard pendingJump == r else { pendingJump = r; return .rejected }
            let recent = lastTime.map { t.timeIntervalSince($0) <= Self.maxGap } ?? false
            pendingJump = nil; range = n; last = r; lastTime = t; learning = nil
            return recent ? .gain(r.exp) : .none
        }
        guard r != l else { if r.exp == 0, r.pct == 0 { lastTime = t; pendingJump = nil }; return .none }
        defer { learning = r }
        guard let a = Self.interval(l), let b = Self.interval(r), let n = Self.both(a, b),
              r.exp > l.exp, Double(r.exp - l.exp) < n.upperBound * (n.upperBound < Self.low ? 1 : 0.05) else { return .rejected }
        let d = r.exp - l.exp
        let recent = lastTime.map { t.timeIntervalSince($0) <= Self.maxGap } ?? true
        range = n; last = r; lastTime = t; learning = nil
        return recent ? .gain(d) : .none
    }
    /// 界面上显示的读数（没锁定时先显示刚读到的）
    public var display: ExpReading? { last ?? learning }
}

/// 每分钟的经验记录：有读数的分钟才有记录（0 也记），没记录的分钟是“没数据”（游戏没开、暂停），图上画成空缺
public struct ExpStore: Codable, Sendable {
    /// 分钟（Unix 秒 / 60）→ 这一分钟获得的经验
    public var minutes: [Int: Int] = [:]
    /// 分钟 → 死亡扣掉的经验
    public var losses: [Int: Int] = [:]
    /// 日期（yyyy-MM-dd，本地时区）→ 当天获得的经验（分钟记录只留 35 天，按天的一直留）
    public var days: [String: Int] = [:]
    public var levelUps: [Int] = []
    /// 分钟 → 其中卖给 NPC 的钱（也算在 minutes 里）。旧记录没有
    public var sold: [Int: Int]? = nil

    public init() {}
    /// 分钟 → 其他收入（任务奖励、交易、摆摊；也算在 minutes 里）、在 NPC 商店花的（也算在 losses 里）
    public var other: [Int: Int]? = nil, bought: [Int: Int]? = nil
    /// 个人商店（摆摊、逛摊）：收到的、花掉的
    public var stallIn: [Int: Int]? = nil, stallOut: [Int: Int]? = nil
    /// 任务奖励的金币；坐车、坐船花的
    public var quest: [Int: Int]? = nil, travel: [Int: Int]? = nil
    public mutating func earnQuest(_ n: Int, at t: Date) { record(.gain(n), at: t); Self.add(&quest, n, t) }
    /// 刚记进“没认出来”的改成任务奖励
    public mutating func moveToQuest(_ n: Int, at t: Date) -> Bool {
        let m = Self.minute(t)
        guard let o = other?[m], o >= n else { return false }
        other?[m] = o == n ? nil : o - n
        Self.add(&quest, n, t); return true
    }
    /// 已经当成捡的记过了：只改类别
    public mutating func markQuest(_ n: Int, at t: Date) { Self.add(&quest, n, t) }
    /// 这两分钟里记了多少交通费
    func travelled(near t: Date) -> Int { let m = Self.minute(t); return (travel?[m] ?? 0) + (travel?[m - 1] ?? 0) }
    public mutating func payTravel(_ n: Int, at t: Date) { record(.loss(n), at: t); Self.add(&travel, n, t) }
    private static func add(_ d: inout [Int: Int]?, _ n: Int, _ t: Date) { d = (d ?? [:]).merging([minute(t): n], uniquingKeysWith: +) }
    public mutating func sell(_ n: Int, at t: Date) { record(.gain(n), at: t); Self.add(&sold, n, t) }
    public mutating func stall(_ d: Int, at t: Date) { if d > 0 { record(.gain(d), at: t); Self.add(&stallIn, d, t) } else { record(.loss(-d), at: t); Self.add(&stallOut, -d, t) } }
    public mutating func earnOther(_ n: Int, at t: Date) { record(.gain(n), at: t); Self.add(&other, n, t) }
    public mutating func buy(_ n: Int, at t: Date) { record(.loss(n), at: t); Self.add(&bought, n, t) }
    /// 花掉了但没认出花在哪
    public var unknownOut: Int { losses.values.reduce(0, +) - [bought, stallOut, travel].reduce(0) { $0 + ($1 ?? [:]).values.reduce(0, +) } }
    /// 打怪捡的：全部收入去掉卖店、其他
    public var hunted: [Int: Int] {
        let cut = (sold ?? [:]).merging(other ?? [:], uniquingKeysWith: +).merging(stallIn ?? [:], uniquingKeysWith: +).merging(quest ?? [:], uniquingKeysWith: +)
        return minutes.reduce(into: [:]) { $0[$1.key] = max(0, $1.value - (cut[$1.key] ?? 0)) }
    }

    public static func minute(_ t: Date) -> Int { Int(t.timeIntervalSince1970 / 60) }

    static let dayFmt: DateFormatter = {
        let f = DateFormatter(); f.calendar = Calendar(identifier: .gregorian); f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current; f.dateFormat = "yyyy-MM-dd"; return f
    }()
    public static func dayKey(_ t: Date) -> String { dayFmt.string(from: t) }

    /// 这一分钟有读数（就算没涨经验也算“有数据”）
    public mutating func touch(_ t: Date) { minutes[Self.minute(t), default: 0] += 0 }

    public mutating func record(_ e: ExpEvent, at t: Date) {
        let m = Self.minute(t)
        switch e {
        case .gain(let g): minutes[m, default: 0] += g; days[Self.dayKey(t), default: 0] += g
        case .levelUp(let g): minutes[m, default: 0] += g; days[Self.dayKey(t), default: 0] += g; levelUps.append(m)
        case .loss(let l): losses[m, default: 0] += l; minutes[m, default: 0] += 0
        case .none: minutes[m, default: 0] += 0
        case .rejected: break
        }
    }

    /// 撤回多记的（金币重复记了，背包对账时扣回那一分钟和那一天）
    public mutating func retract(_ n: Int, at t: Date) {
        let m = Self.minute(t), k = Self.dayKey(t)
        minutes[m] = max(0, (minutes[m] ?? 0) - n)
        days[k] = max(0, (days[k] ?? 0) - n)
    }

    /// 隔了一阵才读到的经验：平均记到中间这几分钟（重启程序、状态栏被挡住一会儿）
    public mutating func recordSpan(_ g: Int, from a: Date, to b: Date) {
        let ms = Array(Self.minute(a)...max(Self.minute(a), Self.minute(b)))
        for (i, m) in ms.enumerated() {
            let part = g / ms.count + (i < g % ms.count ? 1 : 0)
            record(.gain(part), at: Date(timeIntervalSince1970: Double(m) * 60))
        }
    }

    /// 按日历的分钟 / 小时 / 天累加。不能用“每天 1440 分钟”去除：夏令时切换那天是 23 或 25 小时，后面整月都会错一天
    public static func grouped(_ d: [Int: Int], from: Date, to: Date, by unit: Calendar.Component, calendar: Calendar) -> [(Date, Int)] {
        let a = minute(from), b = minute(to)
        var sums: [Date: Int] = [:]
        for (m, g) in d where m >= a && m < b {
            let t = Date(timeIntervalSince1970: Double(m) * 60)
            sums[calendar.dateInterval(of: unit, for: t)?.start ?? t, default: 0] += g
        }
        return sums.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }

    /// 只留最近 35 天的分钟记录
    public mutating func prune(now: Date) {
        let cut = Self.minute(now) - 35 * 24 * 60
        minutes = minutes.filter { $0.key >= cut }
        losses = losses.filter { $0.key >= cut }
        sold = sold?.filter { $0.key >= cut }; other = other?.filter { $0.key >= cut }; bought = bought?.filter { $0.key >= cut }; stallIn = stallIn?.filter { $0.key >= cut }; stallOut = stallOut?.filter { $0.key >= cut }; quest = quest?.filter { $0.key >= cut }; travel = travel?.filter { $0.key >= cut }
        levelUps = levelUps.filter { $0 >= cut }
    }

    /// 真正在打怪的分钟：有经验或金币进账的分钟，加上两次进账之间 3 分钟以内的空当（跑路、补给）。
    /// 逛店、挂机一点没涨的时间不算，否则“每小时”会一直往下掉
    public static func playing(_ gains: [[Int: Int]], maxGap: Int = 3) -> Set<Int> {
        var out = Set<Int>()
        for d in gains { for (k, v) in d where v > 0 { out.insert(k) } }
        let s = out.sorted()
        for (a, b) in zip(s, s.dropFirst()) where b - a > 1 && b - a <= maxGap + 1 { out.formUnion((a + 1)..<b) }
        return out
    }

    /// 有数据的分钟数；正在进行的这一分钟按已经过去的秒数算（否则刚开始一分钟就当成整分钟，每小时会偏低）
    public static func activeMinutes(_ keys: some Sequence<Int>, from: Date, to: Date, now: Date) -> Double {
        let a = minute(from), b = minute(to), cur = minute(now)
        var n = 0.0
        for k in Set(keys) where k >= a && k < b && k <= cur {
            n += k == cur ? now.timeIntervalSince1970.truncatingRemainder(dividingBy: 60) / 60 : 1
        }
        return n
    }

    /// [from, to) 时间段里获得的经验和有数据的分钟数
    public func total(from: Date, to: Date) -> (exp: Int, minutes: Int) {
        let a = Self.minute(from), b = Self.minute(to)
        var e = 0, n = 0
        for (m, g) in minutes where m >= a && m < b { e += g; n += 1 }
        return (e, n)
    }

    /// 按天累计（超过 35 天的时间段用这个）
    public func totalDays(from: Date, to: Date) -> Int {
        let a = Self.dayKey(from), b = Self.dayKey(to)
        return days.filter { $0.key >= a && $0.key <= b }.values.reduce(0, +)
    }
}
