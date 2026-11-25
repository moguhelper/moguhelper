// 没有资料表时，从屏幕上的文字看任务找谁接。
import Foundation

public enum TipPlan {
    /// 可接页写的 “! Talk to NPC Roger”
    public static func starter(_ lines: [String]) -> String? {
        for l in lines {
            guard let r = l.range(of: "Talk to NPC\\s+", options: [.regularExpression, .caseInsensitive]) else { continue }
            let n = l[r.upperBound...].trimmingCharacters(in: CharacterSet(charactersIn: " .!"))
            if n.count >= 2, n.count <= 30 { return n }
        }
        return nil
    }
}
