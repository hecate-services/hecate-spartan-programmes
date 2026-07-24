# hecate-spartan-programmes

Experiment runners for the hecate-spartan research programmes.

This repository exists to fix one specific hole, and the hole is not hypothetical:
it is the same one faber fell into and paid for.

## The problem it solves

The hecate-spartan corpus publishes signed insights (`hecate-spartan/insights/`).
Until this repository existed, the runner that produced a result lived **inside
the service it measured**: `apps/hecate_spartan/src/weigh_self_audit/`, and its
frozen corpus briefly sat in `apps/hecate_spartan/priv/`. The release is
`[hecate_spartan, sasl]`, so both shipped in every container.

Two costs, one obvious and one not.

The obvious one: a service image carrying an experiment and 50KB of news articles
it never reads.

The one that matters: **a runner that lives inside its subject drifts with it.**
faber learned this at insight 047. A buggy runner yields a feed that is wrong and
*internally consistent*, which no amount of analysis on the feed alone can detect;
two faber insights (038, 040) were retracted as exactly that confound, and no
faber insight before 047 records which engine version produced it.

## How it fixes it

Runners live here permanently and never run on the service's test suite. The
record for an experiment is **four** things, not two:

| Artefact | Lives in |
|---|---|
| Signed insight | `hecate-spartan/insights/NNN_*.md` |
| Frozen corpus and raw feed | here, `corpora/<experiment>/` |
| Runner | here, `experiments/` while active, `programmes/` once archived |
| Endpoint and model pin | here, in the experiment's own provider module |

## Deliberately not depending on hecate-spartan

faber-programmes consumes faber-tweann as a library at a pinned commit, and
`git log rebar.config` is its provenance. This repository does **not** do that,
and the difference is not laziness.

Pinning hecate-spartan would drag macula, reckon-db, evoq and their Rust NIFs into
a harness that needs a URL and a model name. Every future re-run of an experiment
would then depend on whether that whole stack still builds. `hecate-arena` is
dep-free for the same reason.

It is also mostly unnecessary. **For M1 the subject under test is a prompt
protocol, not hecate-spartan code**: draft versus draft-then-verify, against a
pinned model. The service contributed one function's worth of configuration, which
`pinned_provider` now owns in fifteen lines.

Where an experiment's subject genuinely *is* service code (the defusal and recall
programmes: `defuse.erl`, `mind_memory`), that experiment pins it deliberately, in
its own directory, and records the pin. A per-experiment decision, not a repo-wide
one.

So what gets pinned here is what actually determines a result: the **model**, the
**prompt**, the **corpus**, and the **checker**.

## Layout

```
experiments/   ACTIVE working area. Compiled. One experiment at a time.
programmes/    ARCHIVE. Never compiled, never on a source path.
corpora/       frozen corpora and raw feeds, one directory per experiment
scripts/       harvest, run
src/           the app stub that makes this a rebar3 project
```

`programmes/` is absent from `src_dirs` on purpose. An archived runner is a
record, not a build input: it never compiles again and it never runs on this
repository's test suite.

## Experiments

| # | Experiment | Insight | Status |
|---|---|---|---|
| M1 | self-audit economics: does draft-then-verify earn its 2x compute? | [014](https://codeberg.org/hecate-services/hecate-spartan/src/branch/main/insights/014_experiment_m1_self_audit_economics_pre_registration.md) | built, corpus frozen, **not yet run** |

M1's confirmatory slice is scored **once**, and `self_audit_assay:run/2` performs
calibration and confirmatory scoring in a single pass. Running it is a decision,
not a build step.

## Running M1

```sh
HECATE_LOCAL_URL=http://msi00.lab:11434/v1/chat/completions \
HECATE_LOCAL_MODEL=qwen2.5:7b-instruct-q4_K_M \
  ./scripts/run-m1.sh
```

Expect a few hours: CPU inference runs 25 to 80 seconds per call, and the run
makes three calls per item across 143 items. It is free, unmetered and offline,
which is exactly why it was chosen over a hosted endpoint.
