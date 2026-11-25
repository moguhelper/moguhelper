// 物品图标（Assets/ItemIcons.json，游戏素材，只自用，不进 git、不放分发版；没有这个文件时只显示文字）。
// 还能按图标颜色认出背包、快捷栏里是什么东西。
import Foundation

public final class ItemIcons: @unchecked Sendable {
    struct Entry: Decodable { var png: Data, color: [Int], cat: String }
    private let items: [String: Entry]
    public static let shared = ItemIcons()
    private init() {
        let u = GameData.url("ItemIcons") ?? Bundle.main.url(forResource: "ItemIcons", withExtension: "json") ?? URL(fileURLWithPath: "Assets/ItemIcons.json")
        items = (try? Data(contentsOf: u)).flatMap { try? JSONDecoder().decode([String: Entry].self, from: $0) } ?? [:]
    }
    public var count: Int { items.count }
    public func png(_ name: String) -> Data? { items[name]?.png }
    /// Use 页的东西按图标颜色认名字；两样一样像就不猜
    public func useName(color c: [Int]) -> String? {
        guard c.count == 3 else { return nil }
        let d = items.filter { $0.value.cat == "Use" && $0.value.color.count == 3 }
            .map { ($0.key, zip($0.value.color, c).map { abs($0 - $1) }.max()!) }.filter { $0.1 <= 8 }.sorted { ($0.1, $0.0) < ($1.1, $1.0) }
        guard let a = d.first else { return nil }
        if d.count > 1, d[1].1 - a.1 < 2 { return nil }
        return a.0
    }
}
