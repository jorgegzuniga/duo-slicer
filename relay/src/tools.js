// Tools Duo Slicer offers Claude. The iPhone app implements them (App/ClaudeTools.swift); names and arguments must match.

const plate = { type: "integer", description: "Plate number as shown in the app (Plate 1, Plate 2, …). Default: the current plate." };
const object = {
  anyOf: [{ type: "integer" }, { type: "string" }],
  description: "Object index from get_project, or the object's name.",
};
const printer = { type: "string", description: "A saved printer's name (from list_printers). Default: the selected printer." };

export const TOOLS = [
  {
    name: "list_projects",
    title: "List projects",
    description: "Projects saved in Duo Slicer on the user's iPhone, and the one that's open.",
    inputSchema: { type: "object", properties: {} },
    annotations: { readOnlyHint: true },
  },
  {
    name: "open_project",
    title: "Open project",
    description: "Open a saved project by name (from list_projects). Returns the same details as get_project.",
    inputSchema: { type: "object", properties: { name: { type: "string" } }, required: ["name"] },
  },
  {
    name: "get_project",
    title: "Get project",
    description:
      "The open project: its plates (numbered as in the app) with objects, sizes and whether they fit the printer, the filaments, " +
      "the printer it is sliced for, current settings, Snapmaker U1 head assignments and the latest slice result.",
    inputSchema: { type: "object", properties: {} },
    annotations: { readOnlyHint: true },
  },
  {
    name: "select_plate",
    title: "Select plate",
    description: "Make a plate the current one.",
    inputSchema: { type: "object", properties: { plate }, required: ["plate"] },
  },
  {
    name: "list_presets",
    title: "List presets",
    description:
      "Quality presets and build plate types for the printer being sliced for (kind: process), or filament presets (kind: filament, with an optional search).",
    inputSchema: {
      type: "object",
      properties: { kind: { type: "string", enum: ["process", "filament"] }, search: { type: "string" } },
    },
    annotations: { readOnlyHint: true },
  },
  {
    name: "set_settings",
    title: "Change settings",
    description:
      "Change slicing settings for the open project. process: quality preset name (see list_presets). bed_type: build plate. " +
      "overrides: settings by key, for example layer_height (mm), wall_loops, top_shell_layers, bottom_shell_layers, " +
      "sparse_infill_density (\"20%\"), sparse_infill_pattern (grid, line, zig-zag), brim_type (no_brim, outer_only, auto_brim), " +
      "brim_width (mm), skirt_loops, outer_wall_speed (mm/s); null puts a key back to the preset value. " +
      "filament_presets and colors map a filament number to a preset name or a #RRGGBB colour. Slice again afterwards.",
    inputSchema: {
      type: "object",
      properties: {
        process: { type: "string" },
        bed_type: { type: "string" },
        overrides: { type: "object", additionalProperties: { type: ["string", "number", "null"] } },
        filament_presets: { type: "object", additionalProperties: { type: "string" } },
        colors: { type: "object", additionalProperties: { type: "string" } },
      },
    },
  },
  {
    name: "rotate_object",
    title: "Rotate object",
    description: "Rotate an object about its centre and set it back down on the bed.",
    inputSchema: {
      type: "object",
      properties: { object, axis: { type: "string", enum: ["x", "y", "z"] }, degrees: { type: "number" } },
      required: ["object", "axis", "degrees"],
    },
  },
  {
    name: "lay_flat",
    title: "Lay flat",
    description: "Put an object's largest flat face down on the bed.",
    inputSchema: { type: "object", properties: { object }, required: ["object"] },
  },
  {
    name: "reset_object",
    title: "Reset object",
    description: "Undo rotations and moves of an object.",
    inputSchema: { type: "object", properties: { object }, required: ["object"] },
  },
  {
    name: "center_plate",
    title: "Center plate",
    description: "Move a plate's objects to the middle of the printer's bed (useful when a plate doesn't fit after switching printers).",
    inputSchema: { type: "object", properties: { plate } },
  },
  {
    name: "move_object",
    title: "Move object",
    description:
      "Move an object on its plate: x and y put the middle of its footprint at that spot on the bed (mm, printer coordinates; " +
      "the result shows the bed's range), or dx and dy move it by that much. Returns where it ended up and whether it fits.",
    inputSchema: {
      type: "object",
      properties: { object, x: { type: "number" }, y: { type: "number" }, dx: { type: "number" }, dy: { type: "number" } },
      required: ["object"],
    },
  },
  {
    name: "arrange_plate",
    title: "Arrange plate",
    description:
      "Pack a plate's objects neatly on the bed, clear of each other and of no-print areas. allow_rotation also turns parts " +
      "by 90° to fit more. Returns the new positions and any objects that didn't fit (move those with move_to_plate).",
    inputSchema: { type: "object", properties: { plate, allow_rotation: { type: "boolean" } } },
  },
  {
    name: "move_to_plate",
    title: "Move to another plate",
    description: "Move an object to another plate (by number), or to a new plate when plate is left out. It's placed where it fits.",
    inputSchema: { type: "object", properties: { object, plate: { type: "integer" } }, required: ["object"] },
  },
  {
    name: "set_toolheads",
    title: "Assign toolheads",
    description: "Snapmaker U1 only: choose which head (1–4) prints each filament on the current plate. Slice again afterwards.",
    inputSchema: {
      type: "object",
      properties: {
        assignments: {
          type: "array",
          items: { type: "object", properties: { filament: { type: "integer" }, head: { type: "integer" } }, required: ["filament", "head"] },
        },
      },
      required: ["assignments"],
    },
  },
  {
    name: "slice_plate",
    title: "Slice plate",
    description:
      "Slice a plate for the selected printer. Returns print time, grams per filament, layers, colour changes and warnings. " +
      "Takes from a few seconds to about a minute on the phone.",
    inputSchema: { type: "object", properties: { plate } },
  },
  {
    name: "get_layer_preview",
    title: "Layer preview",
    description: "Top-down picture of one sliced layer (1-based; default: the last layer) of the current slice.",
    inputSchema: { type: "object", properties: { layer: { type: "integer" } } },
    annotations: { readOnlyHint: true },
  },
  {
    name: "get_plate_image",
    title: "Plate picture",
    description: "The designer's picture of a plate, from the project file.",
    inputSchema: { type: "object", properties: { plate } },
    annotations: { readOnlyHint: true },
  },
  {
    name: "list_printers",
    title: "List printers",
    description:
      "Every printer saved in Duo Slicer with its live state (Duo Slicer stays connected to all of them): printing progress, " +
      "temperatures, errors, the queued print it's on. Also which one is selected and every printer model the app can slice for.",
    inputSchema: { type: "object", properties: {} },
    annotations: { readOnlyHint: true },
  },
  {
    name: "select_printer",
    title: "Select printer",
    description: "Select a saved printer by name (or, with none saved, a printer model to slice for). Plates are then sliced for it.",
    inputSchema: { type: "object", properties: { printer: { type: "string" } }, required: ["printer"] },
  },
  {
    name: "get_printer_status",
    title: "Printer status",
    description:
      "One printer (default: the selected one): connection, state, progress, layer, temperatures, and what's loaded (Bambu AMS slots with ids, or Snapmaker U1 heads).",
    inputSchema: { type: "object", properties: { printer } },
    annotations: { readOnlyHint: true },
  },
  {
    name: "get_camera_image",
    title: "Camera picture",
    description: "A fresh picture from a printer's camera (default: the selected printer), to check on a print or whether the bed is clear.",
    inputSchema: { type: "object", properties: { printer } },
    annotations: { readOnlyHint: true },
  },
  {
    name: "start_print",
    title: "Start print",
    description:
      "Print a plate on the selected printer (slices it first if needed). The user has to approve on their phone, where they also confirm " +
      "the bed is clear; this waits up to two minutes for them. Bambu printers: optional spools [{filament, slot}] with AMS slot ids from " +
      "get_printer_status (254 = external spool); otherwise spools are matched by colour.",
    inputSchema: {
      type: "object",
      properties: {
        plate,
        printer,
        spools: {
          type: "array",
          items: { type: "object", properties: { filament: { type: "integer" }, slot: { type: "integer" } }, required: ["filament", "slot"] },
        },
      },
    },
    annotations: { openWorldHint: true },
  },
  {
    name: "control_print",
    title: "Pause, resume or stop",
    description: "Pause, resume or stop the current print on a printer (default: the selected one). Stopping asks the user on their phone first.",
    inputSchema: {
      type: "object",
      properties: { action: { type: "string", enum: ["pause", "resume", "stop"] }, printer },
      required: ["action"],
    },
    annotations: { destructiveHint: true, openWorldHint: true },
  },
  {
    name: "get_queue",
    title: "Print queue",
    description:
      "The print queue: each job (id, project, plate, printer, status: waiting, slicing, sending, printing, done or failed), whether it's " +
      "running, and printers waiting for the user to clear their bed.",
    inputSchema: { type: "object", properties: {} },
    annotations: { readOnlyHint: true },
  },
  {
    name: "add_to_queue",
    title: "Add to print queue",
    description:
      "Queue plates of the open project as it is now (its settings and changes are kept): plates by number, or all_plates; copies of each; " +
      "printer to tie them to one saved printer (default: whichever printer of the project's model is free first). " +
      "Plates are sliced when a printer is ready for them.",
    inputSchema: {
      type: "object",
      properties: {
        plates: { type: "array", items: { type: "integer" } },
        all_plates: { type: "boolean" },
        copies: { type: "integer", minimum: 1, maximum: 50 },
        printer,
      },
    },
  },
  {
    name: "remove_from_queue",
    title: "Remove from queue",
    description: "Remove a job from the print queue by its id from get_queue. A print that's already printing keeps printing.",
    inputSchema: { type: "object", properties: { job: { type: "string" } }, required: ["job"] },
  },
  {
    name: "start_queue",
    title: "Start print queue",
    description:
      "Start (or resume) the print queue. The user confirms on their phone that the free printers' beds are clear; this waits up to " +
      "two minutes. Later, each printer that finishes waits for the user to say its bed is clear before its next print.",
    inputSchema: { type: "object", properties: {} },
    annotations: { openWorldHint: true },
  },
  {
    name: "pause_queue",
    title: "Pause print queue",
    description: "Stop sending new prints from the queue. Prints already sent keep printing.",
    inputSchema: { type: "object", properties: {} },
  },
];

// How long the relay waits for the phone (ms).
export const TIMEOUTS = {
  slice_plate: 150000,
  start_print: 200000,
  control_print: 140000,
  open_project: 60000,
  get_camera_image: 40000,
  add_to_queue: 60000,
  start_queue: 140000,
  arrange_plate: 60000,
};
export const DEFAULT_TIMEOUT = 30000;

export const INSTRUCTIONS =
  "Duo Slicer is a 3D-printing slicer running on the user's iPhone; these tools reach it while the app is open. " +
  "Typical flow: list_projects / open_project or get_project, adjust (set_settings, rotate_object, lay_flat, move_object, arrange_plate, " +
  "move_to_plate, center_plate, set_toolheads on a Snapmaker U1), slice_plate, look at get_layer_preview, then start_print, which the " +
  "user approves on the phone. Plates are numbered as in the app. Prints go to the printer selected in the app (list_printers / " +
  "select_printer); list_printers shows every printer's live state and get_camera_image shows a printer's camera. To print several " +
  "plates, copies or projects one after another, add_to_queue each, then start_queue; get_queue follows it.";
