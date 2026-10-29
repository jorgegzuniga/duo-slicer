#!/usr/bin/env python3
"""Builds Resources/demo.3mf: a small two-plate, four-colour project the app opens in demo mode (screenshots, CI).

Plate 1 "Coaster": a white disc with three coloured rings on top. Plate 2 "Tags": three two-colour tags.
Plate pictures are drawn here too (top-down PNGs) so the plate strip and printer thumbnails have something to show.
"""
import json
import math
import struct
import sys
import zipfile
import zlib

COLORS = ["#F2F2F2", "#0A6E70", "#F28C28", "#1F2A44"]


def annulus(r0, r1, z0, z1, cx=0.0, cy=0.0, n=96):
    """Ring (r0 > 0) or disc (r0 == 0) as an indexed mesh."""
    v, t = [], []
    def add(x, y, z):
        v.append((round(cx + x, 4), round(cy + y, 4), z))
        return len(v) - 1
    if r0 <= 0:
        cb, ct = add(0, 0, z0), add(0, 0, z1)
        ob = [add(r1 * math.cos(2 * math.pi * i / n), r1 * math.sin(2 * math.pi * i / n), z0) for i in range(n)]
        ot = [add(r1 * math.cos(2 * math.pi * i / n), r1 * math.sin(2 * math.pi * i / n), z1) for i in range(n)]
        for i in range(n):
            j = (i + 1) % n
            t += [(cb, ob[j], ob[i]), (ct, ot[i], ot[j]), (ob[i], ob[j], ot[j]), (ob[i], ot[j], ot[i])]
        return v, t
    ob = [add(r1 * math.cos(2 * math.pi * i / n), r1 * math.sin(2 * math.pi * i / n), z0) for i in range(n)]
    ot = [add(r1 * math.cos(2 * math.pi * i / n), r1 * math.sin(2 * math.pi * i / n), z1) for i in range(n)]
    ib = [add(r0 * math.cos(2 * math.pi * i / n), r0 * math.sin(2 * math.pi * i / n), z0) for i in range(n)]
    it = [add(r0 * math.cos(2 * math.pi * i / n), r0 * math.sin(2 * math.pi * i / n), z1) for i in range(n)]
    for i in range(n):
        j = (i + 1) % n
        t += [(ob[i], ob[j], ot[j]), (ob[i], ot[j], ot[i])]          # outer wall
        t += [(ib[j], ib[i], it[i]), (ib[j], it[i], it[j])]          # inner wall
        t += [(ot[i], ot[j], it[j]), (ot[i], it[j], it[i])]          # top
        t += [(ob[j], ob[i], ib[i]), (ob[j], ib[i], ib[j])]          # bottom
    return v, t


def box(x0, y0, z0, x1, y1, z1):
    v = [(x0, y0, z0), (x1, y0, z0), (x1, y1, z0), (x0, y1, z0), (x0, y0, z1), (x1, y0, z1), (x1, y1, z1), (x0, y1, z1)]
    t = [(0, 2, 1), (0, 3, 2), (4, 5, 6), (4, 6, 7), (0, 1, 5), (0, 5, 4), (1, 2, 6), (1, 6, 5), (2, 3, 7), (2, 7, 6), (3, 0, 4), (3, 4, 7)]
    return v, t


def mesh_xml(oid, v, t):
    vs = "".join(f'<vertex x="{a}" y="{b}" z="{c}"/>' for a, b, c in v)
    ts = "".join(f'<triangle v1="{a}" v2="{b}" v3="{c}"/>' for a, b, c in t)
    return f'<object id="{oid}" type="model"><mesh><vertices>{vs}</vertices><triangles>{ts}</triangles></mesh></object>'


def png(w, h, pixels):
    raw = b"".join(b"\x00" + bytes(pixels[y * w * 4:(y + 1) * w * 4]) for y in range(h))
    def chunk(tag, data):
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b"")


def rgb(hexs):
    return tuple(int(hexs[i:i + 2], 16) for i in (1, 3, 5))


def draw(shapes, size=256, extent=120.0):
    """shapes: (kind, params, colour) in mm around the plate centre; returns PNG bytes."""
    px = bytearray(size * size * 4)
    for y in range(size):
        for x in range(size):
            mx = (x + 0.5) / size * extent - extent / 2
            my = extent / 2 - (y + 0.5) / size * extent
            col = None
            for kind, p, c in shapes:
                if kind == "ring":
                    r = math.hypot(mx - p[2], my - p[3])
                    if p[0] <= r <= p[1]:
                        col = c
                elif kind == "box" and p[0] <= mx <= p[2] and p[1] <= my <= p[3]:
                    col = c
            i = (y * size + x) * 4
            if col:
                r, g, b = rgb(col)
                px[i:i + 4] = bytes((r, g, b, 255))
    return png(size, size, px)


out = sys.argv[1] if len(sys.argv) > 1 else "Resources/demo.3mf"
objects, components, ms_objects, build = [], [], [], []
next_id = 1


def add_object(name, parts, x, y):
    """parts: list of ((v, t), filament)"""
    global next_id
    comp_ids = []
    for (v, t), _ in parts:
        objects.append(mesh_xml(next_id, v, t))
        comp_ids.append(next_id)
        next_id += 1
    oid = next_id
    next_id += 1
    objects.append(f'<object id="{oid}" type="model"><components>' + "".join(f'<component objectid="{c}"/>' for c in comp_ids) + "</components></object>")
    build.append(f'<item objectid="{oid}" transform="1 0 0 0 1 0 0 0 1 {x} {y} 0"/>')
    ms = f'<object id="{oid}"><metadata key="name" value="{name}"/><metadata key="extruder" value="{parts[0][1]}"/>'
    for c, (_, f) in zip(comp_ids, parts):
        ms += f'<part id="{c}" subtype="normal_part"><metadata key="extruder" value="{f}"/></part>'
    ms_objects.append(ms + "</object>")
    return oid


stride = 256 * 1.2
# plate 1: coaster at the bed centre
coaster = add_object("Coaster", [(annulus(0, 45, 0, 2.4), 1), (annulus(34, 41, 2.4, 3.2), 2), (annulus(19, 27, 2.4, 3.2), 3), (annulus(0, 9, 2.4, 3.2), 4)], 128, 128)
# plate 2: three tags (second plate sits one stride to the right)
tags = []
for k, (f, y) in enumerate([(2, -30), (3, 0), (4, 30)]):
    tags.append(add_object(f"Tag {k + 1}", [(box(-30, -9, 0, 30, 9, 2), 1), (box(-24, -3, 2, 24, 3, 2.8), f)], stride + 128, 128 + y))

main = ('<?xml version="1.0" encoding="UTF-8"?><model unit="millimeter" xmlns="http://schemas.microsoft.com/3dmanufacturing/core/2015/02" '
        'xmlns:p="http://schemas.microsoft.com/3dmanufacturing/production/2015/06"><resources>' + "".join(objects) +
        "</resources><build>" + "".join(build) + "</build></model>")
plates = (f'<plate><metadata key="plater_id" value="1"/><metadata key="plater_name" value="Coaster"/>'
          f'<metadata key="thumbnail_file" value="Metadata/plate_1.png"/><model_instance><metadata key="object_id" value="{coaster}"/></model_instance></plate>'
          f'<plate><metadata key="plater_id" value="2"/><metadata key="plater_name" value="Tags"/><metadata key="thumbnail_file" value="Metadata/plate_2.png"/>' +
          "".join(f'<model_instance><metadata key="object_id" value="{t}"/></model_instance>' for t in tags) + "</plate>")
ms = '<?xml version="1.0" encoding="UTF-8"?><config>' + "".join(ms_objects) + plates + "</config>"
cfg = {"printer_model": "Bambu Lab A1", "layer_height": "0.2", "filament_colour": COLORS, "filament_type": ["PLA"] * 4,
       "filament_settings_id": ["Bambu PLA Basic @BBL A1"] * 4, "printable_area": ["0x0", "256x0", "256x256", "0x256"],
       "curr_bed_type": "Textured PEI Plate"}
p1 = draw([("ring", (0, 45, 0, 0), COLORS[0]), ("ring", (34, 41, 0, 0), COLORS[1]), ("ring", (19, 27, 0, 0), COLORS[2]), ("ring", (0, 9, 0, 0), COLORS[3])])
shapes2 = []
for f, y in [(2, -30), (3, 0), (4, 30)]:
    shapes2 += [("box", (-30, y - 9, 30, y + 9), COLORS[0]), ("box", (-24, y - 3, 24, y + 3), COLORS[f - 1])]
p2 = draw(shapes2)
with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
    z.writestr("3D/3dmodel.model", main)
    z.writestr("Metadata/model_settings.config", ms)
    z.writestr("Metadata/project_settings.config", json.dumps(cfg))
    z.writestr("Metadata/plate_1.png", p1)
    z.writestr("Metadata/plate_2.png", p2)
print("wrote", out)
