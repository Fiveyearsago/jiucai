import Foundation

/// Freezes each round's proxy order so replenishment waits until the following round.
public struct ProxyRotationQueue {
    private var pendingIDs: [UUID] = []

    public init() {}

    /// Returns the remaining active proxies in this round without changing the stored pool.
    /// Repeated selections keep the current proxy available until its account group finishes.
    public mutating func selectionConfiguration(from configuration: ProxyConfiguration) -> ProxyConfiguration {
        guard configuration.enabled else { return configuration }

        var activeByID: [UUID: ProxyEntry] = [:]
        var activeIDs: [UUID] = []
        for entry in configuration.activeEntries where activeByID[entry.id] == nil {
            activeByID[entry.id] = entry
            activeIDs.append(entry.id)
        }

        pendingIDs.removeAll { activeByID[$0] == nil }
        if pendingIDs.isEmpty {
            pendingIDs = activeIDs
        }

        var selection = configuration
        selection.entries = pendingIDs.compactMap { activeByID[$0] }
        return selection
    }

    /// Consumes a proxy after its account group finishes, fails, or becomes uncertain.
    public mutating func didFinishProxy(id: UUID) {
        pendingIDs.removeAll { $0 == id }
    }
}
