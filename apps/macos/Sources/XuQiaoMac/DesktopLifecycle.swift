import AppKit
import Combine
import SwiftUI
import XuQiaoCore

enum DesktopPreferences {
    static let keepRunningInMenuBarKey = "app.keepRunningInMenuBar"
    static var keepRunningInMenuBar: Bool {
        UserDefaults.standard.object(forKey: keepRunningInMenuBarKey) as? Bool ?? true
    }
}

/// 关闭窗口只改变展示状态；连接模型由 App 持有，隐藏、重开都不重新创建服务。
@MainActor
final class DesktopLifecycle: NSObject {
    private weak var model: AppModel?
    private weak var mainWindow: NSWindow?
    private var windowDelegate: MainWindowCloseDelegate?
    private var statusItem: NSStatusItem?
    private var snapshotSubscription: AnyCancellable?
    private var pendingRequestID: String?
    private var openMainWindow: (() -> Void)?
    var terminating = false

    func attach(window: NSWindow, model: AppModel, openMainWindow: @escaping () -> Void) {
        self.openMainWindow = openMainWindow
        if self.model !== model {
            self.model = model
            installStatusItem()
            snapshotSubscription = model.$snapshot.sink { [weak self] snapshot in
                guard let self else { return }
                self.refreshStatus(snapshot)
                // 每个实际请求仅激活一次；等待手机确认或心跳更新不再抢焦点。
                let requestID = snapshot.pending?.requestID
                if requestID != self.pendingRequestID {
                    self.pendingRequestID = requestID
                    if let pending = snapshot.pending, !pending.macConfirmed { self.show(.connection) }
                }
            }
        }
        if mainWindow !== window {
            mainWindow = window
            windowDelegate = MainWindowCloseDelegate(lifecycle: self, original: window.delegate)
        }
        if window.delegate !== windowDelegate {
            windowDelegate?.original = window.delegate
            window.delegate = windowDelegate
        }
    }

    func show(_ page: AppModel.Page? = nil) {
        if let page { model?.selection = page }
        NSApp.setActivationPolicy(.regular)
        if let mainWindow { mainWindow.makeKeyAndOrderFront(nil) }
        else { openMainWindow?() }
        NSApp.activate(ignoringOtherApps: true)
    }

    func close(_ window: NSWindow) -> Bool {
        if terminating { return true }
        if DesktopPreferences.keepRunningInMenuBar {
            window.orderOut(nil)
            // 转入顶部状态栏，隐藏 Dock 图标；显式重开时恢复正常应用策略。
            NSApp.setActivationPolicy(.accessory)
        } else {
            NSApp.terminate(nil)
        }
        return false
    }

    func prepareToTerminate() { terminating = true; model?.server.stop() }

    private func installStatusItem() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item
        item.button?.target = self
        item.button?.action = #selector(openStatusMenu)
        // AppKit 明确接收左右键，右键无需先打开窗口即可使用“退出续桥”。
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    private func refreshStatus(_ snapshot: ServerSnapshot) {
        let connected = snapshot.peers.contains { $0.connected }
        statusItem?.button?.image = MenuBarConnectionIcon.image(connected: connected)
        statusItem?.button?.toolTip = connected ? "续桥 · 设备已连接" : "续桥 · 未连接，点击配对"
        statusItem?.button?.setAccessibilityLabel(connected ? "续桥，设备已连接" : "续桥，未连接")
    }

    @objc private func openStatusMenu() {
        guard let button = statusItem?.button, let model else { return }
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: model.snapshot.status, action: nil, keyEquivalent: ""))
        if !model.snapshot.host.isEmpty { menu.addItem(NSMenuItem(title: "局域网 · " + model.snapshot.host, action: nil, keyEquivalent: "")) }
        if !model.snapshot.ready && model.snapshot.error != nil { add("重试连接服务", action: .retry, to: menu) }
        menu.addItem(.separator())
        for peer in model.snapshot.peers {
            let item = NSMenuItem(title: deviceLabel(peer.name, id: peer.id) + (peer.connected ? " · 已连接" : peer.paused ? " · 已暂停" : " · 等待重连"), action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            add("查看设备", action: .show(.devices), to: submenu)
            if peer.connected { add("断开连接", action: .disconnect(peer), to: submenu) }
            item.submenu = submenu; menu.addItem(item)
        }
        if model.snapshot.peers.isEmpty { menu.addItem(NSMenuItem(title: "尚未配对设备", action: nil, keyEquivalent: "")) }
        menu.addItem(.separator())
        add("发送文件…", action: .show(.files), to: menu)
        if model.snapshot.files.tasks.contains(where: { $0.isFileTransferRecord && $0.state == .awaitingUser }) { add("有文件待接收…", action: .show(.files), to: menu) }
        add("连接新手机…", action: .pair, to: menu)
        add("打开主窗口", action: .show(model.selection), to: menu)
        add("设置…", action: .show(.settings), key: ",", to: menu)
        menu.addItem(.separator())
        add("退出续桥", action: .quit, key: "q", to: menu)
        if let event = NSApp.currentEvent { NSMenu.popUpContextMenu(menu, with: event, for: button) }
        else { menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.minY), in: button) }
    }

    private enum Action { case show(AppModel.Page), disconnect(PeerView), retry, pair, quit }
    private func add(_ title: String, action: Action, key: String = "", to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: #selector(performMenuAction(_:)), keyEquivalent: key)
        item.target = self; item.representedObject = action; menu.addItem(item)
    }
    @objc private func performMenuAction(_ sender: NSMenuItem) {
        guard let action = sender.representedObject as? Action, let model else { return }
        switch action {
        case .show(let page): show(page)
        case .disconnect(let peer): model.server.disconnect(peerID: peer.id, expectedGeneration: peer.trustGeneration)
        case .retry: model.server.retry()
        case .pair: model.showPairing(); show(.connection)
        case .quit: NSApp.terminate(nil)
        }
    }
}

/// 只拦截关闭，其他窗口消息转发给 SwiftUI 原 delegate，保留其窗口管理和恢复行为。
@MainActor
private final class MainWindowCloseDelegate: NSObject, NSWindowDelegate {
    weak var lifecycle: DesktopLifecycle?
    var original: NSWindowDelegate?
    init(lifecycle: DesktopLifecycle, original: NSWindowDelegate?) { self.lifecycle = lifecycle; self.original = original }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard original?.windowShouldClose?(sender) ?? true else { return false }
        return lifecycle?.close(sender) ?? true
    }
    override func responds(to selector: Selector!) -> Bool { super.responds(to: selector) || (original?.responds(to: selector) ?? false) }
    override func forwardingTarget(for selector: Selector!) -> Any? {
        if original?.responds(to: selector) == true { return original }
        return super.forwardingTarget(for: selector)
    }
}

struct WindowLifecycleAttachment: NSViewRepresentable {
    let lifecycle: DesktopLifecycle
    let model: AppModel
    @Environment(\.openWindow) private var openWindow
    func makeNSView(context: Context) -> WindowAttachmentView { let view = WindowAttachmentView(); updateNSView(view, context: context); return view }
    func updateNSView(_ view: WindowAttachmentView, context: Context) {
        view.onAttach = { window in lifecycle.attach(window: window, model: model, openMainWindow: { openWindow(id: "main") }) }
        if let window = view.window { view.onAttach?(window) }
    }
}

final class WindowAttachmentView: NSView {
    var onAttach: ((NSWindow) -> Void)?
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); if let window { onAttach?(window) } }
}
