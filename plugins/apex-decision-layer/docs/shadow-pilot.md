# Shadow pilot runbook

How to collect the evidence that `apex-decide measure` needs (spec §8, §9, §14 Phase 3), in one repository, without letting an uncalibrated answer change anything a person would not have chosen. Every step is a human action outside an apex-scope-loop run. `label`, `measure --lock` and an invalidating `replay` are refused (exit 5) while an `ACTIVE` run lock is held.

## 1. Opt in, with shadow on every call

`.claude/apex-decision-layer/config.json`, committed:

```json
{ "egress": "hosted",
  "state_fields": "raw",
  "primary": { "default": "none", "dispatch/task-class@1": "jev", "risk-tier@1": "jev" },
  "shadow": { "backend": "frontier", "sample": 1.0, "deadline_ms": 20000 },
  "jev": { "transport": "typesafe" },
  "decision_log": { "store_state": "full" } }
```

- `store_state: full` keeps each call's state in the decision log. `measure --lock` needs states to build the replay sample, and `replay` needs them to detect drift. Leave it at `hash` if the states are too sensitive to keep. You can still measure, but the record will have no replay sample.
- With no Anthropic key, set `shadow` to `{}` and measure `jev` alone. A shadow answer costs only the call and never reaches a consumer.
- Run `apex-decide doctor --probe` once. It checks that each key is present and each host is reachable.
- In a cloud session whose proxy injects the provider key, export the key variable with a placeholder, for example `TYPESAFE_API_KEY=proxy-injected-key`.

## 2. Run plans as usual

apex-dispatch's `route.sh` asks `dispatch/task-class@1` for every task whose class is still `auto`, and apex-scope-loop's `risk-tier.sh --classify` asks `risk-tier@1`. Every answer and every shadow answer lands in `<state-base>/decisions/decisions.jsonl`. Uncalibrated answers can only tighten a route, so nothing gets cheaper while you collect.

## 3. Label

- **Human labels.** Label a decision after its task is done: `apex-decide label --rubric dispatch/task-class@1 --decision d-… --label feature [--note …]`. The label is the class or tier you would have chosen with hindsight. Labels are committed in `.claude/apex-decision-layer/labels/`.
- **Outcome-proxy labels.** Put them in a JSONL file of `{decision_id, label, source: "outcome-proxy", baseline}`, derived from the ledgers:
  - for task-class, the class the task was finally completed under;
  - for risk-tier, the final effective tier.

  `baseline` is the code-only answer for the same task: the table's class (`table_choice.class`), or the heuristic tier. Pass the file to `corpus` and `measure` with `--outcomes FILE`.
- **The agreement rule.** Proxy labels count only when at least 20 decisions carry both a human label and a proxy label, and the two agree at 0.8 or more. Label a blind, stratified sample: about 50% high confidence, 25% middle and 25% low.

## 4. Measure

```bash
apex-decide corpus  --rubric risk-tier@1 --outcomes outcomes.jsonl --out corpus.jsonl   # inspect the join
apex-decide measure --rubric risk-tier@1 --backend jev --outcomes outcomes.jsonl --out measure-risk-tier-jev.json
```

The report ends with one status:
- `insufficient n`: fewer than 100 labelled rows, or fewer than 10 positives for an acted-on label.
- `degenerate`: fewer than 3 distinct scores for an acted-on label. AUROC means little when the answers are near one-hot, as Jev's mostly are.
- `fails kill criterion`
- `passes kill criterion`: AUROC ≥ 0.6, at least +0.08 over the code-only baseline, the CI's lower bound above the baseline, and a single resolved model.

Brier and ECE are printed beside AUROC. A base-rate predictor has perfect ECE, so read ECE only alongside AUROC.

## 5. Lock (only on a pass)

1. Run `apex-decide measure … --lock`. It writes `.claude/apex-decision-layer/calibration/<rubric>@<v>/<backend>.json` and a `.replay.jsonl` sample, and prints the record's `sha256:` digest.
2. Review the record, then add the digest to `calibration_lock` in the config and commit both. Until the digest is listed, the record calibrates nothing. Editing the record changes its digest, so an edited record stops calibrating too.

## 6. Drift (weekly)

`apex-decide replay --rubric <id>@<v> --backend <name>` re-asks the replay sample. It exits 4 and marks the record `invalidated` when any answer moves more than 0.25, or the provider resolves a different model. Calls are then uncalibrated until someone re-measures. Use `--dry-run` to check without invalidating. A weekly `/schedule` beside apex-scope-loop's architecture review runs the replay, and Phase 4 documents it.
