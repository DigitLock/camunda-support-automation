"""Classifier calibration report (design D5-2). Runs the classifier module directly
against the Anthropic API — no Camunda, no database.

Usage: report.sh [--runs N] [--subset e2e] [--tickets PATH]
Writes report-latest.md next to this file. Exit 1 if intent accuracy < 0.85 or any
silent error (wrong intent that was not sent to review) occurred in the last run.
"""

import argparse
import json
import sys
from collections import Counter, defaultdict
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent / ".." / ".." / "workers" / "llm-classifier"))
import classifier  # noqa: E402

HERE = Path(__file__).parent
E2E_IDS = {f"T-100{i}" for i in range(1, 8)}
THRESHOLD_SWEEP = [0.6, 0.7, 0.8, 0.9]

# claude-haiku-4-5 USD per MTok as of 2026-09 — update on price change
PRICE_IN, PRICE_OUT = 1.00, 5.00
PRICE_CACHE_WRITE, PRICE_CACHE_READ = 1.25, 0.10

ACCURACY_GATE, SILENT_GATE = 0.85, 0


def cost_usd(tokens):
    plain_in = tokens["in"] - tokens["cache_write"] - tokens["cache_read"]
    return (
        plain_in * PRICE_IN + tokens["cache_write"] * PRICE_CACHE_WRITE
        + tokens["cache_read"] * PRICE_CACHE_READ + tokens["out"] * PRICE_OUT
    ) / 1_000_000


def run_once(clf, tickets):
    results = []
    for t in tickets:
        outcome = clf.classify(t["subject"], t["body"])
        results.append({"ticket": t, **outcome})
        v = outcome["variables"]
        print(f"  {t['id']}: {v['intent']} ({v['confidence']:.2f})"
              f"{' REVIEW ' + ','.join(outcome['audit']['review_reasons']) if v['needsReview'] else ''}")
    return results


def analyse(results, threshold):
    """Metrics for one run; needsReview is recomputed for the sweep from the recorded
    confidence + non-threshold reasons, so one API run serves all thresholds."""
    strict = [r for r in results if r["ticket"]["expected"]["intent"] is not None]
    ambiguous = [r for r in results if r["ticket"]["expected"]["intent"] is None]

    def reviewed(r, t):
        other = [x for x in r["audit"]["review_reasons"] if x != "below_threshold"]
        return bool(other) or r["variables"]["confidence"] < t

    intent_ok = [r for r in strict if r["variables"]["intent"] == r["ticket"]["expected"]["intent"]]
    silent = [r for r in strict
              if r["variables"]["intent"] != r["ticket"]["expected"]["intent"]
              and not reviewed(r, threshold)]
    sentiment_miss = [(r["ticket"]["id"], r["ticket"]["expected"]["sentiment"],
                       r["variables"]["sentiment"]) for r in results
                      if r["variables"]["sentiment"] != r["ticket"]["expected"]["sentiment"]]
    lang_miss = [(r["ticket"]["id"], r["ticket"]["language"],
                  r["variables"]["detectedLanguage"]) for r in results
                 if r["variables"]["detectedLanguage"] != r["ticket"]["language"]]

    confusion = defaultdict(Counter)
    for r in strict:
        confusion[r["ticket"]["expected"]["intent"]][r["variables"]["intent"]] += 1

    sweep = []
    for t in THRESHOLD_SWEEP:
        auto = [r for r in strict if not reviewed(r, t)]
        auto_ok = sum(r["variables"]["intent"] == r["ticket"]["expected"]["intent"] for r in auto)
        sweep.append({
            "threshold": t,
            "auto_accuracy": auto_ok / len(auto) if auto else 1.0,
            "review_rate": 1 - (len(auto) + sum(not reviewed(r, t) for r in ambiguous)) / len(results),
        })

    tokens = {
        "in": sum(r["audit"]["tokens_in"] or 0 for r in results),
        "out": sum(r["audit"]["tokens_out"] or 0 for r in results),
        "cache_write": sum(r["audit"]["cache_creation_tokens"] for r in results),
        "cache_read": sum(r["audit"]["cache_read_tokens"] for r in results),
    }
    return {
        "intent_accuracy": len(intent_ok) / len(strict) if strict else 1.0,
        "strict_total": len(strict),
        "intent_correct": len(intent_ok),
        "silent": [(r["ticket"]["id"], r["variables"]["intent"],
                    r["ticket"]["expected"]["intent"]) for r in silent],
        "ambiguous_reviewed": sum(reviewed(r, threshold) for r in ambiguous),
        "ambiguous_total": len(ambiguous),
        "sentiment_accuracy": 1 - len(sentiment_miss) / len(results),
        "sentiment_miss": sentiment_miss,
        "language_accuracy": 1 - len(lang_miss) / len(results),
        "language_miss": lang_miss,
        "review_rate": sum(reviewed(r, threshold) for r in results) / len(results),
        "fallbacks": sum(r["variables"]["classifierSource"] == "fallback" for r in results),
        "confusion": confusion,
        "sweep": sweep,
        "tokens": tokens,
    }


def render(metrics, runs_results, threshold, subset_name):
    lines = [
        "# Classification report (latest)",
        "",
        f"Prompt: `{runs_results[0][0]['variables']['promptVersion']}` · "
        f"threshold: {threshold} · tickets: {len(runs_results[0])} ({subset_name}) · "
        f"runs: {len(runs_results)}",
        "",
        f"- **Intent accuracy: {metrics['intent_accuracy']:.1%}**"
        f" ({metrics['intent_correct']}/{metrics['strict_total']} non-ambiguous)",
        f"- Silent errors (wrong intent, not reviewed): **{len(metrics['silent'])}**"
        + (f" — {metrics['silent']}" if metrics["silent"] else ""),
        f"- Ambiguous routed to review: {metrics['ambiguous_reviewed']}/{metrics['ambiguous_total']}",
        f"- Sentiment accuracy: {metrics['sentiment_accuracy']:.1%}"
        + (f" — misses (id, expected → predicted): "
           f"{[f'{i}: {e} → {p}' for i, e, p in metrics['sentiment_miss']]}"
           if metrics["sentiment_miss"] else ""),
        f"- Language accuracy: {metrics['language_accuracy']:.1%}"
        + (f" — misses (id, expected → predicted): "
           f"{[f'{i}: {e} → {p}' for i, e, p in metrics['language_miss']]}"
           if metrics["language_miss"] else ""),
        f"- Review rate: {metrics['review_rate']:.1%} · fallbacks: {metrics['fallbacks']}",
        "",
        "## Intent confusion (expected → predicted)",
        "",
        "| expected \\ predicted | " + " | ".join(classifier.guardrails.INTENTS) + " |",
        "|---|" + "---|" * len(classifier.guardrails.INTENTS),
    ]
    for exp in classifier.guardrails.INTENTS:
        row = metrics["confusion"].get(exp, {})
        lines.append(f"| {exp} | " + " | ".join(str(row.get(p, 0))
                     for p in classifier.guardrails.INTENTS) + " |")
    lines += [
        "",
        "## Threshold sweep",
        "",
        "| threshold | auto-routed accuracy | review rate |",
        "|---|---|---|",
    ]
    for s in metrics["sweep"]:
        lines.append(f"| {s['threshold']} | {s['auto_accuracy']:.1%} | {s['review_rate']:.1%} |")

    if len(runs_results) > 1:
        stable = 0
        total = len(runs_results[0])
        for i in range(total):
            intents = {run[i]["variables"]["intent"] for run in runs_results}
            stable += len(intents) == 1
        lines += ["", f"## Stability: {stable}/{total} tickets identical across "
                      f"{len(runs_results)} runs"]

    t = metrics["tokens"]
    lines += [
        "",
        "## Tokens and cost (last run)",
        "",
        f"- input {t['in']} (cache write {t['cache_write']}, cache read {t['cache_read']}),"
        f" output {t['out']}",
        f"- estimated cost: ${cost_usd(t):.4f}"
        f" (haiku-4-5 prices as of 2026-09, cache-read-aware)",
    ]
    return "\n".join(lines) + "\n"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--runs", type=int, default=1)
    ap.add_argument("--subset", choices=["e2e"], default=None)
    ap.add_argument("--tickets", default=str(HERE / "tickets-40.json"))
    args = ap.parse_args()

    tickets = json.loads(Path(args.tickets).read_text())
    subset_name = "full set"
    if args.subset == "e2e":
        tickets = [t for t in tickets if t["id"] in E2E_IDS]
        subset_name = "e2e subset"

    clf = classifier.build_from_env()
    runs_results = []
    for n in range(args.runs):
        print(f"run {n + 1}/{args.runs}:")
        runs_results.append(run_once(clf, tickets))

    metrics = analyse(runs_results[-1], clf.threshold)
    report = render(metrics, runs_results, clf.threshold, subset_name)
    (HERE / "report-latest.md").write_text(report)
    print("\n" + report)

    failed = metrics["intent_accuracy"] < ACCURACY_GATE or len(metrics["silent"]) > SILENT_GATE
    if failed:
        print(f"GATE FAILED: accuracy {metrics['intent_accuracy']:.1%} (gate {ACCURACY_GATE:.0%}),"
              f" silent errors {len(metrics['silent'])} (gate {SILENT_GATE})")
    if metrics["fallbacks"] > 0:
        print(f"FAIL: {metrics['fallbacks']} fallbacks — the gate measured rules, not the model")
        failed = True
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
