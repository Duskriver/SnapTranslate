"""Observe stage footprints, including the live UI child; no AX or screenshots."""
import csv
import ctypes
import os
from pathlib import Path
import subprocess
import sys
import threading

lib = ctypes.CDLL('/usr/lib/libproc.dylib')
lib.proc_pid_rusage.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_void_p]
lib.proc_pid_rusage.restype = ctypes.c_int

def footprint(pid):
    data = ctypes.create_string_buffer(1024)
    if lib.proc_pid_rusage(pid, 2, ctypes.byref(data)):
        raise RuntimeError(f'Cannot measure PID {pid}')
    return ctypes.c_uint64.from_buffer(data, 72).value / 1048576

base, version, run = Path(sys.argv[1]), sys.argv[2], sys.argv[3]
work = base / f'{version}-{run}'
work.mkdir()
environment = dict(os.environ, SNAP_SETTINGS_PROBE=str(work))
with (work / 'stderr.log').open('w') as error_log:
    process = subprocess.Popen([str(base / version / 'SnapTranslate.app/Contents/MacOS/SnapTranslate')],
                               stdout=subprocess.PIPE, stderr=error_log, text=True, env=environment)
    watchdog = threading.Timer(120, process.terminate)
    watchdog.start()
    try:
        with (work / 'measurements.csv').open('w') as output:
            writer = csv.writer(output)
            for line in process.stdout:
                stage, main, elapsed = line.strip().split(',')
                children = subprocess.run(['pgrep', '-P', str(process.pid)], capture_output=True, text=True).stdout.split()
                child = sum(footprint(int(pid)) for pid in children)
                row = [version, run, stage, main, child, float(main) + child, len(children), elapsed]
                writer.writerow(row)
                print(','.join(map(str, row)), flush=True)
                if stage == 'closed-5':
                    snapshot = subprocess.run([sys.executable, 'scripts/inspect-memory.py', str(process.pid)],
                                              capture_output=True, text=True, timeout=30)
                    (work / 'closed-services.json').write_text(snapshot.stdout)
                    if snapshot.returncode:
                        raise RuntimeError(f'Could not inspect associated services: {snapshot.stderr}')
                if stage == 'idle-5s' and children:
                    raise RuntimeError('Settings child remained alive after closing')
        if process.wait(timeout=10):
            raise RuntimeError(f'Settings probe failed: {error_log.name}')
    finally:
        watchdog.cancel()
        if process.poll() is None:
            process.terminate()
            process.wait(timeout=10)
