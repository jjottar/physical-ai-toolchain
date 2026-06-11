#!/usr/bin/env bash
# Validate and run the Day 1 real-photo alignment simulation stage
set -o errexit -o nounset -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=stage-common.sh
source "$SCRIPT_DIR/stage-common.sh"

show_help() {
  cat << 'EOF'
Usage: run-usd2roi-day1-real-alignment.sh [OPTIONS]

OPTIONS:
    --pcb-assets DIR           Downloaded datasets/pcb/assets input
    --output-dir DIR           Stage output folder
    --board NAME               Cookbook board name
    --scene-filename NAME      Scene USD basename
    --real-image-filename PATH Real photo path relative to assets root or basename
    -h, --help                 Show this help message
EOF
}

pcb_assets=""
output_dir=""
board="0603_H100"
scene_filename="spark_lighting.usd"
real_image_filename="input_real_image/0603_H100.jpg"
paidf_root="${PAIDF_SIMULATION_ROOT:-/workspace/paidf-simulation}"
kit_timeout_seconds="${DIG_AML_KIT_TIMEOUT_SECONDS:-1200}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)              show_help; exit 0 ;;
    --pcb-assets)           pcb_assets="$(require_option_value "$1" "${2:-}")"; shift 2 ;;
    --output-dir)           output_dir="$(require_option_value "$1" "${2:-}")"; shift 2 ;;
    --board)                board="$(require_option_value "$1" "${2:-}")"; shift 2 ;;
    --scene-filename)       scene_filename="$(require_option_value "$1" "${2:-}")"; shift 2 ;;
    --real-image-filename)  real_image_filename="$(require_option_value "$1" "${2:-}")"; shift 2 ;;
    *)                      fatal "Unknown option: $1" ;;
  esac
done

require_dir "$pcb_assets" "PCBA assets"
require_output_dir "$output_dir"
require_optix
require_dev_shm_gb 16
require_paidf_root "$paidf_root" "paidf-simulation"
require_file "$paidf_root/scripts/usd2roi/usd2roi_render.py" "usd2roi_render.py"
require_file "$paidf_root/scripts/usd2roi/usd2roi_register.py" "usd2roi_register.py"
require_file "$paidf_root/scripts/usd2roi/usd2roi_crop.py" "usd2roi_crop.py"
[[ -n "$(find_first_file "$pcb_assets" "$scene_filename")" ]] || \
  fatal "scene_filename=$scene_filename not found under $pcb_assets"
[[ -n "$real_image_filename" ]] || fatal "--real-image-filename is required"
[[ "$real_image_filename" != /* && "$real_image_filename" != *".."* && "$real_image_filename" != *"//"* ]] || \
  fatal "--real-image-filename must be relative and remain under the PCBA assets root"
if [[ -f "$pcb_assets/$real_image_filename" ]]; then
  info "real image found: $pcb_assets/$real_image_filename"
else
  [[ -n "$(find_first_file "$pcb_assets" "$(basename "$real_image_filename")")" ]] || \
    fatal "real_image_filename=$real_image_filename not found under $pcb_assets"
fi
ensure_yq

cookbook_dir="$DIG_AML_ROOT/cookbooks/pcb/$board"
require_file "$cookbook_dir/usd2roi_nvpcb.yaml" "Day 1 usd2roi cookbook"

scene_usd="$(find_first_file "$pcb_assets" "$scene_filename")"
if [[ -f "$pcb_assets/$real_image_filename" ]]; then
  real_image="$pcb_assets/$real_image_filename"
else
  real_image="$(find_first_file "$pcb_assets" "$(basename "$real_image_filename")")"
fi

config_file=/tmp/usd2roi_day1_resolved.yaml
cp "$cookbook_dir/usd2roi_nvpcb.yaml" "$config_file"
SCENE_USD="$scene_usd" REAL_IMAGE="$real_image" OUT="$output_dir" yq -i '
  .scene = strenv(SCENE_USD) |
  .real_image = strenv(REAL_IMAGE) |
  .output.dir = strenv(OUT)
' "$config_file"
cp "$config_file" "$output_dir/usd2roi_day1.yaml"

info "Running Day 1 USD render: $scene_usd"
run_with_timeout "$kit_timeout_seconds" "Day 1 USD render" \
  /isaac-sim/kit/kit /isaac-sim/apps/isaacsim.exp.base.kit \
  --no-window --exec \
  "$paidf_root/scripts/usd2roi/usd2roi_render.py --config $config_file"

info "Running Day 1 MI registration: $real_image"
set +o errexit
python3 "$paidf_root/scripts/usd2roi/usd2roi_register.py" --config "$config_file"
registration_exit=$?
set -o errexit
if [[ "$registration_exit" -ne 0 ]]; then
  fatal "usd2roi_register.py exited $registration_exit; inspect MI alignment ranges and real-photo pairing"
fi

info "Running Day 1 ROI crop"
python3 "$paidf_root/scripts/usd2roi/usd2roi_crop.py" --config "$config_file"

roi_count=$(find "$output_dir/crop" -path '*/normal_img/*.png' -type f 2>/dev/null | wc -l | tr -d '[:space:]')
[[ "$roi_count" =~ ^[0-9]+$ && "$roi_count" -gt 0 ]] || fatal "0 Day 1 ROI crops emitted under $output_dir/crop"
{
  printf 'workflow=day1-real-photo-usd2roi\n'
  printf 'board=%s\n' "$board"
  printf 'scene_filename=%s\n' "$scene_filename"
  printf 'real_image_filename=%s\n' "$real_image_filename"
  printf 'roi_count=%s\n' "$roi_count"
} >"$output_dir/artifact_manifest.txt"

info "Day 1 real-photo alignment complete: $roi_count ROI(s)"
