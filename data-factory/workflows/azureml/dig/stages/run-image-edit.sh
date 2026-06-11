#!/usr/bin/env bash
# Validate and run the Qwen Image-Edit augmentation stage
set -o errexit -o nounset -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=stage-common.sh
source "$SCRIPT_DIR/stage-common.sh"

show_help() {
  cat << 'EOF'
Usage: run-image-edit.sh [OPTIONS]

OPTIONS:
    --input-dir DIR          Rendered ROI or structural crop input
    --output-dir DIR         Stage output folder
    --image-edit-endpoint URL
    --image-edit-model MODEL Exact model ID; must be NVIDIA NVPCB OVSL2SL
    --layout NAME            day0-roi or structural-rgb
    -h, --help               Show this help message
EOF
}

input_dir=""
output_dir=""
image_edit_endpoint=""
image_edit_model="nvidia/Qwen-Image-Edit-NVPCB-OVSL2SL"
layout="day0-roi"

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)              show_help; exit 0 ;;
    --input-dir)            input_dir="$(require_option_value "$1" "${2:-}")"; shift 2 ;;
    --output-dir)           output_dir="$(require_option_value "$1" "${2:-}")"; shift 2 ;;
    --image-edit-endpoint)  image_edit_endpoint="$(require_option_value "$1" "${2:-}")"; shift 2 ;;
    --image-edit-model)     image_edit_model="$(require_option_value "$1" "${2:-}")"; shift 2 ;;
    --layout)               layout="$(require_option_value "$1" "${2:-}")"; shift 2 ;;
    *)                      fatal "Unknown option: $1" ;;
  esac
done

require_dir "$input_dir" "image-edit input"
require_output_dir "$output_dir"
[[ -n "$image_edit_endpoint" ]] || fatal "--image-edit-endpoint is required"
validate_image_edit_model "$image_edit_endpoint" "$image_edit_model"

case "$layout" in
  day0-roi) require_nonzero_file_count "$input_dir" '*/normal_img/*.png' "Day 0 ROI normal image" ;;
  structural-rgb) require_nonzero_file_count "$input_dir" '*/rgb/*.png' "structural RGB crop" ;;
  *) fatal "--layout must be day0-roi or structural-rgb" ;;
esac

require_file /app/modules/cli.py "PAIDF augmentation CLI"
require_file "$DIG_AML_ROOT/cookbooks/pcb/augmentation_config_ovsl2sl.yaml" "augmentation cookbook"
require_command uv

batch_builder=/tmp/build_image_edit_batch.py
cat >"$batch_builder" <<'PY'
from __future__ import annotations

import glob
import os
import pathlib
import sys

import yaml


def _overlay_endpoint(config: dict[str, object]) -> None:
  endpoint = os.environ.get("IMAGE_EDIT_ENDPOINT", "").strip()
  model = os.environ.get("IMAGE_EDIT_MODEL", "").strip()
  image_edit = config.setdefault("endpoints", {}).setdefault("image_edit", {})
  if endpoint:
    image_edit["url"] = endpoint
  if model:
    image_edit["model"] = model


def _output_extension(config: dict[str, object]) -> str:
  data = config.get("data") or [{}]
  template = data[0]
  output = template.get("output", {}) if isinstance(template, dict) else {}
  return pathlib.Path(output.get("video", "/tmp/output.png")).suffix or ".png"


def _day0_entries(input_dir: str, output_dir: str, extension: str) -> list[dict[str, object]]:
  images = sorted(glob.glob(f"{input_dir}/crop/*/*/normal_img/*.png") + glob.glob(f"{input_dir}/crop/*/*/normal_img/*.jpg"))
  if not images:
    raise SystemExit(f"No Day 0 ROI images found under {input_dir}/crop/*/*/normal_img/")
  entries = []
  for image in images:
    path = pathlib.Path(image)
    material = path.parts[-4]
    cell = path.parts[-3]
    cell_output = pathlib.Path(output_dir) / "crop" / material / cell
    cell_output.mkdir(parents=True, exist_ok=True)
    stem = path.stem
    entries.append(
      {
        "inputs": {"rgb": image},
        "output": {
          "video": str(cell_output / f"{stem}{extension}"),
          "caption": f"/tmp/cap_{material}_{cell}_{stem}.txt",
          "metadata": f"/tmp/meta_{material}_{cell}_{stem}.json",
        },
      }
    )
  return entries


def _structural_entries(input_dir: str, output_dir: str, extension: str) -> list[dict[str, object]]:
  images: list[tuple[str, str]] = []
  for rgb_dir in sorted(glob.glob(f"{input_dir}/cropped/*/rgb")):
    mode = pathlib.Path(rgb_dir).parent.name
    for image in sorted(glob.glob(f"{rgb_dir}/*.png") + glob.glob(f"{rgb_dir}/*.jpg")):
      images.append((mode, image))
  if not images:
    raise SystemExit(f"No structural RGB crops found under {input_dir}/cropped/<mode>/rgb/")
  entries = []
  for mode, image in images:
    path = pathlib.Path(image)
    output_path = pathlib.Path(output_dir) / mode / "rgb"
    output_path.mkdir(parents=True, exist_ok=True)
    stem = path.stem
    entries.append(
      {
        "inputs": {"rgb": image},
        "output": {
          "video": str(output_path / f"{stem}{extension}"),
          "caption": f"/tmp/cap_{mode}_{stem}.txt",
          "metadata": f"/tmp/meta_{mode}_{stem}.json",
        },
      }
    )
  return entries


input_dir, output_dir, cookbook_path, batch_path, layout = sys.argv[1:]
with open(cookbook_path, encoding="utf-8") as cookbook_file:
  config = yaml.safe_load(cookbook_file)

_overlay_endpoint(config)
extension = _output_extension(config)
if layout == "day0-roi":
  config["data"] = _day0_entries(input_dir, output_dir, extension)
elif layout == "structural-rgb":
  config["data"] = _structural_entries(input_dir, output_dir, extension)
else:
  raise SystemExit(f"unsupported layout: {layout}")

with open(batch_path, "w", encoding="utf-8") as batch_file:
  yaml.safe_dump(config, batch_file, sort_keys=False)
print(f"Batch config: {len(config['data'])} image(s) -> {batch_path}")
PY

export IMAGE_EDIT_ENDPOINT="$image_edit_endpoint"
export IMAGE_EDIT_MODEL="$image_edit_model"
batch_config=/tmp/augmentation_batch.yaml
(
  cd /app
  uv run python "$batch_builder" \
    "$input_dir" "$output_dir" "$DIG_AML_ROOT/cookbooks/pcb/augmentation_config_ovsl2sl.yaml" "$batch_config" "$layout"
  uv run python modules/cli.py --config "$batch_config"
)

case "$layout" in
  day0-roi) emitted_count=$(find "$output_dir/crop" -mindepth 3 \( -name '*.png' -o -name '*.jpg' \) -type f 2>/dev/null | wc -l | tr -d '[:space:]') ;;
  structural-rgb) emitted_count=$(find "$output_dir" -mindepth 3 -path '*/rgb/*' \( -name '*.png' -o -name '*.jpg' \) -type f 2>/dev/null | wc -l | tr -d '[:space:]') ;;
esac
[[ "$emitted_count" =~ ^[0-9]+$ && "$emitted_count" -gt 0 ]] || fatal "image-edit emitted no images"
{
  printf 'workflow=image-edit\n'
  printf 'layout=%s\n' "$layout"
  printf 'image_edit_model=%s\n' "$image_edit_model"
  printf 'output_file_count=%s\n' "$emitted_count"
} >"$output_dir/artifact_manifest.txt"
info "Image-edit complete: $emitted_count image(s)"
