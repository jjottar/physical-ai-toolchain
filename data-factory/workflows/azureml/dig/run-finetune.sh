#!/usr/bin/env bash
# Run the DIG Finetune Only workflow inside an Azure ML job
set -o errexit -o nounset -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || (cd "$SCRIPT_DIR/../../.." && pwd))"

show_help() {
  cat << 'EOF'
Usage: run-finetune.sh [OPTIONS]

Train an AnomalyGen checkpoint from a DIG raw dataset and uploaded pretrained
model tree.

OPTIONS:
    --raw-dataset DIR             Downloaded datasets/<usecase>/raw input
    --pretrained-model DIR        Downloaded models/pretrained input
    --usecase-model DIR           Downloaded models/<usecase> input containing ag_config.yaml
    --output-dir DIR              Azure ML output folder for the finetuned checkpoint
    --name NAME                   Run name (default: finetune)
    --usecase NAME                DIG use case: pcb, metal_surface, glass (default: pcb)
    --num-gpus N                  Number of visible GPUs for training (default: 1)
    --min-gpu-memory-gb N         Minimum memory per visible GPU; 0 disables (default: 40)
    --max-iter N                  Override trainer.max_iter; 0 uses cookbook default (default: 0)
    --save-iter N                 Override checkpoint.save_iter; 0 uses cookbook default (default: 0)
    -h, --help                    Show this help message
EOF
}

fatal() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

require_option_value() {
  local option_name="$1" option_value="${2:-}"

  [[ -n "$option_value" && "$option_value" != --* ]] || fatal "$option_name requires a value"
  echo "$option_value"
}

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
      fatal "GPU $gpu_index has ${memory_mb} MiB memory; finetune requires at least ${required_gb} GiB per GPU"
    fi
  done

  printf '[INFO] GPU memory preflight passed: %s visible GPU(s), minimum %s GiB per requested GPU\n' \
    "$gpu_count" "$required_gb"
}

link_pretrained_tree() {
  local pretrained_dir="$1" checkpoint_root="$2" item item_name cosmos_source cosmos_target

  mkdir -p "$checkpoint_root"
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
      ln -s "$item" "$checkpoint_root/nvidia/$item_name"
    done
    shopt -u nullglob
  fi

  cosmos_source=$(find "$pretrained_dir" -path '*/Cosmos-Predict2-2B-Text2Image/model.pt' -type f | head -n 1 || true)
  cosmos_target="$checkpoint_root/nvidia/Cosmos-Predict2-2B-Text2Image/model.pt"
  [[ -n "$cosmos_source" || -e "$cosmos_target" ]] || fatal "Cosmos Predict2 2B model.pt not found in pretrained input"
}

select_best_step() {
  local checkpoint_root="$1" fallback_step="$2" valid_dir model_dir best latest_trained csv step padded avg

  valid_dir=$(find "$checkpoint_root" -maxdepth 8 -type d -name valid 2>/dev/null | head -n 1 || true)
  if [[ -n "$valid_dir" ]] && compgen -G "$valid_dir/*/valid_kpi.csv" >/dev/null; then
    model_dir=$(find "$checkpoint_root" -type d -path '*/checkpoints/model' -print -quit 2>/dev/null || true)
    best=$(
      for csv in "$valid_dir"/*/valid_kpi.csv; do
        step="$(basename "$(dirname "$csv")")"
        [[ "$step" == "0" ]] && continue
        if [[ -n "$model_dir" ]]; then
          padded="$(printf 'iter_%09d.pt' "$step")"
          [[ -f "$model_dir/$padded" ]] || continue
        fi
        avg="$(awk -F',' '$1=="nn_score"{print $NF}' "$csv")"
        [[ -n "$avg" ]] && printf '%s %s\n' "$avg" "$step"
      done | sort -gr | head -n 1 | awk '{print $2}'
    )
    if [[ -n "$best" ]]; then
      echo "$best"
      return 0
    fi
  fi

  latest_trained=$(find "$checkpoint_root" -path '*/checkpoints/model/iter_*.pt' -printf '%f\n' 2>/dev/null \
    | sed 's/iter_0*//; s/\.pt//' \
    | sort -gr \
    | head -n 1)
  if [[ -n "$latest_trained" ]]; then
    echo "$latest_trained"
    return 0
  fi

  echo "$fallback_step"
}

raw_dataset=""
pretrained_model=""
usecase_model=""
output_dir=""
run_name="finetune"
usecase="pcb"
num_gpus="1"
min_gpu_memory_gb="40"
max_iter_override="0"
save_iter_override="0"
paidf_root="${PAIDF_ANOMALYGEN_ROOT:-/workspace/paidf-anomalygen}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)                    show_help; exit 0 ;;
    --raw-dataset)                raw_dataset="$(require_option_value "$1" "${2:-}")"; shift 2 ;;
    --pretrained-model)           pretrained_model="$(require_option_value "$1" "${2:-}")"; shift 2 ;;
    --usecase-model)              usecase_model="$(require_option_value "$1" "${2:-}")"; shift 2 ;;
    --output-dir)                 output_dir="$(require_option_value "$1" "${2:-}")"; shift 2 ;;
    --name)                       run_name="$(require_option_value "$1" "${2:-}")"; shift 2 ;;
    --usecase)                    usecase="$(require_option_value "$1" "${2:-}")"; shift 2 ;;
    --num-gpus)                   num_gpus="$(require_option_value "$1" "${2:-}")"; shift 2 ;;
    --min-gpu-memory-gb)          min_gpu_memory_gb="$(require_option_value "$1" "${2:-}")"; shift 2 ;;
    --max-iter)                   max_iter_override="$(require_option_value "$1" "${2:-}")"; shift 2 ;;
    --save-iter)                  save_iter_override="$(require_option_value "$1" "${2:-}")"; shift 2 ;;
    *)                            fatal "Unknown option: $1" ;;
  esac
done

[[ -n "$raw_dataset" ]] || fatal "--raw-dataset is required"
[[ -n "$pretrained_model" ]] || fatal "--pretrained-model is required"
[[ -n "$usecase_model" ]] || fatal "--usecase-model is required"
[[ -n "$output_dir" ]] || fatal "--output-dir is required"
[[ -d "$paidf_root" ]] || fatal "paidf-anomalygen root not found: $paidf_root"
[[ "$num_gpus" =~ ^[1-9][0-9]*$ ]] || fatal "--num-gpus must be a positive integer"
[[ "$min_gpu_memory_gb" =~ ^[0-9]+$ ]] || fatal "--min-gpu-memory-gb must be a non-negative integer"
[[ "$max_iter_override" =~ ^[0-9]+$ ]] || fatal "--max-iter must be a non-negative integer"
[[ "$save_iter_override" =~ ^[0-9]+$ ]] || fatal "--save-iter must be a non-negative integer"

case "$usecase" in
  pcb|metal_surface|glass) ;;
  *) fatal "--usecase must be one of: pcb, metal_surface, glass" ;;
esac

shm_gb=$(df -B1G /dev/shm | awk 'NR==2 {print $2}')
[[ "$shm_gb" =~ ^[0-9]+$ ]] || fatal "Unable to parse /dev/shm size"
[[ "$shm_gb" -ge 16 ]] || fatal "/dev/shm is ${shm_gb}GiB; finetune requires at least 16 GiB"

validate_gpu_memory "$min_gpu_memory_gb"

scripts_dir="$paidf_root/scripts/utilities"
for required_script in prep_testcase.sh validate_dataset.py; do
  [[ -e "$scripts_dir/$required_script" ]] || fatal "$required_script missing from $scripts_dir"
done

pretrained_dir=$(find "$pretrained_model" -maxdepth 4 -type d -name pretrained | head -n 1 || true)
[[ -n "$pretrained_dir" ]] || pretrained_dir="$pretrained_model"
[[ -d "$pretrained_dir" ]] || fatal "pretrained tree not found in $pretrained_model"

ag_config_path=$(find "$usecase_model" -maxdepth 8 -name ag_config.yaml | head -n 1 || true)
[[ -n "$ag_config_path" ]] || fatal "ag_config.yaml not found in $usecase_model"

defect_spec=$(find "$raw_dataset" -maxdepth 3 -name defect_spec.jsonl | head -n 1 || true)
[[ -n "$defect_spec" ]] || fatal "defect_spec.jsonl not found in $raw_dataset"
dataset_dir="$(dirname "$defect_spec")"

mkdir -p "$output_dir"
cd "$paidf_root"
link_pretrained_tree "$pretrained_dir" "$paidf_root/checkpoints"

if ! command -v yq >/dev/null 2>&1; then
  if command -v wget >/dev/null 2>&1; then
    wget -q https://github.com/mikefarah/yq/releases/download/v4.44.3/yq_linux_amd64 -O /tmp/yq
    chmod +x /tmp/yq
    export PATH="/tmp:$PATH"
  else
    fatal "yq is required to render the training config, and wget is not available to install it"
  fi
fi

printf '[INFO] Validating raw dataset: %s\n' "$dataset_dir"
python3 "$scripts_dir/validate_dataset.py" "$dataset_dir"

num_sdg=$(find "$dataset_dir" -type f -path '*/mask/*/*' \( -name '*.png' -o -name '*.jpg' -o -name '*.jpeg' \) | wc -l | tr -d ' ')
[[ "$num_sdg" -gt 0 ]] || fatal "no training masks found under $dataset_dir/*/mask"

validation_dir=/tmp/validation
rm -rf "$validation_dir"
mkdir -p "$validation_dir/amp"
validation_jsonl="$validation_dir/validation.jsonl"

bash "$scripts_dir/prep_testcase.sh" \
  --name "validation_${run_name}" \
  --num-sdg "$num_sdg" \
  --dataset-dir "$dataset_dir" \
  --defect-spec "$defect_spec" \
  --amp-output-dir "$validation_dir/amp" \
  --output-jsonl "$validation_jsonl"

[[ -s "$validation_jsonl" ]] || fatal "prep_testcase.sh produced an empty validation.jsonl"
validation_rows=$(wc -l <"$validation_jsonl" | tr -d ' ')
validation_amp_files=$(find "$validation_dir/amp" -type f | wc -l | tr -d ' ')

config_file=/tmp/ag_config.yaml
NAME="$run_name" \
JOB_NAME="${run_name}_training_FP32_lr0.02_bs=2_2b_512x512" \
DATASET_DIR="$dataset_dir" \
VAL_JSONL="$validation_jsonl" \
NVDINOV2_CKPT="checkpoints/NVDINOV2/nv_dinov2_classification_model.ckpt" \
yq '
  .job.group = strenv(NAME) |
  .job.name = strenv(JOB_NAME) |
  .dataloader_train.dataset.dataset_dir = strenv(DATASET_DIR) |
  .dataloader_val.dataset.input_data_path = strenv(VAL_JSONL) |
  .model.config.ag_config.mask_encoder.encoder_config.init_cfg.checkpoint = strenv(NVDINOV2_CKPT) |
  del(.trainer.early_stop)
' "$ag_config_path" >"$config_file"

if [[ "$max_iter_override" -gt 0 ]]; then
  MAX_ITER="$max_iter_override" yq -i '.trainer.max_iter = env(MAX_ITER)' "$config_file"
fi
if [[ "$save_iter_override" -gt 0 ]]; then
  SAVE_ITER="$save_iter_override" yq -i '.checkpoint.save_iter = env(SAVE_ITER)' "$config_file"
fi

max_iter=$(yq '.trainer.max_iter // 0' "$config_file")
save_iter=$(yq '.checkpoint.save_iter // 0' "$config_file")
if [[ "$save_iter" -gt 0 && "$max_iter" -gt 0 && "$save_iter" -gt "$max_iter" ]]; then
  fatal "cookbook save_iter=$save_iter exceeds max_iter=$max_iter; no checkpoint would be saved"
fi

mkdir -p ag_configs
cp "$config_file" "ag_configs/${run_name}.yaml"
cp "$config_file" "$output_dir/ag_config.yaml"
cp "$validation_jsonl" "$output_dir/validation.jsonl"

export IMAGINAIRE_OUTPUT_ROOT="$output_dir/results"
export PYTORCH_CUDA_ALLOC_CONF="${PYTORCH_CUDA_ALLOC_CONF:-expandable_segments:True}"
mkdir -p "$IMAGINAIRE_OUTPUT_ROOT"
printf '[INFO] Starting torchrun for %s with %s GPU(s)\n' "$run_name" "$num_gpus"
torchrun --nproc_per_node="$num_gpus" --master_port=12341 \
  -m scripts.anomaly_gen.ag_train \
  --config=cosmos_predict2/configs/base/ag_config.py \
  --ag_config="ag_configs/${run_name}.yaml" \
  -- experiment="predict2_anomaly_gen_ddp_2b"

checkpoint_count=$(find "$output_dir" -path '*/checkpoints/model/iter_*.pt' -type f | wc -l | tr -d ' ')
[[ "$checkpoint_count" -gt 0 ]] || fatal "training completed but no iter_*.pt checkpoint files were found in $output_dir"

best_step=$(select_best_step "$output_dir" "$save_iter")
printf '%s\n' "$best_step" >"$output_dir/best_step.txt"

{
  printf 'workflow=finetune\n'
  printf 'run_name=%s\n' "$run_name"
  printf 'usecase=%s\n' "$usecase"
  printf 'dataset_dir=%s\n' "$dataset_dir"
  printf 'validation_rows=%s\n' "$validation_rows"
  printf 'validation_amp_files=%s\n' "$validation_amp_files"
  printf 'max_iter=%s\n' "$max_iter"
  printf 'save_iter=%s\n' "$save_iter"
  printf 'checkpoint_count=%s\n' "$checkpoint_count"
  printf 'best_step=%s\n' "$best_step"
} >"$output_dir/artifact_manifest.txt"

printf '[INFO] validation.jsonl rows: %s\n' "$validation_rows"
printf '[INFO] validation amp files: %s\n' "$validation_amp_files"
printf '[INFO] checkpoint count: %s\n' "$checkpoint_count"
printf '[INFO] best step: %s\n' "$best_step"
printf '[INFO] Artifact manifest: %s\n' "$output_dir/artifact_manifest.txt"
printf '[INFO] Finetune complete from %s\n' "$REPO_ROOT"
