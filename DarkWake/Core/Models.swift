import Foundation

enum VesselKind: String, Codable, CaseIterable {
    case cargo, tanker, passenger, fishing, pleasure, highSpeed, tug, other, unknown

    /// From the AIS "type of ship and cargo" code (ITU-R M.1371 table 53).
    init(aisShipType code: Int) {
        switch code {
        case 30: self = .fishing
        case 31, 32, 52: self = .tug
        case 36, 37: self = .pleasure
        case 40...49: self = .highSpeed
        case 60...69: self = .passenger
        case 70...79: self = .cargo
        case 80...89: self = .tanker
        case 0: self = .unknown
        default: self = .other
        }
    }

    /// Rough height of the radar-reflecting superstructure above the
    /// waterline -- sets how far away the radar horizon hides the vessel.
    var radarHeightM: Double {
        switch self {
        case .cargo, .tanker, .passenger: return 20
        case .fishing, .tug: return 6
        case .pleasure: return 3
        case .highSpeed: return 4
        case .other, .unknown: return 8
        }
    }

    var label: String {
        switch self {
        case .highSpeed: return "High-speed craft"
        default: return rawValue.capitalized
        }
    }
}

/// AIS navigational status codes that mean "not going anywhere".
enum NavStatus {
    static let atAnchor = 1, moored = 5, aground = 6, fishing = 7, underWay = 0, undefined = 15

    static func isStationary(_ code: Int?) -> Bool {
        guard let code else { return false }
        return code == atAnchor || code == moored || code == aground
    }

    static func label(_ code: Int?) -> String {
        switch code {
        case 0: return "Under way (engine)"
        case 1: return "At anchor"
        case 2: return "Not under command"
        case 3: return "Restricted manoeuvrability"
        case 5: return "Moored"
        case 6: return "Aground"
        case 7: return "Engaged in fishing"
        case 8: return "Under way (sail)"
        default: return "Not reported"
        }
    }
}

/// One AIS position report (the cooperative source: carries an identity).
struct AISReport {
    var mmsi: Int
    var name: String?
    var kind: VesselKind?
    var position: LatLon
    var sogKnots: Double?
    var cogDeg: Double?
    var navStatus: Int?
    var time: Date
}

/// One radar plot (the non-cooperative source: position only, no identity).
struct RadarContact {
    var position: LatLon
    var time: Date
    /// 1-sigma position error per axis for this plot, metres.
    var rStdM: Double
    /// Simulation-only ground truth for scoring; nil for clutter. Never read
    /// by fusion or the detectors.
    var truthID: String?
}

struct Region: Identifiable, Hashable {
    let id: String
    let name: String
    let center: LatLon
    let radarSite: LatLon
    let radarName: String
    /// Bearing of the main traffic lane through `center` (simulation only).
    let laneBearingDeg: Double
    let halfSpanLatDeg: Double

    var halfSpanLonDeg: Double { halfSpanLatDeg / cos(center.lat * .pi / 180) }
    var minLat: Double { center.lat - halfSpanLatDeg }
    var maxLat: Double { center.lat + halfSpanLatDeg }
    var minLon: Double { center.lon - halfSpanLonDeg }
    var maxLon: Double { center.lon + halfSpanLonDeg }

    func contains(_ p: LatLon, marginM: Double = 0) -> Bool {
        let mLat = marginM / 111_320
        let mLon = marginM / (111_320 * cos(center.lat * .pi / 180))
        return p.lat > minLat + mLat && p.lat < maxLat - mLat && p.lon > minLon + mLon && p.lon < maxLon - mLon
    }

    static let presets: [Region] = [
        Region(id: "dover", name: "Dover Strait", center: LatLon(lat: 51.02, lon: 1.45),
               radarSite: LatLon(lat: 51.14, lon: 1.37), radarName: "South Foreland",
               laneBearingDeg: 40, halfSpanLatDeg: 0.3),
        Region(id: "gibraltar", name: "Strait of Gibraltar", center: LatLon(lat: 35.95, lon: -5.55),
               radarSite: LatLon(lat: 36.00, lon: -5.61), radarName: "Tarifa",
               laneBearingDeg: 85, halfSpanLatDeg: 0.25),
        Region(id: "singapore", name: "Singapore Strait", center: LatLon(lat: 1.18, lon: 103.90),
               radarSite: LatLon(lat: 1.16, lon: 103.74), radarName: "Raffles Lighthouse",
               laneBearingDeg: 75, halfSpanLatDeg: 0.25),
        // Centred far enough north that Upper New York Bay and Newark Bay
        // sit inside the area rather than in its 2 km edge band, where
        // went-dark is suppressed.
        Region(id: "nyc", name: "New York Bight", center: LatLon(lat: 40.50, lon: -73.95),
               radarSite: LatLon(lat: 40.46, lon: -74.00), radarName: "Sandy Hook",
               laneBearingDeg: 115, halfSpanLatDeg: 0.3),
    ]
}
