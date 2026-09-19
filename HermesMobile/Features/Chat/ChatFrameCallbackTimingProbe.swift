#if DEBUG
import Foundation
import QuartzCore
import SwiftUI
import UIKit

/// Bounded summary of main-run-loop CADisplayLink callback timing. This does
/// not observe whether Core Animation or the GPU presented a frame.
struct ChatFrameCallbackTimingSummary: Equatable {
    let callbackCount: Int
    let callbackGapCount: Int
    let estimatedMissedTargetIntervals: Int
    let callbackGapsWithEstimatedMisses: Int
    let maximumTargetIntervalsBetweenCallbacks: Int
    let p95TargetIntervalsBetweenCallbacks: Int?
    let p99TargetIntervalsBetweenCallbacks: Int?
    let maximumCallbackGapMilliseconds: Double?
    /// Monotonic callback timestamps for the exact gap represented by
    /// `maximumCallbackGapMilliseconds`. The app-wide monitor converts these
    /// to offsets from its sample start before exposing correlation data.
    let maximumCallbackGapStartTime: TimeInterval?
    let maximumCallbackGapEndTime: TimeInterval?
    let maximumCallbackGapTargetIntervals: Int?
    let p95CallbackGapMillisecondBin: Int?
    let p99CallbackGapMillisecondBin: Int?
    let measuredCallbackGapSeconds: TimeInterval
    let cadenceChangeRebases: Int

    var formattedReport: String {
        return ([
            "measurement=CADisplayLink main-run-loop callback timing only; not presented frames, FPS, or GPU hitch proof",
        ] + reportLines())
            .joined(separator: "\n")
    }

    /// The metric lines are reusable by the phase-labelled app-wide report.
    /// Histogram buckets are intentionally reported as upper bounds; the raw
    /// maximum remains exact within the accumulator's finite input domain.
    func reportLines(label: String? = nil) -> [String] {
        let maximumGap = maximumCallbackGapMilliseconds.map { String(format: "%.2f", $0) } ?? "none"
        let p95Gap = Self.formattedMillisecondBucket(p95CallbackGapMillisecondBin)
        let p99Gap = Self.formattedMillisecondBucket(p99CallbackGapMillisecondBin)
        let p95Intervals = Self.formattedIntervalBucket(p95TargetIntervalsBetweenCallbacks)
        let p99Intervals = Self.formattedIntervalBucket(p99TargetIntervalsBetweenCallbacks)

        return [
            label.map { "phase=\($0)" },
            "callbacks=\(callbackCount)",
            "callback_gaps=\(callbackGapCount)",
            "measured_callback_gap_coverage_seconds=\(String(format: "%.3f", measuredCallbackGapSeconds))",
            "estimated_missed_target_intervals=\(estimatedMissedTargetIntervals)",
            "callback_gaps_with_estimated_misses=\(callbackGapsWithEstimatedMisses)",
            "maximum_target_intervals_between_callbacks=\(maximumTargetIntervalsBetweenCallbacks)",
            "p95_target_intervals_between_callbacks=\(p95Intervals)",
            "p99_target_intervals_between_callbacks=\(p99Intervals)",
            "maximum_callback_gap_ms=\(maximumGap)",
            "p95_callback_gap_ms_upper_bin=\(p95Gap)",
            "p99_callback_gap_ms_upper_bin=\(p99Gap)",
            "cadence_change_rebases=\(cadenceChangeRebases)",
            "histogram_storage_bins=\(ChatFrameCallbackTimingAccumulator.histogramStorageBinCount)"
        ].compactMap { $0 }
    }

    private static func formattedMillisecondBucket(_ bucket: Int?) -> String {
        guard let bucket else { return "none" }
        return bucket >= 500 ? "500+" : "<\(bucket + 1)"
    }

    private static func formattedIntervalBucket(_ bucket: Int?) -> String {
        guard let bucket else { return "none" }
        return bucket >= 32 ? "32+" : String(bucket)
    }
}

/// A display-link sink can be shared by the existing lab and the app-wide
/// diagnostic without making either sink observable SwiftUI state.
protocol ChatFrameCallbackTimingRecorder: AnyObject {
    func record(callbackTime: TimeInterval, targetInterval: TimeInterval)
    func pause()
}

/// A fixed-histogram accumulator: callback storage remains constant-size no
/// matter how long the opt-in sample runs. Every update is O(1), does not
/// publish SwiftUI state, and does not log.
final class ChatFrameCallbackTimingAccumulator: ChatFrameCallbackTimingRecorder {
    private static let callbackGapBinCount = 501 // 0..<500 ms, plus 500 ms and above.
    private static let targetIntervalBinCount = 33 // Exact 1...31, plus 32 and above.
    static let histogramStorageBinCount = callbackGapBinCount + targetIntervalBinCount

    private var callbackGapHistogram = [Int](repeating: 0, count: callbackGapBinCount)
    private var targetIntervalHistogram = [Int](repeating: 0, count: targetIntervalBinCount)
    private var previousCallbackTime: TimeInterval?
    private var previousTargetInterval: TimeInterval?

    private(set) var callbackCount = 0
    private(set) var callbackGapCount = 0
    private(set) var estimatedMissedTargetIntervals = 0
    private(set) var callbackGapsWithEstimatedMisses = 0
    private(set) var maximumTargetIntervalsBetweenCallbacks = 0
    private(set) var maximumCallbackGapMilliseconds: Double?
    private(set) var maximumCallbackGapStartTime: TimeInterval?
    private(set) var maximumCallbackGapEndTime: TimeInterval?
    private(set) var maximumCallbackGapTargetIntervals: Int?
    private(set) var measuredCallbackGapSeconds: TimeInterval = 0
    private(set) var cadenceChangeRebases = 0

    var histogramStorageCount: Int {
        callbackGapHistogram.count + targetIntervalHistogram.count
    }

    func reset() {
        callbackGapHistogram = [Int](repeating: 0, count: Self.callbackGapBinCount)
        targetIntervalHistogram = [Int](repeating: 0, count: Self.targetIntervalBinCount)
        callbackCount = 0
        callbackGapCount = 0
        estimatedMissedTargetIntervals = 0
        callbackGapsWithEstimatedMisses = 0
        maximumTargetIntervalsBetweenCallbacks = 0
        maximumCallbackGapMilliseconds = nil
        maximumCallbackGapStartTime = nil
        maximumCallbackGapEndTime = nil
        maximumCallbackGapTargetIntervals = nil
        measuredCallbackGapSeconds = 0
        cadenceChangeRebases = 0
        pause()
    }

    /// Drops only the timing baseline. Counts remain available across an app
    /// lifecycle pause, while a resumed sample cannot count sleep as a stall.
    func pause() {
        previousCallbackTime = nil
        previousTargetInterval = nil
    }

    func record(callbackTime: TimeInterval, targetInterval: TimeInterval) {
        guard callbackTime.isFinite, targetInterval.isFinite, targetInterval > 0 else {
            pause()
            return
        }

        callbackCount = Self.saturatingAdd(callbackCount, 1)

        guard let previousCallbackTime, let previousTargetInterval else {
            self.previousCallbackTime = callbackTime
            self.previousTargetInterval = targetInterval
            return
        }

        // A substantial target-period change (for example 120 Hz ↔ 60 Hz) is
        // a cadence rebase, not a missed callback. Do not compare across it.
        let cadenceRatio = targetInterval / previousTargetInterval
        if !cadenceRatio.isFinite || abs(cadenceRatio - 1) > 0.15 {
            cadenceChangeRebases = Self.saturatingAdd(cadenceChangeRebases, 1)
            self.previousCallbackTime = callbackTime
            self.previousTargetInterval = targetInterval
            return
        }

        let gap = callbackTime - previousCallbackTime
        guard gap.isFinite, gap >= 0 else {
            self.previousCallbackTime = callbackTime
            self.previousTargetInterval = targetInterval
            return
        }

        let gapMilliseconds = gap * 1_000
        guard gapMilliseconds.isFinite else {
            self.previousCallbackTime = callbackTime
            self.previousTargetInterval = targetInterval
            return
        }
        let intervalRatio = gap / targetInterval
        let intervalCount: Int
        if !intervalRatio.isFinite || intervalRatio >= Double(Int.max) {
            intervalCount = Int.max
        } else {
            intervalCount = max(1, Int(intervalRatio.rounded()))
        }
        let missedCount = intervalCount - 1

        callbackGapCount = Self.saturatingAdd(callbackGapCount, 1)
        Self.increment(&callbackGapHistogram, at: Self.callbackGapBin(for: gapMilliseconds))
        Self.increment(&targetIntervalHistogram, at: min(intervalCount, Self.targetIntervalBinCount - 1))
        estimatedMissedTargetIntervals = Self.saturatingAdd(estimatedMissedTargetIntervals, missedCount)
        if missedCount > 0 {
            callbackGapsWithEstimatedMisses = Self.saturatingAdd(callbackGapsWithEstimatedMisses, 1)
        }
        maximumTargetIntervalsBetweenCallbacks = max(maximumTargetIntervalsBetweenCallbacks, intervalCount)
        if maximumCallbackGapMilliseconds == nil || gapMilliseconds > maximumCallbackGapMilliseconds! {
            maximumCallbackGapMilliseconds = gapMilliseconds
            maximumCallbackGapStartTime = previousCallbackTime
            maximumCallbackGapEndTime = callbackTime
            maximumCallbackGapTargetIntervals = intervalCount
        }
        measuredCallbackGapSeconds += gap

        self.previousCallbackTime = callbackTime
        self.previousTargetInterval = targetInterval
    }

    func summary() -> ChatFrameCallbackTimingSummary {
        ChatFrameCallbackTimingSummary(
            callbackCount: callbackCount,
            callbackGapCount: callbackGapCount,
            estimatedMissedTargetIntervals: estimatedMissedTargetIntervals,
            callbackGapsWithEstimatedMisses: callbackGapsWithEstimatedMisses,
            maximumTargetIntervalsBetweenCallbacks: maximumTargetIntervalsBetweenCallbacks,
            p95TargetIntervalsBetweenCallbacks: Self.percentileBucket(
                in: targetIntervalHistogram,
                sampleCount: callbackGapCount,
                percentile: 0.95
            ),
            p99TargetIntervalsBetweenCallbacks: Self.percentileBucket(
                in: targetIntervalHistogram,
                sampleCount: callbackGapCount,
                percentile: 0.99
            ),
            maximumCallbackGapMilliseconds: maximumCallbackGapMilliseconds,
            maximumCallbackGapStartTime: maximumCallbackGapStartTime,
            maximumCallbackGapEndTime: maximumCallbackGapEndTime,
            maximumCallbackGapTargetIntervals: maximumCallbackGapTargetIntervals,
            p95CallbackGapMillisecondBin: Self.percentileBucket(
                in: callbackGapHistogram,
                sampleCount: callbackGapCount,
                percentile: 0.95
            ),
            p99CallbackGapMillisecondBin: Self.percentileBucket(
                in: callbackGapHistogram,
                sampleCount: callbackGapCount,
                percentile: 0.99
            ),
            measuredCallbackGapSeconds: measuredCallbackGapSeconds,
            cadenceChangeRebases: cadenceChangeRebases
        )
    }

    private static func callbackGapBin(for milliseconds: Double) -> Int {
        guard milliseconds.isFinite, milliseconds >= 0 else { return 0 }
        guard milliseconds < Double(callbackGapBinCount - 1) else {
            return callbackGapBinCount - 1
        }
        return Int(milliseconds.rounded(.down))
    }

    private static func percentileBucket(
        in histogram: [Int],
        sampleCount: Int,
        percentile: Double
    ) -> Int? {
        guard sampleCount > 0, percentile > 0, percentile <= 1 else { return nil }
        let rank = max(1, Int(ceil(Double(sampleCount) * percentile)))
        var cumulative = 0
        for (index, count) in histogram.enumerated() {
            cumulative = saturatingAdd(cumulative, count)
            if cumulative >= rank { return index }
        }
        return histogram.count - 1
    }

    private static func increment(_ histogram: inout [Int], at index: Int) {
        histogram[index] = saturatingAdd(histogram[index], 1)
    }

    private static func saturatingAdd(_ lhs: Int, _ rhs: Int) -> Int {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? Int.max : sum
    }
}

enum ChatPerformanceCadencePhase: String, CaseIterable, Hashable {
    case entry
    case back
    case send

    fileprivate var index: Int {
        switch self {
        case .entry: return 0
        case .back: return 1
        case .send: return 2
        }
    }
}

/// One phase interval retained for post-sample correlation. These are event
/// boundaries, not display-link samples; the monitor keeps a small fixed
/// history so a worst callback gap can be attributed without storing a
/// per-frame timeline.
struct ChatPerformanceCadencePhaseBoundaryRecord: Equatable {
    let phase: ChatPerformanceCadencePhase
    let startSecondsFromSampleStart: TimeInterval
    let endSecondsFromSampleStart: TimeInterval
}

/// Correlation for the single largest callback gap. Timestamps are offsets
/// from the opt-in sample's monotonic start, never wall-clock dates. This is
/// callback timing evidence only and does not claim a presented-frame hitch.
struct ChatPerformanceWorstCallbackGapCorrelation: Equatable {
    let gapSeconds: TimeInterval
    let targetIntervalCount: Int
    let startSecondsFromSampleStart: TimeInterval
    let endSecondsFromSampleStart: TimeInterval
    let overlappingPhase: ChatPerformanceCadencePhase?
}

/// Scalar interaction timing retained per phase. A phase can finish before a
/// display-link callback arrives, so its begin/end duration and callback
/// coverage must not be inferred from the callback-gap histogram.
struct ChatPerformancePhaseTimingSummary: Equatable {
    let eventCount: Int
    let timedEventCount: Int
    let eventsWithoutCallback: Int
    let totalInteractionDurationSeconds: TimeInterval
    let maximumInteractionDurationSeconds: TimeInterval?
    let maximumFirstCallbackLatencySeconds: TimeInterval?

    var reportLines: [String] {
        let maximumDuration = maximumInteractionDurationSeconds.map {
            String(format: "%.2f", $0 * 1_000)
        } ?? "none"
        let maximumFirstCallback = maximumFirstCallbackLatencySeconds.map {
            String(format: "%.2f", $0 * 1_000)
        } ?? "none"
        return [
            "interaction_events=\(eventCount)",
            "interaction_timed_events=\(timedEventCount)",
            "interaction_events_without_callback=\(eventsWithoutCallback)",
            "interaction_duration_total_ms=\(String(format: "%.2f", totalInteractionDurationSeconds * 1_000))",
            "interaction_duration_max_ms=\(maximumDuration)",
            "first_callback_latency_max_ms=\(maximumFirstCallback)",
        ]
    }
}

/// Fixed scalar state for one phase. It records interaction boundaries and
/// first-callback latency without retaining an event or callback timeline.
final class ChatPerformancePhaseTimingAccumulator {
    private var isActive = false
    private var startedAt: TimeInterval?
    private var pausedAt: TimeInterval?
    private var sawCallback = false

    private(set) var eventCount = 0
    private(set) var timedEventCount = 0
    private(set) var eventsWithoutCallback = 0
    private(set) var totalInteractionDurationSeconds: TimeInterval = 0
    private(set) var maximumInteractionDurationSeconds: TimeInterval?
    private(set) var maximumFirstCallbackLatencySeconds: TimeInterval?

    func reset() {
        isActive = false
        startedAt = nil
        pausedAt = nil
        sawCallback = false
        eventCount = 0
        timedEventCount = 0
        eventsWithoutCallback = 0
        totalInteractionDurationSeconds = 0
        maximumInteractionDurationSeconds = nil
        maximumFirstCallbackLatencySeconds = nil
    }

    func begin(at time: TimeInterval) {
        if isActive {
            end(at: time)
        }
        isActive = true
        startedAt = time.isFinite ? time : nil
        pausedAt = nil
        sawCallback = false
        eventCount = Self.saturatingIncrement(eventCount)
    }

    func recordFirstCallback(at time: TimeInterval) {
        guard isActive, !sawCallback else { return }
        sawCallback = true
        guard let startedAt, time.isFinite else { return }
        let latency = max(0, time - startedAt)
        guard latency.isFinite else { return }
        maximumFirstCallbackLatencySeconds = max(maximumFirstCallbackLatencySeconds ?? 0, latency)
    }

    func end(at time: TimeInterval) {
        guard isActive else { return }
        let effectiveEnd = pausedAt ?? time
        if let startedAt, effectiveEnd.isFinite {
            let duration = max(0, effectiveEnd - startedAt)
            if duration.isFinite {
                timedEventCount = Self.saturatingIncrement(timedEventCount)
                totalInteractionDurationSeconds = Self.saturatingAdd(
                    totalInteractionDurationSeconds,
                    duration
                )
                maximumInteractionDurationSeconds = max(
                    maximumInteractionDurationSeconds ?? 0,
                    duration
                )
            }
        }
        if !sawCallback {
            eventsWithoutCallback = Self.saturatingIncrement(eventsWithoutCallback)
        }
        isActive = false
        startedAt = nil
        pausedAt = nil
        sawCallback = false
    }

    func pause(at time: TimeInterval) {
        guard isActive, pausedAt == nil else { return }
        pausedAt = time.isFinite ? time : nil
    }

    func resume(at time: TimeInterval) {
        guard isActive, let pausedAt else { return }
        if let startedAt, time.isFinite {
            let pausedDuration = max(0, time - pausedAt)
            if pausedDuration.isFinite {
                let rebasedStart = startedAt + pausedDuration
                self.startedAt = rebasedStart.isFinite ? rebasedStart : time
            }
        }
        self.pausedAt = nil
    }

    func summary() -> ChatPerformancePhaseTimingSummary {
        ChatPerformancePhaseTimingSummary(
            eventCount: eventCount,
            timedEventCount: timedEventCount,
            eventsWithoutCallback: eventsWithoutCallback,
            totalInteractionDurationSeconds: totalInteractionDurationSeconds,
            maximumInteractionDurationSeconds: maximumInteractionDurationSeconds,
            maximumFirstCallbackLatencySeconds: maximumFirstCallbackLatencySeconds
        )
    }

    private static func saturatingIncrement(_ value: Int) -> Int {
        value == Int.max ? Int.max : value + 1
    }

    private static func saturatingAdd(_ lhs: TimeInterval, _ rhs: TimeInterval) -> TimeInterval {
        let sum = lhs + rhs
        return sum.isFinite ? sum : Double.greatestFiniteMagnitude
    }
}

struct ChatPerformanceCadenceMonitorSummary: Equatable {
    let aggregate: ChatFrameCallbackTimingSummary
    let phaseSummaries: [ChatPerformanceCadencePhase: ChatFrameCallbackTimingSummary]
    let phaseTimings: [ChatPerformanceCadencePhase: ChatPerformancePhaseTimingSummary]
    let phaseEventCounts: [ChatPerformanceCadencePhase: Int]
    let worstGapCorrelation: ChatPerformanceWorstCallbackGapCorrelation?
    let phaseBoundaryRecords: [ChatPerformanceCadencePhaseBoundaryRecord]
    let scenePauseCount: Int
    let scenePauseSeconds: TimeInterval
    let sampleDurationSeconds: TimeInterval

    var formattedReport: String {
        var lines = [
            "measurement=CADisplayLink main-run-loop callback timing only; not presented frames, FPS, or GPU hitch proof",
            "scope=DEBUG opt-in app-wide cadence monitor",
            "sample_duration_seconds=\(String(format: "%.3f", sampleDurationSeconds))",
            "phase_marker_scope=entry ends at ChatView.onAppear; back ends at return observation; send ends when sendDraftMessage returns; not first-presented-frame timing"
        ]

        if let worstGapCorrelation {
            let phase = worstGapCorrelation.overlappingPhase?.rawValue ?? "none"
            lines += [
                "worst_callback_gap_phase=\(phase)",
                "worst_callback_gap_seconds=\(String(format: "%.3f", worstGapCorrelation.gapSeconds))",
                "worst_callback_gap_target_intervals=\(worstGapCorrelation.targetIntervalCount)",
                "worst_callback_gap_start_seconds_from_sample=\(String(format: "%.3f", worstGapCorrelation.startSecondsFromSampleStart))",
                "worst_callback_gap_end_seconds_from_sample=\(String(format: "%.3f", worstGapCorrelation.endSecondsFromSampleStart))"
            ]
        } else {
            lines.append("worst_callback_gap_correlation=none")
        }

        let boundaryIntervals = phaseBoundaryRecords.map { record in
            "\(record.phase.rawValue):\(String(format: "%.3f", record.startSecondsFromSampleStart))-\(String(format: "%.3f", record.endSecondsFromSampleStart))"
        }.joined(separator: ",")
        lines.append(
            "phase_boundary_intervals_from_sample=\(boundaryIntervals.isEmpty ? "none" : boundaryIntervals)"
        )
        lines += aggregate.reportLines(label: "aggregate")

        for phase in ChatPerformanceCadencePhase.allCases {
            let summary = phaseSummaries[phase] ?? ChatFrameCallbackTimingAccumulator().summary()
            let timing = phaseTimings[phase] ?? ChatPerformancePhaseTimingAccumulator().summary()
            let eventCount = phaseEventCounts[phase] ?? 0
            lines.append("phase=\(phase.rawValue) phase_events=\(eventCount)")
            lines += summary.reportLines()
            lines += timing.reportLines
            let coverage: String
            if summary.callbackCount == 0 {
                coverage = "none"
            } else if summary.callbackGapCount == 0 {
                coverage = "insufficient_gap_samples"
            } else {
                coverage = "observed"
            }
            lines.append(
                "phase_callback_timing_coverage=\(coverage)"
            )
        }

        // No display-link callbacks are sampled while the scene is inactive,
        // so a background interval is reported as a lifecycle boundary rather
        // than fabricated as a callback gap.
        lines.append(
            "phase=scene_pause pause_count=\(scenePauseCount) pause_seconds=\(String(format: "%.3f", scenePauseSeconds)) "
                + "callbacks=0 callback_gaps=0 maximum_target_intervals_between_callbacks=0 "
                + "p95_target_intervals_between_callbacks=none p99_target_intervals_between_callbacks=none "
                + "maximum_callback_gap_ms=none p95_callback_gap_ms_upper_bin=none "
                + "p99_callback_gap_ms_upper_bin=none"
        )
        return lines.joined(separator: "\n")
    }
}

/// App-wide DEBUG diagnostic state. It is deliberately not an
/// ObservableObject: display-link callbacks mutate only fixed accumulators and
/// never invalidate a SwiftUI body. Phase markers are ignored unless the
/// explicit launch argument is present. The singleton is main-run-loop-owned:
/// marker calls originate in SwiftUI's main actor and the display link invokes
/// `record` on the main run loop.
final class ChatPerformanceCadenceMonitor: ChatFrameCallbackTimingRecorder {
    static let appWideOptInArgument = "--chat-performance-app-wide-monitor"
    static let shared = ChatPerformanceCadenceMonitor()
    /// Phase markers are sparse interaction boundaries, so a small bounded
    /// history is enough to correlate the largest callback gap without
    /// retaining an unbounded event timeline.
    static let phaseBoundaryRecordCapacity = 32

    private struct AbsolutePhaseBoundaryRecord {
        let phase: ChatPerformanceCadencePhase
        let startTime: TimeInterval
        let endTime: TimeInterval
    }

    static var isAppWideOptedIn: Bool {
        ProcessInfo.processInfo.arguments.contains(appWideOptInArgument)
    }

    private let aggregate = ChatFrameCallbackTimingAccumulator()
    private var phaseAccumulators = ChatPerformanceCadencePhase.allCases.map { _ in
        ChatFrameCallbackTimingAccumulator()
    }
    private var phaseTimingAccumulators = ChatPerformanceCadencePhase.allCases.map { _ in
        ChatPerformancePhaseTimingAccumulator()
    }
    private var phaseEventCounts = ChatPerformanceCadencePhase.allCases.map { _ in 0 }
    private var activePhase: ChatPerformanceCadencePhase?
    private var isSampling = false
    private var isSceneActive = true
    private var scenePauseStartedAt: TimeInterval?
    private var scenePauseCount = 0
    private var scenePauseSeconds: TimeInterval = 0
    private var sampleStartedAt: TimeInterval?
    private var phaseBoundaryRecords: [AbsolutePhaseBoundaryRecord] = []
    private var activePhaseStartedAt: TimeInterval?

    func startSampling(at time: TimeInterval = CACurrentMediaTime()) {
        aggregate.reset()
        for accumulator in phaseAccumulators {
            accumulator.reset()
        }
        for accumulator in phaseTimingAccumulators {
            accumulator.reset()
        }
        phaseEventCounts = ChatPerformanceCadencePhase.allCases.map { _ in 0 }
        activePhase = nil
        isSampling = true
        isSceneActive = true
        scenePauseStartedAt = nil
        scenePauseCount = 0
        scenePauseSeconds = 0
        sampleStartedAt = time.isFinite ? time : nil
        phaseBoundaryRecords.removeAll(keepingCapacity: true)
        activePhaseStartedAt = nil
    }

    func stopSampling(at time: TimeInterval = CACurrentMediaTime()) -> ChatPerformanceCadenceMonitorSummary {
        if let activePhase {
            finishActivePhaseBoundary(at: time)
            phaseTimingAccumulators[activePhase.index].end(at: time)
            self.activePhase = nil
        }
        let result = summary(at: time)
        isSampling = false
        pause()
        return result
    }

    func reset() {
        aggregate.reset()
        for accumulator in phaseAccumulators {
            accumulator.reset()
        }
        for accumulator in phaseTimingAccumulators {
            accumulator.reset()
        }
        phaseEventCounts = ChatPerformanceCadencePhase.allCases.map { _ in 0 }
        activePhase = nil
        isSampling = false
        isSceneActive = true
        scenePauseStartedAt = nil
        scenePauseCount = 0
        scenePauseSeconds = 0
        sampleStartedAt = nil
        phaseBoundaryRecords.removeAll(keepingCapacity: true)
        activePhaseStartedAt = nil
    }

    func beginPhase(
        _ phase: ChatPerformanceCadencePhase,
        at time: TimeInterval = CACurrentMediaTime()
    ) {
        guard isSampling else { return }
        if let activePhase {
            finishActivePhaseBoundary(at: time)
            phaseAccumulators[activePhase.index].pause()
            phaseTimingAccumulators[activePhase.index].end(at: time)
        }
        activePhase = phase
        activePhaseStartedAt = time.isFinite ? time : nil
        phaseAccumulators[phase.index].pause()
        phaseTimingAccumulators[phase.index].begin(at: time)
        if !isSceneActive {
            phaseTimingAccumulators[phase.index].pause(at: time)
        }
        phaseEventCounts[phase.index] = Self.saturatingIncrement(phaseEventCounts[phase.index])
    }

    func endPhase(
        _ phase: ChatPerformanceCadencePhase,
        at time: TimeInterval = CACurrentMediaTime()
    ) {
        guard isSampling, activePhase == phase else { return }
        finishActivePhaseBoundary(at: time)
        phaseAccumulators[phase.index].pause()
        phaseTimingAccumulators[phase.index].end(at: time)
        activePhase = nil
        activePhaseStartedAt = nil
    }

    /// Scene changes are lifecycle boundaries, not frame samples. Resuming
    /// leaves the timing baselines empty so background sleep cannot become a
    /// fabricated main-run-loop stall.
    func setSceneActive(_ active: Bool, at time: TimeInterval = CACurrentMediaTime()) {
        guard isSceneActive != active else { return }
        isSceneActive = active
        pause()

        if active {
            for accumulator in phaseTimingAccumulators {
                accumulator.resume(at: time)
            }
            if let scenePauseStartedAt, time.isFinite {
                scenePauseSeconds += max(0, time - scenePauseStartedAt)
            }
            scenePauseStartedAt = nil
        } else {
            for accumulator in phaseTimingAccumulators {
                accumulator.pause(at: time)
            }
            scenePauseCount = Self.saturatingIncrement(scenePauseCount)
            scenePauseStartedAt = time.isFinite ? time : nil
        }
    }

    func record(callbackTime: TimeInterval, targetInterval: TimeInterval) {
        guard isSampling, isSceneActive else { return }
        aggregate.record(callbackTime: callbackTime, targetInterval: targetInterval)
        if let activePhase {
            phaseTimingAccumulators[activePhase.index].recordFirstCallback(at: callbackTime)
            phaseAccumulators[activePhase.index].record(
                callbackTime: callbackTime,
                targetInterval: targetInterval
            )
        }
    }

    func pause() {
        aggregate.pause()
        for accumulator in phaseAccumulators {
            accumulator.pause()
        }
    }

    func summary(at time: TimeInterval = CACurrentMediaTime()) -> ChatPerformanceCadenceMonitorSummary {
        var phaseSummaries: [ChatPerformanceCadencePhase: ChatFrameCallbackTimingSummary] = [:]
        var phaseTimings: [ChatPerformanceCadencePhase: ChatPerformancePhaseTimingSummary] = [:]
        var eventCounts: [ChatPerformanceCadencePhase: Int] = [:]
        for phase in ChatPerformanceCadencePhase.allCases {
            phaseSummaries[phase] = phaseAccumulators[phase.index].summary()
            phaseTimings[phase] = phaseTimingAccumulators[phase.index].summary()
            eventCounts[phase] = phaseEventCounts[phase.index]
        }

        var completedPauseSeconds = scenePauseSeconds
        if let scenePauseStartedAt, time.isFinite {
            completedPauseSeconds += max(0, time - scenePauseStartedAt)
        }
        var duration: TimeInterval = 0
        if let sampleStartedAt, time.isFinite {
            duration = max(0, time - sampleStartedAt)
        }

        let aggregateSummary = aggregate.summary()
        let relativeBoundaries = relativePhaseBoundaryRecords(at: time)

        return ChatPerformanceCadenceMonitorSummary(
            aggregate: aggregateSummary,
            phaseSummaries: phaseSummaries,
            phaseTimings: phaseTimings,
            phaseEventCounts: eventCounts,
            worstGapCorrelation: worstGapCorrelation(
                from: aggregateSummary,
                boundaries: relativeBoundaries
            ),
            phaseBoundaryRecords: relativeBoundaries,
            scenePauseCount: scenePauseCount,
            scenePauseSeconds: completedPauseSeconds,
            sampleDurationSeconds: duration
        )
    }

    /// Fixed storage across the aggregate and three phase accumulators. This
    /// is exposed only for deterministic DEBUG unit coverage, not for the UI.
    var histogramStorageCount: Int {
        aggregate.histogramStorageCount
            + phaseAccumulators.reduce(0) { $0 + $1.histogramStorageCount }
    }

    /// Number of retained phase boundaries in the bounded correlation ring.
    /// This is DEBUG test visibility only; it is not rendered or published.
    var phaseBoundaryRecordCount: Int {
        phaseBoundaryRecords.count
    }

    // Static marker facade keeps production view call sites DEBUG-only and
    // avoids environment/state propagation through the whole navigation tree.
    static func begin(
        _ phase: ChatPerformanceCadencePhase,
        at time: TimeInterval = CACurrentMediaTime()
    ) {
        guard isAppWideOptedIn else { return }
        shared.beginPhase(phase, at: time)
    }

    static func end(
        _ phase: ChatPerformanceCadencePhase,
        at time: TimeInterval = CACurrentMediaTime()
    ) {
        guard isAppWideOptedIn else { return }
        shared.endPhase(phase, at: time)
    }

    static func setSceneActive(_ active: Bool) {
        guard isAppWideOptedIn else { return }
        shared.setSceneActive(active)
    }

    private func finishActivePhaseBoundary(at time: TimeInterval) {
        defer { activePhaseStartedAt = nil }
        guard let activePhase, let startTime = activePhaseStartedAt,
              startTime.isFinite, time.isFinite else { return }

        appendPhaseBoundary(
            AbsolutePhaseBoundaryRecord(
                phase: activePhase,
                startTime: startTime,
                endTime: max(startTime, time)
            )
        )
    }

    private func appendPhaseBoundary(_ record: AbsolutePhaseBoundaryRecord) {
        if phaseBoundaryRecords.count >= Self.phaseBoundaryRecordCapacity {
            phaseBoundaryRecords.removeFirst()
        }
        phaseBoundaryRecords.append(record)
    }

    private func absolutePhaseBoundaryRecords(at time: TimeInterval) -> [AbsolutePhaseBoundaryRecord] {
        var records = phaseBoundaryRecords
        guard let activePhase, let startTime = activePhaseStartedAt,
              startTime.isFinite, time.isFinite else { return records }

        if records.count >= Self.phaseBoundaryRecordCapacity {
            records.removeFirst()
        }
        records.append(
            AbsolutePhaseBoundaryRecord(
                phase: activePhase,
                startTime: startTime,
                endTime: max(startTime, time)
            )
        )
        return records
    }

    private func relativePhaseBoundaryRecords(at time: TimeInterval) -> [ChatPerformanceCadencePhaseBoundaryRecord] {
        guard let sampleStartedAt, sampleStartedAt.isFinite else { return [] }

        return absolutePhaseBoundaryRecords(at: time).compactMap { record in
            guard let start = Self.relativeTimestamp(record.startTime, from: sampleStartedAt),
                  let end = Self.relativeTimestamp(record.endTime, from: sampleStartedAt) else {
                return nil
            }
            return ChatPerformanceCadencePhaseBoundaryRecord(
                phase: record.phase,
                startSecondsFromSampleStart: start,
                endSecondsFromSampleStart: max(start, end)
            )
        }
    }

    private func worstGapCorrelation(
        from summary: ChatFrameCallbackTimingSummary,
        boundaries: [ChatPerformanceCadencePhaseBoundaryRecord]
    ) -> ChatPerformanceWorstCallbackGapCorrelation? {
        guard let sampleStartedAt, sampleStartedAt.isFinite,
              let startTime = summary.maximumCallbackGapStartTime,
              let endTime = summary.maximumCallbackGapEndTime,
              let gapMilliseconds = summary.maximumCallbackGapMilliseconds,
              let start = Self.relativeTimestamp(startTime, from: sampleStartedAt),
              let end = Self.relativeTimestamp(endTime, from: sampleStartedAt),
              gapMilliseconds.isFinite else {
            return nil
        }

        let gapSeconds = gapMilliseconds / 1_000
        guard gapSeconds.isFinite else { return nil }

        return ChatPerformanceWorstCallbackGapCorrelation(
            gapSeconds: gapSeconds,
            targetIntervalCount: summary.maximumCallbackGapTargetIntervals
                ?? summary.maximumTargetIntervalsBetweenCallbacks,
            startSecondsFromSampleStart: start,
            endSecondsFromSampleStart: max(start, end),
            overlappingPhase: Self.phaseOverlapping(
                start: start,
                end: max(start, end),
                boundaries: boundaries
            )
        )
    }

    private static func relativeTimestamp(
        _ timestamp: TimeInterval,
        from origin: TimeInterval
    ) -> TimeInterval? {
        guard timestamp.isFinite, origin.isFinite else { return nil }
        let relative = timestamp - origin
        guard relative.isFinite else { return nil }
        // A valid sample is monotonic and starts before its callbacks. Clamp
        // malformed test/instrument input rather than reporting a backwards
        // relative timeline.
        return max(0, relative)
    }

    private static func phaseOverlapping(
        start: TimeInterval,
        end: TimeInterval,
        boundaries: [ChatPerformanceCadencePhaseBoundaryRecord]
    ) -> ChatPerformanceCadencePhase? {
        guard end >= start else { return nil }
        var bestPhase: ChatPerformanceCadencePhase?
        var bestOverlap: TimeInterval = 0

        for boundary in boundaries {
            let overlapStart = max(start, boundary.startSecondsFromSampleStart)
            let overlapEnd = min(end, boundary.endSecondsFromSampleStart)
            let overlap = max(0, overlapEnd - overlapStart)
            if overlap > bestOverlap {
                bestOverlap = overlap
                bestPhase = boundary.phase
            }
        }
        return bestPhase
    }

    private static func saturatingIncrement(_ value: Int) -> Int {
        value == Int.max ? Int.max : value + 1
    }
}

/// Hidden 1×1 host for DEBUG-only callback diagnostics. A single common-mode
/// display link is active only after explicit launch-argument opt-in and start.
struct ChatFrameCallbackTimingLinkHost: UIViewRepresentable {
    let recorder: ChatFrameCallbackTimingRecorder
    let isSampling: Bool
    let sceneIsActive: Bool

    init(
        accumulator: ChatFrameCallbackTimingAccumulator,
        isSampling: Bool,
        sceneIsActive: Bool
    ) {
        recorder = accumulator
        self.isSampling = isSampling
        self.sceneIsActive = sceneIsActive
    }

    init(
        recorder: ChatFrameCallbackTimingRecorder,
        isSampling: Bool,
        sceneIsActive: Bool
    ) {
        self.recorder = recorder
        self.isSampling = isSampling
        self.sceneIsActive = sceneIsActive
    }

    func makeUIView(context: Context) -> UIView {
        let view = ChatFrameCallbackTimingHostView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        view.isAccessibilityElement = false
        view.onWindowAttachmentChanged = { [weak coordinator = context.coordinator] isAttached in
            coordinator?.setHostAttachedToWindow(isAttached)
        }
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.update(
            recorder: recorder,
            shouldRun: isSampling && sceneIsActive
        )
        context.coordinator.setHostAttachedToWindow(view.window != nil)
    }

    static func dismantleUIView(_ view: UIView, coordinator: Coordinator) {
        coordinator.stop()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    @MainActor
    final class Coordinator: NSObject {
        private var displayLink: CADisplayLink?
        private weak var recorder: ChatFrameCallbackTimingRecorder?
        private var shouldRun = false
        private var isHostAttachedToWindow = false

        func update(recorder: ChatFrameCallbackTimingRecorder, shouldRun: Bool) {
            self.recorder = recorder
            self.shouldRun = shouldRun
            reconcileDisplayLink()
        }

        func setHostAttachedToWindow(_ isAttached: Bool) {
            guard isHostAttachedToWindow != isAttached else { return }
            isHostAttachedToWindow = isAttached
            reconcileDisplayLink()
        }

        private func reconcileDisplayLink() {
            guard shouldRun, isHostAttachedToWindow else {
                pauseDisplayLink()
                return
            }
            guard displayLink == nil else { return }

            let link = CADisplayLink(target: self, selector: #selector(recordTick(_:)))
            displayLink = link
            // Common mode keeps the probe observing callback cadence during
            // scroll tracking; it does not change the display's rate policy.
            link.add(to: .main, forMode: .common)
        }

        func stop() {
            shouldRun = false
            isHostAttachedToWindow = false
            pauseDisplayLink()
            recorder = nil
        }

        private func pauseDisplayLink() {
            displayLink?.invalidate()
            displayLink = nil
            recorder?.pause()
        }

        @objc private func recordTick(_ link: CADisplayLink) {
            recorder?.record(
                callbackTime: CACurrentMediaTime(),
                targetInterval: link.targetTimestamp - link.timestamp
            )
        }
    }
}

@MainActor
private final class ChatFrameCallbackTimingHostView: UIView {
    var onWindowAttachmentChanged: ((Bool) -> Void)?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        onWindowAttachmentChanged?(window != nil)
    }
}
#endif
