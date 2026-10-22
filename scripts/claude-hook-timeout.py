#!/usr/bin/env python3
"""One ordinary-CLI timeout observation; never answers an Agent question.

Only the explicit --run mode creates the single isolated CLI task. --observe-hook
is an inert stdout/timing observer around the real native helper, not a CLI launcher.
All fixture credentials below are public constants, not provisioned identities.
"""
from pathlib import Path
import datetime, hashlib, json, os, re, shlex, shutil, signal, socket
import sqlite3, subprocess, sys, tempfile, time, urllib.error, urllib.request, uuid

REPO = Path(__file__).resolve().parents[1]
EVIDENCE = REPO / 'evidence/claude-hook-timeout'
BINARY = REPO / 'dist/macos-arm64/agentinbox'
EXPECTED_BINARY_SHA = '553f2131319e84bf85eae34dc2e514aae57c170fcb06e3fc33851f2d2f950a1f'
HOST_TOKEN = 'public-claude-timeout-host-fixture-v1'
DEVICE_TOKEN = 'public-claude-timeout-device-fixture-v1'
QUESTION = 'AGENTINBOX_CHOOSE_ROUTE'
PROMPT = ('AgentInbox isolated hook timeout fixture. Do not read files, run commands, '
          'modify files, or change settings. Call AskUserQuestion exactly once with '
          'question AGENTINBOX_CHOOSE_ROUTE, header Route, options Alpha (test alpha) '
          'and Beta (test beta), multiSelect false. Do not choose an answer yourself '
          'or fabricate a tool result. Wait for the actual user response. If the real '
          'tool returns Beta, output exactly AGENTINBOX_RECEIVED:Beta. Do not ask '
          'another question or retry if interrupted. A hook failure is not an answer '
          'or approval.')

def utc(): return datetime.datetime.now(datetime.timezone.utc).isoformat()
def save(name, value):
    path = EVIDENCE / name
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n')
    return path
def command(args, check=True):
    result = subprocess.run([str(x) for x in args], capture_output=True, text=True, timeout=20)
    if check and result.returncode:
        raise RuntimeError(f'{args[0]} exit {result.returncode}: {result.stderr[:180]}')
    return result
def process_identity(pid):
    result = command(['/bin/ps','-p',str(pid),'-o','lstart=','-o','comm='],False)
    return result.stdout.strip() if result.returncode == 0 else None
def same_process(pid, identity): return bool(identity) and process_identity(pid) == identity
def request(base, token, path, body=None):
    data = None if body is None else json.dumps(body).encode()
    req = urllib.request.Request(base + path, data=data,
        headers={'Authorization':'Bearer ' + token,'Content-Type':'application/json','Connection':'close'})
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    try:
        with opener.open(req,timeout=4) as reply: return reply.status,json.load(reply)
    except urllib.error.HTTPError as error: return error.code,json.load(error)
def until(label, test, seconds):
    deadline=time.monotonic()+seconds
    while time.monotonic()<deadline:
        value=test()
        if value: return value
        time.sleep(.1)
    raise RuntimeError(f'{label}: {seconds}s observation deadline; no retry task created')
def native_audit(summary):
    transcript=Path(summary['transcriptPath'])
    tool_uses=[];results=[];final=[]
    for line in transcript.read_text().splitlines() if transcript.exists() else []:
        try: row=json.loads(line)
        except json.JSONDecodeError: continue
        if row.get('type') not in ('assistant','user'): continue
        blocks=row.get('message',{}).get('content',[])
        if isinstance(blocks,str): blocks=[{'type':'text','text':blocks}]
        for block in blocks:
            if block.get('type')=='tool_use':
                tool_uses.append({'id':block.get('id'),'name':block.get('name')})
            if block.get('type')=='tool_result' and block.get('tool_use_id')==summary['toolUseId']:
                results.append({'toolUseId':block['tool_use_id'],'isError':block.get('is_error',False)})
            if row.get('type')=='assistant' and block.get('type')=='text' and 'AGENTINBOX_RECEIVED:' in block.get('text',''):
                final.append(block['text'])
    return {'nativeToolUses':tool_uses,
        'matchingOriginalToolUseCount':sum(x['id']==summary['toolUseId'] for x in tool_uses),
        'matchingOriginalToolResultCount':len(results),'originalToolResults':results,
        'otherToolUseNames':[x['name'] for x in tool_uses if x['name']!='AskUserQuestion'],
        'finalReceivedMarkerCount':len(final)}
def observe_hook(config_path):
    config=json.loads(Path(config_path).read_text())
    raw=sys.stdin.buffer.read();event=json.loads(raw)
    questions=event.get('tool_input',{}).get('questions',[])
    summary={'observedAtUTC':utc(),'observerStartedMonotonic':time.monotonic(),
        'sessionId':event.get('session_id'),'promptId':event.get('prompt_id'),
        'toolUseId':event.get('tool_use_id'),'hookEventName':event.get('hook_event_name'),
        'toolName':event.get('tool_name'),'cwd':event.get('cwd'),
        'transcriptPath':event.get('transcript_path'),'questions':questions,
        'observerPid':os.getpid(),'outerHookTimeoutSeconds':10,'helperReadTimeoutSeconds':5}
    assert summary['sessionId']==config['sessionId']
    assert summary['cwd']==config['cwd']
    assert summary['hookEventName']=='PreToolUse' and summary['toolName']=='AskUserQuestion'
    assert len(questions)==1 and questions[0]['question']==QUESTION
    assert [o['label'] for o in questions[0]['options']]==['Alpha','Beta']
    assert not questions[0].get('multiSelect',False)
    child=subprocess.Popen([config['binary'],'hook',config['ipcSocket'],'5'],
        stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
    summary['helperPid']=child.pid;summary['helperProcessIdentity']=process_identity(child.pid)
    save('native-hook.json',summary)
    output,stderr=child.communicate(raw)
    finished=time.monotonic()
    save('helper-return.json',{'finishedAtUTC':utc(),'finishedMonotonic':finished,
        'elapsedSeconds':finished-summary['observerStartedMonotonic'],
        'helperExitCode':child.returncode,'stdout':output.decode(),
        'stdoutJSON':json.loads(output),'stderr':stderr.decode(),
        'helperReadTimeoutSeconds':5,'outerHookTimeoutSeconds':10,
        'observerForwardedNativeOutputUnchanged':True})
    sys.stdout.buffer.write(output);sys.stdout.buffer.flush()
    if stderr: sys.stderr.buffer.write(stderr);sys.stderr.buffer.flush()
    raise SystemExit(child.returncode)

def run():
    EVIDENCE.mkdir(parents=True,exist_ok=True)
    attempt=EVIDENCE/'attempt.json'
    if attempt.exists(): raise RuntimeError('This single-run attempt already exists; no retry allowed')
    old=json.loads((REPO/'evidence/claude-live/launch.json').read_text())
    cwd=Path(old['pane'].split('|',2)[2]).resolve()
    assert str(cwd).endswith('/p0/tasks/claude-interactive') and cwd.is_dir()
    assert hashlib.sha256(BINARY.read_bytes()).hexdigest()==EXPECTED_BINARY_SHA
    version=command([old['cliArgs'][0],'--version']).stdout.strip()
    session=str(uuid.uuid4());host_id='claude-timeout-'+str(uuid.uuid4())
    tmux_socket='agentinbox-timeout-'+uuid.uuid4().hex[:8]
    assert command(['tmux','-L',tmux_socket,'has-session'],False).returncode!=0
    runtime=Path(tempfile.mkdtemp(prefix='ainb-ct-',dir='/tmp'));runtime.chmod(0o700)
    ipc=runtime/'state/ipc/hook.sock'
    save('attempt.json',{'startedAtUTC':utc(),'singleAttempt':True,'status':'started',
        'claudeVersion':version,'binarySHA256':EXPECTED_BINARY_SHA,'cwd':str(cwd),
        'sessionId':session,'hostId':host_id,'tmuxSocket':tmux_socket,
        'runtimeDirectory':str(runtime),'installedServicesTouched':False,
        'globalSettingsChanged':False,'phoneOrPairingUsed':False})
    children=[];handles=[];cli_pid=None;cli_identity=None;summary=None;product=None
    proof={'scope':'ordinary real Claude CLI with temporary isolated hook settings; no phone answer',
        'claudeVersion':version,'helperReadTimeoutSeconds':5,'outerHookTimeoutSeconds':10,
        'hostConfiguredTTLSeconds':60,'hookSettingsAreTemporary':True,
        'defaultGlobalHookChainVerified':False,'installedServicesTouched':False,
        'globalSettingsChanged':False,'phoneOrPairingUsed':False,'passed':False}
    try:
        with socket.socket() as listener:
            listener.bind(('127.0.0.1',0));port=listener.getsockname()[1]
        base=f'http://127.0.0.1:{port}'
        relay_config={'listen':f'127.0.0.1:{port}','database':str(runtime/'relay.sqlite'),
            'credentials':[{'id':'public-timeout-host','role':'host','hostId':host_id,'token':HOST_TOKEN},
                           {'id':'public-timeout-device','role':'device','token':DEVICE_TOKEN}], 'apns':None}
        (runtime/'relay.json').write_text(json.dumps(relay_config));(runtime/'relay.json').chmod(0o600)
        token=runtime/'public-fixture-token';token.write_text(HOST_TOKEN);token.chmod(0o600)
        host_config={'hostId':host_id,'relayUrl':base,'tokenFile':str(token),
            'stateDir':str(runtime/'state'),'ipcSocket':str(ipc),'scopes':[str(cwd)],
            'codexSocket':None,'threadIds':[],'requestTtl':60}
        (runtime/'host.json').write_text(json.dumps(host_config));(runtime/'host.json').chmod(0o600)
        def start(role,config):
            output=(EVIDENCE/f'{role}.log').open('w');handles.append(output)
            child=subprocess.Popen([str(BINARY),role,*(['--config',str(config)] if role=='relay' else [str(config)])],stdout=output,stderr=subprocess.STDOUT)
            children.append((child,process_identity(child.pid)));return child
        start('relay',runtime/'relay.json')
        def ready_relay():
            try:return request(base,DEVICE_TOKEN,'/v1/requests')[0]==200
            except OSError:return False
        until('isolated loopback relay startup',ready_relay,5)
        start('host',runtime/'host.json')
        def status():
            result=command([BINARY,'hostctl',ipc,'status'],False)
            return json.loads(result.stdout) if result.returncode==0 else None
        until('isolated host startup',lambda:ipc.exists() and (status() or {}).get('startupReconciled'),5)
        observer={'binary':str(BINARY),'ipcSocket':str(ipc),'sessionId':session,'cwd':str(cwd)}
        observer_path=runtime/'observer.json';observer_path.write_text(json.dumps(observer));observer_path.chmod(0o600)
        observer_command=shlex.join([sys.executable,str(Path(__file__).resolve()),'--observe-hook',str(observer_path)])
        settings={'hooks':{'PreToolUse':[{'matcher':'AskUserQuestion','hooks':[{'type':'command','command':observer_command,'timeout':10}]}]}}
        settings_path=EVIDENCE/'settings.json';settings_path.write_text(json.dumps(settings,indent=2)+'\n')
        args=[old['cliArgs'][0],'--settings',str(settings_path),'--setting-sources','',
            '--strict-mcp-config','--mcp-config','{"mcpServers":{}}','--tools','AskUserQuestion',
            '--disable-slash-commands','--effort','low','--session-id',session,
            '--name','AgentInbox isolated hook timeout observation',PROMPT]
        save('launch.json',{'cliArgs':args,'ordinaryInteractiveCLI':True,'stdioSDKHost':False,
            'tmuxSocket':tmux_socket,'cwd':str(cwd),'settingSources':'empty: existing global/project hooks excluded',
            'observerOnlyWrapsNativeHookCommand':True,'answersOrPtyKeysSent':False})
        command(['tmux','-L',tmux_socket,'new-session','-d','-s','timeout','-x','120','-y','38','-c',str(cwd),'exec '+shlex.join(args)])
        pane=command(['tmux','-L',tmux_socket,'display-message','-p','-t','timeout:0.0','#{pane_id}|#{pane_pid}|#{pane_current_path}']).stdout.strip()
        pane_id,pid,pane_cwd=pane.split('|',2);cli_pid=int(pid);cli_identity=process_identity(cli_pid)
        assert cli_identity and pane_cwd==str(cwd)
        proof.update({'cliPid':cli_pid,'cliProcessIdentity':cli_identity,'paneId':pane_id,
            'sessionId':session,'hostId':host_id,'runtimeDirectory':str(runtime)})
        def capture():
            result=command(['tmux','-L',tmux_socket,'capture-pane','-p','-t',pane_id,'-S','-90'],False)
            return result.stdout
        def find_pending():
            screen=capture()
            if any(phrase in screen.lower() for phrase in ('trust this folder','trust this workspace','please log in','sign in to continue')):
                raise RuntimeError('Trust/login interstitial observed; no input accepted')
            if not same_process(cli_pid,cli_identity):raise RuntimeError('Own CLI exited before exact native hook')
            rows=request(base,DEVICE_TOKEN,'/v1/requests')[1]['requests']
            if rows:return rows[0]
            if (EVIDENCE/'helper-return.json').exists():raise RuntimeError('Helper returned before a pending binding was captured')
            return None
        product=until('one real native pending request',find_pending,60)
        assert product['state']=='pending' and product['sessionId']==session and product['engine']=='claude'
        assert product['body']==QUESTION and [x['label'] for x in product['options']]==['Alpha','Beta']
        save('pending-binding.json',product)
        until('native helper completion without outer hook kill',lambda:(EVIDENCE/'helper-return.json').exists(),12)
        returned=json.loads((EVIDENCE/'helper-return.json').read_text());summary=json.loads((EVIDENCE/'native-hook.json').read_text())
        assert returned['helperExitCode']==0 and returned['stdoutJSON']=={}
        assert returned['elapsedSeconds']<10,'Outer hook budget reached; natural native-helper completion not proven'
        assert summary['sessionId']==product['sessionId'] and summary['toolUseId']==product['nativeRequestId']
        assert summary['promptId']==product['turnId']
        time.sleep(max(0,returned['finishedMonotonic']+2-time.monotonic()))
        screen=capture();lines=screen.splitlines();markers=[i for i,line in enumerate(lines) if QUESTION in line]
        excerpt='\n'.join(lines[markers[-1]:] if markers else lines[-25:]).strip()+'\n'
        (EVIDENCE/'screen-after-helper-return.txt').write_text(excerpt)
        audit=native_audit(summary);save('native-audit-before-cleanup.json',audit)
        assert audit['matchingOriginalToolUseCount']==1 and audit['matchingOriginalToolResultCount']==0
        assert not audit['otherToolUseNames'] and audit['finalReceivedMarkerCount']==0
        assert same_process(cli_pid,cli_identity)
        assert QUESTION in excerpt and 'Alpha' in excerpt and 'Beta' in excerpt
        visible_option_rows=bool(re.search(r'(?m)^\s*[❯>]?\s*1[.)]\s+Alpha',excerpt)) and bool(re.search(r'(?m)^\s*[❯>]?\s*2[.)]\s+Beta',excerpt))
        native_waiting_instruction=any(x in excerpt.lower() for x in ('enter to select','enter to confirm','esc to cancel','↑/↓','arrow keys'))
        assert visible_option_rows and native_waiting_instruction,'Native waiting UX not established; preserve own excerpt for review'
        def terminal_product():
            row=request(base,DEVICE_TOKEN,f'/v1/requests/{product["requestId"]}')[1]
            return row if row['state'] in ('expired','invalidated') else None
        terminal=until('old bound product closes without answer',terminal_product,5)
        beta=next(x['id'] for x in product['options'] if x['label']=='Beta')
        late_status,late=request(base,DEVICE_TOKEN,f'/v1/requests/{product["requestId"]}/responses',
            {'requestId':product['requestId'],'responseId':str(uuid.uuid4()),'revision':product['revision'],'optionIds':[beta],'text':None,'answers':{}})
        assert late_status==409
        with sqlite3.connect(f'file:{runtime / "relay.sqlite"}?mode=ro',uri=True) as db:
            responses=db.execute('SELECT COUNT(*) FROM responses WHERE request=?',(product['requestId'],)).fetchone()[0]
        host_events=[]
        for line in (EVIDENCE/'host.log').read_text().splitlines():
            try:host_events.append(json.loads(line))
            except json.JSONDecodeError:pass
        dispatches=[x for x in host_events if x.get('event')=='response-dispatched' and x.get('requestId')==product['requestId']]
        assert responses==0 and not dispatches
        proof.update({'passed':True,'binding':{k:product.get(k) for k in ('requestId','revision','hostId','runtimeId','sessionId','turnId','nativeRequestId','itemId','expiresAt')},
            'helperElapsedSeconds':returned['elapsedSeconds'],'helperOutputJSON':{},'helperExitCode':0,
            'outerHookKillObserved':False,'deadlineAttribution':'Host expires=min(hostTTL,helperDeadline); EOF and helper read limit can race. No claim that read-timeout won.',
            'nativeQuestionStillWaitingAfterHelperReturn':True,'nativeUiExcerptFile':'screen-after-helper-return.txt',
            'originalToolUseCount':1,'originalToolResultCountBeforeCleanup':0,'otherToolUseNames':[],
            'originalProductFinalState':terminal['state'],'lateBetaHTTP':late_status,'lateBetaBody':late,
            'serverResponseCount':responses,'nativeDispatchCount':len(dispatches),'answersOrPtyKeysSent':False})
    except Exception as error:
        proof['failure']=str(error)
        raise
    finally:
        cleanup={'atUTC':utc(),'onlyOwnProcesses':True,'answersOrPtyKeysSent':False,
                 'installedServicesTouched':False,'globalSettingsChanged':False,'phoneOrPairingUsed':False}
        if cli_pid and same_process(cli_pid,cli_identity):
            os.kill(cli_pid,signal.SIGTERM)
            deadline=time.monotonic()+5
            while same_process(cli_pid,cli_identity) and time.monotonic()<deadline:time.sleep(.1)
            cleanup['ownCliStopped']=not same_process(cli_pid,cli_identity)
        if command(['tmux','-L',tmux_socket,'has-session'],False).returncode==0:
            command(['tmux','-L',tmux_socket,'kill-server'],False)
        if cli_pid:
            cleanup['ownCliStopped']=not same_process(cli_pid,cli_identity)
            if not cleanup['ownCliStopped']:cleanup['ownCliNeedsAttention']=True
        if (EVIDENCE/'native-hook.json').exists():
            observed=json.loads((EVIDENCE/'native-hook.json').read_text())
            helper_pid=observed.get('helperPid');identity=observed.get('helperProcessIdentity')
            if helper_pid and same_process(helper_pid,identity):os.kill(helper_pid,signal.SIGTERM)
        for child,identity in reversed(children):
            if child.poll() is None:
                assert same_process(child.pid,identity),'Own child identity changed; refusing unrelated PID signal'
                child.terminate()
                try:child.wait(timeout=5)
                except subprocess.TimeoutExpired:cleanup['ownFixtureNeedsAttention']=True
        for handle in handles:handle.close()
        cleanup['fixtureChildrenExited']=all(child.poll() is not None for child,_ in children)
        cleanup['tmuxSocketStopped']=command(['tmux','-L',tmux_socket,'has-session'],False).returncode!=0
        if summary:
            cleanup['nativeAuditAfterCleanup']=native_audit(summary)
            save('native-audit-after-cleanup.json',cleanup['nativeAuditAfterCleanup'])
        if cleanup['fixtureChildrenExited'] and cleanup['tmuxSocketStopped'] and not cleanup.get('ownCliNeedsAttention'):
            shutil.rmtree(runtime);cleanup['privateRuntimeRemoved']=True
        save('cleanup.json',cleanup);save('result.json',proof)
        state=json.loads(attempt.read_text());state['status']='passed' if proof['passed'] else 'stopped-after-one-attempt';state['finishedAtUTC']=utc();save('attempt.json',state)
        print(json.dumps({'passed':proof['passed'],'failure':proof.get('failure'),'proof':str(EVIDENCE/'result.json'),'cleanup':cleanup},ensure_ascii=False))

if __name__=='__main__':
    if len(sys.argv)==3 and sys.argv[1]=='--observe-hook':observe_hook(sys.argv[2])
    elif sys.argv[1:]==['--run']:run()
    else:raise SystemExit('Use --run for the authorized single attempt; --observe-hook is internal.')
