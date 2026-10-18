#!/usr/bin/env python3
"""Checks recorder B lines for fold handoff problems.
usage: foldcheck.py recording.txt
For every visible status bar (keyed by window and order) it reports frames where
  - the fold view is up but a trailing system icon is not hidden (double drawing),
  - trailing icons are hidden but no fold layer is visible (a blank frame),
  - a fold layer jumps (moves or resizes more than JUMP points between frames),
and the state of the last frame (must be fully restored once unfolded)."""
import re, sys

TRAILING = ("CellularSignalView", "WifiSignalView", "BatteryView")
JUMP = 8.0
item_re = re.compile(r"\[(\S+) ([-\d.]+) ([-\d.]+) ([-\d.]+) ([-\d.]+) a([-\d.]+)( M)?\]")

def frames(path):
    for line in open(path):
        if not line.startswith("B "):
            continue
        m = re.search(r"t=([\d.]+)", line)
        if not m:
            continue
        t = float(m.group(1))
        for index, (window, body) in enumerate(re.findall(r"\{(\w+)(.*?)\}", line)):
            items = [(i[0], float(i[5]), bool(i[6]), tuple(float(v) for v in i[1:5])) for i in item_re.findall(body)]
            yield t, "%s#%d" % (window, index), items

problems = []
last = {}
previous_by_bar = {}
for t, bar, items in frames(sys.argv[1]):
    previous = previous_by_bar.get(bar, {})
    trailing = [i for i in items if any(k in i[0] for k in TRAILING)]
    fold = [i for i in items if i[0].startswith("dli.") and i[1] > 0.01]
    fold_view = any(i[0] == "DLIStatusFoldView" for i in items)
    if fold_view and any(not masked and a > 0.01 for _, a, masked, _ in trailing):
        problems.append((t, bar + " fold view up but a system icon is drawn", [i[:3] for i in trailing]))
    if any(masked for _, _, masked, _ in trailing) and not fold:
        problems.append((t, bar + " icons hidden but nothing drawn", [i[:3] for i in trailing]))
    current = {}
    for name, a, _, (x, y, w, h) in fold:
        if name in ("dli.fill", "dli.track") or name in current:
            continue
        current[name] = (x + w / 2, y + h / 2, w, h)
        if name in previous:
            px, py, pw, ph = previous[name]
            d = max(abs(x + w / 2 - px), abs(y + h / 2 - py), abs(w - pw), abs(h - ph))
            if d > JUMP:
                problems.append((t, "%s %s jumps %.1f pt" % (bar, name, d), (previous[name], current[name])))
    previous_by_bar[bar] = current
    last[bar] = (t, items)

for p in problems[:20]:
    print("%.4f %s %s" % p)
print("%d problem frames" % len(problems))
for bar, (t, items) in sorted(last.items()):
    masked = [i[0].replace("STUIStatusBar", "") for i in items if i[2]]
    fold = [i[0] for i in items if i[0].startswith("dli.") or i[0] == "DLIStatusFoldView"]
    print("last %s t=%.3f masked=%s fold=%d layers" % (bar, t, masked, len(fold)))
