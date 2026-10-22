import SwiftUI

struct VesselCard: View {
    @Environment(AppModel.self) private var model
    let pin: VesselPin
    @State private var injected = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(pin.title).font(.headline)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(pin.status.label)
                    .font(.caption.bold())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(pin.status.color.opacity(0.2), in: Capsule())
                    .foregroundStyle(pin.status.color)
                Button { model.selectedID = nil } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                GridRow {
                    stat("Speed", String(format: "%.1f kn", pin.speedKn))
                    stat("Course", pin.speedKn > 0.5 ? String(format: "%03.0f\u{00B0}", pin.courseDeg) : "\u{2014}")
                    stat("\u{00B1} pos", "\(Int(pin.positionStdM.rounded())) m")
                }
                GridRow {
                    stat("Last AIS", age(pin.lastAIS))
                    stat("Last radar", age(pin.lastRadar))
                    stat("Radar hits", "\(pin.radarHits)")
                }
            }

            if pin.mmsi != nil {
                Text(NavStatus.label(pin.navStatus)).font(.caption).foregroundStyle(.secondary)
            }

            if let a = model.alerts.first(where: { $0.isOpen && ($0.trackID == pin.id || $0.otherTrackID == pin.id) }) {
                Label(a.detail, systemImage: a.kind.symbol)
                    .font(.caption)
                    .foregroundStyle(a.kind.color)
            }

            if model.canInject(pin) && !injected {
                Button {
                    model.injectDropout(for: pin)
                    injected = true
                } label: {
                    Label("Inject AIS dropout (8 min)", systemImage: "antenna.radiowaves.left.and.right.slash")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .controlSize(.small)
            }
        }
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .onChange(of: pin.id) { _, _ in injected = false }
    }

    private var subtitle: String {
        var parts: [String] = []
        if let m = pin.mmsi { parts.append("MMSI \(m)") } else { parts.append("No AIS identity") }
        if let k = pin.kind { parts.append(k.label) }
        return parts.joined(separator: " \u{00B7} ")
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.callout.monospacedDigit())
        }
    }

    private func age(_ d: Date?) -> String {
        guard let d else { return "never" }
        let s = model.now.timeIntervalSince(d)
        return s < 5 ? "now" : "\(fmt(s)) ago"
    }
}
