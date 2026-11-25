// 大图的小地图会滚动：拿整张小地图（Assets/MiniMaps.json，游戏素材，只自用）和画面里露出的那一段比，算滚到了哪里。
// 没有这个文件时退回用绿点、蓝圈对位。
import CoreGraphics
import Foundation
import ImageIO

public final class MiniMapImages: @unchecked Sendable {
    public static let shared = MiniMapImages()
    struct Ref { let w: Int, h: Int; let rows: [[(x: Int, c: (Int, Int, Int))]] }
    private let raw: [String: Data]
    private let lock = NSLock()
    private var cache: [Int: Ref] = [:], order: [Int] = []
    private init() {
        let u = GameData.url("MiniMaps") ?? Bundle.main.url(forResource: "MiniMaps", withExtension: "json") ?? URL(fileURLWithPath: "Assets/MiniMaps.json")
        raw = (try? Data(contentsOf: u)).flatMap { try? JSONDecoder().decode([String: Data].self, from: $0) } ?? [:]
    }
    func ref(_ id: Int) -> Ref? {
        lock.lock(); defer { lock.unlock() }
        if let r = cache[id] { return r }
        guard let d = raw[String(id)], let s = CGImageSourceCreateWithData(d as CFData, nil), let im = CGImageSourceCreateImageAtIndex(s, 0, nil) else { return nil }
        let w = im.width, h = im.height
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        buf.withUnsafeMutableBytes { p in
            CGContext(data: p.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.draw(im, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        // 只用不透明的像素（透明的地方会透出游戏画面）
        var rows = (0..<h).map { y in (0..<w).compactMap { x -> (x: Int, c: (Int, Int, Int))? in
            let i = (y * w + x) * 4
            return buf[i + 3] == 255 ? (x, (Int(buf[i]), Int(buf[i + 1]), Int(buf[i + 2]))) : nil
        } }
        // 黑乎乎的图（树洞）哪里都像：亮的像素够多就只比亮的
        let lit = rows.map { $0.filter { max($0.c.0, $0.c.1, $0.c.2) >= 40 } }
        if lit.reduce(0, { $0 + $1.count }) >= 400 { rows = lit }
        let r = Ref(w: w, h: h, rows: rows)
        cache[id] = r; order.append(id)
        if order.count > 6 { cache[order.removeFirst()] = nil }
        return r
    }
}

extension MiniMap {
    /// 滚动量（小地图像素）：画面左上角对应整张图的哪里。分不清返回 nil
    static func scroll(_ p: Pix, _ c: CGRect, _ s: Int, map: NavMap) -> (Double, Double)? {
        guard let r = MiniMapImages.shared.ref(map.id) else { return nil }
        let vw = Int(c.width) / s, vh = Int(c.height) / s
        guard vw > 20, vh > 20 else { return nil }
        var v = [(Int, Int, Int)](repeating: (0, 0, 0), count: vw * vh)
        for y in 0..<vh { for x in 0..<vw { v[y * vw + x] = p.rgb(Int(c.minX) + x * s, Int(c.minY) + y * s) } }
        // 比画面小的方向居中（差一两个像素），大的方向逐个试
        let xs = r.w > vw ? Array(0...(r.w - vw)) : Array(((r.w - vw) / 2 - 2)...((r.w - vw) / 2 + 2))
        let ys = r.h > vh ? Array(0...(r.h - vh)) : Array(((r.h - vh) / 2 - 2)...((r.h - vh) / 2 + 2))
        let step = xs.count * ys.count > 4000 ? 3 : 1       // 两个方向都滚动时少看几个点
        func score(_ ox: Int, _ oy: Int, _ step: Int) -> (Double, Int) {
            var n = 0, k = 0, t = 0
            for y in max(0, oy)..<min(r.h, oy + vh) {
                for e in r.rows[y] {
                    let x = e.x - ox
                    guard x >= 0, x < vw else { continue }
                    t += 1
                    if step > 1, t % step != 0 { continue }
                    n += 1
                    let q = v[(y - oy) * vw + x]
                    if abs(q.0 - e.c.0) < 18, abs(q.1 - e.c.1) < 18, abs(q.2 - e.c.2) < 18 { k += 1 }
                }
            }
            return (n > 0 ? Double(k) / Double(n) : 0, n)
        }
        var best = (0.0, 0, 0), second = 0.0
        for oy in ys { for ox in xs {
            let (f, n) = score(ox, oy, step)
            guard n >= 100 / step else { continue }
            if f > best.0 {
                if abs(best.1 - ox) > 2 || abs(best.2 - oy) > 2 { second = max(second, best.0) }
                best = (f, ox, oy)
            } else if abs(best.1 - ox) > 2 || abs(best.2 - oy) > 2 { second = max(second, f) }
        } }
        guard best.0 >= 0.6, best.0 - second >= 0.12 else { return nil }
        return (Double(best.1), Double(best.2))
    }
}
