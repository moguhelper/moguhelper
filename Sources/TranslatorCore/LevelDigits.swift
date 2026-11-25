// 状态栏的等级：橙色小格子里的白色像素数字。文字识别常漏掉前面的 1（12 → 2），按格子数和字形认。
import CoreGraphics
import Foundation

public enum LevelDigits {
    public struct Reading: Sendable, Equatable {
        /// 几个格子
        public var count: Int
        /// 认出来的数；有一格对不上就是 nil
        public var value: Int?
        /// 每一格都是核实过的字形，一点不差
        public var sure: Bool
    }
    /// 实拍核实过的：1 2 6 7 8；其余按同一套字推的，差几点也算，但不算 sure
    static let verified: Set<Int> = [1, 2, 6, 7, 8]
    static let glyphs: [[String]] = [
        [".#####.", "##...##", "##...##", "##...##", "##...##", "##...##", ".#####."],
        [".##", "###", ".##", ".##", ".##", ".##", ".##"],
        [".#####.", "##...##", ".....##", "..####.", ".##....", "##.....", "#######"],
        [".#####.", "##...##", ".....##", "..####.", ".....##", "##...##", ".#####."],
        ["....##.", "...###.", "..####.", ".##.##.", "#######", "....##.", "....##."],
        ["#######", "##.....", "######.", ".....##", ".....##", "##...##", ".#####."],
        [".#####.", "##...##", "##.....", "######.", "##...##", "##...##", ".#####."],
        ["#######", ".....##", "....##.", "...##..", "...##..", "..##...", "..##..."],
        [".#####.", "##...##", "##...##", ".#####.", "##...##", "##...##", ".#####."],
        [".#####.", "##...##", "##...##", ".######", ".....##", "##...##", ".#####."],
    ]
    /// im：状态栏那条截图（50 点高）；scale：一点几个像素。没看到格子返回 nil
    public static func read(_ im: CGImage, scale s: Int) -> Reading? {
        guard s >= 1, let p = MiniMap.Pix(im), p.w >= 60 * s, p.h >= 20 * s else { return nil }
        let W = min(p.w, 90 * s), H = p.h, tw = 11 * s, th = 13 * s
        var white = [Bool](repeating: false, count: W * H), fill = white, dark = white
        for y in 0..<H { for x in 0..<W {
            let c = p.rgb(x, y), k = y * W + x
            white[k] = min(c.0, c.1, c.2) >= 235
            fill[k] = white[k] || c.0 >= 195 && c.1 >= 75 && c.1 <= 160 && c.2 <= 60
            dark[k] = max(c.0, c.1, c.2) < 70
        } }
        func share(_ m: [Bool], _ x0: Int, _ y0: Int, _ w: Int, _ h: Int) -> Double {
            var n = 0
            for y in y0..<(y0 + h) { for x in x0..<(x0 + w) where m[y * W + x] { n += 1 } }
            return Double(n) / Double(w * h)
        }
        var tiles: [(x: Int, y: Int)] = []
        for y in stride(from: 2, to: H - th, by: 1) { for x in stride(from: 2, to: W - tw - s, by: 1) where fill[(y + th / 2) * W + x] && !fill[(y + th / 2) * W + x - 1] {
            guard !tiles.contains(where: { abs($0.x - x) < 6 * s && abs($0.y - y) < 6 * s }) else { continue }
            guard share(fill, x, y, tw, th) >= 0.94, (0.06..<0.5).contains(share(white, x, y, tw, th)) else { continue }
            func edge(_ ex: Int) -> Bool { share(dark, ex, y + 4, 1, th - 8) > 0.8 }
            guard edge(x - s), edge(x + tw) else { continue }
            tiles.append((x, y))
        } }
        guard let first = tiles.first else { return nil }
        // 一排挨着的格子，别的地方有像的就不认
        let row = tiles.sorted { $0.x < $1.x }
        guard row.count <= 3, row.allSatisfy({ abs($0.y - first.y) <= s }) else { return nil }
        for (a, b) in zip(row, row.dropFirst()) where b.x - a.x < 11 * s || b.x - a.x > 13 * s { return nil }
        var v: Int? = 0, sure = true
        for t in row {
            var g = [[Bool]](repeating: [Bool](repeating: false, count: 11), count: 13)
            for j in 0..<13 { for i in 0..<11 { g[j][i] = white[(t.y + j * s + s / 2) * W + t.x + i * s + s / 2] } }
            guard let d = match(g) else { v = nil; sure = false; continue }
            v = v.map { $0 * 10 + d.0 }; sure = sure && d.1
        }
        if let x = v, x < 1 || x > 250 || String(x).count != row.count { v = nil; sure = false }
        return Reading(count: row.count, value: v, sure: sure)
    }
    static func match(_ g: [[Bool]]) -> (Int, Bool)? {
        let rows = g.indices.filter { g[$0].contains(true) }, cols = (0..<11).filter { c in g.contains { $0[c] } }
        guard let r0 = rows.first, let r1 = rows.last, let c0 = cols.first, let c1 = cols.last, r1 - r0 == 6 else { return nil }
        var d: [(n: Int, off: Int)] = []
        for (n, t) in glyphs.enumerated() where abs(t[0].count - (c1 - c0 + 1)) <= 1 {
            var off = 0
            for j in 0..<7 { for (i, ch) in t[j].enumerated() { if (c0 + i < 11 && g[r0 + j][c0 + i]) != (ch == "#") { off += 1 } } }
            off += (c1 - c0 + 1 - t[0].count).magnitude == 1 ? 2 : 0
            d.append((n, off))
        }
        d.sort { $0.off < $1.off }
        guard let b = d.first else { return nil }
        // 核实过的要一点不差；推的字形许差几点，但要比第二像的明显近
        if verified.contains(b.n) { return b.off == 0 ? (b.n, true) : nil }
        guard b.off <= 5, d.count < 2 || d[1].off - b.off >= 2 else { return nil }
        return (b.n, false)
    }
}
