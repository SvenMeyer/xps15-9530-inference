#!/usr/bin/env python3
"""Per-second trace of one Strata start: tokens, CPU clocks, watts, temperatures and firmware limits. Needs no root.
CPU package watts come from a btop instance in tmux session socket strata-probe. Usage: strata-throttle-trace.py ARM ENGINE_PID OUT.jsonl"""
import glob,json,os,re,subprocess,sys,threading,time,urllib.request
arm,pid,out=sys.argv[1],int(sys.argv[2]),sys.argv[3]
def rf(p):
    try: return open(p).read().strip()
    except OSError: return None
def num(p,d=1):
    v=rf(p)
    return int(v)/d if v and v.lstrip('-').isdigit() else None
S='benchkit-src/BenchKit/src/benchkit/'
rd=lambda f:open(S+f).read().rstrip('\n')
LONG=f"Below are two Python modules from a benchmark harness.\n\n### jobs.py\n{rd('jobs.py')}\n\n### config.py\n{rd('config.py')}\n\nTask: review parse_slice and slice_label in jobs.py. List every input that is handled wrongly or inconsistently, then write a corrected version of both functions and pytest cases that cover the edge cases."
CODE="Write a Python function parse_iso8601_duration(s) that turns strings like 'P3DT4H5M6.5S' or 'PT0.25S' into seconds as a float. Reject invalid input with ValueError. Then write pytest tests for it."
PROSE="Explain to a new backend engineer how a hash map handles collisions, why the load factor matters, and when you would pick open addressing over separate chaining. Use one small worked example."
zones=[]
for z in sorted(glob.glob('/sys/class/thermal/thermal_zone*')):
    trips={}
    for p in glob.glob(z+'/trip_point_*_type'):
        k=rf(p); v=rf(p.replace('_type','_temp'))
        if k in ('hot','critical') and v and v.lstrip('-').isdigit(): trips[k]=int(v)/1000
    zones.append((rf(z+'/type'),z+'/temp',trips))
coretemp=next((d for d in glob.glob('/sys/class/hwmon/hwmon*') if rf(d+'/name')=='coretemp'),None)
smm=next((d for d in glob.glob('/sys/class/hwmon/hwmon*') if rf(d+'/name')=='dell_smm'),None)
cool={}
for c in glob.glob('/sys/class/thermal/cooling_device*'):
    t=rf(c+'/type')
    if t in ('Processor','intel_powerclamp'): cool.setdefault(t,[]).append(c+'/cur_state')
GPU={};BT={};PR={};REC={};TOK={};stop=threading.Event()
q='power.draw,power.limit,clocks.gr,clocks.mem,pcie.link.gen.current,pstate,utilization.gpu,temperature.gpu,clocks_event_reasons.active'
nv=subprocess.Popen(['nvidia-smi','--query-gpu='+q,'--format=csv,noheader,nounits','-lms','1000'],stdout=subprocess.PIPE,text=True)
def gpu_loop():
    for l in nv.stdout:
        f=[x.strip() for x in l.split(',')]
        try: GPU[int(time.time())]=dict(gw=float(f[0]),glim=float(f[1]) if f[1].replace('.','').isdigit() else None,gclk=float(f[2]),mclk=float(f[3]),pcie=int(f[4]),gps=f[5],gu=float(f[6]),gc=float(f[7]),gr=f[8])
        except (ValueError,IndexError): pass
probe=subprocess.Popen([sys.executable,'-I','-c','''import os,time
os.sched_setaffinity(0,{19})
while 1:
    t=time.perf_counter();x=0
    for i in range(200000): x+=i*i
    d=time.perf_counter()-t
    print(int(time.time()),round(1/d,3),flush=True)
    time.sleep(max(0.05,1-d))'''],stdout=subprocess.PIPE,text=True)
def probe_loop():
    for l in probe.stdout:
        a=l.split()
        if len(a)==2: PR[int(a[0])]=float(a[1])
def btop_loop():
    while not stop.wait(1):
        c=subprocess.run(['tmux','-L','strata-probe','capture-pane','-p'],capture_output=True,text=True).stdout.split('\n')
        m=re.findall(r'(\d+(?:\.\d+)?)W\b',' '.join(c[1:]))
        if m: BT[int(time.time())]=float(m[0])
def cpu_t():
    return sum(map(int,open(f'/proc/{pid}/stat').read().rsplit(')',1)[1].split()[11:13]))
def sampler():
    p=cpu_t(); pt=time.time()
    while not stop.wait(1):
        try:
            n=cpu_t(); t=time.time(); k=int(t)
            pf=[(num(f'/sys/devices/system/cpu/cpu{c}/cpufreq/scaling_cur_freq',1000) or 0) for c in (0,2,4,6,8,10)]
            ef=[(num(f'/sys/devices/system/cpu/cpu{c}/cpufreq/scaling_cur_freq',1000) or 0) for c in (12,13,14,15,16,17,18,19)]
            REC[k]=dict(t=k,pmax=max(pf),pmin=min(pf),emean=round(sum(ef)/8),engine=round((n-p)/100/(t-pt),2),
              pkgc=num(coretemp+'/temp1_input',1000) if coretemp else None,
              fan1=num(smm+'/fan1_input') if smm else None,fan2=num(smm+'/fan2_input') if smm else None,
              zones={z[0]:num(z[1],1000) for z in zones},
              pkg_thr=num('/sys/devices/system/cpu/cpu0/thermal_throttle/package_throttle_count'),
              pkg_ms=num('/sys/devices/system/cpu/cpu0/thermal_throttle/package_throttle_total_time_ms'),
              core_thr=sum(num(f'/sys/devices/system/cpu/cpu{c}/thermal_throttle/core_throttle_count') or 0 for c in (0,2,4,6,8,10)),
              proc_cool=max((num(x) or 0) for x in cool.get('Processor',[]) or ['/x']),clamp=max((num(x) or 0) for x in cool.get('intel_powerclamp',[]) or ['/x']),
              pl1=num('/sys/class/powercap/intel-rapl:0/constraint_0_power_limit_uw',1000000),pl2=num('/sys/class/powercap/intel-rapl:0/constraint_1_power_limit_uw',1000000),
              mpl1=num('/sys/class/powercap/intel-rapl-mmio:0/constraint_0_power_limit_uw',1000000),mpl2=num('/sys/class/powercap/intel-rapl-mmio:0/constraint_1_power_limit_uw',1000000),
              maxf=num('/sys/devices/system/cpu/cpu0/cpufreq/scaling_max_freq',1000),profile=rf('/sys/firmware/acpi/platform_profile'))
            p,pt=n,t
        except Exception as e: REC.setdefault('err',str(e))
for fn in (gpu_loop,probe_loop,btop_loop,sampler): threading.Thread(target=fn,daemon=True).start()
time.sleep(3)
def ask(p,mt=700):
    body=json.dumps({"model":"qwen3.8-flash-next-iq3_s","max_tokens":mt,"seed":7,"stream":True,"messages":[{"role":"user","content":p}]}).encode()
    first=last=None;n=0;t0=time.time()
    with urllib.request.urlopen(urllib.request.Request("http://127.0.0.1:8099/v1/chat/completions",body,{"Content-Type":"application/json"}),timeout=900) as r:
        for raw in r:
            if not raw.startswith(b'data: ') or raw.startswith(b'data: [DONE]'): continue
            try: ch=json.loads(raw[6:]).get('choices') or []
            except Exception: continue
            if ch and any(ch[0].get('delta',{}).get(x) for x in ('content','reasoning_content','reasoning')):
                now=time.time(); first=first or now; last=now; n+=1; TOK[int(now)]=TOK.get(int(now),0)+1
    return t0,first,last,n
ask("Say hi.",16)
REQ=[]
for rnd in range(1,int(os.environ.get('TRACE_ROUNDS','3'))+1):
    for name,p in (('code',CODE),('prose',PROSE),('agent',LONG)):
        t0,a,b,n=ask(p); REQ.append(dict(round=rnd,prompt=name,t0=t0,first=a,last=b,n=n)); time.sleep(.6)
        ss=[k for k in range(int(a)+1,int(b)) if k in REC]; low=sum(REC[k]['pmax']<=600 for k in ss)
        print(f'[{arm}] r{rnd} {name:5} {n/(b-a):5.1f} t/s {b-a:5.1f}s  CPU at 400 MHz {low:3d}s',flush=True)
stop.set(); time.sleep(1.2)
with open(out,'w') as f:
    f.write(json.dumps(dict(type='meta',arm=arm,trips={z[0]:z[2] for z in zones},err=REC.get('err')))+'\n')
    for q_ in REQ: f.write(json.dumps(dict(type='req',**q_))+'\n')
    for k in sorted(x for x in REC if x!='err'):
        f.write(json.dumps(dict(type='s',tok=TOK.get(k,0),cw=BT.get(k),probe=PR.get(k),**REC[k],**GPU.get(k,{})))+'\n')
for x in (nv,probe): x.kill()
os._exit(0)
