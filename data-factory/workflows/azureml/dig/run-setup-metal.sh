#!/usr/bin/env bash
# Run the DIG metal surface setup workflow inside an Azure ML job
set -o errexit -o nounset -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || (cd "$SCRIPT_DIR/../../.." && pwd))"

show_help() {
  cat << 'EOF'
Usage: run-setup-metal.sh --model-output DIR --dataset-output DIR

Download the DIG metal surface checkpoint and raw dataset into Azure ML output
folders.

OPTIONS:
    --model-output DIR       Output folder for models/metal_surface
    --dataset-output DIR     Output folder for datasets/metal_surface/raw
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
paidf_root="${PAIDF_ANOMALYGEN_ROOT:-/workspace/paidf-anomalygen}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)          show_help; exit 0 ;;
    --model-output)     model_output="$(require_option_value "$1" "${2:-}")"; shift 2 ;;
    --dataset-output)   dataset_output="$(require_option_value "$1" "${2:-}")"; shift 2 ;;
    *)                  fatal "Unknown option: $1" ;;
  esac
done

[[ -n "$model_output" ]] || fatal "--model-output is required"
[[ -n "$dataset_output" ]] || fatal "--dataset-output is required"
[[ -d "$paidf_root" ]] || fatal "paidf-anomalygen root not found: $paidf_root"

mkdir -p "$model_output" "$dataset_output"

printf '[INFO] Downloading metal surface checkpoint into %s\n' "$model_output"
cd "$paidf_root"
bash scripts/utilities/download_anomalygen_checkpoints.sh \
  --uc metal \
  --checkpoint-dir "$model_output"

nested_dir=$(find "$model_output" -mindepth 2 -maxdepth 3 -name 'iter_*.pt' -exec dirname {} \; 2>/dev/null | head -n 1 || true)
if [[ -n "$nested_dir" && "$nested_dir" != "$model_output" ]]; then
  printf '[INFO] Flattening checkpoint files from %s\n' "$nested_dir"
  find "$nested_dir" -maxdepth 1 -type f \( -name 'iter_*.pt' -o -name 'ag_config.yaml' \) \
    -exec mv {} "$model_output/" \;
  rm -rf "$(dirname "$nested_dir")"
fi

model_file_count=$(find "$model_output" -type f | wc -l | tr -d ' ')
[[ "$model_file_count" -gt 0 ]] || fatal "no files found in $model_output"
printf '[INFO] models/metal_surface file count: %s\n' "$model_file_count"

printf '[INFO] Preparing metal surface dataset into %s\n' "$dataset_output"
python3 -m scripts.utilities.prepare_dataset_uc2 "$dataset_output"

dataset_file_count=$(find "$dataset_output" -type f | wc -l | tr -d ' ')
[[ "$dataset_file_count" -gt 0 ]] || fatal "no files found in $dataset_output"
printf '[INFO] datasets/metal_surface/raw file count: %s\n' "$dataset_file_count"
printf '[INFO] Setup complete from %s\n' "$REPO_ROOT"
