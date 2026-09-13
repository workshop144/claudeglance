import Foundation

// MARK: - History backup bundle

/// Every persisted history store in one file, for the export/import round-trip.
/// The mirror copy in `~/.claudeglance` already covers an ordinary uninstall;
/// this covers moving to a new Mac, or a wipe that takes the home folder with it.
struct HistoryBackup: Codable {
    var version: Int
    var exported: Date
    var usage: [HistorySample]
    var status: StatusHistory
    var activity: ActivityArchive

    init(version: Int = HistoryStorage.currentVersion, exported: Date = Date(),
         usage: [HistorySample], status: StatusHistory, activity: ActivityArchive) {
        self.version = version; self.exported = exported
        self.usage = usage; self.status = status; self.activity = activity
    }
}

enum HistoryBackupService {
    static var suggestedFileName: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return "ClaudeGlance-history-\(f.string(from: Date())).json"
    }

    /// Snapshot of everything worth keeping. Main thread — reads the live stores.
    static func snapshot() -> HistoryBackup {
        HistoryBackup(usage: HistoryStore.shared.samples,
                      status: StatusHistoryStore.shared.history,
                      activity: ActivityArchiveStore.shared.archive)
    }

    static func exportData() -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try? encoder.encode(snapshot())
    }

    /// Merges a backup into the live stores rather than replacing them, so
    /// importing an older export can only ever add history back.
    @discardableResult
    static func restore(from data: Data) -> HistoryBackup? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let backup = try? decoder.decode(HistoryBackup.self, from: data) else { return nil }
        HistoryStore.shared.merge(backup.usage)
        StatusHistoryStore.shared.merge(backup.status)
        ActivityArchiveStore.shared.merge(backup.activity)
        return backup
    }

    /// A one-line summary of what an import brought in, for the settings row.
    static func summary(_ backup: HistoryBackup) -> String {
        "Imported \(backup.activity.days.count) activity days, "
            + "\(backup.status.days.count) status days, \(backup.usage.count) usage samples."
    }
}
