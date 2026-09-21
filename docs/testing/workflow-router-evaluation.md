# Top-level workflow router evaluation

This is a bounded, synthetic dry-run evaluation of the role dispatcher in
`convex/lib/workflow_router.ts`. The experimental dispatcher makes one typed decision:
`direct_action` for the intent of one bounded action, or `workflow` for the
existing planner. It does not extract arguments or execute a request. Dictation
and local Stop handling are outside this evaluation.

The fixture is grouped by scenario family so variants stay in one split. With
seed `20260922`, it contains 30 scenarios in 15 groups: 14 development, 6
calibration, and 10 holdout. It includes the compound request “Open Brave and
search Hello World”, sequencing, negation, corrections, follow-ups, literal
“Paint and Draw” app names, unsupported or sensitive workflows, and simple
single actions. A workflow case marked `harmfulIfDirectAction` counts as a
harmful accepted routing error if the policy admits `direct_action`.

The corrected live run used Jev `jev-1.13.0` and the configured LLM baseline
`gpt-5.6-luna` through 16 cases (6 calibration, then 10 holdout),
32 provider calls, and 11,431 reported tokens. The TypeSafe input estimate was
`$0.000346164` for the Jev calls at `$0.042` per million input tokens. No
desktop input, dictation insertion, email, file, purchase, or deployment
effect was attempted. The complete sanitized rows, including distributions,
confidence, expected/actual routes, latency, usage, and errors, are in
[`workflow-router-live-v2.json`](workflow-router-live-v2.json). The earlier
v1 report is retained as a diagnostic artifact: its baseline was capped at 32
output tokens, which caused some reasoning responses to end before the route
JSON. The same holdout was rerun after this harness correction; it is not a new independent sample. The Jev prompt and frozen threshold values were unchanged. The v2 comparator uses 512 output tokens and records attempted latency
and usage even when a provider contract is invalid.

Calibration froze these thresholds before holdout:

```json
{
  "minSelectedProbability": 0.8,
  "minTopTwoMargin": 0.3
}
```

| Holdout measure | Jev | LLM baseline |
| --- | ---: | ---: |
| Samples | 10 | 10 |
| Valid predictions | 10 (100%) | 10 (100%) |
| Harmful direct-action errors | 0 | 0 |
| Policy-route correctness | 100% | 100% |
| Raw Jev choice correctness | 100% | — |
| p50 classifier latency | 247 ms | 1,296 ms |
| p95 classifier latency (nearest rank) | 388 ms | 3,688 ms |

These scores measure conceptual intent classification, not compatibility with the shipped local parser. Review found that `Please open Brave`, `Scroll up a little`, and `Hit the Escape key` are labeled as single-action intents even though the current exact parser cannot execute them directly. The calibration set includes the last example. A future direct route needs validated argument interpretation before these labels can count as executable successes. The evaluator therefore also holds `directExecutionValidated` false.

Jev passed the conceptual classifier comparison on this small holdout. It did not pass production adoption:
the experiment measured classifier latency only and did not establish that
dispatching a direct action reduces the actual replacement route’s end-to-end
latency. The holdout is also too small to treat zero observed harmful errors as
a safety guarantee.

Run the deterministic check with:

```sh
node scripts/evaluate-workflow-router.ts --mode deterministic
```

Run another explicitly bounded live dry run with the supplied local
configuration path (the script defaults to `.env.local` and accepts an
override):

```sh
node scripts/evaluate-workflow-router.ts \
  --mode live --max-cases 24 --max-calls 48 --max-tokens 250000
```

The evaluator uses a 15-second request timeout, stops after three consecutive
provider failures, enforces the call/token limits, and fails closed to
`workflow` for malformed Jev answers or disabled policy.

The request shape follows the current TypeSafe System One API: a structured
`state`, one named `choice` question, a fixed criteria map, and a returned
choice distribution. See the [TypeSafe API reference](https://docs.typesafe.ai/api)
for the request and response contract.

The production app does not import this experimental dispatcher. Exact recognized commands stay local; other complete requests go to the existing planner. No user setting enables this candidate. Provider or budget stops now retain their partial row as invalid evidence, and incomplete evaluations fail a separate completeness gate.
