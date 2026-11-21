"""Compare built cores: python3 scripts/bench/compare.py BASELINE_ROOT CANDIDATE_ROOT [RUNS=5].
Uses local synthetic media only. One warmup, then alternating implementations.
RSS is sampled separately for the Node parent and its largest live child (not summed).
CPU from wait4 includes waited descendants; sampling may miss short-lived peaks.
"""
import base64, hashlib, json, os, statistics, subprocess, sys, tempfile, time
from pathlib import Path
base, candidate = map(Path, sys.argv[1:3])
runs = int(sys.argv[3]) if len(sys.argv) > 3 else 5
worker = candidate / "scripts/bench/inspect.mjs"

def pixels(png):
    p = subprocess.run(["ffmpeg", "-v", "error", "-i", "pipe:0", "-f", "image2pipe", "-c:v", "pam", "-pix_fmt", "rgb24", "pipe:1"], input=base64.b64decode(png), capture_output=True, check=True)
    return hashlib.sha256(p.stdout).hexdigest()

def run(root, clip, method, folder):
    log = folder / "processes"
    log.write_text("")
    env = {**os.environ, "PATH": str(folder / "bin") + os.pathsep + os.environ["PATH"], "POACH_BENCH_LOG": str(log)}
    start = time.perf_counter()
    with tempfile.TemporaryFile() as out, tempfile.TemporaryFile() as err:
        p = subprocess.Popen(["node", str(worker), str(root / "packages/core/dist/index.js"), str(clip), method], stdout=out, stderr=err, env=env)
        parent_rss = child_rss = 0
        while True:
            pid, status, usage = os.wait4(p.pid, os.WNOHANG)
            if pid: break
            rows = subprocess.check_output(["ps", "-axo", "pid=,ppid=,rss="], text=True)
            rows = [tuple(map(int, line.split())) for line in rows.splitlines() if line.strip()]
            descendants = {p.pid}
            for _ in range(5): descendants |= {pid for pid, ppid, _ in rows if ppid in descendants}
            parent_rss = max(parent_rss, max((rss for pid, _, rss in rows if pid == p.pid), default=0))
            child_rss = max(child_rss, max((rss for pid, _, rss in rows if pid in descendants and pid != p.pid), default=0))
            time.sleep(0.01)
        p.returncode = os.waitstatus_to_exitcode(status)
        elapsed = time.perf_counter() - start
        out.seek(0); err.seek(0)
        if p.returncode: raise RuntimeError(err.read().decode())
        value = json.load(out)
    value["images"] = [pixels(image) for image in value["images"]]
    counts = log.read_text().splitlines()
    return value, dict(wall=elapsed, cpu=usage.ru_utime + usage.ru_stime, parentRSSKiB=parent_rss, childRSSKiB=child_rss, ffmpeg=counts.count("ffmpeg"), ffprobe=counts.count("ffprobe"))

with tempfile.TemporaryDirectory(prefix="poach-compare-") as temp:
    folder = Path(temp); (folder / "bin").mkdir()
    for tool in ("ffmpeg", "ffprobe"):
        actual = subprocess.check_output(["which", tool], text=True).strip()
        wrapper = folder / "bin" / tool
        wrapper.write_text('#!/bin/sh\nprintf "%s\\n" "' + tool + '" >> "$POACH_BENCH_LOG"\nexec "' + actual + '" "$@"\n')
        wrapper.chmod(0o700)
    cases = [("motion", "testsrc2=size=160x90:rate=30", "2", [], "inspectVideo"),
             ("static", "color=black:size=96x64:rate=12", "1", [], "inspectVideo"),
             ("sparse", "testsrc2=size=96x64:rate=1/2", "6", [], "inspectVideo"),
             ("offset", "testsrc2=size=96x64:rate=30", "1", ["-output_ts_offset", "2"], "inspectVideo"),
             ("portrait", "testsrc=size=91x161:rate=30", "1", ["-pix_fmt", "yuv444p"], "inspectVideo"),
             ("short", "testsrc2=size=96x64:rate=30", "0.1", [], "inspectVideo"),
             ("hd", "testsrc2=size=1920x1080:rate=30", "30", [], "inspectVideo"),
             ("overrun", "testsrc2=size=96x64:rate=30", "31.5", [], "inspectRecording")]
    for name, source, duration, extra, method in cases:
        clip = folder / (name + ".mov")
        subprocess.run(["ffmpeg", "-v", "error", "-f", "lavfi", "-i", source, "-t", duration, "-c:v", "libx264", *extra, str(clip)], check=True)
        values = {}
        measurements = {"baseline": [], "candidate": []}
        for iteration in range(runs + 1):
            for label, root in (("baseline", base), ("candidate", candidate)):
                value, stats = run(root, clip, method, folder)
                if "baseline" in values and value != values["baseline"]:
                    raise AssertionError(f"Output mismatch: {name} {label}\n{value['result']}\n{values['baseline']['result']}")
                values[label] = value
                if iteration: measurements[label].append(stats)
        report = {label: {key: {"median": statistics.median(row[key] for row in rows), "min": min(row[key] for row in rows), "max": max(row[key] for row in rows)} for key in rows[0]} for label, rows in measurements.items()}
        print(json.dumps({"case": name, "parity": True, "runs": runs, "measurements": report}), flush=True)
