// Duo Slicer relay.
//   claude.ai (MCP, Streamable HTTP)  ->  POST /mcp/<secret>
//   Duo Slicer on the iPhone          ->  WebSocket /device?token=<secret>
// Each secret gets its own Durable Object, which forwards tool calls to the phone and waits for the answer.
import { DurableObject } from "cloudflare:workers";
import { TOOLS, TIMEOUTS, DEFAULT_TIMEOUT, INSTRUCTIONS } from "./tools.js";

const VERSIONS = ["2025-06-18", "2025-03-26", "2024-11-05"];
const TOKEN = /^[A-Za-z0-9_-]{32,128}$/;
const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "POST, GET, DELETE, OPTIONS",
  "Access-Control-Allow-Headers": "content-type, accept, authorization, mcp-session-id, mcp-protocol-version",
  "Access-Control-Expose-Headers": "mcp-session-id",
};
const OFFLINE =
  "Duo Slicer isn't connected. Ask the user to open Duo Slicer on their iPhone (Use with Claude must be on), then try again.";

async function roomFor(env, token) {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(token));
  const hex = [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
  return env.RELAY.get(env.RELAY.idFromName(hex));
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (request.method === "OPTIONS") return new Response(null, { status: 204, headers: CORS });
    if (url.pathname === "/" || url.pathname === "") {
      return new Response("Duo Slicer relay. Add <this address>/mcp/<your key> as a custom connector in Claude; the key is in the app.\n", {
        headers: { "content-type": "text/plain; charset=utf-8" },
      });
    }
    if (url.pathname === "/device") {
      const token = url.searchParams.get("token") || "";
      if (!TOKEN.test(token)) return new Response("bad token", { status: 403 });
      return (await roomFor(env, token)).fetch(request);
    }
    const m = url.pathname.match(/^\/mcp\/([A-Za-z0-9_-]+)\/?$/);
    if (m) {
      if (!TOKEN.test(m[1])) return new Response("not found", { status: 404, headers: CORS });
      return (await roomFor(env, m[1])).fetch(request);
    }
    return new Response("not found", { status: 404 });
  },
};

function rpcResult(id, result) {
  return { jsonrpc: "2.0", id, result };
}
function rpcError(id, code, message) {
  return { jsonrpc: "2.0", id, error: { code, message } };
}
function json(body, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json", ...CORS } });
}

export class Relay extends DurableObject {
  constructor(ctx, env) {
    super(ctx, env);
    this.pending = new Map();
    this.seq = 0;
    // keep-alive pings from the app are answered without waking the object
    this.ctx.setWebSocketAutoResponse(new WebSocketRequestResponsePair('{"type":"ping"}', '{"type":"pong"}'));
  }

  async fetch(request) {
    const url = new URL(request.url);
    if (url.pathname === "/device") {
      if (request.headers.get("Upgrade") !== "websocket") return new Response("expected a WebSocket", { status: 426 });
      for (const old of this.ctx.getWebSockets("device")) {
        try {
          old.close(4000, "replaced by a newer connection");
        } catch (_) {}
      }
      const pair = new WebSocketPair();
      this.ctx.acceptWebSocket(pair[1], ["device"]);
      return new Response(null, { status: 101, webSocket: pair[0] });
    }
    return this.mcp(request);
  }

  // ---- phone side

  async webSocketMessage(ws, message) {
    let m;
    try {
      m = JSON.parse(typeof message === "string" ? message : new TextDecoder().decode(message));
    } catch (_) {
      return;
    }
    if (m && m.type === "hello") {
      ws.serializeAttachment({ app: m.app, version: m.version, since: Date.now() });
      return;
    }
    const p = m && m.id !== undefined ? this.pending.get(m.id) : undefined;
    if (p) {
      this.pending.delete(m.id);
      p.resolve(m);
    }
  }

  async webSocketClose(ws, code, reason) {
    try {
      ws.close(code, reason);
    } catch (_) {}
    if (this.ctx.getWebSockets("device").length === 0) {
      for (const [id, p] of this.pending) {
        this.pending.delete(id);
        p.reject(new Error("offline"));
      }
    }
  }

  async webSocketError(ws) {
    try {
      ws.close(1011, "error");
    } catch (_) {}
  }

  device() {
    const all = this.ctx.getWebSockets("device");
    return all.length ? all[all.length - 1] : null;
  }

  callDevice(name, args, timeoutMs) {
    const ws = this.device();
    if (!ws) return Promise.reject(new Error("offline"));
    const id = `c${Date.now().toString(36)}-${++this.seq}`;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error("timeout"));
      }, timeoutMs);
      this.pending.set(id, {
        resolve: (m) => {
          clearTimeout(timer);
          resolve(m);
        },
        reject: (e) => {
          clearTimeout(timer);
          reject(e);
        },
      });
      try {
        ws.send(JSON.stringify({ id, method: "tools/call", params: { name, arguments: args } }));
      } catch (e) {
        this.pending.delete(id);
        clearTimeout(timer);
        reject(new Error("offline"));
      }
    });
  }

  // ---- Claude side (MCP over Streamable HTTP, JSON responses)

  async mcp(request) {
    if (request.method === "GET") return new Response("This MCP server answers POST requests only.", { status: 405, headers: { Allow: "POST", ...CORS } });
    if (request.method === "DELETE") return new Response(null, { status: 204, headers: CORS });
    if (request.method !== "POST") return new Response(null, { status: 405, headers: { Allow: "POST", ...CORS } });
    let body;
    try {
      body = await request.json();
    } catch (_) {
      return json(rpcError(null, -32700, "Parse error"), 400);
    }
    const batch = Array.isArray(body) ? body : [body];
    const out = [];
    for (const msg of batch) {
      const r = await this.handle(msg);
      if (r) out.push(r);
    }
    if (out.length === 0) return new Response(null, { status: 202, headers: CORS });
    return json(Array.isArray(body) ? out : out[0]);
  }

  async handle(msg) {
    if (!msg || typeof msg !== "object" || msg.jsonrpc !== "2.0") return rpcError(msg && msg.id !== undefined ? msg.id : null, -32600, "Invalid Request");
    const isRequest = msg.id !== undefined && msg.id !== null;
    if (!isRequest) return null; // notifications (initialized, cancelled) and responses need no answer
    switch (msg.method) {
      case "initialize": {
        const asked = msg.params && msg.params.protocolVersion;
        return rpcResult(msg.id, {
          protocolVersion: VERSIONS.includes(asked) ? asked : VERSIONS[0],
          capabilities: { tools: { listChanged: false } },
          serverInfo: { name: "duo-slicer", title: "Duo Slicer", version: "1.0.0" },
          instructions: INSTRUCTIONS,
        });
      }
      case "ping":
        return rpcResult(msg.id, {});
      case "tools/list":
        return rpcResult(msg.id, { tools: TOOLS });
      case "tools/call": {
        const name = msg.params && msg.params.name;
        const args = (msg.params && msg.params.arguments) || {};
        if (!TOOLS.some((t) => t.name === name)) return rpcError(msg.id, -32602, `Unknown tool: ${name}`);
        try {
          const reply = await this.callDevice(name, args, TIMEOUTS[name] || DEFAULT_TIMEOUT);
          if (reply.error) return rpcResult(msg.id, { content: [{ type: "text", text: String(reply.error.message || reply.error) }], isError: true });
          const result = reply.result && Array.isArray(reply.result.content) ? reply.result : { content: [{ type: "text", text: "Done." }] };
          return rpcResult(msg.id, result);
        } catch (e) {
          const text =
            e.message === "offline"
              ? OFFLINE
              : "Duo Slicer didn't answer in time. It may still be working (slicing or waiting for the user); check with get_project or get_printer_status.";
          return rpcResult(msg.id, { content: [{ type: "text", text }], isError: true });
        }
      }
      case "resources/list":
        return rpcResult(msg.id, { resources: [] });
      case "prompts/list":
        return rpcResult(msg.id, { prompts: [] });
      default:
        return rpcError(msg.id, -32601, `Method not found: ${msg.method}`);
    }
  }
}
