import ctypes,subprocess,time,sys,json
from pathlib import Path
lib=ctypes.CDLL('/usr/lib/libproc.dylib')
lib.proc_pid_rusage.argtypes=[ctypes.c_int,ctypes.c_int,ctypes.c_void_p]
lib.proc_pid_rusage.restype=ctypes.c_int
def footprint(pid):
 b=ctypes.create_string_buffer(1024)
 if lib.proc_pid_rusage(pid,2,ctypes.byref(b)):return None
 return ctypes.c_uint64.from_buffer(b,72).value/1048576
base=Path(sys.argv[1]);version=sys.argv[2];run=sys.argv[3]
with (base/f'{version}-{run}.csv').open('w') as f,(base/f'{version}-{run}.stderr').open('w') as e:
 p=subprocess.Popen([str(base/version/'SnapTranslate.app/Contents/MacOS/SnapTranslate')],stdout=f,stderr=e)
 samples=[]
 deadline=time.monotonic()+120
 while p.poll() is None:
  if time.monotonic()>deadline:
   p.terminate();p.wait(timeout=10);raise RuntimeError('Idle memory probe timed out')
  children=subprocess.run(['pgrep','-P',str(p.pid)],capture_output=True,text=True).stdout.split()
  child_values=[(int(pid),footprint(int(pid))) for pid in children]
  main=footprint(p.pid)
  live=[(pid,n) for pid,n in child_values if n is not None]
  if main is not None:samples.append({'time':time.time(),'main_mib':main,'children':live,'sum_mib':main+sum(n for _,n in live)})
  time.sleep(.1)
 if p.returncode:raise SystemExit(p.returncode)
(base/f'{version}-{run}-observations.json').write_text(json.dumps(samples))
peak=max(s['sum_mib'] for s in samples)
print(version,run,'sampled_main_child_sum_peak_mib',round(peak,3),'max_child_count',max(len(s['children']) for s in samples),flush=True)
