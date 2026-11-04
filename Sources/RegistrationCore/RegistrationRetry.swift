import Foundation

public struct PageLoadTimeout: LocalizedError {
    public static let defaultSeconds: TimeInterval = 10
    public let seconds: TimeInterval
    public init(seconds: TimeInterval = defaultSeconds) { self.seconds = seconds }
    public var errorDescription: String? { "网页加载超过 \(seconds.formatted(.number.grouping(.never))) 秒。" }
}

public enum RegistrationRetry {
    /// Retry one account with fresh proxies, never retrying a proxy already used for it.
    @MainActor
    public static func run(
        selectProxy: (_ previous: UUID?, _ excluded: Set<UUID>) async throws -> ProxyEntry?,
        attempt: (ProxyEntry?) async throws -> Void,
        shouldRetry: () -> Bool,
        onRetry: (ProxyEntry, Error) throws -> Void
    ) async throws {
        var failed: Set<UUID> = []
        var previous: UUID?
        while true {
            try Task.checkCancellation()
            let proxy = try await selectProxy(previous, failed)
            try Task.checkCancellation()
            if let proxy, failed.contains(proxy.id) {
                throw ClientError.message("当前账号已尝试所有可用代理，任务已停止。")
            }
            if proxy == nil, !failed.isEmpty {
                throw ClientError.message("没有可继续尝试的代理，任务已停止。")
            }
            do {
                try await attempt(proxy)
                return
            } catch {
                if error is CancellationError { throw error }
                try Task.checkCancellation()
                guard let proxy, shouldRetry() else { throw error }
                failed.insert(proxy.id)
                previous = proxy.id
                try onRetry(proxy, error)
            }
        }
    }
}
