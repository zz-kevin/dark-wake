import SwiftUI

struct SettingsScreen: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            Form {
                Section("Source") {
                    Picker("Data", selection: $model.source) {
                        ForEach(DataSource.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Picker("Area", selection: $model.regionID) {
                        ForEach(Region.presets) { Text($0.name).tag($0.id) }
                    }
                    if model.source == .simulation {
                        Picker("Speed", selection: $model.simSpeed) {
                            ForEach([1.0, 5, 20, 60], id: \.self) { Text("\(Int($0))\u{00D7}").tag($0) }
                        }
                    }
                }

                if model.source == .live {
                    Section {
                        SecureField("aisstream.io API key", text: $model.apiKey)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Link("Get a free key at aisstream.io", destination: URL(string: "https://aisstream.io")!)
                    } header: {
                        Text("Live AIS")
                    } footer: {
                        Text("Stored in the Keychain. Coverage is terrestrial AIS receivers, so quiet patches far offshore are normal.")
                    }
                }

                Section {
                    LabeledContent("Minimum AIS silence", value: "\(Int(model.minSilenceS)) s")
                    Slider(value: $model.minSilenceS, in: 30...300, step: 10)
                    LabeledContent("Radar recency", value: "\(Int(model.radarRecencyS)) s")
                    Slider(value: $model.radarRecencyS, in: 10...120, step: 10)
                    LabeledContent("Unconfirmed gap after", value: "\(Int(model.gapMinutes)) min")
                    Slider(value: $model.gapMinutes, in: 5...60, step: 5)
                } header: {
                    Text("Detection")
                } footer: {
                    Text("A vessel is flagged as gone dark when its AIS has been silent for the longer of this minimum and three of its own usual reporting intervals, while radar has kept corroborating it on at least half the sweeps.")
                }

                Section {
                    Button {
                        model.restart()
                        model.tab = .map
                    } label: {
                        Label("Apply and restart", systemImage: "arrow.clockwise")
                    }
                }

                Section("About") {
                    Text("Dark Wake fuses AIS (vessels' own identity transponders) with a simulated coastal radar that sees hulls but not names, then flags vessels whose AIS goes quiet while radar keeps tracking them, along with AIS position jumps, stopped-alongside rendezvous, and radar contacts that never identify themselves.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
        }
    }
}
