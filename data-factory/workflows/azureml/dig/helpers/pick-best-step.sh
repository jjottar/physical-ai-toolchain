#!/usr/bin/env bash
# Select the best AnomalyGen inference checkpoint step from validation outputs
set -o errexit -o nounset -o pipefail

checkpoint_root="${1:?usage: pick-best-step.sh <checkpoint-root> <fallback-step>}"
fallback_step="${2:?usage: pick-best-step.sh <checkpoint-root> <fallback-step>}"

valid_dir=$(find "$checkpoint_root" -maxdepth 8 -type d -name valid -print -quit 2>/dev/null || true)
if [[ -n "$valid_dir" ]] && ls "$valid_dir"/*/valid_kpi.csv >/dev/null 2>&1; then
  model_dir=$(find "$checkpoint_root" -type d -path '*/checkpoints/model' -print -quit 2>/dev/null || true)
  best_step=$(
    for csv_file in "$valid_dir"/*/valid_kpi.csv; do
      step=$(basename "$(dirname "$csv_file")")
      [[ "$step" != "0" ]] || continue
      if [[ -n "$model_dir" ]]; then
        checkpoint_file=$(printf 'iter_%09d.pt' "$step")
        [[ -f "$model_dir/$checkpoint_file" ]] || continue
      fi
      average_score=$(awk -F',' '$1=="nn_score"{print $NF}' "$csv_file")
      [[ -n "$average_score" ]] && printf '%s %s\n' "$average_score" "$step"
    done | sort -gr | head -1 | awk '{print $2}'
  )
  if [[ -n "$best_step" ]]; then
    printf '[pick-best-step] best=%s from %s\n' "$best_step" "$valid_dir" >&2
    printf '%s\n' "$best_step"
    exit 0
  fi
  printf '[pick-best-step] WARN: no validated step had a matching model checkpoint; using trainer fallback\n' >&2
fi

latest_trained=$(find "$checkpoint_root" -path '*/checkpoints/model/iter_*.pt' -exec basename {} \; 2>/dev/null \
  | sed 's/iter_0*//; s/\.pt//' \
  | sort -gr \
  | head -1)
if [[ -n "$latest_trained" ]]; then
  printf '[pick-best-step] latest trained iter=%s\n' "$latest_trained" >&2
  printf '%s\n' "$latest_trained"
  exit 0
fi

printf '%s\n' "$fallback_step"
