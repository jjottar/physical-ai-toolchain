#!/usr/bin/env bash
# Run the DIG pretrained bundle setup workflow inside an Azure ML job
set -o errexit -o nounset -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || (cd "$SCRIPT_DIR/../../.." && pwd))"

show_help() {
  cat << 'EOF'
Usage: run-setup-pretrained.sh --pretrained-output DIR [OPTIONS]

Assemble models/pretrained for DIG workflows into an Azure ML output folder.

OPTIONS:
    --pretrained-output DIR   Output folder for models/pretrained
    --model-sizes SIZES       Cosmos Predict2 model sizes (default: 2B)
    -h, --help                Show this help message
EOF
}

fatal() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

require_option_value() {
  local option_name="$1" option_value="${2:-}"

  [[ -n "$option_value" && "$option_value" != --* ]] || fatal "$option_name requires a value"
  echo "$option_value"
}

pretrained_output=""
model_sizes="2B"
paidf_root="${PAIDF_ANOMALYGEN_ROOT:-/workspace/paidf-anomalygen}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)              show_help; exit 0 ;;
    --pretrained-output)    pretrained_output="$(require_option_value "$1" "${2:-}")"; shift 2 ;;
    --model-sizes)          model_sizes="$(require_option_value "$1" "${2:-}")"; shift 2 ;;
    *)                      fatal "Unknown option: $1" ;;
  esac
done

[[ -n "$pretrained_output" ]] || fatal "--pretrained-output is required"
[[ -d "$paidf_root" ]] || fatal "paidf-anomalygen root not found: $paidf_root"
[[ "$model_sizes" =~ ^[A-Za-z0-9[:space:]]+$ ]] || fatal "--model-sizes contains unsupported characters"

mkdir -p "$pretrained_output/pretrained"
IFS=' ' read -r -a model_size_args <<< "$model_sizes"

printf '[INFO] Assembling pretrained bundle into %s\n' "$pretrained_output/pretrained"
cd "$paidf_root"

python -m scripts.download_checkpoints \
  --model_types text2image \
  --model_sizes "${model_size_args[@]}" >/tmp/download_checkpoints.log 2>&1 || {
  printf 'ERROR: scripts.download_checkpoints failed. Last 40 lines:\n' >&2
  tail -40 /tmp/download_checkpoints.log >&2 || true
  exit 1
}

container_checkpoint_dir="$paidf_root/checkpoints"
for item in NVDINOV2 nvidia google-t5 facebook sam2 Qwen; do
  if [[ -e "$container_checkpoint_dir/$item" ]]; then
    rm -rf "$pretrained_output/pretrained/$item"
    cp -R "$container_checkpoint_dir/$item" "$pretrained_output/pretrained/"
    printf '[INFO] Copied checkpoints/%s\n' "$item"
  else
    printf '[WARN] checkpoints/%s not found; continuing\n' "$item"
  fi
done

if command -v hf >/dev/null 2>&1; then
  mkdir -p "$pretrained_output/pretrained/nvidia/C-RADIO-V3"
  hf download nvidia/C-RADIOv3-B \
    model.safetensors \
    --local-dir "$pretrained_output/pretrained/nvidia/C-RADIO-V3"
else
  fatal "hf CLI is required to download nvidia/C-RADIOv3-B"
fi

file_count=$(find "$pretrained_output/pretrained" -type f | wc -l | tr -d ' ')
total_bytes=$(du -sk "$pretrained_output/pretrained" | awk '{print $1 * 1024}')
[[ "$file_count" -gt 0 ]] || fatal "no files found in $pretrained_output/pretrained"

for required_path in NVDINOV2 nvidia google-t5 facebook; do
  [[ -e "$pretrained_output/pretrained/$required_path" ]] || fatal "required pretrained subtree missing: $required_path"
done

{
  printf 'workflow=setup-pretrained\n'
  printf 'pretrained_output=%s\n' "$pretrained_output/pretrained"
  printf 'model_sizes=%s\n' "$model_sizes"
  printf 'file_count=%s\n' "$file_count"
  printf 'total_bytes=%s\n' "$total_bytes"
} >"$pretrained_output/artifact_manifest.txt"

printf '[INFO] models/pretrained file count: %s\n' "$file_count"
printf '[INFO] models/pretrained bytes: %s\n' "$total_bytes"
printf '[INFO] Artifact manifest: %s\n' "$pretrained_output/artifact_manifest.txt"
printf '[INFO] Setup complete from %s\n' "$REPO_ROOT"
