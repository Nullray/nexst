#!/usr/bin/env python3
"""Verify fresh-clone profile metadata and reject mixed CPU/core sources."""
import importlib.util
import json
from pathlib import Path
import tempfile

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('scope_profile', ROOT / 'tools/hardware/profile.py')
profile = importlib.util.module_from_spec(spec)
spec.loader.exec_module(profile)
manifest = json.loads((ROOT / 'config/kunminghu-profile.json').read_text())
for cores in (1, 2):
    with tempfile.TemporaryDirectory() as d:
        root = Path(d)
        (root / 'config').mkdir()
        data = dict(manifest, num_cores=cores)
        (root / 'config/kunminghu-profile.json').write_text(json.dumps(data))
        (root / 'kmh/hardware').mkdir(parents=True)
        (root / 'kmh/hardware/xs-gen').symlink_to(ROOT / 'kmh/hardware/xs-gen', target_is_directory=True)
        (root / 'work_farm').symlink_to(ROOT / 'work_farm', target_is_directory=True)
        assert not (root / 'build/CPU_SOURCE.json').exists()
        result = profile.initialize_source(root)
        assert result['num_cores'] == cores
        assert json.loads((root / 'build/CPU_SOURCE.json').read_text()) == result
        try:
            profile.initialize_source(root, 3 - cores)
            raise AssertionError('mixed core count accepted')
        except ValueError:
            pass
        data['cpu_commit'] = '0' * 40
        (root / 'config/kunminghu-profile.json').write_text(json.dumps(data))
        try:
            profile.initialize_source(root)
            raise AssertionError('wrong CPU commit accepted')
        except ValueError:
            pass
    print(f'PASS: fresh {cores}-core metadata, wrong-core and wrong-CPU rejection')
