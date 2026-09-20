# Intent fallback evaluation

This evaluation exercises the bounded OpenAI fallback used after the frozen Jev development report rejects a route. It uses only the English development split, synthetic utterances, and three checked-in synthetic PNG fixtures. It never dispatches a desktop action, changes a file, sends mail, uploads a real screen, or deploys anything.

The fallback request is built by `convex/lib/intent_fallback.ts`. The helper carries the same instructions and text envelope as the runtime path, and the parser delegates to the production `intent_policy.ts` validator. The runtime imports the same helper and validator and uses the same 1,024-token response ceiling.

The runner deliberately evaluates a small fixed set: one high-confidence Jev wrong-intent row, one dictation row, one keyboard row, one ambiguous row, one unsupported row, and three visual rows. It performs a direct text baseline, reuses that exact text result as the cascade's text fallback when the frozen Jev gate rejects, and sends one additional image-paired request for each visual row. The hard ceiling is 24 cases, 24 provider calls, and 60,000 reported tokens; the default eight-case run needs at most 19 calls.

The frozen Jev gate is applied independently at every relevant stage with selected probability ≥ 0.5, confidence ≥ 0.5, and top-two margin ≥ 0.8. Action rows require intent, action, and target gates; dictation, clarification, and unsupported rows require only the intent gate. The calibration and holdout files are recorded for provenance. The holdout is never used to retune the gate.

Run the source through the repository's existing esbuild dependency so the production TypeScript modules are bundled before Node executes it:

```sh
node_modules/.bin/esbuild scripts/evaluate-intent-fallback.ts \
  --bundle --platform=node --format=esm \
  --outfile=/tmp/evaluate-intent-fallback.mjs
node --env-file=/Users/owen/Documents/Projects/FlowState/.env.local \
  /tmp/evaluate-intent-fallback.mjs \
  --mode live \
  --output docs/testing/intent/fallback-evaluation-v2.json
```

The command must use the configured `FLOWSTATE_PLANNER_MODEL` for its first fallback request. A 404 stops the run as an unsupported-model limitation; three consecutive provider or validation failures stop it as repeated failures. The runner never silently selects another model. It requires reported OpenAI usage before counting a prediction toward the token budget and writes a sanitized JSON report even when preflight or provider availability prevents measurement.

The checked-in report [fallback-evaluation-v1.json](./intent/fallback-evaluation-v1.json) preserves the bounded live smoke pilot for `gpt-5.6-luna` with the frozen `jev-1.13.0` development rows. That pilot used the previous envelope before the explicit non-action omission rule and the 1,024-token response ceiling were added; its `currentPromptVersion` field points to the current runner envelope. The configured model probe returned HTTP 200, then the pilot stopped after three consecutive fallback failures. It recorded 10 calls and 2,877 tokens: two measured text-baseline predictions, three measured cascade predictions, and one measured vision prediction. These partial observations are not a release accuracy claim; the report records the errors by class, skipped image pair, frozen thresholds, and reason for stopping. New runs use `intent-fallback-v2` and write the selected output path without silently replacing this pilot evidence.

Deterministic validation makes no provider calls and still records fixture and frozen-report hashes:

```sh
node_modules/.bin/esbuild scripts/evaluate-intent-fallback.ts \
  --bundle --platform=node --format=esm \
  --outfile=/tmp/evaluate-intent-fallback.mjs
node /tmp/evaluate-intent-fallback.mjs \
  --mode deterministic \
  --output /tmp/intent-fallback-deterministic.json
```

## Final bounded smoke and limits

The earlier worker ledger totals 22 provider calls: one HTTP-200 availability probe with unparsed usage, a ten-call run (3,964 reported tokens), one diagnostic call (308 tokens), and the preserved ten-call pilot (2,877 tokens). The root used the remaining two calls for [prompt v2](intent/fallback-evaluation-v2.json), reaching the 24-call ceiling. Both v2 responses parsed: an unsupported-password example requested clarification, and a literal scroll sentence remained dictation requiring review. They used 759 reported tokens, with latencies 3,139 ms and 3,932 ms. Total reported usage is 7,908 tokens plus unknown probe/unreported-failure usage; this is not a complete billing total.

The v2 run stopped at its two-call limit. Six text cases and all three image pairs were skipped. There is no measured v2 vision accuracy or completed all-controls fallback comparison. The earlier pilot includes malformed-output and no-output failures; preserve those results. Cloud actions remain confirmation-only. These two successful parses validate the repaired envelope, not release accuracy or autonomous operation.
