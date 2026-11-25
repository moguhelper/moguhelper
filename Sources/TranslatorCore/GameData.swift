// 游戏资料导入：用户自己准备的资料文件，存在本机，程序只负责读。不联网、不下载、不上传，公开版不带任何资料。
// 导入的内容当作不可信：每一项都查过才存；格式见 docs/资料格式.md。
import Foundation

public enum GameData {
    public static let names = ["Maps", "Mobs", "Quests", "QuestNames", "Items", "ItemSources", "ItemIcons", "MiniMaps"]
    public static let title = ["Maps": "地图、NPC、路线", "Mobs": "怪物", "Quests": "任务", "QuestNames": "任务里的名字", "Items": "物品", "ItemSources": "材料出处", "ItemIcons": "物品图标", "MiniMaps": "小地图"]
    public static let maxBytes = 20_000_000

    public enum Failure: Error, Equatable {
        case unknown, tooBig, bad(String)
        public var text: String {
            switch self {
            case .unknown: return "认不出是哪种资料（文件名要是 \(names.joined(separator: "、")) 加 .json）"
            case .tooBig: return "文件太大（最多 20 MB）"
            case .bad(let s): return "内容不对：\(s)"
            }
        }
    }

    /// 只有打包的程序才用导入的资料（命令行测试不受影响）；测试版用自己的目录
    public static let dir: URL? = {
        guard let id = Bundle.main.bundleIdentifier, id.hasPrefix("app.moguhelper") else { return nil }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(id == "app.moguhelper.test" ? "MoguHelper-test" : "MoguHelper").appendingPathComponent("游戏资料")
    }()
    /// 导入过这种资料就用它，没有就用程序自带的
    public static func url(_ name: String) -> URL? {
        guard let u = dir?.appendingPathComponent(name + ".json"), FileManager.default.fileExists(atPath: u.path) else { return nil }
        return u
    }
    public static var imported: [String] { names.filter { url($0) != nil } }
    public static func remove(_ name: String) { if let u = url(name) { try? FileManager.default.removeItem(at: u) } }

    /// 查过没问题才存。返回有多少条
    @discardableResult
    public static func add(_ file: URL, to folder: URL? = dir) throws -> (name: String, count: Int) {
        let name = file.deletingPathExtension().lastPathComponent
        guard names.contains(name), file.pathExtension.lowercased() == "json", let folder else { throw Failure.unknown }
        let v = try file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard v.isRegularFile == true else { throw Failure.unknown }
        guard (v.fileSize ?? .max) <= maxBytes else { throw Failure.tooBig }
        let d = try Data(contentsOf: file), n = try check(name, d)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try d.write(to: folder.appendingPathComponent(name + ".json"), options: .atomic)
        return (name, n)
    }

    // MARK: 检查

    public static func check(_ name: String, _ d: Data) throws -> Int {
        guard d.count <= maxBytes else { throw Failure.tooBig }
        guard let j = try? JSONSerialization.jsonObject(with: d) else { throw Failure.bad("不是 JSON") }
        func need(_ ok: Bool, _ why: String) throws { if !ok { throw Failure.bad(why) } }
        func str(_ v: Any?, _ n: Int = 100) -> Bool { (v as? String).map { !$0.isEmpty && $0.count <= n } ?? false }
        // JSON 的 true / false 也是 NSNumber，不算数
        func num(_ v: Any?, _ lim: Double) -> Double? {
            guard let x = v as? NSNumber, CFGetTypeID(x) != CFBooleanGetTypeID(), x.doubleValue.isFinite, abs(x.doubleValue) <= lim else { return nil }
            return x.doubleValue
        }
        func int(_ v: Any?, _ r: ClosedRange<Int> = 0...999_999_999) -> Bool { num(v, 1e9).map { $0 == $0.rounded() && r.contains(Int($0)) } ?? false }
        func optInt(_ v: Any?) -> Bool { v == nil || v is NSNull || int(v) }
        func xy(_ a: [Any], _ r: Range<Int>) -> Bool { a[r].allSatisfy { num($0, 100_000) != nil } }
        func strings(_ v: Any?, _ n: Int = 100) -> Bool { (v as? [Any])?.allSatisfy { str($0, n) } ?? false }
        func table(_ v: Any?) -> Bool { (v as? [String: Any])?.allSatisfy { str($0.key) && str($0.value) } ?? false }
        func png(_ v: Any?) -> Bool { (v as? String).flatMap { $0.count <= 2_000_000 ? Data(base64Encoded: $0) : nil }.map { $0.starts(with: [0x89, 0x50, 0x4E, 0x47]) } ?? false }
        func dict() throws -> [String: Any] { guard let o = j as? [String: Any] else { throw Failure.bad("最外层不是对象") }; return o }
        func rows(_ v: Any?, _ n: Int, _ lim: Int) -> [[Any]]? {
            guard let a = v as? [[Any]], a.count <= lim, a.allSatisfy({ $0.count == n }) else { return nil }
            return a
        }
        switch name {
        case "Maps":
            let o = try dict()
            guard let ms = o["maps"] as? [[String: Any]], ms.count <= 5000 else { throw Failure.bad("没有 maps") }
            var ids = Set<Int>()
            for m in ms {
                try need(int(m["id"]) && str(m["street"]) && str(m["name"]) && int(m["ret"]), "地图缺编号、街道、名字或 ret")
                let id = (m["id"] as! NSNumber).intValue
                try need(ids.insert(id).inserted, "地图编号 \(id) 重复")
                guard let b = m["box"] as? [Any], b.count == 4, xy(b, 0..<4), num(b[2], 1e5)! > num(b[0], 1e5)!, num(b[3], 1e5)! > num(b[1], 1e5)! else { throw Failure.bad("地图 \(id) 的 box") }
                guard let p = rows(m["portals"], 4, 100), p.allSatisfy({ int($0[0]) && xy($0, 1..<3) && int($0[3], -1...100) }) else { throw Failure.bad("地图 \(id) 的 portals") }
                guard let n = rows(m["npcs"], 3, 200), n.allSatisfy({ int($0[0]) && xy($0, 1..<3) }) else { throw Failure.bad("地图 \(id) 的 npcs") }
                guard let k = rows(m["mobs"], 2, 100), k.allSatisfy({ int($0[0]) && int($0[1], 0...1000) }) else { throw Failure.bad("地图 \(id) 的 mobs") }
                guard let mi = m["mini"] as? [Any], mi.isEmpty || mi.count == 2 && mi.allSatisfy({ (num($0, 5000) ?? 0) >= 1 }) else { throw Failure.bad("地图 \(id) 的 mini") }
                if let w = m["warps"], !(w is NSNull) {
                    guard let w = rows(w, 5, 100), w.allSatisfy({ xy($0, 0..<4) && int($0[4], -1...100) }) else { throw Failure.bad("地图 \(id) 的 warps") }
                }
            }
            for k in ["npcs", "mobs"] {
                guard let t = o[k] as? [String: Any], t.allSatisfy({ (Int($0.key).map { $0 >= 0 && $0 <= 999_999_999 } ?? false) && str($0.value) }) else { throw Failure.bad(k) }
            }
            guard let qs = o["quests"] as? [[String: Any]], qs.count <= 10_000 else { throw Failure.bad("quests") }
            for q in qs {
                try need(int(q["id"]) && ["start", "end", "level", "slevel", "meso", "exp"].allSatisfy { optInt(q[$0]) }, "任务的编号、NPC 或等级")
                for k in ["mobs", "items"] { guard let a = rows(q[k], 2, 100), a.allSatisfy({ str($0[0]) && int($0[1], 0...100_000) }) else { throw Failure.bad("任务的 \(k)") } }
            }
            return ms.count
        case "Mobs":
            let o = try dict()
            guard let m = o["mobs"] as? [String: [String: Any]], m.count <= 5000 else { throw Failure.bad("没有 mobs") }
            for (k, v) in m { try need(str(k) && ["lv", "hp", "exp"].allSatisfy { optInt(v[$0]) } && (v["png"] == nil || png(v["png"])), "怪物 \(k.prefix(40))") }
            guard let s = o["spawns"] as? [String: [String: Any]], s.count <= 5000 else { throw Failure.bad("没有 spawns") }
            for (k, v) in s {
                try need(Int(k) != nil && v.count <= 100, "刷新点的地图编号")
                for (n, p) in v { guard str(n), let a = rows(p, 2, 1000), a.allSatisfy({ xy($0, 0..<2) }) else { throw Failure.bad("地图 \(k.prefix(12)) 的刷新点") } }
            }
            return m.count
        case "Quests":
            guard let a = j as? [[String: Any]], a.count <= 10_000 else { throw Failure.bad("最外层不是数组") }
            for q in a {
                try need(int(q["id"]) && str(q["name"]) && q["area"] is String && strings(q["en"], 5000), "任务缺编号、名字或说明")
                if let z = q["zh"], !(z is NSNull) { guard let z = z as? [String], z.count == (q["en"] as! [Any]).count, z.allSatisfy({ $0.count <= 5000 }) else { throw Failure.bad("任务的 zh 和 en 要一一对应") } }
                if let z = q["zhName"], !(z is NSNull) { try need((z as? String).map { $0.count <= 100 } ?? false, "任务的 zhName") }
            }
            return a.count
        case "QuestNames":
            let o = try dict()
            try need(o["npc"] == nil || strings(o["npc"]), "npc")
            for k in ["mob", "item", "map", "titles"] { try need(o[k] == nil || table(o[k]), k) }
            return ["mob", "item", "map", "titles"].reduce((o["npc"] as? [Any])?.count ?? 0) { $0 + ((o[$1] as? [String: Any])?.count ?? 0) }
        case "Items":
            guard let a = try dict()["items"] as? [[String: Any]], a.count <= 50_000 else { throw Failure.bad("没有 items") }
            for i in a {
                try need(str(i["en"]) && (i["zh"] as? String).map { $0.count <= 100 } ?? false && (i["cat"] == nil || strings(i["cat"])), "物品缺 en 或 zh")
                if let d = i["desc"], !(d is NSNull) {
                    guard let d = d as? [[String: Any]], d.count <= 20, d.allSatisfy({ ($0["en"] as? [String]).map { $0.allSatisfy { $0.count <= 2000 } } == true && ($0["zh"] as? [String])?.count == ($0["en"] as? [String])?.count }) else { throw Failure.bad("物品说明的 en 和 zh 要一一对应") }
                }
            }
            return a.count
        case "ItemSources":
            guard let a = try dict()["items"] as? [String: Any], a.count <= 10_000, (try? JSONDecoder().decode(SourceShape.self, from: d)) != nil else { throw Failure.bad("items") }
            return a.count
        case "ItemIcons":
            let o = try dict()
            for (k, v) in o {
                guard str(k), let e = v as? [String: Any], png(e["png"]), let c = e["color"] as? [Any], c.count <= 3, c.allSatisfy({ int($0, 0...255) }), e["cat"] is String else { throw Failure.bad("图标 \(k.prefix(40))") }
            }
            return o.count
        case "MiniMaps":
            let o = try dict()
            for (k, v) in o { try need(Int(k) != nil && png(v), "小地图 \(k.prefix(12))") }
            return o.count
        default: throw Failure.unknown
        }
    }
    private struct SourceShape: Decodable { var items: [String: ItemSource] }

    // MARK: 防止坏资料让程序打不开

    private static var mark: URL? { dir?.deletingLastPathComponent().appendingPathComponent("资料启动标记") }
    /// 程序刚启动、读资料之前。连着两次一打开就崩：把导入的资料挪开。返回 true 表示挪开了
    public static func launching() -> Bool {
        guard let m = mark, let dir, !imported.isEmpty else { return false }
        let n = (try? String(contentsOf: m, encoding: .utf8)).flatMap { Int($0) } ?? 0
        if n >= 2 {
            let off = dir.deletingLastPathComponent().appendingPathComponent("游戏资料-停用")
            try? FileManager.default.removeItem(at: off)
            try? FileManager.default.moveItem(at: dir, to: off)
            try? FileManager.default.removeItem(at: m)
            return true
        }
        try? String(n + 1).write(to: m, atomically: true, encoding: .utf8)
        return false
    }
    /// 正常运行了一会儿、或正常退出
    public static func launched() { if let m = mark { try? FileManager.default.removeItem(at: m) } }
}
