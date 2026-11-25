// 自己走图采集：只记“从哪张图的什么位置走到了哪张图”，不用 Maps.json 里的任何内容，以后可以单独拿来做导航。
// 地名用屏幕上小地图标题的英文；位置只记在小地图里的比例。只看截图，不碰游戏。
import CoreGraphics
import Foundation

/// 一帧小地图
public struct MapSample: Sendable {
    public var titlePrint: Int                 // 标题文字的指纹
    public var me: CGPoint?                    // 黄点，画面里的点
    public var rings: [CGPoint]                // 蓝圈
    public var view: CGSize
    public var pix: MiniPix? = nil
    public init(titlePrint: Int, me: CGPoint?, rings: [CGPoint], view: CGSize) { self.titlePrint = titlePrint; self.me = me; self.rings = rings; self.view = view }
}

public struct WalkedExit: Codable, Sendable, Equatable {
    public var to: String                      // 目标图的 key
    /// 是从蓝圈走过去的。false = 不在蓝圈上（暗门、自动传送点，也可能是坐车 / 回城 / 死亡）
    public var door: Bool
    public var fx: Double, fy: Double          // 离开时在小地图画面里的位置（0~1）
    public var n: Int
    /// 只有一头看到蓝圈（另一头滚动着没看全）；两个方向都走过就算门
    public var half: Bool? = nil
    /// 到了那边落在画面的哪里（左右比例）
    public var lx: Double? = nil
    /// 在整张小地图里的位置（点）；大图滚动时也准
    public var ax: Double? = nil, ay: Double? = nil
    public init(to: String, door: Bool, fx: Double, fy: Double, n: Int, half: Bool? = nil, lx: Double? = nil) { self.to = to; self.door = door; self.fx = fx; self.fy = fy; self.n = n; self.half = half; self.lx = lx }
}
public struct WalkedMap: Codable, Sendable, Equatable {
    public var street: String, name: String
    /// 同时看到过最多几个蓝圈（大图滚动时看不全，是“至少”）
    public var doors = 0
    public var exits: [WalkedExit] = []
    /// 整张小地图比画面宽多少、高多少（点）
    public var sx: Double? = nil, sy: Double? = nil
    /// 走通的门：同一目标图算一个
    public var walked: Int { exits.filter(\.door).count }
    public init(street: String, name: String) { self.street = street; self.name = name }
}

extension MiniMap {
    /// 从含小地图的截图里取一帧；title：标题文字那块（像素）
    public static func sample(_ im: CGImage, scale s: Int, title: CGRect) -> MapSample? {
        guard let p = Pix(im), let c = canvas(p, s) else { return nil }
        let S = Double(s)
        let me = dots(p, c, s, minArea: 6, maxArea: 70, yellow).filter { $0.n >= 10 * s * s }.min { abs($0.n - 24 * s * s) < abs($1.n - 24 * s * s) }
        let rings = rings(p, c, s).map { CGPoint(x: ($0.0 - c.minX) / S, y: ($0.1 - c.minY) / S) }
        var h = 5381
        let t = title.intersection(CGRect(x: 0, y: 0, width: p.w, height: p.h))
        guard !t.isNull else { return nil }
        for y in Int(t.minY)..<Int(t.maxY) { for x in Int(t.minX)..<Int(t.maxX) {
            let k = p.rgb(x, y)
            h = (h &* 33) &+ (k.0 > 215 ? 1 : 0)
        } }
        let W = Int(c.width) / s, H = Int(c.height) / s
        var v = [UInt16](repeating: 0, count: max(0, W * H))
        if W > 0, H > 0 { for y in 0..<H { for x in 0..<W {
            let k = p.rgb(min(p.w - 1, Int(c.minX) + x * s), min(p.h - 1, Int(c.minY) + y * s))
            v[y * W + x] = UInt16((k.0 >> 4) << 8 | (k.1 >> 4) << 4 | k.2 >> 4)
        } } }
        var out = MapSample(titlePrint: h, me: me.map { CGPoint(x: ($0.x - c.minX) / S, y: ($0.y - c.minY) / S) }, rings: rings, view: CGSize(width: c.width / S, height: c.height / S))
        out.pix = MiniPix(w: W, h: H, v: v)
        return out
    }
}

extension MiniMap {
    /// 标题识别前：白字挑出来变成白底黑字，四周留白（字贴着右边时末尾的 I 会读丢）
    public static func titleImage(_ im: CGImage, rect: CGRect) -> CGImage? {
        guard let c = im.cropping(to: rect.integral), let p = Pix(c) else { return nil }
        let pad = 24, w = p.w + pad * 2, h = p.h + pad * 2
        var out = [UInt8](repeating: 255, count: w * h)
        for y in 0..<p.h { for x in 0..<p.w {
            // 底色 (156,187,205)、字是白的、字的阴影是灰蓝的：红色通道最分得开
            let r = p.rgb(x, y).0
            out[(y + pad) * w + x + pad] = UInt8(255 - min(255, max(0, (r - 170) * 255 / 70)))
        } }
        guard let d = CGDataProvider(data: Data(out) as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue), provider: d, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}

public final class MapCollector {
    public private(set) var maps: [String: WalkedMap]
    public private(set) var current: String?
    private var titles: [Int: String] = [:]                  // 指纹 → 图
    private var reading: (print: Int, key: String)?          // 新标题第一次读到的
    private var recent: [(t: Date, s: MapSample)] = []       // 这张图最近几帧
    private var entering: [(t: Date, s: MapSample)] = []     // 标题变了、还没认出名字时的帧
    private var edge: (from: String, to: String, me: CGPoint, view: CGSize, fromRing: Bool, entry: CGPoint?, t: Date)?
    /// 现在在整张图的哪里
    private var track: MapTrack?
    public private(set) var spot: (x: Double?, y: Double?)?
    private var edgeSpot: (x: Double?, y: Double?)?
    private func follow(_ k: String, _ s: MapSample) {
        if track == nil { track = MapTrack(sx: maps[k]?.sx, sy: maps[k]?.sy) }
        let r = track!.feed(s)
        // 黄点这一下没看到：滚动照样记着，位置用上一次的会错，先空着
        spot = r
        if let v = track!.x.spare, maps[k]?.sx.map({ abs($0 - v) > 3 }) ?? true { maps[k]?.sx = v }
        if let v = track!.y.spare, maps[k]?.sy.map({ abs($0 - v) > 3 }) ?? true { maps[k]?.sy = v }
    }

    public init(maps: [String: WalkedMap] = [:]) { self.maps = maps; mergeGarbled() }
    /// 地名、街道都认花了几个字母（Kerning City / Cining City，Victoria Road / C toria Road）；编号必须一样
    static func garbled(_ a: WalkedMap, _ b: WalkedMap) -> Bool {
        let x = NavDB.norm(a.name), y = NavDB.norm(b.name), p = NavDB.norm(a.street), q = NavDB.norm(b.street)
        guard NavDB.roman(a.name) == NavDB.roman(b.name), min(x.count, y.count) >= 8, a.name != b.name || a.street != b.street else { return false }
        return Fuzzy.distance(x, y, limit: 3) <= 3 && Fuzzy.distance(p, q, limit: 3) <= 3
    }
    /// 以前存下的认残的：两张名字像、“门”两头位置一模一样（人没动，是标题认花了）
    private func mergeGarbled() {
        for k in maps.keys.sorted() {
            guard let m = maps[k] else { continue }
            for e in m.exits {
                guard let o = maps[e.to], e.to != k, let lx = e.lx, abs(lx - e.fx) < 0.005, Self.garbled(m, o) else { continue }
                let bad = (m.exits.count, m.name.count) >= (o.exits.count, o.name.count) ? e.to : k, good = bad == k ? e.to : k
                maps[bad] = nil
                for j in maps.keys {
                    for i in maps[j]!.exits.indices where maps[j]!.exits[i].to == bad { maps[j]!.exits[i].to = good }
                    maps[j]!.exits.removeAll { $0.to == j }
                }
                break
            }
        }
    }

    /// 标题识别出的两行 → (街道, 地名)。不像标题返回 nil
    public static func parseTitle(_ lines: [OCRLine]) -> (street: String, name: String)? {
        let l = lines.sorted { $0.minY < $1.minY }.map { $0.text.trimmingCharacters(in: .whitespaces) }.filter { $0.filter(\.isLetter).count >= 3 }
        guard l.count == 2, l[1].filter(\.isLetter).count >= 4 else { return nil }
        // 末尾编号的 I 常认成 ! l 1 |
        var name = l[1]
        if let r = name.range(of: "\\s[Il1!|]{1,3}$", options: .regularExpression) { name.replaceSubrange(r, with: " " + String(repeating: "I", count: name[r].count - 1)) }
        return (l[0], name)
    }
    static func key(_ street: String, _ name: String) -> String { String(NavDB.norm(street)) + "|" + String(NavDB.norm(name)) + "|" + NavDB.roman(name) }

    /// 新标题要不要识别
    public func needsTitle(_ s: MapSample) -> Bool { titles[s.titlePrint] == nil }

    /// 识别出一个标题。连续两次读到一样的才算（挡住一半的残句不会稳定）
    public func setTitle(_ print: Int, street: String, name: String) {
        guard titles[print] == nil else { return }
        var k = Self.key(street, name)
        // 地名一模一样、街道差得不多（街道认花了：Dungeon → uoabung）：同一张。街道完全是另一个的（同名不同图）不并
        if maps[k] == nil, let same = maps.first(where: { String(NavDB.norm($0.value.name)) == String(NavDB.norm(name)) && NavDB.roman($0.value.name) == NavDB.roman(name)
            && Fuzzy.distance(NavDB.norm($0.value.street), NavDB.norm(street), limit: 5) <= max(2, NavDB.norm(street).count * 3 / 5) }) { k = same.key }
        // 和见过的只差一个字母：同一张（编号必须一样）
        if maps[k] == nil, let same = maps.keys.filter({ o in o.split(separator: "|", omittingEmptySubsequences: false).last == k.split(separator: "|", omittingEmptySubsequences: false).last && k.count >= 12 && Fuzzy.distance(Array(o), Array(k), limit: 1) <= 1 }).first { k = same }
        guard let r = reading, r.print == print, r.key == k else { reading = (print, k); return }
        reading = nil
        titles[print] = k
        if titles.count > 400 { titles = [print: k] }
        if maps[k] == nil { maps[k] = WalkedMap(street: street, name: name) }
    }

    /// 每帧调用。有新东西返回 true
    @discardableResult
    public func feed(_ s: MapSample, at t: Date = Date()) -> Bool {
        guard let k = titles[s.titlePrint] else {
            // 名字还没认出来：留着，认出来再算进去。被挡住时的乱标题也走这里，最多留 20 帧
            entering.append((t, s)); if entering.count > 20 { entering.removeFirst() }
            return false
        }
        var changed = false
        if k != current {
            // 标题读短了（被挡住、还没画完：“The Forest North of I”）：前后脚变成更长的名字、人没动 = 同一张图
            if let c = current, let last = recent.last, t.timeIntervalSince(last.t) < 6, let a = last.s.me, let b = s.me, abs(a.x - b.x) < 12, abs(a.y - b.y) < 12,
               last.s.view == s.view, let m0 = maps[c], let m1 = maps[k], m0.street == m1.street && (Self.cut(m0.name, m1.name) || Self.cut(m1.name, m0.name)) || Self.garbled(m0, m1) {
                let short = Self.garbled(m0, m1) ? (m0.exits.count >= m1.exits.count && m0.name.count >= m1.name.count ? k : c) : Self.cut(m0.name, m1.name) ? c : k, long = short == c ? k : c
                for (p, v) in titles where v == short { titles[p] = long }
                if let sm = maps[short] {
                    maps[long]!.doors = max(maps[long]!.doors, sm.doors)
                    for x in sm.exits where x.to != long && !maps[long]!.exits.contains(where: { $0.to == x.to }) { maps[long]!.exits.append(x) }
                }
                maps[short] = nil
                for key in maps.keys { for i in maps[key]!.exits.indices where maps[key]!.exits[i].to == short { maps[key]!.exits[i].to = long } }
                if let e = edge { edge = (e.from == short ? long : e.from, e.to == short ? long : e.to, e.me, e.view, e.fromRing, e.entry, e.t) }
                current = long; entering = []; follow(long, s)
                recent.append((t, s))
                return true
            }
            let first = entering.first { titles[$0.s.titlePrint] == k } ?? (t, s)
            finishEdge()
            // 上一张图最后一帧 → 这张图第一帧，隔得太久（关过小地图、切出去过）就不算
            if let from = current, let last = recent.last, let me = last.s.me, first.t.timeIntervalSince(last.t) < 8 {
                edge = (from, k, me, last.s.view, Self.near(me, recent.suffix(30).flatMap(\.s.rings)), first.s.me, first.t)
            }
            edgeSpot = spot; track = nil; spot = nil
            current = k; recent = []; changed = true
        }
        entering = []
        recent.append((t, s)); if recent.count > 40 { recent.removeFirst() }
        follow(k, s)
        if s.rings.count > maps[k]!.doors, s.rings.count <= 12 { maps[k]!.doors = s.rings.count; changed = true }
        if let e = edge, t.timeIntervalSince(e.t) > 3 { changed = finishEdge() || changed }
        return changed
    }

    /// 过了几秒再定：自己的黄点会盖住脚下的蓝圈，走开了才看得到
    @discardableResult
    private func finishEdge() -> Bool {
        guard let e = edge else { return false }
        edge = nil
        let at = edgeSpot
        let landed = e.entry.map { Self.near($0, recent.prefix(12).flatMap(\.s.rings)) } ?? false
        var door = e.fromRing && landed
        let half = !door && (e.fromRing || landed)
        let last = recent.first?.s
        let lx = e.entry.flatMap { p in last.flatMap { $0.view.width > 0 ? Double(p.x / $0.view.width) : nil } }
        let gx = e.view.width > 0 ? Double(e.me.x / e.view.width) : 0
        // 树洞、山洞的门在小地图上没有蓝圈：来回都走过，而且去的落脚点就是回来的出发点（两头都对得上），就是门。
        // 回城卷、坐车、死亡的落脚点不会正好这样
        if !door, let lx, let j = maps[e.to]?.exits.firstIndex(where: { $0.to == e.from }), let back = maps[e.to]?.exits[j], let bl = back.lx,
           abs(back.fx - lx) < 0.1, abs(bl - gx) < 0.1 {
            door = true
            maps[e.to]!.exits[j].door = true
        }
        // 回头路也走过，两趟都至少有一头看到蓝圈：是门（坐车、回城不会正好原路来回）
        if !door, let j = maps[e.to]?.exits.firstIndex(where: { $0.to == e.from }), let back = maps[e.to]?.exits[j], half, back.half == true || back.door {
            door = true
            maps[e.to]!.exits[j].door = true
        }
        let fx = e.view.width > 0 ? e.me.x / e.view.width : 0, fy = e.view.height > 0 ? e.me.y / e.view.height : 0
        var m = maps[e.from]!
        // 同一目标图已经有了：位置取平均；曾经从门走通过的就算门
        if let i = m.exits.firstIndex(where: { $0.to == e.to && ($0.door == door) }) {
            let n = Double(m.exits[i].n)
            m.exits[i].fx = (m.exits[i].fx * n + fx) / (n + 1); m.exits[i].fy = (m.exits[i].fy * n + fy) / (n + 1); m.exits[i].n += 1
            if let x = at?.x { m.exits[i].ax = x }; if let y = at?.y { m.exits[i].ay = y }
        } else { var x = WalkedExit(to: e.to, door: door, fx: fx, fy: fy, n: 1, half: half ? true : nil, lx: lx); x.ax = at?.x; x.ay = at?.y; m.exits.append(x) }
        if door { m.exits.removeAll { $0.to == e.to && !$0.door } }
        maps[e.from] = m
        return true
    }
    /// 只比左右：高的图会上下滚动，同一个门在画面里的上下位置会变；站在门上时黄点又盖住了蓝圈，只能和前后几秒看到的比
    /// a 是 b 的前半截（去掉 a 最后那个可能残缺的词）
    public static func cut(_ a: String, _ b: String) -> Bool {
        guard a != b else { return false }
        let x = String(NavDB.norm(a)), y = String(NavDB.norm(b))
        if NavDB.roman(a) != "", NavDB.roman(b) != "" { return false }
        // 只差末尾编号（Grew / Grew II）可能是两张图（Grew I 少读了 I），不并
        if y.hasPrefix(x), b.split(separator: " ").count == a.split(separator: " ").count + 1, NavDB.roman(b) != "" { return false }
        if y.count > x.count, y.hasPrefix(x) { return true }
        let w = a.split(separator: " ").dropLast()
        let stem = String(NavDB.norm(w.joined(separator: " ")))
        return stem.count >= 8 && y.count > x.count && y.hasPrefix(stem)
    }
    static func near(_ p: CGPoint, _ rings: [CGPoint]) -> Bool { rings.contains { abs($0.x - p.x) <= 9 } }
}
