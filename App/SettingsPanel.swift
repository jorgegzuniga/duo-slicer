import SwiftUI

struct ChoiceOption: Identifiable, Hashable {
    let value: String
    let label: String
    var id: String { value }
}

struct SettingsPanel: View {
    @EnvironmentObject var model: AppModel

    /// Plate types the target printer's filament presets have temperatures for.
    private var bedTypes: [ChoiceOption] {
        let types = model.project?.printer?.bedTypes ?? ["Textured PEI Plate"]
        return types.map { ChoiceOption(value: $0, label: bedTypeLabel($0)) }
    }
    private let brims: [ChoiceOption] = [
        ChoiceOption(value: "auto_brim", label: "Auto (none)"),
        ChoiceOption(value: "no_brim", label: "No brim"),
        ChoiceOption(value: "outer_only", label: "Outer brim"),
        ChoiceOption(value: "outer_and_inner", label: "Outer brim (inner not supported)"),
    ]
    private let patterns: [ChoiceOption] = [
        ChoiceOption(value: "grid", label: "Grid"),
        ChoiceOption(value: "line", label: "Lines"),
        ChoiceOption(value: "zig-zag", label: "Zig-zag"),
    ]

    var body: some View {
        Form {
            Section {
                Picker("Preset", selection: Binding(get: { model.options.process }, set: { v in Task { await model.setProcess(v) } })) {
                    ForEach(sortedProcesses, id: \.self) {
                        Text(presetDisplayName($0)).tag($0)
                    }
                }
                if bedTypes.count > 1 {
                    Picker("Build plate", selection: stringBinding("curr_bed_type", bedTypes.first?.value ?? "Textured PEI Plate")) {
                        ForEach(bedTypes) { Text($0.label).tag($0.value) }
                    }
                } else if let only = bedTypes.first {
                    LabeledContent("Build plate", value: only.label)
                }
            } header: {
                Text("Quality")
            } footer: {
                Text("Presets for the \(model.target.name).")
            }
            Section("Strength") {
                Stepper("Walls: \(intValue("wall_loops", 2))", value: intBinding("wall_loops", 2), in: 1...10)
                Stepper("Top layers: \(intValue("top_shell_layers", 5))", value: intBinding("top_shell_layers", 5), in: 0...20)
                Stepper("Bottom layers: \(intValue("bottom_shell_layers", 3))", value: intBinding("bottom_shell_layers", 3), in: 0...20)
                VStack(alignment: .leading) {
                    HStack { Text("Infill"); Spacer(); Text("\(infill)%").monospacedDigit().foregroundStyle(.secondary) }
                    Slider(value: Binding(get: { Double(infill) }, set: { v in Task { await model.setOverride("sparse_infill_density", "\(Int(v))%") } }), in: 0...100, step: 5)
                }
                Picker("Infill pattern", selection: stringBinding("sparse_infill_pattern", "grid")) {
                    ForEach(patternOptions) { Text($0.label).tag($0.value) }
                }
            }
            Section {
                Picker("Brim", selection: stringBinding("brim_type", "auto_brim")) {
                    ForEach(brimOptions) { Text($0.label).tag($0.value) }
                }
                Stepper("Skirt loops: \(intValue("skirt_loops", 0))", value: intBinding("skirt_loops", 0), in: 0...5)
            } header: {
                Text("Adhesion")
            } footer: {
                Text("Supports and tree supports aren't generated yet; flat and layered prints like wall art don't need them.")
            }
            if !model.options.overrides.filter({ $0.key != "curr_bed_type" }).isEmpty {
                Section {
                    Button("Reset to preset values", role: .destructive) {
                        Task {
                            let bed = model.options.overrides["curr_bed_type"]
                            model.options.overrides = bed.map { ["curr_bed_type": $0] } ?? [:]
                            model.invalidateSlice()
                            await model.refreshEffective()
                        }
                    }
                }
            }
        }
    }

    var infill: Int { Int(Double((model.effective["sparse_infill_density"] ?? "15%").replacingOccurrences(of: "%", with: "")) ?? 15) }

    var patternOptions: [ChoiceOption] {
        let cur = model.effective["sparse_infill_pattern"] ?? "grid"
        if patterns.contains(where: { $0.value == cur }) { return patterns }
        return patterns + [ChoiceOption(value: cur, label: cur + " (prints as grid)")]
    }

    var brimOptions: [ChoiceOption] {
        let cur = model.effective["brim_type"] ?? "auto_brim"
        if brims.contains(where: { $0.value == cur }) { return brims }
        return brims + [ChoiceOption(value: cur, label: cur)]
    }

    var sortedProcesses: [String] {
        let all = model.project?.processes ?? []
        return all.sorted { a, b in
            let x = Double(a.prefix(4)) ?? 0
            let y = Double(b.prefix(4)) ?? 0
            return x == y ? a < b : x < y
        }
    }

    func intValue(_ k: String, _ d: Int) -> Int { Int(Double(model.effective[k] ?? "") ?? Double(d)) }

    func intBinding(_ k: String, _ d: Int) -> Binding<Int> {
        Binding(get: { intValue(k, d) }, set: { v in Task { await model.setOverride(k, String(v)) } })
    }

    func stringBinding(_ k: String, _ d: String) -> Binding<String> {
        Binding(get: { model.effective[k] ?? model.options.overrides[k] ?? d }, set: { v in Task { await model.setOverride(k, v) } })
    }
}
