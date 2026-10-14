#!/usr/bin/env python3
"""Read the tracked ordinary Kunminghu profile; initialize build metadata."""
import argparse
import json
from pathlib import Path
import subprocess


def load_profile(root):
    data = json.loads((Path(root) / 'config/kunminghu-profile.json').read_text())
    if (data['cpu_kind'] != 'kunminghu' or data['num_cores'] not in (1, 2) or
            data['config'] != 'FpgaDefaultConfig' or data['board'] != 'uvhs2' or
            data['cpu_repository'] != 'https://github.com/OpenXiangShan/XiangShan.git'):
        raise ValueError('unsupported ordinary Kunminghu SCOPE profile')
    return data


def initialize_source(root, cores=None):
    root = Path(root)
    profile = load_profile(root)
    if cores is not None and cores != profile['num_cores']:
        raise ValueError('requested core count differs from this branch; use the matching branch')
    for location, field in [('kmh/hardware/xs-gen', 'cpu_commit'), ('work_farm', 'work_farm_commit')]:
        actual = subprocess.check_output(['git', '-C', str(root / location), 'rev-parse', 'HEAD'], text=True).strip()
        if actual != profile[field]:
            raise ValueError(f'{location} differs from the pinned {field}')
    source = {key: profile[key] for key in ('cpu_kind', 'num_cores', 'config', 'cpu_commit',
                                           'cpu_repository', 'work_farm_commit')}
    source.update(main_branch='kunminghu', main_commit=profile['upstream_main_commit'])
    build = root / 'build'
    build.mkdir(exist_ok=True)
    (build / 'CPU_SOURCE.json').write_text(json.dumps(source, indent=2) + '\n')
    return source


def main():
    root = Path(__file__).resolve().parents[2]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--field', choices=('num_cores', 'cpu_kind', 'config'))
    parser.add_argument('--initialize', action='store_true')
    args = parser.parse_args()
    data = initialize_source(root) if args.initialize else load_profile(root)
    print(data[args.field] if args.field else json.dumps(data, indent=2))


if __name__ == '__main__':
    main()
