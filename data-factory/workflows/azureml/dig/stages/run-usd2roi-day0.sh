#!/usr/bin/env bash
# Validate and run the Day 0 usd2roi simulation stage
set -o errexit -o nounset -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=stage-common.sh
source "$SCRIPT_DIR/stage-common.sh"

show_help() {
  cat << 'EOF'
Usage: run-usd2roi-day0.sh [OPTIONS]

OPTIONS:
    --pcb-assets DIR        Downloaded datasets/pcb/assets input
    --output-dir DIR        Stage output folder
    --board NAME            Cookbook board name
    --scene-filename NAME   Scene USD basename
    --render-patches N      Render patch cap
    --crop-max-emit N       Optional final crop cap; use null for cookbook null
    -h, --help              Show this help message
EOF
}

pcb_assets=""
output_dir=""
board="0603_H100"
scene_filename="spark_lighting.usd"
render_patches="5"
crop_max_emit=""
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
    --crop-max-emit)    crop_max_emit="$(require_option_value "$1" "${2:-}")"; shift 2 ;;
    *)                  fatal "Unknown option: $1" ;;
  esac
done

require_dir "$pcb_assets" "PCBA assets"
require_output_dir "$output_dir"
require_optix
require_dev_shm_gb 16
require_paidf_root "$paidf_root" "paidf-simulation"
require_file "$paidf_root/scripts/sdg/standalone/sdg_pipeline.py" "sdg_pipeline.py"
require_file "$paidf_root/scripts/usd2roi/usd2roi_crop.py" "usd2roi_crop.py"
[[ -n "$(find_first_file "$pcb_assets" "$scene_filename")" ]] || \
  fatal "scene_filename=$scene_filename not found under $pcb_assets"
[[ "$render_patches" =~ ^-?[0-9]+$ ]] || fatal "--render-patches must be an integer"
[[ -z "$crop_max_emit" || "$crop_max_emit" == "null" || "$crop_max_emit" =~ ^[0-9]+$ ]] || \
  fatal "--crop-max-emit must be empty, null, or a non-negative integer"
ensure_yq

cookbook_dir="$DIG_AML_ROOT/cookbooks/pcb/$board"
require_file "$cookbook_dir/pcba_target.yaml" "PCBA target cookbook"
require_file "$cookbook_dir/day0_image.yaml" "Day 0 image cookbook"
require_file "$cookbook_dir/day0_crop.yaml" "Day 0 crop cookbook"

scene_usd="$(find_first_file "$pcb_assets" "$scene_filename")"
pcba_patched=/tmp/pcba_target_patched.yaml
sdg_yaml=/tmp/day0_image_resolved.yaml
crop_yaml=/tmp/day0_crop_resolved.yaml
cp "$cookbook_dir/pcba_target.yaml" "$pcba_patched"
cp "$cookbook_dir/day0_image.yaml" "$sdg_yaml"
cp "$cookbook_dir/day0_crop.yaml" "$crop_yaml"

SCENE_USD="$scene_usd" yq -i '.scene = strenv(SCENE_USD)' "$pcba_patched"
OUT="$output_dir" MAX_IMAGE_COUNT="$render_patches" yq -i '
  .output = strenv(OUT) |
  .max_image_count = (strenv(MAX_IMAGE_COUNT) | tonumber)
' "$sdg_yaml"
OUT="$output_dir" yq -i '.output.dir = strenv(OUT)' "$crop_yaml"

if [[ -n "$crop_max_emit" ]]; then
  if [[ "$crop_max_emit" == "null" ]]; then
    yq -i '.crop.max_emit = null' "$crop_yaml"
  else
    CROP_MAX_EMIT="$crop_max_emit" yq -i '.crop.max_emit = (strenv(CROP_MAX_EMIT) | tonumber)' "$crop_yaml"
  fi
fi

if ! grep -qE '^[^#]*horizontal_aperture:' "$sdg_yaml" "$pcba_patched" 2>/dev/null; then
  {
    printf '\n'
    printf 'horizontal_aperture: 200.0\n'
  } >>"$sdg_yaml"
fi

cp "$pcba_patched" "$output_dir/pcba_target.yaml"
cp "$sdg_yaml" "$output_dir/day0_image.yaml"
cp "$crop_yaml" "$output_dir/day0_crop.yaml"

info "Running Day 0 scan-grid render: $scene_usd"
run_with_timeout "$kit_timeout_seconds" "Day 0 scan-grid render" \
  /isaac-sim/kit/kit /isaac-sim/apps/isaacsim.exp.base.kit \
  --no-window --exec \
  "$paidf_root/scripts/sdg/standalone/sdg_pipeline.py --config $sdg_yaml --pcba-config $pcba_patched"

info "Running Day 0 ROI crop"
python3 "$paidf_root/scripts/usd2roi/usd2roi_crop.py" --config "$crop_yaml"

roi_count=$(find "$output_dir/crop" -path '*/normal_img/*.png' -type f 2>/dev/null | wc -l | tr -d '[:space:]')
[[ "$roi_count" =~ ^[0-9]+$ && "$roi_count" -gt 0 ]] || fatal "0 ROI normal images emitted under $output_dir/crop"
material_dirs=$(find "$output_dir/crop" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; 2>/dev/null | sort | tr '\n' ' ')
{
  printf 'workflow=day0-usd2roi\n'
  printf 'board=%s\n' "$board"
  printf 'scene_filename=%s\n' "$scene_filename"
  printf 'roi_count=%s\n' "$roi_count"
  printf 'materials=%s\n' "$material_dirs"
} >"$output_dir/artifact_manifest.txt"

info "Day 0 usd2roi complete: $roi_count ROI(s); materials: $material_dirs"
