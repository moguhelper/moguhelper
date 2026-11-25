// 聊天截图预处理。不放在 OCRCore：那里的代码一改，识别子进程就变了，系统要重新编译识别模型（约半分钟）
@_exported import OCRCore
import CoreGraphics
import CoreText
import Foundation

extension ChatOCR {
    /// 聊天截图预处理：每个像素取最亮的通道再拉开对比。好友（橙）、公告（黄）等彩色字都变成白字，
    /// 半透明黑底后面的棕色砖墙、木头压成黑色（橙字压在棕色背景上不处理会认花）
    public static func brighten(_ img: CGImage) -> CGImage {
        guard let (buf, w, h) = TooltipDetector.rgba(img) else { return img }
        var out = [UInt8](repeating: 0, count: w * h)
        for i in 0..<(w * h) {
            let m = Int(max(buf[i * 4], buf[i * 4 + 1], buf[i * 4 + 2]))
            out[i] = UInt8(min(255, max(0, (m - 110) * 255 / 145)))
        }
        megaphones(buf, w, h, &out)
        guard let p = CGDataProvider(data: Data(out) as CFData) else { return img }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue), provider: p, decode: nil, shouldInterpolate: false, intent: .defaultIntent) ?? img
    }

    /// 频道牌数字（4×5 格）；6、8、9 没见过实物，按同一套字推的
    static let digits: [[String]] = [[".##.", "#..#", "#..#", "#..#", ".##."], [".##.", "..#.", "..#.", "..#.", "..#."], ["###.", "...#", ".###", "#...", "####"],
                                     ["###.", "...#", ".###", "...#", "###."], ["#..#", "#..#", "####", "...#", "...#"], ["####", "#...", "###.", "...#", "###."],
                                     [".##.", "#...", "###.", "#..#", ".##."], [".###", "...#", "...#", "..#.", "..#."], [".##.", "#..#", ".##.", "#..#", ".##."],
                                     [".##.", "#..#", ".###", "...#", ".##."]]
    /// 红点（每个字格 2×2 像素，左上角是 C）→ 频道号；哪个数字不像就不认
    static func channel(_ red: Set<[Int]>) -> Int? {
        func digit(_ x0: Int) -> Int? {
            let d = digits.enumerated().map { i, t -> (Int, Int) in
                var n = 0
                for (y, row) in t.enumerated() { for (x, c) in row.enumerated() where (c == "#") != red.contains([x0 + x, y]) { n += 1 } }
                return (n, i)
            }.sorted { $0 < $1 }
            return d[0].0 <= 3 && d[1].0 > d[0].0 ? d[0].1 : nil
        }
        guard let a = digit(8), let b = digit(13), a * 10 + b > 0 else { return nil }
        return a * 10 + b
    }
    static func label(_ s: String, _ w: Int, _ h: Int) -> [UInt8]? {
        var buf = [UInt8](repeating: 0, count: w * h)
        let ok = buf.withUnsafeMutableBytes { p -> Bool in
            guard let c = CGContext(data: p.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            let l = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, CGFloat(h) * 0.9, nil),
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1)]))
            c.textPosition = CGPoint(x: (CGFloat(w) - CTLineGetTypographicBounds(l, nil, nil, nil)) / 2, y: CGFloat(h) * 0.15)
            CTLineDraw(l, c)
            return true
        }
        return ok ? buf : nil
    }

    /// 喇叭：一整条不透明的浅底（粉、黄、青…）配深色字，物品名又是亮字。按“和这一条的底色差多少”重画成黑底白字；
    /// 频道牌（白边小框“CH02 + 耳朵”）只留红字，放大一倍放回原处
    static func megaphones(_ b: [UInt8], _ w: Int, _ h: Int, _ out: inout [UInt8]) {
        guard w > 200, h > 12 else { return }
        func px(_ x: Int, _ y: Int) -> (Int, Int, Int) { let i = (y * w + x) * 4; return (Int(b[i]), Int(b[i + 1]), Int(b[i + 2])) }
        func off(_ p: (Int, Int, Int), _ c: (Int, Int, Int)) -> Int { max(abs(p.0 - c.0), abs(p.1 - c.1), abs(p.2 - c.2)) }
        let xs = Array(stride(from: w / 20, to: w * 19 / 20, by: 3))
        // 每一行的底色：中间值；六成以上的点都是它、而且够亮
        var rows: [(Int, Int, Int)?] = (0..<h).map { y in
            let ps = xs.map { px($0, y) }
            func mid(_ v: [Int]) -> Int { v.sorted()[v.count / 2] }
            let c = (mid(ps.map { $0.0 }), mid(ps.map { $0.1 }), mid(ps.map { $0.2 }))
            guard max(c.0, c.1, c.2) > 150, ps.filter({ off($0, c) <= 26 }).count * 10 >= ps.count * 6 else { return nil }
            return c
        }
        var y = 0
        while y < h {
            guard let c0 = rows[y] else { y += 1; continue }
            var e = y + 1, prev = c0
            while e < h {
                if let c = rows[e], off(c, prev) <= 24, off(c, c0) <= 60 { prev = c; e += 1; continue }
                // 粗体字多的那几行看不出底色：后面几行又是这个底色就算中间也是
                guard rows[e].map({ off($0, prev) > 24 }) ?? true, let n = (e + 1..<max(e + 2, min(h, e + 7))).first(where: { $0 < h && rows[$0].map { off($0, prev) <= 24 } ?? false }),
                      (e..<n).allSatisfy({ rows[$0] == nil }) else { break }
                for k in e..<n { rows[k] = prev }
                e = n
            }
            defer { y = e }
            guard e - y >= 12 else { continue }
            // 左右到哪儿为止
            func solid(_ x: Int) -> Bool { (y..<e).filter { off(px(x, $0), rows[$0]!) <= 40 }.count * 10 >= (e - y) * 4 }
            guard let l = (0..<w / 4).first(where: solid), let r = (w * 3 / 4..<w).last(where: solid) else { continue }
            for yy in y..<e {
                for x in 0..<w {
                    out[yy * w + x] = x < l || x > r ? 0 : UInt8(min(255, max(0, (off(px(x, yy), rows[yy]!) - 40) * 255 / 80)))
                }
            }
            // 频道牌：上下两条一样长的白边
            func white(_ yy: Int) -> [(Int, Int)] {
                var a: [(Int, Int)] = [], s = -1
                for x in l...(r + 1) {
                    let on = x <= r && { let p = px(x, yy); return min(p.0, p.1, p.2) >= 236 }()
                    if on, s < 0 { s = x } else if !on, s >= 0 { if x - s >= 30, x - s <= 160 { a.append((s, x)) }; s = -1 }
                }
                return a
            }
            var done = y
            for top in y..<e where top >= done {
                for (a, z) in white(top) {
                    guard var bot = (top..<min(e, top + 52)).first(where: { yy in yy >= top + 14 && white(yy).contains { abs($0.0 - a) <= 3 && abs($0.1 - z) <= 3 } }) else { continue }
                    // 下边有两三行粗
                    for k in bot + 1..<bot + 4 where k < e && bot == k - 1 && white(k).contains(where: { abs($0.0 - a) <= 6 && abs($0.1 - z) <= 6 }) { bot = k }
                    let x0 = max(l, a - 4), x1 = min(r, z + 3)
                    var red: [(Int, Int)] = []
                    for yy in top...bot { for x in x0...x1 {
                        out[yy * w + x] = 0
                        let p = px(x, yy); if p.0 > 170, p.1 < 70, p.2 < 70 { red.append((x, yy)) }
                    } }
                    done = bot + 1
                    guard let rx0 = red.map(\.0).min(), let rx1 = red.map(\.0).max(), let ry0 = red.map(\.1).min(), let ry1 = red.map(\.1).max() else { continue }
                    // 数字按像素字形认，再用普通字体写回去（原来的像素字识别常认错）
                    if let n = channel(Set(red.map { [($0.0 - rx0) / 2, ($0.1 - ry0) / 2] })), let t = label("ch\(n)", x1 - x0 + 1, bot - top + 1) {
                        for yy in 0...(bot - top) { for x in 0...(x1 - x0) { out[(top + yy) * w + x0 + x] = t[yy * (x1 - x0 + 1) + x] } }
                        continue
                    }
                    let ox = (x0 + x1) / 2 - (rx1 - rx0 + 1), oy = (top + bot) / 2 - (ry1 - ry0 + 1) + 1
                    for (x, yy) in red { for dx in 0...1 { for dy in 0...1 {
                        let nx = ox + (x - rx0) * 2 + dx, ny = oy + (yy - ry0) * 2 + dy
                        if nx >= x0, nx <= x1, ny >= top, ny <= bot { out[ny * w + nx] = 255 }
                    } } }
                }
            }
        }
    }
}
