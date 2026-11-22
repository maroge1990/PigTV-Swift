#!/usr/bin/env python3
"""#360 (E1): a Time Profiler trace of the Guide's scenarios, summarised per scenario window.

  python3 Tools/profile-summary.py <time-profile.xml> <os-signpost.xml> [presses,…] [samples.json.gz]
  python3 Tools/profile-summary.py <samples.json.gz> - [presses,…]        (summarise a saved samples file again)

The XML inputs are `xctrace export` tables (time-profile, os-signpost). The main thread's samples can be saved
(time, weight, stack) to summarise again elsewhere. Windows: clusters of GuideFocusMove signposts, else of the sampled
focus updates (the grid's didUpdateFocusIn), else the busy stretches of the main thread; a gap of 2 s starts a new one.
With presses given (testProfileScenarios: 40,40,10 for down, up, right) the last that many windows are the scenarios (the
presses that enter the grid come first). For each it prints the main thread's on-CPU ms (in all and per press), the
phases (each sample counted once, by the first phase in the list that any frame of its stack matches), the top symbols
at the top of the stack, and the nearest app (PigTV) frame, inclusive.
"""
import gzip
import json
import re
import sys
import xml.etree.ElementTree as ET
from collections import Counter

PHASES = [  # in order: a sample goes to the first phase any of its frames matches
    ("XCUITest accessibility queries", r"XCTAccessibility|XCTAutomation|AXRuntime|AXUIElement|_accessibility|Accessibility"),
    ("probe (measurement)", r"GuidePerfProbe|GuidePerf\.|DisplayLinkFrames|GuideFrameWait"),
    ("cell configuration (updateConfiguration)", r"updateConfiguration|UIHostingConfiguration|_UIHostingConfiguration"),
    ("focus engine (UIKit)", r"UIFocus|_UIFocus|FocusSystem|FocusEngine|updateFocus|FocusUpdate|focusAnimation"),
    ("collection view data and layout", r"GuideGridLayout|GuideGridStore|UICollectionViewData|UICollectionViewLayout|-\[UICollectionView |_UICollectionView"),
    ("SwiftUI (graph, bodies, hosting)", r"AttributeGraph|AG::|ViewGraph|GraphHost|ViewRendererHost|UIHosting|_UIHostingView|\|SwiftUI"),
    ("Core Animation layout", r"CA::Layer::layout|layoutSublayers|layoutSubviews|layoutIfNeeded"),
    ("Core Animation commit and render", r"CA::Transaction|CA::Context|CA::Layer::|CA::Render|RB::|\|QuartzCore|\|RenderBox"),
    ("run loop and dispatch", r"CFRunLoop|_dispatch|dispatch_"),
]


def load(path):
    rows, ids = [], {}
    for _, el in ET.iterparse(path, events=("end",)):
        if "id" in el.attrib:
            ids[el.attrib["id"]] = el
        if el.tag == "row":
            rows.append(el)
    return rows, ids


def res(el, ids):
    if el is None:
        return None
    return ids.get(el.attrib["ref"], el) if "ref" in el.attrib else el


def frames(bt, ids):
    out = []
    if bt is None:
        return out
    for f in bt.iter("frame"):
        f = res(f, ids)
        b = f.find("binary")
        b = res(b, ids) if b is not None else None
        out.append((f.attrib.get("name", "?"), b.attrib.get("name", "?") if b is not None else "?"))
    return out


def from_xml(tp, sp):
    windows = []
    srows, sids = load(sp)
    moves = []
    for r in srows:
        name, t = r.find("name"), r.find("event-time")
        name, t = res(name, sids), res(t, sids)
        if name is not None and t is not None and (name.text or "") == "GuideFocusMove":
            moves.append(int(t.text))
    for t in sorted(moves):
        if windows and t - windows[-1][1] < 2e9:
            windows[-1][1] = t
        else:
            windows.append([t, t])
    rows, ids = load(tp)
    samples = []
    for r in rows:
        th = res(r.find("thread"), ids)
        if th is None or not th.attrib.get("fmt", "").startswith("Main Thread"):
            continue
        t = int(res(r.find("sample-time"), ids).text)
        w = r.find("weight")
        w = int(res(w, ids).text) if w is not None else 1_000_000
        bt = None
        for child in r:  # the stack column: a backtrace (or tagged-backtrace) element, possibly a reference
            c = res(child, ids)
            if c is not None and c.find(".//frame") is not None:
                bt = c
                break
        samples.append((t, w, frames(bt, ids)))
    return samples, windows


def summarise(samples, windows, presses):
    samples.sort(key=lambda x: x[0])
    print(f"PROFILE main-thread samples in the trace: {len(samples)}")
    if not windows:
        for t, _, fr in samples:
            if any("didUpdateFocusIn" in n for n, _ in fr):
                if windows and t - windows[-1][1] < 2e9:
                    windows[-1][1] = t
                else:
                    windows.append([t, t])
        windows = [w for w in windows if w[1] > w[0]]
        print(f"PROFILE windows from sampled focus updates: {len(windows)}")
    if not windows and samples:
        start = samples[0][0]
        bins = Counter()
        for t, w, _ in samples:
            bins[(t - start) // 250_000_000] += w
        runs = []
        for b in sorted(k for k, v in bins.items() if v > 5_000_000):
            if runs and b - runs[-1][1] <= 6:
                runs[-1][1] = b
            else:
                runs.append([b, b])
        windows = [[start + a * 250_000_000, start + (b + 1) * 250_000_000] for a, b in runs]
        print(f"PROFILE windows from busy stretches: {len(windows)}")
    if presses:
        windows = windows[-len(presses):]
    for i, (a, b) in enumerate(windows):
        inside = [s for s in samples if a - 50_000_000 <= s[0] <= b + 400_000_000]
        total = sum(s[1] for s in inside) / 1e6
        n = presses[i] if i < len(presses) else 0
        per = f", {total / n:.1f} ms per press over {n:.0f}" if n else ""
        print(f"\nPROFILE window {i + 1}: {(b - a) / 1e9:.1f} s, main thread on CPU {total:.1f} ms{per}")
        phase, top, app = Counter(), Counter(), Counter()
        for _, w, fr in inside:
            names = [f"{nm}|{bn}" for nm, bn in fr]
            chosen = "other"
            for label, pat in PHASES:
                if any(re.search(pat, x) for x in names):
                    chosen = label
                    break
            phase[chosen] += w
            if fr:
                top[f"{fr[0][0]} [{fr[0][1]}]"] += w
            own = next((nm for nm, bn in fr if bn.startswith("PigTV")), None)
            app[own or "(no PigTV frame)"] += w

        def table(title, c, k):
            print(f"  {title}")
            whole = max(1, sum(c.values()))
            for name, w in c.most_common(k):
                ms = w / 1e6
                pp = f"{ms / n:7.2f}" if n else "      -"
                print(f"    {ms:8.1f} ms {pp} /press {100 * w / whole:5.1f}%  {name[:160]}")
        table("phases (ms, ms per press, share)", phase, 12)
        table("top of stack (self)", top, 25)
        table("nearest PigTV frame (inclusive)", app, 15)


def main():
    tp, sp = sys.argv[1], sys.argv[2]
    presses = [float(x) for x in sys.argv[3].split(",")] if len(sys.argv) > 3 and sys.argv[3] else []
    if tp.endswith(".json.gz"):
        samples = [(t, w, [tuple(f.rsplit("|", 1)) for f in fr]) for t, w, fr in json.load(gzip.open(tp, "rt"))]
        summarise(samples, [], presses)
        return
    samples, windows = from_xml(tp, sp)
    if len(sys.argv) > 4:
        with gzip.open(sys.argv[4], "wt") as out:
            json.dump([[t, w, [f"{nm}|{bn}" for nm, bn in fr]] for t, w, fr in samples], out)
    summarise(samples, windows, presses)


main()
