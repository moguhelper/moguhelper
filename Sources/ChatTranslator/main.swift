// 冒险岛聊天翻译（合规说明）
// - 只用系统“屏幕录制”权限截取游戏窗口画面，在内存里识别文字后翻译，截图不保存到硬盘。
// - 不读取/修改游戏内存，不注入进程，不抓网络包，不改游戏文件。
// - 不向游戏发送任何按键或点击；悬浮窗口全部“鼠标穿透”。
// - 翻译用 macOS 自带的本地翻译，聊天内容不发到网上。
import AppKit
import SwiftUI
import Vision
import TranslatorCore

final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock(); private var done = false
    func claim() -> Bool { lock.lock(); defer { lock.unlock() }; if done { return false }; done = true; return true }
}

/// 给一步操作加超时：超过时间就立刻放弃这一次（不等它），不让整个程序卡住
func withTimeout<T: Sendable>(_ seconds: Double, _ op: @escaping @Sendable () async -> T?) async -> T? {
    let once = OnceFlag()
    return await withCheckedContinuation { (cont: CheckedContinuation<T?, Never>) in
        Task.detached(priority: .userInitiated) { let v = await op(); if once.claim() { cont.resume(returning: v) } }
        Task.detached { try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9)); if once.claim() { cont.resume(returning: nil) } }
    }
}

/// 本机数据目录。测试版（app.moguhelper.test）用单独的，不碰平时的记录
let dataDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent(Bundle.main.bundleIdentifier == "app.moguhelper.test" ? "MoguHelper-test" : "MoguHelper")
let appStart = Date()
func trace(_ s: String) {
    let t = String(format: "%.1fs", Date().timeIntervalSince(appStart))
    NSLog("ChatTranslator: %@ %@", t, s); print("[trace]", t, s); fflush(stdout)
    LogFile.write(s)
}

@MainActor
final class AppController: NSObject, NSApplicationDelegate {
    private let locator = GameWindowLocator()
    private var glossary: Glossary!
    private var translator: ChatTranslator!
    private let chatHistory = ChatHistory(limit: 200), shopHistory = ChatHistory(limit: 200)
    private var activity: NSObjectProtocol?
    private var ocrReady = false
    private var knownWords: Set<String> = []
    private let ocrClient = OCRClient()      // 聊天框识别（子进程）
    private let expMonitor = ExpMonitor()
    private let hoverClient = OCRClient(idleStop: 90)   // 鼠标指向、物品说明识别（另一个子进程，互不等待；空闲 90 秒自动释放）

    private let side = SidePanel()
    private let selector = RegionSelector()

    private var statusItem: NSStatusItem!
    private var statusLine = NSMenuItem(title: "正在寻找游戏窗口…", action: nil, keyEquivalent: "")
    private var memoryItem = NSMenuItem(title: "内存占用 —", action: nil, keyEquivalent: "")
    private var history: [Entry] = []
    private let historyLimit = 200
    private var lastFingerprint: [UInt8] = []
    private var busy = false
    private var missCount = 0
    private var emptyFrames = 0
    // 物品说明框翻译
    private let tipPanels = [TooltipPanel(), TooltipPanel()]
    /// 原地替换模式：说明框里逐行盖上中文（装备图标、边框、灰色字露出来）
    private let tipInPlace = [LabelsPanel(), LabelsPanel()]
    private var tipPieceCache: [Int: [TooltipPiece]] = [:]
    private var tipCache: [Int: TooltipZh] = [:]
    private var tipMisses = 0
    private var lastTipRects: [CGRect] = []        // 上次识别过的说明框位置（截图像素）
    private var lastTipShown: [TooltipZh] = []
    private var lastTipMouse = NSPoint(x: -9999, y: -9999)   // 上次显示说明框翻译时的鼠标位置
    /// 锁定后第一次确认时截到的细条，之后拿来比较（框在不在）
    private var tipRefStrips: [CGImage?] = []
    private var tipLastTry = Date.distantPast     // 上次截整个窗口找说明框的时间
    private var tipUnstable = 0                   // 连续几次两帧找到的框位置不一致
    private var tipLocked: [CGRect] = []      // 已显示的说明框（截图像素）；鼠标不动就不再重新识别
    private var tipCandidate: [CGRect] = []   // 上一帧找到的框，连续两帧一致才识别
    private var tipDumpCount = 0
    // 任务窗口翻译
    /// NPC 对话框：选项写在任务助手里，游戏里不盖（用户定）
    private var npcShown = false
    private func npcHide() { npcShown = false; nav.setChoices([]) }
    private func npcShow(_ e: [Entry]) { npcShown = true; nav.setChoices(e) }
    private var npcFp = 0
    private var npcRect: CGRect? = nil
    private var npcCache: [Int: [Entry]] = [:]
    private let questMerger = QuestScrollMerger()
    private var questBusy = false
    private var questMisses = 0
    private var questLayout: QuestLayout?            // 上次的位置（1 倍截图像素 = 窗口内的点）
    private var questFpBody = 0
    private var questEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "questEnabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "questEnabled") }
    }
    private var tipTicks = 0
    private var tipScale: CGFloat = 2
    private var tipSpotMisses = 0
    private var tipGaveUpAt = Date.distantPast
    private var lastMissDumpAt = Date.distantPast
    private var tipBusy = false
    private var lastMouse = NSPoint.zero
    private var mouseStillSince = Date()
    private var tipEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "tipEnabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "tipEnabled") }
    }
    // 物品说明只用“原地替换（保留图标）”（用户决定，另外两种显示方式不要了）
    private var tipMode: TipMode {
        get { .overlay }
        set { }
    }
    private var dumpIndex = 0
    private var busySince = Date()
    private var selecting = false

    private var paused = false

    // 每种窗口大小各存一个聊天区域
    private func regionKey(_ size: CGSize) -> String { "region-\(Int(size.width))x\(Int(size.height))" }
    private func region(for size: CGSize) -> Region? {
        guard let d = UserDefaults.standard.data(forKey: regionKey(size)) else { return nil }
        return try? JSONDecoder().decode(Region.self, from: d)
    }
    private func saveRegion(_ r: Region, for size: CGSize) {
        UserDefaults.standard.set(try? JSONEncoder().encode(r), forKey: regionKey(size))
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { GameData.launched() }
        if dataMoved {
            let a = NSAlert(); a.messageText = "导入的游戏资料有问题，已停用"
            a.informativeText = "程序连着两次一打开就关了，先不用导入的资料。文件挪到了数据文件夹的“游戏资料-停用”。"
            NSApp.activate(ignoringOtherApps: true); a.runModal()
        }
        do { glossary = try Glossary.load() } catch { fatalError("词表加载失败：\(error)") }
        OCRClient.customWords = glossary.customWords
        translator = ChatTranslator(glossary: glossary)
        knownWords = glossary.knownWords
        // 关闭“App 小憩”，避免系统把本程序当后台程序降速
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: "实时翻译聊天")
        ocrClient.warmUp()
        side.chatFontSize = CGFloat(UserDefaults.standard.integer(forKey: "sideFontSize"))
        setupMenu()
        side.selectButton.target = self
        side.selectButton.action = #selector(selectRegion)
        applyMode()

        // 预热：第一次文字识别要加载模型，较慢
        Task { _ = await translator.translate(ChatParser.classify("Player : hello", minY: 0, maxY: 0)) }

        // 不在启动时主动弹权限框之外的任何东西；第一次截图时系统会询问“屏幕录制”权限
        // 只在启动时请求一次权限。没有权限时绝不调用截屏接口，否则系统会反复弹窗。
        // 这台电脑上授权成功过的不再请求：偶尔查不到授权时只在面板里提示，不弹系统窗口
        if CGPreflightScreenCaptureAccess() { UserDefaults.standard.set(true, forKey: "screenGranted") }
        // 权限在首次引导里由用户点按钮申请，不在启动时弹
        if Welcome.needed { welcome.show() }
        ChatParser.playerName = expMonitor.model.name
        expMonitor.onNameChange = { [weak self] in
            guard let self else { return }
            ChatParser.playerName = self.expMonitor.model.name
            self.npcCache.removeAll(); self.npcFp = 0
            self.rebuildMenu()
        }

        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.chatTick() }
        }
        // 内存保护：每分钟自检一次，超过 300 MB 就清空缓存、重建识别器，防止长时间运行越来越卡
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.memoryGuard() }
        }
        // 任务窗口：0.35 秒找一次（打开后尽快翻译）
        Timer.scheduledTimer(withTimeInterval: 0.35, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.questTick() }
        }
        // 鼠标一离开物品，说明框翻译马上收起（只看鼠标位置，不截图，很省）
        // 游戏窗口最小化 / 切到别的桌面 / 关掉：0.15 秒内收起所有翻译（只问系统窗口在不在屏幕上，不截图）
        Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.gameVisibilityCheck() }
        }
        // NPC 选项：每 0.15 秒看一次箭头停在哪
        Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.npcSelTick() }
        }
        Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tipQuickHide() }
        }
        Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.tooltipTick() }
        }
        nav.collect = mapCollect
        nav.myLevel = { [weak self] in self?.expMonitor.model.level }
        nav.playerName = { [weak self] in self?.expMonitor.model.name ?? "" }
        nav.client = hoverClient
        expMonitor.onShop = { [weak self] in self?.nav.shopSells($0) }
        termSource.resume()
        expMonitor.mapNow = { [weak self] in self?.nav.mapId }
        loadRides()
        nav.onJump = { [weak self] from, to in
            // 和 NPC 说完话就换了地方：坐车、坐船（回城卷不用说话，不算）
            if let self, Date().timeIntervalSince(self.npcLastSeen) < 20 { self.expMonitor.rode(); self.learnRide(from, to) }
        }
        nav.onCounts = { [weak self] in self?.expMonitor.questCounts($0) }
        nav.huntMap = { [weak self] item in
            guard let self else { return nil }
            // 至少捡到 2 个，碰巧捡到别人丢的不算
            return expMonitor.hunt.maps.filter { ($0.value.drops[item] ?? 0) >= 2 }
                .sorted { ($0.value.drops[item]!, $1.key) > ($1.value.drops[item]!, $0.key) }
                .lazy.compactMap { k, _ in self.mapCollect.maps[k].flatMap { NavDB.shared.locate([$0.street, $0.name]) } }.first
        }
        expMonitor.currentMap = { [weak self] in self.flatMap { $0.collectEnabled ? $0.mapCollect.steadyMap : nil } }
        applyExpHeader()
        nav.onQuestChange = { [weak self] in
            self?.rebuildMenu()
        }
        // 任务导航：每 2 秒认一次小地图标题（没有在导航的任务就什么都不做）
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.navEnabled, !self.paused, !self.selecting, !self.gameHidden, let g = self.locator.current else { return }
                await self.nav.tick(locator: self.locator, g: g, client: self.expMonitor.client)
            }
        }
        Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.arrowTick() }
        }
        Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.navEnabled, !self.paused, !self.selecting, !self.gameHidden, let g = self.locator.current else { return }
                await self.nav.helperTick(locator: self.locator, g: g, client: self.expMonitor.client)
            }
        }
        mapCollect.playerName = { [weak self] in self?.expMonitor.model.name ?? "" }
        mapCollect.covered = { [weak self] in guard let self else { return true }; return self.questLayout != nil || self.shopRect != nil || self.npcTalk.map { Date().timeIntervalSince($0.t) < 4 } ?? false }
        mapCollect.onMe = { [weak self] in self?.walkTick() }
        nav.onGain = { [weak self] k, n in self?.mapCollect.gained(k, n) }
        nav.npcNames = { [weak self] in Array(Set((self?.walkData().npcs ?? [:]).values.flatMap(\.keys))) }
        nav.onTitle = { [weak self] l in
            guard let self else { return }
            self.mapCollect.titleLine(l, known: Set(self.walkData().maps.values.map { MapCollector.streetKey($0.street) }))
        }
        nav.seenMobs = { [weak self] in
            guard let self, let k = self.mapCollect.current else { return [] }
            return self.mapCollect.mobs.list(k).map { (name: $0.name, lv: $0.mob.lv, kills: $0.mob.kills) }
        }
        nav.lastTalk = { [weak self] in self?.npcTalk.flatMap { Date().timeIntervalSince($0.t) < 120 ? $0.name : nil } }
        nav.seenPlaces = { [weak self] n in
            guard let self else { return [] }
            let p = self.walkData()
            // 打某种怪：它掉的东西在哪捡到过也算
            var mine = ([n] + QuestTips.drops(of: n)).flatMap { p.places($0) }.sorted { ($0.n, $1.key) > ($1.n, $0.key) }.compactMap { p.maps[$0.key]?.name }
            // 自己见过、打过这种怪的图（近的在前）
            if let k = p.bestHaunt(n, from: self.mapCollect.current), let m = p.maps[k]?.name, !mine.contains(m) { mine.insert(m, at: 0) }
            for h in p.haunts(n) { if let m = p.maps[h.key]?.name, !mine.contains(m) { mine.append(m) } }
            return mine + QuestTips.spots(n).filter { !mine.contains($0) }
        }
        nav.walkHere = { [weak self] in self.flatMap { s in s.mapCollect.current.flatMap { s.walkData().maps[$0]?.name } } }
        nav.walkMap = { [weak self] n in self.flatMap { WalkNav.place(n, pack: $0.walkData()) } }
        nav.walkNpc = { [weak self] n in
            guard let self else { return nil }
            let p = self.walkData()
            return WalkNav.npcMaps(n, pack: p, from: self.mapCollect.current).first.flatMap { p.maps[$0]?.name }
        }
        nav.walkHops = { [weak self] n in
            guard let self, let at = self.mapCollect.current else { return nil }
            let p = self.walkData()
            // 同名的图可能有几张（隐藏街道里也有）：取最近的
            let ks = p.maps.filter { $0.value.name == n }.keys
            if ks.contains(at) { return 0 }
            return ks.compactMap { p.route(from: at, to: $0)?.count }.min()
        }
        nav.onWalk = { [weak self] in self?.walkPack = nil; self?.walkTick() }
        // 地图采集：每 0.5 秒看一眼小地图（标题变了才识别文字）
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.collectEnabled, !self.paused, !self.selecting, !self.gameHidden, let g = self.locator.current else { return }
                await self.mapCollect.tick(locator: self.locator, g: g, client: self.expMonitor.client)
            }
        }
        // 经验统计：每 6 秒读一次状态栏的经验数字
        Timer.scheduledTimer(withTimeInterval: 6, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.expTick() }
        }
        Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.expEnabled, !self.paused, !self.selecting, !self.gameHidden, let g = self.locator.current else { return }
                await self.expMonitor.mesoTick(locator: self.locator, g: g)
            }
        }
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.expEnabled, !self.paused, !self.selecting, !self.gameHidden, let g = self.locator.current else { return }
                await self.expMonitor.potionTick(locator: self.locator, g: g)
            }
        }
        Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.expEnabled, !self.paused, !self.selecting, !self.gameHidden, let g = self.locator.current else { return }
                await self.expMonitor.bagTick(locator: self.locator, g: g)
            }
        }
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.expEnabled, !self.paused, !self.selecting, !self.gameHidden, let g = self.locator.current else { return }
                await self.expMonitor.shopTick(locator: self.locator, g: g)
            }
        }
        Timer.scheduledTimer(withTimeInterval: 0.7, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.expEnabled, !self.paused, !self.selecting, !self.gameHidden, let g = self.locator.current else { return }
                await self.expMonitor.pickupTick(locator: self.locator, g: g)
            }
        }
    }

    /// 自己走图采集
    private let mapCollect = MapCollectModel()
    private var collectEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "mapCollect") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "mapCollect") }
    }
    @objc private func toggleCollect() { collectEnabled.toggle(); rebuildMenu() }
    private var collectWindow: NSWindow?
    private var potionWindow: NSWindow?
    @objc private func showPotions() {
        if potionWindow == nil {
            let w = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 580, height: 320), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            w.title = "药水（名字、单价、用量）"; w.isReleasedWhenClosed = false; w.center()
            w.contentView = NSHostingView(rootView: PotionView(exp: expMonitor, model: expMonitor.model) { [weak self] in self?.expMonitor.savePotions() })
            potionWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        potionWindow?.makeKeyAndOrderFront(nil)
    }
    private lazy var welcome = Welcome(retryOCR: { [weak self] in self?.ocrClient.warmUp() })
    @objc private func showWelcome() { welcome.show() }
    private var huntWindow: NSWindow?
    @objc private func showHunt() {
        if huntWindow == nil {
            let w = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 500, height: 560), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            w.title = "打怪记录（效率、掉落）"; w.isReleasedWhenClosed = false; w.center()
            w.contentView = NSHostingView(rootView: HuntView(exp: expMonitor, maps: mapCollect))
            huntWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        huntWindow?.makeKeyAndOrderFront(nil)
    }
    @objc private func toggleIconMode() { IconStore.shared.screenOnly.toggle(); rebuildMenu() }
    private var keepWindow: NSWindow?
    @objc private func showKeep() {
        if keepWindow == nil {
            let w = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 500, height: 520), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            w.title = "背包：留还是卖"; w.isReleasedWhenClosed = false; w.center()
            w.contentView = NSHostingView(rootView: KeepView(exp: expMonitor))
            keepWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        keepWindow?.makeKeyAndOrderFront(nil)
    }
    // 没有地图资料时带路：自己走过的 + 朋友传的
    private var walkPack: (pack: MoguPack, at: Date)?
    private func walkData() -> MoguPack {
        if let p = walkPack, Date().timeIntervalSince(p.at) < 10 { return p.pack }
        let own = MoguPack(maps: mapCollect.maps, drops: expMonitor.hunt.maps.mapValues { $0.drops }, npcs: mapCollect.met.maps.mapValues { $0.mapValues(\.list) }, mobs: mapCollect.mobs.packed, day: "")
        let p = MoguPack.merged(own: own, packStore.packs.map(\.pack))
        walkPack = (p, Date())
        return p
    }
    private func walkTick() {
        guard NavDB.shared.maps.isEmpty else { return }
        nav.refreshSeen()
        let p = walkData()
        if let t = nav.target {
            let text = [t.giver ?? "", nav.fromNpc ?? "", nav.endNpc ?? "", t.en ?? "", (t.zh ?? [:]).keys.sorted().joined(separator: ". ")].joined(separator: " ")
            let left = nav.tipMobs + nav.progress.filter { $0.value.count == 2 && $0.value[0] < $0.value[1] }.keys.sorted()
            nav.setWalk(goals: WalkNav.goals(text: text, items: left, pack: p, from: mapCollect.current), unknown: WalkNav.unknown(text: text, pack: p))
        } else { nav.setWalk(goals: [], unknown: []) }
        nav.autoWalk()
        mapCollect.setReference(packStore.packs.flatMap { $0.pack.maps.map { ($0.key, ($0.value.street, $0.value.name)) } })
        guard let g = nav.walkGoal else { nav.setWalk(shortcut: nil); return }
        let cab = mapCollect.current.flatMap { WalkNav.shortcut(p, from: $0, to: g.map) }
        if cab != nav.shortcut { trace("nav: 出租车 \(cab ?? "不用")") }
        nav.setWalk(shortcut: cab)
        nav.setWalk(hint: mapCollect.current.flatMap { WalkNav.hint(p, from: $0, goal: g, me: mapCollect.meFx, at: mapCollect.spot) } ?? NavHint(dir: .none, text: mapCollect.current == nil ? "还不知道你在哪，把小地图展开" : "走过的门还连不到那里"))
    }
    private var packWindow: NSWindow?
    private lazy var packStore = PackStore()
    @objc private func showPacks() {
        if packWindow == nil {
            let w = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 500, height: 600), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            w.title = "查路线、查掉落"; w.isReleasedWhenClosed = false; w.center()
            w.contentView = NSHostingView(rootView: PackView(store: packStore, maps: mapCollect, exp: expMonitor, nav: nav))
            packWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        packWindow?.makeKeyAndOrderFront(nil)
    }
    /// 双击 .mogu 文件
    func application(_ application: NSApplication, open urls: [URL]) {
        for u in urls where u.isFileURL && u.pathExtension.lowercased() == "mogu" { packStore.open(u); showPacks() }
    }
    @objc private func showCollect() {
        if collectWindow == nil {
            let w = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 480, height: 560), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            w.title = "走过的地图"; w.isReleasedWhenClosed = false; w.center()
            w.contentView = NSHostingView(rootView: MapCollectView(model: mapCollect, nav: nav))
            collectWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        collectWindow?.makeKeyAndOrderFront(nil)
    }
    /// 任务导航（侧边面板）
    private let nav = NavModel()
    private lazy var navArrow = NavArrowPanel(nav)
    private var arrowEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "navArrow") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "navArrow") }
    }
    @objc private func toggleMoveArrow() { navArrow.movable.toggle(); rebuildMenu() }
    @objc private func resetArrow() { navArrow.resetSpot() }
    @objc private func toggleArrow() { arrowEnabled.toggle(); navArrow.movable = false; if !arrowEnabled { navArrow.hide() }; rebuildMenu() }
    /// 箭头：认自己的位置、显示 / 收起。任务窗口开着时先收起（会压在一起）
    private func arrowTick() async {
        guard navShown || navArrow.movable, arrowEnabled, !paused, !selecting, !gameHidden, let g = locator.current else { navArrow.hide(); return }
        await nav.positionTick(locator: locator, g: g)
        // 拖动时一直显示
        if !navArrow.movable { guard navShown, arrowEnabled, !paused, !selecting, !gameHidden, nav.hint != nil, questLayout == nil else { navArrow.hide(); return } }
        let live = GameWindowLocator.liveInfo(g.windowID)
        navArrow.show(over: live?.0 ?? g.frameTopLeft, level: NSWindow.Level(rawValue: max(NSWindow.Level.floating.rawValue, (live?.1 ?? g.layer) + 1)))
    }
    private var navEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "navEnabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "navEnabled") }
    }
    /// 有任务在导航（没有任务时不为它单独开面板）
    private var navShown: Bool { navEnabled && nav.active }

    private func expTick() async {
        guard expEnabled, !paused, !selecting, !gameHidden, let g = locator.current else { return }
        await expMonitor.tick(locator: locator, g: g)
    }

    private var expEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "expEnabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "expEnabled") }
    }
    @objc private func toggleExp() { expEnabled.toggle(); applyExpHeader(); applyMode(); rebuildMenu() }
    /// 侧边面板顶部的角色、经验小组件（经验统计关掉就收起）
    private func applyExpHeader() {
        guard expEnabled || navEnabled else { side.setHeader(nil); return }
        let v = NSHostingView(rootView: SideHeader(exp: expEnabled ? expMonitor.model : nil, nav: navEnabled ? nav : nil, space: side.space) { [weak self] h in self?.side.setHeaderHeight(h) })
        v.sizingOptions = []
        side.setHeader(v)
    }

    func applicationWillTerminate(_ notification: Notification) { GameData.launched(); expMonitor.save() }
    /// 导入的游戏资料让程序连着打不开，已经挪开
    var dataMoved = false
    /// 被别的程序关掉（重新打包、关机）也先把最后一分钟的账存好
    private lazy var termSource: DispatchSourceSignal = {
        signal(SIGTERM, SIG_IGN)
        let s = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        s.setEventHandler { NSApp.terminate(nil) }
        return s
    }()

    private var lastMemoryClean = Date.distantPast
    private func memoryMB() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        _ = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) } }
        return Double(info.resident_size) / 1_048_576
    }

    private func memoryGuard() async {
        let mb = memoryMB()
        memoryItem.title = String(format: "内存占用 %.0f MB（超过 500 MB 自动清理）", mb)
        trace(String(format: "memory %.0f MB", mb))
        // 侧边小组件（曲线图）本身就占 300 MB 左右，清缓存也降不下来：线定在 500 MB，清过一次 10 分钟内不再清
        // （清理会重启识别子进程，每分钟都清反而让翻译变慢）
        guard mb > 500, Date().timeIntervalSince(lastMemoryClean) > 600 else { return }
        lastMemoryClean = Date()
        await translator.reset()
        ocrClient.stop(); hoverClient.stop(); expMonitor.client.stop()
        if history.count > 50 { history.removeFirst(history.count - 50) }
        lastFingerprint = []
        NSLog("ChatTranslator: memory %.0f MB, caches cleared", mb)
    }

    // MARK: 菜单栏

    private func setupMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // 菜单栏图标：彩色小蘑菇；取不到时退回文字“译”
        if let img = Maple.smallMushroom(18) {
            img.accessibilityDescription = "MoguHelper"
            statusItem.button?.image = img
        } else {
            statusItem.button?.title = "译"
        }
        rebuildMenu()
    }

    // 主菜单一个板块一项，不再往里加零散的开关；新功能放进对应板块（规划见 docs/菜单规划.md）
    private let chatMenu = NSMenu(), windowMenu = NSMenu(), navMenu = NSMenu(), statMenu = NSMenu(), setMenu = NSMenu()
    private var pauseItem: NSMenuItem?
    private func buildTopMenu() {
        let m = NSMenu()
        func sub(_ t: String, _ icon: String, _ menu: NSMenu) {
            let it = NSMenuItem(title: t, action: nil, keyEquivalent: "")
            it.image = NSImage(systemSymbolName: icon, accessibilityDescription: nil); it.submenu = menu
            m.addItem(it)
        }
        sub("聊天翻译", "text.bubble", chatMenu)
        sub("画面翻译", "macwindow", windowMenu)
        sub("任务和路线", "map", navMenu)
        sub("统计", "chart.bar", statMenu)
        sub("设置", "gearshape", setMenu)
        m.addItem(.separator())
        let p = NSMenuItem(title: "", action: #selector(togglePause), keyEquivalent: "p"); p.target = self
        pauseItem = p
        m.addItem(p)
        m.addItem(NSMenuItem(title: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        m.addItem(.separator())
        m.addItem(statusLine)
        m.addItem(memoryItem)
        statusItem.menu = m
    }
    @objc private func toggleNavOn() { navEnabled.toggle(); if !navEnabled { navArrow.movable = false; navArrow.hide() }; applyExpHeader(); applyMode(); rebuildMenu() }
    @objc private func toggleLog() { LogFile.on.toggle(); rebuildMenu() }
    @objc private func openLogs() {
        try? FileManager.default.createDirectory(at: LogFile.dir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(LogFile.dir)
    }
    @objc private func pickNavSeg(_ s: NSSegmentedControl) {
        navEnabled = s.selectedSegment != 0
        if s.selectedSegment == 2 { collectEnabled = true }
        nav.guideOn = s.selectedSegment == 2
        if !navEnabled { navArrow.movable = false; navArrow.hide() }
        applyExpHeader(); applyMode(); rebuildMenu()
    }
    /// 只重填子菜单的内容：主菜单的项不动，开着的子菜单不会被关掉
    private func rebuildMenu() {
        if statusItem.menu == nil { buildTopMenu() }
        pauseItem?.title = paused ? "继续翻译" : "暂停全部翻译"
        func item(_ t: String, _ a: Selector, key: String = "") -> NSMenuItem {
            let it = NSMenuItem(title: t, action: a, keyEquivalent: key); it.target = self; return it
        }
        func sub(_ t: String, _ items: [NSMenuItem]) -> NSMenuItem {
            let menu = NSMenu(); items.forEach { menu.addItem($0) }
            let it = NSMenuItem(title: t, action: nil, keyEquivalent: ""); it.submenu = menu; return it
        }

        // ── 聊天翻译
        var m = chatMenu
        m.removeAllItems()
        m.addItem(item("框选聊天区域…", #selector(selectRegion), key: "r"))
        m.addItem(item("清空记录", #selector(clearHistory)))
        m.addItem(.separator())
        m.addItem(switchItem("显示英文原文", on: side.showOriginal, action: #selector(toggleOriginal)))
        m.addItem(switchItem("显示游戏公告", on: showNotices, action: #selector(toggleNotices)))
        m.addItem(sub("字号", [0, 9, 10, 11, 12, 13, 14, 16].map { sz in
            let it = NSMenuItem(title: sz == 0 ? "自动（按窗口大小）" : "\(sz)", action: #selector(pickSideFontSize(_:)), keyEquivalent: "")
            it.tag = sz; it.target = self; it.state = Int(side.chatFontSize) == sz ? .on : .off
            return it
        }))

        // ── 画面翻译
        m = windowMenu
        m.removeAllItems()
        m.addItem(switchItem("物品说明（鼠标停在物品上）", on: tipEnabled, action: #selector(toggleTip)))
        m.addItem(switchItem("任务、NPC 对话、商店聊天", on: questEnabled, action: #selector(toggleQuest)))

        // ── 任务和路线。有地图资料才有箭头、导航采集
        m = navMenu
        m.removeAllItems()
        let hasMaps = !NavDB.shared.maps.isEmpty
        if hasMaps {
            let seg = NSSegmentedControl(labels: ["关", "任务助手", "导航采集"], trackingMode: .selectOne, target: self, action: #selector(pickNavSeg(_:)))
            seg.controlSize = .small
            seg.selectedSegment = !navEnabled ? 0 : nav.guideOn ? 2 : 1
            m.addItem(Self.rowItem(title: "模式", control: seg))
        } else {
            m.addItem(switchItem("任务助手", on: navEnabled, action: #selector(toggleNavOn)))
        }
        m.addItem(switchItem("游戏画面上显示箭头", on: arrowEnabled, action: #selector(toggleArrow)))
        m.addItem(switchItem("移动导航条（拖动后再关掉）", on: navArrow.movable, action: #selector(toggleMoveArrow)))
        m.addItem(item("导航条恢复默认位置", #selector(resetArrow)))
        m.addItem(switchItem("自动记走过的地图（只存本机）", on: collectEnabled, action: #selector(toggleCollect)))
        m.addItem(.separator())
        m.addItem(item("查路线、查掉落（走过、捡过的）…", #selector(showPacks)))
        m.addItem(item("走过的地图…", #selector(showCollect)))

        // ── 统计
        m = statMenu
        m.removeAllItems()
        m.addItem(switchItem("经验、金币、掉落、药水", on: expEnabled, action: #selector(toggleExp)))
        m.addItem(.separator())
        m.addItem(item("每张图的打怪效率和掉落…", #selector(showHunt)))
        m.addItem(item("药水用量和单价…", #selector(showPotions)))
        if NavDB.shared.hasQuests { m.addItem(item("背包：留还是卖（看任务要不要）…", #selector(showKeep))) }

        // ── 设置
        m = setMenu
        m.removeAllItems()
        let myName = expMonitor.model.name
        // 角色名：显示在侧边面板顶部；NPC 对话、聊天里出现自己的名字时保持英文、不被翻译
        m.addItem(item("当前角色：\(myName.isEmpty ? "识别中" : myName)（认错了点这里改）…", #selector(setMyName)))
        m.addItem(item("权限和翻译包…", #selector(showWelcome)))
        if ItemIcons.shared.count > 0 { m.addItem(switchItem("图标只从游戏画面取（试普通用户）", on: IconStore.shared.screenOnly, action: #selector(toggleIconMode))) }
        m.addItem(.separator())
        m.addItem(switchItem("记运行日志（只存本机，不记聊天）", on: LogFile.on, action: #selector(toggleLog)))
        m.addItem(item("打开日志文件夹", #selector(openLogs)))
    }

    /// 菜单里的一行：左边文字，右边一个控件（开关 / 分段按钮）。点控件菜单不关，开关自己就会动
    static func rowItem(title: String, control: NSControl) -> NSMenuItem {
        // 宽度跟着菜单走（菜单有多宽这一行就多宽），控件贴右边，文字和普通菜单项左边对齐
        let w: CGFloat = 300, h: CGFloat = 28
        let v = NSView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        v.autoresizingMask = [.width]
        let l = NSTextField(labelWithString: title)
        l.font = NSFont.menuFont(ofSize: 0)
        l.sizeToFit()
        l.frame.origin = NSPoint(x: 14, y: (h - l.frame.height) / 2)
        v.addSubview(l)
        control.sizeToFit()
        control.frame.origin = NSPoint(x: w - 12 - control.frame.width, y: (h - control.frame.height) / 2)
        control.autoresizingMask = [.minXMargin]
        v.addSubview(control)
        let it = NSMenuItem()
        it.view = v
        return it
    }
    private func switchItem(_ title: String, on: Bool, action: Selector) -> NSMenuItem {
        let sw = NSSwitch()
        sw.controlSize = .small
        sw.state = on ? .on : .off
        sw.target = self; sw.action = action
        return Self.rowItem(title: title, control: sw)
    }
    /// 显示游戏公告：默认不显示（停服维护类的一直显示）。记录里照样保留，顺序对齐才不会乱
    private var showNotices: Bool {
        get { UserDefaults.standard.bool(forKey: "showNotices") }
        set { UserDefaults.standard.set(newValue, forKey: "showNotices") }
    }
    private func rebuildHistory() {
        let all = showNotices ? chatHistory.items
            : chatHistory.items.filter { !glossary.isHideableNotice(kind: $0.kind, speaker: $0.speaker, raw: $0.raw) }
        history = all.map { Entry(original: $0.raw, chinese: $0.chinese ?? "…") }
    }
    @objc private func toggleNotices() {
        showNotices.toggle()
        rebuildHistory()
        side.show(history);
        rebuildMenu()
    }
    @objc private func toggleOriginal() { side.showOriginal.toggle(); side.show(history); rebuildMenu() }
    /// 角色名：NPC 对话里会叫你的名字，识别容易认错（“Play/rOne”），设置后按它纠正、原样显示不翻译
    @objc private func setMyName() {
        let a = NSAlert()
        a.messageText = "我的角色名"
        a.informativeText = "平时自动从状态栏读，认错了才需要改。用处：翻译时不动你的名字；每个角色的经验、金币、药水、打怪记录分开记。"
        let f = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        f.stringValue = UserDefaults.standard.string(forKey: "myName") ?? ""
        a.accessoryView = f
        a.addButton(withTitle: "确定"); a.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let n = f.stringValue.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty, !n.contains("/") else { return }
        expMonitor.switchTo(n)
        npcCache.removeAll(); npcFp = 0
        rebuildMenu()
    }
    @objc private func toggleQuest() { questEnabled.toggle(); questReset(); npcReset(); shopReset(); rebuildMenu() }
    /// 关掉之后，正在翻译的那一次别再显示
    private var questStopped: Bool { paused || !questEnabled }
    // 和谁说完话被送去了哪（myrides.json）：下次箭头就会带你找他
    private static let ridesURL = dataDir.appendingPathComponent("myrides.json")
    private var myRides: [[Int]] = []
    private var npcTalk: (name: String, t: Date)?
    private func loadRides() {
        myRides = (try? Data(contentsOf: Self.ridesURL)).flatMap { try? JSONDecoder().decode([[Int]].self, from: $0) } ?? []
        for r in myRides where r.count == 3 { NavDB.shared.addRide(from: r[0], npc: r[1], to: r[2]) }
    }
    private func learnRide(_ from: Int, _ to: Int) {
        // 回城卷、死了也会一下到回城的图：不算
        guard let n = npcTalk, Date().timeIntervalSince(n.t) < 20, NavDB.shared.maps[from]?.ret != to,
              let id = NavDB.shared.rider(n.name, in: from), !myRides.contains([from, id, to]) else { return }
        myRides.append([from, id, to])
        NavDB.shared.addRide(from: from, npc: id, to: to)
        if let d = try? JSONEncoder().encode(myRides) { try? d.write(to: Self.ridesURL, options: .atomic) }
        trace("nav: 记下 找 \(n.name) 去 \(NavDB.shared.mapName(to))")
    }
    private var npcMissDumps = 0
    private var npcPendingFp = 0
    private var npcFirstSeen = Date.distantPast      // 这个对话框第一次被看到的时间（看出中文用了多久）
    private func npcReset() { npcHide(); npcFp = 0; npcRect = nil; npcBase = nil; npcPage = nil; npcSeen = false; quiz.close() }
    /// 现在显示的这页：低分辨率原图、当时鼠标在哪、选项位置（对话框里的点）
    private var npcBase: (img: CGImage, mouse: CGPoint)?
    private struct NpcPage { var body = ""; var answer: Int? = nil; var tips: [String]? = nil; var options: [String] = []; var rows: [CGRect] = [] }
    private var npcPage: NpcPage?
    private var npcSeen = false
    private var npcPages: [Int: NpcPage] = [:]
    private var quiz: QuizMemory = {
        (try? Data(contentsOf: quizURL)).flatMap { try? JSONDecoder().decode(QuizMemory.self, from: $0) } ?? QuizMemory()
    }()
    private static let quizURL: URL = {
        let dir = dataDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("quiz.json")
    }()
    private var quizAt = Date.distantPast
    private func npcQuiz(_ p: NpcPage) -> Bool {
        if p.tips != nil { quizAt = Date(); return true }
        return p.options.count < 2 && Date().timeIntervalSince(quizAt) < 300 || nav.quizzing
    }
    /// 对错有变：存下来，画面缓存重来
    private func npcSave() {
        npcCache.removeAll(); npcPages.removeAll()
        if let d = try? JSONEncoder().encode(quiz) { try? d.write(to: Self.quizURL, options: .atomic) }
    }
    /// 换到新的一页：结算上一题
    private func npcShowPage(_ p: NpcPage) {
        npcPage = p; npcSeen = true; npcSelLog = -1; npcPicked = false; npcAnswered = false; npcGone = 0
        trace("npc: 一页 选项\(p.options.count) 问答\(npcQuiz(p)) \(p.body.prefix(80))")
        if quiz.page(p.body, options: p.options, quiz: npcQuiz(p)) {
            npcSave()
            trace("npc: 记下选择 → \(p.body.prefix(40))")
        }
    }
    /// 鼠标在对话框里的位置（点）
    private func npcMouse(_ r: CGRect, _ win: CGRect) -> CGPoint {
        let p = Coords.toTopLeft(NSEvent.mouseLocation)
        return CGPoint(x: p.x - win.minX - r.minX, y: p.y - win.minY - r.minY)
    }
    /// 和显示时比，文字变了没有：选项前的红箭头、游戏鼠标不算
    private nonisolated static func npcChanged(_ a: CGImage, _ b: CGImage, rows: [CGRect], mice: [CGPoint]) -> Bool {
        guard a.width == b.width, a.height == b.height,
              let (x, w, h) = TooltipDetector.rgbaPublic(a), let (y, _, _) = TooltipDetector.rgbaPublic(b) else { return true }
        let skip = rows.map { CGRect(x: $0.minX - 20, y: $0.minY - 6, width: $0.width > 1 ? $0.width + 80 : 20, height: $0.height + 14) }      // 选项那几行不看（鼠标指着会变样），换页时说明一定也变
            + mice.map { CGRect(x: $0.x - 16, y: $0.y - 16, width: 52, height: 52) }
        var rowsN = [Int](repeating: 0, count: h)
        for yy in 0..<h { for xx in 0..<w {
            let i = (yy * w + xx) * 4
            guard abs(Int(x[i]) - Int(y[i])) + abs(Int(x[i + 1]) - Int(y[i + 1])) + abs(Int(x[i + 2]) - Int(y[i + 2])) > 120 else { continue }
            let p = CGPoint(x: xx, y: yy)
            if skip.contains(where: { $0.contains(p) }) { continue }
            rowsN[yy] += 1
        } }
        // 选中的那项下面有虚线，跟着鼠标换：只有一两行高的变化不算，字至少四行高
        var n = 0, yy = 0
        while yy < h {
            var e = yy, sum = 0
            while e < h, rowsN[e] > 0 { sum += rowsN[e]; e += 1 }
            if e - yy >= 4 { n += sum }
            yy = max(e, yy + 1)
        }
        return n > 30
    }
    private var npcSelBusy = false, npcSelLog = -1
    /// 鼠标最后停的地方像是在选（选项、NEXT 按钮）；上一次的位置
    private var npcPicked = false, npcAnswered = false, npcGone = 0
    /// 每个选项的标记：自己选错过的 ✗；核实过的答案、自己选对过的 ✓
    private func npcMarks(_ p: NpcPage) -> [Int: QuizMemory.Mark] {
        var m = quiz.marks(p.body, options: p.options)
        if let a = p.answer { m = m.filter { $0.value == .wrong }; m[a] = .right }
        return m
    }
    private static func npcAnswer(_ k: Int) -> Entry { Entry(original: "", chinese: "答案：选第 \(k + 1) 个", color: Maple.done) }
    /// 缓存里的选项换上现在的对错标记
    private func npcMarked(_ items: [Entry], _ p: NpcPage) -> [Entry] {
        let marks = npcMarks(p), first = items.count - p.options.count
        guard first >= 0 else { return items }
        // 上面的“答案”行也按现在的来
        let head = items[..<first].filter { !$0.chinese.hasPrefix("答案：") } + (marks.first { $0.value == .right }.map { [Self.npcAnswer($0.key)] } ?? [])
        return head + items[first...].enumerated().map { k, e in
            let m = marks[k], base = e.chinese.components(separatedBy: "  ✓ 选这个").first!.components(separatedBy: "  ✗ 上次").first!
            return Entry(original: e.original, chinese: base + (m == .right ? "  ✓ 选这个" : m == .wrong ? "  ✗ 上次选错" : ""), color: m.map { $0 == .right ? Maple.done : Maple.red } ?? Maple.text)
        }
    }
    /// 每 0.15 秒看一眼红箭头停在第几个选项（只截箭头那一列）
    private func npcSelTick() async {
        guard !npcSelBusy, let p = npcPage, p.rows.count >= 2, let r = npcRect, let g = locator.current else { return }
        npcSelBusy = true; defer { npcSelBusy = false }
        let x = max(0, p.rows[0].minX - 18)
        let col = CGRect(x: r.minX + x, y: r.minY, width: 18, height: r.height)
        let loc = locator
        guard let img = await withTimeout(1, { await loc.capture(g, rect: col, outputScale: 1) }), npcPage?.body == p.body,
              let (buf, w, h) = TooltipDetector.rgbaPublic(img) else { return }
        var count = [Int](repeating: 0, count: p.rows.count)
        for (k, row) in p.rows.enumerated() {
            // 对话框可能刚变矮，行会超出截图：两头都夹在 0...h 里
            let y0 = min(h, max(0, Int(row.minY)))
            for yy in y0..<max(y0, min(h, Int(row.maxY))) { for xx in 0..<w {
                let i = (yy * w + xx) * 4
                if buf[i] > 180, buf[i + 1] < 100, buf[i + 2] < 100 { count[k] += 1 }
            } }
        }
        guard var best = count.indices.max(by: { count[$0] < count[$1] }), count[best] >= 3 else {
            // 没有红箭头了，框还是白的：已经选了、正在说答得怎么样（按空格很快，等不到认字）
            var white = 0, dirty = 0
            for yy in 0..<h { for xx in 0..<w {
                let i = (yy * w + xx) * 4
                let ok = abs(Int(buf[i]) - 244) <= 8 && abs(Int(buf[i + 1]) - 244) <= 8 && abs(Int(buf[i + 2]) - 244) <= 8
                if ok { white += 1 } else if p.rows.contains(where: { CGFloat(yy) >= $0.minY && CGFloat(yy) <= $0.maxY }) { dirty += 1 }
            } }
            guard white * 10 > w * h * 7, p.tips != nil else { npcGone = 0; return }
            npcGone += dirty == 0 ? 2 : 1
            if npcGone >= 2, !npcAnswered { npcAnswered = true; trace("npc: 箭头没了，选的是第 \(npcSelLog + 1) 个"); quiz.answer() }
            return
        }
        npcGone = 0
        let mp = npcMouse(r, g.frameTopLeft)
        // 空格选的是红箭头那项；鼠标指着某项时点的是那项，红箭头不跟着动
        let on = p.rows.firstIndex { CGRect(x: $0.minX - 22, y: $0.minY - 3, width: $0.width + 44, height: $0.height + 6).contains(mp) }
        if let on { best = on }
        npcPicked = on != nil || (mp.x > r.width - 100 && mp.x < r.width + 10 && mp.y > r.height - 50 && mp.y < r.height + 10)
        if best != npcSelLog { npcSelLog = best; trace("npc: 箭头停在第 \(best + 1) 个") }
        quiz.select(best)
    }

    private func questReset() {
        questLayout = nil; questFpBody = 0
    }

    /// 游戏窗口不在屏幕上（最小化、切走、关闭）时为 true：所有翻译都收起，各循环暂停显示
    private var gameHidden = false
    /// 旁边的面板正退在别的窗口后面
    private var sideBehind = false
    private func gameVisibilityCheck() {
        // 彻底找不到游戏窗口时交给聊天循环处理（重新找到后它会重新摆好显示）
        // 暂停前已经在翻译的那一次可能这时才显示出来：再收一遍
        if paused, !navArrow.movable { hideOverlays() }
        guard let g = locator.current else { gameHidden = false; return }
        guard !selecting else { return }
        let onScreen = GameWindowLocator.liveInfo(g.windowID) != nil
        // 别的窗口（终端、浏览器）盖住了某块中文：那块先透明，挪开或点回游戏就恢复
        let mine = NSApp.windows.filter { $0 is NSPanel && $0.ignoresMouseEvents && $0.isVisible }
        if onScreen, !mine.isEmpty || side.panel.isVisible {
            let front = GameWindowLocator.windowsInFront(of: g.windowID)
            for p in mine {
                let r = Coords.toAppKit(p.frame)      // 上下翻转，两个方向算法一样
                let a: CGFloat = front.contains { $0.intersects(r.insetBy(dx: 2, dy: 2)) } ? 0 : 1
                if p.alphaValue != a { p.alphaValue = a }
            }
            // 旁边的面板：别的窗口盖在那里时退到它后面（露出来的部分照样能看能点），没有了再浮上来
            let sp = side.panel
            if !sp.isVisible { sideBehind = false }
            if sp.isVisible {
                let covered = front.contains { $0.intersects(Coords.toAppKit(sp.frame).insetBy(dx: 2, dy: 2)) }
                if covered, !sideBehind { sideBehind = true; sp.level = .normal; sp.order(.above, relativeTo: Int(g.windowID)) }
                else if !covered, sideBehind { sideBehind = false; sp.level = .floating; sp.orderFrontRegardless() }
            }
        }
        if !onScreen, !gameHidden {
            gameHidden = true
            trace("game window off screen: hide all")
            hideAll(); questReset(); npcReset(); shopReset(); tipReset("游戏窗口不在屏幕上")
        } else if onScreen, gameHidden {
            gameHidden = false
            trace("game window back on screen")
            applyMode()
        }
    }

    // MARK: 任务窗口：每秒用低分辨率截图找一次任务窗口；列表或正文有变化时才用高分辨率截那一块去识别、翻译。
    // 不替用户滚动：用户自己滚动正文时，把每次看到的部分拼成完整说明。

    private var navIds: [Int: (NavTarget, [(name: String, count: String)])] = [:]      // 详情画面指纹 → 导航目标和进度
    private func questTick() async {
        guard questEnabled, !paused, !selecting, !questBusy, !gameHidden, let g = locator.current else { return }
        questBusy = true; defer { questBusy = false; if questStopped { questReset(); npcReset(); shopReset() } }
        let win = g.frameTopLeft
        let loc = self.locator
        guard let small = await withTimeout(3, { await loc.capture(g, rect: CGRect(origin: .zero, size: win.size), outputScale: 1) }) else { return }
        await npcStep(small: small, g: g)
        await shopStep(small: small, g: g)
        let found = await Task.detached { () -> (QuestLayout, Int, Int, CGRect?, QuestTab?)? in
            guard let lay = QuestDetector.find(in: small, scale: 1) else { return nil }
            let body = [lay.header, lay.content].compactMap { $0 }.reduce(CGRect.null) { $0.union($1) }
            // 小地图压在任务窗口上：它上面的点一直在动，不算“正文变了”，里面的字也不要
            let mini = MiniMap.find(in: small, scale: 1).flatMap { $0.intersects(body) || $0.intersects(lay.list) ? $0 : nil }
            return (lay, QuestDetector.fingerprint(small, rect: lay.list, skip: mini), body.isNull ? 0 : QuestDetector.fingerprint(small, rect: body, skip: mini), mini, QuestDetector.tab(in: small, scale: 1, list: lay.list))
        }.value
        guard let (lay, _, fpBody0, miniOver, tab) = found else {
            questMisses += 1
            // 调试：设置了 CT_DEBUG_DUMP 时每 10 次保存一张低分辨率截图
            if let dir = ProcessInfo.processInfo.environment["CT_DEBUG_DUMP"], questMisses % 5 == 1,
               let d = CGImageDestinationCreateWithURL(URL(fileURLWithPath: dir + "/quest-miss.png") as CFURL, "public.png" as CFString, 1, nil) {
                CGImageDestinationAddImage(d, small, nil); CGImageDestinationFinalize(d); trace("quest dump miss \(small.width)x\(small.height)")
            }
            if questMisses >= 2, questLayout != nil { questReset() }
            return
        }
        questMisses = 0
        // 同样的正文换了页签（刚接、刚做完）也要重新看
        let fpBody = fpBody0 == 0 ? 0 : fpBody0 ^ ((tab?.rawValue ?? 3) << 3)
        let level = NSWindow.Level(rawValue: g.layer + 1)
        func screen(_ r: CGRect) -> CGRect { r.offsetBy(dx: win.minX, dy: win.minY) }
        // 内容没变：只跟着窗口挪位置
        if fpBody == questFpBody, let old = questLayout {
            if old != lay { questLayout = lay }
            return
        }
        let client = hoverClient
        let tr = translator!

        // 左侧列表不翻译（用户要求：覆盖后鼠标指过去显示很怪），只翻译右侧详情
        // 右侧详情（标题 + 正文）
        if let h = lay.header, let c = lay.content {
            if fpBody != questFpBody, let (t, obj) = navIds[fpBody] {
                nav.setTarget(t); nav.setProgress(obj)
                questFpBody = fpBody; questLayout = lay
                return
            }
            if fpBody != questFpBody || questLayout?.content != lay.content {
                guard let himg = await withTimeout(3, { await loc.capture(g, rect: h) }),
                      let cimg = await withTimeout(3, { await loc.capture(g, rect: c) }),
                      let hl = await withTimeout(6, { client.recognize(himg) }),
                      let clAll = await withTimeout(6, { client.recognize(cimg) }) else { return }
                // 被小地图盖住的行不要（读到的是小地图的字或残句）
                let cl = clAll.filter { l in
                    guard let miniOver else { return true }
                    let box = CGRect(x: c.minX + l.minX * c.width, y: c.minY + l.minY * c.height, width: (l.maxX - l.minX) * c.width, height: (l.maxY - l.minY) * c.height)
                    return !miniOver.insetBy(dx: 1, dy: 1).intersects(box)
                }.map { l -> OCRLine in var l = l; l.text = NavDB.shared.fixCount(l.text); return l }
                var doc = QuestDoc()
                doc.parseHeader(hl)
                // 标题、等级都没有：不是任务详情（认错了，或窗口刚关掉截到了后面的画面），不显示
                guard !doc.title.isEmpty || !doc.level.isEmpty else { trace("quest: 没读到标题"); questFpBody = 0; return }
                // 滚动拼接：同一个任务，把这次看到的正文接到之前看到的部分上
                let all = questMerger.update(title: doc.title, visible: cl)
                // 灰框（任务摘要 / 目标）和下面的说明分开
                var summary: [String] = [], bodyLines = all
                if let bnd = QuestDetector.summaryBand(in: cimg) {
                    let inBox = cl.filter { ($0.minY + $0.maxY) / 2 < bnd.bottom }
                    summary = QuestDoc.boxBlocks(inBox).filter { !$0.isSummaryTitle && $0.objective == nil }.map(\.text)
                    let boxTexts = Set(inBox.map(\.text))
                    bodyLines = all.filter { !boxTexts.contains($0.text) }
                }
                doc.paragraphs = QuestDoc.parseContent(bodyLines).1
                // 不在游戏窗口上盖译文（用户定）：认出任务、看进度，怎么完成由任务导航用自己的话写。
                // 只用这一屏看到的数字，滚动拼接里可能留着旧的
                let seenObj: [(name: String, count: String)] = QuestDoc.parseContent(cl).objectives.map { (name: ItemNames.clean($0.0), count: $0.1) }
                var target = NavDB.shared.target(title: doc.title, paragraphs: doc.paragraphs, summary: summary.joined(separator: " "), objectives: seenObj)
                if target == nil, !doc.title.isEmpty {
                    // 资料里没有的任务：标题、目标、摘要用系统翻译，只写要做什么
                    var t = NavTarget(title: await tr.translateQuestName(doc.title), start: nil, end: nil, questId: nil)
                    var zh: [String: String] = [:]
                    for o in seenObj { zh[o.name] = await tr.objectiveZh(o.name, title: doc.title, context: all.map(\.text)) }
                    t.zh = zh; t.part = seenObj.isEmpty ? (cl.contains { $0.text.range(of: "[0-9Oo]+\\s*/\\s*[0-9]+", options: .regularExpression) != nil } ? nil : NavTarget.talkPart(doc.paragraphs)) : seenObj.map(\.name).sorted().joined(separator: "|"); t.accepted = seenObj.isEmpty ? nil : true; t.giver = TipPlan.starter(summary + doc.paragraphs + all.map(\.text))
                    var d = QuestDoc(); d.title = doc.title; d.paragraphs = summary.isEmpty ? Array(doc.paragraphs.suffix(1)) : summary
                    let b = (await tr.translateQuest(d)).paragraphs.joined(separator: " ")
                    t.brief = b.isEmpty ? nil : b.count > 90 ? String(b.prefix(90)) + "…" : b
                    t.en = String(([doc.title] + summary + doc.paragraphs).joined(separator: " ").prefix(1500))
                    target = t
                }
                guard questEnabled, !paused else { return }
                // 页签最准：可接 = 没接，进行中 = 接了；已完成的不导航
                switch tab {
                case .available?: let has = target?.start != nil || target?.questId == nil; target?.accepted = false; target?.notStarted = has
                case .inProgress?: target?.accepted = true; target?.notStarted = false
                case .completed?: if let t = target { nav.completed(t) }; target = nil
                case nil: break
                }
                if let t = target {
                    nav.setTarget(t); nav.setProgress(seenObj)
                    if navIds.count > 200 { navIds.removeAll() }
                    navIds[fpBody] = (t, seenObj)
                }
                questFpBody = fpBody
                trace("quest: \(doc.title) → \(target?.title ?? "没认出")，正文 \(all.count) 行，目标 \(seenObj.map { $0.name + " " + $0.count })")
                if let dir = ProcessInfo.processInfo.environment["CT_DEBUG_DUMP"] {
                    for (n, im) in [("quest-h", himg), ("quest-c", cimg)] {
                        if let d = CGImageDestinationCreateWithURL(URL(fileURLWithPath: dir + "/\(n).png") as CFURL, "public.png" as CFString, 1, nil) {
                            CGImageDestinationAddImage(d, im, nil); CGImageDestinationFinalize(d)
                        }
                    }
                }
            }
        } else {
            questFpBody = 0
        }
        questLayout = lay
    }

    // MARK: 个人商店聊天框：和任务窗口共用低分辨率整窗截图找白色聊天框；有变化才截高分辨率识别，记到面板的“店铺聊天”。
    private var shopFp = 0
    private var shopRect: CGRect? = nil          // 聊天框位置（窗口内的点）
    private var shopMisses = 0
    private func shopReset() { shopFp = 0; shopRect = nil; shopMisses = 0 }

    private func shopStep(small: CGImage, g: GameWindowInfo) async {
        let found = await Task.detached { () -> (CGRect, Int, Bool)? in
            guard let r = ShopChatDetector.find(in: small, scale: 1) else { return nil }
            return (r, QuestDetector.fingerprint(small, rect: r), ShopChatDetector.coveredByTooltip(small, r))
        }.value
        guard let (r, fp, covered) = found else {
            guard shopRect != nil else { return }
            // 说明框、鼠标压住边框时会找不到；连续 4 次才算关了
            shopMisses += 1
            if shopMisses >= 4 { trace("shop: 商店关了"); shopReset() }
            return
        }
        expMonitor.stallAt = Date()
        shopMisses = 0
        if shopRect == nil { trace("shop: 聊天框 \(r)") }
        shopRect = r
        if covered || fp == shopFp { return }
        let loc = self.locator, client = hoverClient
        guard let img = await withTimeout(3, { await loc.capture(g, rect: r) }),
              let ls = await withTimeout(6, { client.recognize(img) }) else { return }
        // 游戏里不盖中文（用户定）：只记到面板的“店铺聊天”
        // 只要玩家说的话（“名字 : 内容”）；谁进来、谁离开之类的提示不记（用户定）
        let msgs = ChatParser.parse(ls, systemStarts: glossary.templateRegexes, fullRight: 0.8).filter { $0.kind == .chat }
        let need = shopHistory.sync(visible: msgs, garbled: msgs.map { _ in false })
        for i in need {
            let raw = shopHistory.items[i].raw
            guard let m = msgs.first(where: { $0.raw == raw }) else { continue }
            shopHistory.setChinese(await translateSafe(m), at: i, ifRaw: raw)
        }
        guard questEnabled, !gameHidden else { return }
        shopFp = fp
        side.showShop(shopHistory.items.compactMap { h in h.chinese.map { Entry(original: h.raw, chinese: $0) } })
    }

    // MARK: NPC 对话框：和任务窗口共用同一张低分辨率整窗截图找对话框；文字区有变化才截高分辨率去识别、翻译。
    private var npcLastSeen = Date.distantPast
    private var questLines = Set<String>()
    private func npcStep(small: CGImage, g: GameWindowInfo) async {
        let win = g.frameTopLeft
        let found = await Task.detached { () -> (CGRect, Int)? in
            guard let r = NpcDialogDetector.find(in: small, scale: 1) else { return nil }
            return (r, QuestDetector.fingerprint(small, rect: r))
        }.value
        if let f = found, f.1 != npcFp, npcFirstSeen == .distantPast { npcFirstSeen = Date() }
        guard let (r, fp) = found else {
            npcFirstSeen = .distantPast
            if npcShown || npcFp != 0 || npcSeen {
                // 鼠标最后停在选项或 NEXT 上就关了：是选了（答错会直接关掉）；在 END CHAT 上是自己关的
                if npcPage?.tips != nil, npcPicked, !npcAnswered { trace("npc: 选了就关了"); quiz.answer() }
                trace("npc: 对话框关了")
                npcReset()
                // 调试：存下这一帧（确认是真关了还是没认出来）
                if let dir = ProcessInfo.processInfo.environment["CT_DEBUG_DUMP"],
                   let d = CGImageDestinationCreateWithURL(URL(fileURLWithPath: dir + "/npc-miss-\(npcMissDumps % 5).png") as CFURL, "public.png" as CFString, 1, nil) {
                    CGImageDestinationAddImage(d, small, nil); CGImageDestinationFinalize(d); npcMissDumps += 1
                }
            }
            return
        }
        npcTalk?.t = Date(); npcLastSeen = Date(); nav.talkedAt = npcLastSeen; expMonitor.npcAt = npcLastSeen
        if fp == npcFp {
            npcRect = r
            return
        }
        let now = small.cropping(to: r.integral), mouse = npcMouse(r, win)
        // 只是红箭头换了、鼠标动了：还是这一页，不重新识别（每次重认选项会跳字）
        if let base = npcBase, let now {
            let rows = npcPage?.rows ?? []
            let changed = await Task.detached { Self.npcChanged(base.img, now, rows: rows, mice: [base.mouse, mouse]) }.value
            if !changed {
                npcRect = r
                npcFp = fp; npcFirstSeen = .distantPast
                return
            }
            // 换页了：旧中文马上收起，别盖在新的一页上
            npcHide()
        }
        if let items = npcCache[fp], let page = npcPages[fp] {
            npcShowPage(page)
            let items = npcCache[fp] ?? npcMarked(items, page)      // 刚记下对错：换上新的标记
            if items.isEmpty { npcHide() } else { npcShow(items) }; npcFp = fp; npcRect = r; npcFirstSeen = .distantPast
            npcBase = now.map { ($0, mouse) }
            return
        }
        // 对话框的字是一个个打出来的：隔 0.4 秒再截一次，这一块没变（字打完了）才识别，免得翻成半句。
        // 还在变就等下一轮（每秒一次）；以前要等下一轮才确认，长对话要三四秒才出中文
        if fp != npcPendingFp {
            npcPendingFp = fp
            let whole = CGRect(origin: .zero, size: win.size)
            // 红箭头、鼠标在动不算；还在打字就再等，最多等三次
            var last = now, lastMouse = mouse, still = false
            for _ in 0..<3 where !still {
                try? await Task.sleep(nanoseconds: 300_000_000)
                guard let again = await withTimeout(2, { await self.locator.capture(g, rect: whole, outputScale: 1) })?.cropping(to: r.integral) else { return }
                let a = last, m = [lastMouse, npcMouse(r, win)]
                let arrows = [CGRect(x: 38, y: 0, width: 1, height: r.height)]
                still = await Task.detached { a.map { !Self.npcChanged($0, again, rows: arrows, mice: m) } ?? false }.value
                last = again; lastMouse = m[1]
            }
            guard still else { npcPendingFp = 0; return }
        }
        let loc = self.locator, client = hoverClient
        let tr = translator!
        guard let img = await withTimeout(3, { await loc.capture(g, rect: r) }),
              let ls = await withTimeout(6, { client.recognize(img) }) else { return }
        let W = r.width, H = r.height
        var items: [Entry] = []
        var log: [String] = []
        let blocks = NpcDialog.blocks(ls)
        var page = NpcPage(body: blocks.filter { $0.kind == .body }.map(\.text).joined(separator: " "))
        let opts = blocks.filter { $0.kind == .option }
        page.options = opts.map(\.text)
        page.rows = opts.map { CGRect(x: $0.minX * Double(W), y: $0.minY * Double(H), width: ($0.maxX - $0.minX) * Double(W), height: ($0.maxY - $0.minY) * Double(H)) }
        // 左边头像下面的名字：出题的 NPC 给答案、记对错；被送走时知道是谁送的
        do {
            let left = CGRect(x: r.minX - 140, y: r.minY, width: 136, height: r.height)
            if left.minX >= 0, let im = await withTimeout(3, { await loc.capture(g, rect: left) }), let nl = await withTimeout(6, { client.recognize(im) }) {
                if let n = nl.map(\.text).filter({ $0.filter(\.isLetter).count >= 2 }).max(by: { $0.count < $1.count }) { npcTalk = (n, Date()); mapCollect.talked(n) }
                if opts.count >= 2 { page.tips = QuestTips.quiz(npc: nl.map(\.text), body: page.body) }
                trace("npc: 名字 \(nl.map(\.text)) 要点 \(page.tips ?? [])")
            }
        }
        npcShowPage(page)
        // 有核实过的答案就直接写；没有才写要点
        let answer = page.tips == nil ? nil : QuestTips.answer(body: page.body, options: page.options)
        if answer == nil { for s in page.tips ?? [] { items.append(Entry(original: "", chinese: "要点：" + s, color: Maple.warn)) } }
        page.answer = answer
        let marks = npcMarks(page)
        if let k = marks.first(where: { $0.value == .right })?.key { items.append(Self.npcAnswer(k)) }
        var optIndex = 0
        for b in blocks {
            // 只列选项：说了什么不翻（怎么做由任务助手用自己的话写，用户定；想看某一行按住键指着）
            guard opts.count >= 2, b.kind == .option else { continue }
            var b = b
            b.text = NpcDialog.optionText(b.text)
            let z = await tr.translateNpc(b)
            let mark = marks[optIndex]
            optIndex += 1
            let same = z.filter(\.isLetter).lowercased() == b.text.filter(\.isLetter).lowercased()
            let zh = "\(optIndex). " + (z.isEmpty || same ? b.text : z) + (mark == .right ? "  ✓ 选这个" : mark == .wrong ? "  ✗ 上次选错" : "")
            let color = mark.map { $0 == .right ? Maple.done : Maple.red } ?? Maple.text
            // 带上英文，好和游戏里对
            items.append(Entry(original: z.isEmpty || same ? "" : b.text, chinese: zh, color: color))
            log.append("\(b.text) → \(zh)")
        }
        // 翻译时对话框已经关了：别再显示
        guard npcPage?.body == page.body, !paused, questEnabled else { return }
        if items.isEmpty { npcHide() } else { npcShow(items) }
        if npcCache.count > 200 { npcCache.removeAll(); npcPages.removeAll() }
        npcCache[fp] = items; npcPages[fp] = page
        npcBase = now.map { ($0, mouse) }
        npcFp = fp; npcRect = r
        trace("npc: (\(Int(Date().timeIntervalSince(npcFirstSeen) * 1000)) ms) " + log.joined(separator: " | "))
        npcFirstSeen = .distantPast
        if let dir = ProcessInfo.processInfo.environment["CT_DEBUG_DUMP"],
           let d = CGImageDestinationCreateWithURL(URL(fileURLWithPath: dir + "/npc.png") as CFURL, "public.png" as CFString, 1, nil) {
            CGImageDestinationAddImage(d, img, nil); CGImageDestinationFinalize(d)
        }
    }

    /// 文字颜色：一块区域里除底色以外出现最多的颜色（选项是蓝字、小标题是橙字、说明是深灰字）
    static func inkColor(_ img: CGImage, bg: NSColor) -> NSColor? {
        let w = img.width, h = img.height
        guard w > 0, h > 0, let b = bg.usingColorSpace(.sRGB) else { return nil }
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        let br = Int(b.redComponent * 255), bgc = Int(b.greenComponent * 255), bb = Int(b.blueComponent * 255)
        var count: [Int: Int] = [:]
        for i in stride(from: 0, to: w * h * 4, by: 4) {
            let r = Int(buf[i]), g = Int(buf[i + 1]), bl = Int(buf[i + 2])
            guard abs(r - br) + abs(g - bgc) + abs(bl - bb) > 150 else { continue }
            count[(r >> 4) << 8 | (g >> 4) << 4 | (bl >> 4), default: 0] += 1
        }
        guard let best = count.max(by: { $0.value < $1.value }), best.value >= 8 else { return nil }
        let k = best.key
        return NSColor(srgbRed: CGFloat((k >> 8 & 15) * 16 + 8) / 255, green: CGFloat((k >> 4 & 15) * 16 + 8) / 255,
                       blue: CGFloat((k & 15) * 16 + 8) / 255, alpha: 1)
    }

    /// 取截图某处的颜色（比例坐标，左上原点），用作覆盖块的底色
    nonisolated static func sampleColor(_ img: CGImage, xFrac: Double, yFrac: Double) -> NSColor {
        let x = min(img.width - 1, max(0, Int(Double(img.width) * xFrac)))
        let y = min(img.height - 1, max(0, Int(Double(img.height) * yFrac)))
        guard let c = img.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)),
              let ctx = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return .white }
        ctx.draw(c, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        guard let d = ctx.data?.assumingMemoryBound(to: UInt8.self) else { return .white }
        return NSColor(srgbRed: CGFloat(d[0]) / 255, green: CGFloat(d[1]) / 255, blue: CGFloat(d[2]) / 255, alpha: 1)
    }

    /// 每一行取出现最多的颜色，拼成 1 像素宽的背景图（文字只占少数，取到的是底色；横向的渐变、高光线都保留）。
    /// 用截图自己的色彩空间读写，画出来和原画面颜色完全一致。
    static func rowBackground(_ img: CGImage) -> CGImage? {
        let w = img.width, h = img.height
        guard w > 0, h > 0 else { return nil }
        let cs = img.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        var out = [UInt8](repeating: 255, count: h * 4)
        for y in 0..<h {
            var count: [UInt32: Int] = [:]
            let row = y * w * 4
            for x in 0..<w {
                let i = row + x * 4
                let key = UInt32(buf[i]) << 16 | UInt32(buf[i + 1]) << 8 | UInt32(buf[i + 2])
                count[key, default: 0] += 1
            }
            if let best = count.max(by: { $0.value < $1.value })?.key {
                out[y * 4] = UInt8(best >> 16 & 255); out[y * 4 + 1] = UInt8(best >> 8 & 255); out[y * 4 + 2] = UInt8(best & 255)
            }
        }
        guard let octx = CGContext(data: &out, width: 1, height: h, bitsPerComponent: 8, bytesPerRow: 4,
                                   space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        return octx.makeImage()
    }

    /// 整块区域出现最多的那一种颜色，做成 1×1 的底图（用截图自己的色彩空间，和原画面颜色完全一样）。
    /// 用在字带阴影、底下有装饰线的小标题：按行取色会把线画成横杠，纯色又不能偏白偏灰。
    static func flatBackground(_ img: CGImage) -> CGImage? {
        let w = img.width, h = img.height
        guard w > 0, h > 0 else { return nil }
        let cs = img.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        var count: [UInt32: Int] = [:]
        for i in stride(from: 0, to: w * h * 4, by: 4) {
            count[UInt32(buf[i]) << 16 | UInt32(buf[i + 1]) << 8 | UInt32(buf[i + 2]), default: 0] += 1
        }
        guard let best = count.max(by: { $0.value < $1.value })?.key else { return nil }
        var out: [UInt8] = [UInt8(best >> 16 & 255), UInt8(best >> 8 & 255), UInt8(best & 255), 255]
        guard let octx = CGContext(data: &out, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                   space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        return octx.makeImage()
    }

    /// 一块区域里出现最多的颜色（背景色；文字笔画占少数）
    static func dominantColor(_ img: CGImage, rect: CGRect) -> NSColor {
        let r = rect.integral.intersection(CGRect(x: 0, y: 0, width: img.width, height: img.height))
        guard r.width >= 1, r.height >= 1, let crop = img.cropping(to: r) else { return .white }
        let w = crop.width, h = crop.height
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return .white }
        ctx.draw(crop, in: CGRect(x: 0, y: 0, width: w, height: h))
        var count: [Int: Int] = [:]
        for i in stride(from: 0, to: w * h * 4, by: 8) {
            let key = Int(buf[i] >> 3) << 10 | Int(buf[i + 1] >> 3) << 5 | Int(buf[i + 2] >> 3)
            count[key, default: 0] += 1
        }
        guard let best = count.max(by: { $0.value < $1.value })?.key else { return .white }
        let r5 = CGFloat(best >> 10 & 31), g5 = CGFloat(best >> 5 & 31), b5 = CGFloat(best & 31)
        return NSColor(srgbRed: (r5 * 8 + 4) / 255, green: (g5 * 8 + 4) / 255, blue: (b5 * 8 + 4) / 255, alpha: 1)
    }

    static func textColor(on bg: NSColor) -> NSColor {
        guard let c = bg.usingColorSpace(.sRGB) else { return .black }
        let lum = 0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent
        return lum < 0.6 ? .white : .black
    }

    @objc private func toggleTip() { tipEnabled.toggle(); hideTips(); rebuildMenu() }
    @objc private func pickTipMode(_ s: NSMenuItem) {
        if let raw = s.representedObject as? String, let t = TipMode(rawValue: raw) { tipMode = t }
        hideTips(); rebuildMenu()
    }
    private func hideTips() { tipPanels.forEach { $0.hide() }; tipInPlace.forEach { $0.hide() } }
    private let tipLog = ProcessInfo.processInfo.environment["CT_TIP_LOG"] != nil
    private func tipHide(_ why: String) {
        if tipPanels.contains(where: { $0.panel.isVisible }) || tipInPlace.contains(where: { $0.isVisible }) { trace("tip hide: \(why)") }
        hideTips()
    }

    // MARK: 物品说明框：鼠标停下后，在鼠标附近找深蓝色说明框，识别并翻译
    // 只读取光标位置并截图，不监听键盘、不操作游戏。

    private var tipNames: [Int: String] = [:]
    private func tooltipTick() async {
        // 物品说明关着时，只在背包开着的时候看（取图标用），不显示
        let bagOpen = expEnabled && (expMonitor.model.mesoSeen.map { Date().timeIntervalSince($0) < 3 } ?? false)
        guard tipEnabled || bagOpen, !paused, !selecting, !tipBusy, !gameHidden, let g = locator.current else { return }
        let mouse = NSEvent.mouseLocation
        if hypot(mouse.x - lastMouse.x, mouse.y - lastMouse.y) > 2 { lastMouse = mouse; mouseStillSince = Date() }
        let m = Coords.toTopLeft(mouse)
        let win = g.frameTopLeft
        guard win.contains(m) else { tipMisses += 1; if tipMisses >= 2 { tipReset("鼠标不在游戏窗口") }; return }
        guard Date().timeIntervalSince(mouseStillSince) >= 0.15 else { return }
        // 鼠标离开了上次锁定的位置：之前的框作废
        if !tipLocked.isEmpty, hypot(mouse.x - lastTipMouse.x, mouse.y - lastTipMouse.y) > 2 {
            tipLocked = []; tipCandidate = []
        }

        // 截图会占用显卡、拖慢游戏（游戏自己画的鼠标会变卡），所以尽量少截：
        // 在同一个位置找了两次都没有说明框，就等鼠标移动后再找
        // （放弃后仍每 1.5 秒再试一次：游戏的说明框有时出得慢，尤其是要并排显示两个框的装备）
        if tipLocked.isEmpty, tipGaveUpAt == mouseStillSince, Date().timeIntervalSince(tipLastTry) < 1.5 { return }
        let loc = self.locator
        tipTicks += 1

        // 已经锁定（鼠标没动、框已显示）：每 0.6 秒只截框顶部一小条确认框还在，不重新识别、不重新排版
        if !tipLocked.isEmpty {
            guard tipTicks % 3 == 0 else { return }
            tipBusy = true; defer { tipBusy = false }
            let r = tipLocked[0]
            // 只看框中间那一段（左右边界可能按并排的另一个框补宽过）。框顶部可能多算了一截、框正中可能是职业那一行（黑底小格），
            // 所以顶部和中间各看一条，任一条像说明框就算还在
            let strips = Self.tipStrips(r, scale: tipScale, win: win.size)
            var still = false
            for (k, st) in strips.enumerated() {
                guard let img = await withTimeout(3, { await loc.capture(g, rect: st) }) else { return }
                // 和显示时那张截图里同一位置比：基本没变就是框还在（框背后是白色窗口时“像不像说明框”会误判）
                if k < tipRefStrips.count, let ref = tipRefStrips[k] {
                    if Self.imagesClose(ref, img) { still = true; break }
                } else if await Task.detached(operation: { TooltipDetector.looksLikeBox(img) }).value { still = true; break }
            }
            if still { tipMisses = 0 } else {
                tipMisses += 1
                // 连续 3 次（约 1.8 秒）都看不到才算框没了；平时框消失都是因为鼠标移开，那个由 tipQuickHide 立刻处理
                if tipMisses >= 3 { tipReset("说明框消失了") }
            }
            return
        }

        tipBusy = true; defer { tipBusy = false }
        tipLastTry = Date()
        // 截整个游戏窗口（说明框可能很大，比如宠物说明能占半个画面）
        let cap = CGRect(origin: .zero, size: win.size)
        guard let img = await withTimeout(3, { await loc.capture(g, rect: cap) }) else { return }
        let scale = CGFloat(img.width) / cap.width
        tipScale = scale
        let local = CGPoint(x: m.x - win.minX, y: m.y - win.minY)
        let cursorPx = CGPoint(x: local.x * scale, y: local.y * scale)

        // 找框在后台线程做，不占主线程
        let found: [CGRect]? = await Task.detached { () -> [CGRect]? in
            guard let first = TooltipDetector.find(in: img, cursor: cursorPx, scale: scale) else { return nil }
            // 装备会并排出现两个框（当前物品 + 身上装备），在第一个框左右再找一个
            var rects = [first.rect]
            // 并排的框高度不同、背后画面也不同，只试一个点常常找不到：左右各试几个高度
            var probes: [CGPoint] = []
            for dy in [30.0, 70.0, 120.0, 170.0] {
                probes.append(CGPoint(x: first.rect.maxX + 16 * scale, y: first.rect.minY + dy * scale))
                probes.append(CGPoint(x: first.rect.minX - 16 * scale, y: first.rect.minY + dy * scale))
            }
            for probe in probes where probe.x >= 0 && probe.x < CGFloat(img.width) && probe.y < CGFloat(img.height) {
                // 先只看这一个点是不是说明框的深蓝（很快）；不是就不用整张图去找
                guard let c = Self.sampleColor(img, xFrac: Double(probe.x) / Double(img.width), yFrac: Double(probe.y) / Double(img.height)).usingColorSpace(.sRGB) else { continue }
                let (pr, pg, pb) = (Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
                guard pr <= 95, pg <= 100, pb >= 45, pb <= 150 else { continue }
                if let other = TooltipDetector.find(in: img, cursor: probe, scale: scale),
                   !other.rect.intersects(first.rect), abs(other.rect.minY - first.rect.minY) < 40 * scale {
                    rects.append(other.rect); break
                }
            }
            return rects
        }.value
        guard var rects = found else {
            tipMisses += 1
            tipSpotMisses += 1
            // 鼠标刚停下时游戏的说明框可能还没出来：停够 1.2 秒都没找到才放弃
            if tipSpotMisses >= 2, Date().timeIntervalSince(mouseStillSince) > 1.2 {
                if tipGaveUpAt != mouseStillSince { trace("tip 没找到说明框 cursor=\(Int(cursorPx.x)),\(Int(cursorPx.y)) img=\(img.width)x\(img.height) win=\(Int(win.width))x\(Int(win.height))") }
                tipGaveUpAt = mouseStillSince; tipSpotMisses = 0
            }
            if tipMisses >= 2 { tipReset("鼠标附近没找到说明框 cursor=\(Int(cursorPx.x)),\(Int(cursorPx.y))") }
            dumpTip(img, "miss")
            return
        }
        tipMisses = 0; tipSpotMisses = 0
        rects.sort { $0.minX < $1.minX }
        // 并排的两个装备框宽度相同；背景干扰时某个框可能认窄了，按宽的那个补齐（左框往左、右框往右补）
        if rects.count == 2 {
            let wMax = max(rects[0].width, rects[1].width)
            rects[0] = CGRect(x: rects[0].maxX - wMax, y: rects[0].minY, width: wMax, height: rects[0].height)
            rects[1] = CGRect(x: rects[1].minX, y: rects[1].minY, width: wMax, height: rects[1].height)
            rects = rects.map { $0.intersection(CGRect(x: 0, y: 0, width: img.width, height: img.height)) }
        }
        // 连续两帧找到的框一致才算稳定，再去识别（避免半个框被识别、显示后又变）
        let same = rects.count == tipCandidate.count && zip(rects, tipCandidate).allSatisfy {
            abs($0.minX - $1.minX) <= 6 && abs($0.minY - $1.minY) <= 6 && abs($0.maxX - $1.maxX) <= 6 && abs($0.maxY - $1.maxY) <= 6
        }
        tipCandidate = rects
        guard same else {
            tipUnstable += 1
            if tipUnstable % 5 == 0 { trace("tip 框位置不稳定 \(tipUnstable) 次 \(rects.map { "\(Int($0.minX)),\(Int($0.minY)),\(Int($0.width))x\(Int($0.height))" })") }
            return
        }
        tipUnstable = 0

        // 原地替换：逐行盖住英文。所有框都识别、翻译完再一起显示（一个一个显示时，前一个会被“鼠标移开”误收起）
        if tipMode == .overlay {
            // 并排两个装备框偶尔被认成一个大框（两倍宽）：从中间分开
            var boxes: [CGRect] = []
            for r in rects {
                // 只在中间真有一道缝（不像框底的竖条）时才分开；技能说明框本身就很宽，是一整块
                if r.width / scale > 400, let gx = TooltipDetector.gapColumn(img, r) {
                    boxes.append(CGRect(x: r.minX, y: r.minY, width: gx - r.minX - 2 * scale, height: r.height))
                    boxes.append(CGRect(x: gx + 2 * scale, y: r.minY, width: r.maxX - gx - 2 * scale, height: r.height))
                } else { boxes.append(r) }
            }
            let tight = await Task.detached { boxes.map { TooltipDetector.tighten(img, $0, scale: scale) } }.value
            var ready: [(CGRect, [TooltipPiece])] = []
            for r in tight.prefix(tipInPlace.count) {
                guard let cleaned = await Task.detached(operation: { TooltipDetector.cleaned(img, rect: r) }).value else { continue }
                let key = cleaned.fingerprint
                if let c = tipPieceCache[key] {
                    if let n = tipNames[key] { IconStore.shared.offer(n, await Task.detached { IconGrab.tooltip(img, box: r, scale: Int(scale)) }.value) }
                    ready.append((r, c)); continue
                }
                let client = self.hoverClient
                let image = cleaned.image
                guard let lines = await withTimeout(5, { client.recognize(image) }) else { return }
                let ps = await translator!.translateTooltipPieces(lines, boxHeightPt: Double(r.height / scale))
                guard !ps.isEmpty else { continue }
                if tipPieceCache.count > 300 { tipPieceCache.removeAll() }
                tipPieceCache[key] = ps
                // 说明框里有名字和大图标：顺便取图标
                if let en = ItemDB.shared.screenName(TooltipDoc.parse(lines, glossary: glossary).title) {
                    tipNames[key] = en
                    IconStore.shared.offer(en, await Task.detached { IconGrab.tooltip(img, box: r, scale: Int(scale)) }.value)
                    // 说明框会淡入：再截一次，两次一样才要
                    let cr = CGRect(x: r.minX / scale, y: r.minY / scale, width: r.width / scale, height: r.height / scale)
                    if let again = await withTimeout(2, { await loc.capture(g, rect: cr, outputScale: scale) }) {
                        IconStore.shared.offer(en, await Task.detached { IconGrab.tooltip(again, box: CGRect(x: 0, y: 0, width: again.width, height: again.height), scale: Int(scale)) }.value)
                    }
                }
                trace("tooltip 原地: " + ps.map(\.zh).joined(separator: " | "))
                dumpTip(img, "ok")
                ready.append((r, ps))
            }
            guard !ready.isEmpty else { return }
            guard hypot(NSEvent.mouseLocation.x - mouse.x, NSEvent.mouseLocation.y - mouse.y) <= 2 else { return }
            // 先记下位置再显示，免得“鼠标移开”检查拿旧位置比较把刚显示的收掉
            lastTipMouse = mouse
            tipLocked = rects
            // 参考画面：就从这张（一定有说明框的）截图里取，和之后确认时截的细条同样位置、同样大小
            tipRefStrips = Self.tipStrips(rects[0], scale: scale, win: win.size).map { st in
                img.cropping(to: CGRect(x: st.minX * scale, y: st.minY * scale, width: st.width * scale, height: st.height * scale).integral)
            }
            tipInPlace.forEach { $0.hide() }; tipPanels.forEach { $0.hide() }
            guard tipEnabled else { return }
            for (i, (r, ps)) in ready.enumerated() {
                let bw = r.width / scale, bh = r.height / scale
                var items: [OverlayItem] = []
                let boxImg = img.cropping(to: r.integral)
                let boxBg = boxImg.flatMap { Self.flatBackground($0) }
                var jobsRowDone = Set<Int>()
                let boxColor = boxImg.map { Self.dominantColor($0, rect: CGRect(x: 0, y: 0, width: $0.width, height: $0.height)) } ?? NSColor(srgbRed: 0.1, green: 0.12, blue: 0.35, alpha: 1)
                for p in ps {
                    // 物品名、说明、属性盖到右边；需求、职业只盖自己那一格（旁边还有别的字）
                    let wide = p.kind == .title || p.kind == .desc || p.kind == .stat || p.kind == .flag
                    let small = p.kind == .req || p.kind == .gray || p.kind == .jobs
                    let x0 = max(0, CGFloat(p.minX) * bw - 3), x1 = wide ? bw - 6 : min(bw - 4, CGFloat(p.maxX) * bw + 4)
                    // 需求、职业这几行用固定字号（按识别出的行高算，左右两个框会一大一小）；行框不够高就上下撑开
                    let fs: CGFloat = p.kind == .jobs || (p.kind == .gray && !p.zh.contains("：")) ? 10.5 : small ? 9.5 : (p.kind == .title ? 13 : 12)
                    var y0 = max(0, CGFloat(p.minY) * bh - (small ? 2 : 1)), y1 = min(bh, CGFloat(p.maxY) * bh + (small ? 2 : 1))
                    if small, y1 - y0 < fs + 4 { let mid = (y0 + y1) / 2; y0 = max(0, mid - (fs + 4) / 2); y1 = min(bh, mid + (fs + 4) / 2) }
                    let rr = CGRect(x: x0, y: y0, width: max(10, x1 - x0), height: y1 - y0)
                    let fg: NSColor = (p.kind == .jobs || p.kind == .flag) ? NSColor(srgbRed: 1, green: 0.6, blue: 0.2, alpha: 1)
                        : p.kind == .gray ? NSColor(srgbRed: 0.55, green: 0.56, blue: 0.66, alpha: 1) : .white
                    let multi = p.kind == .desc && (p.maxY - p.minY) * Double(bh) > 22
                    // 需求、职业这几行字很小（像素字体），中文字号按行高来，不然会被压扁、裁掉
                    // 职业行：整行先擦干净（连游戏的黑色小底框一起擦掉，两个框看起来一样），每个职业的字直接写在上面
                    if p.kind == .jobs || (p.kind == .gray && !p.zh.contains("：")) {   // 灰色的职业（灰色需求行带“：”）
                        if !jobsRowDone.contains(Int(rr.minY)) {
                            jobsRowDone.insert(Int(rr.minY))
                            // 黑色小底框比字高一点：上下各多擦 3 点
                            let row = CGRect(x: bw * 0.02, y: max(0, rr.minY - 3), width: bw * 0.96, height: min(bh - max(0, rr.minY - 3), rr.height + 6))
                            if let rc = img.cropping(to: CGRect(x: r.minX + row.minX * scale, y: r.minY + row.minY * scale, width: row.width * scale, height: row.height * scale).integral) {
                                items.append(OverlayItem(rect: row, text: "", bg: boxColor, bgImage: TooltipDetector.eraseText(rc, whole: true) ?? boxBg, fg: fg, fontSize: fs))
                            }
                        }
                        items.append(OverlayItem(rect: rr, text: p.zh, bg: .clear, bgImage: nil, fg: fg, fontSize: fs, padX: 1, center: true))
                        continue
                    }
                    let crop = img.cropping(to: CGRect(x: r.minX + rr.minX * scale, y: r.minY + rr.minY * scale, width: rr.width * scale, height: rr.height * scale).integral)
                    let erased = crop.flatMap { TooltipDetector.eraseText($0) } ?? boxBg
                    // 原来是什么颜色就用什么颜色写（红字＝需求没达到、彩色物品名等）；
                    // 括号里加减的数值（“+6 (5 +1)” 的 “+1”）颜色不同就单独上色
                    var fgFinal = fg
                    var accent: (String, NSColor)? = nil
                    if p.kind != .gray, p.kind != .jobs, let c = crop, let tc = TooltipDetector.textColor(c) {
                        if p.kind != .desc || TooltipDetector.mostlyRed(c) {
                            fgFinal = NSColor(srgbRed: CGFloat(tc.r) / 255, green: CGFloat(tc.g) / 255, blue: CGFloat(tc.b) / 255, alpha: 1)
                        }
                        if p.kind == .stat, let m = p.zh.range(of: "[+-]\\s*[0-9]+\\s*[）)]$", options: .regularExpression) {
                            let tailW = CGFloat(p.maxX - p.minX) * bw * 0.2
                            let tailX = CGFloat(p.maxX) * bw - tailW
                            if let tcrop = img.cropping(to: CGRect(x: r.minX + tailX * scale, y: r.minY + rr.minY * scale, width: tailW * scale, height: rr.height * scale).integral),
                               let t2 = TooltipDetector.accentColor(tcrop, base: tc) {
                                accent = (String(p.zh[m].dropLast()), NSColor(srgbRed: CGFloat(t2.r) / 255, green: CGFloat(t2.g) / 255, blue: CGFloat(t2.b) / 255, alpha: 1))
                            }
                        }
                    }
                    items.append(OverlayItem(rect: rr, text: p.zh, bg: boxColor, bgImage: erased, fg: fgFinal,
                                             fontSize: fs, bold: p.kind == .title, wrap: multi, padX: small ? 1 : 2,
                                             accentSuffix: accent?.0, accentColor: accent?.1))
                }
                let screenBox = CGRect(x: win.minX + r.minX / scale, y: win.minY + r.minY / scale, width: bw, height: bh)
                tipInPlace[i].show(items, area: screenBox, level: NSWindow.Level(rawValue: max(NSWindow.Level.popUpMenu.rawValue, g.layer + 2)))
                trace("tip 原地 show[\(i)] box=\(screenBox.integral) items=\(items.count)")
            }
            return
        }

        var shown: [(TooltipZh, CGRect)] = []
        for r in rects {
            guard let cleaned = await Task.detached(operation: { TooltipDetector.cleaned(img, rect: r) }).value else { continue }
            let key = cleaned.fingerprint
            let zh: TooltipZh
            if let c = tipCache[key] {
                zh = c
            } else {
                let client = self.hoverClient
                let image = cleaned.image
                guard let lines = await withTimeout(5, { client.recognize(image) }) else { return }
                let doc = TooltipDoc.parse(lines, glossary: glossary)
                guard !doc.title.isEmpty else { continue }
                let tr = translator!
                zh = await tr.translateTooltip(doc)
                if tipCache.count > 300 { tipCache.removeAll() }
                tipCache[key] = zh
                trace("tooltip: \(doc.title) → \(zh.title)")
                dumpTip(img, "ok")
            }
            let screenBox = CGRect(x: win.minX + r.minX / scale, y: win.minY + r.minY / scale,
                                   width: r.width / scale, height: r.height / scale)
            shown.append((zh, screenBox))
        }
        guard !shown.isEmpty else { return }
        // 识别期间鼠标动了：作废这次结果
        guard hypot(NSEvent.mouseLocation.x - mouse.x, NSEvent.mouseLocation.y - mouse.y) <= 2 else { return }

        hideTips()
        for (i, (zh, box)) in shown.enumerated() where i < tipPanels.count {
            tipPanels[i].panel.level = NSWindow.Level(rawValue: max(NSWindow.Level.popUpMenu.rawValue, g.layer + 2))
            tipPanels[i].show(zh, box: box, game: win, mode: tipMode)
            if tipLog { trace("tip show[\(i)] box=\(box.integral) panel=\(tipPanels[i].panel.frame.integral)") }
        }
        tipLocked = rects
        lastTipMouse = mouse
    }

    /// 鼠标离开显示翻译时的位置超过 6 点：游戏里的说明框已经收起了，翻译也立刻收起
    private func tipQuickHide() {
        guard !tipLocked.isEmpty || tipPanels.contains(where: { $0.panel.isVisible }) || tipInPlace.contains(where: { $0.isVisible }) else { return }
        let m = NSEvent.mouseLocation
        if hypot(m.x - lastTipMouse.x, m.y - lastTipMouse.y) > 6 { tipReset("鼠标移开") }
    }

    /// 确认说明框还在时截的两条细条（窗口内的点坐标）：框顶部和正中，各取中间 60% 宽
    static func tipStrips(_ r: CGRect, scale: CGFloat, win: CGSize) -> [CGRect] {
        let x = r.minX / scale + r.width / scale * 0.2, w = r.width / scale * 0.6
        let all = CGRect(origin: .zero, size: win)
        return [CGRect(x: x, y: r.minY / scale + 4, width: w, height: 24), CGRect(x: x, y: r.midY / scale - 12, width: w, height: 24)]
            .map { $0.intersection(all).integral }
    }

    /// 两张同样大小的截图差不多（平均每个点每个颜色差不到 12）
    nonisolated static func imagesClose(_ a: CGImage, _ b: CGImage) -> Bool {
        guard abs(a.width - b.width) <= 2, abs(a.height - b.height) <= 2,
              let (x, wa, _) = TooltipDetector.rgbaPublic(a), let (y, wb, _) = TooltipDetector.rgbaPublic(b) else { return false }
        let w = min(a.width, b.width), h = min(a.height, b.height)
        var d = 0
        for yy in 0..<h { for xx in 0..<w {
            let i = (yy * wa + xx) * 4, j = (yy * wb + xx) * 4
            d += abs(Int(x[i]) - Int(y[j])) + abs(Int(x[i + 1]) - Int(y[j + 1])) + abs(Int(x[i + 2]) - Int(y[j + 2]))
        } }
        return d / max(1, w * h * 3) < 12
    }

    private func tipReset(_ why: String) {
        tipRefStrips = []
        tipHide(why)
        tipLocked = []; tipCandidate = []; tipMisses = 0
    }

    /// 调试用：只有设置了 CT_DEBUG_DUMP 才保存说明框截图（正常使用不写任何文件）
    private func dumpTip(_ img: CGImage, _ tag: String) {
        guard let dir = ProcessInfo.processInfo.environment["CT_DEBUG_DUMP"] else { return }
        if tipDumpCount >= 40 { tipDumpCount = 0 }     // 循环覆盖，最新的总能存下
        if tag == "miss", Date().timeIntervalSince(mouseStillSince) < 1 || lastMissDumpAt == mouseStillSince { return }
        if tag == "miss" { lastMissDumpAt = mouseStillSince }
        let url = URL(fileURLWithPath: dir + "/tip-\(tipDumpCount)-\(tag).png")
        if let d = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) {
            CGImageDestinationAddImage(d, img, nil); CGImageDestinationFinalize(d)
            trace("tip dump \(url.lastPathComponent)")
            tipDumpCount += 1
        }
    }

    @objc private func pickSideFontSize(_ s: NSMenuItem) {
        UserDefaults.standard.set(s.tag, forKey: "sideFontSize")
        side.chatFontSize = CGFloat(s.tag)
        rebuildMenu()
    }
    @objc private func togglePause() { paused.toggle(); if paused { hideOverlays() }; applyMode(); rebuildMenu() }
    /// 盖在游戏画面上的翻译全收起来
    private func hideOverlays() { questReset(); npcReset(); shopReset(); tipReset("收起"); navArrow.hide() }
    @objc private func clearHistory() { history.removeAll(); chatHistory.clear(); shopHistory.clear(); side.show(history); side.showShop([]) }

    /// 重新启动自己（授权屏幕录制后需要重启才生效）
    @objc private func relaunch() {
        let url = Bundle.main.bundleURL
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: url, configuration: cfg) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    @objc private func selectRegion() {
        guard let g = locator.current else { setStatus("未找到游戏窗口，请先打开游戏"); return }
        selecting = true
        hideAll()
        selector.begin(game: g.frameTopLeft) { [weak self] r in
            guard let self else { return }
            self.selecting = false
            if let r {
                self.saveRegion(.from(rectInWindow: r, windowSize: g.frameTopLeft.size), for: g.frameTopLeft.size)
                self.lastFingerprint = []
            }
            self.applyMode()
        }
    }

    private func setStatus(_ s: String) {
        statusLine.title = s
        side.setStatus(s.replacingOccurrences(of: " · 窗口 ", with: " · "), ok: s.hasPrefix("运行中"))
    }

    private func hideAll() {
        side.panel.orderOut(nil); navArrow.hide()
    }

    private func applyMode() {
        hideAll()
        guard !paused, !selecting, locator.current != nil else { return }
        // 切换模式时立刻摆好位置、显示已有内容，不等下一次识别
        let g = locator.current!
        lastFingerprint = []
        side.place(beside: g.frameTopLeft); side.show(history); side.panel.orderFrontRegardless()
    }

    // MARK: 聊天框：每秒截一次

    private func chatTick() async {
        // 万一某一步卡住超过 15 秒，强制解除，下一秒重新开始
        if busy, Date().timeIntervalSince(busySince) > 15 { trace("tick stuck, reset"); busy = false }
        guard !busy, !selecting else { return }
        busy = true; busySince = Date(); defer { busy = false }

        // 引导没做完（没点“开始使用”，或没有屏幕录制权限）：不截图、不出面板
        if Welcome.needed {
            if locator.current != nil || side.panel.isVisible { hideAll(); side.panel.orderOut(nil) }
            return
        }
        if side.selectButton.action != #selector(selectRegion) {
            side.selectButton.title = "框选聊天区域"
            side.selectButton.action = #selector(selectRegion)
        }

        let had = locator.current != nil
        let lastGood = locator.current
        await locator.refresh()
        if locator.current == nil, let lastGood, missCount < 3 {
            // 系统偶尔会有一瞬间不报告游戏窗口；连续 3 秒都找不到才认为游戏真的不在了
            missCount += 1
            locator.restore(lastGood)
        } else if locator.current != nil {
            missCount = 0
        }
        guard let g = locator.current else {
            trace("no game window")
            if had || missCount > 0 { hideAll(); missCount = 0 }
            setStatus("未找到游戏窗口（请打开冒险岛，窗口模式）")
            return
        }
        if !had {
            trace("game window found layer=\(g.layer)")
            setStatus(ocrReady ? "已找到游戏窗口" : "已找到游戏窗口，正在启动文字识别（第一次需要几秒）…")
            applyMode()
        }
        // 游戏窗口最小化 / 切走：所有翻译已收起，这一轮不截图、不显示
        if gameHidden { return }
        let size = g.frameTopLeft.size
        guard let reg = region(for: size) else {
            setStatus("第一次使用这个窗口大小（\(Int(size.width))×\(Int(size.height))）：请点右上角「框选聊天区域」，框出聊天框里的文字")
            side.place(beside: g.frameTopLeft)
            if !side.panel.isVisible { sideBehind = false; side.panel.orderFrontRegardless() }
            return
        }
        let rectInWin = reg.rectInWindow(windowSize: size)
        let screenRect = rectInWin.offsetBy(dx: g.frameTopLeft.minX, dy: g.frameTopLeft.minY)

        // 悬浮窗、覆盖层始终比游戏窗口高一级（游戏激活时会提高自己的层级）
        let above = NSWindow.Level(rawValue: max(NSWindow.Level.floating.rawValue, g.layer + 1))
        if !sideBehind, side.panel.level != above { side.panel.level = above }

        // 跟着游戏窗口移动
        side.place(beside: g.frameTopLeft)
        if paused { setStatus("已暂停"); return }

        let locator = self.locator
        guard let img = await withTimeout(5, { await locator.capture(g, rect: rectInWin) }) else {
            trace("capture failed/timeout")
            setStatus("截图失败：请在 系统设置 → 隐私与安全性 → 屏幕录制 中允许本程序，然后重新打开")
            return
        }
        // 调试用：只有设置了环境变量 CT_DEBUG_DUMP 才把截图写到指定目录（正常使用不会写任何文件）
        if let dir = ProcessInfo.processInfo.environment["CT_DEBUG_DUMP"],
           let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: dir + "/chat-\(dumpIndex % 20).png") as CFURL, "public.png" as CFString, 1, nil) {
            CGImageDestinationAddImage(dest, img, nil); CGImageDestinationFinalize(dest)
            trace("dump #\(dumpIndex % 20) \(img.width)x\(img.height)")
            dumpIndex += 1
        }
        // 画面没变就不重复识别
        let fp = fingerprint(img)
        if fp == lastFingerprint { return }

        let started = Date()
        let client = self.ocrClient
        guard let allLines = await withTimeout(8, { client.recognize(ChatOCR.brighten(img)) }) else {
            trace("ocr busy/timeout")
            if let n = client.notice { setStatus(n) } else if !ocrReady { setStatus("正在启动文字识别…") }
            return
        }
        ocrReady = true
        // 商店窗口、物品说明框盖住的那几行读到的是残句和别的窗口里的字：不要
        var covers: [CGRect] = shopRect.map { ShopChatDetector.window($0) } ?? []
        // 任务窗口、NPC 对话框压在聊天框上：被挡的那几行是半句
        if let q = questLayout {
            let r = [q.header, q.content].compactMap { $0 }.reduce(q.list) { $0.union($1) }
            covers.append(CGRect(x: r.minX - 10, y: r.minY - 52, width: r.width + 34, height: r.height + 92))
        }
        if let r = npcRect { covers.append(CGRect(x: r.minX - 152, y: r.minY - 20, width: r.width + 170, height: r.height + 64)) }
        covers += tipLocked.map { CGRect(x: $0.minX / tipScale, y: $0.minY / tipScale, width: $0.width / tipScale, height: $0.height / tipScale) }
        covers = covers.map { $0.intersection(rectInWin) }.filter { !$0.isNull && $0.width > 4 && $0.height > 2 }
        let lines = covers.isEmpty ? allLines : allLines.filter { l in
            let y0 = rectInWin.minY + CGFloat(l.minY) * rectInWin.height, y1 = rectInWin.minY + CGFloat(l.maxY) * rectInWin.height
            return !covers.contains { min($0.maxY, y1) - max($0.minY, y0) > 2 }
        }
        let parsed = ChatParser.parse(lines, systemStarts: glossary.templateRegexes)
        // 认花了的消息（固定句子能对上的除外）：翻译记录里保留原来那条
        let garbled = parsed.map { !glossary.matchesFixed($0.raw) && (ChatParser.looksGarbled($0, knownWords: knownWords) || ChatParser.lonelyName($0)) }
        let msgs = zip(parsed, garbled).filter { !$0.1 }.map(\.0)
        let appName = g.scWindow.owningApplication?.applicationName ?? "?"
        // 菜单宽度由最长的一行决定：状态写短一点（游戏名不写），菜单就不会撑得很宽
        _ = appName
        setStatus("运行中 · 窗口 \(Int(size.width))×\(Int(size.height)) · 识别 \(Int(Date().timeIntervalSince(started) * 1000)) ms")

        // 翻译记录和聊天框保持同样的顺序：用这一屏去对齐记录末尾
        let firstSync = chatHistory.items.isEmpty
        let need = chatHistory.sync(visible: parsed, garbled: garbled)
        // 交任务得的金币会写在聊天框里（捡钱不会）。刚和 NPC 说过话才算；刚启动时看到的是旧的，不算
        if firstSync { nav.startLines(chatHistory.items.filter { $0.speaker == nil }.map(\.raw)) }
        if !firstSync, Date().timeIntervalSince(npcLastSeen) < 30 {
            for i in need where questLines.insert(chatHistory.items[i].raw + "\(i)").inserted {
                if chatHistory.items[i].speaker == nil {
                    let raw = chatHistory.items[i].raw
                    if raw.range(of: "^You (have )?(received|gained) (EXP|experience) ?\\(", options: [.regularExpression, .caseInsensitive]) != nil, quiz.reward() {
                        trace("npc: 得了经验，这题选对了"); npcSave()
                    }
                    if let r = raw.range(of: "^You have lost mesos? ?\\(-[0-9,.]+\\)", options: [.regularExpression, .caseInsensitive]), let v = Int(raw[r].filter(\.isNumber)) { expMonitor.chatLost(v) }
                    nav.chatItem(raw); nav.questLine(raw)
                }
                if let v = PickupTracker.questValue(chatHistory.items[i].raw), chatHistory.items[i].speaker == nil { expMonitor.questMesos(v) }
            }
        }
        trace("lines=\(lines.count) msgs=\(parsed.count) translate=\(need.count)")
        let byRaw = Dictionary(parsed.map { ($0.raw, $0) }, uniquingKeysWith: { a, _ in a })
        for i in need {
            let raw = chatHistory.items[i].raw
            let m = byRaw[raw] ?? ChatParser.classify(raw, minY: 0, maxY: 0)
            chatHistory.setChinese(await translateSafe(m), at: i, ifRaw: raw)
        }
        rebuildHistory()
        side.show(history)
    }

    /// 翻译加超时：5 秒没结果就先显示英文原文，并重建翻译会话
    private func translateSafe(_ m: ChatMessage) async -> String {
        let tr = translator!
        if let t = await withTimeout(5, { await tr.translate(m) }) { return t.chinese }
        trace("translate timeout: \(m.raw)")
        await tr.reset()
        return "（翻译超时）" + m.raw
    }

    /// 缩成 48×24 灰度小图，用来判断画面有没有变化
    private func fingerprint(_ img: CGImage) -> [UInt8] {
        let w = 48, h = 24
        var buf = [UInt8](repeating: 0, count: w * h)
        buf.withUnsafeMutableBytes { p in
            guard let ctx = CGContext(data: p.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
            ctx.interpolationQuality = .low
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return buf.map { $0 / 16 }   // 降低精度，忽略细微闪动
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let moved = GameData.launching()
    let controller = AppController()
    controller.dataMoved = moved
    app.delegate = controller
    withExtendedLifetime(controller) { app.run() }
}
