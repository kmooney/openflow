#!/usr/bin/env python3
"""M0 latency benchmark: whisper.cpp across models x clips on this machine.

Separates model-load time from inference time, because a real client loads the
model once and keeps it resident -- only inference is in the hot path.
"""
import json, re, subprocess, sys, time, wave, pathlib

ROOT = pathlib.Path(__file__).resolve().parent.parent
CLI = ROOT / "whisper.cpp/build/bin/whisper-cli"
MODELS = ROOT / "whisper.cpp/models"

def dur(p):
    with wave.open(str(p)) as w:
        return w.getnframes() / w.getframerate()

def run(model, wav, threads=8):
    t0 = time.perf_counter()
    r = subprocess.run(
        [str(CLI), "-m", str(model), "-f", str(wav), "-t", str(threads), "-nt"],
        capture_output=True, text=True)
    wall = (time.perf_counter() - t0) * 1000
    blob = r.stdout + r.stderr
    def grab(label):
        m = re.search(rf"{label}\s+time\s+=\s+([\d.]+)\s*ms", blob)
        return float(m.group(1)) if m else None
    load, total = grab("load"), grab("total")
    text = "\n".join(l for l in r.stdout.splitlines()
                     if l.strip() and not l.startswith(("whisper_", "main:", "ggml_"))).strip()
    infer = (total - load) if (load is not None and total is not None) else None
    return dict(wall_ms=wall, load_ms=load, total_ms=total, infer_ms=infer, text=text)

def main():
    wavs = sorted((ROOT / "audio").glob("*.wav")) + sorted((ROOT / "audio/real").glob("*.wav"))
    models = [p for p in sorted(MODELS.glob("ggml-*.bin")) if "for-tests" not in p.name]
    reps = int(sys.argv[1]) if len(sys.argv) > 1 else 3
    rows = []
    print(f"{'model':<26}{'clip':<12}{'audio':>7}{'infer':>9}{'load':>8}{'RTF':>7}")
    print("-" * 69)
    for m in models:
        for w in wavs:
            d = dur(w)
            best, text = None, ""
            for _ in range(reps):  # best-of-N: we want achievable, not average
                r = run(m, w)
                if r["infer_ms"] is None:
                    continue
                if best is None or r["infer_ms"] < best["infer_ms"]:
                    best = r
                text = r["text"]
            if not best:
                print(f"{m.name:<26}{w.stem:<12}  FAILED"); continue
            rtf = (best["infer_ms"] / 1000) / d
            rows.append(dict(model=m.name, clip=w.stem, audio_s=round(d, 1),
                             infer_ms=round(best["infer_ms"]), load_ms=round(best["load_ms"]),
                             rtf=round(rtf, 3), text=text))
            print(f"{m.name:<26}{w.stem:<12}{d:6.1f}s{best['infer_ms']:8.0f}ms"
                  f"{best['load_ms']:7.0f}ms{rtf:7.3f}")
    (ROOT / "results.json").write_text(json.dumps(rows, indent=2))
    print(f"\nwrote {ROOT/'results.json'}  ({len(rows)} rows)")

main()
