import Foundation

/// The print settings of OrcaSlicer's Prepare screen (process and filament), grouped the way OrcaSlicer groups them.
/// Keys and values are the ones Bambu Studio / OrcaSlicer profiles use, so they go straight to the engine as overrides
/// and into the sliced file's settings. `SettingsCatalog.engineKeys` lists the ones the iPhone slicer acts on.
struct SettingDef: Identifiable, Hashable {
    enum Kind: Hashable {
        case bool
        case int(min: Double, max: Double)
        case float(min: Double, max: Double, step: Double)
        case percent(min: Double, max: Double)
        case floatOrPercent      // "0.4" (mm) or "90%"
        case choice([ChoiceOption])
        case text
    }

    enum Scope: Hashable { case process, filament }

    let key: String
    let label: String
    let kind: Kind
    var unit = ""
    var defaultValue = ""
    var tip = ""
    var scope: Scope = .process
    /// Easy mode shows these too.
    var essential = false

    var id: String { key }
    var applied: Bool { SettingsCatalog.engineKeys.contains(key) }
}

struct SettingGroup: Identifiable, Hashable {
    let title: String
    let settings: [SettingDef]
    var id: String { title }
}

struct SettingPage: Identifiable, Hashable {
    let id: String
    let title: String
    let icon: String
    let groups: [SettingGroup]
    var scope: SettingDef.Scope = .process

    var settings: [SettingDef] { groups.flatMap(\.settings) }
}

// MARK: - builders

private func b(_ k: String, _ l: String, _ d: Bool = false, _ tip: String = "") -> SettingDef {
    SettingDef(key: k, label: l, kind: .bool, defaultValue: d ? "1" : "0", tip: tip)
}
private func i(_ k: String, _ l: String, _ d: Int, _ lo: Double, _ hi: Double, unit: String = "", _ tip: String = "") -> SettingDef {
    SettingDef(key: k, label: l, kind: .int(min: lo, max: hi), unit: unit, defaultValue: String(d), tip: tip)
}
private func f(_ k: String, _ l: String, _ d: Double, _ lo: Double, _ hi: Double, unit: String = "mm", step: Double = 0.01, tip: String = "") -> SettingDef {
    SettingDef(key: k, label: l, kind: .float(min: lo, max: hi, step: step), unit: unit, defaultValue: SettingsCatalog.format(d), tip: tip)
}
private func speed(_ k: String, _ l: String, _ d: Double, _ tip: String = "") -> SettingDef {
    f(k, l, d, 0, 1000, unit: "mm/s", step: 1, tip: tip)
}
private func accel(_ k: String, _ l: String, _ d: Double, _ tip: String = "") -> SettingDef {
    f(k, l, d, 0, 100000, unit: "mm/s²", step: 100, tip: tip)
}
private func jerk(_ k: String, _ l: String, _ d: Double, _ tip: String = "") -> SettingDef {
    f(k, l, d, 0, 100, unit: "mm/s", step: 1, tip: tip)
}
private func p(_ k: String, _ l: String, _ d: Double, _ lo: Double = 0, _ hi: Double = 100, _ tip: String = "") -> SettingDef {
    SettingDef(key: k, label: l, kind: .percent(min: lo, max: hi), unit: "%", defaultValue: SettingsCatalog.format(d) + "%", tip: tip)
}
private func fp(_ k: String, _ l: String, _ d: String, unit: String = "mm or %", _ tip: String = "") -> SettingDef {
    SettingDef(key: k, label: l, kind: .floatOrPercent, unit: unit, defaultValue: d, tip: tip)
}
private func c(_ k: String, _ l: String, _ d: String, _ opts: [(String, String)], _ tip: String = "") -> SettingDef {
    SettingDef(key: k, label: l, kind: .choice(opts.map { ChoiceOption(value: $0.0, label: $0.1) }), defaultValue: d, tip: tip)
}
private func t(_ k: String, _ l: String, _ tip: String = "") -> SettingDef {
    SettingDef(key: k, label: l, kind: .text, tip: tip)
}
private func filament(_ d: SettingDef) -> SettingDef {
    var x = d
    x.scope = .filament
    return x
}

enum SettingsCatalog {
    static func format(_ v: Double) -> String {
        if v == v.rounded() && abs(v) < 1e9 { return String(Int(v)) }
        var s = String(format: "%.3f", v)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }

    /// Settings the iPhone slicer reads when it slices (the rest are kept in the sliced file's settings and the
    /// printer's own G-code templates, but don't change the toolpaths yet).
    static let engineKeys: Set<String> = [
        // quality
        "layer_height", "initial_layer_print_height", "line_width", "initial_layer_line_width", "outer_wall_line_width", "inner_wall_line_width",
        "top_surface_line_width", "sparse_infill_line_width", "internal_solid_infill_line_width", "seam_position",
        "xy_hole_compensation", "xy_contour_compensation", "elefant_foot_compensation", "elefant_foot_compensation_layers",
        "ironing_type", "ironing_flow", "ironing_spacing", "ironing_speed", "ironing_inset", "ironing_direction",
        "wall_sequence", "top_solid_infill_flow_ratio", "bottom_solid_infill_flow_ratio",
        // strength
        "wall_loops", "top_shell_layers", "top_shell_thickness", "bottom_shell_layers", "bottom_shell_thickness", "top_surface_pattern",
        "bottom_surface_pattern", "sparse_infill_density", "sparse_infill_pattern", "infill_direction", "solid_infill_direction",
        "infill_wall_overlap",
        // speed
        "initial_layer_speed", "initial_layer_infill_speed", "outer_wall_speed", "inner_wall_speed", "sparse_infill_speed",
        "internal_solid_infill_speed", "top_surface_speed", "travel_speed", "travel_speed_z", "default_acceleration", "outer_wall_acceleration",
        "inner_wall_acceleration", "top_surface_acceleration", "sparse_infill_acceleration", "internal_solid_infill_acceleration",
        "initial_layer_acceleration", "travel_acceleration",
        // others
        "skirt_loops", "skirt_distance", "skirt_height", "brim_type", "brim_width", "brim_object_gap", "fuzzy_skin", "fuzzy_skin_thickness",
        "fuzzy_skin_point_distance", "timelapse_type", "ooze_prevention", "standby_temperature_delta", "preheat_time", "flush_multiplier",
        // filament
        "nozzle_temperature_initial_layer", "nozzle_temperature", "hot_plate_temp", "hot_plate_temp_initial_layer", "textured_plate_temp",
        "textured_plate_temp_initial_layer", "cool_plate_temp", "cool_plate_temp_initial_layer", "eng_plate_temp", "eng_plate_temp_initial_layer",
        "supertack_plate_temp", "supertack_plate_temp_initial_layer", "textured_cool_plate_temp", "textured_cool_plate_temp_initial_layer",
        "chamber_temperatures", "filament_flow_ratio", "filament_max_volumetric_speed", "fan_min_speed", "fan_max_speed",
        "close_fan_the_first_x_layers", "fan_cooling_layer_time", "slow_down_layer_time", "slow_down_min_speed", "additional_cooling_fan_speed",
        "filament_retraction_length", "filament_density", "filament_diameter", "temperature_vitrification", "filament_flush_volumetric_speed",
    ]

    static let infillPatterns: [(String, String)] = [
        ("concentric", "Concentric"), ("zig-zag", "Rectilinear"), ("grid", "Grid"), ("line", "Line"), ("cubic", "Cubic"),
        ("triangles", "Triangles"), ("tri-hexagon", "Tri-hexagon"), ("gyroid", "Gyroid"), ("honeycomb", "Honeycomb"),
        ("adaptivecubic", "Adaptive Cubic"), ("alignedrectilinear", "Aligned Rectilinear"), ("3dhoneycomb", "3D Honeycomb"),
        ("hilbertcurve", "Hilbert Curve"), ("archimedeanchords", "Archimedean Chords"), ("octagramspiral", "Octagram Spiral"),
        ("supportcubic", "Support Cubic"), ("lightning", "Lightning"), ("crosshatch", "Cross Hatch"),
    ]
    /// Patterns the iPhone slicer draws; the others print as grid.
    static let enginePatterns: Set<String> = ["concentric", "zig-zag", "grid", "line", "cubic", "triangles", "tri-hexagon", "gyroid", "adaptivecubic",
                                              "alignedrectilinear", "supportcubic", "crosshatch"]
    static let surfacePatterns: [(String, String)] = [
        ("concentric", "Concentric"), ("zig-zag", "Rectilinear"), ("monotonic", "Monotonic"), ("monotonicline", "Monotonic line"),
        ("alignedrectilinear", "Aligned Rectilinear"), ("hilbertcurve", "Hilbert Curve"), ("archimedeanchords", "Archimedean Chords"),
        ("octagramspiral", "Octagram Spiral"),
    ]
    static let engineSurfacePatterns: Set<String> = ["concentric", "zig-zag", "monotonic", "monotonicline", "alignedrectilinear"]

    // MARK: pages

    static let quality = SettingPage(id: "quality", title: "Quality", icon: "sparkles", groups: [
        SettingGroup(title: "Layer height", settings: [
            f("layer_height", "Layer height", 0.2, 0.04, 0.6, tip: "Thinner layers look smoother and take longer."),
            f("initial_layer_print_height", "First layer height", 0.2, 0.05, 0.6, tip: "A thicker first layer sticks better to the plate."),
        ]),
        SettingGroup(title: "Line width", settings: [
            fp("line_width", "Default", "100%", "Used when a feature's width is 0. Percent of the nozzle diameter."),
            fp("initial_layer_line_width", "First layer", "125%"),
            fp("outer_wall_line_width", "Outer wall", "105%"),
            fp("inner_wall_line_width", "Inner wall", "112.5%"),
            fp("top_surface_line_width", "Top surface", "105%"),
            fp("sparse_infill_line_width", "Sparse infill", "112.5%"),
            fp("internal_solid_infill_line_width", "Internal solid infill", "105%"),
            fp("support_line_width", "Support", "100%"),
        ]),
        SettingGroup(title: "Seam", settings: [
            c("seam_position", "Seam position", "aligned", [("nearest", "Nearest"), ("aligned", "Aligned"), ("back", "Back"), ("random", "Random")],
              "Where each wall loop starts and ends."),
            b("staggered_inner_seams", "Staggered inner seams"),
            fp("seam_gap", "Seam gap", "10%", "How far the loop stops short of its start, to hide the seam."),
            c("seam_slope_type", "Scarf joint seam", "none", [("none", "None"), ("external", "Contour"), ("all", "Contour and hole")]),
            b("seam_slope_conditional", "Conditional scarf joint"),
            f("scarf_angle_threshold", "Conditional angle threshold", 155, 0, 180, unit: "°", step: 1),
            fp("seam_slope_start_height", "Scarf start height", "0"),
            b("seam_slope_entire_loop", "Scarf around entire wall"),
            f("seam_slope_min_length", "Scarf length", 20, 0, 100),
            i("seam_slope_steps", "Scarf steps", 10, 1, 100),
            b("seam_slope_inner_walls", "Scarf joint for inner walls"),
            b("role_based_wipe_speed", "Role-based wipe speed", true),
            fp("wipe_speed", "Wipe speed", "80%", unit: "mm/s or %"),
            b("wipe_on_loops", "Wipe on loops"),
        ]),
        SettingGroup(title: "Precision", settings: [
            b("slice_closing_radius", "Slice gap closing radius"),
            f("resolution", "Resolution", 0.012, 0, 1, step: 0.001, tip: "Simplifies the model's outline to this tolerance."),
            b("enable_arc_fitting", "Arc fitting", false, "Writes curves as G2/G3 arcs."),
            f("xy_hole_compensation", "X-Y hole compensation", 0, -2, 2, tip: "Positive makes holes bigger, negative smaller. Useful for press fits."),
            f("xy_contour_compensation", "X-Y contour compensation", 0, -2, 2, tip: "Positive makes outer edges bigger, negative smaller."),
            f("elefant_foot_compensation", "Elephant foot compensation", 0.15, 0, 2,
              tip: "Shrinks the first layer to cancel the bulge it gets from being squished onto the plate."),
            i("elefant_foot_compensation_layers", "Elephant foot layers", 1, 1, 20),
            b("precise_outer_wall", "Precise wall"),
            b("precise_z_height", "Precise Z height"),
            b("hole_to_polyhole", "Convert holes to polyholes"),
        ]),
        SettingGroup(title: "Ironing", settings: [
            c("ironing_type", "Ironing type", "no ironing", [("no ironing", "No ironing"), ("top", "Top surfaces"), ("topmost", "Topmost surface"),
                                                              ("solid", "All solid layers")],
              "A second, nearly dry pass of the hot nozzle over the top that makes it smooth."),
            c("ironing_pattern", "Ironing pattern", "zig-zag", [("zig-zag", "Rectilinear"), ("concentric", "Concentric")]),
            p("ironing_flow", "Ironing flow", 10, 0, 100),
            f("ironing_spacing", "Ironing line spacing", 0.15, 0.01, 1),
            f("ironing_inset", "Ironing inset", 0, 0, 5),
            speed("ironing_speed", "Ironing speed", 30),
            f("ironing_direction", "Ironing angle", 45, 0, 360, unit: "°", step: 1),
        ]),
        SettingGroup(title: "Wall generator", settings: [
            c("wall_generator", "Wall generator", "classic", [("classic", "Classic"), ("arachne", "Arachne")],
              "Arachne varies the line width to fill thin parts; the iPhone slicer uses Classic."),
            p("wall_transition_length", "Wall transition length", 100, 0, 500),
            p("wall_transition_filter_deviation", "Wall transitioning filter margin", 25, 0, 100),
            f("wall_transition_angle", "Wall transitioning threshold angle", 10, 1, 59, unit: "°", step: 1),
            i("wall_distribution_count", "Wall distribution count", 1, 1, 10),
            p("min_feature_size", "Minimum feature size", 25, 0, 100),
            p("min_bead_width", "Minimum wall width", 85, 0, 100),
        ]),
        SettingGroup(title: "Walls and surfaces", settings: [
            c("wall_sequence", "Walls printing order", "inner wall/outer wall", [("inner wall/outer wall", "Inner/Outer"), ("outer wall/inner wall", "Outer/Inner"),
                                                                                  ("inner-outer-inner wall", "Inner/Outer/Inner")],
              "Outer walls first gives better dimensional accuracy; inner first handles overhangs better."),
            b("is_infill_first", "Print infill first"),
            b("wall_direction", "Wall loop direction"),
            p("top_solid_infill_flow_ratio", "Top surface flow ratio", 100, 50, 150),
            p("bottom_solid_infill_flow_ratio", "Bottom surface flow ratio", 100, 50, 150),
            b("only_one_wall_top", "Only one wall on top surfaces"),
            b("only_one_wall_first_layer", "Only one wall on first layer"),
            b("detect_overhang_wall", "Detect overhang walls", true),
            b("make_overhang_printable", "Make overhangs printable"),
            b("extra_perimeters_on_overhangs", "Extra perimeters on overhangs"),
            b("overhang_reverse", "Reverse on even"),
            b("detect_thin_wall", "Detect thin walls"),
        ]),
        SettingGroup(title: "Bridging", settings: [
            p("bridge_flow", "Bridge flow ratio", 100, 50, 200),
            p("internal_bridge_flow", "Internal bridge flow ratio", 100, 50, 200),
            f("bridge_density", "Bridge density", 100, 10, 120, unit: "%", step: 1),
            b("thick_bridges", "Thick external bridges"),
            b("thick_internal_bridges", "Thick internal bridges", true),
            f("max_bridge_length", "Max bridge length", 10, 0, 1000, step: 1),
            c("counterbore_hole_bridging", "Bridge counterbore holes", "none", [("none", "None"), ("partiallybridge", "Partially bridged"),
                                                                               ("sacrificiallayer", "Sacrificial layer")]),
        ]),
    ])

    static let strength = SettingPage(id: "strength", title: "Strength", icon: "shield.lefthalf.filled", groups: [
        SettingGroup(title: "Walls", settings: [
            i("wall_loops", "Wall loops", 2, 0, 50, "More walls make parts stronger and heavier."),
            b("alternate_extra_wall", "Alternate extra wall"),
            b("detect_thin_wall", "Detect thin walls"),
        ]),
        SettingGroup(title: "Top/bottom shells", settings: [
            c("top_surface_pattern", "Top surface pattern", "monotonicline", SettingsCatalog.surfacePatterns),
            i("top_shell_layers", "Top shell layers", 5, 0, 100),
            f("top_shell_thickness", "Top shell thickness", 1, 0, 10, tip: "Adds top layers until they're at least this thick."),
            p("top_surface_density", "Top surface density", 100, 0, 100),
            c("bottom_surface_pattern", "Bottom surface pattern", "monotonic", SettingsCatalog.surfacePatterns),
            i("bottom_shell_layers", "Bottom shell layers", 3, 0, 100),
            f("bottom_shell_thickness", "Bottom shell thickness", 0, 0, 10),
            p("bottom_surface_density", "Bottom surface density", 100, 0, 100),
            c("internal_solid_infill_pattern", "Internal solid infill pattern", "zig-zag", SettingsCatalog.surfacePatterns),
        ]),
        SettingGroup(title: "Infill", settings: [
            p("sparse_infill_density", "Sparse infill density", 15, 0, 100, "How full the inside is. 15% suits most prints."),
            c("sparse_infill_pattern", "Sparse infill pattern", "grid", SettingsCatalog.infillPatterns,
              "Gyroid and cubic are strong in every direction; grid and line are fastest."),
            fp("infill_anchor", "Length of sparse infill anchor", "400%"),
            fp("infill_anchor_max", "Maximum length of the infill anchor", "20"),
            f("infill_direction", "Sparse infill direction", 45, 0, 360, unit: "°", step: 1),
            f("solid_infill_direction", "Solid infill direction", 45, 0, 360, unit: "°", step: 1),
            t("sparse_infill_rotate_template", "Sparse infill rotation template"),
            p("infill_wall_overlap", "Infill/wall overlap", 15, 0, 100),
            p("top_bottom_infill_wall_overlap", "Top/bottom solid infill/wall overlap", 25, 0, 100),
        ]),
        SettingGroup(title: "Advanced", settings: [
            b("align_infill_direction_to_model", "Align infill direction to model"),
            b("infill_combination", "Infill combination", false, "Prints sparse infill every few layers at a thicker height."),
            f("minimum_sparse_infill_area", "Minimum sparse infill threshold", 15, 0, 1000, unit: "mm²", step: 1),
            c("ensure_vertical_shell_thickness", "Ensure vertical shell thickness", "ensure_all", [("none", "None"), ("ensure_critical_only", "Critical only"),
                                                                                                  ("ensure_moderate", "Moderate"), ("ensure_all", "All")]),
            b("detect_floating_vertical_shell", "Detect floating vertical shells", true),
        ]),
    ])

    static let speeds = SettingPage(id: "speed", title: "Speed", icon: "gauge.with.dots.needle.67percent", groups: [
        SettingGroup(title: "First layer speed", settings: [
            speed("initial_layer_speed", "First layer", 50, "Walls and skirt of the first layer."),
            speed("initial_layer_infill_speed", "First layer infill", 105),
            speed("initial_layer_travel_speed", "First layer travel", 200),
            i("slow_down_layers", "Number of slow layers", 0, 0, 100),
        ]),
        SettingGroup(title: "Other layers speed", settings: [
            speed("outer_wall_speed", "Outer wall", 200),
            speed("inner_wall_speed", "Inner wall", 300),
            fp("small_perimeter_speed", "Small perimeters", "50%", unit: "mm/s or %"),
            f("small_perimeter_threshold", "Small perimeter threshold", 0, 0, 100),
            speed("sparse_infill_speed", "Sparse infill", 270),
            speed("internal_solid_infill_speed", "Internal solid infill", 250),
            speed("top_surface_speed", "Top surface", 200),
            speed("gap_infill_speed", "Gap infill", 250),
            speed("support_speed", "Support", 150),
            speed("support_interface_speed", "Support interface", 80),
        ]),
        SettingGroup(title: "Overhang speed", settings: [
            b("enable_overhang_speed", "Slow down for overhangs", true),
            b("slowdown_for_curled_perimeters", "Slow down for curled perimeters"),
            speed("overhang_1_4_speed", "10–25% overhang", 0),
            speed("overhang_2_4_speed", "25–50% overhang", 50),
            speed("overhang_3_4_speed", "50–75% overhang", 30),
            speed("overhang_4_4_speed", "75–100% overhang", 10),
            speed("bridge_speed", "Bridge", 50),
            fp("internal_bridge_speed", "Internal bridge", "150%", unit: "mm/s or %"),
        ]),
        SettingGroup(title: "Travel speed", settings: [
            speed("travel_speed", "Travel", 500),
            speed("travel_speed_z", "Z travel", 0),
        ]),
        SettingGroup(title: "Acceleration", settings: [
            accel("default_acceleration", "Normal printing", 10000),
            accel("outer_wall_acceleration", "Outer wall", 5000),
            accel("inner_wall_acceleration", "Inner wall", 0),
            accel("bridge_acceleration", "Bridge", 0),
            SettingDef(key: "sparse_infill_acceleration", label: "Sparse infill", kind: .floatOrPercent, unit: "mm/s² or %", defaultValue: "100%"),
            SettingDef(key: "internal_solid_infill_acceleration", label: "Internal solid infill", kind: .floatOrPercent, unit: "mm/s² or %", defaultValue: "0"),
            accel("initial_layer_acceleration", "First layer", 500),
            accel("top_surface_acceleration", "Top surface", 2000),
            accel("travel_acceleration", "Travel", 10000),
            b("accel_to_decel_enable", "Enable accel_to_decel"),
            p("accel_to_decel_factor", "accel_to_decel", 50, 1, 100),
        ]),
        SettingGroup(title: "Jerk (XY)", settings: [
            jerk("default_jerk", "Default", 0),
            jerk("outer_wall_jerk", "Outer wall", 9),
            jerk("inner_wall_jerk", "Inner wall", 9),
            jerk("infill_jerk", "Infill", 9),
            jerk("top_surface_jerk", "Top surface", 9),
            jerk("initial_layer_jerk", "First layer", 9),
            jerk("travel_jerk", "Travel", 12),
        ]),
    ])

    static let support = SettingPage(id: "support", title: "Support", icon: "tree", groups: [
        SettingGroup(title: "Support", settings: [
            b("enable_support", "Enable support", false, "Supports aren't generated on iPhone yet; flat prints don't need them."),
            c("support_type", "Type", "normal(auto)", [("normal(auto)", "Normal (auto)"), ("tree(auto)", "Tree (auto)"), ("normal(manual)", "Normal (manual)"),
                                                        ("tree(manual)", "Tree (manual)")]),
            c("support_style", "Style", "default", [("default", "Default"), ("grid", "Grid"), ("snug", "Snug"), ("tree_slim", "Tree slim"),
                                                    ("tree_strong", "Tree strong"), ("tree_hybrid", "Tree hybrid"), ("organic", "Organic")]),
            f("support_threshold_angle", "Threshold angle", 30, 0, 90, unit: "°", step: 1),
            b("support_on_build_plate_only", "On build plate only"),
            b("support_critical_regions_only", "Support critical regions only"),
            b("support_remove_small_overhang", "Remove small overhangs", true),
        ]),
        SettingGroup(title: "Raft", settings: [
            i("raft_layers", "Raft layers", 0, 0, 100),
            f("raft_contact_distance", "Raft contact Z distance", 0.1, 0, 5),
            f("raft_expansion", "Raft expansion", 1.5, 0, 100),
            p("raft_first_layer_density", "First layer density", 90, 10, 100),
            f("raft_first_layer_expansion", "First layer expansion", 2, 0, 100),
        ]),
        SettingGroup(title: "Support filament", settings: [
            i("support_filament", "Support/raft base", 0, 0, 16, "0 means the filament of the object."),
            i("support_interface_filament", "Support/raft interface", 0, 0, 16),
        ]),
        SettingGroup(title: "Support ironing", settings: [
            b("enable_support_ironing", "Ironing support interface"),
            c("support_ironing_pattern", "Pattern", "zig-zag", [("zig-zag", "Rectilinear"), ("concentric", "Concentric")]),
            p("support_ironing_flow", "Flow", 10, 0, 100),
            f("support_ironing_spacing", "Line spacing", 0.1, 0, 1),
        ]),
        SettingGroup(title: "Advanced", settings: [
            f("support_top_z_distance", "Top Z distance", 0.2, 0, 5),
            f("support_bottom_z_distance", "Bottom Z distance", 0.2, 0, 5),
            c("support_base_pattern", "Base pattern", "default", [("default", "Default"), ("rectilinear", "Rectilinear"), ("rectilinear-grid", "Rectilinear grid"),
                                                                  ("honeycomb", "Honeycomb"), ("lightning", "Lightning"), ("hollow", "Hollow")]),
            f("support_base_pattern_spacing", "Base pattern spacing", 2.5, 0, 10),
            f("support_angle", "Pattern angle", 0, 0, 359, unit: "°", step: 1),
            i("support_interface_top_layers", "Top interface layers", 2, 0, 20),
            i("support_interface_bottom_layers", "Bottom interface layers", 2, -1, 20),
            c("support_interface_pattern", "Interface pattern", "auto", [("auto", "Default"), ("rectilinear", "Rectilinear"), ("concentric", "Concentric"),
                                                                         ("rectilinear_interlaced", "Rectilinear interlaced"), ("grid", "Grid")]),
            f("support_interface_spacing", "Top interface spacing", 0.5, 0, 5),
            f("support_bottom_interface_spacing", "Bottom interface spacing", 0.5, 0, 5),
            f("support_expansion", "Normal support expansion", 0, -10, 10),
            f("support_object_xy_distance", "Support/object XY distance", 0.35, 0, 10),
            b("bridge_no_support", "Don't support bridges"),
            b("independent_support_layer_height", "Independent support layer height", true),
        ]),
        SettingGroup(title: "Tree supports", settings: [
            f("tree_support_tip_diameter", "Tip diameter", 0.8, 0, 10),
            f("tree_support_branch_distance", "Branch distance", 5, 0, 100),
            f("tree_support_branch_diameter", "Branch diameter", 2, 0, 100),
            f("tree_support_branch_angle", "Branch angle", 45, 0, 85, unit: "°", step: 1),
            i("tree_support_wall_count", "Support wall loops", 0, 0, 2),
            b("tree_support_auto_brim", "Auto brim width", true),
        ]),
    ])

    static let multimaterial = SettingPage(id: "multimaterial", title: "Multimaterial", icon: "paintpalette", groups: [
        SettingGroup(title: "Prime tower", settings: [
            b("enable_prime_tower", "Enable", false, "Bambu printers on iPhone purge in the chute instead; the U1 primes each head itself."),
            f("prime_tower_width", "Width", 35, 2, 300),
            f("prime_volume", "Prime volume", 45, 0, 1000, unit: "mm³", step: 1),
            f("prime_tower_brim_width", "Brim width", 3, -1, 100),
            f("wipe_tower_rotation_angle", "Rotation angle", 0, 0, 360, unit: "°", step: 1),
        ]),
        SettingGroup(title: "Filament for features", settings: [
            i("wall_filament", "Walls", 1, 1, 16),
            i("sparse_infill_filament", "Infill", 1, 1, 16),
            i("solid_infill_filament", "Solid infill", 1, 1, 16),
        ]),
        SettingGroup(title: "Ooze prevention", settings: [
            b("ooze_prevention", "Enable", false, "Tool changers: idle heads drop to standby temperature."),
            f("standby_temperature_delta", "Temperature variation", -5, -100, 100, unit: "°C", step: 1),
            f("preheat_time", "Preheat time", 30, 0, 600, unit: "s", step: 1),
        ]),
        SettingGroup(title: "Flush options", settings: [
            b("flush_into_infill", "Flush into objects' infill"),
            b("flush_into_objects", "Flush into objects"),
            b("flush_into_support", "Flush into objects' support", true),
            f("flush_multiplier", "Flush multiplier", 1, 0, 5, unit: "×", step: 0.1, tip: "Scales the purge between colour changes."),
        ]),
        SettingGroup(title: "Advanced", settings: [
            b("interface_shells", "Interface shells"),
            f("mmu_segmented_region_max_width", "Maximum width of segmented region", 0, 0, 100),
        ]),
    ])

    static let others = SettingPage(id: "others", title: "Others", icon: "ellipsis.circle", groups: [
        SettingGroup(title: "Skirt", settings: [
            i("skirt_loops", "Skirt loops", 0, 0, 20, "A loop around the parts that primes the nozzle."),
            f("skirt_distance", "Skirt distance", 2, 0, 60),
            i("skirt_height", "Skirt height", 1, 1, 100, unit: "layers"),
            c("draft_shield", "Draft shield", "disabled", [("disabled", "Disabled"), ("enabled", "Enabled")]),
            speed("skirt_speed", "Skirt speed", 50),
        ]),
        SettingGroup(title: "Brim", settings: [
            c("brim_type", "Brim type", "auto_brim", [("auto_brim", "Auto"), ("brim_ears", "Mouse ears"), ("painted", "Painted"), ("outer_only", "Outer brim only"),
                                                      ("inner_only", "Inner brim only"), ("outer_and_inner", "Outer and inner brim"), ("no_brim", "No brim")],
              "A brim helps tall or small-footprint parts stay stuck to the plate."),
            f("brim_width", "Brim width", 5, 0, 100),
            f("brim_object_gap", "Brim-object gap", 0.1, 0, 5),
        ]),
        SettingGroup(title: "Special mode", settings: [
            c("slicing_mode", "Slicing mode", "regular", [("regular", "Regular"), ("even_odd", "Even-odd"), ("close_holes", "Close holes")]),
            c("print_sequence", "Print sequence", "by layer", [("by layer", "By layer"), ("by object", "By object")]),
            b("spiral_mode", "Spiral vase", false, "One continuous wall spiralling up, no top. Not on iPhone yet."),
            c("timelapse_type", "Timelapse", "0", [("0", "Traditional"), ("1", "Smooth")]),
            c("fuzzy_skin", "Fuzzy skin", "none", [("none", "None"), ("external", "Contour"), ("all", "Contour and hole"), ("allwalls", "All walls")],
              "Rough, textured outer walls that hide layer lines."),
            f("fuzzy_skin_thickness", "Fuzzy skin thickness", 0.3, 0, 2),
            f("fuzzy_skin_point_distance", "Fuzzy skin point distance", 0.8, 0.1, 10),
            b("fuzzy_skin_first_layer", "Apply fuzzy skin to first layer"),
        ]),
        SettingGroup(title: "Travel", settings: [
            b("reduce_crossing_wall", "Avoid crossing walls"),
            fp("max_travel_detour_distance", "Avoid crossing walls max detour", "0"),
            b("reduce_infill_retraction", "Reduce infill retraction", true),
        ]),
        SettingGroup(title: "G-code output", settings: [
            b("gcode_label_objects", "Label objects", true),
            b("exclude_object", "Exclude objects", true),
            b("gcode_comments", "Verbose G-code"),
            b("gcode_add_line_number", "Add line number"),
            t("filename_format", "Filename format"),
        ]),
        SettingGroup(title: "Notes", settings: [
            t("process_notes", "Notes"),
        ]),
    ])

    // MARK: filament (per filament)

    static let filamentPage = SettingPage(id: "filament", title: "Filament", icon: "circle.circle", groups: [
        SettingGroup(title: "Nozzle temperature", settings: [
            filament(f("nozzle_temperature_initial_layer", "First layer", 220, 150, 400, unit: "°C", step: 1)),
            filament(f("nozzle_temperature", "Other layers", 220, 150, 400, unit: "°C", step: 1)),
        ]),
        SettingGroup(title: "Bed temperature", settings: [
            filament(f("hot_plate_temp_initial_layer", "Smooth PEI / High Temp, first layer", 55, 0, 120, unit: "°C", step: 1)),
            filament(f("hot_plate_temp", "Smooth PEI / High Temp", 55, 0, 120, unit: "°C", step: 1)),
            filament(f("textured_plate_temp_initial_layer", "Textured PEI, first layer", 55, 0, 120, unit: "°C", step: 1)),
            filament(f("textured_plate_temp", "Textured PEI", 55, 0, 120, unit: "°C", step: 1)),
            filament(f("cool_plate_temp_initial_layer", "Cool Plate, first layer", 35, 0, 120, unit: "°C", step: 1)),
            filament(f("cool_plate_temp", "Cool Plate", 35, 0, 120, unit: "°C", step: 1)),
            filament(f("eng_plate_temp_initial_layer", "Engineering Plate, first layer", 55, 0, 120, unit: "°C", step: 1)),
            filament(f("eng_plate_temp", "Engineering Plate", 55, 0, 120, unit: "°C", step: 1)),
            filament(f("supertack_plate_temp_initial_layer", "Cool Plate SuperTack, first layer", 35, 0, 120, unit: "°C", step: 1)),
            filament(f("supertack_plate_temp", "Cool Plate SuperTack", 35, 0, 120, unit: "°C", step: 1)),
            filament(f("textured_cool_plate_temp_initial_layer", "Textured Cool Plate, first layer", 40, 0, 120, unit: "°C", step: 1)),
            filament(f("textured_cool_plate_temp", "Textured Cool Plate", 40, 0, 120, unit: "°C", step: 1)),
            filament(f("chamber_temperatures", "Chamber", 0, 0, 80, unit: "°C", step: 1)),
        ]),
        SettingGroup(title: "Flow", settings: [
            filament(f("filament_flow_ratio", "Flow ratio", 0.98, 0.5, 1.5, unit: "×", step: 0.01)),
            filament(f("filament_max_volumetric_speed", "Max volumetric speed", 21, 0.5, 100, unit: "mm³/s", step: 0.5,
                       tip: "Caps every speed so the hot end can melt the filament fast enough.")),
            filament(f("filament_flush_volumetric_speed", "Flush volumetric speed", 0, 0, 100, unit: "mm³/s", step: 0.5)),
            filament(f("filament_density", "Density", 1.24, 0.5, 5, unit: "g/cm³", step: 0.01)),
            filament(f("filament_diameter", "Diameter", 1.75, 1, 3, step: 0.01)),
            filament(f("filament_shrink", "Shrinkage", 100, 50, 150, unit: "%", step: 0.1)),
            filament(f("filament_cost", "Price", 20, 0, 1000, unit: "per kg", step: 1)),
        ]),
        SettingGroup(title: "Cooling", settings: [
            filament(i("close_fan_the_first_x_layers", "No cooling for the first", 1, 0, 1000, unit: "layers")),
            filament(i("full_fan_speed_layer", "Full fan speed at layer", 0, 0, 1000)),
            filament(f("fan_min_speed", "Min fan speed", 60, 0, 100, unit: "%", step: 1)),
            filament(f("fan_max_speed", "Max fan speed", 100, 0, 100, unit: "%", step: 1)),
            filament(f("fan_cooling_layer_time", "Fan full speed below layer time", 60, 0, 1000, unit: "s", step: 1)),
            filament(f("slow_down_layer_time", "Slow printing below layer time", 8, 0, 1000, unit: "s", step: 1)),
            filament(f("slow_down_min_speed", "Min print speed", 20, 0, 1000, unit: "mm/s", step: 1)),
            filament(f("overhang_fan_speed", "Overhang fan speed", 100, 0, 100, unit: "%", step: 1)),
            filament(f("additional_cooling_fan_speed", "Auxiliary part fan", 0, 0, 100, unit: "%", step: 1)),
            filament(f("temperature_vitrification", "Softening temperature", 45, 0, 300, unit: "°C", step: 1)),
        ]),
        SettingGroup(title: "Retraction (overrides the printer)", settings: [
            filament(f("filament_retraction_length", "Length", 0.8, 0, 20)),
            filament(f("filament_z_hop", "Z hop", 0.4, 0, 5)),
            filament(f("filament_retraction_speed", "Retraction speed", 30, 0, 200, unit: "mm/s", step: 1)),
            filament(f("filament_deretraction_speed", "Deretraction speed", 30, 0, 200, unit: "mm/s", step: 1)),
            filament(f("filament_retraction_minimum_travel", "Minimum travel", 1, 0, 100)),
        ]),
    ], scope: .filament)

    static let processPages: [SettingPage] = [quality, strength, speeds, support, multimaterial, others]
    static let pages: [SettingPage] = processPages + [filamentPage]

    static let byKey: [String: SettingDef] = {
        var d: [String: SettingDef] = [:]
        for p in pages { for s in p.settings where d[s.key] == nil { d[s.key] = s } }
        return d
    }()

    /// The first page a setting appears on (a few appear on two, as in OrcaSlicer).
    static let ownerPage: [String: String] = {
        var d: [String: String] = [:]
        for p in pages { for s in p.settings where d[s.key] == nil { d[s.key] = p.id } }
        return d
    }()

    static func page(_ id: String) -> SettingPage? { pages.first { $0.id == id } }
}
