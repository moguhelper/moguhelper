// 自己捡到东西的地方：物品英文名 → 地图（街道|地名）→ 捡到过几次。只记自己看到的，不含任何现成掉落表
import Foundation

public struct FindLog: Codable, Sendable, Equatable {
    public var items: [String: [String: Int]] = [:]
    public init() {}
    public mutating func add(_ item: String, map: String, n: Int) { items[item, default: [:]][map, default: 0] += n }
    /// 捡到最多的图
    public func best(_ item: String) -> String? { items[item]?.max { ($0.value, $1.key) < ($1.value, $0.key) }?.key }
    /// 数量从 old 变成 new，要不要记：涨了、涨得不离谱，而且在这张图已经待了一会儿（刚换图的可能是上一张捡的）
    public static func gained(old: [Int]?, new: [Int], secondsInMap: Double) -> Int? {
        guard let o = old?.first, let n = new.first, n > o, n - o <= 10, secondsInMap >= 12 else { return nil }
        return n - o
    }
}
extension NavDB {
    /// 去某张图
    public func route(from: Int, map to: Int, item: String) -> NavRoute? {
        guard maps[from] != nil, maps[to] != nil else { return nil }
        if from == to {
            var r = NavRoute(steps: ["这张图捡到过 \(itemName(item))"], arrived: true, uncertain: false, kind: .mob)
            r.goalMap = to
            return r
        }
        guard var (r, _) = walk(from: from, goals: [to: 0]) else { return nil }
        r.steps.append("在 \(mapName(to)) 捡到过 \(itemName(item))")
        return r
    }
    public func mapKey(_ id: Int) -> String? { maps[id].map { $0.street + "|" + $0.name } }
    public func mapId(key: String) -> Int? { maps.values.first { $0.street + "|" + $0.name == key }?.id }
}

/// 自己走过的一个门在地图上的位置（只给自己的导航用，坐标按现有地图表换算，不放进 mymaps.json）
public struct WalkedLink: Codable, Sendable, Equatable {
    public var from: Int, to: Int, x: Double, y: Double
    /// 离开时就站在蓝圈上：表里本来就通的，走一次就信
    public var door: Bool? = nil
    public init(from: Int, to: Int, x: Double, y: Double, door: Bool? = nil) { self.door = door; self.from = from; self.to = to; self.x = x; self.y = y }
}
