// 按字形读游戏里的字：游戏的字是 Arial 不抗锯齿画的，每个字母的点阵固定，一个像素一个像素地对，不会把 x1 认成 xl。
import CoreGraphics
import Foundation

public struct GlyphLine: Sendable, Equatable {
    public var text: String
    /// 点：左边、基线
    public var x: Int, base: Int
    /// 对上的像素数
    public var score: Int
}

public final class Glyphs: @unchecked Sendable {
    struct Glyph { let c: Character, adv: Int, left: Int, top: Int, h: Int, w: Int, on: [(x: Int, y: Int)], off: [(x: Int, y: Int)] }
    public static let shared = Glyphs()
    private var fonts: [Int: [Glyph]] = [:]
    private init() {
        struct Raw: Decodable {
            var adv: Int, left: Int, top: Int, rows: [Int]
            init(from d: Decoder) throws { var u = try d.unkeyedContainer(); adv = try u.decode(Int.self); left = try u.decode(Int.self); top = try u.decode(Int.self); rows = try u.decode([Int].self) }
        }
        guard let u = Bundle.main.url(forResource: "Glyphs", withExtension: "json") ?? Bundle.module.url(forResource: "Glyphs", withExtension: "json"),
              let d = try? Data(contentsOf: u), let f = try? JSONDecoder().decode([String: [String: Raw]].self, from: d) else { return }
        for (s, t) in f {
            fonts[Int(s)!] = t.map { k, r in
                let w = r.rows.map { v in v == 0 ? 0 : Int.bitWidth - v.leadingZeroBitCount }.max() ?? 0
                var on: [(x: Int, y: Int)] = [], off: [(x: Int, y: Int)] = []
                for (y, v) in r.rows.enumerated() { for x in 0..<w { if v >> x & 1 == 1 { on.append((x + r.left, y - r.top)) } else { off.append((x + r.left, y - r.top)) } } }
                return Glyph(c: Character(k), adv: r.adv, left: r.left, top: r.top, h: r.rows.count, w: w, on: on, off: off)
            }.sorted { $0.c < $1.c }
        }
    }

    /// 一段字的笔画：亮点（从左上角算起）。缺字返回 nil
    public func shape(_ text: String, size: Int) -> (w: Int, h: Int, on: [(x: Int, y: Int)])? {
        guard let gs = fonts[size] else { return nil }
        var pen = 0, pts: [(x: Int, y: Int)] = []
        for c in text {
            guard let g = gs.first(where: { $0.c == c }) else { return nil }
            pts += g.on.map { (pen + $0.x, $0.y) }; pen += g.adv
        }
        guard let x0 = pts.map(\.x).min(), let x1 = pts.map(\.x).max(), let y0 = pts.map(\.y).min(), let y1 = pts.map(\.y).max() else { return nil }
        return (x1 - x0 + 1, y1 - y0 + 1, pts.map { ($0.x - x0, $0.y - y0) })
    }

    /// lit：这个像素是不是字的颜色。size：字号。返回每一行读到的字
    public func read(w: Int, h: Int, size: Int, minLetters: Int = 4, lit: (Int, Int) -> Bool) -> [GlyphLine] {
        guard let gs = fonts[size], w > 10, h > 10 else { return [] }
        var m = [Bool](repeating: false, count: w * h)
        for y in 0..<h { for x in 0..<w { m[y * w + x] = lit(x, y) } }
        let space = gs.first { $0.c == " " }!.adv
        // 每列、每基线上有没有字
        var found: [GlyphLine] = []
        for base in 6..<(h + 1) {
            // 从右往左：笔位 x 处最好能读到多少
            var best = [Int](repeating: 0, count: w + 24), pick = [Int](repeating: -1, count: w + 24)      // pick：第几个字；-2 空格
            var any = false
            for x in stride(from: w - 1, through: 0, by: -1) {
                for (i, g) in gs.enumerated() where !g.on.isEmpty {
                    guard x + g.left >= 0, x + g.left + g.w <= w, base - g.top >= 0, base - g.top + g.h <= h else { continue }
                    var ok = true
                    for p in g.on where !m[(base + p.y) * w + x + p.x] { ok = false; break }
                    guard ok else { continue }
                    var extra = 0
                    for p in g.off where m[(base + p.y) * w + x + p.x] { extra += 1 }
                    guard extra * 10 <= g.off.count else { continue }
                    // 字的上下各一行、左边一列不该连着别的亮点（背景杂点、更大的字的一部分）
                    var edge = 0
                    for k in 0..<g.w {
                        let X = x + g.left + k, up = base - g.top - 1, dn = base - g.top + g.h
                        if up >= 0, m[up * w + X] { edge += 1 }
                        if dn < h, m[dn * w + X] { edge += 1 }
                    }
                    let s = g.on.count - extra * 3 - edge * 2
                    guard s > 0 else { continue }
                    let v = s + best[x + g.adv]
                    if v > best[x] { best[x] = v; pick[x] = i; any = true }
                }
                // 空格：这一格是空的
                if x + space < w, best[x + space] > best[x], pick[x + space] >= 0 {
                    var blank = true
                    for yy in max(0, base - size * 2 / 3)..<min(h, base) where blank { for xx in x..<(x + space) where m[yy * w + xx] { blank = false; break } }
                    if blank { best[x] = best[x + space] - 1; pick[x] = -2 }
                }
            }
            guard any else { continue }
            var x = 0
            while x < w {
                // 从一个像样的字开始
                guard pick[x] >= 0, best[x] >= 40, gs[pick[x]].on.count >= 8 else { x += 1; continue }
                // 往右几个像素里有更好的开头就用那个
                var sx = x
                for k in 1...3 where x + k < w && pick[x + k] >= 0 && best[x + k] > best[sx] { sx = x + k }
                var t = "", p = sx, sc = 0, letters = 0
                while p < w, pick[p] != -1 {
                    if pick[p] == -2 { t += " "; p += space } else { let g = gs[pick[p]]; t.append(g.c); sc += g.on.count; if g.c.isLetter || g.c.isNumber { letters += 1 }; p += g.adv }
                }
                // 一串竖线是边框
                if letters >= minLetters, Set(t.filter { !"lI|i.' ".contains($0) }).count >= 3 { found.append(GlyphLine(text: Self.fixIL(t.trimmingCharacters(in: .whitespaces)), x: sx, base: base, score: sc)) }
                x = max(p, x + 1)
            }
        }
        // 同一块地方只留最好的
        var out: [GlyphLine] = []
        for f in found.sorted(by: { $0.score > $1.score }) where !out.contains(where: { abs($0.base - f.base) < size * 2 / 3 && max($0.x, f.x) < min($0.x + $0.text.count * size / 2, f.x + f.text.count * size / 2) }) { out.append(f) }
        return out.sorted { ($0.base, $0.x) < ($1.base, $1.x) }
    }
    /// l 和 I 在小字号里一模一样：单词中间、末尾的是 l；单词开头后面跟小写辅音以外的才可能是 l；全大写的词、罗马数字是 I
    public static func fixIL(_ s: String) -> String {
        s.split(separator: " ", omittingEmptySubsequences: false).map { w -> String in
            var c = Array(w)
            let letters = c.filter(\.isLetter)
            // 全是大写（EXP、HP、III、VII）
            if letters.allSatisfy({ $0.isUppercase || $0 == "l" }) && letters.contains(where: { "IVXABCDEFGHJKLMNOPQRSTUWYZ".contains($0) }) { return String(c.map { $0 == "l" ? "I" : $0 }) }
            for i in c.indices where c[i] == "I" || c[i] == "l" {
                let first = i == 0 || !c[i - 1].isLetter
                let next = i + 1 < c.count ? c[i + 1] : " "
                if !first { c[i] = "l" }
                // 开头：后面是 n t m c r s g d（In、It、Item、Iron、Ice）的当 I，别的当 l
                else if "ntmcrsgdf".contains(next) { c[i] = "I" }
                else if next.isLetter { c[i] = "l" }
                else { c[i] = "I" }
            }
            return String(c)
        }.joined(separator: " ")
    }
    /// 截图里某种颜色的字
    public func read(_ im: CGImage, scale s: Int, size: Int, color: (Int, Int, Int), tol: Int = 8) -> [GlyphLine] {
        guard let p = MiniMap.Pix(im) else { return [] }
        return read(w: p.w / s, h: p.h / s, size: size) { x, y in let c = p.rgb(x * s, y * s); return abs(c.0 - color.0) <= tol && abs(c.1 - color.1) <= tol && abs(c.2 - color.2) <= tol }
    }
}
