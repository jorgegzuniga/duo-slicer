// Drives Xcode's Device Hub (the Simulator app) through System Events, for CI on the iPhone Duo.
// simctl has no way to unfold the Duo yet, so this looks for the posture controls in the app's menus and window
// (Device Hub shows them as a floating bar under the device: folded, half open, open).
//   osascript -l JavaScript ci/device-hub.js dump <bundle id>
//   osascript -l JavaScript ci/device-hub.js click-menu <bundle id>
//   osascript -l JavaScript ci/device-hub.js click-ui <bundle id> <n>    (n-th control that looks like a posture control)
//   osascript -l JavaScript ci/device-hub.js click-at <x> <y>           (a mouse click at screen coordinates)
ObjC.import("CoreGraphics");

const POSTURE = /unfold|posture|flat|fully open|^open|open$|book|tent|half|tabletop|laptop/i;
const FULLY_OPEN = /unfold|flat|fully open|^open|open$|book/i;

function safe(f) {
  try {
    const v = f();
    return v === null || v === undefined ? "" : String(v);
  } catch (e) {
    return "";
  }
}

function windowCount(p) {
  try {
    return p.windows().length;
  } catch (e) {
    return -1;
  }
}

// Device Hub runs as a trampoline plus the app itself; use the one with windows.
function candidates(se, bid) {
  const out = [];
  for (const p of se.processes()) {
    const name = safe(() => p.name());
    const id = safe(() => p.bundleIdentifier());
    if (id === bid || /device ?hub|simulator/i.test(name)) out.push({ p, name, id, windows: windowCount(p) });
  }
  out.sort((a, b) => b.windows - a.windows);
  return out;
}

function menus(p) {
  const out = [];
  let bar = [];
  try {
    bar = p.menuBars[0].menuBarItems();
  } catch (e) {}
  for (const mb of bar) {
    const items = [];
    let mis = [];
    try {
      mis = mb.menus[0].menuItems();
    } catch (e) {}
    for (const mi of mis) {
      let subEls = [];
      try {
        if (mi.menus.length) subEls = mi.menus[0].menuItems();
      } catch (e) {}
      const key = safe(() => mi.attributes["AXMenuItemCmdChar"].value());
      const mods = safe(() => mi.attributes["AXMenuItemCmdModifiers"].value());
      items.push({ el: mi, name: safe(() => mi.name()), key, mods, subEls, sub: subEls.map((s) => safe(() => s.name())) });
    }
    out.push({ name: safe(() => mb.name()), items });
  }
  return out;
}

function controls(p) {
  const out = [];
  let wins = [];
  try {
    wins = p.windows();
  } catch (e) {}
  for (const w of wins) {
    let all = [];
    try {
      all = w.entireContents();
    } catch (e) {}
    for (const e of all) {
      out.push({
        el: e,
        window: safe(() => w.name()),
        role: safe(() => e.role()),
        name: safe(() => e.name()),
        desc: safe(() => e.description()),
        help: safe(() => e.help()),
        title: safe(() => e.title()),
        value: safe(() => e.value()).slice(0, 60),
        pos: safe(() => e.position()),
        size: safe(() => e.size()),
      });
    }
  }
  return out;
}

function clickAt(x, y) {
  const pt = { x: x, y: y };
  $.CGEventPost($.kCGHIDEventTap, $.CGEventCreateMouseEvent(null, $.kCGEventMouseMoved, pt, $.kCGMouseButtonLeft));
  delay(0.2);
  $.CGEventPost($.kCGHIDEventTap, $.CGEventCreateMouseEvent(null, $.kCGEventLeftMouseDown, pt, $.kCGMouseButtonLeft));
  delay(0.1);
  $.CGEventPost($.kCGHIDEventTap, $.CGEventCreateMouseEvent(null, $.kCGEventLeftMouseUp, pt, $.kCGMouseButtonLeft));
}

function run(argv) {
  const [mode, a1, a2] = argv;
  if (mode === "click-at") {
    clickAt(parseFloat(a1), parseFloat(a2));
    return `clicked at ${a1}, ${a2}`;
  }
  const se = Application("System Events");
  const all = candidates(se, a1);
  if (!all.length) return "no process for " + a1;
  const p = all[0].p;
  try {
    p.frontmost = true;
  } catch (e) {}
  delay(1);

  if (mode === "dump") {
    const lines = all.map((c) => `process: ${c.name} (${c.id}), windows: ${c.windows}`);
    for (const m of menus(p)) {
      lines.push(
        "MENU " + m.name + ": " +
          m.items.map((i) => i.name + (i.key ? ` [${i.mods}+${i.key}]` : "") + (i.sub.length ? " > [" + i.sub.join(", ") + "]" : "")).join(" | ")
      );
    }
    for (const c of controls(p)) {
      if (!c.name && !c.desc && !c.help && !c.title && !/button|radio|check|segment/i.test(c.role)) continue;
      lines.push(`${c.window} :: ${c.role} name=[${c.name}] desc=[${c.desc}] help=[${c.help}] title=[${c.title}] value=[${c.value}] pos=[${c.pos}] size=[${c.size}]`);
    }
    return lines.join("\n");
  }

  if (mode === "click-menu") {
    for (const m of menus(p)) {
      for (const i of m.items) {
        if (i.sub.length && /posture|fold|hinge|lid/i.test(i.name)) {
          for (let k = 0; k < i.sub.length; k++) {
            if (FULLY_OPEN.test(i.sub[k]) && !/half|partial/i.test(i.sub[k])) {
              i.subEls[k].click();
              return `clicked menu ${m.name} > ${i.name} > ${i.sub[k]}`;
            }
          }
        }
        if (/^unfold|^open flat|^fully open|^flat$|^open device$/i.test(i.name)) {
          i.el.click();
          return `clicked menu ${m.name} > ${i.name}`;
        }
      }
    }
    return "no posture menu item";
  }

  if (mode === "click-ui") {
    const n = parseInt(a2 || "0", 10);
    const hits = controls(p)
      .filter((c) => /button|radio|checkbox|segment|slider|pop ?up/i.test(c.role) && POSTURE.test([c.name, c.desc, c.help, c.title].join(" ")))
      .sort((x, y) => {
        const fx = FULLY_OPEN.test([x.name, x.desc, x.help, x.title].join(" ")) && !/half/i.test(x.desc + x.name) ? 0 : 1;
        const fy = FULLY_OPEN.test([y.name, y.desc, y.help, y.title].join(" ")) && !/half/i.test(y.desc + y.name) ? 0 : 1;
        return fx - fy;
      });
    if (n >= hits.length) return `no control #${n} (${hits.length} look like posture controls)`;
    const c = hits[n];
    try {
      c.el.click();
    } catch (e) {
      try {
        c.el.actions.byName("AXPress").perform();
      } catch (e2) {
        return "click failed: " + e2;
      }
    }
    return `clicked ${c.role} name=[${c.name}] desc=[${c.desc}] help=[${c.help}] pos=[${c.pos}]`;
  }
  return "unknown mode " + mode;
}
