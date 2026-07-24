#!/usr/bin/env bash
#
# Harvest and FREEZE experiment M1's source corpus (insight 014).
#
# The committed .jsonl is the artefact; this script is its provenance. Re-running
# it will NOT reproduce the same corpus, because the feeds move. That is expected:
# the corpus is frozen once, before any scoring, and never regenerated. If it ever
# needs replacing, that is a new corpus with a new pre-registration.
#
# WHY HARVESTING IS LEGITIMATE HERE, where it was not for P6: M1's ground truth is
# derived MECHANICALLY from the article text (a field is grounded iff its evidence
# snippet is a verbatim substring of the source and the value occurs inside it).
# Nobody authors the answers, so nobody can pick the winner by choosing words. P6
# needed authored probe queries, which is exactly why it is blocked on data.
#
# HYGIENE, declared before sampling and frozen with the corpus (insight 014 line
# 110 requires this ordering):
#
#   language   English only. The feeds below are chosen accordingly, so no
#              per-item language detection is needed and none can be tuned later.
#   length     MIN_CHARS..MAX_CHARS of plain text. The floor keeps items that
#              have something to extract; the ceiling keeps prompt tokens far
#              below the model's 32k context so nothing is silently truncated
#              (insight 014 counts truncation as a parse-class failure).
#   malformed  an item missing a title, a link, or a description is dropped.
#   dedupe     by normalised text hash, so a story syndicated across two feeds
#              cannot appear twice and inflate N.
#   id         sha256 of the item link, first 16 hex. Stable and content-
#              independent, so `self_audit_corpus:split/2` (which sorts by id)
#              yields the same calibration/confirmatory split on every machine,
#              independent of fetch order.
#
# SOURCES: EU-origin, English-language, public RSS. The same feeds hecate-news
# consumed, filtered to English by the language rule above.

set -euo pipefail

# Lands in the m1_assay app, which is NOT in the relx release, so the corpus
# never ships in a container. It is experiment input, not a runtime asset, which
# is exactly what a `priv/' directory would have wrongly implied.
OUT="${1:-corpora/m1/corpus.jsonl}"
MIN_CHARS=200
MAX_CHARS=1500

FEEDS=(
  "https://www.france24.com/en/rss"
  "https://rss.dw.com/rdf/rss-en-all"
  "https://www.euractiv.com/feed/"
)

RAW="$(mktemp -d)"
trap 'rm -rf "$RAW"' EXIT

echo "harvesting ${#FEEDS[@]} feeds ..." >&2
i=0
for url in "${FEEDS[@]}"; do
  i=$((i + 1))
  if curl -fsSL --max-time 45 -A "hecate-spartan-m1-corpus/1.0" "$url" -o "$RAW/feed$i.xml"; then
    echo "  ok   $url ($(wc -c <"$RAW/feed$i.xml") bytes)" >&2
  else
    echo "  FAIL $url (skipped)" >&2
    rm -f "$RAW/feed$i.xml"
  fi
done

mkdir -p "$(dirname "$OUT")"

MIN_CHARS="$MIN_CHARS" MAX_CHARS="$MAX_CHARS" RAW="$RAW" OUT="$OUT" python3 <<'PY'
import glob, hashlib, html, json, os, re
import xml.etree.ElementTree as ET

MIN = int(os.environ["MIN_CHARS"])
MAX = int(os.environ["MAX_CHARS"])
raw, out = os.environ["RAW"], os.environ["OUT"]

def plain(s):
    """Strip markup and entities, collapse whitespace. RSS descriptions are HTML."""
    s = re.sub(r"<[^>]+>", " ", s or "")
    s = html.unescape(s)
    return re.sub(r"\s+", " ", s).strip()

def findtext(node, *names):
    for n in names:
        el = node.find(n)
        if el is not None and (el.text or "").strip():
            return el.text
        # RDF/RSS1.0 and Atom put things in namespaces
        for child in node:
            if child.tag.rsplit("}", 1)[-1] == n and (child.text or "").strip():
                return child.text
    return ""

items, seen, dropped = [], set(), {"malformed": 0, "short": 0, "long": 0, "dupe": 0}

for path in sorted(glob.glob(f"{raw}/*.xml")):
    try:
        root = ET.parse(path).getroot()
    except ET.ParseError:
        continue
    nodes = [n for n in root.iter() if n.tag.rsplit("}", 1)[-1] in ("item", "entry")]
    for n in nodes:
        title = plain(findtext(n, "title"))
        body = plain(findtext(n, "description", "summary", "content"))
        link = plain(findtext(n, "link", "guid", "id"))
        if not (title and body and link):
            dropped["malformed"] += 1
            continue
        text = f"{title}. {body}" if not title.endswith((".", "?", "!")) else f"{title} {body}"
        if len(text) < MIN:
            dropped["short"] += 1
            continue
        if len(text) > MAX:
            dropped["long"] += 1
            continue
        key = hashlib.sha256(re.sub(r"\W+", "", text.lower()).encode()).hexdigest()
        if key in seen:
            dropped["dupe"] += 1
            continue
        seen.add(key)
        items.append({"id": hashlib.sha256(link.encode()).hexdigest()[:16], "text": text})

items.sort(key=lambda it: it["id"])
with open(out, "w", encoding="utf-8") as f:
    for it in items:
        f.write(json.dumps(it, ensure_ascii=False) + "\n")

print(f"kept {len(items)} items -> {out}")
print("dropped: " + ", ".join(f"{k}={v}" for k, v in dropped.items()))
if items:
    lens = [len(it["text"]) for it in items]
    print(f"length: min={min(lens)} median={sorted(lens)[len(lens)//2]} max={max(lens)}")
PY
