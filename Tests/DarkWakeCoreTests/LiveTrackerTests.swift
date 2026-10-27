import XCTest
@testable import DarkWakeCore

/// Live mode replayed: a real-looking AIS feed (irregular, with pauses)
/// through LiveTracker, ticked every 2 s like the app.
///
/// Reproduces the first live run on a real iPad (New York, 2026-10-23):
/// harbour craft with ordinary 60-120 s AIS pauses were flagged "went
/// dark", and two injected dropouts in Upper New York Bay were not flagged.
final class LiveTrackerTests: XCTestCase {
    let ny = Region.presets.first { $0.id == "nyc" }!
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    struct Vessel {
        var mmsi: Int
        var start: LatLon
        var sog: Double
        var cog: Double
        var interval: Double
        /// (from, to) seconds with no AIS transmitted at all.
        var pauses: [(Double, Double)] = []
    }

    /// Runs `seconds` of feed. `inject`: (mmsi, at seconds).
    func replay(_ vessels: [Vessel], seconds: Double, inject: [(Int, Double)] = []) -> LiveTracker {
        let live = LiveTracker(region: ny)
        var nextReport = vessels.map { _ in 0.0 }
        var pending = inject
        var t = 0.0
        while t <= seconds {
            for (i, v) in vessels.enumerated() where t >= nextReport[i] {
                nextReport[i] += v.interval
                if v.pauses.contains(where: { t >= $0.0 && t < $0.1 }) { continue }
                let proj = LocalProjection(origin: v.start)
                let (vx, vy) = velocityXY(sogKnots: v.sog, cogDeg: v.cog)
                live.receive(AISReport(mmsi: v.mmsi, name: "V\(v.mmsi)", kind: .tug,
                                       position: proj.toLatLon(x: vx * t, y: vy * t),
                                       sogKnots: v.sog, cogDeg: v.cog, navStatus: NavStatus.underWay,
                                       time: t0.addingTimeInterval(t)))
            }
            for (k, (m, at)) in pending.enumerated().reversed() where t >= at {
                XCTAssertTrue(live.inject(mmsi: m, now: t0.addingTimeInterval(t)))
                pending.remove(at: k)
            }
            live.tick(now: t0.addingTimeInterval(t))
            t += 2
        }
        return live
    }

    // Lower Bay, well inside radar cover and the area.
    let lowerBay = LatLon(lat: 40.52, lon: -74.02)
    // Upper New York Bay off Robbins Reef, where the iPad test was.
    let upperBay = LatLon(lat: 40.672, lon: -74.045)

    func testOrdinaryAISPausesAreNotWentDark() {
        let vessels = [65.0, 80, 100, 120, 150].enumerated().map { i, pause in
            Vessel(mmsi: 366_000_100 + i, start: LatLon(lat: lowerBay.lat + Double(i) * 0.01, lon: lowerBay.lon),
                   sog: 8, cog: 30, interval: 10, pauses: [(300, 300 + pause)])
        }
        let live = replay(vessels, seconds: 900)
        let dark = live.pipeline.anomalies.alerts.filter { $0.kind == .wentDark }
        XCTAssertEqual(dark.count, 0, "false alarms: \(dark.map(\.detail))")
    }

    func testInjectedDropoutInUpperBayIsFlagged() {
        let v = Vessel(mmsi: 368_253_890, start: upperBay, sog: 6, cog: 200, interval: 10)
        let live = replay([v], seconds: 600, inject: [(v.mmsi, 180)])
        let s = live.scorecard(now: t0.addingTimeInterval(600))
        XCTAssertEqual(s.confirmedDetected, 1, "alerts: \(live.pipeline.anomalies.alerts.map { "\($0.kind) \($0.detail)" })")
        if let m = s.medianLatencyS { XCTAssertLessThanOrEqual(m, 90) }
    }

    /// The first live re-test showed an empty scorecard for the first 150 s
    /// after injecting; it should say a dropout is in progress instead.
    func testInjectionInProgressIsReportedAsPending() {
        let v = Vessel(mmsi: 368_253_891, start: lowerBay, sog: 8, cog: 30, interval: 10)
        let live = replay([v], seconds: 240, inject: [(v.mmsi, 180)])
        let s = live.scorecard(now: t0.addingTimeInterval(240))
        XCTAssertEqual(s.scored, 0)
        XCTAssertEqual(s.pending, 1)
    }

    /// Second live recording (Dover Strait, late night): the feed was so
    /// sparse that an injected ship's real reports came every minute or two,
    /// so the AIS-derived radar barely saw it and the detector rightly held
    /// off. That says nothing about detection, so it isn't scored as a miss.
    func testInjectionRadarCouldNotSeeIsNotScoredAsMiss() {
        // Reports every 150 s: the radar's 60 s view of an injected ship
        // covers 40% of sweeps, under the detector's half-the-sweeps bar.
        let v = Vessel(mmsi: 257_711_000, start: lowerBay, sog: 8.6, cog: 62, interval: 150)
        let live = replay([v], seconds: 600, inject: [(v.mmsi, 200)])
        let s = live.scorecard(now: t0.addingTimeInterval(600))
        XCTAssertEqual(s.radarUnobservable, 1)
        XCTAssertEqual(s.scored, 0)
        XCTAssertEqual(s.radarVisible, 0)
        XCTAssertNil(s.confirmedRecall)
    }

    /// Reports every 90 s still leave the radar data on two sweeps in three,
    /// so that injection must be scored -- and caught.
    func testSparseButFollowableInjectionIsStillScored() {
        let v = Vessel(mmsi: 257_711_001, start: lowerBay, sog: 8.6, cog: 62, interval: 90)
        let live = replay([v], seconds: 600, inject: [(v.mmsi, 200)])
        let s = live.scorecard(now: t0.addingTimeInterval(600))
        XCTAssertEqual(s.radarUnobservable, 0)
        XCTAssertEqual(s.confirmedDetected, 1)
    }

    func testInjectedDropoutOnClassBVesselIsFlagged() {
        // Class B under way: a report every 30 s.
        let v = Vessel(mmsi: 338_000_001, start: lowerBay, sog: 7, cog: 120, interval: 30)
        let live = replay([v], seconds: 900, inject: [(v.mmsi, 300)])
        XCTAssertEqual(live.scorecard(now: t0.addingTimeInterval(900)).confirmedDetected, 1,
                       "alerts: \(live.pipeline.anomalies.alerts.map { "\($0.kind) \($0.detail)" })")
    }
}
