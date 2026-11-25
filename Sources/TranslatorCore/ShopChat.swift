// 个人商店里的聊天框（右边的白框）：找位置、整理识别出的行。只处理截图像素，不接触游戏。
import Foundation
import CoreGraphics

public enum ShopChatDetector {
    /// 在低分辨率整窗截图里找商店聊天框的白色区域（像素，左上原点）。
    /// 特征（实测，单位点）：白色内区约 258×212，上、左是两点宽的浅蓝灰边（约 (177,203,224)、(141,168,188)），
    /// 往下约 20 点是黑边白底的输入框（左边对齐，约 216 点宽）。
    public static func find(in img: CGImage, scale s: CGFloat) -> CGRect? {
        guard let (buf, w, h) = TooltipDetector.rgba(img) else { return nil }
        @inline(__always) func px(_ x: Int, _ y: Int) -> (Int, Int, Int) {
            let i = (y * w + x) * 4
            return (Int(buf[i]), Int(buf[i + 1]), Int(buf[i + 2]))
        }
        @inline(__always) func white(_ x: Int, _ y: Int) -> Bool { let p = px(x, y); return p.0 >= 250 && p.1 >= 250 && p.2 >= 250 }
        @inline(__always) func border(_ x: Int, _ y: Int) -> Bool {
            let p = px(x, y)
            return p.0 >= 115 && p.0 <= 215 && p.2 - p.0 >= 18 && p.1 - p.0 >= 8 && p.2 - p.1 >= 4
        }
        @inline(__always) func dark(_ x: Int, _ y: Int) -> Bool { let p = px(x, y); return p.0 + p.1 + p.2 < 330 }
        let pt = { (v: CGFloat) in Int((v * s).rounded()) }
        let minW = pt(240), maxW = pt(275)
        for y in 1..<max(2, h - pt(150)) {
            var x = 1
            while x < w - minW {
                guard border(x, y), white(x, y + pt(3)) else { x += 1; continue }
                var n = 0
                while x + n < w, border(x + n, y), white(x + n, y + pt(3)) { n += 1 }
                defer { x += max(n, 1) }
                guard n >= minW, n <= maxW else { continue }
                // 最上面一行字约 10 点以下，左边留白约 5 点：沿留白往下量到底
                let cx = x + pt(3)
                let top = y + pt(3)
                var bottom = top, gap = 0
                var yy = top
                while yy < h, gap <= pt(40) {       // 鼠标可能压住一小段
                    if white(cx, yy) { bottom = yy; gap = 0 } else { gap += 1 }
                    if border(cx, yy), border(cx + pt(40), yy), border(x + n - pt(6), yy) { break }
                    yy += 1
                }
                guard bottom - top >= pt(190), bottom - top <= pt(235) else { continue }
                // 下面的输入框：黑色上边线
                let hasInput = ((bottom + pt(6))...(bottom + pt(34))).contains { r in
                    guard r < h else { return false }
                    var k = 0
                    for c in stride(from: x + pt(6), to: x + pt(200), by: 2) where dark(c, r) { k += 2 }
                    return k >= pt(170)
                }
                guard hasInput else { continue }
                return CGRect(x: x, y: top - pt(1), width: n, height: bottom - top + pt(2))
            }
        }
        return nil
    }

    /// 进出提示：名字后面的中文，和英文后半截在画面上的宽度（点，固定）
    public static func presence(_ raw: String) -> (zh: String, tail: CGFloat)? {
        let n = Fuzzy.normalize(raw)
        for (en, zh, w, lim) in [("hasentered", "进来了", CGFloat(70.5), 2), ("haslefttheroom", "离开了", CGFloat(95.5), 3)] {
            guard n.count > en.count, n.count <= en.count + 18 else { continue }
            if Fuzzy.distance(Array(n.suffix(en.count)), Array(en), limit: lim) <= lim { return (zh, w) }
        }
        return nil
    }

    /// 一行字（白底）里名字的右边界，单位点；找不到返回 nil。名字保留原画面，就不会因为认错字母而写错。
    /// 游戏字体字母之间一般空 2～3 点，词与词之间空 4～5 点（实测），但数字 1 两边也空 4 点。
    /// 进出提示给出后半截宽度 tail 从右边量；聊天找后面跟着冒号的空隙；都不行取第一个词间空隙
    public static func nameEnd(_ line: CGImage, scale s: CGFloat, tail: CGFloat? = nil) -> CGFloat? {
        guard let (buf, w, h) = TooltipDetector.rgba(line) else { return nil }
        // 每段连续有字的列
        var runs: [(a: CGFloat, b: CGFloat)] = []
        var start = -1
        for x in 0...w {
            var ink = false
            if x < w { for y in 0..<h where !ink { let i = (y * w + x) * 4; ink = min(buf[i], min(buf[i + 1], buf[i + 2])) < 160 } }
            if ink, start < 0 { start = x }
            if !ink, start >= 0 { runs.append((CGFloat(start) / s, CGFloat(x) / s)); start = -1 }
        }
        guard runs.count >= 2 else { return nil }
        let gaps = (0..<(runs.count - 1)).filter { runs[$0 + 1].a - runs[$0].b >= 3.6 }
        if let t = tail, let end = runs.last?.b, let k = gaps.min(by: { abs(end - runs[$0].b - t) < abs(end - runs[$1].b - t) }), abs(end - runs[k].b - t) <= 2 { return runs[k].b }
        if tail == nil, let k = gaps.first(where: { $0 + 2 < runs.count && runs[$0 + 1].b - runs[$0 + 1].a <= 2.2 && runs[$0 + 2].a - runs[$0 + 1].b >= 3.6 }) { return runs[k].b }
        return gaps.first.map { runs[$0].b }
    }

    /// 这一行字的顶端（点）：在整块聊天框截图里，离 midY（点）最近的一段连续有字的行
    public static func inkTop(_ img: CGImage, midY: CGFloat, scale s: CGFloat) -> CGFloat? {
        guard let (buf, w, h) = TooltipDetector.rgba(img) else { return nil }
        var best: (top: Int, d: CGFloat)? = nil, start = -1
        let pad = Int(4 * s)
        for y in 0...h {
            var ink = false
            if y < h { for x in pad..<max(pad, w - pad) where !ink { let i = (y * w + x) * 4; ink = min(buf[i], min(buf[i + 1], buf[i + 2])) < 160 } }
            if ink, start < 0 { start = y }
            if !ink, start >= 0 {
                let d = abs(CGFloat(start + y) / 2 / s - midY)
                if CGFloat(y - start) >= 5 * s, d < (best?.d ?? 7) { best = (start, d) }
                start = -1
            }
        }
        return best.map { CGFloat($0.top) / s }
    }

    /// 聊天：名字后面的中文（“：内容”，名字由原画面显示）。不是“名字 : 内容”返回 nil
    public static func afterName(_ m: ChatMessage, zh: String) -> String? {
        guard m.kind == .chat, let n = m.speaker, zh.hasPrefix(n + "：") else { return nil }
        return String(zh.dropFirst(n.count))
    }

    /// 聊天框（点）→ 商店窗口盖住的范围：主窗口、下面的手续费提示
    public static func window(_ r: CGRect) -> [CGRect] {
        [CGRect(x: r.minX - 237, y: r.minY - 157, width: 523, height: r.height + 193),
         CGRect(x: r.minX - 237, y: r.maxY + 34, width: 230, height: 62)]
    }

    /// 物品说明框弹在聊天框上：框里有不少说明框的深蓝色（这时不能盖中文，会挡住说明框）
    public static func coveredByTooltip(_ img: CGImage, _ r: CGRect) -> Bool {
        guard let (buf, w, h) = TooltipDetector.rgba(img) else { return false }
        var n = 0, t = 0
        for y in stride(from: max(0, Int(r.minY)), to: min(h, Int(r.maxY)), by: 3) {
            for x in stride(from: max(0, Int(r.minX)), to: min(w, Int(r.maxX)), by: 3) {
                let i = (y * w + x) * 4
                t += 1
                if TooltipDetector.isTooltipTint(Int(buf[i]), Int(buf[i + 1]), Int(buf[i + 2])) { n += 1 }
            }
        }
        return t > 0 && n * 100 > t * 4
    }
}
