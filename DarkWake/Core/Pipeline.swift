import Foundation

/// One fusion + detection cycle: AIS since the last cycle, one radar sweep,
/// then every detector. The same code runs the app (live or simulated) and
/// the tests.
final class Pipeline {
    let region: Region
    let radar: CoastalRadar
    let fusion: FusionEngine
    let anomalies: AnomalyEngine
    private var rng: SplitMix64

    init(region: Region, radar: CoastalRadar, fusionConfig: FusionConfig = FusionConfig(),
         detectorConfig: DetectorConfig = DetectorConfig(), seed: UInt64 = 11) {
        self.region = region
        self.radar = radar
        fusion = FusionEngine(origin: region.center, config: fusionConfig)
        anomalies = AnomalyEngine(region: region, config: detectorConfig)
        rng = SplitMix64(seed: seed)
    }

    @discardableResult
    func cycle(ais: [AISReport], radarTargets: [CoastalRadar.Target]?, now: Date) -> [Alert] {
        var events = fusion.ingest(ais: ais)
        if let targets = radarTargets {
            events += fusion.ingest(radar: radar.sweep(targets, at: now, rng: &rng), at: now)
        }
        let new = anomalies.step(engine: fusion, events: events, now: now)
        fusion.retire(now: now)
        return new
    }
}

/// Simulated world + pipeline, stepped one radar sweep at a time.
final class SimulationRun {
    let simulator: VesselSimulator
    let pipeline: Pipeline

    init(region: Region, start: Date = Date(), seed: UInt64 = 7,
         fusionConfig: FusionConfig = FusionConfig(), detectorConfig: DetectorConfig = DetectorConfig()) {
        let radar = CoastalRadar(site: region.radarSite)
        simulator = VesselSimulator(region: region, radar: radar, start: start, seed: seed)
        pipeline = Pipeline(region: region, radar: radar, fusionConfig: fusionConfig,
                            detectorConfig: detectorConfig, seed: seed &+ 1)
    }

    var now: Date { simulator.now }

    @discardableResult
    func step() -> [Alert] {
        let t = simulator.now.addingTimeInterval(pipeline.radar.sweepPeriodS)
        let reports = simulator.advance(to: t)
        return pipeline.cycle(ais: reports, radarTargets: simulator.radarTargets(), now: t)
    }

    func scorecard() -> Scorecard {
        Scorecard(truth: simulator.truth, jumps: simulator.jumps, alerts: pipeline.anomalies.alerts,
                  aisVessels: simulator.mmsisSeen.count, now: now)
    }
}

/// Precision/recall against simulation ground truth -- the measured-number
/// habit from Dark Track's anomaly/harness.py.
struct Scorecard {
    var scored = 0              // dark episodes long enough to judge
    var pending = 0             // still running and too young to judge yet
    var radarVisible = 0        // ...that started inside radar cover, away from the area edge
    var edgeExcluded = 0        // radar-visible but started in the edge band: not scored
    var radarUnobservable = 0   // live injections the radar had too little data to see: not scored
    var confirmedDetected = 0   // radar-visible episodes flagged "went dark"
    var anyDetected = 0         // all scored episodes flagged went dark or AIS gap
    var rendezvousScored = 0
    var rendezvousDetected = 0
    var jumpsInjected = 0
    var jumpsDetected = 0
    var falseAlarms = 0
    var falseAlarmVessels = 0
    var aisVessels = 0
    var latencies: [Double] = []

    /// Grace after AIS resumes before a late alert counts as false.
    static let slackS = 30.0
    /// Episodes shorter than this (e.g. the vessel left the area) aren't scored.
    static let minDurationS = 150.0

    init() {}

    init(truth: [DarkTruth], jumps: [JumpTruth], alerts: [Alert], aisVessels: Int, now: Date) {
        self.aisVessels = aisVessels
        let darkAlerts = alerts.filter { $0.kind == .wentDark || $0.kind == .aisGap }
        for e in truth {
            let end = e.end ?? now
            guard end.timeIntervalSince(e.start) >= Self.minDurationS else {
                if e.end == nil { pending += 1 }
                continue
            }
            guard e.radarCouldObserve else {
                radarUnobservable += 1
                continue
            }
            scored += 1
            let hits = darkAlerts.filter {
                $0.mmsi == e.mmsi && $0.detectedAt >= e.start && $0.detectedAt <= end.addingTimeInterval(Self.slackS)
            }
            if let first = hits.min(by: { $0.detectedAt < $1.detectedAt }) {
                anyDetected += 1
                latencies.append(first.detectedAt.timeIntervalSince(e.start))
            }
            if e.radarVisibleAtStart && e.atEdgeAtStart {
                edgeExcluded += 1
            } else if e.radarVisibleAtStart {
                radarVisible += 1
                if hits.contains(where: { $0.kind == .wentDark }) { confirmedDetected += 1 }
            }
            if e.reason == .rendezvous && e.end != nil {
                rendezvousScored += 1
                // By time, not MMSI: a vessel dark for a long approach is often
                // re-acquired as an anonymous radar track, so the alert may
                // name neither party.
                if alerts.contains(where: { $0.kind == .rendezvous
                    && $0.detectedAt >= e.start && $0.detectedAt <= end.addingTimeInterval(Self.slackS) }) {
                    rendezvousDetected += 1
                }
            }
        }
        jumpsInjected = jumps.count
        jumpsDetected = jumps.filter { j in
            alerts.contains { $0.kind == .positionJump && $0.mmsi == j.mmsi && abs($0.detectedAt.timeIntervalSince(j.time)) < 60 }
        }.count
        let falses = darkAlerts.filter { a in
            !truth.contains { $0.mmsi == a.mmsi && a.detectedAt >= $0.start
                && a.detectedAt <= ($0.end ?? now).addingTimeInterval(Self.slackS) }
        }
        falseAlarms = falses.count
        falseAlarmVessels = Set(falses.compactMap(\.mmsi)).count
    }

    var confirmedRecall: Double? { radarVisible == 0 ? nil : Double(confirmedDetected) / Double(radarVisible) }
    var anyRecall: Double? { scored == 0 ? nil : Double(anyDetected) / Double(scored) }
    var falseAlarmRate: Double { aisVessels == 0 ? 0 : Double(falseAlarmVessels) / Double(aisVessels) }
    var medianLatencyS: Double? {
        guard !latencies.isEmpty else { return nil }
        let s = latencies.sorted()
        return s[s.count / 2]
    }
}
