import SwiftUI

struct AlertsScreen: View {
    @Environment(AppModel.self) private var model
    @State private var filter: AlertKind?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ScorecardView(card: model.scorecard, simulation: model.source == .simulation)
                } header: {
                    Text(model.source == .simulation ? "Scored against simulation truth" : "Injected dropouts")
                }

                let shown = model.alerts.filter { filter == nil || $0.kind == filter }
                let open = shown.filter(\.isOpen)
                let closed = shown.filter { !$0.isOpen }.prefix(100)

                Section("Open (\(open.count))") {
                    if open.isEmpty {
                        Text("Nothing open").foregroundStyle(.secondary)
                    }
                    ForEach(open) { row($0) }
                }
                if !closed.isEmpty {
                    Section("Resolved") {
                        ForEach(Array(closed)) { row($0) }
                    }
                }
            }
            .navigationTitle("Alerts")
            .toolbar {
                Menu {
                    Picker("Kind", selection: $filter) {
                        Text("All kinds").tag(AlertKind?.none)
                        ForEach(AlertKind.allCases, id: \.self) { Text($0.title).tag(AlertKind?.some($0)) }
                    }
                } label: {
                    Image(systemName: filter == nil ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                }
            }
        }
    }

    private func row(_ a: Alert) -> some View {
        Button { model.show(a) } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: a.kind.symbol)
                    .foregroundStyle(a.isOpen ? a.kind.color : .secondary)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(a.kind.title).font(.subheadline.bold())
                        Spacer()
                        Text(a.detectedAt.formatted(date: .omitted, time: .shortened))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Text(a.name ?? a.mmsi.map { "MMSI \($0)" } ?? "Unidentified contact")
                        .font(.subheadline)
                    Text(a.detail).font(.caption).foregroundStyle(.secondary)
                }
            }
            .opacity(a.isOpen ? 1 : 0.7)
        }
        .buttonStyle(.plain)
    }
}

struct ScorecardView: View {
    let card: Scorecard
    let simulation: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if card.scored == 0 {
                Text(simulation
                     ? "Waiting for the first scripted dropout to run long enough to score\u{2026}"
                     : "Select a vessel on the map and inject an AIS dropout to test detection against the live picture.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                metric("Went dark (radar-visible)", ratio(card.confirmedDetected, card.radarVisible))
                if card.edgeExcluded > 0 {
                    metric("Not scored (at area edge)", "\(card.edgeExcluded)")
                }
                metric("Any dark/gap alert", ratio(card.anyDetected, card.scored))
                if let m = card.medianLatencyS { metric("Median time to alert", fmt(m)) }
                if simulation {
                    metric("Rendezvous caught", ratio(card.rendezvousDetected, card.rendezvousScored))
                    metric("Position jumps caught", ratio(card.jumpsDetected, card.jumpsInjected))
                    metric("False went-dark alarms",
                           "\(card.falseAlarms) (\(card.falseAlarmVessels) of \(card.aisVessels) vessels, \(String(format: "%.1f", card.falseAlarmRate * 100))%)")
                }
            }
        }
    }

    private func metric(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.subheadline)
            Spacer()
            Text(value).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
        }
    }

    private func ratio(_ a: Int, _ b: Int) -> String {
        b == 0 ? "\u{2014}" : "\(a)/\(b) (\(Int((Double(a) / Double(b) * 100).rounded()))%)"
    }
}
