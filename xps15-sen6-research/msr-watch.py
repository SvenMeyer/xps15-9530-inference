#!/usr/bin/env python3
"""Read-only MSR logger for the XPS 15 SEN6 400 MHz brake.

Opens /dev/cpu/N/msr O_RDONLY and only calls pread. It never writes an MSR and never clears a log bit.
Run as root while a load produces a stall:
  sudo python3 -I xps15-sen6-msr-watch.py --seconds 1500
Re-read a log without root:
  python3 -I xps15-sen6-msr-watch.py --summarize FILE.jsonl
"""
import argparse, glob, json, os, re, signal, struct, time

IA32_MPERF, IA32_APERF, PLATFORM_INFO = 0xE7, 0xE8, 0xCE
PERF_STATUS, THERM_STATUS, PKG_THERM_STATUS = 0x198, 0x19C, 0x1B1
TEMP_TARGET, POWER_CTL, PKG_POWER_LIMIT = 0x1A2, 0x1FC, 0x610
PERF_LIMIT_REASONS, PLATFORM_POWER_LIMIT, HWP_CAPABILITIES = 0x64F, 0x65C, 0x771
TSC = 0x10
ZONES = ("SEN6", "SEN5", "SKIN", "TCPU")
STALL_MHZ, BUSY_C0, MIN_BUSY = 600, 0.5, 4


def rd(path):
    try:
        with open(path) as f:
            return f.read().strip()
    except OSError:
        return None


def zone_paths():
    out = {}
    for z in glob.glob("/sys/class/thermal/thermal_zone*"):
        t = rd(z + "/type")
        if t in ZONES:
            out[t] = z + "/temp"
    return out


class Msr:
    def __init__(self, root):
        paths = glob.glob(os.path.join(root, "*", "msr"))
        self.fd = {int(re.search(r"/(\d+)/msr$", p).group(1)): os.open(p, os.O_RDONLY) for p in paths}
        if not self.fd:
            raise SystemExit("no MSR devices under " + root)
        self.cpus = sorted(self.fd)

    def get(self, cpu, reg):
        try:
            b = os.pread(self.fd[cpu], 8, reg)
        except OSError:
            return None
        return struct.unpack("<Q", b)[0] if len(b) == 8 else None


def bit(v, n):
    return None if v is None else (v >> n) & 1


def sample(m, base_mhz, prev, zones):
    now = {c: (m.get(c, IA32_APERF), m.get(c, IA32_MPERF), m.get(c, TSC)) for c in m.cpus}
    busy = []
    if prev:
        for c in m.cpus:
            a, mp, t = now[c]
            pa, pm, pt = prev[c]
            if None in (a, mp, t, pa, pm, pt) or mp <= pm or t <= pt:
                continue
            if (mp - pm) / (t - pt) >= BUSY_C0:
                busy.append(base_mhz * (a - pa) / (mp - pm))
    th = [m.get(c, THERM_STATUS) for c in m.cpus]
    th = [x for x in th if x is not None]
    c0 = m.cpus[0]
    pkg, plr = m.get(c0, PKG_THERM_STATUS), m.get(c0, PERF_LIMIT_REASONS)
    temps = {}
    for k, p in zones.items():
        v = rd(p)
        temps[k] = int(v) / 1000 if v and v.lstrip("-").isdigit() else None
    return now, dict(
        t=round(time.time(), 2), **temps, busy=len(busy),
        busy_max_mhz=round(max(busy)) if busy else None,
        stall=bool(len(busy) >= MIN_BUSY and max(busy) <= STALL_MHZ),
        core_thermal=sum(bit(x, 0) for x in th), core_prochot=sum(bit(x, 2) for x in th), cores=len(th),
        pkg_thermal=bit(pkg, 0), pkg_prochot=bit(pkg, 2),
        plr=None if plr is None else hex(plr), plr_prochot=bit(plr, 0), plr_thermal=bit(plr, 1),
        perf_ratio=None if (x := m.get(c0, PERF_STATUS)) is None else (x >> 8) & 0xFF,
        pl=None if (x := m.get(c0, PKG_POWER_LIMIT)) is None else hex(x),
        psys=None if (x := m.get(c0, PLATFORM_POWER_LIMIT)) is None else hex(x),
        hwp=None if (x := m.get(c0, HWP_CAPABILITIES)) is None else hex(x),
        power_ctl=None if (x := m.get(c0, POWER_CTL)) is None else hex(x),
    )


def summarize(path):
    R = [json.loads(l) for l in open(path)]
    R = [r for r in R if r.get("type") == "s"]
    S, N = [r for r in R if r["stall"]], [r for r in R if not r["stall"] and r["busy"] >= MIN_BUSY]
    ep = sum(1 for i, r in enumerate(R) if r["stall"] and (i == 0 or not R[i - 1]["stall"]))
    frac = lambda rows, f: sum(1 for r in rows if f(r)) / len(rows) if rows else 0.0
    tests = {
        "external PROCHOT/FORCEPR, any core (0x19C bit 2)": lambda r: r["core_prochot"] > 0,
        "external PROCHOT/FORCEPR, package (0x1B1 bit 2)": lambda r: r["pkg_prochot"] == 1,
        "perf-limit PROCHOT (0x64F bit 0)": lambda r: r["plr_prochot"] == 1,
        "CPU thermal limit, any core (0x19C bit 0)": lambda r: r["core_thermal"] > 0,
        "CPU thermal limit, package (0x1B1 bit 0)": lambda r: r["pkg_thermal"] == 1,
        "perf-limit thermal (0x64F bit 1)": lambda r: r["plr_thermal"] == 1,
    }
    print(f"samples {len(R)}, stalled {len(S)} in {ep} episodes, busy not stalled {len(N)}")
    res = {}
    for k, f in tests.items():
        res[k] = (frac(S, f), frac(N, f))
        print(f"  {k:52} stalled {res[k][0]*100:5.1f}%   normal {res[k][1]*100:5.1f}%")
    for k in ("pl", "psys", "hwp", "power_ctl"):
        print(f"  {k}: stalled {sorted({r[k] for r in S if r[k]})[:4]}  normal {sorted({r[k] for r in N if r[k]})[:4]}")
    pv = lambda rows: sorted({r["plr"] for r in rows if r["plr"]})[:8]
    print("  0x64F values: stalled", pv(S), " normal", pv(N))
    if len(S) < 10:
        print("VERDICT: not enough stalled samples (need 10).")
    else:
        a, b = res["external PROCHOT/FORCEPR, any core (0x19C bit 2)"]
        c, d = res["CPU thermal limit, any core (0x19C bit 0)"]
        if a >= 0.8 and b <= 0.1:
            print("VERDICT: an external agent asserts PROCHOT/FORCEPR during the stall.")
        elif c >= 0.8 and d <= 0.1:
            print("VERDICT: the CPU's own thermal limit tracks the stall; external PROCHOT does not.")
        else:
            print("VERDICT: neither bit tracks the stall cleanly. Compare the 0x64F values and limit registers above.")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--seconds", type=int, default=1500)
    ap.add_argument("--out", default=None)
    ap.add_argument("--msr-root", default="/dev/cpu", help="test hook")
    ap.add_argument("--summarize")
    a = ap.parse_args()
    if a.summarize:
        return summarize(a.summarize)
    out = a.out or os.path.join(os.path.dirname(os.path.abspath(__file__)), time.strftime("xps15-sen6-msr-%Y%m%d-%H%M.jsonl"))
    m = Msr(a.msr_root)
    info = m.get(m.cpus[0], PLATFORM_INFO)
    base = ((info >> 8) & 0xFF) * 100 if info else 0
    if not base:
        raise SystemExit("cannot read base frequency from MSR 0xCE")
    stop = []
    for s in (signal.SIGINT, signal.SIGTERM):
        signal.signal(s, lambda *_: stop.append(1))
    zones, prev, end, last = zone_paths(), None, time.time() + a.seconds, False
    with open(out, "w") as f:
        f.write(json.dumps(dict(type="meta", base_mhz=base, cpus=len(m.cpus),
                                temp_target=hex(m.get(m.cpus[0], TEMP_TARGET) or 0),
                                power_ctl=hex(m.get(m.cpus[0], POWER_CTL) or 0))) + "\n")
        while time.time() < end and not stop:
            t0 = time.time()
            prev, r = sample(m, base, prev, zones)
            r["type"] = "s"
            f.write(json.dumps(r) + "\n")
            f.flush()
            if r["stall"] != last:
                print(time.strftime("%H:%M:%S"), "STALL START" if r["stall"] else "stall end", "SEN6", r.get("SEN6"),
                      "ext-PROCHOT cores", r["core_prochot"], "0x64F", r["plr"], flush=True)
                last = r["stall"]
            time.sleep(max(0, 1 - (time.time() - t0)))
    u, g = os.environ.get("SUDO_UID"), os.environ.get("SUDO_GID")
    if u and g:
        os.chown(out, int(u), int(g))
    print("log:", out)
    summarize(out)


if __name__ == "__main__":
    main()
