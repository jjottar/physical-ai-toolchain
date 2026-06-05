#!/usr/bin/env bash
# Run the DIG PCBA setup workflow inside an Azure ML job
set -o errexit -o nounset -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || (cd "$SCRIPT_DIR/../../.." && pwd))"

show_help() {
  cat << 'EOF'
Usage: run-setup-pcb.sh --model-output DIR --dataset-output DIR --assets-output DIR

Download the DIG PCBA checkpoint, raw dataset, and USD assets into Azure ML
output folders.

OPTIONS:
    --model-output DIR       Output folder for models/pcb
    --dataset-output DIR     Output folder for datasets/pcb/raw
    --assets-output DIR      Output folder for datasets/pcb/assets
    -h, --help               Show this help message
EOF
}

fatal() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

require_option_value() {
  local option_name="$1" option_value="${2:-}"

  [[ -n "$option_value" && "$option_value" != --* ]] || fatal "$option_name requires a value"
  echo "$option_value"
}

model_output=""
dataset_output=""
assets_output=""
paidf_root="${PAIDF_ANOMALYGEN_ROOT:-/workspace/paidf-anomalygen}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)          show_help; exit 0 ;;
    --model-output)     model_output="$(require_option_value "$1" "${2:-}")"; shift 2 ;;
    --dataset-output)   dataset_output="$(require_option_value "$1" "${2:-}")"; shift 2 ;;
    --assets-output)    assets_output="$(require_option_value "$1" "${2:-}")"; shift 2 ;;
    *)                  fatal "Unknown option: $1" ;;
  esac
done

[[ -n "$model_output" ]] || fatal "--model-output is required"
[[ -n "$dataset_output" ]] || fatal "--dataset-output is required"
[[ -n "$assets_output" ]] || fatal "--assets-output is required"
[[ -d "$paidf_root" ]] || fatal "paidf-anomalygen root not found: $paidf_root"

mkdir -p "$model_output" "$dataset_output" "$assets_output"
cd "$paidf_root"

printf '[INFO] Downloading PCBA checkpoint into %s\n' "$model_output"
bash scripts/utilities/download_anomalygen_checkpoints.sh \
  --uc pcb \
  --checkpoint-dir "$model_output"

nested_dir=$(find "$model_output" -mindepth 2 -maxdepth 3 -name 'iter_*.pt' -exec dirname {} \; 2>/dev/null | head -n 1 || true)
if [[ -n "$nested_dir" && "$nested_dir" != "$model_output" ]]; then
  printf '[INFO] Flattening checkpoint files from %s\n' "$nested_dir"
  find "$nested_dir" -maxdepth 1 -type f \( -name 'iter_*.pt' -o -name 'ag_config.yaml' \) \
    -exec mv {} "$model_output/" \;
  rm -rf "$(dirname "$nested_dir")"
fi

[[ -f "$model_output/ag_config.yaml" ]] || fatal "ag_config.yaml not found in $model_output"
[[ -f "$model_output/iter_000014000.pt" || -n "$(find "$model_output" -maxdepth 1 -name 'iter_*.pt' -print -quit)" ]] || \
  fatal "iter_*.pt checkpoint not found in $model_output"

printf '[INFO] Preparing PCBA raw dataset into %s\n' "$dataset_output"
python3 -m scripts.utilities.prepare_dataset_uc1 "$dataset_output"
rm -f "$dataset_output/.gitattributes" 2>/dev/null || true
[[ -f "$dataset_output/defect_spec.jsonl" ]] || fatal "defect_spec.jsonl not found in $dataset_output"

printf '[INFO] Downloading PCBA USD assets into %s\n' "$assets_output"
hf download nvidia/Spark-AnomalyGen-USD \
  --repo-type dataset \
  --local-dir "$assets_output"
rm -rf "$assets_output/.cache" 2>/dev/null || true
rm -f "$assets_output/.gitattributes" 2>/dev/null || true
find "$assets_output" -type f \( -name '*.usd' -o -name '*.usda' \) -print -quit | grep -q . || \
  fatal "no USD assets found in $assets_output"

model_file_count=$(find "$model_output" -type f | wc -l | tr -d ' ')
dataset_file_count=$(find "$dataset_output" -type f | wc -l | tr -d ' ')
assets_file_count=$(find "$assets_output" -type f | wc -l | tr -d ' ')
[[ "$model_file_count" -gt 0 ]] || fatal "no files found in $model_output"
[[ "$dataset_file_count" -gt 0 ]] || fatal "no files found in $dataset_output"
[[ "$assets_file_count" -gt 0 ]] || fatal "no files found in $assets_output"

{
  printf 'workflow=setup-pcb\n'
  printf 'model_output=%s\n' "$model_output"
  printf 'dataset_output=%s\n' "$dataset_output"
  printf 'assets_output=%s\n' "$assets_output"
  printf 'model_file_count=%s\n' "$model_file_count"
  printf 'dataset_file_count=%s\n' "$dataset_file_count"
  printf 'assets_file_count=%s\n' "$assets_file_count"
} >"$model_output/artifact_manifest.txt"

printf '[INFO] models/pcb file count: %s\n' "$model_file_count"
printf '[INFO] datasets/pcb/raw file count: %s\n' "$dataset_file_count"
printf '[INFO] datasets/pcb/assets file count: %s\n' "$assets_file_count"
printf '[INFO] Artifact manifest: %s\n' "$model_output/artifact_manifest.txt"
printf '[INFO] Setup complete from %s\n' "$REPO_ROOT"
