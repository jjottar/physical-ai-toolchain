#!/usr/bin/env bash
# Validate and run the structural defect simulation stage
set -o errexit -o nounset -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=stage-common.sh
source "$SCRIPT_DIR/stage-common.sh"

show_help() {
  cat << 'EOF'
Usage: run-structural-render.sh [OPTIONS]

OPTIONS:
    --pcb-assets DIR        Downloaded datasets/pcb/assets input
    --output-dir DIR        Stage output folder
    --board NAME            Cookbook board name
    --scene-filename NAME   Scene USD basename
    --render-patches N      Render patch cap; -1 means full coverage
    --defect-modes MODES    all or comma-separated shift,tombstone,sideflip
    --crop-offset N         Crop padding in pixels
    -h, --help              Show this help message
EOF
}

pcb_assets=""
output_dir=""
board="0603_H100"
scene_filename="spark_lighting.usd"
render_patches="5"
defect_modes="all"
crop_offset="10"
paidf_root="${PAIDF_SIMULATION_ROOT:-/workspace/paidf-simulation}"
kit_timeout_seconds="${DIG_AML_KIT_TIMEOUT_SECONDS:-1200}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)          show_help; exit 0 ;;
    --pcb-assets)       pcb_assets="$(require_option_value "$1" "${2:-}")"; shift 2 ;;
    --output-dir)       output_dir="$(require_option_value "$1" "${2:-}")"; shift 2 ;;
    --board)            board="$(require_option_value "$1" "${2:-}")"; shift 2 ;;
    --scene-filename)   scene_filename="$(require_option_value "$1" "${2:-}")"; shift 2 ;;
    --render-patches)   render_patches="$(require_option_value "$1" "${2:-}")"; shift 2 ;;
    --defect-modes)     defect_modes="$(require_option_value "$1" "${2:-}")"; shift 2 ;;
    --crop-offset)      crop_offset="$(require_option_value "$1" "${2:-}")"; shift 2 ;;
    *)                  fatal "Unknown option: $1" ;;
  esac
done

require_dir "$pcb_assets" "PCBA assets"
require_output_dir "$output_dir"
require_optix
require_dev_shm_gb 16
require_paidf_root "$paidf_root" "paidf-simulation"
require_file "$paidf_root/scripts/sdg/standalone/sdg_pipeline.py" "sdg_pipeline.py"
require_file "$paidf_root/scripts/postprocess/crop_components.py" "crop_components.py"
[[ -n "$(find_first_file "$pcb_assets" "$scene_filename")" ]] || \
  fatal "scene_filename=$scene_filename not found under $pcb_assets"
[[ "$render_patches" =~ ^-?[0-9]+$ ]] || fatal "--render-patches must be an integer"
[[ "$crop_offset" =~ ^[0-9]+$ ]] || fatal "--crop-offset must be a non-negative integer"
case ",$defect_modes," in
  ,all,|*,shift,*|*,tombstone,*|*,sideflip,*) ;;
  *) fatal "--defect-modes must be all or a comma-separated subset of shift,tombstone,sideflip" ;;
esac
ensure_yq

cookbook_dir="$DIG_AML_ROOT/cookbooks/pcb/$board"
require_file "$cookbook_dir/pcba_target.yaml" "PCBA target cookbook"
require_file "$cookbook_dir/defect_image.yaml" "structural defect cookbook"

scene_usd="$(find_first_file "$pcb_assets" "$scene_filename")"
work_output=/tmp/structural_render_output
rm -rf "$work_output"
mkdir -p "$work_output"

pcba_patched=/tmp/pcba_target_patched.yaml
render_yaml=/tmp/structural_render_resolved.yaml
cp "$cookbook_dir/pcba_target.yaml" "$pcba_patched"
cp "$cookbook_dir/defect_image.yaml" "$render_yaml"

SCENE_USD="$scene_usd" yq -i '.scene = strenv(SCENE_USD)' "$pcba_patched"
OUT="$work_output" MAX_IMAGE_COUNT="$render_patches" yq -i '
  .output = strenv(OUT) |
  .max_image_count = (strenv(MAX_IMAGE_COUNT) | tonumber)
' "$render_yaml"

if [[ "$defect_modes" != "all" ]]; then
  all_modes=(shift tombstone sideflip)
  for mode in "${all_modes[@]}"; do
    if [[ ",$defect_modes," == *",$mode,"* ]]; then
      MODE="$mode" yq -i '.defects[strenv(MODE)].enabled = true' "$render_yaml"
    else
      MODE="$mode" yq -i '.defects[strenv(MODE)].enabled = false' "$render_yaml"
    fi
  done
fi

cp "$pcba_patched" "$work_output/pcba_target.yaml"
cp "$render_yaml" "$work_output/render_config.yaml"

info "Running structural defect render: $scene_usd"
run_with_timeout "$kit_timeout_seconds" "structural defect render" \
  /isaac-sim/kit/kit /isaac-sim/apps/isaacsim.exp.base.kit \
  --no-window --exec \
  "$paidf_root/scripts/sdg/standalone/sdg_pipeline.py --config $render_yaml --pcba-config $pcba_patched"

frame_count=$(find "$work_output" -path '*/trigger_*/rgb_*.png' -type f 2>/dev/null | wc -l | tr -d '[:space:]')
[[ "$frame_count" =~ ^[0-9]+$ && "$frame_count" -gt 0 ]] || fatal "structural render produced no RGB frames under $work_output"

python3 "$paidf_root/scripts/postprocess/crop_components.py" \
  --input "$work_output/trigger_0000" \
  --output "$work_output/cropped" \
  --crops rgb semantic_segmentation component_instance \
  --offset "$crop_offset"

crop_count=$(find "$work_output/cropped" -mindepth 2 -path '*/rgb/*.png' -type f 2>/dev/null | wc -l | tr -d '[:space:]')
[[ "$crop_count" =~ ^[0-9]+$ && "$crop_count" -gt 0 ]] || fatal "structural crop emitted no per-mode RGB crops"
cp -r "$work_output"/. "$output_dir"/
{
  printf 'workflow=day0-structural-render\n'
  printf 'board=%s\n' "$board"
  printf 'scene_filename=%s\n' "$scene_filename"
  printf 'defect_modes=%s\n' "$defect_modes"
  printf 'frame_count=%s\n' "$frame_count"
  printf 'crop_count=%s\n' "$crop_count"
} >"$output_dir/artifact_manifest.txt"

info "Structural render complete: $frame_count frame(s), $crop_count crop(s)"
