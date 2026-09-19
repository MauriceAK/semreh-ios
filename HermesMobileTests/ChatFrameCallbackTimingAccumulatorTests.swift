#if DEBUG
import XCTest
@testable import HermesMobile

final class ChatFrameCallbackTimingAccumulatorTests: XCTestCase {
    func testSixtyHertzCallbacksAccumulateWithoutEstimatedMisses() {
        let accumulator = ChatFrameCallbackTimingAccumulator()
        let interval = 1.0 / 60.0

        for frame in 0..<7 {
            accumulator.record(
                callbackTime: 10 + Double(frame) * interval,
                targetInterval: interval
            )
        }

        let summary = accumulator.summary()
        XCTAssertEqual(summary.callbackCount, 7)
        XCTAssertEqual(summary.callbackGapCount, 6)
        XCTAssertEqual(summary.estimatedMissedTargetIntervals, 0)
        XCTAssertEqual(summary.maximumTargetIntervalsBetweenCallbacks, 1)
        XCTAssertEqual(summary.p95TargetIntervalsBetweenCallbacks, 1)
        XCTAssertEqual(summary.p99TargetIntervalsBetweenCallbacks, 1)
        XCTAssertEqual(summary.p95CallbackGapMillisecondBin, 16)
        XCTAssertEqual(summary.p99CallbackGapMillisecondBin, 16)
    }

    func testOneHundredTwentyHertzCallbacksAccumulateWithoutEstimatedMisses() {
        let accumulator = ChatFrameCallbackTimingAccumulator()
        let interval = 1.0 / 120.0

        for frame in 0..<7 {
            accumulator.record(
                callbackTime: 20 + Double(frame) * interval,
                targetInterval: interval
            )
        }

        let summary = accumulator.summary()
        XCTAssertEqual(summary.callbackCount, 7)
        XCTAssertEqual(summary.callbackGapCount, 6)
        XCTAssertEqual(summary.estimatedMissedTargetIntervals, 0)
        XCTAssertEqual(summary.maximumTargetIntervalsBetweenCallbacks, 1)
        XCTAssertEqual(summary.p95TargetIntervalsBetweenCallbacks, 1)
        XCTAssertEqual(summary.p99TargetIntervalsBetweenCallbacks, 1)
        XCTAssertEqual(summary.p95CallbackGapMillisecondBin, 8)
        XCTAssertEqual(summary.p99CallbackGapMillisecondBin, 8)
    }

    func testMissedTargetIntervalsAppearInMaximumAndP95Aggregates() {
        let accumulator = ChatFrameCallbackTimingAccumulator()
        let interval = 1.0 / 60.0

        accumulator.record(callbackTime: 0, targetInterval: interval)
        accumulator.record(callbackTime: 2 * interval, targetInterval: interval)

        let summary = accumulator.summary()
        XCTAssertEqual(summary.callbackGapCount, 1)
        XCTAssertEqual(summary.estimatedMissedTargetIntervals, 1)
        XCTAssertEqual(summary.callbackGapsWithEstimatedMisses, 1)
        XCTAssertEqual(summary.maximumTargetIntervalsBetweenCallbacks, 2)
        XCTAssertEqual(summary.p95TargetIntervalsBetweenCallbacks, 2)
        XCTAssertEqual(summary.p99TargetIntervalsBetweenCallbacks, 2)
        XCTAssertEqual(summary.p95CallbackGapMillisecondBin, 33)
        XCTAssertEqual(summary.p99CallbackGapMillisecondBin, 33)
    }

    func testSixtyAndOneHundredTwentyHertzCadenceChangesRebaseWithoutFalseMisses() {
        let accumulator = ChatFrameCallbackTimingAccumulator()
        let interval120 = 1.0 / 120.0
        let interval60 = 1.0 / 60.0
        let start = 30.0

        accumulator.record(callbackTime: start, targetInterval: interval120)
        accumulator.record(callbackTime: start + interval120, targetInterval: interval120)
        accumulator.record(
            callbackTime: start + interval120 + interval60,
            targetInterval: interval60
        )
        accumulator.record(
            callbackTime: start + interval120 + 2 * interval60,
            targetInterval: interval60
        )
        accumulator.record(
            callbackTime: start + interval120 + 2 * interval60 + interval120,
            targetInterval: interval120
        )
        accumulator.record(
            callbackTime: start + interval120 + 2 * interval60 + 2 * interval120,
            targetInterval: interval120
        )

        let summary = accumulator.summary()
        XCTAssertEqual(summary.callbackCount, 6)
        XCTAssertEqual(summary.callbackGapCount, 3)
        XCTAssertEqual(summary.cadenceChangeRebases, 2)
        XCTAssertEqual(summary.estimatedMissedTargetIntervals, 0)
        XCTAssertEqual(summary.maximumTargetIntervalsBetweenCallbacks, 1)
    }

    func testPauseDropsOnlyTheTimingBaselineAndResetClearsTheAggregate() {
        let accumulator = ChatFrameCallbackTimingAccumulator()
        let interval = 1.0 / 60.0

        accumulator.record(callbackTime: 40, targetInterval: interval)
        accumulator.record(callbackTime: 40 + interval, targetInterval: interval)
        accumulator.pause()
        accumulator.record(callbackTime: 400, targetInterval: interval)
        accumulator.record(callbackTime: 400 + interval, targetInterval: interval)

        let afterResume = accumulator.summary()
        XCTAssertEqual(afterResume.callbackCount, 4)
        XCTAssertEqual(afterResume.callbackGapCount, 2)
        XCTAssertEqual(afterResume.estimatedMissedTargetIntervals, 0)

        accumulator.reset()
        let reset = accumulator.summary()
        XCTAssertEqual(reset.callbackCount, 0)
        XCTAssertEqual(reset.callbackGapCount, 0)
        XCTAssertEqual(reset.estimatedMissedTargetIntervals, 0)
        XCTAssertNil(reset.maximumCallbackGapMilliseconds)
        XCTAssertEqual(accumulator.histogramStorageCount, ChatFrameCallbackTimingAccumulator.histogramStorageBinCount)
    }

    func testLargeSamplesKeepHistogramStorageBounded() {
        let accumulator = ChatFrameCallbackTimingAccumulator()
        let interval = 1.0 / 60.0
        let fixedStorageCount = accumulator.histogramStorageCount

        for frame in 0..<20_000 {
            accumulator.record(
                callbackTime: 50 + Double(frame) * interval,
                targetInterval: interval
            )
        }

        XCTAssertEqual(accumulator.histogramStorageCount, fixedStorageCount)
        XCTAssertEqual(fixedStorageCount, ChatFrameCallbackTimingAccumulator.histogramStorageBinCount)
        XCTAssertEqual(accumulator.summary().callbackCount, 20_000)
    }

    func testVeryLargeFiniteGapUsesOverflowBinsWithoutTrapping() {
        let accumulator = ChatFrameCallbackTimingAccumulator()
        let interval = 1.0 / 60.0

        accumulator.record(callbackTime: 0, targetInterval: interval)
        accumulator.record(callbackTime: 1e300, targetInterval: interval)

        let summary = accumulator.summary()
        XCTAssertEqual(summary.maximumTargetIntervalsBetweenCallbacks, Int.max)
        XCTAssertEqual(summary.estimatedMissedTargetIntervals, Int.max - 1)
        XCTAssertEqual(summary.p95TargetIntervalsBetweenCallbacks, 32)
        XCTAssertEqual(summary.p99TargetIntervalsBetweenCallbacks, 32)
        XCTAssertEqual(summary.p95CallbackGapMillisecondBin, 500)
        XCTAssertEqual(summary.p99CallbackGapMillisecondBin, 500)
        XCTAssertTrue(summary.formattedReport.contains("p95_target_intervals_between_callbacks=32+"))
        XCTAssertTrue(summary.formattedReport.contains("p99_target_intervals_between_callbacks=32+"))
    }

    func testAccumulatorRetainsExactWorstGapEndpointsAndTargetIntervals() throws {
        let accumulator = ChatFrameCallbackTimingAccumulator()
        let interval = 1.0 / 60.0

        accumulator.record(callbackTime: 10, targetInterval: interval)
        accumulator.record(callbackTime: 10 + interval, targetInterval: interval)
        accumulator.record(callbackTime: 10 + interval + 0.250, targetInterval: interval)

        let summary = accumulator.summary()
        XCTAssertEqual(summary.maximumCallbackGapMilliseconds ?? 0, 250, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(summary.maximumCallbackGapStartTime), 10 + interval, accuracy: 0.000_001)
        XCTAssertEqual(try XCTUnwrap(summary.maximumCallbackGapEndTime), 10 + interval + 0.250, accuracy: 0.000_001)
        XCTAssertEqual(summary.maximumCallbackGapTargetIntervals, 15)

        accumulator.reset()
        let reset = accumulator.summary()
        XCTAssertNil(reset.maximumCallbackGapStartTime)
        XCTAssertNil(reset.maximumCallbackGapEndTime)
        XCTAssertNil(reset.maximumCallbackGapTargetIntervals)
    }

    func testP95AndP99UseTheBoundedGapHistogram() {
        let accumulator = ChatFrameCallbackTimingAccumulator()
        let interval = 1.0 / 60.0
        var callbackTime = 0.0

        accumulator.record(callbackTime: callbackTime, targetInterval: interval)
        for _ in 0..<94 {
            callbackTime += interval
            accumulator.record(callbackTime: callbackTime, targetInterval: interval)
        }
        for _ in 0..<4 {
            callbackTime += 2 * interval
            accumulator.record(callbackTime: callbackTime, targetInterval: interval)
        }
        callbackTime += 6 * interval
        accumulator.record(callbackTime: callbackTime, targetInterval: interval)
        callbackTime += 18 * interval
        accumulator.record(callbackTime: callbackTime, targetInterval: interval)

        let summary = accumulator.summary()
        XCTAssertEqual(summary.callbackGapCount, 100)
        XCTAssertEqual(summary.p95TargetIntervalsBetweenCallbacks, 2)
        XCTAssertEqual(summary.p99TargetIntervalsBetweenCallbacks, 6)
        XCTAssertEqual(summary.p95CallbackGapMillisecondBin, 33)
        XCTAssertEqual(summary.p99CallbackGapMillisecondBin, 100)
        XCTAssertEqual(summary.maximumTargetIntervalsBetweenCallbacks, 18)
        XCTAssertEqual(summary.maximumCallbackGapMilliseconds ?? 0, 300, accuracy: 0.01)
    }

    func testMonitorLabelsPhaseGapsAndKeepsPhaseBaselinesIndependent() {
        let monitor = ChatPerformanceCadenceMonitor()
        let interval = 1.0 / 60.0
        monitor.startSampling(at: 0)

        monitor.beginPhase(.entry, at: 0)
        monitor.record(callbackTime: 0, targetInterval: interval)
        monitor.record(callbackTime: interval, targetInterval: interval)
        monitor.endPhase(.entry, at: 2 * interval)

        monitor.beginPhase(.back, at: 2)
        monitor.record(callbackTime: 2.250, targetInterval: interval)
        monitor.record(callbackTime: 2.250 + interval, targetInterval: interval)
        monitor.endPhase(.back, at: 2.250 + 2 * interval)

        monitor.beginPhase(.send, at: 4)
        monitor.record(callbackTime: 4, targetInterval: interval)
        monitor.record(callbackTime: 4 + interval, targetInterval: interval)
        monitor.endPhase(.send, at: 4 + 2 * interval)

        let summary = monitor.summary(at: 11)
        XCTAssertEqual(summary.sampleDurationSeconds, 11, accuracy: 0.000_001)
        XCTAssertEqual(summary.phaseEventCounts[.entry], 1)
        XCTAssertEqual(summary.phaseEventCounts[.back], 1)
        XCTAssertEqual(summary.phaseEventCounts[.send], 1)
        XCTAssertEqual(summary.phaseSummaries[.entry]?.callbackGapCount, 1)
        XCTAssertEqual(summary.phaseSummaries[.back]?.callbackGapCount, 1)
        XCTAssertEqual(summary.phaseSummaries[.send]?.callbackGapCount, 1)
        XCTAssertEqual(summary.phaseSummaries[.back]?.maximumTargetIntervalsBetweenCallbacks, 1)
        XCTAssertEqual(summary.phaseTimings[.entry]?.eventCount, 1)
        XCTAssertEqual(summary.phaseTimings[.entry]?.eventsWithoutCallback, 0)
        XCTAssertEqual(
            summary.phaseTimings[.entry]?.maximumInteractionDurationSeconds ?? 0,
            2 * interval,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            summary.phaseTimings[.back]?.maximumFirstCallbackLatencySeconds ?? 0,
            0.250,
            accuracy: 0.000_001
        )
        XCTAssertTrue(summary.formattedReport.contains("phase=entry"))
        XCTAssertTrue(summary.formattedReport.contains("phase=back"))
        XCTAssertTrue(summary.formattedReport.contains("phase=send"))
        XCTAssertTrue(summary.formattedReport.contains("p99_callback_gap_ms_upper_bin="))
    }

    func testMonitorCorrelatesWorstGapAcrossPhaseEndWithRelativeMonotonicTimestamps() throws {
        let monitor = ChatPerformanceCadenceMonitor()
        let interval = 1.0 / 60.0
        let sampleStart = 100.0
        monitor.startSampling(at: sampleStart)

        // The first callback establishes the aggregate baseline before entry.
        monitor.record(callbackTime: sampleStart, targetInterval: interval)
        monitor.beginPhase(.entry, at: sampleStart + 0.010)
        monitor.endPhase(.entry, at: sampleStart + 0.100)
        // This gap spans the entry boundary, which is exactly the case that a
        // phase-local callback histogram cannot observe.
        monitor.record(callbackTime: sampleStart + 0.800, targetInterval: interval)

        let summary = monitor.summary(at: sampleStart + 1.0)
        let correlation = try XCTUnwrap(summary.worstGapCorrelation)
        XCTAssertEqual(correlation.gapSeconds, 0.800, accuracy: 0.000_001)
        XCTAssertEqual(correlation.targetIntervalCount, 48)
        XCTAssertEqual(correlation.startSecondsFromSampleStart, 0, accuracy: 0.000_001)
        XCTAssertEqual(correlation.endSecondsFromSampleStart, 0.800, accuracy: 0.000_001)
        XCTAssertEqual(correlation.overlappingPhase, .entry)
        XCTAssertEqual(summary.phaseBoundaryRecords.count, 1)
        XCTAssertEqual(summary.phaseBoundaryRecords[0].phase, .entry)
        XCTAssertEqual(summary.phaseBoundaryRecords[0].startSecondsFromSampleStart, 0.010, accuracy: 0.000_001)
        XCTAssertEqual(summary.phaseBoundaryRecords[0].endSecondsFromSampleStart, 0.100, accuracy: 0.000_001)
        XCTAssertTrue(summary.formattedReport.contains("worst_callback_gap_phase=entry"))
        XCTAssertTrue(summary.formattedReport.contains("worst_callback_gap_start_seconds_from_sample=0.000"))
    }

    func testMonitorScenePauseRebasesWithoutCountingSleepAsGap() {
        let monitor = ChatPerformanceCadenceMonitor()
        let interval = 1.0 / 60.0
        monitor.startSampling(at: 100)
        monitor.beginPhase(.entry, at: 100)
        monitor.record(callbackTime: 100, targetInterval: interval)
        monitor.record(callbackTime: 100 + interval, targetInterval: interval)

        monitor.setSceneActive(false, at: 200)
        monitor.setSceneActive(true, at: 260)
        monitor.record(callbackTime: 260, targetInterval: interval)
        monitor.record(callbackTime: 260 + interval, targetInterval: interval)
        monitor.endPhase(.entry, at: 261)

        let summary = monitor.summary(at: 261)
        XCTAssertEqual(summary.scenePauseCount, 1)
        XCTAssertEqual(summary.scenePauseSeconds, 60, accuracy: 0.001)
        XCTAssertEqual(summary.aggregate.callbackGapCount, 2)
        XCTAssertEqual(summary.aggregate.estimatedMissedTargetIntervals, 0)
        XCTAssertEqual(
            summary.phaseTimings[.entry]?.maximumInteractionDurationSeconds ?? 0,
            101,
            accuracy: 0.000_001
        )
        XCTAssertTrue(summary.formattedReport.contains("phase=scene_pause pause_count=1"))
    }

    func testSynchronousPhaseWithoutCallbackReportsInteractionDurationAndNoCoverage() throws {
        let monitor = ChatPerformanceCadenceMonitor()
        monitor.startSampling(at: 0)
        monitor.beginPhase(.entry, at: 10)
        let summary = monitor.stopSampling(at: 10.250)
        let timing = try XCTUnwrap(summary.phaseTimings[.entry])
        XCTAssertEqual(summary.phaseSummaries[.entry]?.callbackCount, 0)
        XCTAssertEqual(timing.eventCount, 1)
        XCTAssertEqual(timing.timedEventCount, 1)
        XCTAssertEqual(timing.eventsWithoutCallback, 1)
        XCTAssertEqual(timing.totalInteractionDurationSeconds, 0.250, accuracy: 0.000_001)
        XCTAssertEqual(timing.maximumInteractionDurationSeconds ?? 0, 0.250, accuracy: 0.000_001)
        XCTAssertNil(timing.maximumFirstCallbackLatencySeconds)
        XCTAssertEqual(summary.phaseBoundaryRecords.count, 1)
        XCTAssertNil(summary.worstGapCorrelation)
        XCTAssertTrue(summary.formattedReport.contains("interaction_events_without_callback=1"))
        XCTAssertTrue(summary.formattedReport.contains("phase_callback_timing_coverage=none"))
    }

    func testMonitorKeepsPhaseHistogramStorageBounded() {
        let monitor = ChatPerformanceCadenceMonitor()
        let interval = 1.0 / 60.0
        monitor.startSampling(at: 0)
        let fixedStorageCount = monitor.histogramStorageCount

        monitor.beginPhase(.send, at: 0)
        for frame in 0..<20_000 {
            monitor.record(
                callbackTime: Double(frame) * interval,
                targetInterval: interval
            )
        }

        XCTAssertEqual(monitor.histogramStorageCount, fixedStorageCount)
        XCTAssertEqual(
            fixedStorageCount,
            ChatFrameCallbackTimingAccumulator.histogramStorageBinCount * 4
        )
    }

    func testMonitorKeepsPhaseBoundaryCorrelationRecordsBoundedAndResettable() {
        let monitor = ChatPerformanceCadenceMonitor()
        monitor.startSampling(at: 0)

        for index in 0..<(ChatPerformanceCadenceMonitor.phaseBoundaryRecordCapacity + 5) {
            let start = Double(index)
            monitor.beginPhase(.send, at: start)
            monitor.endPhase(.send, at: start + 0.010)
        }

        XCTAssertEqual(
            monitor.phaseBoundaryRecordCount,
            ChatPerformanceCadenceMonitor.phaseBoundaryRecordCapacity
        )
        let summary = monitor.summary(at: 40)
        XCTAssertEqual(
            summary.phaseBoundaryRecords.count,
            ChatPerformanceCadenceMonitor.phaseBoundaryRecordCapacity
        )
        XCTAssertEqual(summary.phaseBoundaryRecords.first?.startSecondsFromSampleStart ?? -1, 5, accuracy: 0.000_001)

        monitor.reset()
        XCTAssertEqual(monitor.phaseBoundaryRecordCount, 0)
        monitor.startSampling(at: 100)
        XCTAssertTrue(monitor.summary(at: 100).phaseBoundaryRecords.isEmpty)
    }
}
#endif
