import Foundation
import MapKit
import Observation
import SwiftUI

enum DataSource: String, CaseIterable, Identifiable {
    case simulation, live
    var id: String { rawValue }
    var label: String { self == .simulation ? "Simulation" : "Live AIS" }
}

enum Tab: Hashable { case map, alerts, settings }

/// Ask the map to move. A fresh token each time so repeating the same
/// target still moves it.
struct CameraRequest: Equatable {
    let token = UUID()
    let center: LatLon
    let spanDeg: Double
}

/// What a marker on the map shows -- a snapshot of one fused track.
struct VesselPin: Identifiable {
    enum Status { case ais, stationary, dark, gap, radarOnly }

    let id: Int
    var coordinate: CLLocationCoordinate2D
    var courseDeg: Double
    var speedKn: Double
    var status: Status
    var title: String
    var mmsi: Int?
    var kind: VesselKind?
    var navStatus: Int?
    var lastAIS: Date?
    var lastRadar: Date?
    var radarHits: Int
    var trail: [CLLocationCoordinate2D]
    /// 1-sigma position uncertainty, metres -- grows while a dark vessel
    /// is only being held by noisy radar, or coasting on nothing.
    var positionStdM: Double
    var hasAlert: Bool
}

@MainActor
@Observable
final class AppModel {
    // Settings (persisted)
    var source: DataSource = .simulation { didSet { save() } }
    var regionID: String = Region.presets[0].id { didSet { save() } }
    var simSpeed: Double = 20 { didSet { save() } }
    var minSilenceS: Double = 60 { didSet { save() } }
    var radarRecencyS: Double = 30 { didSet { save() } }
    var gapMinutes: Double = 10 { didSet { save() } }
    var apiKey: String = Keychain.read("aisstream") ?? "" { didSet { Keychain.write("aisstream", apiKey) } }

    // Published state
    var tab: Tab = .map
    var pins: [VesselPin] = []
    var alerts: [Alert] = []
    var scorecard = Scorecard()
    var now = Date()
    var running = false
    var liveState: AISStreamClient.State = .idle
    var liveMessages = 0
    var selectedID: Int?
    var cameraRequest: CameraRequest?
    var lastNewAlert: Alert?

    private var sim: SimulationRun?
    private var live: LiveFeed?
    private var loop: Task<Void, Never>?

    var region: Region { Region.presets.first { $0.id == regionID } ?? Region.presets[0] }
    var radar: CoastalRadar { CoastalRadar(site: region.radarSite) }
    var openAlertCount: Int { alerts.filter(\.isOpen).count }
    var darkCount: Int { pins.filter { $0.status == .dark || $0.status == .gap }.count }
    var selectedPin: VesselPin? { pins.first { $0.id == selectedID } }

    init() {
        let d = UserDefaults.standard
        if let s = d.string(forKey: "source").flatMap(DataSource.init(rawValue:)) { source = s }
        if let r = d.string(forKey: "region"), Region.presets.contains(where: { $0.id == r }) { regionID = r }
        if d.double(forKey: "simSpeed") > 0 { simSpeed = d.double(forKey: "simSpeed") }
        if d.double(forKey: "minSilence") > 0 { minSilenceS = d.double(forKey: "minSilence") }
        if d.double(forKey: "radarRecency") > 0 { radarRecencyS = d.double(forKey: "radarRecency") }
        if d.double(forKey: "gapMinutes") > 0 { gapMinutes = d.double(forKey: "gapMinutes") }
    }

    private func save() {
        let d = UserDefaults.standard
        d.set(source.rawValue, forKey: "source")
        d.set(regionID, forKey: "region")
        d.set(simSpeed, forKey: "simSpeed")
        d.set(minSilenceS, forKey: "minSilence")
        d.set(radarRecencyS, forKey: "radarRecency")
        d.set(gapMinutes, forKey: "gapMinutes")
    }

    private var detectorConfig: DetectorConfig {
        var c = DetectorConfig()
        c.minAISSilenceS = minSilenceS
        c.radarRecencyS = radarRecencyS
        c.gapSilenceS = gapMinutes * 60
        return c
    }

    // MARK: Lifecycle

    func restart() {
        stop()
        pins = []
        alerts = []
        scorecard = Scorecard()
        selectedID = nil
        cameraRequest = CameraRequest(center: region.center, spanDeg: region.halfSpanLatDeg * 2.4)
        switch source {
        case .simulation:
            let run = SimulationRun(region: region, start: Date(), seed: UInt64.random(in: 1...1_000_000),
                                    detectorConfig: detectorConfig)
            sim = run
            now = run.now
            resumeSim()
        case .live:
            guard !apiKey.isEmpty else {
                liveState = .failed("Add an aisstream.io API key in Settings")
                return
            }
            let feed = LiveFeed(region: region, detectorConfig: detectorConfig)
            feed.client.onState = { [weak self] s in self?.liveState = s }
            live = feed
            feed.start(apiKey: apiKey)
            loop = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self, let feed = self.live else { return }
                    let t = Date()
                    let before = feed.pipeline.anomalies.alerts.count
                    feed.tick(now: t)
                    self.publish(pipeline: feed.pipeline, now: t,
                                 new: Array(feed.pipeline.anomalies.alerts[before...]))
                    self.scorecard = feed.scorecard(now: t)
                    self.liveMessages = feed.client.messages
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                }
            }
        }
        running = true
    }

    func stop() {
        loop?.cancel()
        loop = nil
        live?.stop()
        live = nil
        sim = nil
        running = false
    }

    func togglePause() {
        if running { loop?.cancel(); loop = nil; running = false } else if sim != nil { resumeSim() } else { restart() }
    }

    private func resumeSim() {
        guard sim != nil else { return }
        running = true
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let run = self.sim else { return }
                let new = run.step()
                self.publish(pipeline: run.pipeline, now: run.now, new: new)
                self.scorecard = run.scorecard()
                // One step is one radar sweep of simulated time.
                let period = run.pipeline.radar.sweepPeriodS / max(self.simSpeed, 0.1)
                try? await Task.sleep(nanoseconds: UInt64(period * 1e9))
            }
        }
    }

    // MARK: Actions

    /// Switch a vessel's AIS off for 8 minutes while the radar keeps seeing it.
    func injectDropout(for pin: VesselPin) {
        guard let mmsi = pin.mmsi else { return }
        if let sim { sim.simulator.forceDark(mmsi: mmsi) } else { live?.inject(mmsi: mmsi) }
    }

    func canInject(_ pin: VesselPin) -> Bool {
        guard pin.mmsi != nil, pin.status == .ais else { return false }
        if let m = pin.mmsi, let live { return !live.isInjected(m) }
        return true
    }

    func show(_ alert: Alert) {
        selectedID = alert.trackID
        let p = pins.first { $0.id == alert.trackID }?.coordinate
        cameraRequest = CameraRequest(center: p.map { LatLon(lat: $0.latitude, lon: $0.longitude) } ?? alert.position, spanDeg: 0.12)
        tab = .map
    }

    // MARK: Snapshot

    private func publish(pipeline: Pipeline, now: Date, new: [Alert]) {
        self.now = now
        let fusion = pipeline.fusion, anomalies = pipeline.anomalies
        var out: [VesselPin] = []
        for t in fusion.tracks.values where t.confirmed {
            let dark = anomalies.darkKind(t.id)
            let flagged = anomalies.hasOpenAlert(t.id)
            // An identified vessel that has gone quiet without raising
            // anything has most likely just left the feed's area.
            if !t.isRadarOnly && dark == nil && !flagged && now.timeIntervalSince(t.lastUpdate) > 300 { continue }
            let status: VesselPin.Status
            switch dark {
            case .wentDark?: status = .dark
            case .aisGap?: status = .gap
            default: status = t.isRadarOnly ? .radarOnly : (t.aisStationary ? .stationary : .ais)
            }
            let (_, P) = t.kf.peekPredict(now.timeIntervalSince(t.lastUpdate))
            let speed = t.isRadarOnly || dark != nil ? t.kf.speedKnots : (t.lastAIS?.sogKnots ?? t.kf.speedKnots)
            let course = t.isRadarOnly || dark != nil
                ? courseDeg(vx: t.kf.velocity.0, vy: t.kf.velocity.1)
                : (t.lastAIS?.cogDeg ?? courseDeg(vx: t.kf.velocity.0, vy: t.kf.velocity.1))
            out.append(VesselPin(
                id: t.id,
                coordinate: (dark == .aisGap ? (t.lastAIS?.position ?? fusion.latLon(of: t, at: now)) : fusion.latLon(of: t, at: now)).coordinate,
                courseDeg: course, speedKn: speed, status: status,
                title: t.name ?? (t.mmsi.map { "MMSI \($0)" } ?? "Unidentified #\(t.id)"),
                mmsi: t.mmsi, kind: t.kind, navStatus: t.lastAIS?.navStatus,
                lastAIS: t.lastAISAt, lastRadar: t.lastRadarAt, radarHits: t.radarHits,
                trail: t.trail.map(\.coordinate), positionStdM: ((P[0, 0] + P[1, 1]) / 2).squareRoot(),
                hasAlert: flagged))
        }
        pins = out.sorted { $0.id < $1.id }
        alerts = anomalies.alerts.sorted { $0.detectedAt > $1.detectedAt }
        if let worst = new.max(by: { $0.kind.severity < $1.kind.severity }), worst.kind.severity >= 2 {
            lastNewAlert = worst
        }
        if let sel = selectedID, !pins.contains(where: { $0.id == sel }) { selectedID = nil }
    }
}

extension LatLon {
    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: lat, longitude: lon) }
}
