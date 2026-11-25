// 把截图交给“文字识别小助手”子进程处理（在本程序里直接做高精度识别，结果经常为空，原因未明；子进程里稳定）
import Foundation
import ImageIO
import CoreText
import TranslatorCore

final class OCRClient: @unchecked Sendable {
    private var process: Process?
    private var toHelper: FileHandle?
    private var fromHelper: FileHandle?
    private var pending = Data()
    private let lock = NSLock()
    private var lastUse = Date()
    private var idleTimer: DispatchSourceTimer?
    /// 正在识别的那一次从什么时候开始（没在识别为 nil）。看门狗用：子进程偶尔卡住不回话，锁就永远放不开、以后全部“忙”
    private let busyLock = NSLock()
    private var busySince: Date?
    private var runningProcess: Process?
    /// 看门狗的时限。实测（2026-11-23）：识别程序变过、缓存没了之后，系统要重新编译识别模型，单独一个约 30 秒，三个一起近 80 秒；
    /// 编到一半被杀就白编，下一个从头来——原来固定 8 秒会反复杀、永远起不来，就是“识别卡死”。
    /// 所以没准备好之前给 5 分钟；准备好以后新起的进程 30 秒，还被杀就翻倍。
    /// 这个进程已经认成功过：模型都装好了，再卡就是真卡住（实测有），8 秒就重开
    private static let provenLimit: TimeInterval = 8
    private var proven = false
    private static let coldLimit: TimeInterval = 300, warmLimit: TimeInterval = 30
    private var hangLimit: TimeInterval = OCRClient.warmLimit
    /// 识别模型准备好了没有（几个子进程共用一份缓存）。没准备好时只让一个子进程去准备，别的直接跳过，免得同时重复编译
    private static let gate = NSLock()
    private static var ready = false
    private static weak var warmer: OCRClient?
    private static var warmStart: Date?
    /// 准备阶段连续被系统报错几次、下次什么时候再试。每次失败系统都要白编译约 15~30 秒、占满一个核，别马上重来
    private static var coldFails = 0, retryAt = Date.distantPast
    /// 传给子进程的自定义词
    static var customWords: [String] = []
    /// 首次引导用：准备好没有、失败几次、等了几秒
    static var progress: (ready: Bool, fails: Int, seconds: Int) {
        gate.lock(); defer { gate.unlock() }
        return (ready, coldFails, warmStart.map { Int(Date().timeIntervalSince($0)) } ?? 0)
    }
    /// 连续报错几次（换个新进程可能就好）
    private var errors = 0
    /// 连续没识别成的开始时间（成功一次清掉）
    private var failingSince: Date?
    /// 识别有没有出状况，给界面显示用；正常为 nil
    var notice: String? {
        Self.gate.lock(); let ready = Self.ready, start = Self.warmStart, fails = Self.coldFails; Self.gate.unlock()
        if !ready {
            if fails >= 2 { return "系统文字识别启动失败（已试 \(fails) 次）：请重启电脑，再打开本程序" }
            guard let t = start.map({ Date().timeIntervalSince($0) }), t > 2 else { return nil }
            return t < 120 ? "正在准备文字识别（通常半分钟到一分多钟，已等 \(Int(t)) 秒）" : "系统文字识别卡住了，还在等；很久不好就重启电脑"
        }
        busyLock.lock(); defer { busyLock.unlock() }
        if let f = failingSince, Date().timeIntervalSince(f) > 6 { return "系统文字识别卡住了，正在等它恢复" }
        return nil
    }
    private var watchdog: DispatchSourceTimer?

    /// 空闲这么久没用就关掉子进程、释放识别模型占的内存（下次用时自动重开）
    /// wait：忙的时候最多等多久（统计用：几路读数共用一个子进程，排一下队，别白丢一次）
    private let wait: TimeInterval
    init(idleStop: TimeInterval? = nil, wait: TimeInterval = 0) {
        self.wait = wait
        // 看门狗：一次识别超过时限还没回来，就结束子进程（读管道会马上返回空，锁随之放开；下次用时自动重开）
        let w = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        w.schedule(deadline: .now() + 2, repeating: 2)
        w.setEventHandler { [weak self] in
            guard let self else { return }
            self.busyLock.lock(); let since = self.busySince; let p = self.runningProcess; let proven = self.proven; var limit = proven ? Self.provenLimit : self.hangLimit; self.busyLock.unlock()
            Self.gate.lock(); if !Self.ready, !proven { limit = Self.coldLimit }; Self.gate.unlock()
            if let since, Date().timeIntervalSince(since) > limit, let p, p.isRunning {
                NSLog("ChatTranslator: ocr-helper 卡住 %.0f 秒，重启", Date().timeIntervalSince(since))
                trace(String(format: "ocr 卡住 %.0f 秒，重启子进程%@", Date().timeIntervalSince(since), proven ? "" : "（还没成功过）"))
                if !proven { self.busyLock.lock(); self.hangLimit = min(Self.coldLimit, limit * 2); self.busyLock.unlock() }
                // 新进程起不来：多半是缓存丢了在重新编译：回到“没准备好”，下次只放一个进去、给 5 分钟
                Self.gate.lock(); if !proven, Self.ready { Self.ready = false; Self.warmStart = Date() }; Self.gate.unlock()
                kill(p.processIdentifier, SIGKILL)      // 卡在系统识别里，直接结束
            }
        }
        w.resume()
        watchdog = w
        guard let idle = idleStop else { return }
        let t = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        t.schedule(deadline: .now() + 30, repeating: 30)
        t.setEventHandler { [weak self] in
            guard let self, self.lock.try() else { return }
            defer { self.lock.unlock() }
            if self.process != nil, Date().timeIntervalSince(self.lastUse) > idle { self.stop() }
        }
        t.resume()
        idleTimer = t
    }

    private func start() -> Bool {
        let exe = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/ocr-helper")
        let p = Process()
        p.executableURL = exe
        let inPipe = Pipe(), outPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        if let path = ProcessInfo.processInfo.environment["CT_HELPER_LOG"] {
            FileManager.default.createFile(atPath: path, contents: nil)
            p.standardError = FileHandle(forWritingAtPath: path)
        } else {
            p.standardError = FileHandle.nullDevice
        }
        p.environment = ProcessInfo.processInfo.environment.merging(["CT_CUSTOM_WORDS": Self.customWords.joined(separator: "\n")]) { $1 }
        // 子进程默认继承本程序的“后台低优先级”，第一次加载识别模型会慢到几十秒；明确设为用户交互级
        p.qualityOfService = .userInitiated
        do { try p.run() } catch { return false }
        process = p
        busyLock.lock(); runningProcess = p; proven = false; busyLock.unlock()
        toHelper = inPipe.fileHandleForWriting
        fromHelper = outPipe.fileHandleForReading
        pending = Data()
        return true
    }

    func stop() { process?.terminate(); process = nil }

    /// 启动时先预热：拉起子进程并识别一张带字的小图，让模型提前加载好
    func warmUp() {
        DispatchQueue.global(qos: .userInitiated).async {
            let size = CGSize(width: 300, height: 32)
            guard let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return }
            ctx.setFillColor(gray: 0, alpha: 1); ctx.fill(CGRect(origin: .zero, size: size))
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: "Player : warm up", attributes: [
                kCTFontAttributeName as NSAttributedString.Key: CTFontCreateWithName("Helvetica" as CFString, 18, nil),
                kCTForegroundColorAttributeName as NSAttributedString.Key: CGColor(gray: 1, alpha: 1)]))
            ctx.textPosition = CGPoint(x: 6, y: 9); CTLineDraw(line, ctx)
            if let img = ctx.makeImage() { _ = self.recognize(img) }
        }
    }

    /// 模型没准备好时只放一个进去
    private static func enter(_ c: OCRClient) -> Bool {
        gate.lock(); defer { gate.unlock() }
        if ready { return true }
        if let w = warmer, w !== c { return false }
        if Date() < retryAt { return false }
        warmer = c
        if warmStart == nil { warmStart = Date() }
        return true
    }
    private static func leave(_ c: OCRClient, ok: Bool) {
        gate.lock(); defer { gate.unlock() }
        if ok, !ready { ready = true; trace(String(format: "ocr 准备好了，用了 %.1f 秒", Date().timeIntervalSince(warmStart ?? Date()))) }
        if ok { coldFails = 0 }
        if warmer === c { warmer = nil }
    }

    /// 同步调用（在后台线程里用）。出错时重启子进程，返回 nil。
    func recognize(_ img: CGImage) -> [OCRLine]? {
        // 上一次还没识别完就直接跳过这一次，不排队、不卡住
        guard wait > 0 ? lock.lock(before: Date(timeIntervalSinceNow: wait)) : lock.try() else { return nil }
        guard Self.enter(self) else { lock.unlock(); return nil }
        var ok = false
        defer { Self.leave(self, ok: ok) }
        busyLock.lock(); busySince = Date(); if failingSince == nil { failingSince = Date() }; busyLock.unlock()
        defer { busyLock.lock(); busySince = nil; busyLock.unlock(); lock.unlock() }
        lastUse = Date()
        if process?.isRunning != true, !start() { return nil }
        let data = NSMutableData()
        guard let d = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(d, img, nil)
        guard CGImageDestinationFinalize(d) else { return nil }
        var len = UInt32(data.length).bigEndian
        do {
            try toHelper?.write(contentsOf: Data(bytes: &len, count: 4))
            try toHelper?.write(contentsOf: data as Data)
        } catch { stop(); return nil }
        // 读到换行为止
        while true {
            if let nl = pending.firstIndex(of: 0x0A) {
                let line = pending[pending.startIndex..<nl]
                pending = Data(pending[(nl + 1)...])
                // 回的是 null：系统识别报错（不是“没有字”）。连着三次就换个新进程
                guard let out = try? JSONDecoder().decode([OCRLine].self, from: Data(line)) else {
                    errors += 1
                    Self.gate.lock()
                    if !Self.ready { Self.coldFails += 1; Self.retryAt = Date(timeIntervalSinceNow: min(300, 15 * pow(2, Double(Self.coldFails - 1)))); trace("ocr 准备失败第 \(Self.coldFails) 次") }
                    Self.gate.unlock()
                    if errors >= 3 { errors = 0; stop() }
                    return nil
                }
                ok = true; errors = 0
                busyLock.lock(); hangLimit = Self.warmLimit; proven = true; failingSince = nil; busyLock.unlock()
                return out
            }
            guard let chunk = fromHelper?.availableData, !chunk.isEmpty else { stop(); return nil }
            pending.append(chunk)
        }
    }
}
