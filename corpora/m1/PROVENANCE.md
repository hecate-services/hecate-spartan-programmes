# M1 corpus — freeze record

The frozen source corpus for experiment M1 (insight 014). `corpora/m1/corpus.jsonl`
is the artefact; `scripts/harvest-m1-corpus.sh` is how it was made.

**Frozen: 2026-07-24. Never regenerated.** Re-running the harvester will not
reproduce it, because the feeds move. If this corpus is ever replaced, that is a
new corpus with a new pre-registration, and this one is retained as the record of
what the earlier run scored against.

## N, declared as a rule rather than a number

**N = every item that survives the frozen hygiene rules.** No sampling step, no
top-N cut, no selection of any kind.

That is deliberate. A pre-registered *count* still leaves someone choosing which
items make the cut; a pre-registered *rule* does not. The only inputs are the feed
snapshot and the hygiene constants, both fixed before anything was fetched.

Realised: **N = 143**, split by `self_audit_corpus:split/2` into **35 calibration**
(the 35 lowest ids) and **108 confirmatory**. The split sorts by id, and id is a
hash of the item link, so it is content-independent and identical on any machine
regardless of fetch order.

## Hygiene (declared before harvesting, per insight 014)

| Rule | Value | Why |
|---|---|---|
| language | English only, enforced by feed choice | no per-item detector that could be tuned afterwards |
| length floor | 200 characters | items below it have nothing to extract |
| length ceiling | 1500 characters | keeps prompts far below the model's 32k context, so nothing is silently truncated; 014 counts truncation as a parse-class failure |
| malformed | dropped if missing title, link or description | |
| dedupe | by normalised text hash | a story syndicated across two feeds cannot inflate N |
| id | `sha256(link)[0:16]` | stable, content-independent, reproducible split |

## Sources

EU-origin, English-language, public RSS. The same feeds `hecate-news` consumed,
filtered to English by the language rule.

| Feed | Result |
|---|---|
| `https://www.france24.com/en/rss` | ok, 30,356 bytes |
| `https://rss.dw.com/rdf/rss-en-all` | ok, 122,269 bytes |
| `https://www.euractiv.com/feed/` | **HTTP 403, skipped** |

The Euractiv failure is recorded rather than retried or worked around. The corpus
is what two feeds yielded under the frozen rules.

## Realised counts

```
kept 143
dropped: malformed=1, short=20, long=0, dupe=0
length: min=201  p25=229  median=256  p75=273  max=1100
```

Verified after freezing: 143 items load, all ids unique, calibration and
confirmatory slices disjoint.

## A note on the length distribution

The median item is 256 characters, which is a headline plus one or two sentences.
Spot-checked items do carry extractable material of all four classes ("100,000
jobs from its 630,000-strong workforce"; "More than 40,000 evacuated ... the local
prefect said Friday").

The distribution was inspected **after** the floor was declared and applied, and
the floor was deliberately **not** re-tuned on the strength of it. Adjusting corpus
hygiene once you can see the data is how a corpus gets shaped toward a result. If
these items turn out too easy, calibration will show a base ungrounded rate below
5% and the run **voids** on 014's own pre-declared condition, which is precisely
what that condition is for. A void is a real outcome; a tuned corpus is not.

## Why harvesting is legitimate here, and was not for P6

M1's ground truth is derived **mechanically** from the article text: a field is
grounded iff its evidence snippet is a verbatim substring of the source and the
value occurs inside it. Nobody authors the answers, so nobody can pick the winner
by choosing wording.

P6 needed authored probe *queries*, where the wording decides whether lexical or
semantic retrieval wins. That is why P6 is blocked on data and M1 is not, and the
difference is worth keeping straight.
