// 普通用户模式：不带任何图标文件，图标从用户自己的画面上取（商店每行、物品说明框）。只放内存，不写硬盘。
import CoreGraphics
import Foundation

public enum IconGrab {
    /// 32×32 的小图（RGBA，背景透明）
    public struct Icon: Sendable, Equatable {
        public var px: [UInt8]            // 32*32*4，不预乘
        public var opaque: Int { stride(from: 3, to: px.count, by: 4).reduce(0) { $0 + (px[$1] > 0 ? 1 : 0) } }
        public var image: CGImage? {
            guard let d = CGDataProvider(data: Data(px) as CFData) else { return nil }
            return CGImage(width: 32, height: 32, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 128, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                           bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue), provider: d, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        }
    }
    /// 从四边往里把背景（浅灰、影子）去掉，碰到图标的黑边、鲜艳的颜色就停
    /// slot：底是背包格子，颜色知道，只去格子底色和它上面的影子（灰色的东西不会被误去）
    private static func strip(slot: Bool = false, _ at: (Int, Int) -> (Int, Int, Int)) -> Icon? {
        var px = [UInt8](repeating: 0, count: 32 * 32 * 4)
        var bg = [Bool](repeating: false, count: 32 * 32), st: [Int] = []
        func isBg(_ c: (Int, Int, Int)) -> Bool {
            if slot {
                if abs(c.0 - 206) <= 2, abs(c.1 - 201) <= 2, abs(c.2 - 190) <= 2 { return true }
                return c.1 >= 60 && abs(c.0 - c.1 * 225 / 223) <= 3 && abs(c.2 - c.1 * 213 / 223) <= 4
            }
            let lo = min(c.0, c.1, c.2), hi = max(c.0, c.1, c.2); return lo >= 70 && hi - lo <= 45 }
        for i in 0..<32 { for (x, y) in [(i, 0), (i, 31), (0, i), (31, i)] where !bg[y * 32 + x] && isBg(at(x, y)) { bg[y * 32 + x] = true; st.append(y * 32 + x) } }
        while let k = st.popLast() {
            let x = k % 32, y = k / 32
            for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                let X = x + dx, Y = y + dy
                if X >= 0, Y >= 0, X < 32, Y < 32, !bg[Y * 32 + X], isBg(at(X, Y)) { bg[Y * 32 + X] = true; st.append(Y * 32 + X) }
            }
        }
        for y in 0..<32 { for x in 0..<32 where !bg[y * 32 + x] {
            let c = at(x, y), i = (y * 32 + x) * 4
            px[i] = UInt8(c.0); px[i + 1] = UInt8(c.1); px[i + 2] = UInt8(c.2); px[i + 3] = 255
        } }
        let icon = Icon(px: px)
        // 太空、太满（挡住了、没找对地方）不要
        return (60...850).contains(icon.opaque) ? icon : nil
    }
    /// 小图标的颜色：算法和快捷栏、商店里一样（右上那块鲜艳的颜色平均）
    public static func color(_ im: CGImage) -> [Int]? {
        guard let p = MiniMap.Pix(im), p.w >= 32, p.h >= 32 else { return nil }
        var sum = [0, 0, 0], c = 0
        for y in 7..<20 { for x in 12..<32 {
            let q = p.rgb(x, y)
            guard max(q.0, q.1, q.2) - min(q.0, q.1, q.2) > 45 else { continue }
            sum[0] += q.0; sum[1] += q.1; sum[2] += q.2; c += 1
        } }
        return c >= 12 ? sum.map { $0 / c } : nil
    }
    /// 商店一行的图标格。(x, y)：格子左上角（像素）
    public static func shop(_ im: CGImage, x: Int, y: Int, scale s: Int) -> Icon? {
        guard let p = MiniMap.Pix(im), x >= 0, y >= 0, x + 32 * s <= p.w, y + 32 * s <= p.h else { return nil }
        return strip { p.rgb(x + $0 * s, y + $1 * s) }
    }
    /// 物品说明框里的大图标（放大 2 倍，外面一圈浅色方框 68 点）。box：说明框（像素）
    public static func tooltip(_ im: CGImage, box: CGRect, scale s: Int) -> Icon? {
        guard let p = MiniMap.Pix(im) else { return nil }
        func light(_ x: Int, _ y: Int) -> Bool { guard x >= 0, y >= 0, x < p.w, y < p.h else { return false }; let c = p.rgb(x, y); return min(c.0, c.1, c.2) >= 130 && abs(c.2 - c.0) < 60 }
        // 方框左上角：左边、上边是暗的，往右往下各 60 点的边是浅的
        for y in stride(from: Int(box.minY) + 16 * s, to: min(Int(box.maxY) - 68 * s, Int(box.minY) + 90 * s), by: 1) {
            for x in stride(from: Int(box.minX) + 2 * s, to: min(Int(box.maxX) - 68 * s, Int(box.minX) + 24 * s), by: 1) {
                guard light(x + 1, y + 1), !light(x - 2, y + 4 * s), !light(x + 4 * s, y - 2) else { continue }
                var n = 0
                for k in stride(from: 2 * s, to: 66 * s, by: 2 * s) { if light(x + k, y + 1) { n += 1 }; if light(x + 1, y + k) { n += 1 }; if light(x + k, y + 67 * s) { n += 1 }; if light(x + 67 * s, y + k) { n += 1 } }
                guard n >= 120 else { continue }
                // 方框 68 点 = 34 格（每格 2 点），图标 32 格居中
                return strip { p.rgb(x + (2 + $0 * 2) * s + s / 2, y + (2 + $1 * 2) * s + s / 2) }
            }
        }
        return nil
    }
    /// 和标准图标比（自检用）：允许整体错开几格，返回对得上的比例
    public static func similarity(_ a: Icon, _ ref: CGImage) -> Double {
        guard let r = MiniMap.Pix(ref) else { return 0 }
        var best = 0.0
        for oy in -2...(34 - r.h) { for ox in -2...(34 - r.w) {
            var n = 0, ok = 0
            for y in 0..<r.h { for x in 0..<r.w {
                let c = r.rgb(x, y), X = x + ox, Y = y + oy
                guard max(c.0, c.1, c.2) - min(c.0, c.1, c.2) > 45 else { continue }
                n += 1
                guard X >= 0, Y >= 0, X < 32, Y < 32 else { continue }
                let i = (Y * 32 + X) * 4
                if a.px[i + 3] > 0, abs(Int(a.px[i]) - c.0) < 12, abs(Int(a.px[i + 1]) - c.1) < 12, abs(Int(a.px[i + 2]) - c.2) < 12 { ok += 1 }
            } }
            if n > 0 { best = max(best, Double(ok) / Double(n)) }
        } }
        return best
    }
}

/// 图标指纹（Assets/ItemPrints.json）：只有颜色，还原不出图
public final class ItemPrints: @unchecked Sendable {
    public static let shared = ItemPrints()
    private var byPrint: [(p: [UInt8], names: [String])] = []
    public var count: Int { byPrint.count }
    private init() {
        let u = Bundle.main.url(forResource: "ItemPrints", withExtension: "json") ?? URL(fileURLWithPath: "Assets/ItemPrints.json")
        let d = (try? Data(contentsOf: u)).flatMap { try? JSONDecoder().decode([String: Data].self, from: $0) } ?? [:]
        // 用同一张图的（各种卷轴）放一起
        byPrint = Dictionary(grouping: d.filter { $0.value.count == 60 }, by: { [UInt8]($0.value) }).map { ($0.key, $0.value.map(\.key).sorted()) }
    }
    /// 这个指纹是哪些东西；没有很像的、或有两种一样像返回空
    public func names(_ p: [Int]) -> [String] {
        var best = (99, [String]()), second = 99
        for e in byPrint {
            var d = 0
            for i in 0..<60 { d = max(d, abs(Int(e.p[i]) - p[i])); if d >= second { break } }
            if d < best.0 { second = best.0; best = (d, e.names) } else if d < second { second = d }
        }
        return best.0 <= 4 && second - best.0 >= 3 ? best.1 : []
    }
}

extension IconGrab {
    /// 粗看（1 倍截图）：有没有一大片背包格子的底色
    public static func maybeBag(_ im: CGImage) -> Bool {
        guard let p = MiniMap.Pix(im) else { return false }
        var n = 0
        for y in stride(from: 0, to: p.h, by: 2) { for x in stride(from: 0, to: p.w, by: 2) { let c = p.rgb(x, y); if abs(c.0 - 225) <= 8, abs(c.1 - 223) <= 8, abs(c.2 - 213) <= 8 { n += 1 } } }
        return n >= 900
    }
    public struct BagCell: Sendable { public var x: Int, y: Int, names: [String], empty = false, print: [Int] = [] }
    /// 背包里能看到的格子（像素）和各是什么。格子按左边、上边那条暗边找，半透明时找不到
    public static func bag(_ im: CGImage, scale s: Int) -> [BagCell] {
        guard let p = MiniMap.Pix(im) else { return [] }
        var rows = [Int](repeating: 0, count: p.h), cols = [Int](repeating: 0, count: p.w)
        for y in 0..<p.h { for x in 0..<p.w { let c = p.rgb(x, y); if abs(c.0 - 206) <= 1, abs(c.1 - 201) <= 1, abs(c.2 - 190) <= 1 { rows[y] += 1; cols[x] += 1 } } }
        func starts(_ a: [Int]) -> [Int] { a.indices.filter { a[$0] >= 45 * s && ($0 == 0 || a[$0 - 1] < 45 * s) } }
        let ys = starts(rows), xs = starts(cols)
        guard xs.count <= 24, ys.count <= 24 else { return [] }
        var out: [BagCell] = []
        for y in ys { for x in xs where x + 32 * s <= p.w && y + 32 * s <= p.h {
            // 左边的暗边要大半都在（图标会压住几点）：被鼠标、说明框压住的格子，和选中的金框都不取
            let some = (2..<32).filter { k in let c = p.rgb(x, y + k * s); return abs(c.0 - 206) <= 4 && abs(c.1 - 201) <= 4 && abs(c.2 - 190) <= 4 }.count
            guard some >= 14 else { continue }
            var f: [Int] = []
            for y0 in stride(from: 0, to: 20, by: 5) { for x0 in stride(from: 12, to: 32, by: 4) {
                var r = 0, g = 0, b = 0
                for j in y0..<(y0 + 5) { for i in x0..<(x0 + 4) { let c = p.rgb(x + i * s, y + j * s); r += c.0; g += c.1; b += c.2 } }
                f += [r / 20, g / 20, b / 20]
            } }
            // 空格：除了最上面一排暗边，全是底色
            let empty = (15..<60).allSatisfy { abs(f[$0] - [225, 223, 213][$0 % 3]) <= 1 }
                && (4..<30).allSatisfy { k in let c = p.rgb(x + k * s, y + 24 * s); return abs(c.0 - 225) <= 2 && abs(c.1 - 223) <= 2 && abs(c.2 - 213) <= 2 }
            out.append(BagCell(x: x, y: y, names: empty ? [] : ItemPrints.shared.names(f), empty: empty, print: f))
        } }
        return out
    }
    /// 取格子里的图标：数量数字盖住的地方用旁边的颜色补上
    public static func bagIcon(_ im: CGImage, _ c: BagCell, counts: [QuickSlot.Count], scale s: Int) -> Icon? {
        guard let p = MiniMap.Pix(im) else { return nil }
        var px = (0..<1024).map { p.rgb(c.x + ($0 % 32) * s, c.y + ($0 / 32) * s) }
        var hole = [Bool](repeating: false, count: 1024)
        let cx = c.x / s, cy = c.y / s
        for n in counts where n.x >= cx - 2 && n.x < cx + 30 && n.y >= cy + 10 && n.y < cy + 32 {
            var x = n.x - cx
            for d in String(n.value).compactMap(\.wholeNumberValue) {
                if d == 1, x > n.x - cx { x += 1 }      // 不在开头的 1 前面多空一点
                let g = QuickSlot.pixels(d)
                for r in 0..<9 { for k in g[r].indices where g[r][k] { for dy in -1...1 { for dx in -1...1 {
                    let X = x + k + dx, Y = n.y - cy + r + dy
                    if X >= 0, X < 32, Y >= 0, Y < 32 { hole[Y * 32 + X] = true }
                } } } }
                // “1” 左边还伸出一点
                if d == 1 { for Y in (n.y - cy - 1)...(n.y - cy + 3) where (0..<32).contains(Y) { for X in stride(from: max(0, x - 3), to: max(1, min(32, x)), by: 1) { hole[Y * 32 + X] = true } } }
                x += g[0].count + 2
            }
        }
        // 一圈一圈往里补
        for _ in 0..<16 {
            var next = hole
            var put: [(Int, (Int, Int, Int))] = []
            for i in 0..<1024 where hole[i] {
                let x = i % 32, y = i / 32
                for (dx, dy) in [(0, -1), (1, 0), (-1, 0), (0, 1)] {
                    let X = x + dx, Y = y + dy
                    if X >= 0, Y >= 0, X < 32, Y < 32, !hole[Y * 32 + X] { put.append((i, px[Y * 32 + X])); next[i] = false; break }
                }
            }
            if put.isEmpty { break }
            for (i, v) in put { px[i] = v }
            hole = next
        }
        return strip(slot: true) { px[$1 * 32 + $0] }
    }
}
