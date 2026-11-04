import Combine
import Foundation
import RegistrationCore

@MainActor
final class RequestMonitor: ObservableObject {
    @Published private(set) var networkRecords: [NetworkRecord] = []
    @Published private(set) var requestObservations: [RequestHeaderObservation] = []
    @Published private(set) var appliedHeaders: RequestHeaderConfiguration?
    @Published private(set) var appliedHeaderMode: RequestHeaderMode?
    @Published private(set) var currentUserAgent = ""

    func configure(_ headers: RequestHeaderConfiguration) {
        appliedHeaders = headers
        appliedHeaderMode = headers.mode
        currentUserAgent = headers.customHeaders.first { $0.key.caseInsensitiveCompare("User-Agent") == .orderedSame }?.value
            ?? headers.effectiveUserAgent ?? "URLSession 系统默认"
    }

    func record(_ entry: NetworkRecord) {
        networkRecords.insert(entry, at: 0)
        if networkRecords.count > 300 { networkRecords.removeLast(networkRecords.count - 300) }
        requestObservations.insert(RequestHeaderObservation(method: entry.method, path: entry.path,
            transport: entry.transport, profile: appliedHeaders?.title ?? "原生默认",
            headers: entry.requestHeaders.map { ObservedRequestHeader(name: $0.name, value: $0.value, source: $0.source) }), at: 0)
        if requestObservations.count > 100 { requestObservations.removeLast(requestObservations.count - 100) }
    }

    func clearNetworkRecords() { networkRecords.removeAll(); requestObservations.removeAll() }
}
