// End-to-end: Claude-style MCP calls through a local relay (wrangler dev) to the real app running in the simulator.
//   node test/app-e2e.mjs <base> <secret> <out-dir>
// The app must be launched with -DuoDemo YES -DuoDemoPrinter snapmaker-u1 -DuoClaudeRelay <base> -DuoClaudeSecret <secret>.
import { writeFileSync } from "node:fs";

const [base = "http://127.0.0.1:8787", secret, out = "."] = process.argv.slice(2);
const mcp = `${base}/mcp/${secret}`;
let failures = 0;
let id = 0;
const log = [];
const check = (name, ok, extra = "") => {
  const line = `${ok ? "ok  " : "FAIL"} ${name}${extra ? " — " + extra : ""}`;
  console.log(line);
  log.push(line);
  if (!ok) failures++;
};
async function call(name, args = {}) {
  const r = await fetch(mcp, {
    method: "POST",
    headers: { "content-type": "application/json", accept: "application/json, text/event-stream" },
    body: JSON.stringify({ jsonrpc: "2.0", id: ++id, method: "tools/call", params: { name, arguments: args } }),
  });
  const body = await r.json();
  return body.result || { isError: true, content: [{ type: "text", text: JSON.stringify(body.error) }] };
}
const text = (r) => (r.content || []).filter((c) => c.type === "text").map((c) => c.text).join("\n");
const json = (r) => {
  try {
    return JSON.parse(text(r));
  } catch (_) {
    return null;
  }
};

// wait for the app to connect
let ready = false;
for (let i = 0; i < 60 && !ready; i++) {
  const r = await call("list_projects");
  if (!r.isError) ready = true;
  else await new Promise((res) => setTimeout(res, 3000));
}
check("app connected to the relay", ready);
if (!ready) {
  writeFileSync(`${out}/claude-e2e.txt`, log.join("\n") + "\n");
  process.exit(1);
}

let r = await call("get_project");
let p = json(r);
check("get_project", p && p.project === "Duo demo" && p.plates.length === 2, text(r).slice(0, 160));
check("slicing for the U1", p && /U1/.test(p.slicing_for), p && p.slicing_for);

r = await call("list_presets", { kind: "process" });
check("list_presets", json(r) && json(r).processes.length > 3);

r = await call("set_settings", { overrides: { sparse_infill_density: "25%", wall_loops: 3 } });
check("set_settings", !r.isError && /sparse_infill_density/.test(text(r)), text(r).slice(0, 200));

r = await call("set_toolheads", { assignments: [{ filament: 2, head: 4 }] });
check("set_toolheads", !r.isError && /"head" : 4|"head": 4/.test(text(r)), text(r).slice(0, 200));

r = await call("rotate_object", { object: "Coaster", axis: "z", degrees: 30 });
check("rotate_object", !r.isError && json(r) && json(r).fits === true, text(r).slice(0, 160));

r = await call("slice_plate", { plate: 1 });
const s = json(r);
check("slice_plate", !r.isError && s && s.layers > 10 && s.grams > 1, text(r).slice(0, 300));
check("head assignment used", s && s.filaments.some((f) => f.filament === 2 && f.head === 4), JSON.stringify(s && s.filaments));

r = await call("get_layer_preview", { layer: 16 });
const img = (r.content || []).find((c) => c.type === "image");
check("get_layer_preview returns a PNG", img && Buffer.from(img.data, "base64").subarray(1, 4).toString() === "PNG");
if (img) writeFileSync(`${out}/claude-layer-preview.png`, Buffer.from(img.data, "base64"));

r = await call("get_plate_image", { plate: 2 });
check("get_plate_image", (r.content || []).some((c) => c.type === "image"));

r = await call("select_plate", { plate: 2 });
check("select_plate", !r.isError && /Plate 2/.test(text(r)), text(r));

r = await call("center_plate", {});
check("center_plate", !r.isError && json(r) && json(r).fits === true, text(r).slice(0, 160));

r = await call("list_printers");
check("list_printers", json(r) && json(r).supported_models.length === 11, text(r).slice(0, 200));

r = await call("get_printer_status");
check("get_printer_status", !r.isError && json(r) && "connected" in json(r), text(r).slice(0, 200));

r = await call("start_print", { plate: 1 });
check("start_print refuses without a connected printer", r.isError === true && /isn't connected|No printer/.test(text(r)), text(r).slice(0, 200));

r = await call("control_print", { action: "pause" });
check("control_print without a printer", r.isError === true, text(r).slice(0, 160));

r = await call("open_project", { name: "nope-not-here" });
check("open_project with a bad name", r.isError === true, text(r).slice(0, 160));

console.log(failures ? `${failures} failed` : "app end-to-end passed");
writeFileSync(`${out}/claude-e2e.txt`, log.join("\n") + `\n${failures ? failures + " failed" : "app end-to-end passed"}\n`);
process.exit(failures ? 1 : 0);
