import Foundation

// MARK: - Service health (status.claude.com)

/// Atlassian Statuspage indicator levels for the Claude status page.
enum ServiceStatusIndicator: String {
    case none        // all systems operational
    case minor
    case major
    case critical
    case maintenance
    case unknown     // not yet fetched, or fetch/parse failed
}

struct ServiceStatus {
    let indicator: ServiceStatusIndicator
    let description: String

    static let unknown = ServiceStatus(indicator: .unknown, description: "Status unavailable")
}

/// Polls the public Claude status page — no auth, no Keychain, no token. Just
/// the same JSON that powers status.claude.com's "All Systems Operational" badge.
final class StatusService: ObservableObject {
    static let shared = StatusService()

    @Published private(set) var status: ServiceStatus = .unknown

    private var timer: Timer?
    private let interval: TimeInterval = 5 * 60

    // Injectable for testing.
    var urlSession: URLSession = .shared

    private init() {}

    // status.anthropic.com now redirects here; use the canonical host directly.
    private let endpoint = URL(string: "https://status.claude.com/api/v2/status.json")!

    private struct StatusResponse: Decodable {
        struct Status: Decodable {
            let indicator: String
            let description: String
        }
        let status: Status
    }

    func startPolling() {
        fetch()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.fetch()
        }
    }

    func stopPolling() {
        timer?.invalidate()
        timer = nil
    }

    func fetch() {
        Task {
            do {
                var request = URLRequest(url: endpoint)
                request.timeoutInterval = 15
                let (data, _) = try await urlSession.data(for: request)
                let decoded = try JSONDecoder().decode(StatusResponse.self, from: data)
                let indicator = ServiceStatusIndicator(rawValue: decoded.status.indicator) ?? .unknown
                let result = ServiceStatus(indicator: indicator, description: decoded.status.description)
                await MainActor.run { self.status = result }
            } catch {
                #if DEBUG
                print("[StatusService] fetch failed: \(error)")
                #endif
                // Keep the last known status on a transient failure rather than
                // flapping the badge to gray.
            }
        }
    }
}
