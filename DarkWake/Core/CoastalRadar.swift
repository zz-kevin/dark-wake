import Foundation

/// Synthetic shore-based surface-search radar: the non-cooperative second
/// source, the maritime stand-in for Dark Track's ingestion/radar_model.py.
///
/// What makes it realistic enough to force real fusion logic:
/// - a radar horizon from antenna and target height (small boats vanish
///   sooner than ships),
/// - polar measurement noise, so error grows with range,
/// - detection probability that falls with range and target size,
/// - sea clutter: false plots scattered over the coverage area,
/// - no identity on any plot.
struct CoastalRadar {
    var site: LatLon
    var antennaHeightM = 60.0
    var maxRangeM = 48_000.0
    var sweepPeriodS = 10.0
    var rangeStdM = 25.0
    var azimuthStdDeg = 0.35
    var clutterPerSweep = 1.5

    /// Standard 4/3-earth radar horizon: d(km) = 4.12 (sqrt(h_a) + sqrt(h_t)).
    func horizonM(targetHeightM: Double) -> Double {
        4_120 * (antennaHeightM.squareRoot() + targetHeightM.squareRoot())
    }

    func coverageM(targetHeightM: Double) -> Double {
        min(maxRangeM, horizonM(targetHeightM: targetHeightM))
    }

    func canSee(_ p: LatLon, targetHeightM: Double) -> Bool {
        range(to: p) <= coverageM(targetHeightM: targetHeightM)
    }

    func range(to p: LatLon) -> Double {
        let proj = LocalProjection(origin: site)
        let (x, y) = proj.toXY(p)
        return hypot(x, y)
    }

    func plotStdM(atRange r: Double) -> Double {
        max(rangeStdM, r * azimuthStdDeg * .pi / 180)
    }

    func detectionProbability(range r: Double, targetHeightM: Double) -> Double {
        let base = targetHeightM >= 8 ? 0.95 : 0.8
        return base * (1 - 0.35 * min(r / maxRangeM, 1))
    }

    struct Target {
        var id: String
        var position: LatLon
        var heightM: Double
    }

    func sweep(_ targets: [Target], at time: Date, rng: inout SplitMix64) -> [RadarContact] {
        let proj = LocalProjection(origin: site)
        let azStd = azimuthStdDeg * .pi / 180
        var out: [RadarContact] = []
        for t in targets {
            let (x, y) = proj.toXY(t.position)
            let r = hypot(x, y)
            guard r <= coverageM(targetHeightM: t.heightM), r > 200 else { continue }
            guard rng.chance(detectionProbability(range: r, targetHeightM: t.heightM)) else { continue }
            let rr = r + rng.gaussian(rangeStdM)
            let az = atan2(x, y) + rng.gaussian(azStd)
            out.append(RadarContact(position: proj.toLatLon(x: rr * sin(az), y: rr * cos(az)),
                                    time: time, rStdM: plotStdM(atRange: r), truthID: t.id))
        }
        for _ in 0..<rng.poisson(clutterPerSweep) {
            let r = maxRangeM * rng.uniform().squareRoot()
            let az = rng.uniform(0, 2 * .pi)
            out.append(RadarContact(position: proj.toLatLon(x: r * sin(az), y: r * cos(az)),
                                    time: time, rStdM: plotStdM(atRange: r), truthID: nil))
        }
        return out.shuffled(using: &rng)
    }
}
