// Smoke test against `wrangler dev` (default http://127.0.0.1:8787): a fake phone answers tool calls,
// and MCP requests go through the relay the way claude.ai sends them.
//   npx wrangler dev --port 8787 &   then   node test/smoke.mjs [base]
const base = process.argv[2] || "http://127.0.0.1:8787";
const token = "test_" + "x".repeat(40);
const mcp = `${base}/mcp/${token}`;
let failures = 0;
const check = (name, ok, extra = "") => {
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${extra ? " — " + extra : ""}`);
  if (!ok) failures++;
};
const post = async (body, headers = {}) => {
  const r = await fetch(mcp, {
    method: "POST",
    headers: { "content-type": "application/json", accept: "application/json, text/event-stream", ...headers },
    body: JSON.stringify(body),
  });
  const text = await r.text();
  return { status: r.status, body: text ? JSON.parse(text) : null, type: r.headers.get("content-type") };
};

// 1. MCP handshake without the phone
let r = await post({ jsonrpc: "2.0", id: 1, method: "initialize", params: { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "smoke", version: "1" } } });
check("initialize", r.status === 200 && r.body.result.protocolVersion === "2025-06-18" && r.body.result.capabilities.tools, JSON.stringify(r.body).slice(0, 120));
r = await post({ jsonrpc: "2.0", method: "notifications/initialized" });
check("initialized notification -> 202", r.status === 202);
r = await post({ jsonrpc: "2.0", id: 2, method: "tools/list" });
check("tools/list", r.body.result.tools.length >= 19 && r.body.result.tools.every((t) => t.name && t.inputSchema), `${r.body.result.tools.length} tools`);
r = await post({ jsonrpc: "2.0", id: 3, method: "tools/call", params: { name: "get_project", arguments: {} } });
check("call while the phone is offline", r.body.result.isError === true && /isn't connected/.test(r.body.result.content[0].text));
r = await post({ jsonrpc: "2.0", id: 4, method: "tools/call", params: { name: "nope", arguments: {} } });
check("unknown tool -> JSON-RPC error", r.body.error && r.body.error.code === -32602);
const g = await fetch(mcp);
check("GET -> 405", g.status === 405);
const bad = await fetch(`${base}/mcp/short`, { method: "POST", body: "{}" });
check("short token -> 404", bad.status === 404);

// 2. fake phone
const ws = new WebSocket(`${base.replace("http", "ws")}/device?token=${token}`);
await new Promise((res, rej) => { ws.onopen = res; ws.onerror = rej; });
ws.send(JSON.stringify({ type: "hello", app: "smoke", version: "1" }));
const calls = [];
ws.onmessage = (ev) => {
  const m = JSON.parse(ev.data);
  if (m.type === "pong") { calls.push("pong"); return; }
  calls.push(m.params.name);
  if (m.params.name === "slice_plate") {
    setTimeout(() => ws.send(JSON.stringify({ id: m.id, result: { content: [{ type: "text", text: "sliced plate " + m.params.arguments.plate }] } })), 300);
  } else if (m.params.name === "get_layer_preview") {
    ws.send(JSON.stringify({ id: m.id, result: { content: [{ type: "image", data: "iVBORw0KGgo=", mimeType: "image/png" }, { type: "text", text: "layer" }] } }));
  } else {
    ws.send(JSON.stringify({ id: m.id, result: { content: [{ type: "text", text: "echo " + JSON.stringify(m.params.arguments) }] } }));
  }
};
ws.send('{"type":"ping"}');
await new Promise((res) => setTimeout(res, 300));
check("ping answered", calls.includes("pong"));

r = await post({ jsonrpc: "2.0", id: 5, method: "tools/call", params: { name: "get_project", arguments: {} } });
check("call reaches the phone", r.body.result && r.body.result.content[0].text === "echo {}", JSON.stringify(r.body).slice(0, 120));
r = await post({ jsonrpc: "2.0", id: 6, method: "tools/call", params: { name: "slice_plate", arguments: { plate: 2 } } });
check("slow call waits", r.body.result.content[0].text === "sliced plate 2");
r = await post({ jsonrpc: "2.0", id: 7, method: "tools/call", params: { name: "get_layer_preview", arguments: {} } });
check("image result passes through", r.body.result.content[0].type === "image" && r.body.result.content[0].mimeType === "image/png");
r = await post([
  { jsonrpc: "2.0", id: 8, method: "ping" },
  { jsonrpc: "2.0", id: 9, method: "tools/call", params: { name: "list_printers", arguments: {} } },
]);
check("batch", Array.isArray(r.body) && r.body.length === 2 && r.body[1].result.content[0].text === "echo {}");

// 3. a second phone connection replaces the first
const ws2 = new WebSocket(`${base.replace("http", "ws")}/device?token=${token}`);
await new Promise((res, rej) => { ws2.onopen = res; ws2.onerror = rej; });
const closed = await new Promise((res) => { ws.onclose = (e) => res(e.code); setTimeout(() => res(-1), 2000); });
check("older connection closed", closed === 4000, `code ${closed}`);
ws2.onmessage = (ev) => {
  const m = JSON.parse(ev.data);
  ws2.send(JSON.stringify({ id: m.id, result: { content: [{ type: "text", text: "second" }] } }));
};
r = await post({ jsonrpc: "2.0", id: 10, method: "tools/call", params: { name: "get_printer_status", arguments: {} } });
check("newest connection answers", r.body.result.content[0].text === "second");
ws2.close();
await new Promise((res) => setTimeout(res, 300));
r = await post({ jsonrpc: "2.0", id: 11, method: "tools/call", params: { name: "get_printer_status", arguments: {} } });
check("offline again after the phone leaves", r.body.result.isError === true);

console.log(failures ? `${failures} failed` : "relay smoke test passed");
process.exit(failures ? 1 : 0);
