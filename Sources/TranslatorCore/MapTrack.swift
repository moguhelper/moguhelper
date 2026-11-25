// 没有地图资料时，自己在整张小地图的哪里。大图的小地图会跟着人滚动：比前后两帧挪了多少，碰到边就对一次准。
import CoreGraphics
import Foundation

/// 小地图画面缩成每点一格（每色 4 位），比挪动用
public struct MiniPix: Sendable, Equatable {
    public var w: Int, h: Int, v: [UInt16]
    public init(w: Int, h: Int, v: [UInt16]) { self.w = w; self.h = h; self.v = v }
    /// b 比 a 滚动了多少（画面内容往左挪 = 正）。看不准返回 nil
    public static func shift(_ a: MiniPix, _ b: MiniPix, rx: Int = 14, ry: Int = 22) -> (x: Int, y: Int)? {
        guard a.w == b.w, a.h == b.h, a.w > 30, a.h > 20 else { return nil }
        // 有花纹的点才有用（和左边、上边不一样）
        var pts: [(Int, Int, UInt16)] = []
        for y in stride(from: 2, to: b.h - 1, by: 2) { for x in stride(from: 2, to: b.w - 1, by: 2) {
            let k = b.v[y * b.w + x]
            if k != b.v[y * b.w + x - 1] || k != b.v[(y - 1) * b.w + x] { pts.append((x, y, k)) }
        } }
        guard pts.count >= 60 else { return nil }
        if pts.count > 900 { let s = pts.count / 900 + 1; pts = pts.enumerated().filter { $0.offset % s == 0 }.map(\.element) }
        func score(_ dx: Int, _ dy: Int) -> Double {
            var n = 0, ok = 0
            for p in pts {
                let x = p.0 + dx, y = p.1 + dy
                guard x >= 0, y >= 0, x < a.w, y < a.h else { continue }
                n += 1
                if a.v[y * a.w + x] == p.2 { ok += 1 }
            }
            return n * 2 >= pts.count ? Double(ok) / Double(n) : 0
        }
        let z = score(0, 0)
        if z >= 0.9 { return (0, 0) }
        var best = (s: z, x: 0, y: 0), all: [(s: Double, x: Int, y: Int)] = []
        for dy in -ry...ry { for dx in -rx...rx { let s = score(dx, dy); all.append((s, dx, dy)); if s > best.s + 0.001 { best = (s, dx, dy) } } }
        let second = all.filter { abs($0.x - best.x) > 1 || abs($0.y - best.y) > 1 }.map(\.s).max() ?? 0
        return best.s >= 0.4 && best.s - second >= 0.06 ? (best.x, best.y) : nil
    }
}

/// 一个方向上滚动了多少。左边（上边）算起和右边（下边）算起两套，都知道了就知道整张图比画面多出多少
public struct AxisTrack: Sendable, Equatable {
    public var spare: Double?
    private var lo: Double?, hi: Double?
    public init(spare: Double?) { self.spare = spare }
    public mutating func move(_ d: Double?) {
        guard let d else { lo = nil; hi = nil; return }
        lo = lo.map { $0 + d }; hi = hi.map { $0 + d }
    }
    /// m：黄点在画面里的位置，view：画面多宽
    public mutating func feed(_ m: Double, view: Double) -> Double? {
        if let s = spare, s < 3 { return m }
        // 黄点不在正中 = 滚到头了
        if m < view / 2 - 6 { if let h = hi, lo == nil, h <= 2 { spare = max(0, -h) }; lo = 0; if let s = spare { hi = -s } }
        else if m > view / 2 + 6 { if let l = lo, l >= -2 { spare = max(0, l) }; hi = 0; if let s = spare { lo = s } }
        if let s = spare, s < 3 { return m }
        if let l = lo { return l + m }
        if let h = hi, let s = spare { return s + h + m }
        return nil
    }
}
/// 现在这张图里的位置
public struct MapTrack: Sendable {
    public var x: AxisTrack, y: AxisTrack
    private var last: MiniPix?
    public init(sx: Double?, sy: Double?) { x = AxisTrack(spare: sx); y = AxisTrack(spare: sy) }
    public mutating func feed(_ s: MapSample) -> (x: Double?, y: Double?)? {
        guard let p = s.pix else { return nil }
        if let l = last {
            let d = MiniPix.shift(l, p)
            x.move(d.map { Double($0.x) }); y.move(d.map { Double($0.y) })
        }
        last = p
        guard let m = s.me else { return nil }
        return (x.feed(m.x, view: s.view.width), y.feed(m.y, view: s.view.height))
    }
}
