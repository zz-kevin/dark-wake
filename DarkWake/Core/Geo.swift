import Foundation

struct LatLon: Hashable, Codable {
    var lat: Double
    var lon: Double
}

enum Units {
    static let mpsPerKnot = 0.514444
}

/// lat/lon <-> local east/north metres around an origin. Same small-angle
/// approximation as Dark Track's fusion/geo.py: fine at the tens-of-km
/// scale of one coastal radar's coverage, not across an ocean.
struct LocalProjection {
    let origin: LatLon
    private let mPerDegLat = 111_320.0
    private let mPerDegLon: Double

    init(origin: LatLon) {
        self.origin = origin
        mPerDegLon = 111_320.0 * cos(origin.lat * .pi / 180)
    }

    func toXY(_ p: LatLon) -> (x: Double, y: Double) {
        ((p.lon - origin.lon) * mPerDegLon, (p.lat - origin.lat) * mPerDegLat)
    }

    func toLatLon(x: Double, y: Double) -> LatLon {
        LatLon(lat: origin.lat + y / mPerDegLat, lon: origin.lon + x / mPerDegLon)
    }
}

/// AIS speed over ground (knots) and course over ground (degrees true) as
/// an east/north velocity in m/s.
func velocityXY(sogKnots: Double, cogDeg: Double) -> (Double, Double) {
    let v = sogKnots * Units.mpsPerKnot
    let r = cogDeg * .pi / 180
    return (v * sin(r), v * cos(r))
}

func courseDeg(vx: Double, vy: Double) -> Double {
    let d = atan2(vx, vy) * 180 / .pi
    return d < 0 ? d + 360 : d
}

func hypot2(_ a: (Double, Double), _ b: (Double, Double)) -> Double {
    hypot(a.0 - b.0, a.1 - b.1)
}
