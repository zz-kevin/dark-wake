import Foundation

/// Live AIS from aisstream.io (free API key): a WebSocket that streams
/// position reports for a bounding box. Reconnects with backoff.
@MainActor
final class AISStreamClient {
    enum State: Equatable {
        case idle, connecting, connected, failed(String)
    }

    var onReport: (AISReport) -> Void = { _ in }
    var onState: (State) -> Void = { _ in }
    private(set) var messages = 0

    private var loop: Task<Void, Never>?
    private var socket: URLSessionWebSocketTask?
    /// Name and type arrive in separate ShipStaticData messages.
    private var statics: [Int: (name: String?, kind: VesselKind?)] = [:]

    func connect(apiKey: String, region: Region) {
        disconnect()
        loop = Task { [weak self] in
            var backoff = 2.0
            while !Task.isCancelled {
                guard let self else { return }
                let gotData = await self.runOnce(apiKey: apiKey, region: region)
                if Task.isCancelled { return }
                backoff = gotData ? 2 : min(backoff * 2, 60)
                try? await Task.sleep(nanoseconds: UInt64(backoff * 1e9))
            }
        }
    }

    func disconnect() {
        loop?.cancel()
        loop = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        onState(.idle)
    }

    /// One connection's lifetime. Returns whether any message arrived.
    private func runOnce(apiKey: String, region: Region) async -> Bool {
        onState(.connecting)
        let ws = URLSession.shared.webSocketTask(with: URL(string: "wss://stream.aisstream.io/v0/stream")!)
        socket = ws
        ws.resume()
        var got = false
        do {
            // The subscription must be sent within 3 s of connecting.
            let sub: [String: Any] = [
                "APIKey": apiKey,
                "BoundingBoxes": [[[region.minLat, region.minLon], [region.maxLat, region.maxLon]]],
                "FilterMessageTypes": ["PositionReport", "StandardClassBPositionReport", "ShipStaticData"],
            ]
            let body = String(data: try JSONSerialization.data(withJSONObject: sub), encoding: .utf8)!
            try await ws.send(.string(body))
            while !Task.isCancelled {
                let data: Data
                switch try await ws.receive() {
                case .string(let s): data = Data(s.utf8)
                case .data(let d): data = d
                @unknown default: continue
                }
                if !got { got = true; onState(.connected) }
                handle(data)
            }
        } catch {
            if !Task.isCancelled { onState(.failed(error.localizedDescription)) }
        }
        return got
    }

    private func handle(_ data: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if let err = obj["error"] as? String {
            onState(.failed(err))
            return
        }
        guard let type = obj["MessageType"] as? String,
              let meta = obj["MetaData"] as? [String: Any],
              let mmsi = (meta["MMSI"] as? NSNumber)?.intValue,
              let msg = (obj["Message"] as? [String: Any])?[type] as? [String: Any] else { return }
        messages += 1

        if type == "ShipStaticData" {
            let name = (msg["Name"] as? String)?.trimmingCharacters(in: .whitespaces)
            let kind = (msg["Type"] as? NSNumber).map { VesselKind(aisShipType: $0.intValue) }
            statics[mmsi] = (name?.isEmpty == false ? name : statics[mmsi]?.name, kind ?? statics[mmsi]?.kind)
            return
        }

        guard let lat = (msg["Latitude"] as? NSNumber)?.doubleValue,
              let lon = (msg["Longitude"] as? NSNumber)?.doubleValue,
              abs(lat) <= 90, abs(lon) <= 180 else { return }
        // AIS "not available" sentinels: SOG 102.3, COG 360.
        let sog = ((msg["Sog"] as? NSNumber)?.doubleValue).flatMap { $0 < 102.2 ? $0 : nil }
        let cog = ((msg["Cog"] as? NSNumber)?.doubleValue).flatMap { $0 < 360 ? $0 : nil }
        let nav = (msg["NavigationalStatus"] as? NSNumber)?.intValue
        let metaName = (meta["ShipName"] as? String)?.trimmingCharacters(in: .whitespaces)
        onReport(AISReport(mmsi: mmsi, name: statics[mmsi]?.name ?? (metaName?.isEmpty == false ? metaName : nil),
                           kind: statics[mmsi]?.kind, position: LatLon(lat: lat, lon: lon),
                           sogKnots: sog, cogDeg: cog, navStatus: nav, time: Date()))
    }
}
