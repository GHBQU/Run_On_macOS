// 运行.app — Windows 风格“运行”对话框（macOS）
// 全局快捷键 Option(⌥)+R 呼出窗口；浏览(B)... 选择文件；确定 运行。
import AppKit
import WebKit
import Carbon

func dbg(_ s: String) {
    let line = s + "\n"
    if let d = line.data(using: .utf8),
       let fh = FileHandle(forWritingAtPath: "/tmp/run_debug.log") {
        fh.seekToEndOfFile(); fh.write(d); try? fh.close()
    }
}

// MARK: - 全局热键 (Option+R) 回调

var hotKeyRef: EventHotKeyRef?
var hotKeyHandler: EventHandlerUPP? = { (_: EventHandlerCallRef?, _: EventRef?, _: UnsafeMutableRawPointer?) -> OSStatus in
    RunApp.show()
    return noErr
}
var hotKeyEventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))

// MARK: - 无边框但可成为 Key 窗口（否则键盘输入进不来）

final class KeyableWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

// MARK: - 应用主体

final class RunApp: NSObject, NSApplicationDelegate, WKScriptMessageHandler, WKNavigationDelegate {

    static var shared: RunApp!
    var window: NSWindow!
    var webView: WKWebView!
    var runningProcesses: [Process] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        dbg("didFinishLaunching")
        RunApp.shared = self
        buildMenu()
        buildWindow()
        registerHotKey()
        monitorEscape()
        dbg("launch done")
        if ProcessInfo.processInfo.environment["RUN_SHOW"] == "1" {
            RunApp.show()
        }
    }

    // MARK: 菜单

    private func buildMenu() {
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "显示运行窗口", action: #selector(showWindowAction), keyEquivalent: "r")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "关于 运行", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "退出 运行", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        // 编辑菜单：全选/拷贝/粘贴（⌘A / ⌘C / ⌘V），
        // 通过标准响应链转发给输入框（WKWebView 文本编辑）
        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenu.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editItem.submenu = editMenu

        NSApp.mainMenu = mainMenu
    }

    @objc private func showWindowAction() {
        RunApp.show()
    }

    // MARK: 窗口

    private func buildWindow() {
        let rect = NSRect(x: 0, y: 0, width: 400, height: 225)
        window = KeyableWindow(contentRect: rect,
                          styleMask: [.borderless],
                          backing: .buffered,
                          defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.isMovableByWindowBackground = true
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isReleasedWhenClosed = false

        let config = WKWebViewConfiguration()
        let userContent = WKUserContentController()
        userContent.add(self, name: "runBridge")
        config.userContentController = userContent
        config.suppressesIncrementalRendering = false

        webView = WKWebView(frame: rect, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        webView.autoresizingMask = [.width, .height]
        webView.navigationDelegate = self
        window.contentView = webView
        dbg("window built, screen=\(NSScreen.main?.frame ?? .zero)")

        let htmlURL = Bundle.main.url(forResource: "Run", withExtension: "html")
        dbg("htmlURL=\(String(describing: htmlURL))")
        guard let htmlURL = htmlURL else { return }
        webView.loadFileURL(htmlURL, allowingReadAccessTo: htmlURL.deletingLastPathComponent())
        window.center()
    }

    static func show() {
        guard let app = RunApp.shared else { dbg("show: shared nil"); return }
        dbg("show() called")
        NSApp.activate(ignoringOtherApps: true)
        app.window.makeKeyAndOrderFront(nil)
        app.window.orderFrontRegardless()
        app.window.center()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            dbg("delayed: visible=\(app.window.isVisible) onActiveSpace=\(app.window.isOnActiveSpace) isActive=\(NSApp.isActive)")
        }
        // 让输入框重新获得焦点
        app.webView.evaluateJavaScript("var i=document.getElementById('run-input'); if(i) i.focus();", completionHandler: nil)
        // 打开对话框时自动填入上一次成功运行的内容并全选（浏览刚填过路径时跳过，避免覆盖）
        if app.skipAutoFill {
            app.skipAutoFill = false
            app.pendingAutoFill = nil
        } else if let last = app.loadHistory().first {
            dbg("autofill: last='\(last)'")
            app.pendingAutoFill = last
            app.tryAutoFill() // 页面已加载则立即生效；否则等 didFinish 再填
        } else {
            dbg("autofill: no history")
        }
    }

    func hide() {
        window.orderOut(nil)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        RunApp.show()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false // 常驻后台，等待 ⌥R
    }

    // MARK: 热键 (Carbon)

    private func registerHotKey() {
        InstallEventHandler(GetApplicationEventTarget(), hotKeyHandler, 1, &hotKeyEventType, nil, nil)
        let hotKeyID = EventHotKeyID(signature: OSType(0x52554E31), id: 1) // "RUN1"
        let status = RegisterEventHotKey(UInt32(kVK_ANSI_R), UInt32(optionKey), hotKeyID,
                                         GetApplicationEventTarget(), 0, &hotKeyRef)
        dbg("RegisterEventHotKey status=\(status)")
        if status != noErr {
            NSLog("RegisterEventHotKey failed: %d", status)
        }
    }

    private func monitorEscape() {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { // Esc
                // 历史下拉菜单开着时先关菜单，再按一次才关窗口
                self.webView.evaluateJavaScript("!document.getElementById('history-pop').classList.contains('hidden')") { res, _ in
                    if let open = res as? Bool, open {
                        self.webView.evaluateJavaScript("closeHistory()", completionHandler: nil)
                    } else {
                        self.hide()
                    }
                }
                return nil
            }
            // Windows 风格助记键：⌥O 聚焦"打开"输入框 / ⌥B 触发"浏览"。
            // 必须带 Option 修饰，否则会直接输入字母。模态会话（浏览面板/报错弹窗）期间忽略。
            let mods = event.modifierFlags
            if mods.contains(.option) && !mods.contains(.command) && !mods.contains(.control) && !mods.contains(.function),
               NSApp.modalWindow == nil,
               let ch = event.charactersIgnoringModifiers?.lowercased() {
                if ch == "o" {
                    dbg("mnemonic: alt+O focus input")
                    self.webView.evaluateJavaScript("var i=document.getElementById('run-input'); if(i){ i.focus(); }", completionHandler: nil)
                    return nil
                }
                if ch == "b" {
                    dbg("mnemonic: alt+B browse")
                    self.browse()
                    return nil
                }
            }
            return event
        }
    }

    // MARK: JS 桥接

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "runBridge",
              let body = message.body as? [String: Any],
              let type = body["type"] as? String else { return }
        dbg("bridge: type=\(type) value=\(body["value"] as? String ?? "")")
        switch type {
        case "close", "cancel":
            hide()
        case "browse":
            browse()
        case "run":
            runCommand(body["value"] as? String ?? "")
        case "getHistory":
            let js = "window.setHistory(" + jsonArrayString(loadHistory()) + ");"
            webView.evaluateJavaScript(js, completionHandler: nil)
        default:
            break
        }
    }

    // MARK: 自动填充（上次成功运行内容 + 全选）

    private var pendingAutoFill: String? = nil

    private func tryAutoFill() {
        guard let last = pendingAutoFill else { return }
        let jsLast = jsonString(last)
        webView.evaluateJavaScript("if (window.setLastRun) { window.setLastRun(" + jsLast + "); document.getElementById('run-input').value; } else { null; }") { res, err in
            dbg("autofill: res=\(String(describing: res)) err=\(String(describing: err))")
            if let v = res as? String, v == last {
                self.pendingAutoFill = nil // 已填充成功
            }
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        dbg("navigation didFinish")
        tryAutoFill()
    }

    // MARK: 历史记录（最近运行成功）

    private let historyKey = "runHistory"
    private let historyLimit = 10
    private var skipAutoFill = false // 浏览刚填入路径时，下次 show() 跳过自动填充

    private func loadHistory() -> [String] {
        UserDefaults.standard.array(forKey: historyKey) as? [String] ?? []
    }

    private func recordSuccess(_ cmd: String) {
        var h = loadHistory()
        h.removeAll { $0 == cmd }
        h.insert(cmd, at: 0)
        if h.count > historyLimit { h = Array(h.prefix(historyLimit)) }
        UserDefaults.standard.set(h, forKey: historyKey)
        dbg("history: recorded '\(cmd)' total=\(h.count)")
    }

    private func jsonArrayString(_ arr: [String]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: arr, options: [])
        return String(data: data, encoding: .utf8) ?? "[]"
    }

    // 单个字符串转合法 JS 字符串字面量（数组包装后剥掉首尾 [ ]）
    private func jsonString(_ s: String) -> String {
        var j = jsonArrayString([s])
        j.removeFirst()
        j.removeLast()
        return j
    }

    // MARK: 浏览

    private var browseSeq = 0
    private func browse() {
        browseSeq += 1
        let seq = browseSeq
        dbg("browse: [S\(seq)] begin")
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "选择"
        panel.message = "选择要运行的程序、文件夹、文档或脚本"
        // 不用 beginSheetModal：无边框浮动窗口上 sheet 的模态会话可能不结束。
        // runModal 同步返回最稳。
        dbg("browse: [S\(seq)] opening panel (modal)")
        NSApp.activate(ignoringOtherApps: true)
        let response = panel.runModal()
        guard response == .OK, let url = panel.url else {
            dbg("browse: [S\(seq)] cancelled/failed response=\(response.rawValue)")
            return
        }
        let path = url.path
        // 注意：JSONSerialization 的顶层对象不允许是 String（会抛 ObjC 异常且无法用
        // Swift catch 捕获，在 WebKit 桥接层被静默吞掉，表现为"没反应"）。
        // 用数组包装再剥掉首尾 [ ]，得到合法 JS 字符串字面量。
        let data = try! JSONSerialization.data(withJSONObject: [path], options: [])
        var escaped = String(data: data, encoding: .utf8) ?? "\"\""
        escaped.removeFirst()
        escaped.removeLast()
        dbg("browse: [S\(seq)] picked path=\(path) escaped=\(escaped)")
        let js = "window.setInputValue(" + escaped + ");"
        dbg("browse: [S\(seq)] fill sent: \(js)")
        webView.evaluateJavaScript(js) { _, err in
            dbg("browse: [S\(seq)] fill result err=\(String(describing: err))")
        }
        skipAutoFill = true // 刚填了浏览路径，show() 不要覆盖成上次运行内容
        RunApp.show() // 选完后把窗口拉回前台，方便直接回车运行
    }

    // MARK: 运行

    private func runCommand(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { hide(); return }

        // URL
        let lower = trimmed.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.hasPrefix("ftp://") || lower.hasPrefix("file://") {
            if let url = URL(string: trimmed) { NSWorkspace.shared.open(url) }
            recordSuccess(trimmed)
            hide()
            return
        }

        let path = (trimmed as NSString).expandingTildeInPath
        var isDir: ObjCBool = false
        let fm = FileManager.default
        guard fm.fileExists(atPath: path, isDirectory: &isDir) else {
            let alert = NSAlert()
            alert.messageText = "macOS 找不到文件 '\(path)'。请确定文件名是否正确后，再试一次。"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "确定")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
            // 报错后把输入框内容全选，方便直接键入覆盖
            webView.evaluateJavaScript("var i=document.getElementById('run-input'); if(i){ i.focus(); i.select(); document.getElementById('run-input').selectionStart + ',' + document.getElementById('run-input').selectionEnd; } else { 'no-input'; }") { res, _ in
                dbg("notfound-select: \(String(describing: res))")
            }
            return
        }

        let url = URL(fileURLWithPath: path)
        if isDir.boolValue || url.pathExtension.lowercased() == "app" {
            NSWorkspace.shared.open(url)          // 文件夹 / .app
        } else if fm.isExecutableFile(atPath: path) {
            let p = Process()                     // 可执行文件直接启动
            p.executableURL = url
            do {
                try p.run()
                runningProcesses.append(p)
            } catch {
                NSWorkspace.shared.open(url)
            }
        } else {
            NSWorkspace.shared.open(url)          // 其他文件用默认应用打开
        }
        recordSuccess(trimmed)
        hide()
    }
}

// MARK: - 入口

let app = NSApplication.shared
let delegate = RunApp()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
