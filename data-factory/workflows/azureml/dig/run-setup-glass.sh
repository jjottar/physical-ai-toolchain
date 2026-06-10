#!/usr/bin/env bash
# Run the DIG glass setup workflow inside an Azure ML job
set -o errexit -o nounset -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || (cd "$SCRIPT_DIR/../../.." && pwd))"

show_help() {
  cat << 'EOF'
Usage: run-setup-glass.sh --model-output DIR --dataset-output DIR --glass-zip PATH

Download the DIG glass checkpoint and prepare the glass raw dataset from a
user-staged Roboflow mobile_screen.zip file.

OPTIONS:
    --model-output DIR       Output folder for models/glass
    --dataset-output DIR     Output folder for datasets/glass/raw
    --glass-zip PATH         Downloaded mobile_screen.zip file or containing directory
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
glass_zip=""
paidf_root="${PAIDF_ANOMALYGEN_ROOT:-/workspace/paidf-anomalygen}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)          show_help; exit 0 ;;
    --model-output)     model_output="$(require_option_value "$1" "${2:-}")"; shift 2 ;;
    --dataset-output)   dataset_output="$(require_option_value "$1" "${2:-}")"; shift 2 ;;
    --glass-zip)        glass_zip="$(require_option_value "$1" "${2:-}")"; shift 2 ;;
    *)                  fatal "Unknown option: $1" ;;
  esac
done

[[ -n "$model_output" ]] || fatal "--model-output is required"
[[ -n "$dataset_output" ]] || fatal "--dataset-output is required"
[[ -n "$glass_zip" ]] || fatal "--glass-zip is required"
[[ -d "$paidf_root" ]] || fatal "paidf-anomalygen root not found: $paidf_root"

if [[ -d "$glass_zip" ]]; then
  glass_zip="$glass_zip/mobile_screen.zip"
fi
[[ -f "$glass_zip" ]] || fatal "mobile_screen.zip not found: $glass_zip"
[[ "$(basename "$glass_zip")" == "mobile_screen.zip" ]] || fatal "glass zip must be named mobile_screen.zip"

mkdir -p "$model_output" "$dataset_output"
cd "$paidf_root"

printf '[INFO] Downloading glass checkpoint into %s\n' "$model_output"
bash scripts/utilities/download_anomalygen_checkpoints.sh \
  --uc glass \
  --checkpoint-dir "$model_output"

nested_dir=$(find "$model_output" -mindepth 2 -maxdepth 3 -name 'iter_*.pt' -exec dirname {} \; 2>/dev/null | head -n 1 || true)
if [[ -n "$nested_dir" && "$nested_dir" != "$model_output" ]]; then
  printf '[INFO] Flattening checkpoint files from %s\n' "$nested_dir"
  find "$nested_dir" -maxdepth 1 -type f \( -name 'iter_*.pt' -o -name 'ag_config.yaml' \) \
    -exec mv {} "$model_output/" \;
  rm -rf "$(dirname "$nested_dir")"
fi

[[ -f "$model_output/ag_config.yaml" ]] || fatal "ag_config.yaml not found in $model_output"
[[ -f "$model_output/iter_000009000.pt" || -n "$(find "$model_output" -maxdepth 1 -name 'iter_*.pt' -print -quit)" ]] || \
  fatal "iter_*.pt checkpoint not found in $model_output"

printf '[INFO] Preparing glass dataset into %s\n' "$dataset_output"
cp "$glass_zip" /tmp/uc3_input.zip
python3 -m scripts.utilities.prepare_dataset_uc3 "$dataset_output" \
  --zip /tmp/uc3_input.zip \
  --masks-from-hf
rm -rf "$dataset_output/.cache" 2>/dev/null || true
rm -f "$dataset_output/.gitattributes" 2>/dev/null || true

[[ -f "$dataset_output/defect_spec.jsonl" ]] || fatal "defect_spec.jsonl not found in $dataset_output"
[[ -d "$dataset_output/Phone" ]] || fatal "Phone material directory not found in $dataset_output"

model_file_count=$(find "$model_output" -type f | wc -l | tr -d ' ')
dataset_file_count=$(find "$dataset_output" -type f | wc -l | tr -d ' ')
[[ "$model_file_count" -gt 0 ]] || fatal "no files found in $model_output"
[[ "$dataset_file_count" -gt 0 ]] || fatal "no files found in $dataset_output"

{
  printf 'workflow=setup-glass\n'
  printf 'model_output=%s\n' "$model_output"
  printf 'dataset_output=%s\n' "$dataset_output"
  printf 'model_file_count=%s\n' "$model_file_count"
  printf 'dataset_file_count=%s\n' "$dataset_file_count"
} >"$model_output/artifact_manifest.txt"

printf '[INFO] models/glass file count: %s\n' "$model_file_count"
printf '[INFO] datasets/glass/raw file count: %s\n' "$dataset_file_count"
printf '[INFO] Artifact manifest: %s\n' "$model_output/artifact_manifest.txt"
printf '[INFO] Setup complete from %s\n' "$REPO_ROOT"
