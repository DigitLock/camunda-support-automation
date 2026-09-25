"""Generation report for ticket.answer (design D5-9, D5-11). Runs the generator module
directly against the Anthropic API — no Camunda, no database.

Usage: report.sh [--runs N] [--questions PATH]
Writes report-<answer prompt version>.md next to this file. Exit 1 if any grounding
violation occurred (on any attempt — a violation caught by the retry still means the
prompt let a number leak) or any in-KB question ended in the fallback template.
"""

import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent / ".." / ".." / "workers" / "llm-classifier"))
import generator  # noqa: E402
from llm import generation_guardrails as gg  # noqa: E402

HERE = Path(__file__).parent

# claude-sonnet-5 USD per MTok as of 2026-09 — update on price change
PRICE_IN, PRICE_OUT = 2.00, 10.00
PRICE_CACHE_WRITE, PRICE_CACHE_READ = 2.50, 0.20


def cost_usd(tokens):
    plain_in = tokens["in"] - tokens["cache_write"] - tokens["cache_read"]
    return (
        plain_in * PRICE_IN + tokens["cache_write"] * PRICE_CACHE_WRITE
        + tokens["cache_read"] * PRICE_CACHE_READ + tokens["out"] * PRICE_OUT
    ) / 1_000_000


def run_once(gen, questions):
    results = []
    for q in questions:
        variables = {"ticketId": q["id"], "subject": q["subject"], "body": q["body"],
                     "language": q["language"], "bookingRef": q.get("bookingRef")}
        outcome = gen.answer(variables)
        v, a = outcome["variables"], outcome["audit"]
        results.append({"question": q, **outcome})
        flags = []
        if a["violations"]:
            flags.append("violations=" + ",".join(a["violations"]))
        if v["answerSource"] == "fallback":
            flags.append("FALLBACK " + str(a["fallback_reason"]))
        print(f"  {q['id']}: kb={v['answerKbIds']} chars={len(v['answerText'])} "
              f"{' '.join(flags)}")
        print(f"      {v['answerText'][:160]}{'…' if len(v['answerText']) > 160 else ''}")
    return results


def analyse(results):
    grounding = [(r["question"]["id"], r["audit"]["violations"]) for r in results
                 if "grounding_violation" in r["audit"]["violations"]]
    other_violations = [(r["question"]["id"], r["audit"]["violations"]) for r in results
                        if r["audit"]["violations"]
                        and "grounding_violation" not in r["audit"]["violations"]]
    in_kb = [r for r in results if r["question"]["inKb"]]
    out_kb = [r for r in results if not r["question"]["inKb"]]
    in_kb_fallback = [r["question"]["id"] for r in in_kb
                      if r["variables"]["answerSource"] == "fallback"]
    kb_hits = [r["question"]["id"] for r in in_kb
               if set(r["question"]["expectKbIds"]) & set(r["variables"]["answerKbIds"])]
    # a handover may cite the section it partially answered from as well (Q-09: KB-07 +
    # KB-11 is correct behaviour), so the metric checks for KB-11, not for equality
    handover = [r["question"]["id"] for r in out_kb
                if "KB-11" in r["variables"]["answerKbIds"]]
    lengths = [len(r["variables"]["answerText"]) for r in results]
    tokens = {
        "in": sum(r["audit"]["tokens_in"] or 0 for r in results),
        "out": sum(r["audit"]["tokens_out"] or 0 for r in results),
        "cache_write": sum(r["audit"]["cache_creation_tokens"] for r in results),
        "cache_read": sum(r["audit"]["cache_read_tokens"] for r in results),
    }
    return {
        "grounding": grounding,
        "other_violations": other_violations,
        "in_kb_total": len(in_kb), "in_kb_fallback": in_kb_fallback, "kb_hits": kb_hits,
        "out_kb_total": len(out_kb), "handover": handover,
        "fallbacks": sum(r["variables"]["answerSource"] == "fallback" for r in results),
        "max_chars": max(lengths), "avg_chars": sum(lengths) / len(lengths),
        "tokens": tokens,
    }


def render(m, runs_results, version, model):
    lines = [
        f"# Generation report — `{version}`",
        "",
        f"Model: `{model}` · questions: {len(runs_results[0])} "
        f"({m['in_kb_total']} in KB, {m['out_kb_total']} outside) · runs: {len(runs_results)}",
        "",
        f"- **Grounding violations (any attempt): {len(m['grounding'])}**"
        + (f" — {m['grounding']}" if m["grounding"] else ""),
        f"- Other guardrail rejections: {len(m['other_violations'])}"
        + (f" — {m['other_violations']}" if m["other_violations"] else ""),
        f"- In-KB questions ending in fallback: **{len(m['in_kb_fallback'])}**"
        + (f" — {m['in_kb_fallback']}" if m["in_kb_fallback"] else ""),
        f"- In-KB questions citing the expected section: {len(m['kb_hits'])}/{m['in_kb_total']}",
        f"- Outside-KB questions handed over (KB-11 in usedKbIds): "
        f"{len(m['handover'])}/{m['out_kb_total']}",
        f"- Fallbacks total: {m['fallbacks']} · max length {m['max_chars']} chars "
        f"(limit {gg.MAX_TEXT_CHARS}) · avg {m['avg_chars']:.0f}",
        "",
        "## Answers (last run)",
        "",
        "| id | lang | in KB | usedKbIds | source | text |",
        "|---|---|---|---|---|---|",
    ]
    for r in runs_results[-1]:
        q, v = r["question"], r["variables"]
        text = v["answerText"].replace("|", "\\|").replace("\n", " ")
        lines.append(f"| {q['id']} | {q['language']} | {'yes' if q['inKb'] else 'no'} | "
                     f"{', '.join(v['answerKbIds'])} | {v['answerSource']} | {text} |")
    if len(runs_results) > 1:
        stable = sum(
            len({tuple(run[i]["variables"]["answerKbIds"]) for run in runs_results}) == 1
            for i in range(len(runs_results[0]))
        )
        lines += ["", f"## Stability: {stable}/{len(runs_results[0])} questions cite the "
                      f"same sections across {len(runs_results)} runs"]
    t = m["tokens"]
    lines += [
        "",
        "## Tokens and cost (last run)",
        "",
        f"- input {t['in']} (cache write {t['cache_write']}, cache read {t['cache_read']}),"
        f" output {t['out']}",
        f"- estimated cost: ${cost_usd(t):.4f} (sonnet-5 prices as of 2026-09, cache-read-aware)",
    ]
    return "\n".join(lines) + "\n"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--runs", type=int, default=1)
    ap.add_argument("--questions", default=str(HERE / "questions.json"))
    args = ap.parse_args()

    questions = json.loads(Path(args.questions).read_text(encoding="utf-8"))
    gen = generator.build_from_env()
    runs_results = []
    for n in range(args.runs):
        print(f"run {n + 1}/{args.runs}:")
        runs_results.append(run_once(gen, questions))

    m = analyse(runs_results[-1])
    models = {r["audit"]["model"] for r in runs_results[-1] if r["audit"]["model"] != "fallback"}
    report = render(m, runs_results, gen.answer_version, ", ".join(sorted(models)) or "n/a")
    out = HERE / f"report-{gen.answer_version}.md"
    out.write_text(report, encoding="utf-8")
    print("\n" + report)

    failed = False
    if m["grounding"]:
        print(f"GATE FAILED: {len(m['grounding'])} grounding violation(s)")
        failed = True
    if m["in_kb_fallback"]:
        print(f"GATE FAILED: in-KB questions ended in fallback: {m['in_kb_fallback']}")
        failed = True
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
