#!/usr/bin/env python3
"""Builds Resources/profiles/*.json: one fully-resolved bundle per supported printer.

Sources (AGPL-3.0 profile data):
  --bambu  path to BambuStudio/resources/profiles/BBL
  --orca   path to OrcaSlicer/resources/profiles/Snapmaker
  --orca-library  path to OrcaSlicer/resources/profiles/OrcaFilamentLibrary

Each bundle holds the printer's machine preset, its quality (process) presets and its compatible
Bambu/Generic/vendor filament presets, with every `inherits` / `include` chain flattened.
"""
import argparse
import glob
import json
import os
import re

META = {"name", "inherits", "from", "instantiation", "setting_id", "type", "description", "base_id", "renamed_from", "version",
        "is_custom_defined", "include"}

PRINTERS = [
    # id, vendor, machine preset, kind
    ("bambu-a1", "bambu", "Bambu Lab A1 0.4 nozzle", "bambu"),
    ("bambu-a1-mini", "bambu", "Bambu Lab A1 mini 0.4 nozzle", "bambu"),
    ("bambu-a2l", "bambu", "Bambu Lab A2L 0.4 nozzle", "bambu"),
    ("bambu-p1p", "bambu", "Bambu Lab P1P 0.4 nozzle", "bambu"),
    ("bambu-p1s", "bambu", "Bambu Lab P1S 0.4 nozzle", "bambu"),
    ("bambu-p2s", "bambu", "Bambu Lab P2S 0.4 nozzle", "bambu"),
    ("bambu-x1", "bambu", "Bambu Lab X1 0.4 nozzle", "bambu"),
    ("bambu-x1c", "bambu", "Bambu Lab X1 Carbon 0.4 nozzle", "bambu"),
    ("bambu-x1e", "bambu", "Bambu Lab X1E 0.4 nozzle", "bambu"),
    ("bambu-h2s", "bambu", "Bambu Lab H2S 0.4 nozzle", "bambu"),
    ("snapmaker-u1", "snapmaker", "Snapmaker U1 (0.4 nozzle)", "klipper_toolchanger"),
]


class Tree:
    def __init__(self, *roots):
        self.idx = {}
        for root in roots:
          for kind in ("machine", "process", "filament"):
            for f in glob.glob(os.path.join(root, kind, "**", "*.json"), recursive=True):
                try:
                    j = json.load(open(f, encoding="utf-8"))
                except Exception:
                    continue
                if "name" in j and (kind, j["name"]) not in self.idx:
                    self.idx[(kind, j["name"])] = j

    def resolve(self, kind, name, seen=None):
        seen = seen or set()
        if (kind, name) in seen:
            return {}
        seen.add((kind, name))
        j = self.idx[(kind, name)]
        out = dict(self.resolve(kind, j["inherits"], seen)) if j.get("inherits") else {}
        for inc in j.get("include", []) or []:
            if (kind, inc) in self.idx:
                for k, v in self.resolve(kind, inc, seen).items():
                    if k not in META:
                        out[k] = v
        out.update(j)
        return out

    def names(self, kind):
        return [n for (k, n) in self.idx if k == kind]


def clean(d):
    return {k: v for k, v in d.items() if k not in META}


def compatible(preset, machine_name, machine_model, vendor):
    cp = preset.get("compatible_printers")
    if isinstance(cp, list) and cp:
        return machine_name in cp
    cond = preset.get("compatible_printers_condition", "")
    if cond:
        m = re.search(r'printer_model\s*==\s*"([^"]+)"', cond)
        return bool(m and m.group(1) == machine_model)
    return False


def area(pts):
    xs, ys = [], []
    for p in pts or []:
        x, y = p.strip().split("x")
        xs.append(float(x)); ys.append(float(y))
    return xs, ys


def build(tree, pid, vendor, machine_name, kind):
    m = tree.resolve("machine", machine_name)
    model = m.get("printer_model", "")
    model_json = tree.idx.get(("machine", model), {})  # Bambu "machine_model" files share the model name
    procs = {}
    for n in tree.names("process"):
        p = tree.idx[("process", n)]
        if p.get("instantiation") != "true":
            continue
        r = tree.resolve("process", n)
        if compatible(r, machine_name, model, vendor):
            procs[n] = clean(r)
    fils = {}
    for n in tree.names("filament"):
        f = tree.idx[("filament", n)]
        if f.get("instantiation") != "true":
            continue
        if vendor == "bambu" and not (n.startswith("Bambu") or n.startswith("Generic")):
            continue
        r = tree.resolve("filament", n)
        if not compatible(r, machine_name, model, vendor):
            continue
        c = clean(r)
        c["__filament_id"] = r.get("filament_id", "")
        fils[n] = c
    xs, ys = area(m.get("printable_area"))
    ex = m.get("bed_exclude_area") or []
    exxs, exys = area([p for p in ex if p.strip() not in ("0x0",)] if len(ex) > 1 else [])
    default_proc = m.get("default_print_profile", "")
    if default_proc not in procs and procs:
        default_proc = sorted(procs, key=lambda s: (abs(float(procs[s].get("layer_height", "0.2")) - 0.2), s))[0]
    nozzles = len(m.get("nozzle_diameter") or ["0.4"])
    return {
        "id": pid,
        "vendor": "Bambu Lab" if vendor == "bambu" else "Snapmaker",
        "name": model or machine_name,
        "kind": kind,
        "machine_name": machine_name,
        "model_id": model_json.get("model_id", ""),
        "nozzle": float((m.get("nozzle_diameter") or ["0.4"])[0]),
        "tools": nozzles,
        "bed": {"min": [min(xs), min(ys)], "max": [max(xs), max(ys)], "height": float(m.get("printable_height", "250")),
                "exclude": [[min(exxs), min(exys)], [max(exxs), max(exys)]] if exxs else []},
        "machine": clean(m),
        "default_process": default_proc,
        "processes": procs,
        "filaments": fils,
        "profile_version": tree.idx[("machine", machine_name)].get("version", ""),
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bambu", required=True)
    ap.add_argument("--orca", required=True)
    ap.add_argument("--orca-library", required=True, help="OrcaSlicer/resources/profiles/OrcaFilamentLibrary")
    ap.add_argument("--out", default=os.path.join(os.path.dirname(__file__), "..", "Resources", "profiles"))
    a = ap.parse_args()
    trees = {"bambu": Tree(a.bambu), "snapmaker": Tree(a.orca, a.orca_library)}
    os.makedirs(a.out, exist_ok=True)
    index = []
    for pid, vendor, machine, kind in PRINTERS:
        b = build(trees[vendor], pid, vendor, machine, kind)
        path = os.path.join(a.out, pid + ".json")
        with open(path, "w", encoding="utf-8") as f:
            json.dump(b, f, separators=(",", ":"), ensure_ascii=False)
        index.append({k: b[k] for k in ("id", "vendor", "name", "kind", "machine_name", "model_id", "nozzle", "tools", "bed", "default_process")})
        print(f"{pid:16s} {b['name']:22s} procs={len(b['processes']):3d} fils={len(b['filaments']):3d} {os.path.getsize(path)//1024} KB")
    with open(os.path.join(a.out, "index.json"), "w", encoding="utf-8") as f:
        json.dump(index, f, indent=1, ensure_ascii=False)


if __name__ == "__main__":
    main()
