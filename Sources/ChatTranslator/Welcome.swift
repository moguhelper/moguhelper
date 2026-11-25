// 首次引导：说明 → 准备文字识别 → 屏幕录制权限 → 中英文翻译包。没做完以前每次启动都显示；菜单里可以再打开。
import AppKit
import SwiftUI
import Translation

@MainActor
final class Welcome {
    private var window: NSWindow?
    private let retryOCR: () -> Void
    init(retryOCR: @escaping () -> Void) { self.retryOCR = retryOCR }
    /// 还没点“开始使用”，或没有屏幕录制权限：别的窗口、识别都先不开
    static var needed: Bool { !UserDefaults.standard.bool(forKey: "welcomeDone") || !CGPreflightScreenCaptureAccess() }
    func show() {
        if window == nil {
            let w = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "MoguHelper"; w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: WelcomeView(retryOCR: retryOCR) { [weak w] in UserDefaults.standard.set(true, forKey: "welcomeDone"); w?.close() })
            w.center(); window = w
        }
        NSApp.activate(ignoringOtherApps: true); window?.makeKeyAndOrderFront(nil)
    }
}

struct WelcomeView: View {
    let retryOCR: () -> Void
    let done: () -> Void
    @AppStorage("agreed1") private var agreed = false
    @State private var ocr = OCRClient.progress
    /// 准备中先别授权：授权要重新启动，会打断准备。失败或等太久就放行，不把人困在这里
    private var ocrWaiting: Bool { !ocr.ready && ocr.fails < 2 && ocr.seconds < 180 }
    @State private var screen = CGPreflightScreenCaptureAccess()
    @State private var lang: LanguageAvailability.Status?
    @State private var sample = ""
    @State private var config: TranslationSession.Configuration?
    private let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()
    private static let en = Locale.Language(identifier: "en"), zh = Locale.Language(identifier: "zh-Hans")

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            step(1, "使用前请看", agreed) {
                Text("这是非官方的免费工具，和游戏公司无关。它只看游戏窗口的画面，不读写游戏内存和文件，不替你按键、点击。识别和翻译都在你的电脑上，不上传。\n\n使用第三方工具可能违反游戏条款，有被处罚、封号的风险，请自行决定，风险自负。")
                if !agreed { Button("我知道了，继续") { agreed = true } }
            }
            step(2, "准备文字识别", ocr.ready) {
                if ocr.ready { Text("准备好了。") }
                else if ocr.fails >= 2 { Text("系统文字识别启动失败（已试 \(ocr.fails) 次）。请重启电脑，再打开本程序。") }
                else {
                    Text("首次使用，系统要准备文字识别模型，通常半分钟到一分多钟。请不要退出，退出了要重新等。")
                    HStack { ProgressView().controlSize(.small); Text("已等 \(ocr.seconds) 秒").foregroundStyle(.secondary) }
                }
            }
            step(3, "屏幕录制权限", screen) {
                Text("要看到游戏画面才能翻译。打开后需要重新启动本程序。")
                if !screen {
                HStack {
                    Button("打开系统设置") {
                        CGRequestScreenCaptureAccess()
                        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") { NSWorkspace.shared.open(u) }
                    }
                    Button("重新启动") { relaunch() }
                }.disabled(!agreed || ocrWaiting)
                if agreed && ocrWaiting { Text("等文字识别准备好再授权。").foregroundStyle(.secondary) } }
            }
            step(4, "英文 → 中文翻译包", lang == .installed) {
                switch lang {
                case .installed: Text(sample.isEmpty ? "已装好。" : sample)
                case .supported: Text("还没装。点下载，会弹出苹果系统自己的下载窗口，点同意就行（免费）。")
                    Button("下载翻译包") { config = .init(source: Self.en, target: Self.zh) }.disabled(!agreed)
                case .unsupported: Text("这台电脑的系统不支持英文到中文的本地翻译。")
                default: Text("正在检查…")
                }
            }
            HStack { Spacer(); Button("开始使用", action: done).keyboardShortcut(.defaultAction).disabled(!(agreed && screen && lang == .installed)) }
        }
        .font(.system(size: 13)).padding(20).frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .task { await check() }
        .onReceive(timer) { _ in
            ocr = OCRClient.progress
            if !ocr.ready { retryOCR() }   // 正在准备、还没到重试时间都会自己跳过
            screen = CGPreflightScreenCaptureAccess(); if lang != .installed { Task { await check() } } }
        .translationTask(config) { s in try? await s.prepareTranslation(); await check() }
    }
    private func check() async {
        let s = await LanguageAvailability().status(from: Self.en, to: Self.zh)
        lang = s
        guard s == .installed, sample.isEmpty else { return }
        if let r = try? await TranslationSession(installedSource: Self.en, target: Self.zh).translate("Welcome, adventurer!") { sample = "已装好。试一句：Welcome, adventurer! → \(r.targetText)" }
    }
    private func relaunch() {
        let c = NSWorkspace.OpenConfiguration(); c.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: c) { _, _ in DispatchQueue.main.async { NSApp.terminate(nil) } }
    }
    private func step<C: View>(_ n: Int, _ t: String, _ ok: Bool, @ViewBuilder _ c: () -> C) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: ok ? "checkmark.circle.fill" : "\(n).circle").font(.system(size: 20)).foregroundStyle(ok ? .green : .secondary)
            VStack(alignment: .leading, spacing: 6) { Text(t).font(.system(size: 14, weight: .bold)); c() }.fixedSize(horizontal: false, vertical: true)
        }
    }
}
