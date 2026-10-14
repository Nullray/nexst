#!/usr/bin/env python3
"""Start detached ordinary Kunminghu single/dual VP1902 builds with logs."""
import argparse
from datetime import datetime
import json
import os
from pathlib import Path
import subprocess
from profile import initialize_source


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--single-root',type=Path,default=Path('/home/yanjiarun/nexst_kunminghu_single'))
    p.add_argument('--dual-root',type=Path,default=Path('/home/yanjiarun/nexst_kunminghu_dual'))
    p.add_argument('--tool-cache',type=Path,required=True)
    p.add_argument('--from-stage',choices=['full','wrapper','shell-synth','role-synth','pdi'],default='full')
    p.add_argument('--wait-single-rtl-pid',type=int)
    a=p.parse_args();records=[]
    for count,root in [(1,a.single_root.resolve()),(2,a.dual_root.resolve())]:
        build=root/'build';build.mkdir(exist_ok=True)
        state_file=build/'PROFILE_BUILD.json'
        if state_file.exists():
            old=json.loads(state_file.read_text());pid=old.get('pid',0)
            proc=Path(f'/proc/{pid}/cmdline')
            if proc.exists() and b'run_profile.py' in proc.read_bytes():
                raise RuntimeError(f'profile already running: {root}, PID {pid}')
        source=initialize_source(root, count)
        if source['cpu_kind']!='kunminghu' or source['num_cores']!=count:
            raise RuntimeError(f'wrong CPU source/core count: {root}')
        bin_dir=build/'toolchain/bin';bin_dir.mkdir(parents=True,exist_ok=True)
        mill=bin_dir/'mill';expected=a.tool_cache.resolve()/'mill/0.12.3'
        if mill.exists() or mill.is_symlink():
            if mill.resolve()!=expected:raise RuntimeError(f'unexpected Mill executable: {mill}')
        else:mill.symlink_to(expected)
        env=os.environ.copy();env.update({'JAVA_HOME':'/usr/lib/jvm/java-11-openjdk-amd64',
            'COURSIER_CACHE':str(a.tool_cache.resolve()/'coursier/v1'),
            'CHISEL_FIRTOOL_PATH':str(a.tool_cache.resolve()/'llvm-firtool/1.62.1/bin'),
            'PATH':str(bin_dir)+':/usr/lib/jvm/java-11-openjdk-amd64/bin:'+env['PATH']})
        command=['nohup','python3','-u','tools/hardware/run_profile.py','--num-cores',str(count),
                 '--cpu-kind','kunminghu','--from-stage',a.from_stage]
        if count==1 and a.wait_single_rtl_pid:command+=['--wait-rtl-pid',str(a.wait_single_rtl_pid)]
        log=build/f'scope-console-{datetime.now():%Y%m%d_%H%M%S}.log'
        with log.open('wb') as stream:
            process=subprocess.Popen(command,cwd=root,env=env,stdin=subprocess.DEVNULL,stdout=stream,
                                     stderr=subprocess.STDOUT,start_new_session=True)
        record={'pid':process.pid,'cwd':str(root),'command':command,'console_log':str(log),
                'started_at':datetime.now().astimezone().isoformat(),'source':source,'detached':True,
                'state_file':str(state_file),'pdi':str(root/'work_farm/hw_plat/target_kmh_proto_uvhs2/system.pdi')}
        (build/'PROFILE_LAUNCH.json').write_text(json.dumps(record,indent=2)+'\n')
        records.append(record);print(json.dumps(record),flush=True)
    (a.dual_root/'build/ORDINARY_SCOPE_LAUNCH.json').write_text(json.dumps(records,indent=2)+'\n')


if __name__=='__main__':main()
