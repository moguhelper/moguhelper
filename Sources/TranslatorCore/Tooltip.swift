// 物品说明框（鼠标悬停在物品上时弹出的深蓝色半透明框）的查找与整理。
// 只处理截图像素，不接触游戏。
import Foundation
import CoreGraphics

public struct TooltipFound {
    /// 说明框在截图里的位置（像素，左上原点）
    public let rect: CGRect
    /// 只保留说明框里白色/亮色文字的黑白图（白底黑字），交给文字识别；背后透出来的任务栏等暗色文字被去掉
    public let cleaned: CGImage
    /// 内容指纹：同一个说明框不重复识别
    public let fingerprint: Int
}

public enum TooltipDetector {
    /// 截图转成 RGBA 字节
    static func rgba(_ img: CGImage) -> (buf: [UInt8], w: Int, h: Int)? {
        let w = img.width, h = img.height
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        let ok = buf.withUnsafeMutableBytes { p -> Bool in
            guard let ctx = CGContext(data: p.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return ok ? (buf, w, h) : nil
    }

    /// 说明框底色：偏深的蓝紫色（用于二值化时排除底色）
    @inline(__always) static func isTooltipBlue(_ r: Int, _ g: Int, _ b: Int) -> Bool {
        b - r >= 25 && b - g >= 15 && b >= 60 && b <= 210 && r <= 130
    }

    /// 说明框内部（非文字）的像素。说明框是约 71% 不透明的深蓝色 (13,17,82) 盖在画面上，
    /// 实测 框内颜色 ≈ 0.29 × 背后颜色 + (9,12,58)：背后白色 → (80,82,130)，砖墙 → (58,46,78)，黑色 → (9,11,58)。
    /// 所以不管背后是什么，框内 R ≤ ~84、G ≤ ~87、B 在 58~132 之间，且 B 不小于 R。
    /// 白底上的说明框颜色（(83,85,132) 左右）和框底深蓝
    @inline(__always) static func isTooltipTint(_ r: Int, _ g: Int, _ b: Int) -> Bool { isInsideBox(r, g, b) && b >= r + 25 && b >= g + 25 }
    @inline(__always) static func isInsideBox(_ r: Int, _ g: Int, _ b: Int) -> Bool {
        // 背后是红/橙色时（招牌、角色衣服）框内会变成 (83,12,58) 这类，B 比 R 小一些但 G 很低
        r <= 90 && g <= 94 && b >= 50 && b <= 142 && (b >= r + 4 || (g <= 60 && b >= r - 30))
    }

    /// 按边框找说明框（精确到点）。框的边是：1 点染色 + 1 点没染色（原画面）+ 里面染色，
    /// 没染色那一圈的颜色套公式正好等于两边的颜色，不管背后是什么都成立（聊天框、状态栏、商店窗口上都准）。
    /// 返回每个框的内部范围（像素）
    static func rings(buf: [UInt8], w: Int, h: Int, scale: CGFloat) -> [CGRect] {
        let s = max(1, Int(scale.rounded())), gw = w / s, gh = h / s
        guard gw > 60, gh > 60 else { return [] }
        // 每点一个值（取格子中间的像素）
        var R = [Int16](repeating: 0, count: gw * gh), G = R, B = R
        for y in 0..<gh { for x in 0..<gw {
            let i = ((y * s + s / 2) * w + x * s + s / 2) * 4
            R[y * gw + x] = Int16(buf[i]); G[y * gw + x] = Int16(buf[i + 1]); B[y * gw + x] = Int16(buf[i + 2])
        } }
        // 点 k 没染色、点 n 是它染色后的样子
        @inline(__always) func tinted(_ k: Int, _ n: Int) -> Bool {
            abs(Int(R[k]) * 29 / 100 + 9 - Int(R[n])) <= 12 && abs(Int(G[k]) * 29 / 100 + 12 - Int(G[n])) <= 12 && abs(Int(B[k]) * 29 / 100 + 58 - Int(B[n])) <= 12
        }
        // 边上的一点：套公式等于两边；或者背后花（物品图标、怪物）两边颜色本来就不同：自己明显没染色、两边都染了色
        @inline(__always) func inside(_ k: Int) -> Bool { isInsideBox(Int(R[k]), Int(G[k]), Int(B[k])) }
        @inline(__always) func edge(_ k: Int, _ d: Int) -> Bool {
            (tinted(k, k - d) && tinted(k, k + d)) || (!inside(k) && inside(k - d) && inside(k + d))
        }
        // 左右两条竖边：一列里连续符合的一段（中间允许被鼠标、文字压断 24 点以内，总体 6 成以上符合）
        struct Run { var x: Int, a: Int, b: Int }
        var vs: [Run] = []
        for x in 1..<(gw - 1) {
            var start = -1, last = -1, count = 0
            func close() { if start >= 0, last - start + 1 >= 28, count * 10 >= (last - start + 1) * 6 { vs.append(Run(x: x, a: start, b: last)) } }
            for y in 0..<gh {
                let k = y * gw + x
                guard edge(k, 1) else { continue }
                if start < 0 { start = y; count = 0 } else if y - last > 24 { close(); start = y; count = 0 }
                last = y; count += 1
            }
            close()
        }
        guard vs.count >= 2 else { return [] }
        // 一行在左右边之间符合的比例
        func cover(_ y: Int, _ x0: Int, _ x1: Int) -> Double {
            guard y >= 1, y < gh - 1, x1 > x0 else { return 0 }
            var n = 0
            for x in x0...x1 { let k = y * gw + x; if edge(k, gw) { n += 1 } }
            return Double(n) / Double(x1 - x0 + 1)
        }
        var found: [CGRect] = []
        for l in vs {
            // 上下两端都对得上的右边。里面的竖线（图标框、背后窗口的边）两端会差几点：先要两端几乎一样的，再取最近的
            func off(_ r: Run) -> Int { max(abs(r.a - l.a), abs(r.b - l.b)) }
            // 真正的右边：再往右，上边那一行就没有框了
            func corner(_ r: Run) -> Bool {
                let y = ((min(l.a, r.a) - 8)...(min(l.a, r.a) + 4)).max { cover($0, l.x + 4, r.x - 4) < cover($1, l.x + 4, r.x - 4) }!
                return cover(y, r.x + 2, min(gw - 2, r.x + 3)) < 1
            }
            guard let r = vs.filter({ $0.x - l.x >= 100 && off($0) <= 14 && corner($0) })
                .min(by: { (off($0) > 3 ? 1 : 0, $0.x) < (off($1) > 3 ? 1 : 0, $1.x) }) else { continue }
            let a = min(l.a, r.a), b = max(l.b, r.b)
            // 横边：上边必须看得到（可能被鼠标压住一截）；下边压在血条等彩色东西上看不清时，用竖边的下端
            guard let top = ((a - 8)...(a + 4)).map({ ($0, cover($0, l.x + 4, r.x - 4)) }).max(by: { $0.1 < $1.1 }), top.1 >= 0.4 else { continue }
            let bot = ((b - 4)...(b + 10)).map { ($0, cover($0, l.x + 4, r.x - 4)) }.max { $0.1 < $1.1 }!
            let t = top.0, u = bot.1 >= 0.3 ? bot.0 : b + 1
            guard u - t >= 28 else { continue }
            let rect = CGRect(x: (l.x + 1) * s, y: (t + 1) * s, width: (r.x - l.x - 1) * s, height: (u - t - 1) * s)
            if !found.contains(rect) { found.append(rect) }
        }
        // 大框里套着的（并排两个框，前一个的右边和后一个的右边拼出来的假框）去掉：留小的
        return found.filter { f in !found.contains { $0 != f && f.contains($0) } }
    }

    /// 截图里所有按边框找到的说明框
    public static func rings(_ img: CGImage, scale: CGFloat) -> [CGRect] {
        guard let (buf, w, h) = rgba(img) else { return [] }
        return rings(buf: buf, w: w, h: h, scale: scale)
    }

    /// 在鼠标附近找说明框。cursor：鼠标在截图里的位置（像素，左上原点）；scale：每点多少像素（Retina 为 2）。
    public static func find(in img: CGImage, cursor: CGPoint, scale: CGFloat) -> TooltipFound? {
        guard let (buf, w, h) = rgba(img) else { return nil }
        @inline(__always) func px(_ x: Int, _ y: Int) -> (Int, Int, Int) {
            let i = (y * w + x) * 4
            return (Int(buf[i]), Int(buf[i + 1]), Int(buf[i + 2]))
        }
        // 0) 先按边框精确找：离鼠标最近的那个（鼠标在框里、或框边离鼠标 70 点以内）
        func distance(_ r: CGRect) -> CGFloat {
            hypot(max(0, r.minX - cursor.x, cursor.x - r.maxX), max(0, r.minY - cursor.y, cursor.y - r.maxY))
        }
        if let ring = rings(buf: buf, w: w, h: h, scale: scale).min(by: { distance($0) < distance($1) }), distance(ring) <= 70 * scale,
           let c = cleaned(img, rect: ring, rgba: (buf, w, h)) {
            return TooltipFound(rect: ring, cleaned: c.image, fingerprint: c.fingerprint)
        }
        // 1) 粗网格（每 step 像素一格）上的“蓝底”标记
        let step = max(2, Int(scale))
        let gw = w / step, gh = h / step
        var blue = [Bool](repeating: false, count: gw * gh)
        for gy in 0..<gh {
            for gx in 0..<gw {
                let (r, g, b) = px(gx * step, gy * step)
                blue[gy * gw + gx] = isInsideBox(r, g, b)
            }
        }
        // 1.5) 腐蚀：只有周围 3×3 格（约 6 像素）都是蓝底的格子才算。背包等窗口的蓝色细边框会被去掉，
        //      避免说明框和背包窗口的边框连成一片
        let er = 1
        var solid = [Bool](repeating: false, count: gw * gh)
        for gy in er..<max(er, gh - er) {
            for gx in er..<max(er, gw - er) where blue[gy * gw + gx] {
                var all = true
                outer: for dy in -er...er { for dx in -er...er where !blue[(gy + dy) * gw + gx + dx] { all = false; break outer } }
                solid[gy * gw + gx] = all
            }
        }
        // 1.6) 闭运算（先膨胀再腐蚀）：说明框是半透明的，背后的物品图标、角色会把蓝底切成碎块，
        //      把小于约 8 像素的缝补上，让整个框连成一片（两个并排的装备框之间缝更宽，不会被连起来）
        func dilate(_ m: [Bool], _ r: Int) -> [Bool] {
            var o = m
            for gy in 0..<gh { for gx in 0..<gw where m[gy * gw + gx] {
                for dy in -r...r { for dx in -r...r {
                    let x = gx + dx, y = gy + dy
                    if x >= 0, y >= 0, x < gw, y < gh { o[y * gw + x] = true }
                } }
            } }
            return o
        }
        func erode(_ m: [Bool], _ r: Int) -> [Bool] {
            var o = [Bool](repeating: false, count: m.count)
            for gy in r..<max(r, gh - r) { for gx in r..<max(r, gw - r) where m[gy * gw + gx] {
                var all = true
                outer: for dy in -r...r { for dx in -r...r where !m[(gy + dy) * gw + gx + dx] { all = false; break outer } }
                o[gy * gw + gx] = all
            } }
            return o
        }
        let closeR = 1
        blue = erode(dilate(solid, closeR), closeR)

        // 2) 在鼠标附近找一块“成片的蓝底”作为起点（说明框通常出现在鼠标右下方，靠边时会翻到其他方向）
        let cx = Int(cursor.x) / step, cy = Int(cursor.y) / step
        let reach = Int(70 * scale) / step
        // 起点候选按离鼠标远近排；离得最近的一小块蓝色可能只是界面上的蓝色边框（技能图标框等），太小就换下一个
        var seeds: [(d: Int, k: Int)] = []
        for gy in stride(from: max(1, cy - reach), to: min(gh - 1, cy + reach), by: 1) {
            for gx in stride(from: max(1, cx - reach), to: min(gw - 1, cx + reach), by: 1) where blue[gy * gw + gx] {
                var n = 0
                for dy in -1...1 { for dx in -1...1 where blue[(gy + dy) * gw + gx + dx] { n += 1 } }
                guard n >= 8 else { continue }
                seeds.append((abs(gx - cx) + abs(gy - cy), gy * gw + gx))
            }
        }
        seeds.sort { $0.d < $1.d }
        var seen = [Bool](repeating: false, count: gw * gh)
        var found: CGRect? = nil
        var tries = 0
        for (_, s) in seeds where !seen[s] {
            tries += 1
            if tries > 12 { break }
            // 3) 从起点向四周填充蓝底，取外接矩形 = 说明框（文字、物品图标被蓝底包围，不影响外框）
            var stack = [s]; seen[s] = true
            var minX = gw, minY = gh, maxX = 0, maxY = 0, count = 0
            var tooBig = false
            while let c = stack.popLast() {
                let x = c % gw, y = c / gw
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y); count += 1
                if count > gw * gh / 2 { tooBig = true; break }   // 漫到大半个画面：不是说明框（比如蓝色背景的地图）
                for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                    let nx = x + dx, ny = y + dy
                    guard nx >= 0, ny >= 0, nx < gw, ny < gh else { continue }
                    let k = ny * gw + nx
                    if !seen[k], blue[k] { seen[k] = true; stack.append(k) }
                }
            }
            if tooBig { return nil }
            // 腐蚀时缩进去的边补回来
            minX = max(0, minX - er); minY = max(0, minY - er); maxX = min(gw - 1, maxX + er); maxY = min(gh - 1, maxY + er)
            let rect = CGRect(x: minX * step, y: minY * step, width: (maxX - minX + 1) * step, height: (maxY - minY + 1) * step)
            // 太小的不是说明框（例如界面上的蓝色按钮、图标边框）：换下一个起点
            if rect.width >= 110 * scale, rect.height >= 30 * scale { found = rect; break }
        }
        guard let rect = found else { return nil }

        guard let c = cleaned(img, rect: rect, rgba: (buf, w, h)) else { return nil }
        return TooltipFound(rect: rect, cleaned: c.image, fingerprint: c.fingerprint)
    }

    /// 一小条截图是不是还在说明框里：大部分像素是框内颜色或文字
    public static func looksLikeBox(_ img: CGImage) -> Bool {
        guard let (buf, w, h) = rgba(img), w > 4, h > 4 else { return false }
        var n = 0, t = 0
        for y in stride(from: 2, to: h - 2, by: 3) {
            for x in stride(from: 2, to: w - 2, by: 3) {
                let i = (y * w + x) * 4
                let r = Int(buf[i]), g = Int(buf[i + 1]), b = Int(buf[i + 2])
                let lum = (r * 299 + g * 587 + b * 114) / 1000
                t += 1
                if isInsideBox(r, g, b) || lum >= 170 || (r >= 190 && b <= 110) { n += 1 }
            }
        }
        return t > 0 && n * 100 >= t * 70
    }

    /// 只保留说明框里的亮色文字（白、橙、红），生成白底黑字图交给文字识别；fingerprint 用来判断内容有没有变
    public static func cleaned(_ img: CGImage, rect: CGRect) -> (image: CGImage, fingerprint: Int)? {
        guard let data = rgba(img) else { return nil }
        return cleaned(img, rect: rect, rgba: data)
    }

    static func cleaned(_ img: CGImage, rect: CGRect, rgba data: (buf: [UInt8], w: Int, h: Int)) -> (image: CGImage, fingerprint: Int)? {
        let (buf, w, h) = data
        @inline(__always) func px(_ x: Int, _ y: Int) -> (Int, Int, Int) {
            let i = (y * w + x) * 4
            return (Int(buf[i]), Int(buf[i + 1]), Int(buf[i + 2]))
        }
        // 4) 只保留亮色文字：白字、以及物品名可能用的彩色字；暗色的背景文字（任务栏等）去掉
        let rx = Int(rect.minX), ry = Int(rect.minY), rw = Int(rect.width), rh = Int(rect.height)
        var out = [UInt8](repeating: 255, count: rw * rh)
        var hash = 5381
        for y in 0..<rh {
            for x in 0..<rw {
                let (r, g, b) = px(min(w - 1, rx + x), min(h - 1, ry + y))
                let lum = (r * 299 + g * 587 + b * 114) / 1000
                // 白字，或橙色字（可用职业、“不可交易”等提示）；灰色字亮度不够，自动去掉
                let orange = r >= 200 && g >= 80 && g <= 210 && b <= 110
                // 红色：需求没达到（例如等级不够）、属性被扣减的 “-1”（实测 (255,0,102)）
                let red = r >= 190 && g <= 90 && b <= 150
                let bright = (lum >= 170 || orange || red) && !isTooltipBlue(r, g, b)
                if bright {
                    out[y * rw + x] = 0
                    if (x + y) % 3 == 0 { hash = (hash &* 33) &+ (x &* 7 &+ y) }
                }
            }
        }
        guard rw > 0, rh > 0, let provider = CGDataProvider(data: Data(out) as CFData),
              let cleaned = CGImage(width: rw, height: rh, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: rw,
                                    space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
                                    provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { return nil }
        return (cleaned, hash)
    }

    /// 识别出的行整理成“物品名 + 说明段落”。说明里折行的句子拼回一段，属性行（含冒号或数字开头）单独成行。
    public static func structure(_ lines: [OCRLine]) -> (title: String, body: [String]) {
        let ls = lines
            .filter { $0.text.filter(\.isLetter).count >= 2 }
            .sorted { $0.minY < $1.minY }
        guard let first = ls.first else { return ("", []) }
        var body: [String] = []
        let maxRight = ls.dropFirst().map(\.maxX).max() ?? 1
        var prevFull = false
        for l in ls.dropFirst() {
            let t = l.text.trimmingCharacters(in: .whitespaces)
            let isStat = t.contains(":") || t.first?.isNumber == true
            if let last = body.last, !isStat, prevFull || t.first?.isLowercase == true,
               !(last.hasSuffix(".") || last.hasSuffix("!") || last.hasSuffix("?") || last.contains(":")) {
                body[body.count - 1] = ChatParser.joinWrapped(last, t)
            } else {
                body.append(t)
            }
            prevFull = l.maxX > maxRight * 0.8
        }
        return (first.text.trimmingCharacters(in: .whitespaces), body)
    }
}

/// 物品说明框整理后的内容
public struct TooltipDoc: Sendable, Equatable {
    public var title = ""
    public var flags: [String] = []                       // 橙色提示：Untradable 等
    public var reqs: [(label: String, value: String)] = [] // REQ LEV : 10 …（灰色的 0 值不会被识别进来）
    public var jobs: [String] = []                         // 可用职业（橙色高亮的）
    public var stats: [(label: String, value: String)] = []
    public var desc: [String] = []                         // 说明文字（折行已拼回）

    public static func == (a: TooltipDoc, b: TooltipDoc) -> Bool {
        a.title == b.title && a.flags == b.flags && a.jobs == b.jobs && a.desc == b.desc
            && a.reqs.map { $0.label + $0.value } == b.reqs.map { $0.label + $0.value }
            && a.stats.map { $0.label + $0.value } == b.stats.map { $0.label + $0.value }
    }

    /// 去掉背后透出来的零碎字（角色名的一截 “condu”、窗口按钮 “[EL.”）：一两个词、又都不是英文单词的行。
    /// 但物品名常常不是英文单词（Cutlus）：去掉以后第一行如果已经是需求 / 职业 / 属性，就把它上面紧挨着的那行找回来当名字
    static func usableLines(_ lines: [OCRLine], glossary g: Glossary) -> [OCRLine] {
        func real(_ l: OCRLine) -> Bool {
            guard l.text.filter(\.isLetter).count >= 2 else { return false }
            let words = l.text.split(whereSeparator: { !$0.isLetter }).map(String.init).filter { $0.count >= 2 }
            if words.count <= 2, l.text.range(of: "[0-9]", options: .regularExpression) == nil, !l.text.contains(":"),
               !words.contains(where: { Words.isWord($0) || g.tipJobs[$0.uppercased()] != nil }),
               !g.tipFlags.keys.contains(where: { Fuzzy.similar($0, l.text) }) { return false }
            return true
        }
        let ok = lines.filter(real).sorted { ($0.minY, $0.minX) < ($1.minY, $1.minX) }
        guard let first = ok.first else { return ok }
        let t = first.text.trimmingCharacters(in: CharacterSet(charactersIn: " •·*.-+°"))
        let words = t.split(whereSeparator: { !$0.isLetter }).map { $0.uppercased() }
        let isField = matchLabel(t, labels: g.tipLabels.keys.sorted { $0.count > $1.count }) != nil
            || (!words.isEmpty && words.allSatisfy { g.tipJobs[$0] != nil })
            || g.tipFlags.keys.contains { Fuzzy.similar($0, t) }
        guard isField else { return ok }
        // 名字在框的最上面：上面被去掉的行里，字最高（名字是大号粗体）的那一行
        guard let name = lines.filter({ !real($0) && $0.text.filter(\.isLetter).count >= 3 && $0.maxY <= first.minY + 0.01 })
            .max(by: { $0.maxY - $0.minY < $1.maxY - $1.minY }) else { return ok }
        return [name] + ok
    }

    /// 把识别出的行分成：名称 / 提示 / 需求 / 职业 / 属性 / 说明
    public static func parse(_ lines: [OCRLine], glossary g: Glossary) -> TooltipDoc {
        var d = TooltipDoc()
        let ls = TooltipDoc.usableLines(lines, glossary: g)
        guard let first = ls.first else { return d }
        func clean(_ s: String) -> String {
            latinize(s).trimmingCharacters(in: CharacterSet(charactersIn: " •·*.-+°")).trimmingCharacters(in: .whitespaces)
        }
        // “(M)” “(F)” 常被认成 “(MI” “(Ml”
        d.title = clean(first.text).replacingOccurrences(of: "\\(([MF])[Il1|]?\\)?$", with: "($1)", options: .regularExpression)
        let jobKeys = Set(g.tipJobs.keys)
        let labelsByLength = g.tipLabels.keys.sorted { $0.count > $1.count }
        var descLines: [OCRLine] = []
        for l in ls.dropFirst() {
            let t = clean(l.text)
            // 橙色提示（单独一行的 “Untradable” 等）
            if g.tipFlags[t] != nil || g.tipFlags[t.trimmingCharacters(in: .punctuationCharacters)] != nil { d.flags.append(t); continue }
            // 说明文字开始后，后面的行都按原顺序算说明（宠物说明里的 “Skill: …” “Tip: …” 不是属性）
            if !descLines.isEmpty { descLines.append(l); continue }
            // 职业行：全是职业单词
            let words = t.split(whereSeparator: { !$0.isLetter }).map { $0.uppercased() }
            if !words.isEmpty, words.allSatisfy({ jobKeys.contains($0) }) { d.jobs += words.map { String($0) }; continue }
            // 已知属性名开头（允许认错一两个字母、允许漏掉冒号）：“REQ LEW : 5”“Weapon Attack +23”
            if let (key, value) = matchLabel(t, labels: labelsByLength) {
                if key.hasPrefix("REQ") { d.reqs.append((key, value)) } else { d.stats.append((key, value)) }
                continue
            }
            // 没见过的 “标签 : 数值”（例如新属性 “Accuracy: +3”）
            if let colon = t.firstIndex(of: ":") {
                let label = t[..<colon].trimmingCharacters(in: .whitespaces)
                let value = t[t.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                let numeric = value.range(of: "^[+-]?\\s*[0-9]", options: .regularExpression) != nil
                if label.count <= 24, label.split(separator: " ").count <= 4, numeric || g.tipValues[value] != nil, value.count <= 30 {
                    d.stats.append((label, value)); continue
                }
            }
            descLines.append(l)
        }
        d.desc = TooltipDoc.paragraphs(descLines.map { OCRLine(text: clean($0.text), minX: $0.minX, maxX: $0.maxX, minY: $0.minY, maxY: $0.maxY) })
        return d
    }
}

/// 行首是不是某个已知属性名（字母比对，允许 1~2 个字母认错），返回（标准属性名, 值）
func matchLabel(_ line: String, labels: [String]) -> (String, String)? {
    // 先找完全一致的属性名，再允许认错字母（否则 MaxHP 会被认成只差一个字母的 MaxMP）
    if let r = matchLabel(line, labels: labels, fuzzy: false) { return r }
    // 冒号前的整段和属性名比，取最接近的（“evater of Life Dries Up” → “Water of Life Dries Up”，行首多认出了字母）
    if let colon = line.firstIndex(of: ":") {
        let head = Array(line[..<colon].lowercased().filter(\.isLetter))
        let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        if head.count >= 8, !value.isEmpty {
            let best = labels.map { k -> (String, Int) in
                let kk = Array(k.lowercased().filter(\.isLetter))
                return (k, kk.count >= 8 ? Fuzzy.distance(head, kk, limit: 4) : 99)
            }.min { $0.1 < $1.1 }
            if let (key, d) = best, d <= max(2, key.filter(\.isLetter).count / 6) { return (key, value) }
        }
    }
    return matchLabel(line, labels: labels, fuzzy: true)
}

func matchLabel(_ line: String, labels: [String], fuzzy: Bool) -> (String, String)? {
    let letters = { (s: Substring) in s.uppercased().filter { $0.isLetter } }
    for key in labels {
        let k = Array(letters(Substring(key)))
        // 取行首和属性名等长的那段字母
        var taken = 0, idx = line.startIndex
        while idx < line.endIndex, taken < k.count {
            if line[idx].isLetter { taken += 1 }
            idx = line.index(after: idx)
        }
        guard taken == k.count else { continue }
        let head = Array(letters(line[..<idx]))
        // 认错时只允许改字母，不允许改到另一个已知属性名上
        let lim = !fuzzy ? 0 : (k.count >= 8 ? 2 : (k.count >= 6 ? 1 : 0))
        guard Fuzzy.distance(head, k, limit: lim) <= lim else { continue }
        // 属性名后面紧跟着字母说明不是这个属性（例如 “STR” 之于 “STRENGTH”）
        if idx < line.endIndex, line[idx].isLetter { continue }
        let value = line[idx...].trimmingCharacters(in: CharacterSet(charactersIn: " :;：.-").union(.whitespaces))
        guard !value.isEmpty else { continue }
        // “Max MP increases.” 这种说明句不是属性行：没有冒号、后面跟着英文单词
        if !line.contains(":"), value.range(of: "^[A-Za-z]{3,}", options: .regularExpression) != nil { continue }
        return (key, value)
    }
    return nil
}

/// 属性值是 “+数字” 时修正认错的数字。
/// 1) 有括号 “(5+1)”、“(28 -3)” 时，前面的值一定等于括号里算出来的结果；
/// 2) 否则把认成字母的单个数字改回来（游戏的像素字体里 6 常被认成 b/p/F，2 认成 z）。
func fixDigits(_ v: String) -> String {
    guard let sign = v.first, sign == "+" || sign == "-" else { return v }
    var head = String(v.dropFirst())
    var tail = ""
    if let p = head.firstIndex(where: { $0 == "(" || $0 == "（" }) {
        tail = String(head[p...]); head = String(head[..<p])
    }
    head = head.trimmingCharacters(in: .whitespaces)
    if head.allSatisfy(\.isNumber), !head.isEmpty, tail.isEmpty { return "\(sign)\(head)" }   // “+ 30” → “+30”
    // 括号里的算式
    let inner = tail.filter { $0.isNumber || $0 == "+" || $0 == "-" || $0 == " " }
    if let m = inner.range(of: "^\\s*([0-9]+)\\s*([+-])\\s*([0-9]+)\\s*$", options: .regularExpression) {
        let parts = inner[m].split(whereSeparator: { $0 == " " || $0 == "+" || $0 == "-" }).compactMap { Int($0) }
        if parts.count == 2 {
            let total = inner.contains("-") ? parts[0] - parts[1] : parts[0] + parts[1]
            let tailFixed = "(" + "\(parts[0]) " + (inner.contains("-") ? "-" : "+") + "\(parts[1]))"
            return "\(sign)\(total) " + tailFixed
        }
    }
    if head.allSatisfy(\.isNumber), !head.isEmpty { return v }
    let map: [Character: Character] = ["b": "6", "p": "6", "P": "6", "F": "6", "G": "6", "฿": "6", "z": "2", "ż": "2", "ž": "2", "ź": "2", "Z": "2",
                                       "O": "0", "o": "0", "l": "1", "I": "1", "|": "1", "S": "5", "s": "5", "B": "8",
                                       "g": "9", "q": "9", "ộ": "6", "A": "4", "‡": "4", "*": "4", "T": "7"]
    let fixed = String(head.map { map[$0] ?? $0 })
    guard !fixed.isEmpty, fixed.allSatisfy(\.isNumber) else { return v }
    return "\(sign)\(fixed)" + (tail.isEmpty ? "" : " " + tail)
}

/// 识别结果里混进来的西里尔字母（Тор、МахНР）换回长得一样的英文字母
func latinize(_ s: String) -> String {
    let map: [Character: Character] = ["А": "A", "В": "B", "Е": "E", "К": "K", "М": "M", "Н": "H", "О": "O", "Р": "P", "С": "C",
                                       "Т": "T", "Х": "X", "Ш": "W", "а": "a", "е": "e", "о": "o", "р": "p", "с": "c", "у": "y",
                                       "х": "x", "ш": "w", "і": "i", "ѕ": "s", "м": "M", "т": "T", "к": "K", "н": "H"]
    return String(s.map { map[$0] ?? $0 })
}

/// 属性值认错一个字母时（Fost → Fast）也能对上词典
func fuzzyValue(_ v: String, _ dict: [String: String]) -> String? {
    let n = Array(v.lowercased())
    guard n.count >= 3 else { return nil }
    return dict.first { k, _ in Fuzzy.distance(Array(k.lowercased()), n, limit: 1) <= 1 }?.value
}

extension TooltipDoc {
    /// 说明文字分段：上下空出一行的地方分段；以 “[”“Lv.”“Tip”“Ex)”“Skill”“Caution” 开头的行也另起一段；
    /// 同一段里的折行拼回一句（整段一起翻译，逐行翻译会把句子拆碎）
    static func paragraphs(_ lines: [OCRLine]) -> [String] {
        guard !lines.isEmpty else { return [] }
        let heights = lines.map { $0.maxY - $0.minY }.sorted()
        let lineH = heights[heights.count / 2]
        var out: [String] = []
        var cur = ""
        var lastMaxY = lines[0].minY
        for l in lines {
            let t = l.text
            let gap = l.minY - lastMaxY > lineH * 0.8
            let starter = t.range(of: "^(\\[|Lv\\.|Tip|Ex\\)|Skill|Caution|Note)", options: [.regularExpression, .caseInsensitive]) != nil
            // 带日期的行（“… Dries Up: 12/17/2026 00:00 UTC”）单独成段
            let dated = t.range(of: "[0-9]{1,2}/[0-9]{1,2}/[0-9]{4}", options: .regularExpression) != nil
            if dated { if !cur.isEmpty { out.append(cur) }; out.append(t); cur = ""; lastMaxY = l.maxY; continue }
            if cur.isEmpty { cur = t }
            else if gap || starter { out.append(cur); cur = t }
            else { cur = ChatParser.joinWrapped(cur, t) }
            lastMaxY = l.maxY
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }
}

/// 物品说明框的中文版
public struct TooltipZh: Sendable {
    public var title: String
    public var flags: [String]
    public var reqLine: String?
    public var jobLine: String?
    public var stats: [String]
    public var desc: [String]
    public var isEquipped = false

    /// 纯文本（旁边翻译窗用）
    public var plainText: String {
        var out = [title + (isEquipped ? "（已装备）" : "")]
        out += flags
        if let r = reqLine { out.append(r) }
        if let j = jobLine { out.append(j) }
        if !stats.isEmpty { out.append("──────"); out += stats }
        out += desc
        return out.joined(separator: "\n")
    }
}

extension ChatTranslator {
    /// 翻译整个说明框：固定词典能翻的直接翻，物品名和说明文字交给系统翻译
    public func translateTooltip(_ d: TooltipDoc) async -> TooltipZh {
        let g = glossary
        let item = ItemDB.shared.title(d.title)
        let title: String
        if let i = item { title = i.zh } else if let z = ItemNames.zh(ItemNames.fix(d.title) ?? d.title) { title = z } else { title = await plain(ItemNames.fix(d.title) ?? d.title) }
        let flags = d.flags.map { g.tipFlags[$0] ?? g.tipFlags[$0.trimmingCharacters(in: .punctuationCharacters)] ?? $0 }
        let reqs = d.reqs.filter { $0.value != "0" }.map { "\(g.tipLabels[$0.label] ?? $0.label) \($0.value)" }
        let jobs = d.jobs.map { g.tipJobs[$0] ?? $0 }
        var stats: [String] = []
        for s in d.stats {
            let label = g.tipLabels[s.label] ?? s.label
            let value: String
            let fixedValue = fixDigits(s.value)
            if let v = g.tipValues[s.value] ?? fuzzyValue(s.value, g.tipValues) { value = v }
            else if fixedValue != s.value { value = fixedValue }
            else if s.value.allSatisfy({ $0.isNumber || "+-%., /:".contains($0) }) { value = s.value }
            else { value = await plain(s.value) }
            let zhLabel = g.tipLabels[s.label] == nil ? await plain(label) : label
            stats.append("\(zhLabel)：\(value)")
        }
        var desc: [String] = []
        if let i = item, let x = ItemDB.shared.desc(i.entry, ocr: d.desc.joined(separator: " ")) { desc = [await itemDescZh(x)] }
        else { for p in d.desc { desc.append(await plain(p)) } }
        return TooltipZh(title: title, flags: flags,
                         reqLine: reqs.isEmpty ? nil : "需求：" + reqs.joined(separator: " · "),
                         jobLine: jobs.isEmpty ? nil : "可用职业：" + jobs.joined(separator: " "),
                         stats: stats, desc: desc)
    }
}

/// 说明框里的一块文字和它的中文（原地替换用）。位置是在说明框截图里的比例（0~1，左上原点）
public struct TooltipPiece: Sendable {
    public enum Kind: Sendable { case title, flag, req, jobs, stat, desc, gray }
    public var kind: Kind
    public var zh: String
    public var minX: Double, maxX: Double, minY: Double, maxY: Double
}

extension ChatTranslator {
    static let reqOrder = ["REQ LEV", "REQ STR", "REQ DEX", "REQ INT", "REQ LUK", "REQ FAM"]
    /// 原地替换：每行（说明文字按段）单独翻译，记住原来的位置，只盖住英文，装备图标、边框、灰色字都露出来
    /// boxHeightPt：说明框高度（点）。需求行只认出一行时（其余都是灰色 0），按游戏固定行距 12 点推算其余行
    public func translateTooltipPieces(_ lines: [OCRLine], boxHeightPt: Double? = nil) async -> [TooltipPiece] {
        let g = glossary
        let doc = TooltipDoc.parse(lines, glossary: g)
        guard !doc.title.isEmpty else { return [] }
        let ls = TooltipDoc.usableLines(lines, glossary: g)
        guard let first = ls.first else { return [] }
        func clean(_ s: String) -> String {
            latinize(s).trimmingCharacters(in: CharacterSet(charactersIn: " •·*.-+°")).trimmingCharacters(in: .whitespaces)
        }
        func piece(_ k: TooltipPiece.Kind, _ z: String, _ ls: [OCRLine]) -> TooltipPiece {
            TooltipPiece(kind: k, zh: z, minX: ls.map(\.minX).min()!, maxX: ls.map(\.maxX).max()!,
                         minY: ls.map(\.minY).min()!, maxY: ls.map(\.maxY).max()!)
        }
        let skillKey = doc.title.lowercased().trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "  ", with: " ")
        var titleZh: String
        var titleLines = [first]
        var item: ItemEntry? = nil
        if let z = g.tipSkills[skillKey] { titleZh = z }
        else if let i = ItemDB.shared.title(doc.title) { titleZh = i.zh; item = i.entry }
        // 名字太长折成两行（“One-Handed Blunt Weapon Attack” / “Scroll: Intermediate”）
        else if ls.count > 1, ls[1].minY - first.maxY < (first.maxY - first.minY), let i = ItemDB.shared.title(doc.title + " " + clean(ls[1].text)) {
            titleZh = i.zh; item = i.entry; titleLines.append(ls[1])
        }
        // 公开版：认错一两个字母的按名单纠正，有自己翻的中文名就用
        else if let z = ItemNames.zh(ItemNames.fix(doc.title) ?? doc.title) { titleZh = z }
        else { titleZh = await plain(ItemNames.fix(doc.title) ?? doc.title) }
        var tp = piece(.title, titleZh, titleLines)
        // 名称前面的小圆点被认成 “*”“•”：覆盖从名字开始，圆点露出来
        let raw = first.text.trimmingCharacters(in: .whitespaces)
        let lead = raw.prefix { !$0.isLetter && !$0.isNumber }.count
        if lead > 0, !raw.isEmpty { tp.minX += (first.maxX - first.minX) * Double(lead) / Double(raw.count) }
        var out = [tp]
        let jobKeys = Set(g.tipJobs.keys)
        let labelsByLength = g.tipLabels.keys.sorted { $0.count > $1.count }
        var descLines: [OCRLine] = []
        var reqRows: [(Int, OCRLine)] = []
        func statZh(_ label: String, _ v: String) async -> String {
            let zl = g.tipLabels[label] == nil ? await plain(label) : g.tipLabels[label]!
            // “+2” 在花背景上会认成 “+¿”“+Ż”
            let fv = fixDigits(v.replacingOccurrences(of: "[¿Żż]", with: "2", options: .regularExpression))
            let value: String
            if let x = g.tipValues[v] ?? fuzzyValue(v, g.tipValues) { value = x }
            else if fv != v { value = fv }
            else if v.allSatisfy({ $0.isNumber || "+-%., /:".contains($0) }) { value = v }
            else if v.count <= 3 {
                // 很短的值是数字被认成了字母（“s”“o”“C”），绝不交给系统翻译（会翻成“字母C”）；能对应的改回数字，否则原样
                let m: [Character: Character] = ["o": "0", "O": "0", "s": "5", "S": "5", "l": "1", "I": "1", "|": "1", "z": "2", "Z": "2",
                                                 "b": "6", "G": "6", "B": "8", "g": "9", "q": "9", "T": "7", "A": "4", "¿": "2", "Ż": "2", "ż": "2"]
                let f = String(v.map { m[$0] ?? $0 })
                value = f.allSatisfy({ $0.isNumber || "+-".contains($0) }) ? f : v
            }
            else { value = await plain(v) }
            return "\(zl)：\(value)"
        }
        for l in ls.dropFirst(titleLines.count) {
            let t = clean(l.text)
            // 说明开始后一般都是说明；但已知属性名开头的行（某一行数值认错，比如 “+8” 认成 “+?”，导致提前进入说明）仍按属性处理
            if !descLines.isEmpty {
                if let (key, value) = matchLabel(t, labels: labelsByLength), !key.hasPrefix("REQ"), descLines.allSatisfy({ matchLabel(clean($0.text), labels: labelsByLength) != nil || $0.text.contains(":") }) {
                    for d in descLines { if let (k2, v2) = matchLabel(clean(d.text), labels: labelsByLength) { out.append(piece(.stat, await statZh(k2, v2), [d])) } else if let c = clean(d.text).firstIndex(of: ":") { let dt = clean(d.text); out.append(piece(.stat, await statZh(String(dt[..<c]).trimmingCharacters(in: .whitespaces), String(dt[dt.index(after: c)...]).trimmingCharacters(in: .whitespaces)), [d])) } }
                    descLines = []
                    out.append(piece(.stat, await statZh(key, value), [l])); continue
                }
                descLines.append(l); continue
            }
            if let f = g.tipFlags[t] ?? g.tipFlags[t.trimmingCharacters(in: .punctuationCharacters)] { out.append(piece(.flag, f, [l])); continue }
            let words = t.split(whereSeparator: { !$0.isLetter }).map { $0.uppercased() }
            if !words.isEmpty, words.allSatisfy({ jobKeys.contains($0) }) {
                // 职业行：游戏把五个职业画在固定位置（占框宽的比例，实测），能用的橙色、不能用的灰色（灰字识别不出来）。
                // 按固定位置逐个写中文，能用的橙色、其余灰色，整行都换成中文
                let have = Set(words)
                let jobs = ["BEGINNER", "WARRIOR", "MAGICIAN", "BOWMAN", "THIEF"]
                // 中文按五等分排开、每格居中（游戏原来的位置按英文长短排，换成中文后看起来不齐）
                for (k, j) in jobs.enumerated() {
                    var p = piece(have.contains(j) ? .jobs : .gray, g.tipJobs[j] ?? j, [l])
                    p.minX = 0.03 + 0.94 * Double(k) / 5; p.maxX = 0.03 + 0.94 * Double(k + 1) / 5
                    out.append(p)
                }
                continue
            }
            if let (key, value) = matchLabel(t, labels: labelsByLength) {
                if key.hasPrefix("REQ") { reqRows.append((Self.reqOrder.firstIndex(of: key) ?? -1, l)) }
                out.append(piece(key.hasPrefix("REQ") ? .req : .stat, await statZh(key, value), [l])); continue
            }
            if let colon = t.firstIndex(of: ":") {
                let label = t[..<colon].trimmingCharacters(in: .whitespaces)
                let value = t[t.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                let numeric = value.range(of: "^[+-]?\\s*[0-9]", options: .regularExpression) != nil
                if label.count <= 24, label.split(separator: " ").count <= 4, numeric || g.tipValues[value] != nil, value.count <= 30 {
                    out.append(piece(.stat, await statZh(label, value), [l])); continue
                }
            }
            descLines.append(l)
        }
        // 灰色的需求行（数值 0，识别不出来）：六行顺序固定，用两行已认出的需求算出行距，把缺的行补成灰色中文
        let known = reqRows.filter { $0.0 >= 0 }.sorted { $0.0 < $1.0 }
        // 只有装备才有六行需求（框里有职业那一行）；飞镖、药水只有“等级”一行，别凭空补出“力量：0”这些
        let isEquip = out.contains { $0.kind == .jobs || ($0.kind == .gray && !$0.zh.contains("：")) }
        if let a = known.first, let b = known.last, b.0 > a.0 || (boxHeightPt != nil && isEquip) {
            let pitch = b.0 > a.0 ? (b.1.minY - a.1.minY) / Double(b.0 - a.0) : 12 / boxHeightPt!
            let h = a.1.maxY - a.1.minY
            let have = Set(known.map(\.0))
            let x0 = known.map(\.1.minX).min()!, x1 = known.map(\.1.maxX).max()!
            for k in 0..<Self.reqOrder.count where !have.contains(k) {
                let y = a.1.minY + Double(k - a.0) * pitch
                guard y >= 0, y + h <= 1 else { continue }
                out.append(TooltipPiece(kind: .gray, zh: "\(g.tipLabels[Self.reqOrder[k]] ?? Self.reqOrder[k])：0", minX: x0, maxX: x1, minY: y, maxY: y + h))
            }
        }
        // 需求一行都没认出来（全是灰色 0）：按职业行往上推（最后一行“人气”在职业行上方 20 点，往上每行 12 点），横向位置约在框宽 39%~62%
        if known.isEmpty, let bh = boxHeightPt, let job = out.first(where: { $0.kind == .jobs || ($0.kind == .gray && !$0.zh.contains("：")) }) {
            let h = 9 / bh
            for k in 0..<Self.reqOrder.count {
                let y = job.minY - (20 + Double(5 - k) * 12) / bh
                guard y >= 0 else { continue }
                out.append(TooltipPiece(kind: .gray, zh: "\(g.tipLabels[Self.reqOrder[k]] ?? Self.reqOrder[k])：0", minX: 0.39, maxX: 0.72, minY: y, maxY: y + h))
            }
        }
        // 说明文字：按段（空一行或特殊开头另起一段）整段翻译，盖住这一段所有行
        if !descLines.isEmpty, let i = item, let d = ItemDB.shared.desc(i, ocr: descLines.map { clean($0.text) }.joined(separator: " ")) {
            // 物品表里有这段说明：整段用表里的
            out.append(piece(.desc, await itemDescZh(d), descLines))
        } else if !descLines.isEmpty {
            let hs = descLines.map { $0.maxY - $0.minY }.sorted()
            let lineH = hs[hs.count / 2]
            var group: [OCRLine] = []
            func flush() async {
                guard !group.isEmpty else { return }
                let paras = TooltipDoc.paragraphs(group.map { OCRLine(text: clean($0.text), minX: $0.minX, maxX: $0.maxX, minY: $0.minY, maxY: $0.maxY) })
                var zs: [String] = []
                for p in paras { zs.append(await plain(p)) }
                out.append(piece(.desc, zs.joined(separator: "\n"), group))
                group = []
            }
            for l in descLines {
                if let last = group.last, l.minY - last.maxY > lineH * 0.8 { await flush() }
                group.append(l)
            }
            await flush()
        }
        return out
    }
}

extension TooltipDetector {
    /// 把说明框一块区域里的文字“擦掉”：文字像素（不是框内深蓝的点，再往外扩 1 像素盖住描边）
    /// 用同一列上下最近的框内像素按距离补色。半透明框背后透出来的画面纹理照样保留，看起来就是没有字的说明框。
    /// 用原图的色彩空间读写，补出来的颜色和原画面一致。
    public static func eraseText(_ img: CGImage, whole: Bool = false) -> CGImage? {
        let w = img.width, h = img.height
        guard w > 2, h > 2 else { return nil }
        let cs = img.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        var text = [Bool](repeating: false, count: w * h)
        // whole：除了最上、最下各一行，整块都重新补色（职业行的黑色小底框颜色和框底很像，按颜色分不出来）
        if whole {
            for y in 1..<(h - 1) { for x in 0..<w { text[y * w + x] = true } }
        }
        for i in 0..<(w * h) where !whole {
            let r = Int(buf[i * 4]), g = Int(buf[i * 4 + 1]), b = Int(buf[i * 4 + 2])
            text[i] = !isInsideBox(r, g, b)
        }
        // 往外扩 1 像素（字边上的半透明过渡色）
        var mask = text
        for y in 0..<h { for x in 0..<w where text[y * w + x] && !whole {
            for dy in -1...1 { for dx in -1...1 {
                let xx = x + dx, yy = y + dy
                if xx >= 0, yy >= 0, xx < w, yy < h { mask[yy * w + xx] = true }
            } }
        } }
        let orig = buf
        for x in 0..<w {
            var y = 0
            while y < h {
                guard mask[y * w + x] else { y += 1; continue }
                var e = y
                while e < h, mask[e * w + x] { e += 1 }
                let top = y - 1, bot = e            // 上下最近的框内像素（可能越界）
                // 取左右 ±3 列的平均（只用没被擦的点），每列单独取会留下细细的竖线
                func avg(_ row: Int, _ c: Int) -> Double? {
                    guard row >= 0, row < h else { return nil }
                    var sum = 0, n = 0
                    for xx in max(0, x - 3)...min(w - 1, x + 3) where !mask[row * w + xx] || xx == x { sum += Int(orig[(row * w + xx) * 4 + c]); n += 1 }
                    return n > 0 ? Double(sum) / Double(n) : nil
                }
                for yy in y..<e {
                    for c in 0..<3 {
                        let a = avg(top, c)
                        let b = avg(bot, c)
                        let v: Double
                        switch (a, b) {
                        case let (a?, b?): let t = Double(yy - top) / Double(bot - top); v = a + (b - a) * t
                        case let (a?, nil): v = a
                        case let (nil, b?): v = b
                        default: v = Double(buf[(yy * w + x) * 4 + c])
                        }
                        buf[(yy * w + x) * 4 + c] = UInt8(max(0, min(255, v.rounded())))
                    }
                    buf[(yy * w + x) * 4 + 3] = 255
                }
                y = e
            }
        }
        _ = ctx
        // 用改好的数据重新生成图片（buf 被改过，不能再用 ctx 里原来那块内存）
        guard let out = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        return out.makeImage()
    }
}

extension TooltipDetector {
    /// 把找到的框收紧到真正的说明框：上下左右逐行 / 逐列看“像框里”的点占多少，不到 6 成的边缘行列去掉
    /// （找框时可能把上面深色的窗口、旁边的画面一起框进来，并排的两个框位置就会对不齐）
    public static func tighten(_ img: CGImage, _ rect: CGRect, scale: CGFloat = 2) -> CGRect {
        guard let (buf, w, h) = rgba(img) else { return rect }
        // 按边框找到的已经精确，不再收（框背后是白条、状态栏时会收错）
        if let exact = rings(buf: buf, w: w, h: h, scale: scale).first(where: {
            abs($0.minX - rect.minX) <= 6 && abs($0.minY - rect.minY) <= 6 && abs($0.maxX - rect.maxX) <= 6 && abs($0.maxY - rect.maxY) <= 6 }) { return exact }
        let r = rect.integral.intersection(CGRect(x: 0, y: 0, width: w, height: h))
        guard r.width > 20, r.height > 20 else { return rect }
        @inline(__always) func ok(_ x: Int, _ y: Int) -> Bool {
            let i = (y * w + x) * 4
            let R = Int(buf[i]), G = Int(buf[i + 1]), B = Int(buf[i + 2])
            let lum = (R * 299 + G * 587 + B * 114) / 1000
            return isInsideBox(R, G, B) || lum >= 170 || (R >= 190 && B <= 110)
        }
        let x0 = Int(r.minX), x1 = Int(r.maxX), y0 = Int(r.minY), y1 = Int(r.maxY)
        func rowOK(_ y: Int) -> Bool {
            var n = 0, t = 0
            for x in stride(from: x0, to: x1, by: 2) { t += 1; if ok(x, y) { n += 1 } }
            return n * 10 >= t * 6
        }
        func colOK(_ x: Int, _ ya: Int, _ yb: Int) -> Bool {
            var n = 0, t = 0
            for y in stride(from: ya, to: yb, by: 2) { t += 1; if ok(x, y) { n += 1 } }
            return n * 10 >= t * 6
        }
        var top = y0, bot = y1 - 1
        while top < bot, !rowOK(top) { top += 1 }
        while bot > top, !rowOK(bot) { bot -= 1 }
        var left = x0, right = x1 - 1
        while left < right, !colOK(left, top, bot) { left += 1 }
        while right > left, !colOK(right, top, bot) { right -= 1 }
        let out = CGRect(x: left, y: top, width: right - left + 1, height: bot - top + 1)
        // 收得太多（框里大片亮色图标等）就不收
        return out.width >= rect.width * 0.6 && out.height >= rect.height * 0.5 ? out : rect
    }
}

extension TooltipDetector {
    public static func rgbaPublic(_ img: CGImage) -> ([UInt8], Int, Int)? { rgba(img).map { ($0.0, $0.1, $0.2) } }
}

extension TooltipDetector {
    /// 一块区域里红字的点数（需求没达到时游戏用红字，实测 (255,0,102) 左右）
    public static func redPixels(_ img: CGImage) -> Int {
        guard let (buf, w, h) = rgba(img) else { return 0 }
        var n = 0
        for i in stride(from: 0, to: w * h * 4, by: 4) where buf[i] >= 190 && buf[i + 1] <= 90 && buf[i + 2] <= 150 { n += 1 }
        return n
    }
    /// 这一行主要是红字（红字点数比白字多）。“+5 (6 -1)” 这种只有一小段红的不算
    public static func mostlyRed(_ img: CGImage) -> Bool {
        guard let (buf, w, h) = rgba(img) else { return false }
        var red = 0, white = 0
        for i in stride(from: 0, to: w * h * 4, by: 4) {
            let r = Int(buf[i]), g = Int(buf[i + 1]), b = Int(buf[i + 2])
            if r >= 190 && g <= 90 && b <= 150 { red += 1 } else if r >= 190 && g >= 190 && b >= 190 { white += 1 }
        }
        return red >= 12 && red > white
    }
}

extension TooltipDetector {
    /// 一块区域里文字的颜色：不是框底的点里，出现最多的那种（按 16 级量化，只算够亮或够鲜艳的点）。没有字返回 nil
    public static func textColor(_ img: CGImage) -> (r: Int, g: Int, b: Int)? {
        guard let (buf, w, h) = rgba(img) else { return nil }
        var count: [Int: Int] = [:]
        for i in stride(from: 0, to: w * h * 4, by: 4) {
            let r = Int(buf[i]), g = Int(buf[i + 1]), b = Int(buf[i + 2])
            if isInsideBox(r, g, b) { continue }
            let mx = max(r, g, b), mn = min(r, g, b)
            guard mx >= 150 || mx - mn >= 80 else { continue }
            count[(r >> 4) << 8 | (g >> 4) << 4 | (b >> 4), default: 0] += 1
        }
        guard let best = count.max(by: { $0.value < $1.value }), best.value >= 6 else { return nil }
        let k = best.key
        return ((k >> 8 & 15) * 16 + 8, (k >> 4 & 15) * 16 + 8, (k & 15) * 16 + 8)
    }
}

extension TooltipDetector {
    /// 宽框中间（40%~60%）有没有一道竖缝：某一列里像框底的点不到一半。有就返回那一列的 x（截图像素），没有返回 nil
    public static func gapColumn(_ img: CGImage, _ rect: CGRect) -> CGFloat? {
        guard let (buf, w, h) = rgba(img) else { return nil }
        let r = rect.integral.intersection(CGRect(x: 0, y: 0, width: w, height: h))
        guard r.width > 20, r.height > 20 else { return nil }
        var best: (x: Int, f: Double)? = nil
        let y0 = Int(r.minY) + Int(r.height * 0.1), y1 = Int(r.maxY) - Int(r.height * 0.1)
        for x in Int(r.minX + r.width * 0.4)..<Int(r.minX + r.width * 0.6) {
            var inside = 0, n = 0
            for y in stride(from: y0, to: y1, by: 2) {
                let i = (y * w + x) * 4
                if isInsideBox(Int(buf[i]), Int(buf[i + 1]), Int(buf[i + 2])) { inside += 1 }
                n += 1
            }
            let f = Double(inside) / Double(max(1, n))
            if best == nil || f < best!.f { best = (x, f) }
        }
        guard let b = best, b.f < 0.5 else { return nil }
        return CGFloat(b.x)
    }
}

extension TooltipDetector {
    /// 一块区域里和 base 颜色明显不同的字的颜色（“(5 +1)” 里蓝色的 “+1”）：只数与 base 差得多的字点，取最多的那种。不够多返回 nil
    public static func accentColor(_ img: CGImage, base: (r: Int, g: Int, b: Int)) -> (r: Int, g: Int, b: Int)? {
        guard let (buf, w, h) = rgba(img) else { return nil }
        var count: [Int: Int] = [:]
        for i in stride(from: 0, to: w * h * 4, by: 4) {
            let r = Int(buf[i]), g = Int(buf[i + 1]), b = Int(buf[i + 2])
            if isInsideBox(r, g, b) { continue }
            let mx = max(r, g, b), mn = min(r, g, b)
            guard mx >= 150, mx - mn >= 60 else { continue }          // 要鲜艳的颜色（白字、灰字不算）
            guard abs(r - base.r) + abs(g - base.g) + abs(b - base.b) > 150 else { continue }
            count[(r >> 4) << 8 | (g >> 4) << 4 | (b >> 4), default: 0] += 1
        }
        guard let best = count.max(by: { $0.value < $1.value }), best.value >= 6 else { return nil }
        let k = best.key
        return ((k >> 8 & 15) * 16 + 8, (k >> 4 & 15) * 16 + 8, (k & 15) * 16 + 8)
    }
}
