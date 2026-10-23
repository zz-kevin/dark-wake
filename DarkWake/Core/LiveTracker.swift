import Foundation

/// Live mode without the networking: real AIS reports in, a synthetic
/// coastal radar derived from them, the fusion/detection pipeline, and
/// dropout injection -- Dark Track's ingestion pattern (real cooperative
/// feed, simulated non-cooperative one) at sea. Driven by explicit times so
/// tests can replay a feed.
///
/// Because the radar is derived from AIS, a vessel that really switches AIS
/// off also vanishes from this radar. Real dropouts therefore surface as
/// "AIS gap (unconfirmed)"; the radar-confirmed "went dark" path is
/// exercised by injection, which hides a vessel's AIS from fusion while the
/// radar keeps seeing it (anomaly/inject.py's approach).
final class LiveTracker {
    let pipeline: Pipeline
    private(set) var truth: [DarkTruth] = []
    private(set) var mmsisSeen = Set<Int>()
    private var buffer: [AISReport] = []
    private var latest: [Int: AISReport] = [:]
    private var injected: [Int: (until: Date, truthIndex: Int)] = [:]
    private var nextSweep: Date?

    /// How long after a moving vessel's last real report the radar keeps
    /// seeing it, dead-reckoned. This plus the detector's radar recency must
    /// stay under the went-dark silence floor (15 + 30 < 60), or an ordinary
    /// pause in a real feed looks like AIS off while radar still tracks it.
    /// At 40 s (40 + 30 > 60) the first live run flagged harbour tugs, pilot
    /// boats and a ferry whose AIS had paused for about a minute.
    var movingTruthS = 15.0
    /// Injected vessels are still transmitting -- fusion just doesn't get
    /// the reports -- so the radar may bridge the gap between their real
    /// reports (30 s or more on Class B) without inventing anything.
    var injectedTruthS = 60.0
    var stationaryTruthS = 600.0

    init(region: Region, detectorConfig: DetectorConfig = DetectorConfig(), seed: UInt64 = 11) {
        pipeline = Pipeline(region: region, radar: CoastalRadar(site: region.radarSite),
                            detectorConfig: detectorConfig, seed: seed)
    }

    func receive(_ r: AISReport) {
        mmsisSeen.insert(r.mmsi)
        latest[r.mmsi] = r
        if injected[r.mmsi] == nil { buffer.append(r) }
    }

    /// One cycle: AIS received since the last one, a radar sweep if due,
    /// then the detectors. Call every couple of seconds.
    @discardableResult
    func tick(now: Date) -> [Alert] {
        for (mmsi, inj) in injected where now >= inj.until {
            truth[inj.truthIndex].end = now
            injected[mmsi] = nil
        }
        let sweepDue = nextSweep.map { now >= $0 } ?? true
        if sweepDue { nextSweep = now.addingTimeInterval(pipeline.radar.sweepPeriodS) }
        let reports = buffer
        buffer.removeAll()
        return pipeline.cycle(ais: reports, radarTargets: sweepDue ? radarTargets(now: now) : nil, now: now)
    }

    /// Where the radar "sees" vessels: each one's latest real report,
    /// dead-reckoned to now.
    func radarTargets(now: Date) -> [CoastalRadar.Target] {
        let proj = LocalProjection(origin: pipeline.radar.site)
        return latest.values.compactMap { r in
            let age = now.timeIntervalSince(r.time)
            let moving = (r.sogKnots ?? 0) >= 1
            let window = !moving ? stationaryTruthS : (injected[r.mmsi] != nil ? injectedTruthS : movingTruthS)
            guard age <= window else { return nil }
            var p = r.position
            if moving, let s = r.sogKnots, let c = r.cogDeg {
                let (vx, vy) = velocityXY(sogKnots: s, cogDeg: c)
                let (x, y) = proj.toXY(p)
                p = proj.toLatLon(x: x + vx * age, y: y + vy * age)
            }
            return .init(id: String(r.mmsi), position: p, heightM: (r.kind ?? .unknown).radarHeightM)
        }
    }

    @discardableResult
    func inject(mmsi: Int, duration: TimeInterval = 480, now: Date) -> Bool {
        guard injected[mmsi] == nil, let r = latest[mmsi] else { return false }
        truth.append(DarkTruth(mmsi: mmsi, name: r.name ?? "MMSI \(mmsi)", start: now, end: nil,
                               radarVisibleAtStart: pipeline.radar.canSee(r.position, targetHeightM: (r.kind ?? .unknown).radarHeightM),
                               atEdgeAtStart: !pipeline.region.contains(r.position, marginM: pipeline.anomalies.config.edgeMarginM),
                               reason: .injected))
        injected[mmsi] = (now.addingTimeInterval(duration), truth.count - 1)
        return true
    }

    func isInjected(_ mmsi: Int) -> Bool { injected[mmsi] != nil }

    func scorecard(now: Date) -> Scorecard {
        Scorecard(truth: truth, jumps: [], alerts: pipeline.anomalies.alerts, aisVessels: mmsisSeen.count, now: now)
    }
}
