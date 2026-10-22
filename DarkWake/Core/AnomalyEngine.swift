import Foundation

enum AlertKind: String, CaseIterable, Codable {
    case wentDark, aisGap, positionJump, kinematic, rendezvous, noAIS

    var title: String {
        switch self {
        case .wentDark: return "Went dark"
        case .aisGap: return "AIS gap (unconfirmed)"
        case .positionJump: return "AIS position jump"
        case .kinematic: return "Kinematic anomaly"
        case .rendezvous: return "Dark rendezvous"
        case .noAIS: return "No-AIS contact"
        }
    }

    var symbol: String {
        switch self {
        case .wentDark: return "antenna.radiowaves.left.and.right.slash"
        case .aisGap: return "questionmark.circle"
        case .positionJump: return "arrow.up.right.and.arrow.down.left"
        case .kinematic: return "waveform.path.ecg"
        case .rendezvous: return "arrow.triangle.merge"
        case .noAIS: return "dot.radiowaves.left.and.right"
        }
    }

    /// 3 = act now, 1 = worth a look.
    var severity: Int {
        switch self {
        case .wentDark, .rendezvous: return 3
        case .positionJump, .aisGap: return 2
        case .kinematic, .noAIS: return 1
        }
    }
}

struct Alert: Identifiable {
    let id = UUID()
    let kind: AlertKind
    let trackID: Int
    var otherTrackID: Int?
    let mmsi: Int?
    let name: String?
    let detectedAt: Date
    var resolvedAt: Date?
    let position: LatLon
    var detail: String
    var isOpen: Bool { resolvedAt == nil }
}

struct DetectorConfig {
    /// AIS silence must exceed max(floor, factor x the vessel's own cadence),
    /// the went_dark_thresholds() idea from Dark Track: a fixed threshold
    /// either misses slow-reporting vessels or false-alarms on them.
    var minAISSilenceS = 60.0
    var silenceIntervalFactor = 3.0
    var radarRecencyS = 30.0
    var radarSweepS = 10.0
    /// Share of sweeps since AIS stopped that must have put a plot on the
    /// track. A coasting track that grabs one stray plot minutes later
    /// (clutter, a passing vessel) is seduction, not corroboration -- that
    /// was every went-dark false alarm in the first simulation runs.
    var minRadarCorroboration = 0.5
    /// The AIS feed is a bounding box: a vessel leaving it goes quiet.
    var edgeMarginM = 2_000.0
    var gapSilenceS = 600.0
    var gapEdgeMarginM = 4_000.0
    var minMovingKnots = 1.0
    var kinematicSigma = 4.0
    var kinematicConsecutive = 2
    var jumpCooldownS = 900.0
    var rendezvousDistanceM = 500.0
    var rendezvousMaxKnots = 2.0
    var rendezvousMinDurationS = 300.0
    var noAISMinHits = 6
}

/// Stateful wrapper around the detector rules: holds open episodes so one
/// dropout is one alert (went_dark_episodes() in Dark Track), not one per
/// cycle.
final class AnomalyEngine {
    var config: DetectorConfig
    let region: Region
    private(set) var alerts: [Alert] = []
    private var open: [String: Int] = [:]               // episode key -> index into alerts
    private var darkSince: [Int: Date] = [:]            // trackID -> lastAISAt when episode opened
    private var streaks: [String: Int] = [:]            // "track/source" -> consecutive outliers
    private var kinematicNormalRun: [Int: Int] = [:]
    private var lastJumpAlert: [Int: Date] = [:]
    private var pairSince: [String: Date] = [:]
    private var pairLastSeen: [String: Date] = [:]
    private var pairAnchor: [String: (Double, Double)] = [:]

    init(region: Region, config: DetectorConfig = DetectorConfig()) {
        self.region = region
        self.config = config
    }

    func silenceThreshold(for t: Track) -> Double {
        max(config.minAISSilenceS, config.silenceIntervalFactor * (t.aisIntervalS ?? 10))
    }

    /// .wentDark or .aisGap while that episode is open, else nil.
    func darkKind(_ trackID: Int) -> AlertKind? {
        if open[key(.wentDark, trackID)] != nil { return .wentDark }
        if open[key(.aisGap, trackID)] != nil { return .aisGap }
        return nil
    }

    func hasOpenAlert(_ trackID: Int) -> Bool {
        open.values.contains { alerts[$0].trackID == trackID || alerts[$0].otherTrackID == trackID }
    }

    func isDark(_ trackID: Int) -> Bool {
        open["\(AlertKind.wentDark.rawValue)/\(trackID)"] != nil || open["\(AlertKind.aisGap.rawValue)/\(trackID)"] != nil
    }

    /// Run every rule for one cycle. Returns alerts opened this cycle.
    @discardableResult
    func step(engine: FusionEngine, events: [UpdateEvent], now: Date) -> [Alert] {
        let before = alerts.count
        let tracks = engine.tracks
        resolveVanished(tracks: tracks, now: now)
        wentDarkAndGaps(engine: engine, now: now)
        jumps(engine: engine, events: events)
        kinematic(engine: engine, events: events)
        rendezvous(engine: engine, now: now)
        noAIS(engine: engine, now: now)
        return Array(alerts[before...])
    }

    // MARK: Rules

    private func wentDarkAndGaps(engine: FusionEngine, now: Date) {
        for t in engine.tracks.values {
            guard t.aisHits > 0, let lastAIS = t.lastAISAt, let report = t.lastAIS else { continue }
            let darkKey = key(.wentDark, t.id), gapKey = key(.aisGap, t.id)

            // AIS came back: close whichever episode is open.
            if let since = darkSince[t.id], lastAIS > since {
                close(darkKey, at: lastAIS, note: "AIS resumed")
                close(gapKey, at: lastAIS, note: "AIS resumed")
                darkSince[t.id] = nil
                continue
            }
            // Anchored and moored vessels legitimately report every 3 min
            // and drift in and out of coverage -- the maritime version of
            // Dark Track ignoring ground traffic.
            if t.aisStationary { continue }

            let silence = now.timeIntervalSince(lastAIS)
            let radarFresh = t.lastRadarAt.map { now.timeIntervalSince($0) <= config.radarRecencyS } ?? false
            let sweeps = max(1, (silence / config.radarSweepS).rounded(.down))
            let corroborated = radarFresh && Double(t.radarHitsSinceAIS) >= config.minRadarCorroboration * sweeps
            if silence > silenceThreshold(for: t) && corroborated && open[darkKey] == nil
                && region.contains(report.position, marginM: config.edgeMarginM) {
                close(gapKey, at: now, note: "Radar re-acquired; upgraded to went dark")
                darkSince[t.id] = lastAIS
                openAlert(darkKey, Alert(kind: .wentDark, trackID: t.id, mmsi: t.mmsi, name: t.name,
                                         detectedAt: now, position: engine.latLon(of: t, at: now),
                                         detail: "AIS silent \(fmt(silence)) while radar still tracks it at \(Int(t.kf.speedKnots.rounded())) kn"))
            } else if silence > max(config.gapSilenceS, 10 * (t.aisIntervalS ?? 10)) && !radarFresh
                        && open[darkKey] == nil && open[gapKey] == nil {
                // No radar to confirm. Only flag it if the vessel wasn't
                // simply sailing out of the area: both its last AIS fix and
                // its dead-reckoned position must be well inside the region.
                let (vx, vy) = velocityXY(sogKnots: report.sogKnots ?? 0, cogDeg: report.cogDeg ?? 0)
                let (lx, ly) = engine.projection.toXY(report.position)
                let dr = engine.projection.toLatLon(x: lx + vx * silence, y: ly + vy * silence)
                guard region.contains(report.position, marginM: config.gapEdgeMarginM),
                      region.contains(dr, marginM: config.gapEdgeMarginM) else { continue }
                darkSince[t.id] = lastAIS
                openAlert(gapKey, Alert(kind: .aisGap, trackID: t.id, mmsi: t.mmsi, name: t.name,
                                        detectedAt: now, position: report.position,
                                        detail: "No AIS for \(fmt(silence)) mid-area and outside radar cover; last \(Int((report.sogKnots ?? 0).rounded())) kn"))
            }
        }
    }

    private func jumps(engine: FusionEngine, events: [UpdateEvent]) {
        for e in events {
            guard let j = e.jump, let t = engine.tracks[e.trackID] else { continue }
            if let last = lastJumpAlert[t.id], e.time.timeIntervalSince(last) < config.jumpCooldownS { continue }
            lastJumpAlert[t.id] = e.time
            var a = Alert(kind: .positionJump, trackID: t.id, mmsi: t.mmsi, name: t.name, detectedAt: e.time,
                          position: t.lastAIS?.position ?? engine.latLon(of: t, at: e.time),
                          detail: String(format: "Reported position moved %.1f km at an implied %.0f kn -- possible spoofing",
                                         j.distanceM / 1000, j.impliedKnots))
            a.resolvedAt = e.time
            alerts.append(a)
        }
    }

    /// Port of kinematic_inconsistency(): residual beyond kinematicSigma of
    /// the filter's own innovation std for N updates in a row from one source.
    private func kinematic(engine: FusionEngine, events: [UpdateEvent]) {
        for e in events where e.jump == nil {
            guard let t = engine.tracks[e.trackID], t.confirmed, t.updates > 5, e.innovationStdM > 0 else { continue }
            let sKey = "\(e.trackID)/\(e.source.rawValue)"
            let aKey = key(.kinematic, e.trackID)
            let normalized = e.residualM / e.innovationStdM
            if normalized > config.kinematicSigma {
                streaks[sKey, default: 0] += 1
                if open[aKey] != nil {
                    kinematicNormalRun[e.trackID] = 0
                } else if streaks[sKey]! >= config.kinematicConsecutive {
                    kinematicNormalRun[e.trackID] = 0
                    openAlert(aKey, Alert(kind: .kinematic, trackID: t.id, mmsi: t.mmsi, name: t.name,
                                          detectedAt: e.time, position: engine.latLon(of: t, at: e.time),
                                          detail: String(format: "%@ residual %.1f\u{03C3} -- manoeuvre the motion model can't explain",
                                                         e.source == .ais ? "AIS" : "Radar", normalized)))
                }
            } else {
                streaks[sKey] = 0
                if open[aKey] != nil {
                    kinematicNormalRun[e.trackID, default: 0] += 1
                    if kinematicNormalRun[e.trackID]! >= config.kinematicConsecutive {
                        close(aKey, at: e.time, note: nil)
                        kinematicNormalRun[e.trackID] = nil
                    }
                }
            }
        }
    }

    /// Ship-to-ship transfers at sea are the classic reason to go dark: two
    /// tracks held alongside each other, at least one dark or with no AIS.
    ///
    /// "Stopped" is judged from how far the pair's midpoint moved over the
    /// whole window, not from each filter's instantaneous speed: two hulls
    /// 150 m apart swap radar plots, which made the filter speeds jitter
    /// between 2 and 8 kn while both vessels were doing under 1 (15 scripted
    /// rendezvous in simulation, 1 caught).
    private func rendezvous(engine: FusionEngine, now: Date) {
        let live = engine.tracks.values.filter {
            $0.confirmed && now.timeIntervalSince($0.lastUpdate) < 120
        }.sorted { $0.id < $1.id }
        let maxDriftM = config.rendezvousMaxKnots * Units.mpsPerKnot * config.rendezvousMinDurationS
        var seen = Set<String>()
        for (i, a) in live.enumerated() {
            for b in live[(i + 1)...] {
                guard a.isRadarOnly || b.isRadarOnly || isDark(a.id) || isDark(b.id) else { continue }
                let pa = a.predictedXY(at: now), pb = b.predictedXY(at: now)
                let gap = hypot2(pa, pb)
                guard gap < config.rendezvousDistanceM else { continue }
                let pk = "\(a.id)-\(b.id)"
                seen.insert(pk)
                pairLastSeen[pk] = now
                let mid = ((pa.0 + pb.0) / 2, (pa.1 + pb.1) / 2)
                if let anchor = pairAnchor[pk], hypot2(mid, anchor) <= maxDriftM {
                    // still holding station
                } else {
                    pairAnchor[pk] = mid
                    pairSince[pk] = now
                }
                let since = pairSince[pk] ?? now
                let held = now.timeIntervalSince(since)
                let aKey = "\(AlertKind.rendezvous.rawValue)/\(pk)"
                if open[aKey] == nil && held >= config.rendezvousMinDurationS {
                    // Name the alert after the identified vessel when there is one.
                    let named = [a, b].first { !$0.isRadarOnly } ?? a
                    let other = named.id == a.id ? b : a
                    let drift = hypot2(mid, pairAnchor[pk] ?? mid) / held / Units.mpsPerKnot
                    var al = Alert(kind: .rendezvous, trackID: named.id, mmsi: named.mmsi, name: named.name,
                                   detectedAt: now, position: engine.latLon(of: named, at: now),
                                   detail: String(format: "Held within %d m of %@ for %@, drifting %.1f kn",
                                                  Int(gap), other.isRadarOnly ? "a radar-only contact" : (other.name ?? "MMSI \(other.mmsi ?? 0)"),
                                                  fmt(held), drift))
                    al.otherTrackID = other.id
                    openAlert(aKey, al)
                }
            }
        }
        for (pk, last) in pairLastSeen where !seen.contains(pk) && now.timeIntervalSince(last) > 120 {
            close("\(AlertKind.rendezvous.rawValue)/\(pk)", at: last, note: "Vessels separated")
            pairSince[pk] = nil
            pairAnchor[pk] = nil
            pairLastSeen[pk] = nil
        }
    }

    private func noAIS(engine: FusionEngine, now: Date) {
        for t in engine.tracks.values where t.isRadarOnly && t.confirmed && t.radarHits >= config.noAISMinHits {
            let k = key(.noAIS, t.id)
            guard open[k] == nil, !alerts.contains(where: { $0.kind == .noAIS && $0.trackID == t.id }) else { continue }
            openAlert(k, Alert(kind: .noAIS, trackID: t.id, mmsi: nil, name: nil, detectedAt: now,
                               position: engine.latLon(of: t, at: now),
                               detail: "Radar contact at \(Int(t.kf.speedKnots.rounded())) kn with no AIS identity"))
        }
        // An AIS identity arriving for the contact resolves it.
        for (k, idx) in open where alerts[idx].kind == .noAIS {
            if let t = engine.tracks[alerts[idx].trackID], !t.isRadarOnly {
                close(k, at: now, note: "AIS identified as \(t.name ?? "MMSI \(t.mmsi ?? 0)")")
            }
        }
    }

    private func resolveVanished(tracks: [Int: Track], now: Date) {
        for (k, idx) in open {
            let a = alerts[idx]
            let gone = tracks[a.trackID] == nil || (a.otherTrackID.map { tracks[$0] == nil } ?? false)
            if gone {
                close(k, at: now, note: "Track lost")
                darkSince[a.trackID] = nil
            }
        }
    }

    // MARK: Episode bookkeeping

    private func key(_ k: AlertKind, _ id: Int) -> String { "\(k.rawValue)/\(id)" }

    private func openAlert(_ k: String, _ a: Alert) {
        alerts.append(a)
        open[k] = alerts.count - 1
    }

    private func close(_ k: String, at t: Date, note: String?) {
        guard let idx = open[k] else { return }
        alerts[idx].resolvedAt = t
        if let note { alerts[idx].detail += " \u{2014} \(note)" }
        open[k] = nil
    }
}

func fmt(_ s: Double) -> String {
    let s = Int(s.rounded())
    return s < 120 ? "\(s) s" : "\(s / 60) min"
}
