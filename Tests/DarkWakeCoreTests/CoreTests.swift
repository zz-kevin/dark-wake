import XCTest
@testable import DarkWakeCore

final class MathTests: XCTestCase {
    func testInverse() {
        let m = Mat(3, 3, [4, 7, 2, 3, 6, 1, 2, 5, 3])
        let i = m * m.inverse()!
        for r in 0..<3 { for c in 0..<3 { XCTAssertEqual(i[r, c], r == c ? 1 : 0, accuracy: 1e-9) } }
    }

    func testHungarianPicksGlobalOptimumNotGreedy() {
        // Greedy takes (0,0)=1 then is stuck with (1,1)=100: total 101.
        // Optimal is (0,1)+(1,0) = 2+2.
        let a = hungarian([[1, 2], [2, 100]])
        XCTAssertEqual(a, [1, 0])
    }

    func testHungarianRectangular() {
        XCTAssertEqual(hungarian([[5, 1, 9]]), [1])
        XCTAssertEqual(hungarian([[3], [1], [2]]), [nil, 0, nil])
    }

    func testKalmanLearnsVelocity() {
        var exact = KalmanFilter(x0: 0, y0: 0, accelStd: 0.05, initPosVar: 2_500)
        var noisy = exact
        var rng = SplitMix64(seed: 1)
        for k in 1...60 {
            exact.predict(10)
            exact.update(z: (Double(k) * 50, 0), rStd: 30)
            noisy.predict(10)
            noisy.update(z: (Double(k) * 50 + rng.gaussian(30), rng.gaussian(30)), rStd: 30)
        }
        XCTAssertEqual(exact.velocity.0, 5, accuracy: 0.01)
        XCTAssertEqual(exact.velocity.1, 0, accuracy: 0.01)
        // 30 m plots every 10 s: about a knot of velocity noise is expected.
        XCTAssertEqual(noisy.velocity.0, 5, accuracy: 0.6)
        XCTAssertEqual(noisy.velocity.1, 0, accuracy: 0.6)
    }
}

final class RadarTests: XCTestCase {
    func testHorizonHidesSmallBoatsSoonerThanShips() {
        let radar = CoastalRadar(site: LatLon(lat: 51, lon: 1))
        XCTAssertGreaterThan(radar.coverageM(targetHeightM: 20), radar.coverageM(targetHeightM: 3))
        let far = LocalProjection(origin: radar.site).toLatLon(x: 0, y: 44_000)
        XCTAssertTrue(radar.canSee(far, targetHeightM: 20))
        XCTAssertFalse(radar.canSee(far, targetHeightM: 3))
    }

    func testPlotsHaveNoIdentityLeakIntoFusion() {
        var rng = SplitMix64(seed: 3)
        var radar = CoastalRadar(site: LatLon(lat: 51, lon: 1))
        radar.clutterPerSweep = 0
        let target = CoastalRadar.Target(id: "x", position: LatLon(lat: 51.1, lon: 1), heightM: 20)
        var errs: [Double] = []
        for _ in 0..<500 {
            for c in radar.sweep([target], at: Date(), rng: &rng) {
                let (x, y) = LocalProjection(origin: target.position).toXY(c.position)
                errs.append(hypot(x, y))
            }
        }
        XCTAssertGreaterThan(errs.count, 400)               // Pd ~0.9 at 11 km
        let rms = (errs.map { $0 * $0 }.reduce(0, +) / Double(errs.count)).squareRoot()
        XCTAssertLessThan(rms, 120)                          // ~25 m range + 68 m cross-range
    }
}

/// Hand-built scenarios: one vessel, controlled AIS, radar from truth.
final class DetectorTests: XCTestCase {
    let region = Region.presets[0]

    /// Runs a straight-line vessel for `minutes`, dropping AIS from `darkAt`.
    func run(sog: Double, navStatus: Int, darkAt: Double?, minutes: Double = 20,
             aisJumpAt: Double? = nil) -> [Alert] {
        var radar = CoastalRadar(site: region.radarSite)
        radar.clutterPerSweep = 0
        let p = Pipeline(region: region, radar: radar)
        let proj = LocalProjection(origin: region.center)
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        var alerts: [Alert] = []
        var t = 0.0
        while t < minutes * 60 {
            t += 10
            let (vx, vy) = velocityXY(sogKnots: sog, cogDeg: 90)
            var pos = proj.toLatLon(x: vx * t, y: vy * t)
            let now = t0.addingTimeInterval(t)
            let target = CoastalRadar.Target(id: "v", position: pos, heightM: 20)
            if let j = aisJumpAt, abs(t - j * 60) < 5 { pos = proj.toLatLon(x: vx * t, y: vy * t + 30_000) }
            let ais: [AISReport] = (darkAt.map { t < $0 * 60 } ?? true)
                ? [AISReport(mmsi: 235_000_001, name: "TEST", kind: .cargo, position: pos, sogKnots: sog,
                             cogDeg: 90, navStatus: navStatus, time: now)]
                : []
            alerts += p.cycle(ais: ais, radarTargets: [target], now: now)
        }
        return alerts
    }

    func testWentDarkFiresWithinSilencePlusOneSweep() {
        let alerts = run(sog: 12, navStatus: NavStatus.underWay, darkAt: 5)
        let dark = alerts.filter { $0.kind == .wentDark }
        XCTAssertEqual(dark.count, 1, "one dropout, one alert")
        let latency = dark[0].detectedAt.timeIntervalSince(Date(timeIntervalSince1970: 1_800_000_000 + 300))
        XCTAssertLessThanOrEqual(latency, 60 + 10 + 10)
    }

    func testNoAlertWhileAISFlows() {
        XCTAssertTrue(run(sog: 12, navStatus: NavStatus.underWay, darkAt: nil)
            .filter { $0.kind == .wentDark || $0.kind == .kinematic }.isEmpty)
    }

    func testAnchoredVesselGoingQuietIsIgnored() {
        XCTAssertTrue(run(sog: 0, navStatus: NavStatus.atAnchor, darkAt: 5).filter { $0.kind == .wentDark }.isEmpty)
    }

    func testPositionJumpFlaggedOnce() {
        let jumps = run(sog: 12, navStatus: NavStatus.underWay, darkAt: nil, aisJumpAt: 8).filter { $0.kind == .positionJump }
        XCTAssertEqual(jumps.count, 1, "jump out and back is one alert")
    }
}

/// End-to-end over the simulator's scripted bad actors, scored against its
/// ground truth. Prints the numbers the README quotes.
final class ScenarioTests: XCTestCase {
    func testThreeHoursAcrossRegions() {
        var total = Scorecard()
        for (i, region) in Region.presets.enumerated() {
            let run = SimulationRun(region: region, start: Date(timeIntervalSince1970: 1_800_000_000), seed: UInt64(100 + i))
            for _ in 0..<(3 * 360) { run.step() }
            let s = run.scorecard()
            print(String(format: "%@: scored %d, radar-visible %d, went-dark %d/%d (+%d at edge), any %d/%d, rendezvous %d/%d, jumps %d/%d, false alarms %d (%d/%d vessels), median latency %.0f s",
                         region.name, s.scored, s.radarVisible, s.confirmedDetected, s.radarVisible, s.edgeExcluded, s.anyDetected, s.scored,
                         s.rendezvousDetected, s.rendezvousScored, s.jumpsDetected, s.jumpsInjected,
                         s.falseAlarms, s.falseAlarmVessels, s.aisVessels, s.medianLatencyS ?? -1))
            total.radarVisible += s.radarVisible
            total.confirmedDetected += s.confirmedDetected
            total.rendezvousScored += s.rendezvousScored
            total.rendezvousDetected += s.rendezvousDetected
            total.jumpsInjected += s.jumpsInjected
            total.jumpsDetected += s.jumpsDetected
            total.falseAlarmVessels += s.falseAlarmVessels
            total.aisVessels += s.aisVessels
        }
        XCTAssertGreaterThanOrEqual(total.confirmedRecall ?? 0, 0.85)
        XCTAssertLessThan(total.falseAlarmRate, 0.05)
        XCTAssertEqual(total.jumpsDetected, total.jumpsInjected)
        XCTAssertGreaterThanOrEqual(total.rendezvousDetected, total.rendezvousScored - 1)
    }
}
