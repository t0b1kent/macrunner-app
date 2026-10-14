#!/usr/bin/env python3
"""APP32 permanent seconds probes, same app entry and narrow direct controls."""
import argparse, datetime, hashlib, json, os, re, shutil, subprocess, time
from pathlib import Path

selected_root=os.environ.get('MACRUNNER_ROOT')
if not selected_root:
    raise SystemExit('Set MACRUNNER_ROOT to the selected complete MacRunner checkout')
ROOT=Path(selected_root).resolve()
PROBES=ROOT/'scripts/probes/app32'
PRIVATE={'HOME','USER','LOGNAME','__CF_USER_TEXT_ENCODING'}

def sha(p): return hashlib.sha256(p.read_bytes()).hexdigest()
def save(p,v): p.write_text(json.dumps(v,ensure_ascii=False,indent=2)+'\n')
def bounded(argv,env=None,timeout=15):
    return subprocess.run(list(map(str,argv)),env=env,cwd=ROOT,stdin=subprocess.DEVNULL,capture_output=True,timeout=timeout)

def global_modeset(prefix,value):
    p=prefix/'user.reg';lines=p.read_text().splitlines();section=r'[Software\\Wine\\X11 Driver]'
    begin=next((i for i,l in enumerate(lines) if l==section or l.startswith(section+' ')),None)
    entry='"EmulateModeset"="'+value+'"'
    if begin is None:lines+=['',section,entry,'']
    else:
        end=next((i for i in range(begin+1,len(lines)) if lines[i].startswith('[')),len(lines))
        lines[begin+1:end]=[entry]+[l for l in lines[begin+1:end] if not l.startswith('"EmulateModeset"=')]
    p.write_text('\n'.join(lines)+'\n')

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app',type=Path,required=True)
    parser.add_argument('--old-wow64win',type=Path,required=True)
    parser.add_argument('--old-wow64',type=Path,required=True)
    parser.add_argument('--diablo-data',type=Path)
    selection=parser.add_mutually_exclusive_group()
    selection.add_argument('--callback-negative-only',action='store_true',help='Reproduce only the package callback fault; this is not full gate acceptance')
    selection.add_argument('--cdrom-only',action='store_true',help='Check the app CD-ROM profile and missing media without requiring rebuilt native callback modules')
    selection.add_argument('--message-only',action='store_true',help='Run the pinned current MessageBox probe through the app and directly')
    selection.add_argument('--env-only',action='store_true',help='Verify ephemeral acceptance-env reaches the Windows child and inherited parent values do not')
    parser.add_argument('--output',type=Path,required=True)
    parser.add_argument('--reuse-data',type=Path,help='Reuse an owned completed gate data directory; all new raw logs remain there')
    args=parser.parse_args();app=args.app.resolve();out=args.output.resolve();old=args.old_wow64win.resolve()
    assert out.is_relative_to(ROOT/'artifacts') and not out.exists(), 'new private artifact directory required'
    engine=app/'Contents/Resources/engine';candidate=engine/'wine/lib/wine/aarch64-windows/wow64win.dll'
    wow64=engine/'wine/lib/wine/aarch64-windows/wow64.dll';old_wow64=args.old_wow64.resolve()
    assert app.is_dir() and old.is_file() and old!=candidate and sha(old)!=sha(candidate)
    assert old_wow64.is_file()
    if args.callback_negative_only:assert sha(wow64)==sha(old_wow64),'negative-only requires exact package wow64'
    elif not args.cdrom_only:assert sha(wow64)!=sha(old_wow64),'full gate needs corrected wow64 candidate'
    # One coordinator/waiter; do not start another Wine-owning lane controller.
    peers=bounded(['pgrep','-fl',r'(?:app32-20261004/(?:accept-app|wait-build)\.py|scripts/probes/app32/gate\.py)'],timeout=5)
    for line in peers.stdout.decode(errors='replace').splitlines():
        fields=line.split(maxsplit=1)
        if fields and fields[0].isdigit() and int(fields[0])!=os.getpid() and 'Python' in line:
            raise RuntimeError('existing APP32 waiter: '+fields[0])
    verify=bounded(['codesign','--verify','--strict',app]);assert verify.returncode==0,'app signature verification failed'
    main_bytes=(app/'Contents/MacOS/MacRunner').read_bytes()
    assert b'APP_PATH_REFUSED' in main_bytes and b'--run-app-entry-paths' in main_bytes, 'isolated app entry is not present in selected executable'
    out.mkdir(parents=True);(out/'tmp').mkdir()
    while True:
        gate=bounded(['scripts/wine-slot.sh','builds-ok'])
        save(out/'build-waiter-heartbeat.json',dict(utc=datetime.datetime.now(datetime.timezone.utc).isoformat(),returncode=gate.returncode,state='ALLOWED' if gate.returncode==0 else 'WAITING'))
        if gate.returncode==0:break
        time.sleep(30)
    preflight_results=[]
    data=args.reuse_data.resolve() if args.reuse_data else out/'data'
    if args.reuse_data:
        assert data.is_relative_to(ROOT/'artifacts/app32-20261004') and (data.parent/'RESULT.json').is_file(), 'reuse requires a completed owned gate'
        opened=bounded(['/usr/sbin/lsof','-nP','-t','+D',data/'Bottles/Default'],timeout=15)
        assert opened.returncode==1 and not opened.stdout and not opened.stderr, 'reused prefix is still open'
    data_existed=data.exists()
    private_env=dict(os.environ,MACRUNNER_APP_DATA_ROOT=str(data),TMPDIR=str(out/'tmp')+'/')
    private_env.pop('MACRUNNER_BUNDLED_ENGINE',None)
    dry=bounded([app/'Contents/MacOS/MacRunner','--run-app-entry-paths'],env=private_env)
    (out/'dry-paths.stdout.raw').write_bytes(dry.stdout);(out/'dry-paths.stderr.raw').write_bytes(dry.stderr)
    paths=json.loads(dry.stdout)
    assert dry.returncode==0 and paths==dict(data_root=str(data),bottle=str(data/'Bottles/Default'),runs=str(data/'Runs'))
    assert data.exists()==data_existed, 'dry path check performed writes'
    forbidden=Path.home()/'Library/Application Support/MacRunnerControlCenter'
    def default_metadata():
        rows={}
        for suffix in ['', 'Bottles','Bottles/Default','Bottles/Default/.macrunner-bottle.json']:
            path=forbidden/suffix
            try:
                st=path.stat();rows[suffix]=dict(inode=st.st_ino,size=st.st_size,mtime_ns=st.st_mtime_ns)
            except FileNotFoundError:rows[suffix]=dict(state='EMPTY')
        return rows
    before=default_metadata();missing_env=private_env.copy();missing_env.pop('MACRUNNER_APP_DATA_ROOT')
    refused=bounded([app/'Contents/MacOS/MacRunner','--run-app-entry',PROBES/'absent.exe','1',out/'must-not-exist.json'],env=missing_env)
    (out/'missing-root.stdout.raw').write_bytes(refused.stdout);(out/'missing-root.stderr.raw').write_bytes(refused.stderr)
    after=default_metadata()
    assert refused.returncode==2 and b'APP_PATH_REFUSED' in refused.stderr and not (out/'must-not-exist.json').exists()
    assert before==after, 'default bottle metadata changed during negative control'
    save(out/'ISOLATION.json',dict(paths=paths,dry_returncode=dry.returncode,negative_returncode=refused.returncode,
         default_metadata_before=before,default_metadata_after=after,default_state='NO_OBSERVED_CHANGE',limits='metadata plus first guard before IO; no global tracing'))
    print('GATE dry-isolated-paths PASS '+json.dumps(paths,sort_keys=True),flush=True)
    print('GATE negative-missing-data-root PASS rc=2 defaultMetadata=UNCHANGED',flush=True)
    preflight_results=[dict(name='dry-isolated-paths',result='PASS',observed='ISOLATED_PATHS',returncode=0),
                       dict(name='negative-missing-data-root',result='PASS',observed='REFUSED_BEFORE_IO',returncode=2)]
    if args.callback_negative_only:builds=[('callback','callback32.c',['-luser32'])]
    elif args.cdrom_only:builds=[('cdrom','cdrom32.c',[])]
    elif args.message_only:builds=[('message','message32.c',['-luser32'])]
    elif args.env_only:builds=[('env','env32.c',[])]
    else:builds=[('message','message32.c',['-luser32']),('ddraw','ddraw32.c',['-lddraw','-luser32']),('callback','callback32.c',['-luser32']),('cdrom','cdrom32.c',[]),('env','env32.c',[])]
    build_records=[];parser_sha=sha(Path(__file__))
    for folder,source,libs in builds:
        (out/folder).mkdir();name='Diablo.exe' if folder=='cdrom' else 'Heroes3.exe'
        # Keep a valid ordinary caller EBP; only the inline assembly should
        # introduce the non-pointer for the targeted callback.
        frame_flag='-fno-omit-frame-pointer' if folder=='callback' else '-fomit-frame-pointer'
        command=['nice','-n','20','i686-w64-mingw32-clang',PROBES/source,'-O2',frame_flag,'-o',out/folder/name,*libs]
        build=bounded(command,timeout=30);(out/(folder+'-build.log')).write_bytes(build.stdout+build.stderr)
        assert build.returncode==0,folder+' probe compile failed'
        probe=out/folder/name;source_sha=sha(PROBES/source);probe_bytes=probe.read_bytes()
        assert probe_bytes[:2]==b'MZ', 'probe is not a PE executable'
        if folder=='message':
            for marker in [b'FAMILY_FINAL_RESULT',b'MessageBox_caption_cross_thread',b'MessageBox_body_cross_thread',b'INSPECTOR_STARTED']:
                assert marker in probe_bytes,'current message probe marker missing: '+marker.decode()
        build_records.append(dict(probe=folder,source=str((PROBES/source).relative_to(ROOT)),sourceSHA256=source_sha,
                                  executable=str(probe.relative_to(ROOT)),executableSHA256=sha(probe),parserSHA256=parser_sha,
                                  compilerArgv=list(map(str,command)),compilerReturncode=build.returncode))
    save(out/'PROBE-BUILD.json',dict(parserSHA256=parser_sha,probes=build_records))
    if not args.callback_negative_only and not args.message_only and not args.env_only:
        if not args.cdrom_only:shutil.copy2(out/'ddraw/Heroes3.exe',out/'ddraw/APP32NoModeset.exe')
        if args.diablo_data:
            assert args.diablo_data.is_file();os.symlink(args.diablo_data.resolve(),out/'cdrom/DIABDAT.MPQ')
        else:(out/'cdrom/DIABDAT.MPQ').write_bytes(b'MPQ\x1aAPP32 gate fixture: no game payload\n')
        (out/'cdrom-empty').mkdir();shutil.copy2(out/'cdrom/Diablo.exe',out/'cdrom-empty/Diablo.exe')
    # Native wow64win loads from WINEDLLPATH's engine, not the prefix copy.
    old_app=None
    def replace_selected(relative,source,label):
        old_engine=old_app/'Contents/Resources/engine';destination=old_engine/relative
        assert bounded(['cp','-p',destination,out/(label+'.БЫЛО')]).returncode==0
        assert bounded(['cp','-p',source,destination]).returncode==0
        manifest_path=old_engine/'ENGINE.json';manifest=json.loads(manifest_path.read_text())
        manifest['files'][relative]=sha(destination)
        manifest_path.write_text(json.dumps(manifest,ensure_ascii=False,indent=2)+'\n')
        assert bounded(['codesign','--force','--sign','-','--options','runtime',old_app],timeout=30).returncode==0
        assert bounded(['codesign','--verify','--strict',old_app],timeout=30).returncode==0
    if not args.callback_negative_only and not args.cdrom_only and not args.message_only and not args.env_only:
        old_app=out/'OldModule.app'
        assert bounded(['cp','-c','-R',app,old_app],timeout=120).returncode==0
        assert bounded(['cp','-p',old_app/'Contents/MacOS/MacRunner',out/'old-clone-MacRunner.БЫЛО']).returncode==0
        replace_selected('wine/lib/wine/aarch64-windows/wow64win.dll',old,'old-clone-wow64win')
    slot=None;results=list(preflight_results);start=time.monotonic();prefix=data/'Bottles/Default';env=None
    while slot is None:
        acquired=bounded(['scripts/wine-slot.sh','acquire','APP32','func'])
        save(out/'waiter-heartbeat.json',dict(utc=datetime.datetime.now(datetime.timezone.utc).isoformat(),state='WAITING',returncode=acquired.returncode))
        if acquired.returncode==0:slot=acquired.stdout.decode().strip()
        else:time.sleep(30)
    base=os.environ.copy();base.update(MACRUNNER_APP_DATA_ROOT=str(data),TMPDIR=str(out/'tmp')+'/',MACRUNNER_ACCEPTANCE_KEEP_INPUT_SOURCE='1')
    base.pop('MACRUNNER_BUNDLED_ENGINE',None)
    base['APP32_ACCEPTANCE_ENV_TEST']='PARENT_MUST_NOT_LEAK'
    def stopped():
        opened=bounded(['/usr/sbin/lsof','-nP','-t','+D',prefix],timeout=10)
        if opened.returncode!=1 or opened.stdout or opened.stderr:raise RuntimeError('private prefix not stopped')
    def execute(label,exe,guest,through_app,expected,selected_app=None,acceptance_env=None):
        nonlocal env
        assert sha(Path(__file__))==parser_sha, 'gate parser changed after probe compilation'
        probe_name='cdrom' if exe.parent.name=='cdrom-empty' else exe.parent.name
        record=next(r for r in build_records if r['probe']==probe_name)
        assert sha(ROOT/record['source'])==record['sourceSHA256'] and sha(exe)==record['executableSHA256'], 'probe source/executable drift before launch'
        current_app=selected_app or app;current_engine=current_app/'Contents/Resources/engine'
        before=set((data/'Runs').glob('*/engine.log')) if (data/'Runs').exists() else set()
        result_path=out/(label+'.APP-RESULT.json');log_path=out/(label+'.log')
        argv=[current_app/'Contents/MacOS/MacRunner','--run-app-entry',exe,'45',result_path,'--acceptance-probe',*guest] if through_app else [engine/'wine/bin/wine','Z:'+str(exe).replace('/','\\'),*guest]
        if acceptance_env:
            assert through_app, 'acceptance env is only an app entry argument'
            for key,value in sorted(acceptance_env.items()):argv+=['--acceptance-env',key+'='+value]
        active_env=base if through_app else env
        assert active_env is not None
        began=time.monotonic();mapped=False;owned_pid=None;owned_identity=None;screenshot_attempts=0;stall_sampled=False
        with log_path.open('wb') as log:
            child=subprocess.Popen(list(map(str,argv)),env=active_env,cwd=exe.parent,stdin=subprocess.DEVNULL,stdout=log,stderr=subprocess.STDOUT,start_new_session=True)
            while child.poll() is None and time.monotonic()-began<60:
                new=[p for p in (data/'Runs').glob('*/engine.log') if p not in before] if (data/'Runs').exists() else []
                pids=[child.pid] if not through_app else []
                for source in new:
                    raw=source.read_text(errors='replace')
                    for line in raw.splitlines():
                        if 'owned-process pid=' in line and exe.name in line:
                            try: argument=json.loads(line.split(' argv=',1)[1])[0]
                            except (ValueError,IndexError):continue
                            if argument.replace('\\','/').split('/')[-1]!=exe.name:continue
                            m=re.search(r'owned-process pid=(\d+)',line)
                            if m:pids.append(int(m.group(1)))
                if not mapped:
                    for pid in pids:
                        capture=bounded(['/usr/sbin/lsof','-a','-p',str(pid),'-Fn'],timeout=3)
                        if b'wow64win.dll' in capture.stdout:
                            identity=bounded(['ps','-p',str(pid),'-o','lstart='],timeout=3)
                            if identity.returncode!=0 or not identity.stdout.strip():continue
                            (out/(label+'.loaded.raw')).write_bytes(capture.stdout)
                            owned_pid=pid;owned_identity=identity.stdout.strip();mapped=True;break
                # Reuse the existing window enumerator. A Wine dialog may have
                # an empty native title: select solely by proven PID and size.
                if label=='app-message' and owned_pid and .7<time.monotonic()-began<4 and screenshot_attempts<2:
                    identity=bounded(['ps','-p',str(owned_pid),'-o','lstart='],timeout=3)
                    if identity.stdout.strip()==owned_identity:
                        winlist=ROOT/'artifacts/claude-hb-work/hk-native-vs-ours-20260929/harness/winlist'
                        if winlist.exists():
                            listed=bounded([winlist,str(owned_pid)],timeout=4)
                            stem=label+'-window-'+str(screenshot_attempts)
                            (out/(stem+'.winlist.raw')).write_bytes(listed.stdout+listed.stderr)
                            shots=[]
                            for line in listed.stdout.decode(errors='replace').splitlines():
                                fields=line.split(maxsplit=3)
                                if len(fields)<3 or not all(v.isdecimal() for v in fields[:3]):continue
                                wid,width,height=map(int,fields[:3])
                                if width<200 or height<60:continue
                                image=out/(stem+'-w'+str(wid)+'.png')
                                captured=bounded(['/usr/sbin/screencapture','-l',str(wid),'-o','-x','-t','png',image],timeout=5)
                                (out/(image.stem+'.stderr.raw')).write_bytes(captured.stderr)
                                shots.append(dict(window=wid,returncode=captured.returncode,state='PRESENT' if image.exists() else 'FAILED',sha256=sha(image) if image.exists() else None))
                            save(out/(stem+'.json'),dict(pid=owned_pid,identity=owned_identity.decode(),list_returncode=listed.returncode,images=shots,state='PRESENT' if shots else 'EMPTY'))
                    screenshot_attempts+=1
                # One bounded stack snapshot for the proven current inspector
                # pre-entry stall, before owned cleanup; never a timing result.
                if label=='app-message' and owned_pid and time.monotonic()-began>=5 and not stall_sampled:
                    retained='\n'.join(p.read_text(errors='replace') for p in new)
                    if 'INSPECTOR_CREATE handle=' in retained and 'INSPECTOR_STARTED' not in retained:
                        identity=bounded(['ps','-p',str(owned_pid),'-o','lstart='],timeout=3)
                        if identity.stdout.strip()==owned_identity:
                            sampled=bounded(['/usr/bin/sample',str(owned_pid),'1','1','-file',out/(label+'.host-stall.raw')],timeout=10)
                            (out/(label+'.sample.stderr.raw')).write_bytes(sampled.stdout+sampled.stderr)
                            save(out/(label+'.sample.json'),dict(pid=owned_pid,returncode=sampled.returncode,state='PRESENT' if (out/(label+'.host-stall.raw')).exists() else 'FAILED',classification='NOT_GOLDEN',exclusion='one-second stack collection'))
                    stall_sampled=True
                save(out/'waiter-heartbeat.json',dict(utc=datetime.datetime.now(datetime.timezone.utc).isoformat(),state='RUNNING',case=label,app_pid=child.pid,elapsed_seconds=time.monotonic()-began))
                time.sleep(.2)
            if child.poll() is None:
                owned=env or base;owned=dict(owned,WINEPREFIX=str(prefix),TMPDIR=str(out/'tmp')+'/')
                bounded([engine/'wine/bin/wineserver','-k'],env=owned)
                try:child.wait(timeout=10)
                except subprocess.TimeoutExpired:child.terminate();child.wait(timeout=5)
        new=[p for p in (data/'Runs').glob('*/engine.log') if p not in before] if (data/'Runs').exists() else []
        text=log_path.read_text(errors='replace')
        for source in new:
            text+='\n'+source.read_text(errors='replace')
            receipt=source.parent/'launch-receipt.json'
            if receipt.exists():
                value=json.loads(receipt.read_text())
                # Reconstruct the sealed child, never merge unrelated parent
                # variables back into direct controls or environment assertions.
                env={key:base[key] for key in value.get('privateEnvironmentKeys',[]) if key in base}
                env.update(value['environment'])
                assert Path(env['WINEPREFIX']).resolve()==prefix.resolve()
                save(out/(label+'.launch.json'),value)
        if env is not None:
            cleanup=bounded([engine/'wine/bin/wineserver','-k'],env=env)
            drained=bounded([engine/'wine/bin/wineserver','-w'],env=env)
            save(out/(label+'.server.json'),dict(kill_returncode=cleanup.returncode,wait_returncode=drained.returncode,scope='private gate prefix'))
        if guest and guest[0]=='--gate-env':
            final=re.search(r'ENV_RESULT present=(\d) bytes=(\d+) value_hex=([0-9a-f]*) argv_extra=0 result=(PASS|FAIL)',text)
            observed=final.group(4) if final else 'MISSING'
            result=json.loads(result_path.read_text()) if result_path.exists() else {}
            supplied=acceptance_env or {}
            ok=observed=='PASS' and result.get('acceptance_environment')==supplied and result.get('env_overrides')==sorted(supplied)
            if env is not None:
                if supplied:ok=ok and all(env.get(key)==value for key,value in supplied.items())
                else:ok=ok and 'APP32_ACCEPTANCE_ENV_TEST' not in env
            else:ok=False
            ok=ok and '--acceptance-env' not in result.get('args',[]) and result.get('rc')==0
        elif guest and guest[0]=='--gate-message':
            final=re.search(r'FAMILY_FINAL_RESULT checks=(\d+) failures=(\d+) result=(PASS|FAIL)',text)
            if final is None and expected=='FAIL':
                final=re.search(r'FAMILY_RESULT checks=(\d+) failures=(\d+) result=(PASS|FAIL)',text)
            observed=final.group(3) if final else 'MISSING'
            ok=observed==expected and (expected!='PASS' or int(final.group(1))>=28)
            if expected=='FAIL':
                ok=ok and bool(re.search(r'FAMILY_CHECK name=WM_GETTEXT_W result=FAIL',text)) and bool(re.search(r'FAMILY_CHECK name=WM_GETTEXTLENGTH_W result=FAIL',text))
        elif guest and guest[0]=='--gate-callback':
            final=re.search(r'RESULT (PASS|FAIL) checks=(\d+)',text)
            crash=bool(re.search(r'BEGIN callback-ebp value=0001006e',text) and re.search(r'macrunner-hb-first-chance[^\n]*code=c0000005[^\n]*info1=1006e\b',text))
            observed=final.group(1) if final else ('CRASH' if crash else 'MISSING')
            ok=(observed=='PASS' and int(final.group(2))==3) if expected=='PASS' else observed=='CRASH'
        elif guest and guest[0]=='--gate-cdrom':
            final=re.search(r'RESULT (PASS|FAIL) checks=(\d+)',text)
            observed=final.group(1) if final else 'MISSING';ok=observed=='PASS' and int(final.group(2))==3
        elif guest and guest[0]=='--gate-media-missing':
            result=json.loads(result_path.read_text()) if result_path.exists() else {}
            ok=result.get('status')=='FAIL' and 'DIABDAT.MPQ' in result.get('error','') and not re.search(r'engine: pid=\d+',text)
            observed='REFUSED_WITH_DATA_ERROR' if ok else 'MISSING'
        else:
            final=re.search(r'DDRAW_RESULT failures=(\d+) elapsed_ms=(\d+) result=(PASS|FAIL)',text)
            observed=final.group(3) if final else 'MISSING'
            boundary=re.search(r'DDRAW_CHECK name=SetDisplayMode800x600x16 result=FAIL hr=([0-9a-f]+)',text)
            ok=observed==expected and (expected!='FAIL' or (boundary is not None and boundary.group(1)=='80004001'))
        checks=re.findall(r'(?:(?:FAMILY|DDRAW)_CHECK|CHECK )[^\n]*',text)
        for check in checks:print(label+' '+check,flush=True)
        summary=dict(name=label,via='APP_ENTRY' if through_app else 'DIRECT_WINE_CONTROL',expected=expected,observed=observed,
            result='PASS' if ok else 'FAIL',returncode=child.returncode,elapsed_seconds=time.monotonic()-began,
            loaded_maps='PRESENT' if mapped else 'EMPTY',prefix_wow64win_sha256=sha(prefix/'drive_c/windows/system32/wow64win.dll'),
            log_sha256=sha(log_path),probe_sha256=sha(exe),app_sha256=sha(current_app/'Contents/MacOS/MacRunner'),manifest_sha256=sha(current_engine/'ENGINE.json'))
        results.append(summary);save(out/(label+'.json'),summary);print('GATE '+label+' '+summary['result']+' observed='+observed+' expected='+expected,flush=True)
        stopped()
    try:
        if args.callback_negative_only:
            execute('negative-package-callback',out/'callback/Heroes3.exe',['--gate-callback'],True,'CRASH')
        elif args.message_only:
            execute('app-message',out/'message/Heroes3.exe',['--gate-message'],True,'PASS')
            execute('direct-message',out/'message/Heroes3.exe',['--gate-message'],False,'PASS')
        elif args.env_only:
            execute('app-explicit-env',out/'env/Heroes3.exe',['--gate-env','present'],True,'PASS',acceptance_env={'APP32_ACCEPTANCE_ENV_TEST':r'Z:\acceptance path\314159=x87'})
            execute('app-no-env',out/'env/Heroes3.exe',['--gate-env','absent'],True,'PASS')
        elif args.cdrom_only:
            execute('app-cdrom',out/'cdrom/Diablo.exe',['--gate-cdrom'],True,'PASS')
            execute('negative-missing-media',out/'cdrom-empty/Diablo.exe',['--gate-media-missing'],True,'REFUSED_WITH_DATA_ERROR')
        else:
            execute('app-message',out/'message/Heroes3.exe',['--gate-message'],True,'PASS')
            execute('app-ddraw',out/'ddraw/Heroes3.exe',[],True,'PASS')
            execute('direct-message',out/'message/Heroes3.exe',['--gate-message'],False,'PASS')
            execute('direct-ddraw',out/'ddraw/Heroes3.exe',[],False,'PASS')
            execute('app-callback',out/'callback/Heroes3.exe',['--gate-callback'],True,'PASS')
            execute('direct-callback',out/'callback/Heroes3.exe',['--gate-callback'],False,'PASS')
            execute('app-cdrom',out/'cdrom/Diablo.exe',['--gate-cdrom'],True,'PASS')
            execute('negative-missing-media',out/'cdrom-empty/Diablo.exe',['--gate-media-missing'],True,'REFUSED_WITH_DATA_ERROR')
            stopped()
            execute('app-explicit-env',out/'env/Heroes3.exe',['--gate-env','present'],True,'PASS',acceptance_env={'APP32_ACCEPTANCE_ENV_TEST':r'Z:\acceptance path\314159=x87'})
            execute('app-no-env',out/'env/Heroes3.exe',['--gate-env','absent'],True,'PASS')
            execute('negative-old-message',out/'message/Heroes3.exe',['--gate-message'],True,'FAIL',old_app)
            # Same clone, stopped server: restore current message DLL before
            # replacing only the native callback module for the second control.
            replace_selected('wine/lib/wine/aarch64-windows/wow64win.dll',candidate,'old-message-control-restore')
            replace_selected('wine/lib/wine/aarch64-windows/wow64.dll',old_wow64,'old-native-callback')
            execute('negative-old-callback',out/'callback/Heroes3.exe',['--gate-callback'],True,'CRASH',old_app)
            global_modeset(prefix,'N')
            execute('negative-no-modeset',out/'ddraw/APP32NoModeset.exe',[],True,'FAIL')
    finally:
        if env is not None:
            bounded([engine/'wine/bin/wineserver','-k'],env=env);bounded([engine/'wine/bin/wineserver','-w'],env=env)
        bounded(['scripts/wine-slot.sh','release','APP32',slot])
    passed=len(results)==(3 if args.callback_negative_only else 4 if args.cdrom_only or args.message_only or args.env_only else 15) and all(x['result']=='PASS' for x in results)
    save(out/'RESULT.json',dict(classification='DIAGNOSTIC_ONLY/NOT_GOLDEN',result='PASS' if passed else 'FAIL',elapsed_seconds=time.monotonic()-start,
        acceptance='NEGATIVE_CALLBACK_REPRODUCTION_ONLY' if args.callback_negative_only else 'CDROM_PROFILE_ONLY' if args.cdrom_only else 'MESSAGE_PROBE_ONLY' if args.message_only else 'ACCEPTANCE_ENV_ONLY' if args.env_only else 'FULL_APP32_GATE',
        old_wow64win_sha256=sha(old),candidate_wow64win_sha256=sha(candidate),old_wow64_sha256=sha(old_wow64),candidate_wow64_sha256=sha(wow64),cases=results))
    return 0 if passed else 1

if __name__=='__main__':raise SystemExit(main())
