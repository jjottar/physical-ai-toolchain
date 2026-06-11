#!/usr/bin/env bash
# Shared validation helpers for DIG Azure ML pipeline stages
set -o errexit -o nounset -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATA_FACTORY_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
DIG_AML_ROOT="$DATA_FACTORY_ROOT/workflows/azureml/dig"
export OMNI_KIT_ALLOW_ROOT="${OMNI_KIT_ALLOW_ROOT:-1}"

fatal() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
info() { printf '[INFO] %s\n' "$*"; }

require_option_value() {
  local option_name="$1" option_value="${2:-}"

  [[ -n "$option_value" && "$option_value" != --* ]] || fatal "$option_name requires a value"
  echo "$option_value"
}

require_dir() {
  local path_value="$1" description="$2"

  [[ -d "$path_value" ]] || fatal "$description directory not found: $path_value"
}

require_file() {
  local path_value="$1" description="$2"

  [[ -f "$path_value" ]] || fatal "$description file not found: $path_value"
}

require_command() {
  local command_name="$1"

  command -v "$command_name" >/dev/null 2>&1 || fatal "$command_name is required"
}

ensure_yq() {
  if command -v yq >/dev/null 2>&1; then
    return 0
  fi
  if [[ -x /tmp/yq ]]; then
    export PATH="/tmp:$PATH"
    return 0
  fi

  if command -v curl >/dev/null 2>&1; then
    curl -fsSL https://github.com/mikefarah/yq/releases/download/v4.44.3/yq_linux_amd64 -o /tmp/yq
  elif command -v wget >/dev/null 2>&1; then
    wget -q https://github.com/mikefarah/yq/releases/download/v4.44.3/yq_linux_amd64 -O /tmp/yq
  else
    fatal "curl or wget is required to install yq"
  fi
  chmod +x /tmp/yq
  export PATH="/tmp:$PATH"
}

require_output_dir() {
  local path_value="$1"

  [[ -n "$path_value" ]] || fatal "--output-dir is required"
  mkdir -p "$path_value"
}

require_nonzero_file_count() {
  local root_dir="$1" find_pattern="$2" description="$3" count

  require_dir "$root_dir" "$description root"
  count=$(find "$root_dir" -path "$find_pattern" -type f 2>/dev/null | wc -l | tr -d '[:space:]')
  [[ "$count" =~ ^[0-9]+$ ]] || fatal "Unable to count $description files under $root_dir"
  [[ "$count" -gt 0 ]] || fatal "No $description files found under $root_dir"
  info "$description count: $count"
}

require_dev_shm_gb() {
  local min_gb="$1" available_gb

  [[ "$min_gb" =~ ^[0-9]+$ ]] || fatal "minimum /dev/shm value must be numeric"
  available_gb=$(df -B1G /dev/shm | awk 'NR == 2 {print $2}' | tr -d '[:space:]')
  [[ "$available_gb" =~ ^[0-9]+$ ]] || fatal "Unable to determine /dev/shm size"
  [[ "$available_gb" -ge "$min_gb" ]] || fatal "/dev/shm is ${available_gb}GiB; need at least ${min_gb}GiB"
  info "/dev/shm preflight passed: ${available_gb}GiB"
}

require_optix() {
  require_file /usr/share/nvidia/nvoptix.bin "NVIDIA OptiX denoiser"
}

require_paidf_root() {
  local path_value="$1" description="$2"

  require_dir "$path_value" "$description root"
}

run_with_timeout() {
  local timeout_seconds="$1" description="$2" exit_code

  shift 2
  [[ "$timeout_seconds" =~ ^[0-9]+$ && "$timeout_seconds" -gt 0 ]] || \
    fatal "$description timeout must be a positive integer"

  set +o errexit
  if command -v timeout >/dev/null 2>&1; then
    timeout --signal=TERM --kill-after=60s "$timeout_seconds" "$@"
    exit_code=$?
  else
    "$@" &
    command_pid=$!
    (
      sleep "$timeout_seconds"
      kill -TERM "$command_pid" 2>/dev/null || true
      sleep 60
      kill -KILL "$command_pid" 2>/dev/null || true
    ) &
    watchdog_pid=$!
    wait "$command_pid"
    exit_code=$?
    kill "$watchdog_pid" 2>/dev/null || true
    wait "$watchdog_pid" 2>/dev/null || true
  fi
  set -o errexit

  case "$exit_code" in
    0) return 0 ;;
    124|137|143) fatal "$description exceeded ${timeout_seconds}s timeout" ;;
    *) fatal "$description exited $exit_code" ;;
  esac
}

require_gpu_memory() {
  local required_gb="$1" num_gpus="$2" required_mb gpu_count gpu_index memory_mb
  local -a gpu_memory_mb

  [[ "$required_gb" =~ ^[0-9]+$ ]] || fatal "minimum GPU memory value must be numeric"
  [[ "$num_gpus" =~ ^[1-9][0-9]*$ ]] || fatal "GPU count must be a positive integer"
  [[ "$required_gb" -gt 0 ]] || return 0
  require_command nvidia-smi

  mapfile -t gpu_memory_mb < <(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits)
  gpu_count="${#gpu_memory_mb[@]}"
  [[ "$gpu_count" -ge "$num_gpus" ]] || fatal "Requested $num_gpus GPU(s), but only $gpu_count visible GPU(s) were found"

  required_mb=$((required_gb * 1024))
  for ((gpu_index = 0; gpu_index < num_gpus; gpu_index++)); do
    memory_mb="${gpu_memory_mb[$gpu_index]//[[:space:]]/}"
    [[ "$memory_mb" =~ ^[0-9]+$ ]] || fatal "Unable to parse GPU $gpu_index memory from nvidia-smi output"
    [[ "$memory_mb" -ge "$required_mb" ]] || \
      fatal "GPU $gpu_index has ${memory_mb} MiB memory; need at least ${required_gb} GiB"
  done
  info "GPU memory preflight passed: $gpu_count visible GPU(s), minimum ${required_gb}GiB"
}

find_pretrained_dir() {
  local root_dir="$1" pretrained_dir

  pretrained_dir=$(find "$root_dir" -maxdepth 4 -type d -name pretrained -print -quit 2>/dev/null || true)
  if [[ -n "$pretrained_dir" ]]; then
    echo "$pretrained_dir"
  else
    echo "$root_dir"
  fi
}

link_pretrained_tree() {
  local source_dir="$1" target_dir="$2" item item_name

  require_dir "$source_dir" "pretrained source"
  mkdir -p "$target_dir"
  for item in NVDINOV2 google-t5 facebook C-RADIOv2_B.pth sam2 Qwen; do
    if [[ -e "$source_dir/$item" ]]; then
      rm -rf "${target_dir:?}/$item"
      ln -s "$source_dir/$item" "$target_dir/$item"
    fi
  done

  if [[ -d "$source_dir/nvidia" ]]; then
    rm -rf "${target_dir:?}/nvidia"
    mkdir -p "$target_dir/nvidia"
    shopt -s nullglob
    for item in "$source_dir/nvidia"/*; do
      item_name="$(basename "$item")"
      ln -s "$item" "$target_dir/nvidia/$item_name"
    done
    shopt -u nullglob
  fi
}

wrap_anomaly_checkpoint() {
  local checkpoint_dataset="$1" checkpoint_step="$2" wrapper_dir="$3" anomalygen_root="$4" ag_config_path ag_config_dir
  local -a checkpoint_files

  ag_config_path=$(find "$checkpoint_dataset" -maxdepth 8 -name ag_config.yaml -type f -print -quit 2>/dev/null || true)
  [[ -n "$ag_config_path" ]] || fatal "ag_config.yaml not found in $checkpoint_dataset"
  ag_config_dir=$(dirname "$ag_config_path")

  rm -rf "$wrapper_dir"
  mkdir -p "$wrapper_dir/checkpoints/model"
  mapfile -t checkpoint_files < <(find "$checkpoint_dataset" -maxdepth 10 -path '*/checkpoints/model/iter_*.pt' -type f 2>/dev/null)
  if [[ ${#checkpoint_files[@]} -eq 0 ]]; then
    mapfile -t checkpoint_files < <(find "$ag_config_dir" -maxdepth 1 -name 'iter_*.pt' -type f 2>/dev/null)
  fi
  [[ ${#checkpoint_files[@]} -gt 0 ]] || fatal "no model iter_*.pt files found under $checkpoint_dataset"

  for checkpoint_file in "${checkpoint_files[@]}"; do
    ln -sf "$checkpoint_file" "$wrapper_dir/checkpoints/model/$(basename "$checkpoint_file")"
  done
  cp "$ag_config_path" "$wrapper_dir/ag_config.yaml"
  checkpoint_step=$(bash "$DIG_AML_ROOT/helpers/pick-best-step.sh" "$checkpoint_dataset" "$checkpoint_step")
  python3 "$anomalygen_root/scripts/utilities/validate_checkpoint.py" "$wrapper_dir" --step "$checkpoint_step" >&2
  echo "$checkpoint_step"
}

find_first_file() {
  local root_dir="$1" filename="$2"

  find "$root_dir" -name "$filename" -type f -print -quit 2>/dev/null || true
}

validate_image_edit_model() {
  local endpoint="$1" expected_model="$2" models_url response ready_timeout_seconds retry_interval_seconds start_time elapsed_seconds

  [[ "$expected_model" == "nvidia/Qwen-Image-Edit-NVPCB-OVSL2SL" ]] || \
    fatal "image-edit model must be nvidia/Qwen-Image-Edit-NVPCB-OVSL2SL"
  require_command curl

  ready_timeout_seconds="${IMAGE_EDIT_READY_TIMEOUT_SECONDS:-1800}"
  retry_interval_seconds="${IMAGE_EDIT_READY_INTERVAL_SECONDS:-30}"
  [[ "$ready_timeout_seconds" =~ ^[0-9]+$ && "$ready_timeout_seconds" -gt 0 ]] || \
    fatal "IMAGE_EDIT_READY_TIMEOUT_SECONDS must be a positive integer"
  [[ "$retry_interval_seconds" =~ ^[0-9]+$ && "$retry_interval_seconds" -gt 0 ]] || \
    fatal "IMAGE_EDIT_READY_INTERVAL_SECONDS must be a positive integer"

  models_url="${endpoint%/}"
  case "$models_url" in
    */v1/models) ;;
    */v1) models_url="$models_url/models" ;;
    *) models_url="$models_url/v1/models" ;;
  esac

  info "Waiting for image-edit endpoint model identity at $models_url"
  start_time=$(date +%s)
  while true; do
    response=$(curl --silent --show-error --fail --max-time 30 "$models_url" 2>/dev/null || true)
    if printf '%s' "$response" | grep -Fq "$expected_model"; then
      break
    fi

    elapsed_seconds=$(($(date +%s) - start_time))
    [[ "$elapsed_seconds" -lt "$ready_timeout_seconds" ]] || \
      fatal "image-edit endpoint did not advertise $expected_model within ${ready_timeout_seconds}s"
    info "image-edit endpoint not ready after ${elapsed_seconds}s; retrying in ${retry_interval_seconds}s"
    sleep "$retry_interval_seconds"
  done
  info "image-edit endpoint model identity verified: $expected_model"
}
