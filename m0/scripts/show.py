"""Render one utterance in every register, and report honest timings."""
import json, re, subprocess, sys

raw, want, FMT, log = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
blob = open(log).read() if log else ""
def grab(label):
    m = re.search(rf"{label}\s+time\s+=\s+([\d.]+)\s*ms", blob)
    return float(m.group(1)) if m else 0.0
load, total = grab("load"), grab("total")
asr = int(total - load) if total > load > 0 else 0

G, D, R, B, C, X = "\033[32m", "\033[2m", "\033[0m", "\033[1m", "\033[36m", "\033[31m"

def run(tone):
    p = subprocess.run([FMT, "--tone", tone], input=raw, capture_output=True, text=True)
    return json.loads(p.stdout)

print(f"\n  {D}raw / null{R}     {raw}")
res, fails = {}, []
for tone, label in [("formal", "formal"), ("casual", "casual"), ("very-casual", "very casual")]:
    j = run(tone); res[tone] = j
    mark = f" {C}<- clipboard{R}" if tone == want else ""
    body = j["formatted"].replace("\n", f"{D}⏎{R}{G} ")
    print(f"  {B}{label:<11}{R}   {G}{body}{R}{mark}")
    if not j["guardrail_passed"]:
        fails.append(tone)
        print(f"    {X}REJECTED{R} {j.get('note','')} dropped={j['dropped']} added={j['added']}")

ledger = res["formal"].get("ledger", [])
if ledger:
    print(f"\n  {D}ledger — words OpenFlow changed, and why:{R}")
    for e in ledger:
        to = e["to"] or "(removed)"
        print(f"    {D}·{R} {e['from']!r} -> {to}  {D}[{e['why']}]{R}")

pick = res.get(want, res["formal"])
subprocess.run(["pbcopy"], input=(pick["formatted"] or raw), text=True)
verdict = f"{G}all pass{R}" if not fails else f"{X}FAILED: {fails}{R}"
print(f"\n  {B}{asr}ms{R} {D}after you stopped talking · guardrail {verdict}")
print(f"  +{int(load)}ms model load, paid once at launch in the real app, not per utterance.{R}")
