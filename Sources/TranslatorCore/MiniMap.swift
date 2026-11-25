// 小地图：找到地图画面的范围、自己的黄点，换算成地图坐标。只看截图，不碰游戏。
import CoreGraphics
import Foundation

public struct MiniMapReading: Sendable, Equatable {
    /// 自己的位置（地图坐标）。y 为 nil：地图比小地图高，看不全，上下位置说不准
    public var x: Double, y: Double?
    public init(x: Double, y: Double?) { self.x = x; self.y = y }
    /// 小地图上看到的 NPC（绿点），游戏坐标
    public var npcs: [NavPoint] = []
    /// 蓝圈（传送门），游戏坐标
    public var doors: [NavPoint] = []
    /// 头上有黄色“!”（有任务可接）的 NPC
    public var offers: [NavPoint] = []
}

public enum MiniMap {
    static let ratio = 16.0

    struct Pix {
        let w: Int, h: Int, d: [UInt8]
        init?(_ im: CGImage) {
            w = im.width; h = im.height
            var buf = [UInt8](repeating: 0, count: im.width * im.height * 4)
            let (w, h) = (im.width, im.height)
            let ok = buf.withUnsafeMutableBytes { p -> Bool in
                guard let c = CGContext(data: p.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
                c.interpolationQuality = .none
                c.draw(im, in: CGRect(x: 0, y: 0, width: w, height: h)); return true
            }
            guard ok else { return nil }
            d = buf
        }
        @inline(__always) func rgb(_ x: Int, _ y: Int) -> (Int, Int, Int) { let i = (y * w + x) * 4; return (Int(d[i]), Int(d[i + 1]), Int(d[i + 2])) }
    }
    /// 标题那块的浅蓝灰 (155,187,205)
    static func strip(_ c: (Int, Int, Int)) -> Bool { abs(c.0 - 156) < 14 && abs(c.1 - 187) < 14 && abs(c.2 - 205) < 14 }
    static func white(_ c: (Int, Int, Int)) -> Bool { c.0 > 240 && c.1 > 240 && c.2 > 240 }
    static func light(_ c: (Int, Int, Int)) -> Bool { min(c.0, c.1, c.2) > 203 && max(c.0, c.1, c.2) - min(c.0, c.1, c.2) < 16 }

    /// 小地图窗口在整个游戏截图里的位置（像素；可能被拖到任何地方）：浅蓝灰标题块 + 右上角橙色 WORLD 按钮。
    /// 高度只到地图画面下沿（找不到画面就只给标题部分）
    public static func find(in im: CGImage, scale s: Int) -> CGRect? {
        guard let p = Pix(im) else { return nil }
        var y = 14 * s
        while y < p.h - 30 * s {
            var run0 = -1, x = 0
            while x <= p.w {
                if x < p.w, strip(p.rgb(x, y)) { if run0 < 0 { run0 = x } }
                else if run0 >= 0 {
                    let a = run0, b = x; run0 = -1
                    if b - a >= 100 * s, b - a < 420 * s {
                        // 上面 16 点以内、右边 46 点：橙色 WORLD
                        var n = 0
                        for yy in max(0, y - 16 * s)..<y { for xx in max(0, b - 46 * s)..<min(p.w, b + 4 * s) {
                            let c = p.rgb(xx, yy)
                            if c.0 > 200, c.0 < 248, c.1 > 120, c.1 < 190, c.2 < 75 { n += 1 }
                        } }
                        if n >= 110 * s * s {
                            let top = CGRect(x: a - 3 * s, y: y - 20 * s, width: b - a + 6 * s, height: 70 * s)
                            let full = CGRect(x: 0, y: 0, width: p.w, height: p.h)
                            let area = CGRect(x: top.minX, y: top.minY, width: top.width, height: CGFloat(330 * s)).intersection(full)
                            var r = top
                            if let cut = im.cropping(to: area), let c = canvas(in: cut, scale: s) { r.size.height = c.maxY + CGFloat(8 * s) }
                            return r.intersection(full)
                        }
                    }
                }
                x += 1
            }
            y += max(1, s)
        }
        return nil
    }

    /// 地图画面（不含白边）在截图里的范围，像素
    public static func canvas(in im: CGImage, scale s: Int) -> CGRect? { Pix(im).flatMap { canvas($0, s) } }
    static func canvas(_ p: Pix, _ s: Int) -> CGRect? { framed(p, s) ?? canvasByColor(p, s) }

    /// 小地图窗口的线框色 (85,119,153)
    static func line(_ c: (Int, Int, Int)) -> Bool { abs(c.0 - 85) < 34 && abs(c.1 - 119) < 34 && abs(c.2 - 153) < 34 }
    /// 按窗口线框量出“放地图的那块”（白边以内）。地图比这块小时居中，两边是半透明的、会透出游戏背景，不能按颜色找
    static func framed(_ p: Pix, _ s: Int) -> CGRect? {
        for y in stride(from: 20 * s, to: min(p.h - 40 * s, 110 * s), by: 1) {
            // 标题块和地图之间的横线：上面不远是标题块的浅蓝灰
            var run0 = -1, a = 0, b = 0
            for x in 0...p.w {
                if x < p.w, line(p.rgb(x, y)) { if run0 < 0 { run0 = x } } else if run0 >= 0 { if x - run0 > b - a { a = run0; b = x }; run0 = -1 }
            }
            guard b - a >= 100 * s, strip(p.rgb(a + 20 * s, y - 6 * s)), strip(p.rgb(b - 10 * s, y - 6 * s)) else { continue }
            // 往下：左右竖线内侧各 3 点白边
            let L = a, R = b
            // 线框到地图的距离是固定的：左右各 4 点，上下各 6 点（量出来的）。亮背景透进来时按白边量会错
            for yb in stride(from: y + 40 * s, to: p.h, by: 1) {
                var n = 0, k = 0
                for x in stride(from: a + 4 * s, to: b - 4 * s, by: s) { n += 1; if line(p.rgb(x, yb)) { k += 1 } }
                guard k * 100 >= n * 92 else { continue }
                let l = a + 4 * s, r = b - 4 * s, top = y + 6 * s, bottom = yb - 6 * s
                guard bottom - top > 20 * s else { break }
                var w = 0, m = 0
                for yy in stride(from: top + s, to: bottom - s, by: 2 * s) { m += 1; if white(p.rgb(l - 1, yy)), white(p.rgb(r, yy)) { w += 1 } }
                if m > 0, w * 10 >= m * 7 { return CGRect(x: l, y: top, width: r - l, height: bottom - top) }
                break
            }
            // 几行里取：地图边上碰巧是白的那行会量错
            func vote(_ from: Int, _ step: Int) -> Int? {
                var n: [Int: Int] = [:]
                for k in 0..<8 {
                    let yk = y + (12 + k * 5) * s
                    guard yk < p.h else { break }
                    var x = from, seen = 0
                    for _ in 0..<(12 * s) { guard x >= 0, x < p.w else { break }; if white(p.rgb(x, yk)) { seen += 1 } else if seen >= max(1, 2 * s - 1) { n[x, default: 0] += 1; break }; x += step }
                }
                return n.max { ($0.value, -$0.key * step) < ($1.value, -$1.key * step) }.flatMap { $0.value >= 4 ? $0.key : nil }
            }
            guard let l = vote(max(0, L - 2 * s), 1), let r = vote(min(p.w - 1, R + 2 * s), -1), r - l > 80 * s else { return nil }
            // 上沿：横线下面的白边结束；下沿：整行都是白的
            func whiteRow(_ yk: Int) -> Bool {
                var n = 0, w = 0
                for x in stride(from: l, through: r, by: 2 * s) { n += 1; if white(p.rgb(x, yk)) { w += 1 } }
                return w * 100 >= n * 95
            }
            var top = y + 1
            while top < min(p.h, y + 14 * s), !whiteRow(top) { top += 1 }
            guard top < min(p.h, y + 14 * s) else { return nil }
            while top < p.h, whiteRow(top) { top += 1 }
            var bottom = top + 20 * s
            while bottom < p.h, !whiteRow(bottom) { bottom += 1 }
            guard bottom < p.h else { return nil }
            return CGRect(x: l, y: top, width: r - l + 1, height: bottom - top)
        }
        return nil
    }

    static func canvasByColor(_ p: Pix, _ s: Int) -> CGRect? {
        // ① 标题块：浅蓝灰最宽的一段（一行里至少 60 点）
        var best: (x0: Int, x1: Int, y0: Int, y1: Int)?
        var cur: (x0: Int, x1: Int, y0: Int, y1: Int)?
        for y in stride(from: 0, to: p.h, by: 1) {
            var run0 = -1, a = 0, b = 0, x = 0
            while x < p.w { if strip(p.rgb(x, y)) { if run0 < 0 { run0 = x }; if x - run0 > b - a { a = run0; b = x } } else { run0 = -1 }; x += 1 }
            if b - a >= 60 * s {
                if let c = cur, abs(c.x1 - b) <= 2 * s { cur = (min(c.x0, a), max(c.x1, b), c.y0, y) } else if cur == nil || y - cur!.y1 > 2 * s { cur = (a, b, y, y) }
                if let c = cur, c.y1 - c.y0 >= (best.map { $0.y1 - $0.y0 } ?? -1), c.y0 < 110 * s { best = c }
            }
        }
        guard let t = best, t.y1 - t.y0 >= 8 * s else { return nil }
        // ② 标题块下面：白边的第一行
        let xs = stride(from: t.x1 - 50 * s, to: t.x1 - 8 * s, by: s)
        func whiteRow(_ y: Int) -> Bool { let n = Array(xs); return n.filter { $0 >= 0 && white(p.rgb($0, y)) }.count * 10 >= n.count * 9 }
        var y = t.y1
        while y < min(p.h, t.y1 + 14 * s), !whiteRow(y) { y += 1 }
        guard y < min(p.h, t.y1 + 14 * s) else { return nil }
        while y < p.h, whiteRow(y) { y += 1 }
        // 小地图比窗口窄时右边是白的：上面那段白行会一直延续，所以再按“中间一列”找顶边
        let midX = (t.x0 + t.x1) / 2
        var top = t.y1
        while top < p.h, !white(p.rgb(midX, top)) { top += 1 }
        while top < p.h, light(p.rgb(midX, top)) { top += 1 }
        guard top < p.h - 20 * s, top - t.y1 < 40 * s else { return nil }
        // ③ 左右：往两边走到白边 / 外框为止。取几行里最宽的（地图边上可能有浅色）
        var l = midX, r = midX, bottom = top
        for k in 1...6 {
            let yy = top + k * 4 * s
            guard yy < p.h else { break }
            var a = midX, b = midX
            while a > max(0, t.x0 - 4 * s), !light(p.rgb(a - 1, yy)) { a -= 1 }
            while b < min(p.w - 1, t.x1 + 8 * s), !light(p.rgb(b + 1, yy)) { b += 1 }
            l = min(l, a); r = max(r, b)
        }
        guard r - l > 30 * s else { return nil }
        // ④ 下边：整行大半是白的
        bottom = top + 12 * s
        while bottom < p.h {
            var n = 0, w = 0
            for x in stride(from: l, through: r, by: s) { n += 1; if light(p.rgb(x, bottom)) { w += 1 } }
            if w * 10 >= n * 8 { break }
            bottom += 1
        }
        return CGRect(x: l, y: top, width: r - l + 1, height: bottom - top)
    }

    /// 某种颜色的圆点中心（连在一起的像素块），按块大小筛
    static func dots(_ p: Pix, _ r: CGRect, _ s: Int, minArea: Int, maxArea: Int, _ ok: ((Int, Int, Int)) -> Bool) -> [(x: Double, y: Double, n: Int)] {
        let x0 = Int(r.minX), y0 = Int(r.minY), w = Int(r.width), h = min(Int(r.height), p.h - Int(r.minY))
        guard w > 0, h > 0 else { return [] }
        var m = [Bool](repeating: false, count: w * h)
        for y in 0..<h { for x in 0..<w { m[y * w + x] = ok(p.rgb(x0 + x, y0 + y)) } }
        var out: [(Double, Double, Int)] = []
        for i in m.indices where m[i] {
            var st = [i], n = 0, sx = 0, sy = 0, ax = w, bx = 0, ay = h, by = 0
            m[i] = false
            while let k = st.popLast() {
                let x = k % w, y = k / w
                n += 1; sx += x; sy += y; ax = min(ax, x); bx = max(bx, x); ay = min(ay, y); by = max(by, y)
                for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                    let X = x + dx, Y = y + dy
                    if X >= 0, Y >= 0, X < w, Y < h, m[Y * w + X] { m[Y * w + X] = false; st.append(Y * w + X) }
                }
            }
            if n >= minArea * s * s, n <= maxArea * s * s, bx - ax <= 9 * s, by - ay <= 12 * s {
                out.append((Double(sx) / Double(n) + r.minX, Double(sy) / Double(n) + r.minY, n))
            }
        }
        return out.map { (x: $0.0, y: $0.1, n: $0.2) }
    }
    /// 调试、测试用：所有黄点
    public static func yellowDots(in im: CGImage, scale s: Int) -> [String] {
        guard let p = Pix(im), let c = canvas(p, s) else { return [] }
        return dots(p, c, s, minArea: 3, maxArea: 90, yellow).map { String(format: "%.0f,%.0f n=%d", $0.x, $0.y, $0.n) }
    }
    /// 测试用：绿点、蓝圈在画面里的位置，和表里算出的位置
    public static func debugDots(_ im: CGImage, scale s: Int, map: NavMap) -> String {
        guard let p = Pix(im), let c = canvas(p, s) else { return "无" }
        let S = Double(s)
        func f(_ d: [(x: Double, y: Double, n: Int)]) -> String { d.map { String(format: "(%.1f,%.1f n%d)", ($0.x - c.minX) / S, ($0.y - c.minY) / S, $0.n) }.joined() }
        let k = { (x: Double, y: Double) in String(format: "(%.1f,%.1f)", (x - map.box[0]) / ratio, (y - map.box[1]) / ratio) }
        return "画面 \(c.width / S)x\(c.height / S) 整张 \(map.mini) 绿 \(f(dots(p, c, s, minArea: 8, maxArea: 60, green))) 蓝 \(f(dots(p, c, s, minArea: 2, maxArea: 90, blue))) 表NPC \(map.npcs.map { k($0[1], $0[2]) }) 表门 \(map.portals.filter { $0[3] == 2 }.map { k($0[1], $0[2]) })"
    }
    static func yellow(_ c: (Int, Int, Int)) -> Bool { c.0 > 215 && c.1 > 195 && c.2 < 130 && c.0 - c.1 < 45 }
    static func green(_ c: (Int, Int, Int)) -> Bool { c.1 > 190 && c.0 < 110 && c.2 < 110 }

    static func blue(_ c: (Int, Int, Int)) -> Bool { c.2 > 150 && c.0 < 90 && c.1 > 90 && c.2 - c.0 > 90 && c.2 - c.1 > 15 && c.2 - c.1 < 90 }

    /// im：含整个小地图的截图（scale 倍）。map：现在这张图。
    public static func read(_ im: CGImage, scale s: Int, map: NavMap) -> MiniMapReading? {
        guard let p = Pix(im), let c = canvas(p, s), map.mini.count == 2 else { return nil }
        let me = dots(p, c, s, minArea: 6, maxArea: 70, yellow)
            // 自己的黄点大小固定（约 24 平方点）；黄花、黄屋顶也是黄的，取大小最像的
            .filter { d in
                guard d.n >= 10 * s * s else { return false }
                // 地图比画面窄时两边透出游戏背景，那里的黄色不是自己
                let spare = map.mini[0] - Double(c.width) / Double(s)
                guard spare <= 4 else { return true }
                let x = (d.x - Double(c.minX)) / Double(s) + Self.biasX + spare / 2
                return x > -1.5 && x < map.mini[0] + 1.5
            }.min { abs($0.n - 24 * s * s) < abs($1.n - 24 * s * s) }
        guard let me else { return nil }
        let S = Double(s), viewW = Double(c.width) / S, viewH = Double(c.height) / S
        let mx = (me.x - Double(c.minX)) / S, my = (me.y - Double(c.minY)) / S
        // 图标画在脚底上方约 7.4 个小地图像素、偏左约 0.9（用实拍图里的 NPC、传送门核过）
        let fx = mx + Self.biasX, fy = my + Self.biasY
        let spareX = map.mini[0] - viewW, spareY = map.mini[1] - viewH
        // 滚动了多少：比画面小就居中；自己不在正中 → 停在边上；在正中 → 用绿点、蓝圈对位
        func fixed(_ spare: Double, _ v: Double, _ view: Double) -> Double? {
            if spare <= 4 { return spare / 2 }
            return v < view / 2 - 6 ? 0 : v > view / 2 + 6 ? spare : nil
        }
        var ox = fixed(spareX, fx, viewW), oy = fixed(spareY, fy, viewH)
        // 滚动的大图：和整张小地图比，最准
        if spareX > 4 || spareY > 4, let o = scroll(p, c, s, map: map) {
            if spareX > 4 { ox = o.0 }
            if spareY > 4 { oy = o.1 }
        }
        if ox == nil || oy == nil {
            let g = dots(p, c, s, minArea: 8, maxArea: 60, green).map { (($0.x - Double(c.minX)) / S + Self.biasX, ($0.y - Double(c.minY)) / S + Self.biasY) }
            let b = rings(p, c, s).map { (($0.0 - Double(c.minX)) / S + Self.biasX, ($0.1 - Double(c.minY)) / S + Self.biasY) }
            func k(_ x: Double, _ y: Double) -> (Double, Double) { ((x - map.box[0]) / ratio, (y - map.box[1]) / ratio) }
            let npcs = map.npcs.map { k($0[1], $0[2]) }, doors = map.portals.filter { $0[3] == 2 }.map { k($0[1], $0[2]) }
            if let o = align([(g, npcs), (b, doors)], spareX: max(0, spareX), spareY: max(0, spareY), ox: ox, oy: oy) {
                ox = ox ?? o.0; oy = oy ?? o.1
            }
        }
        guard let ox else { return nil }
        let x = fx + ox
        // 算出来的位置要在图里（刚换图、标题先变时会对不上）
        guard x > -6, x < map.mini[0] + 6 else { return nil }
        var out = MiniMapReading(x: x * ratio + map.box[0], y: oy.map { (fy + $0) * ratio + map.box[1] })
        if let oy {
            let green = dots(p, c, s, minArea: 8, maxArea: 60, green)
            out.npcs = green.map {
                NavPoint(x: (($0.x - Double(c.minX)) / S + Self.biasX + ox) * ratio + map.box[0], y: (($0.y - Double(c.minY)) / S + Self.biasY + oy) * ratio + map.box[1])
            }
            out.doors = rings(p, c, s).map {
                NavPoint(x: (($0.0 - Double(c.minX)) / S + Self.biasX + ox) * ratio + map.box[0], y: (($0.1 - Double(c.minY)) / S + Self.biasY + oy) * ratio + map.box[1])
            }
            out.offers = zip(green, out.npcs).filter { offered(p, $0.0.x, $0.0.y, s) }.map(\.1)
        }
        return out
    }
    static let biasX = 0.9, biasY = 7.4

    /// 绿点正上方有没有黄色的“!”
    static func offered(_ p: Pix, _ x: Double, _ y: Double, _ s: Int) -> Bool {
        var n = 0
        for yy in max(0, Int(y) - 11 * s)...max(0, Int(y) - 3 * s) { for xx in max(0, Int(x) - 2 * s)...min(p.w - 1, Int(x) + 2 * s) {
            let c = p.rgb(xx, yy)
            if c.0 > 215, c.1 > 140, c.2 < 90 { n += 1 }
        } }
        return n >= 3 * s * s
    }

    /// 几张同名的图是哪一张：传送门、NPC 点对得最好的；分不出高下返回 nil。只分整张都放得下的小图
    public static func which(_ im: CGImage, scale s: Int, of maps: [NavMap]) -> Int? {
        guard let p = Pix(im), let c = canvas(p, s) else { return nil }
        let S = Double(s)
        // 小图的小地图画面正好和图一样高：只有一张高度对得上就是它（点会被自己的黄点压住，高度不会）
        let tall = maps.filter { $0.mini.count == 2 && abs($0.mini[1] - Double(c.height) / S) <= 1.6 }
        if tall.count == 1, maps.allSatisfy({ m in m.id == tall[0].id || (m.mini.count == 2 && abs(m.mini[1] - tall[0].mini[1]) >= 4) }) { return tall[0].id }
        let g = dots(p, c, s, minArea: 8, maxArea: 60, green).map { (($0.x - Double(c.minX)) / S + biasX, ($0.y - Double(c.minY)) / S + biasY) }
        let b = rings(p, c, s).map { (($0.0 - Double(c.minX)) / S + biasX, ($0.1 - Double(c.minY)) / S + biasY) }
        guard g.count + b.count >= 2 else { return nil }
        let scored = maps.compactMap { m -> (Int, Int)? in
            guard m.mini.count == 2 else { return nil }
            let sx = m.mini[0] - Double(c.width) / S, sy = m.mini[1] - Double(c.height) / S
            // 画面比这张图小，位置算不准：不给分
            guard sx <= 4, sy <= 4 else { return (m.id, 0) }
            func hit(_ d: (Double, Double), _ x: Double, _ y: Double) -> Bool {
                abs(d.0 + sx / 2 - (x - m.box[0]) / ratio) <= 3.5 && abs(d.1 + sy / 2 - (y - m.box[1]) / ratio) <= 5
            }
            let n = b.filter { d in m.portals.contains { $0[3] == 2 && hit(d, $0[1], $0[2]) } }.count + g.filter { d in m.npcs.contains { hit(d, $0[1], $0[2]) } }.count
            return (m.id, n)
        }.sorted { $0.1 > $1.1 }
        guard scored.count == maps.count, scored.count >= 2, scored[0].1 >= 2, scored[0].1 > scored[1].1 else { return nil }
        return scored[0].0
    }

    /// 蓝圈（传送门）的中心：同一个圈会断成几块，挨着的并起来
    static func rings(_ p: Pix, _ c: CGRect, _ s: Int) -> [(Double, Double)] {
        var groups: [[(x: Double, y: Double, n: Int)]] = []
        for d in dots(p, c, s, minArea: 2, maxArea: 90, blue) {
            if let i = groups.firstIndex(where: { $0.contains { abs($0.x - d.x) <= 8 * Double(s) && abs($0.y - d.y) <= 8 * Double(s) } }) { groups[i].append(d) } else { groups.append([d]) }
        }
        return groups.compactMap { g in
            let n = g.reduce(0) { $0 + $1.n }
            guard n >= 14 * s * s else { return nil }      // 背景里零星的蓝色不算
            let x0 = g.map(\.x).min()!, x1 = g.map(\.x).max()!, y0 = g.map(\.y).min()!, y1 = g.map(\.y).max()!
            return ((x0 + x1) / 2, (y0 + y1) / 2)
        }
    }

    /// 看到的点和表里的点对位：让最多的点对上的滚动量；分不出高下返回 nil
    static func align(_ sets: [(seen: [(Double, Double)], known: [(Double, Double)])], spareX: Double, spareY: Double, ox: Double?, oy: Double?) -> (Double, Double)? {
        let tol = 2.6
        var cands: [(Double, Double)] = []
        for st in sets { for d in st.seen { for k in st.known {
            let x = k.0 - d.0, y = k.1 - d.1
            if x < -tol || x > spareX + tol || y < -tol || y > spareY + tol { continue }
            if let ox, abs(x - ox) > tol { continue }
            if let oy, abs(y - oy) > tol { continue }
            cands.append((x, y))
        } } }
        func score(_ o: (Double, Double)) -> Int {
            sets.reduce(0) { a, st in a + st.seen.filter { d in st.known.contains { abs($0.0 - d.0 - o.0) <= tol && abs($0.1 - d.1 - o.1) <= tol } }.count }
        }
        let scored = cands.map { ($0, score($0)) }
        guard let top = scored.map(\.1).max() else { return nil }
        let best = scored.filter { $0.1 == top }.map(\.0)
        let xs = best.map(\.0), ys = best.map(\.1)
        // 一样好的几个差得远：分不清
        guard xs.max()! - xs.min()! <= 6, ys.max()! - ys.min()! <= 6 else { return nil }
        return (xs.reduce(0, +) / Double(xs.count), ys.reduce(0, +) / Double(ys.count))
    }
}

/// 箭头该指哪、写什么
public struct NavHint: Sendable, Equatable {
    public enum Dir: Sendable { case left, right, up, down, upLeft, upRight, downLeft, downRight, here, none }
    public var dir: Dir
    public var text: String
    public init(dir: Dir, text: String) { self.dir = dir; self.text = text }

    /// 箭头条分两行：第一行往哪走，第二行做什么和距离
    public var lines: (String, String?) {
        var head = text, tail: String?
        if text.hasSuffix("）"), let i = text.firstIndex(of: "（") {
            head = String(text[..<i]); tail = String(text[text.index(after: i)...].dropLast())
        }
        if let c = head.lastIndex(of: "，") {
            let rest = String(head[head.index(after: c)...])
            return (String(head[..<c]), rest + (tail.map { " · " + $0 } ?? ""))
        }
        return (head, tail)
    }

    /// 这个点现在在不在画面里。镜头跟着自己走，到地图边就停；view 是游戏画面的大小（不含标题栏）
    static func inView(_ p: NavPoint, me: MiniMapReading, map: NavMap, view: CGSize) -> Bool {
        let w = Double(view.width), h = Double(view.height)
        func center(_ m: Double, _ lo: Double, _ hi: Double, _ len: Double) -> Double { hi - lo <= len ? (lo + hi) / 2 : min(max(m, lo + len / 2), hi - len / 2) }
        guard w > 0, h > 0, map.box[2] > map.box[0], abs(p.x - center(me.x, map.box[0], map.box[2], w)) < w / 2 - 40 else { return false }
        // 图不比画面高：上下都看得到
        if map.box[3] - map.box[1] <= h + 2 { return true }
        guard let y = me.y else { return false }
        // 镜头上下的位置说不太准，底下又有状态栏、聊天框：留宽一点
        let d = p.y - center(y, map.box[1], map.box[3], h)
        return d > -(h / 2 - 90) && d < h / 2 - 120
    }

    /// me 为 nil（没认出自己在哪）时，只有目标贴着地图边才给方向
    public static func make(_ r: NavRoute, me: MiniMapReading?, map: NavMap, view: CGSize? = nil) -> NavHint {
        var action: String
        switch r.kind {
        case .portalUp: action = "进传送门"
        case .portalAuto: action = "走进传送点"
        case .hidden: action = "进隐藏传送点"
        case .npc: action = r.npcName.isEmpty ? "找 NPC" : "找 \(r.npcName)\(r.ride)"
        case .mob where !r.next.isEmpty: action = "找 \(r.npcName)"
        case .mob: return NavHint(dir: .here, text: r.steps.first ?? "就在这张图")
        case .unknown: return NavHint(dir: .none, text: r.steps.first ?? "")
        }
        guard let me else {
            if let t = r.next.first, r.next.count == 1, map.box[2] > map.box[0] {
                let f = (t.x - map.box[0]) / (map.box[2] - map.box[0])
                if f < 0.12 { return NavHint(dir: .left, text: "往最左边，\(action)\(r.kind == .portalUp ? "按 ↑" : "")") }
                if f > 0.88 { return NavHint(dir: .right, text: "往最右边，\(action)\(r.kind == .portalUp ? "按 ↑" : "")") }
            }
            return NavHint(dir: .none, text: r.steps.first ?? "")
        }
        // 上下差得多的要绕，算远一点
        func far(_ t: NavPoint) -> Double { abs(t.x - me.x) + (me.y.map { abs(t.y - $0) * 1.5 } ?? 0) }
        guard let t0 = r.next.min(by: { far($0) < far($1) }) else { return NavHint(dir: .none, text: r.steps.first ?? "") }
        // 同一张图里走隐藏传送点近得多：先指那个入口
        var t = t0
        if r.kind != .hidden, let y = me.y, let w = Warps.first(map, from: NavPoint(x: me.x, y: y), to: t0) {
            t = NavPoint(x: w[0], y: w[1]); action = w[4] == 3 ? "走进隐藏传送点" : "进隐藏传送点（到\(w[3] < w[1] - 110 ? "上面" : w[3] > w[1] + 110 ? "下面" : w[2] < w[0] ? "左边" : "右边")）"
        }
        let viaWarp = t != t0
        let dx = t.x - me.x, dy = me.y.map { t.y - $0 }
        // 上下差得多：斜着指
        // 找 NPC：出现在画面里就算找到，不用站到跟前
        if r.kind == .npc || r.kind == .mob, !viaWarp, let view, inView(t, me: me, map: map, view: view) {
            let h = abs(dx) < 48 ? "" : dx < 0 ? "左" : "右", v = dy.map { abs($0) < 110 ? "" : $0 < 0 ? "上" : "下" } ?? ""
            let side = h + v
            let at = side.isEmpty ? "旁边" : side.count == 2 ? side + "方" : side + "边"
            if !r.ride.isEmpty { return NavHint(dir: .here, text: "点 \(r.npcName) \(r.ride)（在你\(at)）") }
            if r.kind == .mob { return NavHint(dir: .here, text: "到了，\(r.npcName) 会在你\(at)刷新") }
            return NavHint(dir: .here, text: "就在画面里，\(r.npcName.isEmpty ? "NPC" : r.npcName) 在你\(at)")
        }
        let level = dy.map { abs($0) < 110 ? "" : $0 < 0 ? "上" : "下" } ?? ""
        // 上下有两个门、左右位置差不多，又不知道自己在哪层：说清楚是上面那个还是下面那个
        if dy == nil, abs(dx) < 200, r.kind != .npc, r.kind != .mob, r.kind != .hidden, let o = map.portals.first(where: { $0[3] >= 0 && abs($0[1] - t.x) < 260 && abs($0[2] - t.y) > 150 }) {
            return NavHint(dir: t.y < o[2] ? .up : .down, text: "就在这一带，进\(t.y < o[2] ? "上面" : "下面")那个传送门（别进\(t.y < o[2] ? "下面" : "上面")的）")
        }
        if abs(dx) < 48 {
            guard let dy, abs(dy) >= 110 else { return NavHint(dir: .here, text: viaWarp ? "到了，按 ↑ 试试，\(action)" : r.kind == .npc ? (r.ride.isEmpty ? "就在这里" : "点 \(r.npcName) \(r.ride)") : r.kind == .portalAuto || r.kind == .mob && !viaWarp ? "就在这里" : "到了，按 ↑ 进去") }
            return NavHint(dir: dy < 0 ? .up : .down, text: dy < 0 ? "往上，\(action)" : "往下，\(action)")
        }
        let d = abs(dx) / 800
        let dist = d < 0.5 ? "很近" : String(format: "约 %.1f 屏", d)
        let dir: Dir = level == "上" ? (dx < 0 ? .upLeft : .upRight) : level == "下" ? (dx < 0 ? .downLeft : .downRight) : (dx < 0 ? .left : .right)
        return NavHint(dir: dir, text: "往\(dx < 0 ? "左" : "右")\(level)，\(action)（\(dist)）")
    }
}

/// 画面上自己的名牌
public enum NameTag {
    /// 名牌中心在截图里的横向位置（0~1）。旁边的名牌、宠物名可能连成一行（“Snail PlayerOne”），按字的位置算
    public static func find(_ lines: [OCRLine], name: String) -> Double? {
        let key = name.lowercased()
        guard key.count >= 3 else { return nil }
        var best: (d: Int, x: Double)?
        for l in lines {
            let t = Array(l.text.lowercased())
            for n in [key.count, key.count + 1, key.count - 1] where t.count >= n {
                for i in 0...(t.count - n) {
                    let part = Array(t[i..<(i + n)])
                    let d = Fuzzy.distance(part, Array(key), limit: 3)
                    // 短名字只许错一个，长的两个（W 常认成 yv）
                    guard d <= (key.count >= 7 ? 2 : 1) else { continue }
                    // 前后要是边界，别从别人的长名字里截出来
                    if i > 0, t[i - 1].isLetter || t[i - 1].isNumber { continue }
                    if i + n < t.count, t[i + n].isLetter || t[i + n].isNumber { continue }
                    let x = l.minX + (Double(i) + Double(n) / 2) / Double(t.count) * (l.maxX - l.minX)
                    if best == nil || d < best!.d { best = (d, x) }
                }
            }
        }
        return best?.x
    }
}

/// 名牌的笔画图案（点阵）：认准一次后照着找，不再认字
public struct TagShape: Codable, Sendable, Equatable {
    public var w: Int, h: Int, on: [Int]           // on：白点的 y*w+x
    static func white(_ c: (Int, Int, Int)) -> Bool { min(c.0, c.1, c.2) >= 245 }
    /// 从认准的那一行里取（box：截图里的 0~1 范围，s：每点几像素）
    public static func learn(_ im: CGImage, box: CGRect, scale s: Int) -> TagShape? {
        guard let p = MiniMap.Pix(im) else { return nil }
        let x0 = max(0, Int(box.minX * Double(p.w)) / s - 3), x1 = min(p.w / s, Int(box.maxX * Double(p.w)) / s + 4)
        let y0 = max(0, Int(box.minY * Double(p.h)) / s - 3), y1 = min(p.h / s, Int(box.maxY * Double(p.h)) / s + 4)
        var pts: [(Int, Int)] = []
        for y in y0..<max(y0, y1) { for x in x0..<max(x0, x1) where white(p.rgb(x * s, y * s)) { pts.append((x, y)) } }
        guard pts.count >= 40, let a = pts.map(\.0).min(), let b = pts.map(\.0).max(), let c = pts.map(\.1).min(), let d = pts.map(\.1).max(), d - c >= 5, d - c <= 18, b - a >= 14 else { return nil }
        let w = b - a + 1
        return TagShape(w: w, h: d - c + 1, on: pts.map { ($0.1 - c) * w + $0.0 - a })
    }
    /// 名牌是 Arial 12 号：直接按字形表拼，不用先认准一次
    public static func make(_ name: String) -> TagShape? {
        guard name.count >= 3, let g = Glyphs.shared.shape(name, size: 12) else { return nil }
        return TagShape(w: g.w, h: g.h, on: g.on.map { $0.y * g.w + $0.x }.sorted())
    }
    /// 压在聊天框后面的名牌：白字变成固定的灰 (127,127,127)
    static func dimmed(_ c: (Int, Int, Int)) -> Bool { c.0 == c.1 && c.1 == c.2 && (124...130).contains(c.0) }
    /// 先找白的，没有再找聊天框后面变灰的
    public func find(_ im: CGImage, scale s: Int) -> Double? { find(im, scale: s, lit: Self.white) ?? find(im, scale: s, lit: Self.dimmed) }
    /// 在截图里找：九成笔画对上、笔画之间没有多余的亮点。返回中心的横向位置（0~1）
    func find(_ im: CGImage, scale s: Int, lit: ((Int, Int, Int)) -> Bool) -> Double? { spot(im, scale: s, lit: lit).map { Double($0.x) } }
    /// 中心的左右、上下位置（0~1）
    public func spot(_ im: CGImage, scale s: Int) -> CGPoint? { spot(im, scale: s, lit: Self.white) ?? spot(im, scale: s, lit: Self.dimmed) }
    func spot(_ im: CGImage, scale s: Int, lit: ((Int, Int, Int)) -> Bool) -> CGPoint? {
        guard let p = MiniMap.Pix(im), let first = on.first else { return nil }
        let W = p.w / s, H = p.h / s
        guard W > w, H > h else { return nil }
        var m = [Bool](repeating: false, count: W * H)
        for y in 0..<H { for x in 0..<W { m[y * W + x] = lit(p.rgb(x * s, y * s)) } }
        // 第一个点可能被挡住：拿三个分散的点当起点
        let seeds = [first, on[on.count / 2], on[on.count - 1]]
        var best: (n: Int, x: Int, y: Int)?
        var tried = Set<Int>()
        for y in 0..<H { for x in 0..<W where m[y * W + x] {
            for sd in seeds {
                let ox = x - sd % w, oy = y - sd / w
                guard ox >= 0, oy >= 0, ox + w <= W, oy + h <= H, tried.insert(oy * W + ox).inserted else { continue }
                var miss = 0, hit = 0
                for o in on { if m[(oy + o / w) * W + ox + o % w] { hit += 1 } else { miss += 1; if miss * 10 > on.count { break } } }
                guard miss * 10 <= on.count else { continue }
                var total = 0
                for yy in 0..<h { for xx in 0..<w where m[(oy + yy) * W + ox + xx] { total += 1 } }
                guard total - hit <= on.count / 5 else { continue }
                if best == nil || hit > best!.n { best = (hit, ox, oy) }
            }
        } }
        return best.map { CGPoint(x: (Double($0.x) + Double(w) / 2) / Double(W), y: (Double($0.y) + Double(h) / 2) / Double(H)) }
    }
}
