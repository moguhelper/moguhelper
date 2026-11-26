// 我的资料：查走过的图怎么走、东西在哪捡到过；导出、导入 .mogu
import AppKit
import SwiftUI
import TranslatorCore

@MainActor
final class PackStore: ObservableObject {
    struct Item: Identifiable { var id: String, pack: MoguPack }
    @Published private(set) var packs: [Item] = []
    private let dir = dataDir.appendingPathComponent("导入")
    /// 随程序附带的攻略整理（地图连接），删不掉；和它一样的导入文件不重复算
    static let bundledId = "攻略整理（随程序附带）"
    init() {
        if let u = Bundle.main.url(forResource: "GuideMaps", withExtension: "mogu"), let d = try? Data(contentsOf: u), let p = try? MoguPack.read(d) {
            packs.append(Item(id: Self.bundledId, pack: p))
            trace("pack: 随程序附带的地图连接 \(p.maps.count) 张图")
        }
        for f in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] where f.pathExtension == "mogu" {
            if let d = try? Data(contentsOf: f), let p = try? MoguPack.read(d), !packs.contains(where: { $0.pack == p }) { packs.append(Item(id: f.deletingPathExtension().lastPathComponent, pack: p)) }
        }
        packs.sort { ($0.id == Self.bundledId ? 0 : 1, $0.id) < ($1.id == Self.bundledId ? 0 : 1, $1.id) }
    }
    func remove(_ id: String) {
        guard id != Self.bundledId else { return }; try? FileManager.default.removeItem(at: dir.appendingPathComponent(id + ".mogu")); packs.removeAll { $0.id == id } }

    /// 先看清里面有什么，确认了才存
    func open(_ url: URL) {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? nil
        do {
            guard (size ?? 0) <= MoguPack.maxBytes else { throw MoguPack.Failure.tooBig }
            guard let d = try? Data(contentsOf: url) else { throw MoguPack.Failure.notPack }
            let p = try MoguPack.read(d)
            let a = NSAlert()
            a.messageText = "导入这份资料？"
            a.informativeText = "\(p.maps.count) 张图、\(p.maps.values.reduce(0) { $0 + $1.exits.count }) 个门、\(Set(p.drops.values.flatMap(\.keys)).count) 种东西的捡到记录\(p.day.isEmpty ? "" : "（\(p.day) 导出）")。\n是别的玩家记的，可能不准。不会改动你自己的记录，随时可以删掉。"
            a.addButton(withTitle: "导入"); a.addButton(withTitle: "取消")
            NSApp.activate(ignoringOtherApps: true)
            guard a.runModal() == .alertFirstButtonReturn else { return }
            if packs.contains(where: { $0.pack == p }) { return say("这份已经导入过了。") }
            let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"
            var id = f.string(from: Date()), i = 2
            while packs.contains(where: { $0.id == id }) { id = f.string(from: Date()) + "-\(i)"; i += 1 }
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try p.data().write(to: dir.appendingPathComponent(id + ".mogu"), options: .atomic)
            packs.append(Item(id: id, pack: p))
        } catch let e as MoguPack.Failure { say(e.text) } catch { say("没存成：\(error.localizedDescription)") }
    }
    func pick() {
        let o = NSOpenPanel(); o.title = "选择 .mogu 资料"; o.allowsMultipleSelection = false
        NSApp.activate(ignoringOtherApps: true)
        if o.runModal() == .OK, let u = o.url { open(u) }
    }
    func export(_ p: MoguPack) {
        guard !p.maps.isEmpty else { return say("还没有记录。开着“走图时自动记地图”走几张图再来。") }
        let s = NSSavePanel(); s.nameFieldStringValue = "冒险岛地图-\(p.day).mogu"; s.title = "导出我的地图和捡到记录"
        s.message = "只有地图、门和捡到过什么；没有角色名、等级、经验、金币、聊天和图片。"
        NSApp.activate(ignoringOtherApps: true)
        guard s.runModal() == .OK, let u = s.url else { return }
        do { try p.data().write(to: u, options: .atomic); NSWorkspace.shared.activateFileViewerSelecting([u]) } catch { say("没存成：\(error.localizedDescription)") }
    }
    private func say(_ t: String) { let a = NSAlert(); a.messageText = t; NSApp.activate(ignoringOtherApps: true); a.runModal() }
}

/// 游戏资料：用户自己准备的文件，只存在本机
@MainActor
final class GameDataModel: ObservableObject {
    @Published private(set) var list = GameData.imported
    @Published private(set) var changed = false
    func pick() {
        let o = NSOpenPanel(); o.title = "选择游戏资料"; o.message = "选资料文件（可以多选），或放着这些文件的文件夹"
        o.allowsMultipleSelection = true; o.canChooseDirectories = true
        NSApp.activate(ignoringOtherApps: true)
        guard o.runModal() == .OK else { return }
        var files: [URL] = []
        for u in o.urls {
            if (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                files += GameData.names.map { u.appendingPathComponent($0 + ".json") }.filter { FileManager.default.fileExists(atPath: $0.path) }
            } else { files.append(u) }
        }
        var ok: [String] = [], bad: [String] = []
        for f in files {
            do { let r = try GameData.add(f); ok.append("✓ \(GameData.title[r.name] ?? r.name)：\(r.count) 条") }
            catch let e as GameData.Failure { bad.append("✗ \(f.lastPathComponent)：\(e.text)") }
            catch { bad.append("✗ \(f.lastPathComponent)：\(error.localizedDescription)") }
        }
        list = GameData.imported; if !ok.isEmpty { changed = true }
        let a = NSAlert()
        a.messageText = files.isEmpty ? "没找到资料文件" : ok.isEmpty ? "没有导入" : "已导入，重新打开程序后生效"
        a.informativeText = files.isEmpty ? "文件名要是 \(GameData.names.joined(separator: "、")) 加 .json。" : (ok + bad).joined(separator: "\n")
        a.runModal()
    }
    func remove(_ n: String) { GameData.remove(n); list = GameData.imported; changed = true }
}

struct PackView: View {
    @StateObject private var data = GameDataModel()
    @ObservedObject var store: PackStore
    @ObservedObject var maps: MapCollectModel
    @ObservedObject var exp: ExpMonitor
    @State private var query = ""
    @State private var goal: String?
    var nav: NavModel? = nil
    private var own: MoguPack {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        return MoguPack(maps: maps.maps, drops: exp.hunt.maps.mapValues { $0.drops }, npcs: maps.met.maps.mapValues { $0.mapValues(\.list) }, day: f.string(from: Date()))
    }
    private func name(_ p: MoguPack, _ k: String) -> String { p.maps[k].map { "\($0.name)（\($0.street)）" } ?? k }
    private func zh(_ n: String) -> String { (ItemDB.shared.exact(n)?.zh ?? ItemNames.zh(n)).map { "\($0) \(n)" } ?? n }
    var body: some View {
        let mine = own, all = MoguPack.merged(own: mine, store.packs.map(\.pack))
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let items = Set(all.drops.values.flatMap(\.keys)).filter { q.isEmpty || zh($0).lowercased().contains(q) }.sorted()
        let places = all.maps.keys.filter { q.isEmpty || name(all, $0).lowercased().contains(q) }.sorted { name(all, $0) < name(all, $1) }
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("\(all.maps.count) 张图 · \(Set(all.drops.values.flatMap(\.keys)).count) 种东西").font(.system(size: 13, weight: .semibold))
                Spacer()
                Button("导入…") { store.pick() }
                Button("导出我的…") { store.export(mine) }
            }
            Text("自己走过、捡到过的自动记在这里；也可以导入朋友导出的 .mogu。").font(.system(size: 11)).foregroundStyle(.secondary)
            ForEach(store.packs) { p in
                HStack {
                    if p.id == PackStore.bundledId {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("攻略整理（随程序附带）：\(p.pack.maps.count) 张图的连接").font(.system(size: 11))
                            Text("整理自 maplestory-classic.com，原始数据 OSMS Data Explorer（CC BY 4.0），有改动。你自己走过、看到的优先。").font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                        Spacer()
                    } else {
                        Text("导入的资料：\(p.pack.maps.count) 张图\(p.pack.day.isEmpty ? "" : "（\(p.pack.day)）")").font(.system(size: 11))
                        Spacer(); Button("删除") { store.remove(p.id) }.controlSize(.mini)
                    }
                }
            }
            Divider()
            HStack {
                Text("游戏资料").font(.system(size: 12, weight: .semibold))
                Text(data.changed ? "重新打开程序后生效" : data.list.isEmpty ? "没有导入" : "已导入 \(data.list.count) 种").font(.system(size: 11)).foregroundStyle(data.changed ? Color.orange : Color.secondary)
                Spacer(); Button("导入游戏资料…") { data.pick() }
            }
            Text("自己准备的资料文件，只存在这台电脑上，不联网、不上传。请确认你有权使用。").font(.system(size: 11)).foregroundStyle(.secondary)
            ForEach(data.list, id: \.self) { n in
                HStack { Text(GameData.title[n] ?? n).font(.system(size: 11)); Spacer(); Button("删除") { data.remove(n) }.controlSize(.mini) }
            }
            Divider()
            TextField("搜地图或东西（英文名）", text: $query)
            if let g = goal {
                VStack(alignment: .leading, spacing: 3) {
                    HStack { Text("去 \(name(all, g))").font(.system(size: 12, weight: .bold)); Spacer(); if let nav, NavDB.shared.maps.isEmpty { Button("画面上带路") { nav.setWalk(goal: .init(label: "去 \(name(all, g))", map: g)) }.controlSize(.mini) }; Button("关闭") { goal = nil }.controlSize(.mini) }
                    if let c = maps.current {
                        if let r = all.route(from: c, to: g) {
                            if r.isEmpty { Text("你就在这里。") }
                            ForEach(Array(r.enumerated()), id: \.offset) { i, s in Text("\(i + 1). \(s.text)") }
                        } else { Text("走过的门还连不到那里。") }
                    } else { Text("还不知道你在哪：把小地图展开，站一会儿。") }
                }.font(.system(size: 12)).padding(8).frame(maxWidth: .infinity, alignment: .leading).background(RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.1)))
            }
            List {
                Section("东西在哪捡到过") {
                    ForEach(items, id: \.self) { n in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(zh(n)).font(.system(size: 12, weight: .medium))
                            ForEach(all.places(n).prefix(4), id: \.key) { p in
                                HStack { Text("\(name(all, p.key)) ×\(p.n)").font(.system(size: 11)).foregroundStyle(.secondary); Spacer(); Button("怎么走") { goal = p.key }.controlSize(.mini) }
                            }
                        }
                    }
                }
                Section("地图") {
                    ForEach(places, id: \.self) { k in
                        HStack { Text(name(all, k)).font(.system(size: 12)); Spacer(); if k == maps.current { Text("现在在这里").font(.system(size: 10)).foregroundStyle(.secondary) } else { Button("怎么走") { goal = k }.controlSize(.mini) } }
                    }
                }
            }
        }.padding(12).frame(minWidth: 460, minHeight: 480)
    }
}
