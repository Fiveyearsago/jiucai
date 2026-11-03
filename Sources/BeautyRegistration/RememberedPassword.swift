import AppKit
import Combine
import RegistrationCore

@MainActor
final class RememberedPassword: ObservableObject {
    @Published var value = "" {
        didSet {
            guard !restoring, value != oldValue else { return }
            revision += 1
            pendingValue = value
            status = "正在保存到本机…"
            scheduleSave()
        }
    }
    @Published private(set) var status = "正在读取已保存的密码…"
    @Published private(set) var isLoading = true
    private let store: PasswordStore
    private let queue = DispatchQueue(label: "local.beauty.registration.password")
    private var pendingValue: String?
    private var revision = 0
    private var restoring = false
    private var saveTask: Task<Void, Never>?
    private var terminationObserver: AnyCancellable?

    init(store: PasswordStore = LocalPasswordStore()) {
        self.store = store
        // Disk access runs off the UI thread.
        queue.async { [weak self] in
            let result = Result { try store.read() }
            Task { @MainActor [weak self] in self?.finishLoading(result) }
        }
        terminationObserver = NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)
            .sink { [weak self] _ in self?.flush() }
    }

    private func finishLoading(_ result: Result<String?, Error>) {
        isLoading = false
        guard revision == 0 else { return } // Never replace a password typed while the read was in flight.
        switch result {
        case .success(let saved):
            restoring = true
            value = saved ?? ""
            restoring = false
            status = value.isEmpty ? "输入后自动保存在本机。" : "已从本机恢复，重启后仍会保留。"
        case .failure:
            // An unreadable item must not be mistaken for an explicitly cleared field.
            status = "无法读取本机密码文件；重新输入后会尝试保存。"
        }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 350_000_000) } catch { return }
            guard let self, let password = self.pendingValue else { return }
            let version = self.revision
            let store = self.store
            self.queue.async { [weak self] in
                let result = Result { try store.save(password) }
                Task { @MainActor [weak self] in self?.finishSaving(result, version: version, empty: password.isEmpty) }
            }
        }
    }

    private func finishSaving(_ result: Result<Void, Error>, version: Int, empty: Bool) {
        guard revision == version else { return }
        switch result {
        case .success:
            pendingValue = nil
            status = empty ? "已清除保存的密码。" : "已保存到本机，重启后自动恢复。"
        case .failure:
            status = "密码未保存：请检查应用数据目录的访问权限。"
        }
    }

    /// Finish any pending edit before normal application termination.
    func flush() {
        saveTask?.cancel()
        guard let password = pendingValue else { return }
        revision += 1 // Ignore callbacks from writes queued before the final flush.
        let result = queue.sync { Result { try store.save(password) } }
        finishSaving(result, version: revision, empty: password.isEmpty)
    }
}
