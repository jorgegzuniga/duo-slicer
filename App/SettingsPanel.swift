import SwiftUI

struct ChoiceOption: Identifiable, Hashable {
    let value: String
    let label: String
    var id: String { value }
}

enum SettingsMode: String, CaseIterable, Identifiable {
    case easy = "Easy", advanced = "Advanced"
    var id: String { rawValue }
}

/// Print settings: Easy (a few big choices) or Advanced (every OrcaSlicer Prepare setting, by tab).
struct SettingsPanel: View {
    @EnvironmentObject var model: AppModel
    @AppStorage("settings.mode") private var modeRaw = SettingsMode.easy.rawValue

    private var mode: Binding<SettingsMode> {
        Binding(get: { SettingsMode(rawValue: modeRaw) ?? .easy }, set: { modeRaw = $0.rawValue })
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Picker("Mode", selection: mode) {
                    ForEach(SettingsMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 260)
                Spacer(minLength: 0)
                if model.changedSettingsCount > 0 {
                    Menu {
                        Button("Reset all to preset", role: .destructive) { Task { await model.resetSettings() } }
                    } label: {
                        Text("\(model.changedSettingsCount) changed")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(Theme.accent.opacity(0.14), in: Capsule())
                            .foregroundStyle(Theme.accent)
                    }
                    .accessibilityLabel("\(model.changedSettingsCount) settings changed. Reset")
                }
            }
            .padding(.horizontal)
            .padding(.top, 6)
            .padding(.bottom, 4)
            switch mode.wrappedValue {
            case .easy: EasySettings(showAdvanced: { mode.wrappedValue = .advanced })
            case .advanced: AdvancedSettings()
            }
        }
        .background(Color(.systemGroupedBackground))
        .onReceive(NotificationCenter.default.publisher(for: .duoDemoSettings)) { n in
            if let s = n.object as? String, let m = SettingsMode(rawValue: s.capitalized) { mode.wrappedValue = m }
        }
    }
}

// MARK: - shared helpers

extension AppModel {
    /// A process setting as it stands (the user's value, else the preset's).
    func settingValue(_ def: SettingDef) -> String {
        options.overrides[def.key] ?? effective[def.key] ?? def.defaultValue
    }

    func numeric(_ key: String, _ fallback: Double) -> Double {
        let s = (options.overrides[key] ?? effective[key] ?? "").replacingOccurrences(of: "%", with: "")
        return Double(s) ?? fallback
    }
}

func settingIsOn(_ v: String) -> Bool { ["1", "true", "yes", "on"].contains(v.lowercased()) }

/// "0.20mm Standard @BBL X1C" -> ("0.20", "Standard").
func presetParts(_ preset: String) -> (height: String, name: String) {
    let base = presetDisplayName(preset)
    let parts = base.split(separator: " ", maxSplits: 1).map(String.init)
    // "0.20mm Standard" (Bambu) or "0.20 Standard" (Snapmaker)
    guard let first = parts.first else { return ("", base) }
    let number = first.lowercased().hasSuffix("mm") ? String(first.dropLast(2)) : first
    guard Double(number) != nil else { return ("", base) }
    return (number, parts.count > 1 ? parts[1] : "")
}

// MARK: - Easy

struct StrengthLevel: Identifiable {
    let id: String
    let title: String
    let detail: String
    let icon: String
    let values: [String: String?]   // nil = the preset's value

    static let keys = ["wall_loops", "top_shell_layers", "bottom_shell_layers", "sparse_infill_density", "sparse_infill_pattern"]

    static let all: [StrengthLevel] = [
        StrengthLevel(id: "light", title: "Light", detail: "2 walls · 10%", icon: "leaf",
                      values: ["wall_loops": "2", "top_shell_layers": "4", "bottom_shell_layers": "3", "sparse_infill_density": "10%", "sparse_infill_pattern": nil]),
        StrengthLevel(id: "standard", title: "Standard", detail: "Preset", icon: "cube",
                      values: ["wall_loops": nil, "top_shell_layers": nil, "bottom_shell_layers": nil, "sparse_infill_density": nil, "sparse_infill_pattern": nil]),
        StrengthLevel(id: "strong", title: "Strong", detail: "4 walls · 25% gyroid", icon: "shield.lefthalf.filled",
                      values: ["wall_loops": "4", "top_shell_layers": "5", "bottom_shell_layers": "4", "sparse_infill_density": "25%", "sparse_infill_pattern": "gyroid"]),
        StrengthLevel(id: "max", title: "Maximum", detail: "6 walls · 50% gyroid", icon: "bolt.shield",
                      values: ["wall_loops": "6", "top_shell_layers": "7", "bottom_shell_layers": "6", "sparse_infill_density": "50%", "sparse_infill_pattern": "gyroid"]),
    ]
}

struct EasySettings: View {
    @EnvironmentObject var model: AppModel
    let showAdvanced: () -> Void

    private let easyPatterns: [ChoiceOption] = [
        ChoiceOption(value: "grid", label: "Grid · fast"), ChoiceOption(value: "gyroid", label: "Gyroid · strong all ways"),
        ChoiceOption(value: "cubic", label: "Cubic"), ChoiceOption(value: "triangles", label: "Triangles"),
        ChoiceOption(value: "zig-zag", label: "Rectilinear · light"), ChoiceOption(value: "concentric", label: "Concentric"),
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                qualityCard
                strengthCard
                adhesionCard
                finishCard
                plateCard
                if let p = model.plate, !p.filaments.isEmpty { materialsCard(p) }
                Button(action: showAdvanced) {
                    HStack {
                        Image(systemName: "slider.horizontal.3")
                        VStack(alignment: .leading, spacing: 2) {
                            Text("All settings").font(.subheadline.weight(.semibold))
                            Text("Speeds, walls, seams, ironing, cooling and every other OrcaSlicer setting").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.footnote).foregroundStyle(.tertiary)
                    }
                    .foregroundStyle(.primary)
                    .card()
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
    }

    // quality presets as tiles
    var qualityCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            CardTitle(title: "Quality", icon: "sparkles", trailing: "for the \(model.target.shortName)")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(sortedProcesses, id: \.self) { proc in
                        let parts = presetParts(proc)
                        ChoiceTile(selected: model.options.process == proc, action: { Task { await model.setProcess(proc) } }) {
                            VStack(alignment: .leading, spacing: 2) {
                                if !parts.height.isEmpty {
                                    HStack(alignment: .firstTextBaseline, spacing: 1) {
                                        Text(parts.height).font(.title3.weight(.bold).monospacedDigit())
                                        Text("mm").font(.caption2).foregroundStyle(.secondary)
                                    }
                                }
                                Text(parts.name.isEmpty ? presetDisplayName(proc) : parts.name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            .frame(minWidth: 82, alignment: .leading)
                        }
                        .fixedSize(horizontal: true, vertical: false)
                    }
                }
            }
            Text("Thinner layers look smoother and take longer.").font(.caption).foregroundStyle(.secondary)
        }
        .card()
    }

    var strengthCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            CardTitle(title: "Strength", icon: "shield.lefthalf.filled")
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                ForEach(StrengthLevel.all) { level in
                    ChoiceTile(selected: currentLevel == level.id, action: { Task { await model.setOverrides(level.values) } }) {
                        HStack(spacing: 10) {
                            Image(systemName: level.icon).font(.title3).foregroundStyle(Theme.accent).frame(width: 26)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(level.title).font(.subheadline.weight(.semibold))
                                Text(level.detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Infill").font(.subheadline)
                    Spacer()
                    Text("\(infill)%").font(.subheadline.monospacedDigit().weight(.semibold)).foregroundStyle(Theme.accent)
                }
                Slider(value: Binding(get: { Double(infill) }, set: { v in Task { await model.setOverride("sparse_infill_density", "\(Int(v))%") } }),
                       in: 0...100, step: 5)
                    .tint(Theme.accent)
            }
            HStack {
                Text("Pattern").font(.subheadline)
                Spacer()
                Picker("Pattern", selection: stringBinding("sparse_infill_pattern", "grid")) {
                    ForEach(patternOptions) { Text($0.label).tag($0.value) }
                }
                .pickerStyle(.menu)
            }
            HStack {
                Text("Walls").font(.subheadline)
                Spacer()
                Stepper("\(intValue("wall_loops", 2))", value: intBinding("wall_loops", 2), in: 1...10)
                    .fixedSize()
                    .monospacedDigit()
            }
        }
        .card()
    }

    var adhesionCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            CardTitle(title: "Bed adhesion", icon: "square.bottomhalf.filled")
            Picker("Bed adhesion", selection: Binding(get: { adhesion }, set: { setAdhesion($0) })) {
                Text("None").tag("none")
                Text("Skirt").tag("skirt")
                Text("Brim").tag("brim")
            }
            .pickerStyle(.segmented)
            Text(adhesionHelp).font(.caption).foregroundStyle(.secondary)
        }
        .card()
    }

    var finishCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            CardTitle(title: "Finish", icon: "wand.and.stars")
            Toggle(isOn: Binding(get: { (model.effective["ironing_type"] ?? "no ironing") != "no ironing" },
                                 set: { on in Task { await model.setOverride("ironing_type", on ? "top" : "no ironing") } })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Smooth top (ironing)").font(.subheadline)
                    Text("The hot nozzle passes over the top again. Slower, very flat finish.").font(.caption).foregroundStyle(.secondary)
                }
            }
            Toggle(isOn: Binding(get: { (model.effective["fuzzy_skin"] ?? "none") != "none" },
                                 set: { on in Task { await model.setOverride("fuzzy_skin", on ? "external" : "none") } })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Textured walls (fuzzy skin)").font(.subheadline)
                    Text("A rough, matte outside that hides layer lines.").font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "info.circle").foregroundStyle(.secondary)
                Text("Supports aren't generated on iPhone yet; flat and layered prints don't need them.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .tint(Theme.accent)
        .card()
    }

    var plateCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            CardTitle(title: "Build plate", icon: "rectangle.on.rectangle")
            if bedTypes.count > 1 {
                Picker("Build plate", selection: stringBinding("curr_bed_type", bedTypes.first?.value ?? "Textured PEI Plate")) {
                    ForEach(bedTypes) { Text($0.label).tag($0.value) }
                }
                .pickerStyle(.menu)
            } else if let only = bedTypes.first {
                Text(only.label).font(.subheadline)
            }
        }
        .card()
    }

    func materialsCard(_ p: PlateInfo) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            CardTitle(title: "Filaments on this plate", icon: "circle.hexagongrid")
            ForEach(p.filaments, id: \.self) { f in FilamentRow(filament: f) }
        }
        .card()
    }

    // MARK: values

    private var bedTypes: [ChoiceOption] {
        let types = model.project?.printer?.bedTypes ?? ["Textured PEI Plate"]
        return types.map { ChoiceOption(value: $0, label: bedTypeLabel($0)) }
    }

    var currentLevel: String? {
        StrengthLevel.all.first { level in
            StrengthLevel.keys.allSatisfy { k in (level.values[k] ?? nil) == model.options.overrides[k] }
        }?.id
    }

    var adhesion: String {
        let brim = model.effective["brim_type"] ?? "auto_brim"
        if ["outer_only", "outer_and_inner", "inner_only", "brim_ears"].contains(brim) { return "brim" }
        if intValue("skirt_loops", 0) > 0 { return "skirt" }
        return "none"
    }

    var adhesionHelp: String {
        switch adhesion {
        case "brim": return "A \(SettingsCatalog.format(model.numeric("brim_width", 5))) mm brim holds the parts down. Peel it off after printing."
        case "skirt": return "A loop around the parts primes the nozzle before they start."
        default: return "Parts print straight on the plate."
        }
    }

    func setAdhesion(_ v: String) {
        Task {
            switch v {
            case "brim": await model.setOverrides(["brim_type": "outer_only", "skirt_loops": "0"])
            case "skirt": await model.setOverrides(["brim_type": "no_brim", "skirt_loops": "2"])
            default: await model.setOverrides(["brim_type": "no_brim", "skirt_loops": "0"])
            }
        }
    }

    var infill: Int { Int(model.numeric("sparse_infill_density", 15)) }

    var patternOptions: [ChoiceOption] {
        let cur = model.effective["sparse_infill_pattern"] ?? "grid"
        if easyPatterns.contains(where: { $0.value == cur }) { return easyPatterns }
        let name = SettingsCatalog.infillPatterns.first { $0.0 == cur }?.1 ?? cur
        return easyPatterns + [ChoiceOption(value: cur, label: name + (SettingsCatalog.enginePatterns.contains(cur) ? "" : " (prints as grid)"))]
    }

    var sortedProcesses: [String] {
        let all = model.project?.processes ?? []
        return all.sorted { a, b in
            let x = Double(a.prefix(4)) ?? 0
            let y = Double(b.prefix(4)) ?? 0
            return x == y ? a < b : x < y
        }
    }

    func intValue(_ k: String, _ d: Int) -> Int { Int(model.numeric(k, Double(d))) }

    func intBinding(_ k: String, _ d: Int) -> Binding<Int> {
        Binding(get: { intValue(k, d) }, set: { v in Task { await model.setOverride(k, String(v)) } })
    }

    func stringBinding(_ k: String, _ d: String) -> Binding<String> {
        Binding(get: { model.options.overrides[k] ?? model.effective[k] ?? d }, set: { v in Task { await model.setOverride(k, v) } })
    }
}

// MARK: - Advanced

struct AdvancedSettings: View {
    @EnvironmentObject var model: AppModel
    @AppStorage("settings.page") private var pageID = SettingsCatalog.quality.id
    @State private var search = ""
    @State private var searching = false
    @State private var onlyChanged = false
    @State private var filament = 1
    @FocusState private var searchFocused: Bool

    var page: SettingPage { SettingsCatalog.page(pageID) ?? SettingsCatalog.quality }

    var body: some View {
        VStack(spacing: 0) {
            tabs
            if searching {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search settings", text: $search)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($searchFocused)
                        .submitLabel(.search)
                    if !search.isEmpty {
                        Button { search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                            .accessibilityLabel("Clear search")
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 10))
                .padding(.horizontal)
                .padding(.bottom, 6)
            }
            if needsFilamentPicker { filamentPicker }
            List {
                if !search.isEmpty {
                    searchResults
                } else if onlyChanged {
                    changedList
                } else {
                    ForEach(page.groups) { g in
                        Section(g.title) {
                            ForEach(g.settings) { row($0) }
                        }
                    }
                    pageFooter
                }
            }
            .listStyle(.insetGrouped)
            .scrollDismissesKeyboard(.interactively)
        }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { hideKeyboard() }
            }
        }
    }

    var needsFilamentPicker: Bool {
        (search.isEmpty && !onlyChanged && page.scope == .filament) || (!search.isEmpty && matches.contains { $0.scope == .filament })
    }

    var tabs: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    chip(icon: "magnifyingglass", title: nil, selected: searching) {
                        searching.toggle()
                        if searching { searchFocused = true } else { search = "" }
                    }
                    .accessibilityLabel("Search settings")
                    ForEach(SettingsCatalog.pages) { p in
                        chip(icon: p.icon, title: p.title, selected: !onlyChanged && search.isEmpty && pageID == p.id) {
                            pageID = p.id
                            onlyChanged = false
                            search = ""
                        }
                        .id(p.id)
                    }
                    chip(icon: "pencil.circle", title: "Changed\(model.changedSettingsCount > 0 ? " \(model.changedSettingsCount)" : "")", selected: onlyChanged && search.isEmpty) {
                        onlyChanged = true
                        search = ""
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 6)
            }
            .onAppear { proxy.scrollTo(pageID, anchor: .center) }
        }
    }

    func chip(icon: String, title: String?, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.caption.weight(.semibold))
                if let title { Text(title).font(.subheadline.weight(.medium)) }
            }
            .padding(.horizontal, title == nil ? 10 : 12)
            .padding(.vertical, 7)
            .foregroundStyle(selected ? Color.white : Color.primary)
            .background {
                Capsule().fill(selected ? AnyShapeStyle(Theme.gradient) : AnyShapeStyle(Color(.secondarySystemGroupedBackground)))
            }
        }
        .buttonStyle(.plain)
    }

    var filamentPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(filaments, id: \.self) { f in
                    Button {
                        filament = f
                    } label: {
                        HStack(spacing: 6) {
                            ColorDot(color: model.color(of: f), size: 14)
                            Text("F\(f)").font(.subheadline.weight(.semibold).monospaced())
                            Text(filamentName(f)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background {
                            Capsule().fill(filament == f ? Theme.accent.opacity(0.16) : Color(.secondarySystemGroupedBackground))
                        }
                        .overlay { Capsule().strokeBorder(filament == f ? Theme.accent : .clear, lineWidth: 1.2) }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 6)
        }
        .onAppear { if !filaments.contains(filament) { filament = filaments.first ?? 1 } }
    }

    /// Filaments on the selected plate first (they're the ones that print), then the rest of the project's.
    var filaments: [Int] {
        let onPlate = model.plate?.filaments ?? []
        let all = Array(1...max(1, model.project?.filaments.count ?? 1))
        return onPlate + all.filter { !onPlate.contains($0) }
    }

    func filamentName(_ f: Int) -> String {
        presetDisplayName(model.options.filaments[safe: f - 1] ?? model.project?.filaments[safe: f - 1]?.type ?? "")
    }

    var matches: [SettingDef] {
        let q = search.lowercased().trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        var seen = Set<String>()
        return SettingsCatalog.pages.flatMap(\.settings).filter { d in
            guard !seen.contains(d.key) else { return false }
            let hit = d.label.lowercased().contains(q) || d.key.contains(q.replacingOccurrences(of: " ", with: "_")) || d.tip.lowercased().contains(q)
            if hit { seen.insert(d.key) }
            return hit
        }
    }

    @ViewBuilder var searchResults: some View {
        let found = matches
        if found.isEmpty {
            Section { Text("No settings match \u{201C}\(search)\u{201D}.").foregroundStyle(.secondary) }
        } else {
            ForEach(SettingsCatalog.pages) { p in
                let inPage = found.filter { SettingsCatalog.ownerPage[$0.key] == p.id }
                if !inPage.isEmpty {
                    Section(p.title) { ForEach(inPage) { row($0) } }
                }
            }
        }
    }

    @ViewBuilder var changedList: some View {
        let keys = model.options.overrides.keys.filter { $0 != "curr_bed_type" }.sorted()
        if keys.isEmpty && !model.options.hasFilamentOverrides {
            Section {
                Text("Nothing changed: these are the \(presetDisplayName(model.options.process)) preset's settings.").foregroundStyle(.secondary)
            }
        }
        if !keys.isEmpty {
            Section("Print settings") {
                ForEach(keys, id: \.self) { k in
                    row(SettingsCatalog.byKey[k] ?? SettingDef(key: k, label: k, kind: .text))
                }
            }
        }
        ForEach(Array((model.options.filamentOverrides ?? []).enumerated()), id: \.offset) { i, ov in
            if !ov.isEmpty {
                Section("Filament F\(i + 1)") {
                    ForEach(ov.keys.sorted(), id: \.self) { k in
                        let d = SettingsCatalog.byKey[k] ?? filamentFallback(k)
                        row(d, filament: i + 1)
                    }
                }
            }
        }
        if model.changedSettingsCount > 0 {
            Section {
                Button("Reset all to preset", role: .destructive) { Task { await model.resetSettings() } }
            }
        }
    }

    func filamentFallback(_ k: String) -> SettingDef {
        var d = SettingDef(key: k, label: k, kind: .text)
        d.scope = .filament
        return d
    }

    var pageFooter: some View {
        Section {
            EmptyView()
        } footer: {
            Text(page.scope == .filament
                 ? "Changes here apply to F\(filament) only and replace its \(filamentName(filament)) preset's values. Settings marked \u{201C}not on iPhone yet\u{201D} go into the print file but don't change the toolpaths yet."
                 : "Values start from the \(presetDisplayName(model.options.process)) preset. Settings marked \u{201C}not on iPhone yet\u{201D} go into the print file but don't change the toolpaths yet.")
        }
    }

    func row(_ d: SettingDef, filament explicit: Int? = nil) -> some View {
        let f = explicit ?? filament
        let isFilament = d.scope == .filament
        let value = isFilament ? (model.filamentValue(d.key, f) ?? d.defaultValue) : model.settingValue(d)
        let changed = isFilament ? model.filamentOverride(d.key, f) != nil : model.options.overrides[d.key] != nil
        return SettingRow(def: d, value: value, changed: changed) { v in
            Task {
                if isFilament { await model.setFilamentOverride(d.key, f, v) } else { await model.setOverride(d.key, v) }
            }
        }
    }
}

func hideKeyboard() {
    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
}

/// One setting: its control, what it does, whether it changed from the preset (swipe or long-press to reset).
struct SettingRow: View {
    let def: SettingDef
    let value: String
    let changed: Bool
    let set: (String?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            control
            if !def.tip.isEmpty || !def.applied {
                HStack(spacing: 6) {
                    if !def.applied {
                        Text("Not on iPhone yet")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.14), in: Capsule())
                            .foregroundStyle(.secondary)
                    }
                    if !def.tip.isEmpty { Text(def.tip).font(.caption).foregroundStyle(.secondary) }
                }
            }
        }
        .padding(.vertical, 2)
        .swipeActions(edge: .trailing) {
            if changed { Button("Reset") { set(nil) }.tint(Theme.accent) }
        }
        .contextMenu {
            if changed { Button { set(nil) } label: { Label("Reset to preset", systemImage: "arrow.uturn.backward") } }
            Text(def.key)
        }
    }

    var label: some View {
        HStack(spacing: 6) {
            if changed {
                Circle().fill(Theme.accent).frame(width: 7, height: 7).accessibilityLabel("Changed")
            }
            Text(def.label).font(.subheadline).foregroundStyle(def.applied ? .primary : .secondary)
        }
    }

    @ViewBuilder var control: some View {
        switch def.kind {
        case .bool:
            Toggle(isOn: Binding(get: { settingIsOn(value) }, set: { set($0 ? "1" : "0") })) { label }
                .tint(Theme.accent)
        case .int(let lo, let hi) where hi - lo <= 30:
            let n = Int(Double(value) ?? Double(def.defaultValue) ?? lo)
            Stepper(value: Binding(get: { n }, set: { set(String($0)) }), in: Int(lo)...Int(hi)) {
                HStack {
                    label
                    Spacer()
                    Text("\(n)\(def.unit.isEmpty ? "" : " " + def.unit)").font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
        case .int(let lo, let hi):
            HStack {
                label
                Spacer()
                NumberField(value: value, unit: def.unit) { s in
                    guard let d = Double(s) else { return nil }
                    return String(Int(min(max(d, lo), hi).rounded()))
                } commit: { set($0) }
            }
        case .float(let lo, let hi, _):
            HStack {
                label
                Spacer()
                NumberField(value: value, unit: def.unit) { s in
                    guard let d = Double(s) else { return nil }
                    return SettingsCatalog.format(min(max(d, lo), hi))
                } commit: { set($0) }
            }
        case .percent(let lo, let hi):
            HStack {
                label
                Spacer()
                NumberField(value: value.replacingOccurrences(of: "%", with: ""), unit: "%") { s in
                    guard let d = Double(s.replacingOccurrences(of: "%", with: "")) else { return nil }
                    return SettingsCatalog.format(min(max(d, lo), hi)) + "%"
                } commit: { set($0) }
            }
        case .floatOrPercent:
            HStack {
                label
                Spacer()
                NumberField(value: value, unit: "", keyboard: .numbersAndPunctuation, width: 92) { s in
                    let pct = s.hasSuffix("%")
                    guard let d = Double(s.replacingOccurrences(of: "%", with: "")) else { return nil }
                    return SettingsCatalog.format(d) + (pct ? "%" : "")
                } commit: { set($0) }
            }
            Text(def.unit).font(.caption2).foregroundStyle(.tertiary)
        case .choice(let options):
            Picker(selection: Binding(get: { value }, set: { set($0) })) {
                ForEach(choiceOptions(options)) { Text($0.label).tag($0.value) }
            } label: { label }
            .pickerStyle(.menu)
        case .text:
            VStack(alignment: .leading, spacing: 4) {
                label
                NumberField(value: value, unit: "", keyboard: .default, width: nil, alignment: .leading) { $0 } commit: { set($0) }
            }
        }
    }

    /// The options, with the current value added when it isn't one of them; patterns the iPhone slicer
    /// doesn't draw yet say what prints instead.
    func choiceOptions(_ options: [ChoiceOption]) -> [ChoiceOption] {
        var list = options.map { o -> ChoiceOption in
            if def.key == "sparse_infill_pattern" && !SettingsCatalog.enginePatterns.contains(o.value) {
                return ChoiceOption(value: o.value, label: o.label + " (prints as grid)")
            }
            if (def.key == "top_surface_pattern" || def.key == "bottom_surface_pattern") && !SettingsCatalog.engineSurfacePatterns.contains(o.value) {
                return ChoiceOption(value: o.value, label: o.label + " (prints as rectilinear)")
            }
            return o
        }
        if !value.isEmpty && !list.contains(where: { $0.value == value }) { list.append(ChoiceOption(value: value, label: value)) }
        return list
    }
}

/// A text field for a number that commits when editing ends (Return, Done or tapping elsewhere).
struct NumberField: View {
    let value: String
    let unit: String
    var keyboard: UIKeyboardType = .decimalPad
    var width: CGFloat? = 76
    var alignment: TextAlignment = .trailing
    let normalize: (String) -> String?
    let commit: (String) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    init(value: String, unit: String, keyboard: UIKeyboardType = .decimalPad, width: CGFloat? = 76, alignment: TextAlignment = .trailing,
         normalize: @escaping (String) -> String?, commit: @escaping (String) -> Void) {
        self.value = value
        self.unit = unit
        self.keyboard = keyboard
        self.width = width
        self.alignment = alignment
        self.normalize = normalize
        self.commit = commit
    }

    var body: some View {
        HStack(spacing: 4) {
            TextField("", text: $text)
                .keyboardType(keyboard)
                .multilineTextAlignment(alignment)
                .font(.subheadline.monospacedDigit())
                .focused($focused)
                .submitLabel(.done)
                .onSubmit(save)
                .frame(width: width)
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 8))
            if !unit.isEmpty { Text(unit).font(.caption).foregroundStyle(.secondary).fixedSize() }
        }
        .onAppear { text = value }
        .onChange(of: value) { _, v in if !focused { text = v } }
        .onChange(of: focused) { _, f in if !f { save() } }
    }

    func save() {
        let s = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        guard let v = normalize(s) else { text = value; return }
        text = v
        if v != value { commit(v) }
    }
}

extension Notification.Name {
    static let duoDemoSettings = Notification.Name("duoDemoSettings")
}
