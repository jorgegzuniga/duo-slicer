#!/usr/bin/env python3
"""Slices test projects for every printer bundle in Resources/profiles and checks the output.

usage: validate_printers.py a1cli project.3mf[:plate[,plate...]] [...]   (plate indices are 0-based; default 0)

For each printer: template errors (warnings), bed / no-print-box / height checks via check_gcode.py,
and for Bambu packages the MD5 and slice info. Exits non-zero when anything fails.
"""
import json
import os
import subprocess
import sys
import tempfile
import zipfile
import hashlib

root = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
cli = sys.argv[1]
jobs = []
for arg in sys.argv[2:]:
    path, _, plates = arg.partition(":")
    for p in (plates.split(",") if plates else ["0"]):
        jobs.append((path, int(p)))
index = json.load(open(os.path.join(root, "Resources", "profiles", "index.json")))
tmp = tempfile.mkdtemp()
opts = os.path.join(tmp, "opts.json")
open(opts, "w").write("{}")
failures = 0
for pr in index:
    bundle = os.path.join(root, "Resources", "profiles", pr["id"] + ".json")
    for path, plate in jobs:
        out = os.path.join(tmp, "out")
        r = subprocess.run([cli, bundle, path, str(plate), opts, out], capture_output=True, text=True)
        tag = "%-15s %-28s plate %d" % (pr["id"], os.path.basename(path)[:28], plate)
        try:
            s = json.loads(r.stdout.strip().split("\n")[-1])
        except Exception:
            print(tag, "FAILED (no summary)", r.stdout[-300:], r.stderr[-300:])
            failures += 1
            continue
        if not s.get("ok"):
            # expected for parts that don't fit a small bed
            print(tag, "refused:", s.get("error"))
            if "doesn't fit" not in s.get("error", "") and "taller" not in s.get("error", "") and "front-left corner" not in s.get("error", ""):
                failures += 1
            continue
        if s["file_kind"] == "gcode.3mf":
            z = zipfile.ZipFile(out)
            name = s["gcode_path"]
            g = z.read(name)
            assert z.read(name + ".md5").decode() == hashlib.md5(g).hexdigest().upper()
            si = z.read("Metadata/slice_info.config").decode()
            assert 'printer_model_id" value="%s"' % pr["model_id"] in si, "model id missing"
            gpath = os.path.join(tmp, "plate.gcode")
            open(gpath, "wb").write(g)
        else:
            gpath = out
        bed = pr["bed"]
        args = [sys.executable, os.path.join(root, "tools", "check_gcode.py"), gpath,
                "--bed", "%g,%g,%g,%g" % (bed["min"][0], bed["min"][1], bed["max"][0], bed["max"][1]), "--height", str(bed["height"])]
        if bed.get("exclude"):
            args += ["--exclude", "%g,%g,%g,%g" % (bed["exclude"][0][0], bed["exclude"][0][1], bed["exclude"][1][0], bed["exclude"][1][1])]
        if pr["kind"] == "klipper_toolchanger":
            args += ["--tools", str(pr["tools"])]
        chk = subprocess.run(args, capture_output=True, text=True).stdout
        problems = [l for l in chk.split("\n") if l.startswith("problems")][0]
        templ = [w for w in s.get("warnings", []) if "Template" in w]
        ok = problems == "problems 0" and not templ
        failures += 0 if ok else 1
        print(tag, "ok" if ok else "FAIL", "| %d layers, %.0f g, %d changes, %s" % (s["layers"], s["grams"], s["tool_changes"], problems),
              "| " + "; ".join(s.get("warnings", []))[:300])
        if not ok:
            print("   ", "\n    ".join(chk.split("\n")[-14:]))
print("failures", failures)
sys.exit(1 if failures else 0)
