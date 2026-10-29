// Drives Xcode's Device Hub (the Simulator app) through System Events, for CI on the iPhone Duo.
// simctl has no way to unfold the Duo yet, so this looks for the posture controls in the app's menus and window.
//   osascript -l JavaScript ci/device-hub.js dump <bundle id>
//   osascript -l JavaScript ci/device-hub.js click-menu <bundle id>
//   osascript -l JavaScript ci/device-hub.js click-ui <bundle id> <n>    (n-th control that looks like a posture control)

const POSTURE = /unfold|posture|flat|fully open|^open|open$|book|tent|half/i;

function safe(f) {
  try {
    const v = f();
    return v === null || v === undefined ? "" : String(v);
  } catch (e) {
    return "";
  }
}

function findProcess(se, bid) {
  try {
    const ps = se.processes.whose({ bundleIdentifier: bid })();
    if (ps.length) return ps[0];
  } catch (e) {}
  for (const p of se.processes()) {
    if (/device ?hub|simulator/i.test(safe(() => p.name()))) return p;
  }
  return null;
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
      items.push({ el: mi, name: safe(() => mi.name()), subEls, sub: subEls.map((s) => safe(() => s.name())) });
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

function run(argv) {
  const [mode, bid, nArg] = argv;
  const se = Application("System Events");
  const p = findProcess(se, bid);
  if (!p) return "no process for " + bid;
  try {
    p.frontmost = true;
  } catch (e) {}
  delay(1);

  if (mode === "dump") {
    const lines = ["process: " + safe(() => p.name()) + ", windows: " + safe(() => p.windows().length)];
    for (const m of menus(p)) {
      lines.push("MENU " + m.name + ": " + m.items.map((i) => i.name + (i.sub.length ? " > [" + i.sub.join(", ") + "]" : "")).join(" | "));
    }
    for (const c of controls(p)) {
      lines.push(`${c.window} :: ${c.role} name=[${c.name}] desc=[${c.desc}] help=[${c.help}] title=[${c.title}] value=[${c.value}] pos=[${c.pos}] size=[${c.size}]`);
    }
    return lines.join("\n");
  }

  if (mode === "click-menu") {
    for (const m of menus(p)) {
      for (const i of m.items) {
        if (i.sub.length && /posture|fold|hinge|lid/i.test(i.name)) {
          for (let k = 0; k < i.sub.length; k++) {
            if (/unfold|open|flat/i.test(i.sub[k]) && !/half|partial/i.test(i.sub[k])) {
              i.subEls[k].click();
              return `clicked menu ${m.name} > ${i.name} > ${i.sub[k]}`;
            }
          }
        }
        if (/^unfold|^open flat|^fully open|^flat$/i.test(i.name)) {
          i.el.click();
          return `clicked menu ${m.name} > ${i.name}`;
        }
      }
    }
    return "no posture menu item";
  }

  if (mode === "click-ui") {
    const n = parseInt(nArg || "0", 10);
    const hits = controls(p).filter(
      (c) => /button|radio|checkbox|segment|slider|pop ?up/i.test(c.role) && POSTURE.test([c.name, c.desc, c.help, c.title].join(" "))
    );
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
