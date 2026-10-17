#!/usr/bin/env python3
"""Sample an already-running native app without a profiler (one core = 100%)."""
import argparse, ctypes, json, pathlib, statistics, time
parser = argparse.ArgumentParser()
parser.add_argument('pid', type=int)
parser.add_argument('--seconds', type=int, default=30)
parser.add_argument('--output', type=pathlib.Path, required=True)
args = parser.parse_args()
class Timebase(ctypes.Structure):
    _fields_ = [('numer', ctypes.c_uint32), ('denom', ctypes.c_uint32)]
class Usage(ctypes.Structure):
    _fields_ = [('uuid', ctypes.c_uint8 * 16)] + [(name, ctypes.c_uint64) for name in
        ['user', 'system', 'idle', 'interrupt', 'pageins', 'wired', 'rss', 'footprint', 'start', 'exit',
         'child_user', 'child_system', 'child_idle', 'child_interrupt', 'child_pageins', 'child_elapsed', 'disk_read', 'disk_write']]
lib = ctypes.CDLL('/usr/lib/libproc.dylib', use_errno=True)
system = ctypes.CDLL('/usr/lib/libSystem.B.dylib')
base = Timebase(); system.mach_timebase_info(ctypes.byref(base))
seconds_per_tick = base.numer / base.denom / 1e9
lib.proc_pid_rusage.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.POINTER(Usage)]
lib.proc_pidpath.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
path = ctypes.create_string_buffer(4096)
if lib.proc_pidpath(args.pid, path, len(path)) <= 0: raise RuntimeError('Cannot identify process')
def read():
    value = Usage()
    if lib.proc_pid_rusage(args.pid, 2, ctypes.byref(value)) != 0: raise OSError(ctypes.get_errno(), 'proc_pid_rusage')
    return value
previous = read(); identity = previous.start; last_time = start = time.monotonic(); rows = []
for _ in range(args.seconds):
    time.sleep(1); now = time.monotonic(); current = read()
    if current.start != identity: raise RuntimeError('Process was replaced during measurement')
    rows.append(dict(cpu_percent=100*((current.user+current.system)-(previous.user+previous.system))*seconds_per_tick/(now-last_time),
        rss_mib=current.rss/2**20, footprint_mib=current.footprint/2**20,
        idle_wakeups=(current.idle-previous.idle)/(now-last_time)))
    previous = current; last_time = now
result = dict(pid=args.pid, executable=path.value.decode(), seconds=time.monotonic()-start, samples=rows,
    cpu_mean=statistics.mean(row['cpu_percent'] for row in rows), rss_mean=statistics.mean(row['rss_mib'] for row in rows),
    rss_peak=max(row['rss_mib'] for row in rows), footprint_peak=max(row['footprint_mib'] for row in rows))
args.output.write_text(json.dumps(result, indent=2))
print(json.dumps({key:value for key,value in result.items() if key != 'samples'}, ensure_ascii=False))
