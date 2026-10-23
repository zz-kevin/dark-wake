import Foundation

/// Ground truth for one period of a vessel's AIS being off.
struct DarkTruth: Identifiable {
    let id = UUID()
    let mmsi: Int
    let name: String
    let start: Date
    var end: Date?
    let radarVisibleAtStart: Bool
    /// Started inside the area's edge band, where went-dark is suppressed
    /// by design (DetectorConfig.edgeMarginM), so it isn't scored as a miss.
    var atEdgeAtStart = false
    let reason: Reason

    enum Reason: String { case evasive, rendezvous, injected }
}

struct JumpTruth {
    let mmsi: Int
    let time: Date
}

/// Self-contained maritime traffic generator. Plays the part of both the
/// real world (where every vessel actually is) and its AIS transmitters,
/// with scripted bad actors and a record of exactly what they did, so the
/// detectors can be scored the way Dark Track's anomaly/harness.py scores
/// injected events. It knows nothing about land.
final class VesselSimulator {
    enum Behavior {
        case transit(laneCourse: Double)
        case fishing(home: (Double, Double))
        case anchored
        case goFast
        case mothership(home: (Double, Double))
    }

    enum Rendezvous {
        case approach
        case alongside(until: Date)
        case depart(until: Date)
    }

    final class Vessel {
        let id: String
        let mmsi: Int?
        let name: String
        let kind: VesselKind
        var behavior: Behavior
        var x: Double, y: Double
        var speedKn: Double, courseDeg: Double
        var targetSpeedKn: Double, targetCourseDeg: Double
        var aisIntervalS: Double
        var nextAIS: Date
        var navStatus: Int
        var aisOn = true
        var darkUntil: Date?
        var truthIndex: Int?
        var rendezvous: Rendezvous?
        var spoofNext = false
        var nextDecision: Date

        init(id: String, mmsi: Int?, name: String, kind: VesselKind, behavior: Behavior,
             x: Double, y: Double, speedKn: Double, courseDeg: Double, aisIntervalS: Double,
             navStatus: Int, now: Date) {
            self.id = id; self.mmsi = mmsi; self.name = name; self.kind = kind; self.behavior = behavior
            self.x = x; self.y = y; self.speedKn = speedKn; self.courseDeg = courseDeg
            targetSpeedKn = speedKn; targetCourseDeg = courseDeg
            self.aisIntervalS = aisIntervalS; self.navStatus = navStatus
            nextAIS = now; nextDecision = now
        }

        var isSmall: Bool { kind.radarHeightM < 8 }
        var busy: Bool { !aisOn || rendezvous != nil || spoofNext }
    }

    let region: Region
    let radar: CoastalRadar
    let projection: LocalProjection
    private(set) var now: Date
    private(set) var vessels: [Vessel] = []
    private(set) var truth: [DarkTruth] = []
    private(set) var jumps: [JumpTruth] = []
    private(set) var mmsisSeen = Set<Int>()
    private var rng: SplitMix64
    private var nextVesselID = 1
    private var nextDarkEvent: Date
    private var nextRendezvous: Date
    private var nextSpoof: Date
    private var goFastRespawn: Date?
    private let halfX: Double, halfY: Double

    var transitCount = 16, fishingCount = 6, anchoredCount = 3

    init(region: Region, radar: CoastalRadar, start: Date, seed: UInt64 = 7) {
        self.region = region
        self.radar = radar
        projection = LocalProjection(origin: region.center)
        now = start
        rng = SplitMix64(seed: seed)
        halfY = region.halfSpanLatDeg * 111_320
        halfX = region.halfSpanLonDeg * 111_320 * cos(region.center.lat * .pi / 180)
        nextDarkEvent = start.addingTimeInterval(240)
        nextRendezvous = start.addingTimeInterval(600)
        nextSpoof = start.addingTimeInterval(900)
        populate()
    }

    // MARK: Spawning

    private func populate() {
        for _ in 0..<transitCount { spawnTransit(anywhere: true) }
        for _ in 0..<fishingCount {
            let home = randomPoint(within: 0.55)
            let v = makeVessel(mmsi: true, kind: .fishing, behavior: .fishing(home: home), at: home,
                               speed: rng.uniform(2, 6), course: rng.uniform(0, 360), interval: 30, status: NavStatus.fishing)
            vessels.append(v)
        }
        for _ in 0..<anchoredCount {
            let p = randomPoint(within: 0.4)
            vessels.append(makeVessel(mmsi: true, kind: rng.chance(0.5) ? .cargo : .tanker, behavior: .anchored, at: p,
                                      speed: 0, course: rng.uniform(0, 360), interval: 180, status: NavStatus.atAnchor))
        }
        // The mothership sits inside radar cover, between the radar and the
        // middle of the area, and never transmits.
        let (rx, ry) = projection.toXY(radar.site)
        let home = (rx * 0.35, ry * 0.35 - 6_000)
        vessels.append(makeVessel(mmsi: false, kind: .tanker, behavior: .mothership(home: home), at: home,
                                  speed: 0.6, course: rng.uniform(0, 360), interval: 0, status: NavStatus.undefined))
        spawnGoFast()
    }

    private func spawnTransit(anywhere: Bool) {
        let northbound = rng.chance(0.5)
        let lane = region.laneBearingDeg + (northbound ? 0 : 180)
        let r = lane * .pi / 180
        let reach = min(halfX, halfY) * 0.95
        let along = anywhere ? rng.uniform(-reach, reach) : -reach
        let offset = (northbound ? 1.0 : -1.0) * 2_000 + rng.gaussian(500)
        // Along-lane unit vector (sin, cos); starboard perpendicular (cos, -sin).
        let p = (along * sin(r) + offset * cos(r), along * cos(r) - offset * sin(r))
        let kinds: [VesselKind] = [.cargo, .cargo, .tanker, .passenger]
        let v = makeVessel(mmsi: true, kind: kinds[Int(rng.uniform(0, Double(kinds.count)))],
                           behavior: .transit(laneCourse: lane), at: p,
                           speed: rng.uniform(10, 18), course: lane, interval: 10, status: NavStatus.underWay)
        vessels.append(v)
    }

    private func spawnGoFast() {
        let a = rng.uniform(0, 2 * .pi)
        let start = (cos(a) * halfX, sin(a) * halfY)
        let aim = randomPoint(within: 0.3)
        let course = courseDeg(vx: aim.0 - start.0, vy: aim.1 - start.1)
        vessels.append(makeVessel(mmsi: false, kind: .highSpeed, behavior: .goFast, at: start,
                                  speed: rng.uniform(28, 35), course: course, interval: 0, status: NavStatus.undefined))
    }

    private func makeVessel(mmsi: Bool, kind: VesselKind, behavior: Behavior, at p: (Double, Double),
                            speed: Double, course: Double, interval: Double, status: Int) -> Vessel {
        let id = "V\(nextVesselID)"
        nextVesselID += 1
        let m: Int? = mmsi ? Int(rng.uniform(201_000_000, 576_999_999)) : nil
        if let m { mmsisSeen.insert(m) }
        let v = Vessel(id: id, mmsi: m, name: mmsi ? randomName(kind) : "", kind: kind, behavior: behavior,
                       x: p.0, y: p.1, speedKn: speed, courseDeg: course, aisIntervalS: interval,
                       navStatus: status, now: now)
        v.nextAIS = now.addingTimeInterval(rng.uniform(0, max(interval, 1)))
        v.nextDecision = now.addingTimeInterval(rng.uniform(60, 300))
        return v
    }

    private func randomPoint(within frac: Double) -> (Double, Double) {
        (rng.uniform(-halfX, halfX) * frac, rng.uniform(-halfY, halfY) * frac)
    }

    private func randomName(_ kind: VesselKind) -> String {
        let first = ["NORDIC", "ATLANTIC", "PACIFIC", "OCEAN", "SEA", "CAPE", "STAR", "BLUE", "IRON", "GOLDEN",
                     "NORTHERN", "SILVER", "CORAL", "POLAR", "AMBER", "MISTRAL"]
        let second = kind == .fishing
            ? ["HARVEST", "TRAWLER", "GULL", "PROVIDER", "LADY", "DAWN", "TIDE", "MARLIN"]
            : ["SPIRIT", "PIONEER", "VOYAGER", "TRADER", "CARRIER", "HORIZON", "EXPRESS", "GLORY", "ENDEAVOUR"]
        return "\(first[Int(rng.uniform(0, Double(first.count)))]) \(second[Int(rng.uniform(0, Double(second.count)))])"
    }

    // MARK: Stepping

    /// Moves the world forward to `t` and returns the AIS reports transmitted
    /// along the way.
    func advance(to t: Date) -> [AISReport] {
        var out: [AISReport] = []
        let step = 2.0
        while now < t {
            let dt = min(step, t.timeIntervalSince(now))
            now = now.addingTimeInterval(dt)
            scheduleEvents()
            for v in vessels {
                steer(v)
                move(v, dt: dt)
                if let r = transmit(v) { out.append(r) }
            }
            despawnLeavers()
        }
        return out
    }

    func radarTargets() -> [CoastalRadar.Target] {
        vessels.map { .init(id: $0.id, position: projection.toLatLon(x: $0.x, y: $0.y), heightM: $0.kind.radarHeightM) }
    }

    func position(of v: Vessel) -> LatLon { projection.toLatLon(x: v.x, y: v.y) }

    /// Manually switch off one vessel's AIS -- the "inject" button.
    @discardableResult
    func forceDark(mmsi: Int, duration: TimeInterval = 480) -> Bool {
        guard let v = vessels.first(where: { $0.mmsi == mmsi && !$0.busy }) else { return false }
        goDark(v, for: duration, reason: .injected)
        return true
    }

    private func scheduleEvents() {
        if now >= nextDarkEvent {
            nextDarkEvent = now.addingTimeInterval(rng.uniform(360, 720))
            let pool = vessels.filter {
                guard $0.mmsi != nil, !$0.busy else { return false }
                if case .anchored = $0.behavior { return false }
                return true
            }
            if !pool.isEmpty {
                let v = pool[Int(rng.uniform(0, Double(pool.count)))]
                goDark(v, for: rng.uniform(360, 840), reason: .evasive)
                if rng.chance(0.5) { v.targetCourseDeg = (v.courseDeg + (rng.chance(0.5) ? 1 : -1) * rng.uniform(30, 60) + 360).truncatingRemainder(dividingBy: 360) }
            }
        }
        if now >= nextRendezvous {
            nextRendezvous = now.addingTimeInterval(rng.uniform(2_400, 3_000))
            let ship = vessels.first { if case .mothership = $0.behavior { return true }; return false }
            let pool = vessels.filter {
                if case .fishing = $0.behavior { return !$0.busy }
                return false
            }.sorted { a, b in
                guard let s = ship else { return false }
                return hypot(a.x - s.x, a.y - s.y) < hypot(b.x - s.x, b.y - s.y)
            }
            let anyRunning = vessels.contains { $0.rendezvous != nil }
            if !anyRunning, let v = pool.first {
                goDark(v, for: nil, reason: .rendezvous)
                v.rendezvous = .approach
            }
        }
        if now >= nextSpoof {
            nextSpoof = now.addingTimeInterval(rng.uniform(1_500, 2_100))
            let pool = vessels.filter {
                if case .transit = $0.behavior { return !$0.busy }
                return false
            }
            if !pool.isEmpty { pool[Int(rng.uniform(0, Double(pool.count)))].spoofNext = true }
        }
        if let at = goFastRespawn, now >= at {
            goFastRespawn = nil
            spawnGoFast()
        }
    }

    private func goDark(_ v: Vessel, for duration: TimeInterval?, reason: DarkTruth.Reason) {
        guard let m = v.mmsi else { return }
        v.aisOn = false
        v.darkUntil = duration.map { now.addingTimeInterval($0) }
        truth.append(DarkTruth(mmsi: m, name: v.name, start: now, end: nil,
                               radarVisibleAtStart: radar.canSee(position(of: v), targetHeightM: v.kind.radarHeightM),
                               atEdgeAtStart: !region.contains(position(of: v), marginM: DetectorConfig().edgeMarginM),
                               reason: reason))
        v.truthIndex = truth.count - 1
    }

    private func comeBack(_ v: Vessel) {
        v.aisOn = true
        v.darkUntil = nil
        if let i = v.truthIndex { truth[i].end = now }
        v.truthIndex = nil
        if case .transit(let lane) = v.behavior { v.targetCourseDeg = lane }
        v.nextAIS = now
    }

    private func steer(_ v: Vessel) {
        if let until = v.darkUntil, now >= until { comeBack(v) }

        if let phase = v.rendezvous, let ship = vessels.first(where: { if case .mothership = $0.behavior { return true }; return false }) {
            let d = hypot(ship.x - v.x, ship.y - v.y)
            switch phase {
            case .approach:
                v.targetCourseDeg = courseDeg(vx: ship.x - v.x, vy: ship.y - v.y)
                v.targetSpeedKn = 10
                if d < 250 { v.rendezvous = .alongside(until: now.addingTimeInterval(720)) }
            case .alongside(let until):
                v.targetCourseDeg = courseDeg(vx: ship.x - v.x, vy: ship.y - v.y)
                v.targetSpeedKn = d > 150 ? 1.5 : ship.speedKn
                if d <= 150 { v.targetCourseDeg = ship.courseDeg }
                if now >= until { v.rendezvous = .depart(until: now.addingTimeInterval(360)) }
            case .depart(let until):
                if case .fishing(let home) = v.behavior {
                    v.targetCourseDeg = courseDeg(vx: home.0 - v.x, vy: home.1 - v.y)
                }
                v.targetSpeedKn = 8
                if now >= until { v.rendezvous = nil; comeBack(v) }
            }
            return
        }

        switch v.behavior {
        case .fishing(let home), .mothership(let home):
            let isShip: Bool = { if case .mothership = v.behavior { return true }; return false }()
            let leash = isShip ? 800.0 : 6_000.0
            if hypot(home.0 - v.x, home.1 - v.y) > leash {
                v.targetCourseDeg = courseDeg(vx: home.0 - v.x, vy: home.1 - v.y)
            } else if now >= v.nextDecision {
                v.targetCourseDeg = rng.uniform(0, 360)
                v.targetSpeedKn = isShip ? rng.uniform(0.3, 1.0) : rng.uniform(2, 6)
                v.nextDecision = now.addingTimeInterval(rng.uniform(180, 480))
            }
        case .transit, .anchored, .goFast:
            break
        }
    }

    private func move(_ v: Vessel, dt: Double) {
        let turnRate = v.isSmall ? 4.0 : 0.6
        var diff = (v.targetCourseDeg - v.courseDeg).truncatingRemainder(dividingBy: 360)
        if diff > 180 { diff -= 360 }
        if diff < -180 { diff += 360 }
        v.courseDeg += max(-turnRate * dt, min(turnRate * dt, diff))
        v.courseDeg = (v.courseDeg + 360).truncatingRemainder(dividingBy: 360)
        let accelKn = (v.isSmall ? 0.4 : 0.05) / Units.mpsPerKnot * dt
        v.speedKn += max(-accelKn, min(accelKn, v.targetSpeedKn - v.speedKn))
        let (vx, vy) = velocityXY(sogKnots: v.speedKn, cogDeg: v.courseDeg)
        v.x += vx * dt
        v.y += vy * dt
    }

    private func transmit(_ v: Vessel) -> AISReport? {
        guard let m = v.mmsi, now >= v.nextAIS else { return nil }
        v.nextAIS = v.nextAIS.addingTimeInterval(v.aisIntervalS * rng.uniform(0.9, 1.1))
        if v.nextAIS < now { v.nextAIS = now.addingTimeInterval(v.aisIntervalS) }
        guard v.aisOn else { return nil }
        var x = v.x + rng.gaussian(5), y = v.y + rng.gaussian(5)
        if v.spoofNext {
            v.spoofNext = false
            let a = rng.uniform(0, 2 * .pi)
            x += 25_000 * cos(a)
            y += 25_000 * sin(a)
            jumps.append(JumpTruth(mmsi: m, time: now))
        }
        let moving = v.speedKn > 0.3
        return AISReport(mmsi: m, name: v.name, kind: v.kind, position: projection.toLatLon(x: x, y: y),
                         sogKnots: max(0, v.speedKn + rng.gaussian(0.1)),
                         cogDeg: moving ? (v.courseDeg + rng.gaussian(1) + 360).truncatingRemainder(dividingBy: 360) : 0,
                         navStatus: v.navStatus, time: now)
    }

    private func despawnLeavers() {
        let margin = 3_000.0
        let leaving = vessels.filter { abs($0.x) > halfX + margin || abs($0.y) > halfY + margin }
        guard !leaving.isEmpty else { return }
        let ids = Set(leaving.map(\.id))
        vessels.removeAll { ids.contains($0.id) }
        for v in leaving {
            if let i = v.truthIndex { truth[i].end = now }
            switch v.behavior {
            case .transit: spawnTransit(anywhere: false)
            case .goFast: goFastRespawn = now.addingTimeInterval(rng.uniform(300, 900))
            default: break
            }
        }
    }
}
