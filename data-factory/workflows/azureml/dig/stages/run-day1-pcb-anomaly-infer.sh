#!/usr/bin/env bash
# Validate and run the Day 1 PCBA AnomalyGen inference stage
set -o errexit -o nounset -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=stage-common.sh
source "$SCRIPT_DIR/stage-common.sh"

show_help() {
  cat << 'EOF'
Usage: run-day1-pcb-anomaly-infer.sh [OPTIONS]

OPTIONS:
    --raw-dataset DIR              Downloaded datasets/pcb/raw input
    --pretrained-model DIR         Downloaded models/pretrained input
    --usecase-model DIR            Downloaded models/pcb checkpoint input
    --aligned-rois DIR             Day 1 real-photo alignment output
    --output-dir DIR               Final anomaly output folder
    --name NAME                    Run name
    --checkpoint-step STEP         Checkpoint iteration step
    --anomaly-types-json JSON      Defect taxonomy JSON
    --num-sdg N                    Number of SDG entries
    --default-spatial-dependency MODE
    --min-gpu-memory-gb N          Minimum GPU memory preflight
    -h, --help                     Show this help message
EOF
}

raw_dataset=""
pretrained_model=""
usecase_model=""
aligned_rois=""
output_dir=""
run_name="texture_defect_gen_day1_real_alignment"
checkpoint_step="14000"
anomaly_types_json='[["passive_component","excess_solder"],["passive_component","missing"]]'
num_sdg="30"
default_spatial_dependency="cad"
min_gpu_memory_gb="40"
model_size="2b"
num_gpus="1"
paidf_root="${PAIDF_ANOMALYGEN_ROOT:-/workspace/paidf-anomalygen}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)                     show_help; exit 0 ;;
    --raw-dataset)                 raw_dataset="$(require_option_value "$1" "${2:-}")"; shift 2 ;;
    --pretrained-model)            pretrained_model="$(require_option_value "$1" "${2:-}")"; shift 2 ;;
    --usecase-model)               usecase_model="$(require_option_value "$1" "${2:-}")"; shift 2 ;;
    --aligned-rois)                aligned_rois="$(require_option_value "$1" "${2:-}")"; shift 2 ;;
    --output-dir)                  output_dir="$(require_option_value "$1" "${2:-}")"; shift 2 ;;
    --name)                        run_name="$(require_option_value "$1" "${2:-}")"; shift 2 ;;
    --checkpoint-step)             checkpoint_step="$(require_option_value "$1" "${2:-}")"; shift 2 ;;
    --anomaly-types-json)          anomaly_types_json="$(require_option_value "$1" "${2:-}")"; shift 2 ;;
    --num-sdg)                     num_sdg="$(require_option_value "$1" "${2:-}")"; shift 2 ;;
    --default-spatial-dependency)  default_spatial_dependency="$(require_option_value "$1" "${2:-}")"; shift 2 ;;
    --min-gpu-memory-gb)           min_gpu_memory_gb="$(require_option_value "$1" "${2:-}")"; shift 2 ;;
    *)                             fatal "Unknown option: $1" ;;
  esac
done

require_dir "$raw_dataset" "raw dataset"
require_dir "$pretrained_model" "pretrained model"
require_dir "$usecase_model" "usecase model"
require_dir "$aligned_rois" "aligned ROI"
require_output_dir "$output_dir"
require_nonzero_file_count "$aligned_rois" '*/normal_img/*.png' "aligned ROI normal image"
python3 -c 'import json, sys; json.loads(sys.argv[1])' "$anomaly_types_json"
case "$default_spatial_dependency" in
  free|text|cad) ;;
  *) fatal "--default-spatial-dependency must be free, text, or cad" ;;
esac
[[ "$checkpoint_step" =~ ^[0-9]+$ ]] || fatal "--checkpoint-step must be numeric"
[[ "$num_sdg" =~ ^[0-9]+$ ]] || fatal "--num-sdg must be numeric"
[[ "$min_gpu_memory_gb" =~ ^[0-9]+$ ]] || fatal "--min-gpu-memory-gb must be numeric"
[[ -n "$run_name" ]] || fatal "--name is required"
require_paidf_root "$paidf_root" "paidf-anomalygen"
require_file "$paidf_root/scripts/utilities/run_sdg.sh" "run_sdg.sh"
require_file "$paidf_root/scripts/utilities/verify_output.sh" "verify_output.sh"
require_file "$DIG_AML_ROOT/helpers/render-defect-spec.py" "render-defect-spec.py"
require_file "$DIG_AML_ROOT/helpers/pick-best-step.sh" "pick-best-step.sh"

scripts_dir="$paidf_root/scripts/utilities"
for required_script in prep_testcase.sh validate_checkpoint.py validate_jsonl.py run_sdg.sh verify_output.sh; do
  require_file "$scripts_dir/$required_script" "$required_script"
done

cd "$paidf_root"
checkpoint_root="$paidf_root/checkpoints"
pretrained_dir="$(find_pretrained_dir "$pretrained_model")"
link_pretrained_tree "$pretrained_dir" "$checkpoint_root"

wrapper=/tmp/day1_real_alignment_ckpt_wrapper
checkpoint_step="$(wrap_anomaly_checkpoint "$usecase_model" "$checkpoint_step" "$wrapper" "$paidf_root")"

stage_dir=/tmp/day1_real_alignment_stage
rm -rf "$stage_dir"
mapfile -t disk_materials < <(find "$aligned_rois/crop" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; 2>/dev/null | sort)
[[ ${#disk_materials[@]} -gt 0 ]] || fatal "no material dirs under $aligned_rois/crop"

for material in "${disk_materials[@]}"; do
  mkdir -p "$stage_dir/$material/clean_image" "$stage_dir/$material/cad_mask" "$stage_dir/$material/mask"
done

mask_candidate_for() {
  local clean_path="$1" roi_dir stem candidate

  roi_dir="$(dirname "$(dirname "$clean_path")")"
  stem="$(basename "${clean_path%.*}")"
  for candidate in \
    "$roi_dir/cad_mask/${stem}_cad_mask.png" \
    "$roi_dir/cad_mask/${stem}.png" \
    "$roi_dir/seg/${stem}.png" \
    "$roi_dir/ov_seg/${stem}.png" \
    "$roi_dir/semantic_segmentation/${stem}.png"; do
    if [[ -f "$candidate" ]]; then
      echo "$candidate"
      return 0
    fi
  done
  echo ""
}

has_mask_files() {
  local dir="$1"

  find "$dir" -type f \( -iname '*.png' -o -iname '*.jpg' -o -iname '*.jpeg' \) -print -quit 2>/dev/null | grep -q .
}

find_submask_dir() {
  local root="$1" material="$2" defect="$3" candidate

  for candidate in "$root/$material/mask/$defect" "$root/$defect"; do
    if [[ -d "$candidate" ]] && has_mask_files "$candidate"; then
      echo "$candidate"
      return 0
    fi
  done

  while IFS= read -r candidate; do
    if has_mask_files "$candidate"; then
      echo "$candidate"
      return 0
    fi
  done < <(find "$root" -type d \( -path "*/$material/mask/$defect" -o -path "*/mask/$defect" -o -name "$defect" \) -print 2>/dev/null)

  echo ""
}

staged_count=0
for material in "${disk_materials[@]}"; do
  shopt -s nullglob
  for clean_image in "$aligned_rois/crop/$material/normal_img"/*.png "$aligned_rois/crop/$material/normal_img"/*.jpg; do
    image_stem="$(basename "${clean_image%.*}")"
    image_ext="${clean_image##*.}"
    mask_file="$(mask_candidate_for "$clean_image")"
    ln -sf "$clean_image" "$stage_dir/$material/clean_image/${image_stem}.${image_ext}"
    [[ -n "$mask_file" ]] && ln -sf "$mask_file" "$stage_dir/$material/cad_mask/${image_stem}.png"
    staged_count=$((staged_count + 1))
  done
  shopt -u nullglob
done
[[ "$staged_count" -gt 0 ]] || fatal "no aligned ROI crops staged"

submask_root="$raw_dataset"
if ! find "$submask_root" -mindepth 3 -maxdepth 3 -type d -path '*/mask/*' 2>/dev/null | head -1 | grep -q .; then
  nested_root=$(find "$raw_dataset" -mindepth 1 -maxdepth 1 -type d -print -quit 2>/dev/null || true)
  if [[ -n "$nested_root" ]] && find "$nested_root" -mindepth 3 -maxdepth 3 -type d -path '*/mask/*' 2>/dev/null | head -1 | grep -q .; then
    submask_root="$nested_root"
  fi
fi

while IFS=$'\t' read -r material defect; do
  [[ -n "$material" && -n "$defect" ]] || continue
  source_dir="$(find_submask_dir "$submask_root" "$material" "$defect")"
  [[ -n "$source_dir" ]] || fatal "submask files not found for $material+$defect under $submask_root"
  target_dir="$stage_dir/$material/mask/$defect"
  mkdir -p "$target_dir"
  while IFS= read -r mask_file; do
    cp -Lf "$mask_file" "$target_dir/$(basename "$mask_file")"
  done < <(find "$source_dir" -type f \( -iname '*.png' -o -iname '*.jpg' -o -iname '*.jpeg' \) -print 2>/dev/null)
  require_nonzero_file_count "$target_dir" '*' "submask $material+$defect"
done < <(python3 -c 'import json,sys
for material, defect in json.loads(sys.argv[1]): print(f"{material}\t{defect}")' "$anomaly_types_json")

python3 "$DIG_AML_ROOT/helpers/render-defect-spec.py" \
  --output "$stage_dir/defect_spec.jsonl" \
  --pairs "$anomaly_types_json" \
  --spatial-dependency "$default_spatial_dependency"

if [[ "$default_spatial_dependency" == "cad" ]]; then
  labels_file=$(find "$aligned_rois" -maxdepth 5 -name semantic_segmentation_labels.json -type f -print -quit 2>/dev/null || true)
  if [[ -n "$labels_file" ]]; then
    cp "$labels_file" "$stage_dir/semantic_segmentation_labels.json"
  else
    warn_message="spatial_dependency=cad but no semantic_segmentation_labels.json found under $aligned_rois"
    printf '[WARN] %s\n' "$warn_message"
  fi
fi

amp_output=/tmp/day1_real_alignment_amp
jsonl=/tmp/day1_real_alignment_inference.jsonl
sdg_output="$output_dir/inference"
mkdir -p "$amp_output" "$sdg_output"

bash "$scripts_dir/prep_testcase.sh" \
  --name "${run_name}_infer" \
  --num-sdg "$num_sdg" \
  --dataset-dir "$stage_dir" \
  --defect-spec "$stage_dir/defect_spec.jsonl" \
  --amp-output-dir "$amp_output" \
  --output-jsonl "$jsonl"
python3 "$scripts_dir/validate_jsonl.py" "$wrapper" "$jsonl"

export IMAGINAIRE_OUTPUT_ROOT="$sdg_output/results"
export PYTORCH_CUDA_ALLOC_CONF="${PYTORCH_CUDA_ALLOC_CONF:-expandable_segments:True}"
mkdir -p "$IMAGINAIRE_OUTPUT_ROOT"
require_gpu_memory "$min_gpu_memory_gb" "$num_gpus"

bash "$scripts_dir/run_sdg.sh" \
  --checkpoint_dir "$wrapper" \
  --step "$checkpoint_step" \
  --input_jsonl "$jsonl" \
  --output_dir "$sdg_output" \
  --model_size "$model_size" \
  --num_gpus "$num_gpus" \
  --seed 0
bash "$scripts_dir/verify_output.sh" "$jsonl" "$sdg_output"

output_file_count=$(find "$output_dir" -type f | wc -l | tr -d '[:space:]')
[[ "$output_file_count" -gt 0 ]] || fatal "no output files found in $output_dir"
{
  printf 'workflow=day1-real-photo-alignment\n'
  printf 'run_name=%s\n' "$run_name"
  printf 'checkpoint_step=%s\n' "$checkpoint_step"
  printf 'staged_roi_count=%s\n' "$staged_count"
  printf 'output_file_count=%s\n' "$output_file_count"
  printf 'sdg_output=%s\n' "$sdg_output"
} >"$output_dir/artifact_manifest.txt"
info "Day 1 real-photo AnomalyGen inference complete: $output_file_count file(s)"
