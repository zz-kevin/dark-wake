import Foundation

/// Live mode: the aisstream.io connection feeding a LiveTracker (Core), which
/// holds the radar-from-AIS, injection and scoring logic so it can be tested
/// without a network.
@MainActor
final class LiveFeed {
    let tracker: LiveTracker
    let client = AISStreamClient()

    var pipeline: Pipeline { tracker.pipeline }

    init(region: Region, detectorConfig: DetectorConfig) {
        tracker = LiveTracker(region: region, detectorConfig: detectorConfig)
        client.onReport = { [weak self] r in self?.tracker.receive(r) }
    }

    func start(apiKey: String) { client.connect(apiKey: apiKey, region: pipeline.region) }
    func stop() { client.disconnect() }

    /// One cycle; call every couple of seconds.
    func tick(now: Date = Date()) { tracker.tick(now: now) }

    @discardableResult
    func inject(mmsi: Int, now: Date = Date()) -> Bool { tracker.inject(mmsi: mmsi, now: now) }

    func isInjected(_ mmsi: Int) -> Bool { tracker.isInjected(mmsi) }

    func scorecard(now: Date) -> Scorecard { tracker.scorecard(now: now) }
}
