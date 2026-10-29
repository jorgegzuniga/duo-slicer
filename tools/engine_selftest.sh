#!/bin/sh
# Builds the engine harness, slices a generated two-colour tile and checks the G-code.
set -e
cd "$(dirname "$0")/.."
./build_cli.sh
python3 tools/make_test_3mf.py /tmp/a1_test.3mf
echo '{}' > /tmp/a1_opts.json
./a1cli Resources/a1-profiles.json /tmp/a1_test.3mf 0 /tmp/a1_opts.json /tmp/a1_test.gcode.3mf | tee /tmp/a1_summary.json
python3 - <<'PY'
import json, zipfile, subprocess, sys
s = json.load(open('/tmp/a1_summary.json'))
assert s.get('ok'), s
assert s['layers'] == 20, s['layers']
assert s['tool_changes'] >= 1, s
z = zipfile.ZipFile('/tmp/a1_test.gcode.3mf')
g = z.read('Metadata/plate_1.gcode').decode()
open('/tmp/a1_test.gcode', 'w').write(g)
import hashlib
assert z.read('Metadata/plate_1.gcode.md5').decode() == hashlib.md5(g.encode()).hexdigest().upper()
out = subprocess.run([sys.executable, 'tools/check_gcode.py', '/tmp/a1_test.gcode'], capture_output=True, text=True).stdout
print(out)
assert 'problems 0' in out, out
print("engine self-test passed")
PY
