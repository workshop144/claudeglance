import Foundation

// MARK: - 5-hour burn rate & run-out ETA

/// A utilization reading at a point in time, collected each poll.
struct UsageSample: Equatable {
    let time: Date
    let utilization: Int
}

/// A burn-rate estimate derived from recent samples.
struct BurnEstimate: Equatable {
    /// How fast utilization is rising, in percentage points per hour.
    let percentPerHour: Double
    /// Seconds until utilization would reach 100% at this pace — nil when usage
    /// isn't rising (so there's no meaningful run-out time).
    let secondsToLimit: TimeInterval?

    /// True when the projected run-out lands before the window actually resets —
    /// i.e. you're on pace to hit the cap this session.
    func hitsLimitBeforeReset(resetAt: Date?, now: Date) -> Bool {
        guard let secondsToLimit, let resetAt else { return false }
        return now.addingTimeInterval(secondsToLimit) < resetAt
    }
}

/// Appends a sample to the rolling buffer, resetting it when utilization drops
/// (the window reset, or a server-side correction — old samples would otherwise
/// produce a bogus negative rate) and pruning anything older than `window`.
func appendingSample(_ sample: UsageSample, to samples: [UsageSample], window: TimeInterval = 3600) -> [UsageSample] {
    var result = samples
    if let last = result.last, sample.utilization < last.utilization {
        result = []
    }
    result.append(sample)
    let cutoff = sample.time.addingTimeInterval(-window)
    return result.filter { $0.time >= cutoff }
}

/// Estimates the burn rate and run-out time from time-ordered samples. Returns
/// nil until the samples span at least `minSpan` (so a single poll, or two polls
/// seconds apart, doesn't yield a wild extrapolation).
func estimateBurn(from samples: [UsageSample], minSpan: TimeInterval = 240) -> BurnEstimate? {
    guard let first = samples.first, let last = samples.last else { return nil }
    let dt = last.time.timeIntervalSince(first.time)
    guard dt >= minSpan else { return nil }

    let dUtil = Double(last.utilization - first.utilization)
    guard dUtil > 0 else { return BurnEstimate(percentPerHour: 0, secondsToLimit: nil) }

    let perHour = dUtil / dt * 3600.0
    let remaining = Double(max(0, 100 - last.utilization))
    let secondsToLimit = remaining / dUtil * dt
    return BurnEstimate(percentPerHour: perHour, secondsToLimit: secondsToLimit)
}

/// Locale-aware short clock time for an ETA, e.g. "3:47 PM" or "15:47".
func formatClockTime(_ date: Date) -> String {
    let f = DateFormatter()
    f.timeStyle = .short
    f.dateStyle = .none
    return f.string(from: date)
}
