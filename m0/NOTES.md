# M0 findings

Hardware: **Apple M2 (Mac14,2 MacBook Air), 8 cores, 16 GB, macOS 26.6.2.**
Deliberately mid-range — not an M-series Max. whisper.cpp @ Metal, release build.

Method: `scripts/bench.py`, best-of-3 per cell. **Load time is reported
separately from inference time**, because a real client loads the model once at
launch and keeps it resident; only inference is in the keystroke hot path.

---

## 1. Latency — and a result that contradicts the spec

Inference ms (excl. model load), by clip length:

| model | 4s | 10s | 22s | 33s | load |
|---|---|---|---|---|---|
| `base.en` (141 MB) | 152 | **222** | 368 | 571 | 61 ms |
| `small.en` (465 MB) | 394 | **539** | 838 | 1263 | 150 ms |
| `large-v3-turbo-q5_0` (574 MB) | 1402 | **1510** | 1731 | 3164 | 174 ms |
| `large-v3-turbo` (1.6 GB, f16) | 1195 | **1316** | 1568 | 2869 | 462 ms |

**`large-v3-turbo` is the wrong model for dictation, and the spec was wrong to
assume otherwise.** It spends ~1.45s before it has transcribed anything: a 4s
clip costs 1447ms and a 10s clip only 1586ms. That flat floor is the tell —
turbo shrinks Whisper's *decoder* (32 layers → 4) but keeps large-v3's *full
encoder*, and Whisper always pads its input to a 30s window. So encoder cost is
constant and pays no attention to how briefly you spoke.

**Quantization made turbo slower, not faster.** `q5_0` costs ~200ms against the
f16 build at every clip length, despite being a third the size. On Metal the
dequantization work outweighs the reduced memory traffic, and Apple's GPU path
for f16 is well optimized. Quantize to fit a model in memory, not to make it
quick — and never assume the smaller file is the faster one without measuring.

Turbo's advertised speedup is a long-form transcription result, where decoding
dominates. Push-to-talk dictation is the opposite regime: utterances are short,
so cost is encoder-bound and turbo inherits large-v3's bill while its cheaper
decoder has almost nothing to do. It blows the entire 1.5s end-to-end budget on
the ASR stage alone.

**Corollary: RTF is the wrong metric for this product and we should stop
quoting it.** Turbo transcribes the 10s clip at RTF 0.158 — "6× faster than
real time," which sounds excellent and is useless. What the user feels is the
absolute wait after they release the key. Report ms at 5/10/20s, never RTF.

### Recommended default: `small.en`

541ms at 10s leaves ~950ms of the 1.5s budget, and everything downstream
(formatter, guardrail, insertion) measures under 10ms combined. `base.en` is
2.4× faster again and is the right fallback for weak hardware, but it makes real
errors (below). 465 MB is an acceptable first-run download.

---

## 2. Accuracy — three findings, one of them a design problem

From the disfluent clip ("Um, so, the the deploy failed and uh I think…"):

| model | output |
|---|---|
| `base.en` | "Um, so, **that** the deploy failed and **that** I think…" |
| `small.en` | "Um, so, the deploy failed and I think…" |
| `turbo-q5_0` | "Um, so, the the deploy failed and uh I think…" (verbatim) |

**(a) `base.en` substitutes rather than admits uncertainty.** It turned both
`uh`s into `that` — inventing a function word that changes the sentence. That's
worse than dropping it, and it disqualifies `base.en` as a default.

**(b) `small.en` silently deletes disfluencies by itself.** It dropped `uh` and
the `the the` stutter with no prompting. Good for output quality — and a real
problem for our safety story: **the guardrail only covers the formatting stage.
If the ASR edits the user's words, nothing catches it,** because the raw ASR
text *is* the guardrail's reference. We are trusting the ASR absolutely and
should say so in the spec rather than implying the guardrail protects the whole
pipeline. It doesn't; it protects everything downstream of transcription.

**(c) Whisper auto-punctuates and auto-capitalizes, as the spec assumed.** All
three models produced sentence case, commas, and terminal punctuation unaided.
This is confirmed, and it's the main reason the null default is defensible.

---

## 3. Does the rules stage earn its place?

On **fluent** dictation (`s10`, `s30`), the rules formatter changed nothing at
all — `changed=false` for every model. Whisper's output was already sendable.

On **disfluent** dictation it removed the fillers and fired the paragraph break,
and the guardrail passed in every case.

Provisional read: **null is the right default and rules should be one toggle
away.** The rules stage is worth having and worth *not* forcing on anyone. But
this is measured against synthetic speech, and the fluent/disfluent split here
was authored by hand rather than observed — the honest version of this number
needs real recordings (§5).

---

## 4. Two guardrail findings from building it

**Spoken commands delete words on purpose.** "new paragraph" → `\n\n` removes
two real words, so the rules stage could never pass its own guardrail until
`normalize()` erased command phrases from *both* sides. That is exactly the kind
of hole the spec warned about: it is now possible for a formatting driver to
delete a literal "new paragraph" the user meant to say, undetected. Enumerable,
documented, small — but real, and it is the price of having spoken commands at
all.

**List numbering was better solved by preserving than by erasing.** "first… 
second…" → "1. … 2. …" also deletes words. The first attempt stripped list
markers in `normalize()`, which made the ordinal words vanish on one side only
and failed the check. Mapping ordinal words onto the marker's digit (`first` ≡
`1`) keeps the information on both sides instead of blinding the guardrail to
it. General principle worth carrying into `openflow-core`: **canonicalize both
sides toward each other; only erase as a last resort.** Every erasure is a hole.

Two real bugs the tests caught, both worth keeping as regressions: stutter
collapse silently ate the newlines that the structure commands had just
inserted, and a command phrase between two sentences stranded its punctuation
at the start of the new line (`".\n\n. Let's"`).

Current state: 14 tests, all passing, including the adversarial ones — invented
text, a "helpful" grammar rewrite (`i seen` → `I saw`), a dropped content word,
and prompt injection spoken aloud. All correctly rejected.

---

## 5. What is NOT answered yet

**Everything above about *quality* rests on synthetic `say` audio, which is not
valid for it.** TTS has no natural hesitation, no false starts, no
self-correction, and a synthesised "um" is not the signal a hesitating person
produces. Latency and RTF conclusions are unaffected — those depend on audio
duration, not naturalness — but WER and "is raw output good enough" do not
survive the substitution.

`scripts/record.sh` captures six real prompts (speak, don't read). Once those
exist, re-running `scripts/bench.py` answers:

- true WER per model on real dictation
- how often raw Whisper output is already sendable → validates the null default
- how often the rules stage helps, and how often it trips the guardrail

---

## 6. Tone / register (added after the latency work)

Three presets, built as pure rules: **formal** (unchanged output), **casual**
(capitals kept, sentence periods → line breaks, no trailing stop, `?`/`!` kept),
**very casual** (casual + lowercase + no commas).

Two things worth recording:

**Tone cannot trip the guardrail, by construction.** It touches only case,
punctuation and whitespace — exactly what `normalize()` erases — so the check is
blind to it. That's the correct relationship, not a gap: the guardrail exists to
prove your *words* survived, and tone never touches words. Keep running the
check on it anyway; it's free, and a tone failure would indicate a bug in our
own code rather than a misbehaving driver. Useful canary.

**Dropping periods outright is wrong.** "Running late Be there in ten" is not
less punctuation, it's unreadable. Casual converts the sentence boundary to a
line break, which is what people actually do when texting.

Three bugs the tests caught while building it, all now regressions: `2.15` split
into `2`⏎`15` (the boundary check looked at character class but not whitespace);
a period surviving in front of an existing "new paragraph" break (the scan
skipped spaces but not newlines); and `--tone formal` being parsed as an input
filename.

---

## 7. Proper nouns — measured

The most visible quality failure. Baseline `small.en` on a clip naming three
uncommon proper nouns:

| | output |
|---|---|
| baseline | meet in **Largemont** … Ask **Xiaobhan** and Xiaoming |
| + vocabulary hint | meet in **Larchmont** … Ask **Siobhan** and Xiaoming |
| + *unrelated* vocabulary | meet in **Lachmont** … Ask **Xiaobhan** and Xiaoming |

Both errors fixed for +30ms (397 → 427ms). **The third row is the control**: an
unrelated word list did not help, ruling out "any prompt perturbs the decoder
favourably" as the explanation. This is genuine term-specific biasing.

**The prompt is a style prime, not only a vocabulary prime.** A bare
comma-separated list fixed the names but made the model drop punctuation from
the whole transcript — it imitated the prompt's register. Phrasing the hint as a
punctuated sentence keeps both. This is not documented anywhere obvious and cost
an experiment to find; anyone wiring up `initial_prompt` should know it.

Prompt cap is ~224 tokens (`n_text_ctx/2`), so ~100–150 terms. Larger
vocabularies need per-utterance selection, not a full dump.

**Architectural consequence:** proper-noun correction cannot live in the
formatting chain. Rewriting "Largemont" → "Larchmont" is word substitution,
which is exactly what the guardrail forbids — a formatting driver doing it would
be correctly rejected. It has to happen at transcription time via biasing. The
`Hint { vocab }` field in the spec was right; it just needed to be wired up and
made a first-class user-facing feature.

Try it: `./scripts/try.sh` reads `vocab.txt`; `--no-vocab` turns it off.

## 8. Spoken quotes, and signatures

**Quotes.** Detecting "quote-unquote" is trivial; knowing how many words it
covers is not — it is a semantic problem in lexical clothing. Exact spans when
both markers are spoken ("quote … unquote"); a noun-phrase heuristic when only
the opening one is. The stopword list will never be complete, and a gap
over-extends the quote. It fails safe: all words survive, the guardrail passes,
only the quotation marks land wrong. First candidate for an LLM stage.

A bare "quote" is only treated as a marker when a closer follows in the same
sentence, so "she gave me a quote for the work" is left alone.

**Signatures.** A trailing sign-off is exempt from tone — very casual
lowercasing your own name reads as sloppy, not relaxed. Requires a sign-off
phrase *plus* a name; "ok thanks" at the end of a text is not a signature.

31 tests green.

---

## 9. The guardrail was mis-specified

Kevin's objection: *"if the guardrail makes the system work worse, then it is
not a good guardrail."* Correct, and it applies to what I had written.

The v0.2–0.9 invariant was "no word may ever change." That forbade spoken
self-correction — a feature people actually want — and I had explicitly chosen
to ship without it rather than widen the rule. That is a guardrail degrading the
product to protect its own invariant.

The fix is not a weaker rule but a better-aimed one. What we want is not that
words never change; it's that **changes are always visible and accountable.** So
the invariant becomes **no _undeclared_ word changes**: a stage may change words
if it declares which and why, and the host verifies that the declared edits
fully account for the diff.

Exact equality is now the special case where the declaration is empty — still
the default for every word-preserving stage.

Kevin's follow-up — *"changing a word here or there is not super important
though the system should be strongly biased against doing so"* — is a budget,
not a permission. Defaults: `Vocabulary` the only allowed category, 3 edits max,
and an invention ceiling of max(2 words, 25%).

Two things measurement forced:

- **The ceiling needs a floor.** A bare percentage refused one proper-noun fix
  in a 7-word sentence, and short utterances are most of dictation.
- **Count words introduced, not words touched.** Self-correction legitimately
  deletes several words ("Bob, I mean Bill"); inventing text is the real danger.
  Budgeting deletions punished exactly the feature this redesign existed to
  enable.

Also fixed: splicing declared edits into the canonical form skipped the
immediate-repeat collapse that `normalize()` performs, so a legitimate edit
could read as undeclared.

39 tests green, including the one that matters most — declaring
`Largemont → Larchmont` does not license also turning `noon` into `dawn`.

## 10. Enumerations

"One, garlic cloves. Two, milk. Three, raisin bran." → a numbered list. Filed in
the early drafts as "maybe, heuristics get most of it"; having built it, it is
solidly tier-1 work. **The signal is consecutive enumerators each opening their
own sentence, ascending by one** — a conjunction rare enough in prose that the
false-positive rate is low with no semantics at all. "I'll take one. Two would
be better." is correctly left alone, because "one" doesn't open its clause.

Default threshold is three items; two is a real construction but a much weaker
signal and a false positive mangles prose.

**It needed no new guardrail hole**, which is the payoff from the earlier
decision to canonicalize list markers rather than erase them: `normalize()`
already maps both "one" and "1." to the token `1`, so deleting the enumerator
word is invisible to the check without widening anything. Erasure is a hole;
canonicalization is not. That principle has now paid off twice.

Three bugs, all the same shape — a period that isn't a sentence boundary:
`1.` split by the sentence splitter, `1.` split again by the tone transform,
and (earlier) `2.15` split by both. Worth a shared helper in `openflow-core`
rather than three separate guards.

46 tests green.

## 11. Unordered lists, and corrections

**Unordered lists need an announcement.** Unlike enumerations there is no
enumerator signal, and a comma series is syntactically identical to prose. So a
cue is required — "list"/"shopping"/"groceries"/"agenda" in the previous
sentence, or an opening "I need …". That is the whole safety story, and it turns
out to be a feature: the user gets an explicit way to *ask* for a list rather
than the formatter guessing from punctuation. Two extra filters: an item with a
finite verb is a clause ("I went to the store, bought milk"), and items over six
words are runaway prose.

**The guardrail caught a real bug in my own code here.** Stripping the connector
in "bread, and butter" deletes the word "and" — the check rejected the whole
transform and rolled it back, which is exactly right. The fix was to declare it
(`Structure`), not to widen `normalize()`. Worth recording: the first thing the
ledger caught was me.

**Corrections are the feature the old guardrail made impossible.** Erasure is
word deletion; under "no word may ever change" it could not exist. Under the
ledger it declares what it removed, invents nothing so it costs no budget, and
shows up in the utterance record.

Two cue classes, and collapsing them into one rule produced visibly wrong output
for whichever case lost:

- **clause** ("scratch that", "start over", `no no no`) — discard the whole
  preceding attempt
- **phrase** ("I mean", "rather") — replace only the phrase before the cue

A single "no" is an answer, two or more is a correction. Where scope is
ambiguous the rule errs toward deleting less: an extra word left in is
recoverable, a deleted one is not.

Also fixed: both list passes split text into sentences and rejoined, destroying
newlines a "new paragraph" command had already inserted. They now run per line.
And bullet items after the first weren't capitalizing, because the `-` marker
consumed the sentence-start state — the ordered case had only worked by accident
since its "." happened to re-trigger it.

55 tests green.

## 12. Salutations

"Hi John," / "Dear Sarah," get their own block, completing letter layout
(salutation / body / signature). Detection needs **greeting + capitalized name +
comma** — all three, because any two fire on ordinary speech: "Hi, I wanted to
ask" (no name), "Hey we should ship it" (neither), "Dear god, that was close"
(lowercase, so not a name).

Suppressed in very casual, which is the texting register — a text shouldn't
acquire email shape. That is asymmetric with the signature, which is kept in
every register because that was the explicit ask. Flagged in the spec; if the
asymmetry grates, pick one rule for both blocks.

Word-preserving, so free under the guardrail. 60 tests green.
