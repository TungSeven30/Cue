import Foundation

/// Rough time-remaining estimate for one pipeline lane, from the durations
/// of recently completed jobs. Media lengths vary, so this is an average,
/// not a promise — display with a "~".
enum QueueETA {
    /// - Parameters:
    ///   - recentDurations: wall-clock durations of recently finished jobs
    ///     in this lane (seconds); empty means no basis for an estimate.
    ///   - pendingCount: jobs waiting in this lane, excluding the active one.
    ///   - activeFraction: progress (0...1) of the lane's running job, nil
    ///     when the lane is idle.
    static func estimate(
        recentDurations: [TimeInterval],
        pendingCount: Int,
        activeFraction: Double?
    ) -> TimeInterval? {
        let usable = recentDurations.filter { $0.isFinite && $0 > 0 }
        guard !usable.isEmpty else { return nil }
        guard pendingCount > 0 || activeFraction != nil else { return nil }
        let average = usable.reduce(0, +) / Double(usable.count)
        let activeRemainder = activeFraction.map { average * (1 - min(max($0, 0), 1)) } ?? 0
        return average * Double(pendingCount) + activeRemainder
    }
}
