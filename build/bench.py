#!/usr/bin/env python3
"""The kit's realtime benchmark (bench.sh runs it; see there for the why).

  bench.py run    --target T --dist D --work W --out DIR [--res 720p,1440p] [--frames N]
  bench.py report --version V --out DIR [--previous OLD.json] [--not-run WHY] PART.json ...

`run` encodes and decodes the clip set with one target's avmenc/avmdec and the
baselines (x264, libaom, SVT-AV1 through ffmpeg) on this machine and writes
DIR/bench-<target>.json with every measurement. `report` merges those parts
into bench-<version>.json and bench-<version>.md, compares them with the
previous release's JSON, and writes bench-summary.md for the release notes.
Standard library only.
"""
import argparse
import hashlib
import json
import os
import platform
import re
import shutil
import statistics
import subprocess
import sys
import time

FPS = 30
RES = {"720p": (1280, 720), "1440p": (2560, 1440)}
# name -> (kind, screen content?)
CLIPS = {"text": True, "desktop": True, "motion": False}
AVM_RT = ["--rt", "--cpu-used=9", "--lag-in-frames=0", "--end-usage=q", "--qp=160",
          "--threads=4", "--row-mt=1", "--tile-columns=1"]
THRESHOLD = 0.10  # a change against the previous release worth flagging


def log(msg):
    print(msg, file=sys.stderr, flush=True)


def run(cmd, **kw):
    return subprocess.run(cmd, capture_output=True, text=True, **kw)


def md5(path):
    h = hashlib.md5()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def font():
    r = run(["fc-match", "-f", "%{file}", "DejaVu Sans Mono"]) if shutil.which("fc-match") else None
    if r and r.returncode == 0 and r.stdout.endswith(".ttf"):
        return r.stdout
    return "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf"


def page_text(path, lines=900):
    """A long page of code-like text, the same on every machine."""
    words = ["frame", "tile", "block", "residual", "predict", "filter", "plane", "stride",
             "qindex", "cdef", "warp", "motion", "palette", "intrabc", "entropy", "symbol"]
    with open(path, "w") as f:
        for i in range(lines):
            a, b, c = words[i % 16], words[(i * 7) % 16], words[(i * 11) % 16]
            indent = "    " * (i % 4)
            f.write(f"{indent}static int {a}_{b}_{i:04d}(const {c}_t *s, int x) {{ return s->{c}[x] + {i % 97}; }}\n")


def make_clip(work, name, res, frames):
    """Generates a clip with ffmpeg's lavfi sources: public and reproducible."""
    w, h = RES[res]
    d = os.path.join(work, "bench", "clips")
    os.makedirs(d, exist_ok=True)
    out = os.path.join(d, f"{name}-{res}-{frames}.y4m")
    if os.path.exists(out):
        return out
    txt = os.path.join(d, "page.txt")
    if not os.path.exists(txt):
        page_text(txt)
    win = os.path.join(d, "window.txt")  # what fits in the desktop's window
    if not os.path.exists(win):
        page_text(win, lines=28)
    ttf = font()
    fs = h // 40
    if name == "text":  # a page of code scrolling at h/6 pixels per second
        src = (f"color=c=0xf8f8f8:s={w}x{h}:r={FPS},"
               f"drawtext=fontfile={ttf}:textfile={txt}:expansion=none:fontsize={fs}:"
               f"fontcolor=0x202020:x={w // 40}:y={h // 30}-t*{h // 6}")
    elif name == "desktop":  # a still desktop with a window; a counter and a cursor change
        src = (f"color=c=0x30343c:s={w}x{h}:r={FPS},"
               f"drawbox=x={w // 12}:y={h // 10}:w={w * 6 // 10}:h={h * 7 // 10}:color=0xf4f4f4:t=fill,"
               f"drawbox=x={w // 12}:y={h // 10}:w={w * 6 // 10}:h={h // 24}:color=0x2a5db0:t=fill,"
               f"drawtext=fontfile={ttf}:textfile={win}:expansion=none:fontsize={fs * 3 // 4}:"
               f"fontcolor=0x303030:x={w // 12 + 10}:y={h // 10 + h // 20},"
               f"drawbox=x=0:y={h - h // 24}:w={w}:h={h // 24}:color=0x1e1e1e:t=fill,"
               f"drawtext=fontfile={ttf}:text='%{{eif\\:n\\:d}}':fontsize={fs}:fontcolor=white:"
               f"x={w - w // 10}:y={h - h // 28},"
               f"drawbox=x={w * 7 // 10}:y={h * 3 // 4}:w={fs // 2}:h={fs}:color=black:t=fill:"
               f"enable='lt(mod(n\\,30)\\,15)'")
    else:  # camera-like motion
        src = f"testsrc2=s={w}x{h}:r={FPS}"
    r = run(["ffmpeg", "-loglevel", "error", "-y", "-f", "lavfi", "-i", src,
             "-frames:v", str(frames), "-pix_fmt", "yuv420p", "-f", "yuv4mpegpipe", out + ".part"])
    if r.returncode != 0:
        raise RuntimeError(f"clip {name} {res}: {r.stderr.strip()[-300:]}")
    os.rename(out + ".part", out)
    return out


def psnr_y(decoded, source):
    r = run(["ffmpeg", "-hide_banner", "-i", decoded, "-i", source,
             # frame by frame, whatever rate each file claims (avmdec's
             # y4m says none, and ffmpeg would take it as 25 fps)
             "-lavfi", "[0:v]settb=1/30,setpts=N[a];[1:v]settb=1/30,setpts=N[b];[a][b]psnr", "-f", "null", "-"])
    m = re.search(r"PSNR y:([0-9.]+|inf)", r.stderr)
    if not m:
        raise RuntimeError(f"psnr: {r.stderr.strip()[-300:]}")
    return None if m.group(1) == "inf" else float(m.group(1))


def p95(values):
    s = sorted(values)
    return s[min(len(s) - 1, int(round(0.95 * (len(s) - 1))))]


# Video-like content also runs at speed 10 (realtime only: the non-RD work
# for camera/video) with 4 tile columns, as xrdp would for video.
AVM_RT_VIDEO = [a for a in AVM_RT if not a.startswith(("--cpu-used", "--tile-columns"))] + \
    ["--cpu-used=10", "--tile-columns=2"]


def bench_avm(bindir, clip, screen, frames, tmp, runner_prefix, video=False):
    obu = os.path.join(tmp, "avm.obu")
    cmd = runner_prefix + [os.path.join(bindir, "avmenc"), clip, "-o", obu,
                           f"--limit={frames}"] + (AVM_RT_VIDEO if video else AVM_RT)
    if screen:
        cmd.append("--tune-content=screen")
    r = run(cmd)
    if r.returncode != 0:
        raise RuntimeError(f"avmenc: {(r.stderr or r.stdout).strip()[-300:]}")
    # one line per frame from the encoder itself: its type and how long
    # avm_codec_encode took for it (av2_cx_iface.c, report_stats)
    stats = re.findall(r"POC:\s*(\d+)\s*\[\s*(\w+)\s*\].*?:\s*(\d+) Bytes,\s*([0-9.]+)ms", r.stdout)
    if len(stats) < 2:
        raise RuntimeError("avmenc printed no per-frame times")
    key = [float(t) for _, kind, _, t in stats if kind == "KEY"]
    inter = [float(t) for _, kind, _, t in stats if kind != "KEY"]
    size = os.path.getsize(obu)
    dec = os.path.join(bindir, "avmdec")
    fps = []
    for _ in range(3):  # decode speed: best of three
        d = run(runner_prefix + [dec, obu, "--threads=4", "--noblit", "--summary"])
        m = re.search(r"in (\d+) us \(([0-9.]+) fps\)", d.stderr + d.stdout)
        if d.returncode != 0 or not m:
            raise RuntimeError(f"avmdec: {(d.stderr or d.stdout).strip()[-300:]}")
        fps.append(float(m.group(2)))
    y4m = os.path.join(tmp, "avm.y4m")
    d = run(runner_prefix + [dec, obu, "-o", y4m])
    if d.returncode != 0:
        raise RuntimeError(f"avmdec: {d.stderr.strip()[-300:]}")
    inter_mean = statistics.mean(inter) if inter else None
    return {
        "codec": "avm-s10" if video else "avm",
        "preset": ("rt cpu-used=10 4 tiles" if video else
                   "rt cpu-used=9" + (" screen" if screen else "")),
        "frames": len(stats), "keyframe_ms": key[0] if key else None,
        "inter_mean_ms": inter_mean, "inter_p95_ms": p95(inter) if inter else None,
        "enc_fps": 1000.0 / inter_mean if inter_mean else None,
        "kbps": size * 8 / (frames / FPS) / 1000, "psnr_y": psnr_y(y4m, clip),
        "dec_fps": max(fps),
    }


def ffmpeg_bench(args):
    """Runs ffmpeg with -benchmark; returns the wall time it reports."""
    # -benchmark prints its line at the info level
    r = run(["ffmpeg", "-hide_banner", "-nostats", "-loglevel", "info", "-benchmark", "-y"] + args)
    m = re.search(r"rtime=([0-9.]+)s", r.stdout + r.stderr)
    if r.returncode != 0 or not m:
        raise RuntimeError((r.stderr or r.stdout).strip()[-300:])
    return float(m.group(1))


BASELINES = {
    # name: (preset label, ffmpeg encoder options, options for screen content)
    "x264-ultrafast": ("-preset ultrafast -tune zerolatency crf 26",
                       ["-c:v", "libx264", "-preset", "ultrafast", "-tune", "zerolatency",
                        "-crf", "26", "-threads", "4"], []),
    "x264-veryfast": ("-preset veryfast -tune zerolatency crf 26",
                      ["-c:v", "libx264", "-preset", "veryfast", "-tune", "zerolatency",
                       "-crf", "26", "-threads", "4"], []),
    "libaom-rt": ("realtime cpu-used=10 crf 40",
                  ["-c:v", "libaom-av1", "-usage", "realtime", "-cpu-used", "8",
                   "-lag-in-frames", "0", "-row-mt", "1", "-tile-columns", "1",
                   "-threads", "4", "-crf", "40", "-b:v", "0", "-aom-params", "cpu-used=10"],
                  ["-aom-params", "cpu-used=10:tune-content=screen"]),
    "svt-av1-rt": ("preset 10 rtc crf 40",
                   ["-c:v", "libsvtav1", "-preset", "10", "-crf", "40",
                    "-svtav1-params", "rtc=1:lp=4"], []),
}


def bench_baseline(name, clip, screen, frames, tmp):
    label, opts, screen_opts = BASELINES[name]
    if screen and screen_opts:  # the later -aom-params replaces the first
        opts = opts[:-2] + screen_opts
    out = os.path.join(tmp, f"{name}.mkv")
    try:
        t = ffmpeg_bench(["-i", clip, "-frames:v", str(frames)] + opts + [out])
    except RuntimeError:
        if "rtc=1:lp=4" not in opts:
            raise
        # SVT-AV1 before 2.0 has no rtc mode: its low-delay structure instead
        opts = [o.replace("rtc=1:lp=4", "pred-struct=1:lp=4") for o in opts]
        label = label.replace("rtc", "low-delay (no rtc in this SVT-AV1)")
        t = ffmpeg_bench(["-i", clip, "-frames:v", str(frames)] + opts + [out])
    dec = min(ffmpeg_bench(["-threads", "4", "-i", out, "-f", "null", "-"]) for _ in range(3))
    return {
        "codec": name, "preset": label, "frames": frames, "keyframe_ms": None,
        "inter_mean_ms": None, "inter_p95_ms": None,
        # ffmpeg's wall time for the whole run (reading the clip included)
        "enc_fps": frames / t, "kbps": os.path.getsize(out) * 8 / (frames / FPS) / 1000,
        "psnr_y": psnr_y(out, clip), "dec_fps": frames / dec,
    }


def machine():
    cpu = platform.processor() or platform.machine()
    try:
        with open("/proc/cpuinfo") as f:
            info = f.read()
        m = re.search(r"^model name\s*:\s*(.+)$", info, re.M)
        if m:
            cpu = m.group(1).strip()
        elif "CPU part" in info:
            r = run(["lscpu"])
            m = re.search(r"^Model name:\s*(.+)$", r.stdout, re.M)
            cpu = m.group(1).strip() if m else cpu
    except OSError:
        r = run(["sysctl", "-n", "machdep.cpu.brand_string"])
        cpu = r.stdout.strip() or cpu
    try:
        cores = len(os.sched_getaffinity(0))
    except AttributeError:
        cores = os.cpu_count()
    # GitHub's runner image, never a host name (the report is public)
    runner = os.environ.get("BENCH_RUNNER") or (
        f"GitHub {os.environ.get('ImageOS', '')} {os.environ.get('RUNNER_ARCH', '')}".strip()
        if os.environ.get("GITHUB_ACTIONS") else "local machine")
    return {"cpu": cpu, "cores_usable": cores, "cores_total": os.cpu_count(),
            "runner": runner, "os": f"{platform.system()} {platform.release()}",
            "arch": platform.machine()}


def tool_versions():
    v = {}
    r = run(["ffmpeg", "-hide_banner", "-version"])
    v["ffmpeg"] = r.stdout.splitlines()[0] if r.returncode == 0 else "missing"
    return v


def cmd_run(a):
    bindir = os.path.join(a.dist, a.target, "bin")
    manifest = os.path.join(a.dist, a.target, "MANIFEST")
    meta = {}
    if os.path.exists(manifest):
        with open(manifest) as f:
            for line in f:
                k, _, v = line.partition(" ")
                if k in ("version", "source", "kit", "compiler") and v.strip():
                    meta[k] = v.strip()
    out = {"schema": 1, "target": a.target, "build": meta, "machine": machine(),
           "tools": tool_versions(), "avm_settings": " ".join(AVM_RT),
           "fps": FPS, "clips": {}, "results": [], "errors": []}
    tmp = os.path.join(a.work, "bench", "tmp", a.target)
    os.makedirs(tmp, exist_ok=True)
    os.makedirs(a.out, exist_ok=True)
    baselines = [] if a.avm_only else list(BASELINES)
    for res in a.res.split(","):
        frames = a.frames
        for name, screen in CLIPS.items():
            try:
                clip = make_clip(a.work, name, res, frames)
            except RuntimeError as e:
                out["errors"].append(str(e)); log(f"FAIL  {e}")
                continue
            out["clips"][f"{name}-{res}"] = {"frames": frames, "size": "%dx%d" % RES[res],
                                             "md5": md5(clip), "screen": screen}
            avm_rows = ["avm"] + ([] if screen else ["avm-s10"])
            for codec in avm_rows + baselines:
                t0 = time.time()
                try:
                    if codec in ("avm", "avm-s10"):
                        r = bench_avm(bindir, clip, screen, frames, tmp, a.prefix.split(),
                                      video=codec == "avm-s10")
                    else:
                        r = bench_baseline(codec, clip, screen, frames, tmp)
                except (RuntimeError, OSError, ValueError) as e:
                    msg = f"{codec} {name} {res}: {e}"
                    out["errors"].append(msg); log(f"FAIL  {msg}")
                    continue
                r.update(clip=name, res=res)
                out["results"].append(r)
                log(f"ok    {res} {name:8} {codec:15} enc {fmt(r['enc_fps'])} fps, "
                    f"{fmt(r['kbps'], 0)} kbps, PSNR-Y {fmt(r['psnr_y'], 2)}, "
                    f"dec {fmt(r['dec_fps'])} fps ({time.time() - t0:.0f}s)")
    path = os.path.join(a.out, f"bench-{a.target}.json")
    with open(path, "w") as f:
        json.dump(out, f, indent=1)
    print(path)
    return 0 if out["results"] else 1


def fmt(v, digits=1):
    return "–" if v is None else f"{v:,.{digits}f}"


METRICS = [  # key, header, digits, higher is better
    ("keyframe_ms", "key ms", 1, False), ("inter_mean_ms", "inter mean ms", 1, False),
    ("inter_p95_ms", "inter p95 ms", 1, False), ("enc_fps", "enc fps", 1, True),
    ("kbps", "kbps", 0, None), ("psnr_y", "PSNR-Y dB", 2, True), ("dec_fps", "dec fps (4 thr)", 1, True),
]


def index(doc):
    return {(run_["target"], r["res"], r["clip"], r["codec"]): r
            for run_ in doc.get("runs", []) for r in run_["results"]}


def cmd_report(a):
    runs = []
    for p in a.parts:
        with open(p) as f:
            runs.append(json.load(f))
    doc = {"schema": 1, "version": a.version, "runs": runs,
           "not_run": a.not_run or None, "previous": None, "changes": []}
    prev = {}
    if a.previous and os.path.exists(a.previous):
        with open(a.previous) as f:
            old = json.load(f)
        doc["previous"] = old.get("version")
        prev = index(old)
    changes = []
    for key, r in index(doc).items():
        o = prev.get(key)
        if not o:
            continue
        for m, _, _, better in METRICS:
            if r.get(m) and o.get(m):
                d = (r[m] - o[m]) / o[m]
                if abs(d) > THRESHOLD:
                    changes.append({"target": key[0], "res": key[1], "clip": key[2],
                                    "codec": key[3], "metric": m, "old": o[m], "new": r[m],
                                    "change": d})
    doc["changes"] = changes
    os.makedirs(a.out, exist_ok=True)
    base = os.path.join(a.out, f"bench-{a.version}")
    with open(base + ".json", "w") as f:
        json.dump(doc, f, indent=1)
    md = [f"# Realtime benchmark, release {a.version}", ""]
    md += ["Informational, not a gate: CI runners are shared virtual machines and "
           "their timings vary from run to run, often by 10% or more. Each target is "
           "measured only on a machine that runs it natively; every other target is "
           "cross-compiled and passes the decode conformance test (test.sh), without "
           "timings.", ""]
    if a.not_run:
        md += [f"**Benchmark not run: {a.not_run}**", ""]
    md += [f"AVM settings: `{runs[0]['avm_settings'] if runs else ' '.join(AVM_RT)}`, plus "
           "`--tune-content=screen` for the screen clips (text, desktop). Keyframe and "
           "inter-frame times are avmenc's own per-frame times (the time spent in "
           "avm_codec_encode); fps = 1000 / inter mean. The baselines' fps are ffmpeg's "
           "wall time for the whole encode (no per-frame times). Quality settings are not "
           "matched across codecs: read kbps together with PSNR-Y. PSNR-Y is ffmpeg's, on "
           "the decoded frames. Decode fps: avmdec --threads=4 --noblit (AVM), ffmpeg with 4 "
           "threads and its default decoder (the baselines; dav1d for AV1); best of three.", ""]
    md += ["Clips (generated by ffmpeg, see bench.sh): **text**, a page of code scrolling; "
           "**desktop**, a still desktop where a counter and a cursor change; **motion**, "
           "ffmpeg's testsrc2. 30 fps.", ""]
    for run_ in runs:
        mc = run_["machine"]
        md += [f"## {run_['target']}", "",
               f"- Machine: {mc['cpu']}, {mc['cores_usable']} of {mc['cores_total']} cores usable; "
               f"{mc['runner']}; {mc['os']}",
               f"- Build: {run_['build'].get('version', '?')}, {run_['build'].get('source', '?')}, "
               f"kit {run_['build'].get('kit', '?')}, {run_['build'].get('compiler', '?')}",
               f"- Tools: {run_['tools'].get('ffmpeg', '?')}", ""]
        for err in run_["errors"]:
            md.append(f"- not measured: {err}")
        if run_["errors"]:
            md.append("")
        for res in RES:
            rows = [r for r in run_["results"] if r["res"] == res]
            if not rows:
                continue
            md += [f"### {run_['target']}, {res} ({'x'.join(map(str, RES[res]))})", "",
                   "| clip | codec | preset | " + " | ".join(h for _, h, _, _ in METRICS) + " |",
                   "|---|---|---|" + "---:|" * len(METRICS)]
            for r in rows:
                md.append(f"| {r['clip']} | {r['codec']} | {r['preset']} | " +
                          " | ".join(fmt(r.get(m), d) for m, _, d, _ in METRICS) + " |")
            md.append("")
    md += ["## Against the previous release", ""]
    if not prev:
        md += ["No previous release with a benchmark to compare with.", ""]
    elif not changes:
        md += [f"Nothing moved by more than {THRESHOLD:.0%} against {doc['previous']}.", ""]
    else:
        md += [f"Changes over ±{THRESHOLD:.0%} against {doc['previous']} (runner noise "
               "included; a change in one row only is likely noise):", "",
               "| target | res | clip | codec | metric | before | now | change |",
               "|---|---|---|---|---|---:|---:|---:|"]
        for c in changes:
            md.append(f"| {c['target']} | {c['res']} | {c['clip']} | {c['codec']} | {c['metric']} | "
                      f"{fmt(c['old'], 2)} | {fmt(c['new'], 2)} | {c['change']:+.0%} |")
        md.append("")
    with open(base + ".md", "w") as f:
        f.write("\n".join(md))
    # the short table for the release notes: AVM, and x264 ultrafast beside it
    s = []
    if a.not_run:
        s += [f"Benchmark not run: {a.not_run}.", ""]
    rows = [(run_["target"], r) for run_ in runs for r in run_["results"]
            if r["codec"] in ("avm", "avm-s10")]
    if rows:
        x264 = index(doc)
        s += ["| target | res | clip | AVM enc fps | AVM kbps | AVM PSNR-Y | AVM dec fps | x264 ultrafast enc fps / kbps / PSNR-Y |",
              "|---|---|---|---:|---:|---:|---:|---:|"]
        for target, r in rows:
            x = x264.get((target, r["res"], r["clip"], "x264-ultrafast"))
            xs = f"{fmt(x['enc_fps'])} / {fmt(x['kbps'], 0)} / {fmt(x['psnr_y'], 2)}" if x else "–"
            s.append(f"| {target} | {r['res']} | {r['clip']}{' (speed 10)' if r['codec'] == 'avm-s10' else ''} | {fmt(r['enc_fps'])} | "
                     f"{fmt(r['kbps'], 0)} | {fmt(r['psnr_y'], 2)} | {fmt(r['dec_fps'])} | {xs} |")
        s += ["", f"Full report: `bench-{a.version}.md` (and `.json`); informational, CI runners are noisy."]
        if changes:
            s.append(f"{len(changes)} values moved by more than {THRESHOLD:.0%} against {doc['previous']}: see the report.")
    with open(os.path.join(a.out, "bench-summary.md"), "w") as f:
        f.write("\n".join(s) + "\n")
    print(base + ".md")
    return 0


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    r = sub.add_parser("run")
    r.add_argument("--target", required=True)
    r.add_argument("--dist", required=True)
    r.add_argument("--work", required=True)
    r.add_argument("--out", required=True)
    r.add_argument("--res", default="720p,1440p")
    r.add_argument("--frames", type=int, default=60)
    r.add_argument("--avm-only", action="store_true")
    r.add_argument("--prefix", default="", help="a command to run the AVM binaries with")
    s = sub.add_parser("report")
    s.add_argument("--version", required=True)
    s.add_argument("--out", required=True)
    s.add_argument("--previous")
    s.add_argument("--not-run")
    s.add_argument("parts", nargs="*")
    a = p.parse_args()
    if a.cmd == "run":
        for res in a.res.split(","):
            if res not in RES:
                p.error(f"unknown resolution {res} (720p, 1440p)")
        if not 30 <= a.frames <= 60:
            p.error("--frames: 30 to 60")
        return cmd_run(a)
    return cmd_report(a)


if __name__ == "__main__":
    sys.exit(main())
