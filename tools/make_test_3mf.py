"""Builds a small two-colour Bambu-style 3MF (a 40 mm tile with an inset second colour) for engine tests."""
import json, sys, zipfile

def box(x0, y0, z0, x1, y1, z1):
    v = [(x0,y0,z0),(x1,y0,z0),(x1,y1,z0),(x0,y1,z0),(x0,y0,z1),(x1,y0,z1),(x1,y1,z1),(x0,y1,z1)]
    t = [(0,2,1),(0,3,2),(4,5,6),(4,6,7),(0,1,5),(0,5,4),(1,2,6),(1,6,5),(2,3,7),(2,7,6),(3,0,4),(3,4,7)]
    return v, t

def mesh_xml(oid, v, t):
    vs = "".join(f'<vertex x="{a}" y="{b}" z="{c}"/>' for a,b,c in v)
    ts = "".join(f'<triangle v1="{a}" v2="{b}" v3="{c}"/>' for a,b,c in t)
    return f'<object id="{oid}" type="model"><mesh><vertices>{vs}</vertices><triangles>{ts}</triangles></mesh></object>'

out = sys.argv[1]
v1, t1 = box(-20, -20, 0, 20, 20, 2)
v2, t2 = box(-10, -10, 2, 10, 10, 4)
objs = mesh_xml(1, v1, t1) + mesh_xml(2, v2, t2)
main = ('<?xml version="1.0" encoding="UTF-8"?><model unit="millimeter" xmlns="http://schemas.microsoft.com/3dmanufacturing/core/2015/02" '
        'xmlns:p="http://schemas.microsoft.com/3dmanufacturing/production/2015/06"><resources>' + objs +
        '<object id="3" type="model"><components><component objectid="1"/><component objectid="2"/></components></object>'
        '</resources><build><item objectid="3" transform="1 0 0 0 1 0 0 0 1 128 128 0"/></build></model>')
ms = ('<?xml version="1.0" encoding="UTF-8"?><config><object id="3"><metadata key="name" value="Test tile"/><metadata key="extruder" value="1"/>'
      '<part id="1" subtype="normal_part"><metadata key="extruder" value="1"/></part><part id="2" subtype="normal_part"><metadata key="extruder" value="2"/></part></object>'
      '<plate><metadata key="plater_id" value="1"/><metadata key="plater_name" value="Test"/><model_instance><metadata key="object_id" value="3"/></model_instance></plate></config>')
cfg = {"printer_model": "Bambu Lab A1", "layer_height": "0.2", "filament_colour": ["#FFFFFF", "#0078BF"], "filament_type": ["PLA", "PLA"],
       "filament_settings_id": ["Bambu PLA Basic @BBL A1", "Bambu PLA Basic @BBL A1"], "printable_area": ["0x0", "256x0", "256x256", "0x256"]}
with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
    z.writestr("3D/3dmodel.model", main)
    z.writestr("Metadata/model_settings.config", ms)
    z.writestr("Metadata/project_settings.config", json.dumps(cfg))
print("wrote", out)
