import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        if let iconURL = Bundle.main.url(forResource: "Beauty", withExtension: "icns"),
           let icon = NSImage(contentsOf: iconURL) {
            NSApp.applicationIconImage = icon
        }
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct BeautyRegistrationApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = RegistrationModel()
    var body: some Scene {
        WindowGroup("Beauty · 注册助手") {
            ContentView(model: model)
                .frame(minWidth: 1120, minHeight: 760)
                .preferredColorScheme(.light)
                .alert("注册助手", isPresented: Binding(get: {model.alert != nil}, set: {if !$0 {model.alert = nil}})) {
                    Button("知道了", role: .cancel) { model.alert = nil }
                } message: { Text(model.alert ?? "") }
        }
        .defaultSize(width: 1360, height: 880)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("任务") {
                Toggle("使用 Safari 浏览器标识", isOn: $model.useCompatibilityHeaders).disabled(model.isRunning)
                Button("检查接口连接") { model.checkAPIConnection() }.disabled(model.isRunning || model.isCheckingConnection)
                Button("导出注册记录…") { model.exportCSV() }.keyboardShortcut("e", modifiers: [.command, .shift])
                Button("打开记录目录") { model.revealRecords() }
            }
        }
    }
}
