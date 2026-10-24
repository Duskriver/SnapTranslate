"""Observe actual main/worker PIDs without querying their UI or retaining images."""
import ctypes
import json
import os
from pathlib import Path
import queue
import subprocess
import sys
import threading
import time

lib = ctypes.CDLL('/usr/lib/libproc.dylib')
lib.proc_pid_rusage.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_void_p]
lib.proc_pid_rusage.restype = ctypes.c_int


def footprint(pid):
    data = ctypes.create_string_buffer(1024)
    if lib.proc_pid_rusage(pid, 2, ctypes.byref(data)):
        return None
    return ctypes.c_uint64.from_buffer(data, 72).value / 1048576


def snapshot(pid):
    children = subprocess.run(['pgrep', '-P', str(pid)], capture_output=True, text=True).stdout.split()
    live = [(int(child), footprint(int(child))) for child in children]
    live = [(child, value) for child, value in live if value is not None]
    main = footprint(pid)
    return {'time': time.time(), 'main_pid': pid, 'main_mib': main, 'children': live,
            'sum_mib': None if main is None else main + sum(value for _, value in live)}


real_api = os.environ.get('SNAP_MULTI_REAL_API') == '1'
base = Path(sys.argv[1]).resolve()
run = sys.argv[2]
root = base / f'run-{run}'
root.mkdir()
env = dict(os.environ, SNAP_MULTI_PROBE_ROOT=str(root))
lines = queue.Queue()
with (root / 'stderr.log').open('w') as err:
    process = subprocess.Popen([str(base / 'SnapTranslate.app/Contents/MacOS/SnapTranslate')],
                               stdout=subprocess.PIPE, stderr=err, text=True, env=env)
    def read_lines():
        for line in process.stdout:
            lines.put(line.strip())
    reader = threading.Thread(target=read_lines, daemon=True)
    reader.start()
    samples, stages = [], []
    worker_services = set()
    deadline = time.monotonic() + (900 if real_api else 180)
    try:
        while process.poll() is None or not lines.empty():
            if time.monotonic() > deadline:
                raise RuntimeError('Multi-window probe timed out')
            current = snapshot(process.pid)
            if current['main_mib'] is not None:
                samples.append(current)
            while not lines.empty():
                line = lines.get_nowait()
                stage, windows = line.split(',')
                windows = int(windows)
                measurement = snapshot(process.pid)
                if measurement['main_mib'] is None:
                    measurement = current
                expected = 1 if windows else 0
                assert len(measurement['children']) == expected, (stage, measurement)
                measurement.update(stage=stage, windows=windows)
                if real_api and not windows and stage != 'startup':
                    state_file = root / 'worker-state.json'
                    measurement['seconds_since_last_window_close'] = measurement['time'] - state_file.stat().st_mtime
                stages.append(measurement)
                print(','.join(map(str, [run, stage, windows, measurement['main_mib'],
                                        sum(value for _, value in measurement['children']), measurement['sum_mib'],
                                        len(measurement['children'])])), flush=True)
                # Separate read-only XPC snapshots, after the primary sample.
                # No accessibility query or app screenshot is involved.
                if run == '1' and stage in (('retained-5', 'idle-cycle-1-3s', 'idle-cycle-1-15s', 'idle-cycle-1-45s', 'reopened-cycle-2', 'idle-cycle-2-15s') if real_api else ('retained-10', 'idle-cycle-1')):
                    targets = [('main', process.pid)] + [('worker', child) for child, _ in measurement['children']]
                    for role, pid in targets:
                        result = subprocess.run([sys.executable, 'scripts/inspect-memory.py', str(pid)],
                                                capture_output=True, text=True, timeout=60)
                        assert result.returncode == 0, result.stderr
                        report = json.loads(result.stdout)
                        (root / f'{stage}-{role}-xpc.json').write_text(json.dumps(report, indent=2))
                        if role == 'worker':
                            worker_services.update(item['pid'] for item in report['processes'][1:])
                    if not windows:
                        alive = []
                        for pid in worker_services:
                            try:
                                os.kill(pid, 0)
                                alive.append(pid)
                            except ProcessLookupError:
                                pass
                        (root / f'{stage}-worker-service-exit.json').write_text(json.dumps(
                            {'observed_worker_services': sorted(worker_services), 'still_alive_after_close': alive}, indent=2))
                temporary = root / 'observer-ack.tmp'
                temporary.write_text(stage)
                temporary.replace(root / 'observer-ack')
            time.sleep(.1)
        reader.join(timeout=1)
        if process.returncode:
            raise RuntimeError(f'Probe exited {process.returncode}: {(root / "stderr.log").read_text()}')
        assert len(stages) == 12, len(stages)
        assert max(len(sample['children']) for sample in samples) == 1
    finally:
        if process.poll() is None:
            process.terminate()
            process.wait(timeout=10)
        (root / 'observations.json').write_text(json.dumps(samples, indent=2))
        (root / 'stages.json').write_text(json.dumps(stages, indent=2))
