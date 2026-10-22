import Foundation

/// One fused real-world vessel -- the counterpart of fusion/track.py.
final class Track {
    let id: Int
    var mmsi: Int?
    var name: String?
    var kind: VesselKind?
    var kf: KalmanFilter
    let createdAt: Date
    var lastUpdate: Date
    var lastAISAt: Date?
    var lastRadarAt: Date?
    var lastAIS: AISReport?
    var aisHits = 0
    var radarHits = 0
    /// Radar plots since the last AIS report -- how consistently radar has
    /// corroborated the track while its AIS is quiet.
    var radarHitsSinceAIS = 0
    /// Smoothed gap between AIS reports. AIS cadence ranges from 2 s (fast
    /// Class A) to 3 min (anchored) and 30 s+ (Class B), so the went-dark
    /// silence threshold is scaled per vessel instead of fixed.
    var aisIntervalS: Double?
    /// Radar-only tracks start tentative and need confirmHits plots before
    /// they're shown -- that's what keeps sea clutter off the picture.
    var confirmed: Bool
    var missedSweeps = 0
    var updates = 0
    var trail: [LatLon] = []

    init(id: Int, kf: KalmanFilter, at time: Date, confirmed: Bool) {
        self.id = id
        self.kf = kf
        createdAt = time
        lastUpdate = time
        self.confirmed = confirmed
    }

    var isRadarOnly: Bool { mmsi == nil }

    func predictedXY(at t: Date) -> (Double, Double) {
        let (x, _) = kf.peekPredict(t.timeIntervalSince(lastUpdate))
        return (x.a[0], x.a[1])
    }

    /// Last AIS report says the vessel isn't under way.
    var aisStationary: Bool {
        guard let r = lastAIS else { return false }
        return NavStatus.isStationary(r.navStatus) || (r.sogKnots ?? 0) < 1
    }

    func noteTrail(_ p: LatLon) {
        trail.append(p)
        if trail.count > 90 { trail.removeFirst(trail.count - 90) }
    }
}

/// Per-update record the detectors consume (fused_track_events in Dark Track).
struct UpdateEvent {
    enum Source: String { case ais, radar }
    var trackID: Int
    var source: Source
    var time: Date
    var residualM: Double
    var innovationStdM: Double
    /// Set when an AIS report lands implausibly far from the vessel's
    /// previous AIS position -- spoofing or a misconfigured transponder.
    var jump: (distanceM: Double, impliedKnots: Double)?
}

struct FusionConfig {
    var accelStd = 0.08            // m/s^2 -- ships manoeuvre slowly
    var aisPosStdM = 15.0
    var aisVelStdMps = 0.5
    var minGateM = 500.0
    var maxGateM = 3_000.0
    var chi2Gate = 13.82           // 2 dof, 99.9%
    var radarStalenessS = 900.0    // a dark vessel coasts this long and can still take radar
    var confirmHits = 3
    var tentativeMaxMisses = 2
    var radarOnlyRetireS = 90.0
    var retireS = 1_800.0
    var jumpMinDistanceM = 2_000.0
    var jumpMinKnots = 60.0
}

final class FusionEngine {
    let projection: LocalProjection
    var config: FusionConfig
    private(set) var tracks: [Int: Track] = [:]
    private var byMMSI: [Int: Int] = [:]
    private var nextID = 1

    init(origin: LatLon, config: FusionConfig = FusionConfig()) {
        projection = LocalProjection(origin: origin)
        self.config = config
    }

    // MARK: AIS (identified)

    func ingest(ais reports: [AISReport]) -> [UpdateEvent] {
        reports.sorted { $0.time < $1.time }.compactMap(ingest(ais:))
    }

    private func ingest(ais r: AISReport) -> UpdateEvent? {
        let (zx, zy) = projection.toXY(r.position)
        let v: (Double, Double)? = {
            guard let s = r.sogKnots, let c = r.cogDeg else { return nil }
            return velocityXY(sogKnots: s, cogDeg: c)
        }()

        let track: Track
        var jump: (Double, Double)?
        if let id = byMMSI[r.mmsi], let t = tracks[id] {
            track = t
            if let prev = t.lastAIS {
                if r.time <= prev.time { return nil }  // duplicate / out of order
                let (px, py) = projection.toXY(prev.position)
                let d = hypot(zx - px, zy - py)
                let knots = d / r.time.timeIntervalSince(prev.time) / Units.mpsPerKnot
                if d > config.jumpMinDistanceM && knots > config.jumpMinKnots { jump = (d, knots) }
                let gap = min(r.time.timeIntervalSince(prev.time), 300)
                t.aisIntervalS = t.aisIntervalS.map { 0.8 * $0 + 0.2 * gap } ?? gap
            }
        } else if let adopted = adoptRadarOnly(x: zx, y: zy, at: r.time) {
            track = adopted
            byMMSI[r.mmsi] = adopted.id
        } else {
            let kf = KalmanFilter(x0: zx, y0: zy, v0: v, accelStd: config.accelStd,
                                  initPosVar: config.aisPosStdM * config.aisPosStdM, initVelVar: 4)
            track = Track(id: nextID, kf: kf, at: r.time, confirmed: true)
            nextID += 1
            tracks[track.id] = track
            byMMSI[r.mmsi] = track.id
        }

        track.mmsi = r.mmsi
        track.confirmed = true
        if let n = r.name, !n.isEmpty { track.name = n }
        if let k = r.kind { track.kind = k }

        var res: (residualM: Double, innovationStdM: Double) = (0, track.kf.lastInnovationStdM)
        if jump != nil {
            track.kf.reset(x0: zx, y0: zy, v0: v, initPosVar: config.aisPosStdM * config.aisPosStdM)
        } else if track.aisHits > 0 || track.radarHits > 0 {
            track.kf.predict(r.time.timeIntervalSince(track.lastUpdate))
            res = track.kf.update(z: (zx, zy), rStd: config.aisPosStdM, v: v, rvStd: config.aisVelStdMps)
        }
        track.lastUpdate = max(track.lastUpdate, r.time)
        track.lastAISAt = r.time
        track.lastAIS = r
        track.aisHits += 1
        track.radarHitsSinceAIS = 0
        track.updates += 1
        track.noteTrail(r.position)
        return UpdateEvent(trackID: track.id, source: .ais, time: r.time,
                           residualM: res.residualM, innovationStdM: res.innovationStdM,
                           jump: jump.map { (distanceM: $0.0, impliedKnots: $0.1) })
    }

    /// A vessel first seen by radar, then switching AIS on, is one vessel,
    /// not two: hand the radar-only track its identity.
    private func adoptRadarOnly(x: Double, y: Double, at t: Date) -> Track? {
        var best: (Track, Double)?
        for tr in tracks.values where tr.isRadarOnly && tr.confirmed {
            let (px, py) = tr.predictedXY(at: t)
            let d = hypot(px - x, py - y)
            if d < 800, d < (best?.1 ?? .infinity) { best = (tr, d) }
        }
        return best?.0
    }

    // MARK: Radar (anonymous)

    func ingest(radar contacts: [RadarContact], at sweepTime: Date) -> [UpdateEvent] {
        let candidates = tracks.values
            .filter { sweepTime.timeIntervalSince($0.lastUpdate) <= config.radarStalenessS }
            .sorted { $0.id < $1.id }
        let pts = contacts.map { projection.toXY($0.position) }

        let ungated = 1e9
        var cost = [[Double]](repeating: [Double](repeating: ungated, count: max(candidates.count, 1)),
                              count: contacts.count)
        if !candidates.isEmpty {
            let preds = candidates.map { $0.kf.peekPredict(sweepTime.timeIntervalSince($0.lastUpdate)) }
            for (i, c) in contacts.enumerated() {
                let r2 = c.rStdM * c.rStdM
                for (j, p) in preds.enumerated() {
                    let dx = pts[i].x - p.x.a[0], dy = pts[i].y - p.x.a[1]
                    let dist = hypot(dx, dy)
                    if dist > config.maxGateM { continue }
                    let sxx = p.P[0, 0] + r2, syy = p.P[1, 1] + r2, sxy = p.P[0, 1]
                    let det = sxx * syy - sxy * sxy
                    let mahal2 = (syy * dx * dx - 2 * sxy * dx * dy + sxx * dy * dy) / det
                    guard dist <= config.minGateM || mahal2 <= config.chi2Gate else { continue }
                    // Negative log-likelihood (x2, constants dropped), as in
                    // associate.py: a tight-covariance neighbour can't win a
                    // plot just by being a little closer than a coasting track.
                    cost[i][j] = mahal2 + log(det)
                }
            }
        }

        var events: [UpdateEvent] = []
        var matched = Set<Int>()
        let assignment = candidates.isEmpty ? Array(repeating: nil, count: contacts.count) : hungarian(cost)
        for (i, j) in assignment.enumerated() {
            let c = contacts[i]
            if let j, cost[i][j] < ungated {
                let tr = candidates[j]
                tr.kf.predict(sweepTime.timeIntervalSince(tr.lastUpdate))
                let res = tr.kf.update(z: pts[i], rStd: c.rStdM)
                tr.lastUpdate = sweepTime
                tr.lastRadarAt = sweepTime
                tr.radarHits += 1
                tr.radarHitsSinceAIS += 1
                tr.updates += 1
                tr.missedSweeps = 0
                if tr.isRadarOnly && !tr.confirmed && tr.radarHits >= config.confirmHits { tr.confirmed = true }
                if tr.isRadarOnly { tr.noteTrail(projection.toLatLon(x: tr.kf.position.0, y: tr.kf.position.1)) }
                matched.insert(tr.id)
                events.append(UpdateEvent(trackID: tr.id, source: .radar, time: sweepTime,
                                          residualM: res.residualM, innovationStdM: res.innovationStdM))
            } else {
                let kf = KalmanFilter(x0: pts[i].x, y0: pts[i].y, accelStd: config.accelStd * 3,
                                      initPosVar: c.rStdM * c.rStdM, initVelVar: 100)
                let tr = Track(id: nextID, kf: kf, at: sweepTime, confirmed: false)
                nextID += 1
                tr.lastRadarAt = sweepTime
                tr.radarHits = 1
                tracks[tr.id] = tr
                matched.insert(tr.id)
            }
        }
        for tr in tracks.values where tr.isRadarOnly && !tr.confirmed && !matched.contains(tr.id) {
            tr.missedSweeps += 1
        }
        return events
    }

    // MARK: Housekeeping

    /// Drops dead tentative tracks and long-silent tracks. Returns retired ids.
    @discardableResult
    func retire(now: Date) -> [Int] {
        var gone: [Int] = []
        for tr in tracks.values {
            let silent = now.timeIntervalSince(tr.lastUpdate)
            let drop: Bool
            if tr.isRadarOnly {
                drop = tr.confirmed ? silent > config.radarOnlyRetireS : tr.missedSweeps > config.tentativeMaxMisses
            } else {
                drop = silent > config.retireS
            }
            if drop { gone.append(tr.id) }
        }
        for id in gone {
            if let m = tracks[id]?.mmsi { byMMSI[m] = nil }
            tracks[id] = nil
        }
        return gone
    }

    func latLon(of track: Track, at t: Date) -> LatLon {
        let (x, y) = track.predictedXY(at: t)
        return projection.toLatLon(x: x, y: y)
    }
}
