import Foundation

/// Live mode: real AIS from aisstream.io, a synthetic coastal radar derived
/// from it, and the fusion/detection pipeline -- Dark Track's ingestion
/// pattern (real cooperative feed, simulated non-cooperative one) at sea.
///
/// Because the radar is derived from AIS, a vessel that really switches AIS
/// off also vanishes from this radar. Real dropouts therefore surface as
/// "AIS gap (unconfirmed)"; the radar-confirmed "went dark" path is
/// exercised by injection, which hides a vessel's AIS from fusion while the
/// radar keeps seeing it (anomaly/inject.py's approach).
@MainActor
final class LiveFeed {
    let pipeline: Pipeline
    let client = AISStreamClient()
    private(set) var truth: [DarkTruth] = []
    private(set) var mmsisSeen = Set<Int>()
    private var buffer: [AISReport] = []
    private var latest: [Int: AISReport] = [:]
    private var injected: [Int: (until: Date, truthIndex: Int)] = [:]
    private var nextSweep = Date()

    init(region: Region, detectorConfig: DetectorConfig) {
        pipeline = Pipeline(region: region, radar: CoastalRadar(site: region.radarSite), detectorConfig: detectorConfig)
        client.onReport = { [weak self] r in self?.receive(r) }
    }

    func start(apiKey: String) { client.connect(apiKey: apiKey, region: pipeline.region) }
    func stop() { client.disconnect() }

    private func receive(_ r: AISReport) {
        mmsisSeen.insert(r.mmsi)
        latest[r.mmsi] = r
        if injected[r.mmsi] == nil { buffer.append(r) }
    }

    /// One cycle; call every couple of seconds.
    func tick(now: Date = Date()) {
        for (mmsi, inj) in injected where now >= inj.until {
            truth[inj.truthIndex].end = now
            injected[mmsi] = nil
        }
        let sweepDue = now >= nextSweep
        if sweepDue { nextSweep = now.addingTimeInterval(pipeline.radar.sweepPeriodS) }
        let reports = buffer
        buffer.removeAll()
        pipeline.cycle(ais: reports, radarTargets: sweepDue ? radarTargets(now: now) : nil, now: now)
    }

    /// Where the radar "sees" vessels: each one's latest real report,
    /// dead-reckoned to now. Moving vessels expire after 40 s -- under the
    /// 60 s went-dark floor -- so a real AIS dropout doesn't leave a phantom
    /// radar return behind that would look like a confirmed dark vessel.
    private func radarTargets(now: Date) -> [CoastalRadar.Target] {
        let proj = LocalProjection(origin: pipeline.radar.site)
        return latest.values.compactMap { r in
            let age = now.timeIntervalSince(r.time)
            let moving = (r.sogKnots ?? 0) >= 1
            guard age <= (moving ? 40 : 600) else { return nil }
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
    func inject(mmsi: Int, duration: TimeInterval = 480, now: Date = Date()) -> Bool {
        guard injected[mmsi] == nil, let r = latest[mmsi] else { return false }
        truth.append(DarkTruth(mmsi: mmsi, name: r.name ?? "MMSI \(mmsi)", start: now, end: nil,
                               radarVisibleAtStart: pipeline.radar.canSee(r.position, targetHeightM: (r.kind ?? .unknown).radarHeightM),
                               reason: .injected))
        injected[mmsi] = (now.addingTimeInterval(duration), truth.count - 1)
        return true
    }

    func isInjected(_ mmsi: Int) -> Bool { injected[mmsi] != nil }

    func scorecard(now: Date) -> Scorecard {
        Scorecard(truth: truth, jumps: [], alerts: pipeline.anomalies.alerts, aisVessels: mmsisSeen.count, now: now)
    }
}
