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
    /// Trailing-30-day uptime % from the incident feed, for the menu's uptime bar
    /// [#29]. nil until the first incidents fetch lands.
    @Published private(set) var uptime30dPercent: Double?

    private var timer: Timer?
    private let interval: TimeInterval = 5 * 60

    // Injectable for testing.
    var urlSession: URLSession = .shared

    private init() {}

    // status.anthropic.com now redirects here; use the canonical host directly.
    private let endpoint = URL(string: "https://status.claude.com/api/v2/status.json")!
    private let incidentsEndpoint = URL(string: "https://status.claude.com/api/v2/incidents.json")!

    private struct StatusResponse: Decodable {
        struct Status: Decodable {
            let indicator: String
            let description: String
        }
        let status: Status
    }

    func startPolling() {
        fetch()
        fetchIncidents()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.fetch()
            self?.fetchIncidents()
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
                await MainActor.run {
                    self.status = result
                    // Record today's worst status for the uptime history [#29].
                    StatusHistoryStore.shared.record(indicator: indicator)
                }
            } catch {
                #if DEBUG
                print("[StatusService] fetch failed: \(error)")
                #endif
                // Keep the last known status on a transient failure rather than
                // flapping the badge to gray.
            }
        }
    }

    /// Fetch the incident feed to compute the 30-day uptime % and seed the history
    /// store [#29]. Best-effort: a transient failure leaves the last numbers in place.
    func fetchIncidents() {
        Task {
            do {
                var request = URLRequest(url: incidentsEndpoint)
                request.timeoutInterval = 15
                let (data, _) = try await urlSession.data(for: request)
                let incidents = parseIncidents(data)
                let now = Date()
                let pct = uptimePercent(incidents: incidents, window: 30 * 24 * 3600, now: now)
                await MainActor.run {
                    self.uptime30dPercent = pct
                    StatusHistoryStore.shared.seed(incidents: incidents, now: now)
                }
            } catch {
                #if DEBUG
                print("[StatusService] incidents fetch failed: \(error)")
                #endif
            }
        }
    }
}
