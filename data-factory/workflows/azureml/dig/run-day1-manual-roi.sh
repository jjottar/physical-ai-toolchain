#!/usr/bin/env bash
# Run DIG Day 1 manual ROI inference inside an Azure ML job
set -o errexit -o nounset -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || (cd "$SCRIPT_DIR/../../.." && pwd))"

show_help() {
  cat << 'EOF'
Usage: run-day1-manual-roi.sh [OPTIONS]

Run DIG Day 1 manual ROI inference in supported pretrained checkpoint mode.

OPTIONS:
    --raw-dataset DIR                 Downloaded datasets/<usecase>/raw input
    --pretrained-model DIR            Downloaded models/pretrained input
    --cosmos-cache DIR                Optional downloaded Cosmos model cache input
    --usecase-model DIR               Downloaded models/<usecase> checkpoint input
    --output-dir DIR                  Azure ML output folder
    --name NAME                       Run name (default: texture_defect_gen_day1_manual_roi)
    --usecase NAME                    DIG use case: metal_surface, glass, pcb (default: metal_surface)
    --use-pretrained-checkpoint BOOL  Pretrained mode flag; false is not supported in this runner
    --checkpoint-step STEP            Checkpoint iteration step (default: 10000)
    --anomaly-types-json JSON         Defect taxonomy JSON
    --num-sdg N                       Number of SDG entries (default: 30)
    --default-spatial-dependency MODE Fallback dependency: free, text, cad (default: free)
    --model-size SIZE                 Model size: 2b or 14b (default: 2b)
    --num-gpus N                      Number of visible GPUs for inference (default: 1)
    --min-gpu-memory-gb N             Minimum required memory per visible GPU; 0 disables (default: 40)
    -h, --help                        Show this help message
EOF
}

fatal() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

require_option_value() {
  local option_name="$1" option_value="${2:-}"

  [[ -n "$option_value" && "$option_value" != --* ]] || fatal "$option_name requires a value"
  echo "$option_value"
}

raw_dataset=""
pretrained_model=""
cosmos_cache=""
usecase_model=""
output_dir=""
run_name="texture_defect_gen_day1_manual_roi"
usecase="metal_surface"
checkpoint_step="10000"
anomaly_types_json='[["metal_surface","MT_Blowhole"],["metal_surface","MT_Break"],["metal_surface","MT_Crack"],["metal_surface","MT_Fray"],["metal_surface","MT_Uneven"]]'
use_pretrained_checkpoint="true"
num_sdg="30"
default_spatial_dependency="free"
model_size="2b"
num_gpus="1"
min_gpu_memory_gb="40"
paidf_root="${PAIDF_ANOMALYGEN_ROOT:-/workspace/paidf-anomalygen}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)                         show_help; exit 0 ;;
    --raw-dataset)                     raw_dataset="$(require_option_value "$1" "${2:-}")"; shift 2 ;;
    --pretrained-model)                pretrained_model="$(require_option_value "$1" "${2:-}")"; shift 2 ;;
    --cosmos-cache)                    cosmos_cache="$(require_option_value "$1" "${2:-}")"; shift 2 ;;
    --usecase-model)                   usecase_model="$(require_option_value "$1" "${2:-}")"; shift 2 ;;
    --output-dir)                      output_dir="$(require_option_value "$1" "${2:-}")"; shift 2 ;;
    --name)                            run_name="$(require_option_value "$1" "${2:-}")"; shift 2 ;;
    --usecase)                         usecase="$(require_option_value "$1" "${2:-}")"; shift 2 ;;
    --use-pretrained-checkpoint)       use_pretrained_checkpoint="$(require_option_value "$1" "${2:-}")"; shift 2 ;;
    --checkpoint-step)                 checkpoint_step="$(require_option_value "$1" "${2:-}")"; shift 2 ;;
    --anomaly-types-json)              anomaly_types_json="$(require_option_value "$1" "${2:-}")"; shift 2 ;;
    --num-sdg)                         num_sdg="$(require_option_value "$1" "${2:-}")"; shift 2 ;;
    --default-spatial-dependency)      default_spatial_dependency="$(require_option_value "$1" "${2:-}")"; shift 2 ;;
    --model-size)                      model_size="$(require_option_value "$1" "${2:-}")"; shift 2 ;;
    --num-gpus)                        num_gpus="$(require_option_value "$1" "${2:-}")"; shift 2 ;;
    --min-gpu-memory-gb)               min_gpu_memory_gb="$(require_option_value "$1" "${2:-}")"; shift 2 ;;
    *)                                 fatal "Unknown option: $1" ;;
  esac
done

[[ -n "$raw_dataset" ]] || fatal "--raw-dataset is required"
[[ -n "$pretrained_model" ]] || fatal "--pretrained-model is required"
[[ -n "$usecase_model" ]] || fatal "--usecase-model is required"
[[ -n "$output_dir" ]] || fatal "--output-dir is required"
[[ -d "$paidf_root" ]] || fatal "paidf-anomalygen root not found: $paidf_root"

case "$usecase" in
  metal_surface|glass|pcb) ;;
  *) fatal "--usecase must be one of: metal_surface, glass, pcb" ;;
esac

use_pretrained_checkpoint_normalized="$(printf '%s' "$use_pretrained_checkpoint" | tr '[:upper:]' '[:lower:]')"
case "$use_pretrained_checkpoint_normalized" in
  true|1|yes) ;;
  false|0|no)
    fatal "Day 1 manual ROI inline finetune is not supported by this Phase 8 AML runner; run the finetune workflow first and use a staged checkpoint for inference"
    ;;
  *) fatal "--use-pretrained-checkpoint must be true or false" ;;
esac

case "$default_spatial_dependency" in
  free|text|cad) ;;
  *) fatal "--default-spatial-dependency must be one of: free, text, cad" ;;
esac

case "$model_size" in
  2b|14b) ;;
  *) fatal "--model-size must be one of: 2b, 14b" ;;
esac

[[ "$num_gpus" =~ ^[1-9][0-9]*$ ]] || fatal "--num-gpus must be a positive integer"
[[ "$min_gpu_memory_gb" =~ ^[0-9]+$ ]] || fatal "--min-gpu-memory-gb must be a non-negative integer"

validate_gpu_memory() {
  local required_gb="$1" required_mb gpu_count gpu_index memory_mb
  local -a gpu_memory_mb

  [[ "$required_gb" -gt 0 ]] || return 0
  command -v nvidia-smi >/dev/null 2>&1 || fatal "nvidia-smi is required for GPU memory preflight"

  mapfile -t gpu_memory_mb < <(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits)
  gpu_count="${#gpu_memory_mb[@]}"
  [[ "$gpu_count" -ge "$num_gpus" ]] || fatal "Requested $num_gpus GPU(s), but only $gpu_count visible GPU(s) were found"

  required_mb=$((required_gb * 1024))
  for ((gpu_index = 0; gpu_index < num_gpus; gpu_index++)); do
    memory_mb="${gpu_memory_mb[$gpu_index]//[[:space:]]/}"
    [[ "$memory_mb" =~ ^[0-9]+$ ]] || fatal "Unable to parse GPU $gpu_index memory from nvidia-smi output"
    if [[ "$memory_mb" -lt "$required_mb" ]]; then
      fatal "GPU $gpu_index has ${memory_mb} MiB memory; Day 1 requires at least ${required_gb} GiB per GPU"
    fi
  done

  printf '[INFO] GPU memory preflight passed: %s visible GPU(s), minimum %s GiB per requested GPU\n' \
    "$gpu_count" "$required_gb"
}

python3 -c 'import json, sys; json.loads(sys.argv[1])' "$anomaly_types_json"

scripts_dir="$paidf_root/scripts/utilities"
for required_script in prep_testcase.sh validate_checkpoint.py validate_jsonl.py run_sdg.sh verify_output.sh; do
  [[ -e "$scripts_dir/$required_script" ]] || fatal "$required_script missing from $scripts_dir"
done

mkdir -p "$output_dir"
cd "$paidf_root"

checkpoint_root=/workspace/paidf-anomalygen/checkpoints
mkdir -p "$checkpoint_root"
pretrained_dir=$(find "$pretrained_model" -maxdepth 4 -type d -name pretrained | head -n 1 || true)
[[ -n "$pretrained_dir" ]] || pretrained_dir="$pretrained_model"

link_cosmos_predict2_layout() {
  local source_dir="$1" target_dir="$2" child child_name

  [[ -d "$source_dir" ]] || return 0
  mkdir -p "$target_dir"

  shopt -s nullglob
  for child in "$source_dir"/*; do
    child_name="$(basename "$child")"
    if [[ ! -e "$target_dir/$child_name" ]]; then
      ln -s "$child" "$target_dir/$child_name"
    fi
  done
  shopt -u nullglob

  if [[ -e "$source_dir/tokenizer.pth" && ! -e "$target_dir/tokenizer/tokenizer.pth" ]]; then
    mkdir -p "$target_dir/tokenizer"
    ln -s "$source_dir/tokenizer.pth" "$target_dir/tokenizer/tokenizer.pth"
  fi

  if [[ -e "$source_dir/model.pt" && ! -e "$target_dir/model.pt" ]]; then
    ln -s "$source_dir/model.pt" "$target_dir/model.pt"
  fi
}

ensure_cosmos_predict2_model() {
  local target_dir="$1" download_dir

  if [[ -e "$target_dir/model.pt" ]]; then
    return 0
  fi

  command -v hf >/dev/null 2>&1 || fatal "hf CLI is required to download missing Cosmos Predict2 model.pt"
  [[ -n "${HF_TOKEN:-}" ]] || fatal "HF_TOKEN is required to download missing Cosmos Predict2 model.pt"

  download_dir=/tmp/cosmos-predict2-2b-text2image
  rm -rf "$download_dir"
  mkdir -p "$download_dir"
  hf download nvidia/Cosmos-Predict2-2B-Text2Image \
    model.pt tokenizer/tokenizer.pth \
    --local-dir "$download_dir" \
    --token "$HF_TOKEN" || \
    fatal "Unable to download nvidia/Cosmos-Predict2-2B-Text2Image/model.pt; grant the HF token access to this gated repository"

  mkdir -p "$target_dir/tokenizer"
  ln -sf "$download_dir/model.pt" "$target_dir/model.pt"
  ln -sf "$download_dir/tokenizer/tokenizer.pth" "$target_dir/tokenizer/tokenizer.pth"
}

for item in NVDINOV2 google-t5 facebook C-RADIOv2_B.pth sam2 Qwen; do
  if [[ -e "$pretrained_dir/$item" ]]; then
    rm -rf "${checkpoint_root:?}/$item"
    ln -s "$pretrained_dir/$item" "$checkpoint_root/$item"
  fi
done

if [[ -d "$pretrained_dir/nvidia" ]]; then
  rm -rf "${checkpoint_root:?}/nvidia"
  mkdir -p "$checkpoint_root/nvidia"
  shopt -s nullglob
  for item in "$pretrained_dir/nvidia"/*; do
    item_name="$(basename "$item")"
    if [[ "$item_name" == "Cosmos-Predict2-2B-Text2Image" ]]; then
      link_cosmos_predict2_layout "$item" "$checkpoint_root/nvidia/$item_name"
    else
      ln -s "$item" "$checkpoint_root/nvidia/$item_name"
    fi
  done
  shopt -u nullglob
fi

if [[ -n "$cosmos_cache" ]]; then
  cosmos_snapshot=$(find "$cosmos_cache" -path '*/models--nvidia--Cosmos-Predict2.5-2B/snapshots/*/tokenizer.pth' -type f | head -n 1 || true)
  if [[ -z "$cosmos_snapshot" ]]; then
    cosmos_snapshot=$(find "$cosmos_cache" -maxdepth 4 -name tokenizer.pth -type f | head -n 1 || true)
  fi
  if [[ -n "$cosmos_snapshot" ]]; then
    cosmos_snapshot_dir=$(dirname "$cosmos_snapshot")
    cosmos_target="$checkpoint_root/nvidia/Cosmos-Predict2-2B-Text2Image"
    link_cosmos_predict2_layout "$cosmos_snapshot_dir" "$cosmos_target"
    printf '[INFO] Cosmos cache linked from %s\n' "$cosmos_snapshot_dir"
  fi
fi

ensure_cosmos_predict2_model "$checkpoint_root/nvidia/Cosmos-Predict2-2B-Text2Image"
[[ -e "$checkpoint_root/nvidia/Cosmos-Predict2-2B-Text2Image/model.pt" ]] || \
  fatal "Cosmos Predict2 model.pt could not be linked or downloaded"

ag_config_path=$(find "$usecase_model" -maxdepth 8 -name ag_config.yaml | head -n 1 || true)
[[ -n "$ag_config_path" ]] || fatal "ag_config.yaml not found in $usecase_model"
ag_config_dir=$(dirname "$ag_config_path")

wrapper=/tmp/ag_ckpt_wrapper
rm -rf "$wrapper"
mkdir -p "$wrapper/checkpoints/model"

mapfile -t checkpoint_files < <(find "$usecase_model" -maxdepth 10 -path '*/checkpoints/model/iter_*.pt' -type f)
if [[ ${#checkpoint_files[@]} -eq 0 ]]; then
  mapfile -t checkpoint_files < <(find "$ag_config_dir" -maxdepth 1 -name 'iter_*.pt' -type f)
fi
[[ ${#checkpoint_files[@]} -gt 0 ]] || fatal "no iter_*.pt files found in $usecase_model"

for checkpoint_file in "${checkpoint_files[@]}"; do
  ln -sf "$checkpoint_file" "$wrapper/checkpoints/model/$(basename "$checkpoint_file")"
done
cp "$ag_config_path" "$wrapper/ag_config.yaml"

python3 "$scripts_dir/validate_checkpoint.py" "$wrapper" --step "$checkpoint_step"

defect_spec=$(find "$raw_dataset" -maxdepth 3 -name defect_spec.jsonl | head -n 1 || true)
[[ -n "$defect_spec" ]] || fatal "defect_spec.jsonl not found in $raw_dataset; flat upload mode is not staged by this runner"

dataset_dir=$(dirname "$defect_spec")
amp_output=/tmp/amp_output
jsonl=/tmp/inference.jsonl
sdg_output="$output_dir/inference"
mkdir -p "$amp_output" "$sdg_output"

printf '[INFO] Prepared dataset: %s\n' "$dataset_dir"
printf '[INFO] Use case: %s\n' "$usecase"
printf '[INFO] Checkpoint step: %s\n' "$checkpoint_step"
printf '[INFO] Spatial dependency fallback: %s\n' "$default_spatial_dependency"
printf '[INFO] Anomaly taxonomy: %s\n' "$anomaly_types_json"
printf '[INFO] Minimum GPU memory: %s GiB\n' "$min_gpu_memory_gb"

bash "$scripts_dir/prep_testcase.sh" \
  --name "${run_name}_infer" \
  --num-sdg "$num_sdg" \
  --dataset-dir "$dataset_dir" \
  --defect-spec "$defect_spec" \
  --amp-output-dir "$amp_output" \
  --output-jsonl "$jsonl"

python3 "$scripts_dir/validate_jsonl.py" "$wrapper" "$jsonl"

export IMAGINAIRE_OUTPUT_ROOT="${sdg_output}/results"
export PYTORCH_CUDA_ALLOC_CONF="${PYTORCH_CUDA_ALLOC_CONF:-expandable_segments:True}"
mkdir -p "$IMAGINAIRE_OUTPUT_ROOT"

validate_gpu_memory "$min_gpu_memory_gb"
printf '[INFO] PyTorch CUDA allocator: %s\n' "$PYTORCH_CUDA_ALLOC_CONF"

bash "$scripts_dir/run_sdg.sh" \
  --checkpoint_dir "$wrapper" \
  --step "$checkpoint_step" \
  --input_jsonl "$jsonl" \
  --output_dir "$sdg_output" \
  --model_size "$model_size" \
  --num_gpus "$num_gpus" \
  --seed 0

bash "$scripts_dir/verify_output.sh" "$jsonl" "$sdg_output"
output_file_count=$(find "$output_dir" -type f | wc -l | tr -d ' ')
[[ "$output_file_count" -gt 0 ]] || fatal "no output files found in $output_dir"
{
  printf 'workflow=day1-manual-roi\n'
  printf 'run_name=%s\n' "$run_name"
  printf 'usecase=%s\n' "$usecase"
  printf 'checkpoint_step=%s\n' "$checkpoint_step"
  printf 'output_file_count=%s\n' "$output_file_count"
  printf 'sdg_output=%s\n' "$sdg_output"
} >"$output_dir/artifact_manifest.txt"
printf '[INFO] Inference complete: %s\n' "$sdg_output"
printf '[INFO] Output file count: %s\n' "$output_file_count"
printf '[INFO] Artifact manifest: %s\n' "$output_dir/artifact_manifest.txt"
printf '[INFO] Azure ML snapshot root: %s\n' "$REPO_ROOT"
