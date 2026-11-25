import SwiftUI

/// 经验条：照游戏状态栏的质感（浅灰圆角槽 + 黄绿色填充 + 上半截高光），代码画。
/// 刻度很淡，只在上下各露一小截，不把条切成一格一格。
struct ExpBar: View {
    let pct: Double
    var body: some View {
        Canvas { c, size in
            func rgb(_ r: Double, _ g: Double, _ b: Double) -> Color { Color(red: r / 255, green: g / 255, blue: b / 255) }
            func vertical(_ stops: [(Double, Color)], _ r: CGRect) -> GraphicsContext.Shading {
                .linearGradient(Gradient(stops: stops.map { .init(color: $0.1, location: $0.0) }),
                                startPoint: CGPoint(x: 0, y: r.minY), endPoint: CGPoint(x: 0, y: r.maxY))
            }
            // 外框：浅色亮边 → 深色描边 → 槽
            let box = CGRect(origin: .zero, size: size)
            c.fill(Path(roundedRect: box, cornerRadius: 5), with: vertical([(0, rgb(112, 120, 128)), (1, rgb(176, 186, 194))], box))
            let dark = box.insetBy(dx: 1, dy: 1)
            c.fill(Path(roundedRect: dark, cornerRadius: 4), with: .color(rgb(34, 38, 44)))
            let slot = dark.insetBy(dx: 1, dy: 1)
            c.clip(to: Path(roundedRect: slot, cornerRadius: 3))
            c.fill(Path(slot), with: vertical([(0, rgb(142, 142, 142)), (0.2, rgb(202, 202, 202)), (0.5, rgb(186, 186, 186)), (0.52, rgb(164, 164, 164)), (1, rgb(146, 146, 146))], slot))
            let w = pct <= 0 ? 0 : max(2, slot.width * min(1, pct / 100))
            let bar = CGRect(x: slot.minX, y: slot.minY, width: w, height: slot.height)
            c.fill(Path(bar), with: vertical([(0, rgb(196, 214, 40)), (0.2, rgb(226, 242, 70)), (0.5, rgb(204, 226, 20)), (0.52, rgb(178, 206, 0)), (1, rgb(150, 178, 0))], bar))
            for k in 1..<10 {
                let x = (slot.minX + slot.width * CGFloat(k) / 10).rounded()
                for y in [slot.minY, slot.maxY - 2] {
                    c.fill(Path(CGRect(x: x, y: y, width: 1, height: 2)), with: .color(.black.opacity(0.22)))
                }
            }
            // 填充的末端：一道暗边，和灰槽分得清楚
            if w > 0, pct < 100 {
                c.fill(Path(CGRect(x: bar.maxX, y: slot.minY, width: 1, height: slot.height)), with: .color(rgb(100, 112, 40).opacity(0.6)))
            }
            c.fill(Path(CGRect(x: slot.minX, y: slot.minY, width: slot.width, height: 1)), with: .color(.black.opacity(0.18)))
        }
        .frame(height: 17)
    }
}
