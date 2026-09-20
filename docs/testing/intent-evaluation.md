# Intent evaluation

The intent fixture and evaluator are English only. The fixture is synthetic and contains 320 labeled inputs in 80 scenario families across 10 categories. Family variants stay in one split so correlated paraphrases and failure variants cannot leak between development, calibration, and holdout data. The report keeps both input and family counts; the 320 inputs are not independent observations.

Run the deterministic fixture check without credentials or network access:

```sh
pnpm evaluate:intent --seed 17
```

The default report records the fixture version and SHA-256, prompt and candidate-set versions, family and split counts, and the expected intent/action distribution. The stratified split contains 160 development, 80 calibration, and 80 holdout inputs. It does not call a model and leaves accuracy and thresholds unset. To score a separately produced prediction map, pass a JSON object keyed by the split-qualified scenario ID:

```sh
pnpm evaluate:intent --seed 17 --predictions ./tmp/intent-predictions.json
```

The live command evaluates routing only. It never dispatches a desktop action, sends mail, changes files, or deploys anything. Every live run must state all three budgets and a split:

```sh
pnpm evaluate:intent:live --split development --max-cases 30 --max-calls 30 --max-tokens 10000
```

The command stops when it reaches the case, call, or reported token budget, after a conservative prompt-size preflight. Unknown usage stops the run immediately because a token budget cannot be enforced; three consecutive provider failures also stop it. It requires `TYPESAFE_API_KEY` and `FLOWSTATE_JEV_MODEL`; provider failures become bounded report rows. It records the model alias, scenario ID, prompt/candidate-set versions, supported actions and capabilities, actual choices, selected probabilities, confidence, usage, and latency. The runner uses the production question builder and strict validator: complete independent choice answers, exact candidate sets, finite probabilities that sum to one, and required confidence are required before recording a result. Service actions are included only in fixture cases whose `supportedActions` explicitly includes them; they remain dry-run vocabulary cases.

## Measured review policy — September 21, 2026

Model: `jev-1.13.0`; prompt: `intent-questions-v2`; candidate set: `fixture-candidates-v1`; seed: 17. Sanitized [development](intent/development-prompt-v2.json), [calibration](intent/calibration-v2.json), [holdout](intent/holdout-v2.json), and [sweep](intent/calibration-sweep.json) reports are committed. All inputs were synthetic. There were no desktop or service effects.

| Split | Inputs / independent families | Correct raw intent | Dictation misread as action | Model p50 / p95 | Reported input tokens |
|---|---|---|---|---|---|
| Development | 160 / 40 | 126 / 160 | 2 | 269 / 379 ms | 173,843 |
| Calibration | 80 / 20 | 70 / 80 | 4 | 271 / 368 ms | 86,797 |
| Untouched holdout | 80 / 20 | 73 / 80 | 1 | 278 / 324 ms | 86,695 |

These are classifier results, not successful executions. Arguments, permissions, endpoint accuracy, installed-app candidate lists, and end-to-end latency require separate checks. The live native candidate list is larger than the synthetic lists, so the numbers do not transfer directly to deployed use.

A 640-combination sweep on calibration selected confidence >= 0.5, selected-option probability >= 0.5, and top-two margin >= 0.8 for every required stage: intent, plus action and target for action decisions. The criterion maximized action/dictation proposal coverage subject to zero observed wrong intent/action/target combinations. The gate was frozen before the holdout run. It accepted 15/80 calibration inputs across five families and 15/80 holdout inputs across seven families, with zero observed joint-choice errors in either accepted set. Thresholds were not retuned on holdout.

**This is a review policy, not an automatic execution policy.** Even zero failures in 15 independent trials would leave an approximately 18.1% one-sided 95% upper bound on the failure rate; these variants are correlated. Treating seven families as independent would leave an approximately 34.8% upper bound. Neither is evidence of production safety. `DEFAULT_INTENT_POLICY` therefore requires confirmation of every cloud proposal, including fallback proposals. Exact, tested local commands remain available without a model call. Literal dictation prefixes bypass interpretation and retain their payload.

The gate resolves 21/80 holdout decisions when accepted clarification/unsupported decisions are included; 59/80 would need further interpretation (73.75%). This is a proposed classifier escalation rate, not a measured live fallback or screenshot rate. Permission, parameter and capability checks can stop a proposal independently. The holdout literal-correction error and all development/calibration errors remain in the committed reports and regression corpus; they must not become unattended effects.

At TypeSafe's published [Jev price](https://docs.typesafe.ai/models.md) of $0.042 per million input tokens with output free, the frozen development/calibration/holdout runs cost approximately $0.00730 / $0.00365 / $0.00364 respectively, based on reported usage. Holdout Jev-only cost is approximately $0.00455 per 100 utterances. This excludes transcription, Convex, fallback calls and earlier experiments. Earlier prompt-v1 calls produced four invalid probability distributions and were rejected; their unreported usage means experiment totals cannot be represented as exact bills.

No real screen was uploaded for this evaluation. The screenshot path requires a current per-app capture grant and a separate upload opt-in, bounds images in memory, rejects protected/unknown content, records window/display geometry, and revalidates before upload and execution. A model cannot grant these permissions. Raw screenshots and transcripts are not stored in intent request records.

Remaining release evidence: bounded text/vision comparison results; consented continuous microphone sessions and endpoint tuning; authenticated native cloud round-trip; real window/focus/revocation acceptance across apps and displays; memory/end-to-end latency; a second clean Mac/account. No fixed sample size here establishes “all possible cases.”
