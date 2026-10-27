import MapKit
import SwiftUI

struct MapScreen: View {
    @Environment(AppModel.self) private var model
    @State private var camera: MapCameraPosition = .automatic
    @State private var banner: Alert?

    var body: some View {
        @Bindable var model = model
        Map(position: $camera, selection: $model.selectedID) {
            MapCircle(center: model.region.radarSite.coordinate, radius: model.radar.maxRangeM)
                .foregroundStyle(.green.opacity(0.05))
                .stroke(.green.opacity(0.45), lineWidth: 1)
            Annotation(model.region.radarName, coordinate: model.region.radarSite.coordinate) {
                Image(systemName: "dot.radiowaves.up.forward")
                    .font(.caption.bold())
                    .foregroundStyle(.green)
                    .padding(5)
                    .background(.black.opacity(0.6), in: Circle())
            }

            ForEach(model.pins) { pin in
                if pin.status == .dark || pin.status == .gap || pin.id == model.selectedID, pin.trail.count > 1 {
                    MapPolyline(coordinates: pin.trail)
                        .stroke(pin.status.color.opacity(pin.status == .ais ? 0.8 : 0.6), lineWidth: 2)
                }
                if pin.status == .dark || pin.status == .gap || pin.status == .radarOnly {
                    // Capped: a vessel quiet for many minutes has an uncertainty
                    // that grows without bound, and an uncapped ring covered
                    // most of Singapore in the first live recording.
                    MapCircle(center: pin.coordinate, radius: min(max(2 * pin.positionStdM, 60), 5_000))
                        .foregroundStyle(pin.status.color.opacity(0.12))
                        .stroke(pin.status.color.opacity(0.5), lineWidth: 1)
                }
                Annotation(pin.title, coordinate: pin.coordinate, anchor: .center) {
                    VesselMarker(pin: pin, selected: pin.id == model.selectedID)
                }
                .annotationTitles(.hidden)
                .tag(pin.id)
            }
        }
        .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
        .mapControls { MapCompass(); MapScaleView() }
        .safeAreaInset(edge: .top) { StatusBar() }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 8) {
                if let banner {
                    AlertBanner(alert: banner) { model.show(banner); self.banner = nil }
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                if let pin = model.selectedPin {
                    VesselCard(pin: pin)
                } else {
                    Legend()
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 8)
            .animation(.snappy, value: banner?.id)
        }
        .onChange(of: model.cameraRequest) { _, req in
            guard let req else { return }
            withAnimation {
                camera = .region(MKCoordinateRegion(center: req.center.coordinate,
                                                    span: MKCoordinateSpan(latitudeDelta: req.spanDeg, longitudeDelta: req.spanDeg)))
            }
        }
        .onChange(of: model.lastNewAlert?.id) { _, _ in
            banner = model.lastNewAlert
            let shown = banner?.id
            Task {
                try? await Task.sleep(nanoseconds: 6_000_000_000)
                if banner?.id == shown { banner = nil }
            }
        }
    }
}

extension VesselPin.Status {
    var color: Color {
        switch self {
        case .ais: return .cyan
        case .stationary: return .gray
        case .dark: return .red
        case .gap: return .orange
        case .radarOnly: return .yellow
        }
    }

    var label: String {
        switch self {
        case .ais: return "AIS"
        case .stationary: return "At anchor / moored"
        case .dark: return "Went dark"
        case .gap: return "AIS gap"
        case .radarOnly: return "Radar only"
        }
    }
}

struct VesselMarker: View {
    let pin: VesselPin
    let selected: Bool
    @State private var pulse = false

    var body: some View {
        ZStack {
            if pin.status == .dark {
                Circle()
                    .stroke(Color.red, lineWidth: 2)
                    .frame(width: 34, height: 34)
                    .scaleEffect(pulse ? 1.3 : 0.6)
                    .opacity(pulse ? 0 : 0.9)
                    .onAppear {
                        withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) { pulse = true }
                    }
            }
            if selected {
                Circle().stroke(.white, lineWidth: 2).frame(width: 30, height: 30)
            }
            symbol
                .foregroundStyle(pin.status.color)
                .shadow(color: .black.opacity(0.8), radius: 1.5)
        }
        .frame(width: 36, height: 36)
        .contentShape(Rectangle())
    }

    @ViewBuilder private var symbol: some View {
        switch pin.status {
        case .stationary:
            Image(systemName: "circle.fill").font(.system(size: 9))
        case .radarOnly:
            Image(systemName: "diamond.fill").font(.system(size: 13))
        default:
            Image(systemName: "location.north.fill")
                .font(.system(size: (pin.kind?.radarHeightM ?? 8) >= 8 ? 17 : 13))
                .rotationEffect(.degrees(pin.speedKn > 0.5 ? pin.courseDeg : 0))
        }
    }
}

struct StatusBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(dotColor)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.caption.bold())
                Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if model.darkCount > 0 {
                Label("\(model.darkCount)", systemImage: "antenna.radiowaves.left.and.right.slash")
                    .font(.caption.bold())
                    .foregroundStyle(.red)
            }
            if model.source == .simulation {
                Button { model.togglePause() } label: {
                    Image(systemName: model.running ? "pause.fill" : "play.fill")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal)
    }

    private var title: String {
        model.source == .simulation
            ? "\(model.region.name) \u{00B7} simulation \(Int(model.simSpeed))\u{00D7}"
            : "\(model.region.name) \u{00B7} live AIS"
    }

    private var subtitle: String {
        let time = model.now.formatted(date: .omitted, time: .standard)
        let tracks = "\(model.pins.count) tracks"
        switch (model.source, model.liveState) {
        case (.live, .failed(let why)): return why
        case (.live, .connecting): return "Connecting to aisstream.io\u{2026}"
        case (.live, _): return "\(time) \u{00B7} \(tracks) \u{00B7} \(model.liveMessages) msgs"
        default: return "\(time) \u{00B7} \(tracks)"
        }
    }

    private var dotColor: Color {
        switch (model.source, model.liveState) {
        case (.live, .failed): return .red
        case (.live, .connected): return .green
        case (.live, _): return .orange
        default: return model.running ? .green : .gray
        }
    }
}

struct Legend: View {
    var body: some View {
        HStack(spacing: 12) {
            ForEach([VesselPin.Status.ais, .dark, .gap, .radarOnly, .stationary], id: \.self) { s in
                HStack(spacing: 4) {
                    Circle().fill(s.color).frame(width: 7, height: 7)
                    Text(s.label).font(.caption2)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}

struct AlertBanner: View {
    let alert: Alert
    let tap: () -> Void

    var body: some View {
        Button(action: tap) {
            HStack(spacing: 10) {
                Image(systemName: alert.kind.symbol)
                    .foregroundStyle(alert.kind.color)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(alert.kind.title): \(alert.name ?? alert.mmsi.map { "MMSI \($0)" } ?? "unidentified")")
                        .font(.subheadline.bold())
                    Text(alert.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
            }
            .padding(12)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(alert.kind.color.opacity(0.6)))
        }
        .buttonStyle(.plain)
    }
}

extension AlertKind {
    var color: Color {
        switch severity {
        case 3: return .red
        case 2: return .orange
        default: return .yellow
        }
    }
}
