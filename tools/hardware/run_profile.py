#!/usr/bin/env python3
"""Build an ordinary Kunminghu 1/2-core SCOPE profile; keep detached logs/state."""
from datetime import datetime
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import time
from profile import initialize_source, load_profile


def now():
    return datetime.now().astimezone().isoformat()


def main():
    root=Path(__file__).resolve().parents[2]
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--num-cores',type=int,choices=[1,2],default=load_profile(root)['num_cores'])
    p.add_argument('--cpu-kind',choices=['kunminghu'],default='kunminghu')
    p.add_argument('--from-stage',choices=['full','wrapper','shell-synth','role-synth','pdi'],default='full')
    p.add_argument('--wait-rtl-pid',type=int,help='wait for this already-running RTL generation before using its output')
    args=p.parse_args();build=root/'build';build.mkdir(exist_ok=True)
    lock=(build/'profile-build.lock').open('w');fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
    source=initialize_source(root, args.num_cores)
    cpu=subprocess.check_output(['git','-C',str(root/'kmh/hardware/xs-gen'),'rev-parse','HEAD'],text=True).strip()
    if source['cpu_kind']!='kunminghu' or cpu!=source['cpu_commit'] or source['num_cores']!=args.num_cores:
        raise RuntimeError('ordinary Kunminghu source/core count differs from requested profile')
    if 'OpenXiangShan/XiangShan.git' not in (root/'.gitmodules').read_text():
        raise RuntimeError('CPU submodule is not the ordinary XiangShan repository')
    env=os.environ.copy()
    env.update({'CPU_KIND':'kunminghu','CONFIG':'FpgaDefaultConfig','NUM_CORES':str(args.num_cores),
        'VIVADO_MAX_THREADS':'1','VIVADO_SYNTH_THREADS':'1',
        'VIVADO_MIN_AVAILABLE_GIB':env.get('VIVADO_MIN_AVAILABLE_GIB','192' if args.num_cores==1 else '320'),
        'VIVADO_SHARED_LOCK_FILE':str(build/'profile-vivado.lock'),'JVM_XMX':'40G','JVM_XSS':'256m'})
    state_file=build/'PROFILE_BUILD.json'
    if state_file.exists():shutil.copy2(state_file,build/f'PROFILE_BUILD.{datetime.now():%Y%m%d_%H%M%S_%f}.json')
    state={'pid':os.getpid(),'num_cores':args.num_cores,'cpu_kind':'kunminghu','config':'FpgaDefaultConfig',
        'source':source,'cwd':str(root),'started_at':now(),'status':'running','stages':[],'from_stage':args.from_stage}
    def save():
        temp=state_file.with_suffix('.json.tmp');temp.write_text(json.dumps(state,indent=2)+'\n');os.replace(temp,state_file)
    def run(stage,command):
        state['stage']=stage;entry={'stage':stage,'started_at':now(),'command':command};state['stages'].append(entry);save()
        print(f'[{now()}] ordinary Kunminghu {args.num_cores} core(s): {stage}',flush=True)
        code=subprocess.run(command,cwd=root,env=env).returncode
        entry.update(finished_at=now(),returncode=code);save()
        if code:raise RuntimeError(f'{stage} failed: {code}')
    def hardware(stage):run(stage,['bash','tools/build_vp1902.sh','--stage',stage])
    save()
    try:
        if args.wait_rtl_pid:
            state['stage']='wait-rtl';save()
            print(f'[{now()}] waiting for RTL process {args.wait_rtl_pid}',flush=True)
            while Path(f'/proc/{args.wait_rtl_pid}/stat').exists():
                try:status=Path(f'/proc/{args.wait_rtl_pid}/stat').read_text()
                except FileNotFoundError:break
                if status.rsplit(')',1)[1].split()[0]=='Z':break
                time.sleep(10)
        if args.from_stage=='full':hardware('rtl')
        top=root/'kmh/hardware/sources/generated/XSTop.v'
        with top.open() as f:
            if f.readline().strip()!='//commit '+source['cpu_commit']:
                raise RuntimeError('generated XSTop is not from the pinned ordinary Kunminghu CPU')
        run('wrapper',['python3','tools/hardware/prepare_xstop_wrapper.py','--num-cores',str(args.num_cores),
            '--cpu-kind','kunminghu','--config','FpgaDefaultConfig']+([] if args.from_stage in {'full','wrapper'} else ['--check']))
        if args.from_stage in {'full','wrapper'}:hardware('shell-gen');hardware('role-gen')
        run('frontend-check',['python3','tools/hardware/check_frontend.py'])
        hardware_paths=[p for base in ['shell/common','shell/uvhs2','kmh/fpga','kmh/hardware/sources/generated']
                        for p in (root/base).rglob('*') if p.is_file()]
        (build/'HARDWARE_INPUTS.json').write_text(json.dumps({str(p.relative_to(root)):hashlib.sha256(p.read_bytes()).hexdigest()
                                                            for p in hardware_paths},indent=2)+'\n')
        if args.from_stage in {'full','wrapper','shell-synth'}:hardware('shell-synth')
        if args.from_stage!='pdi':hardware('role-synth')
        hardware('pdi');artifact=root/'work_farm/hw_plat/target_kmh_proto_uvhs2/system.pdi'
        if not artifact.is_file() or not artifact.stat().st_size:raise RuntimeError('PDI missing')
        state.update(status='complete',finished_at=now(),pdi=str(artifact),pdi_sha256=hashlib.sha256(artifact.read_bytes()).hexdigest())
    except BaseException as e:
        state.update(status='failed',finished_at=now(),error=str(e));save();raise
    save()


if __name__=='__main__':main()
