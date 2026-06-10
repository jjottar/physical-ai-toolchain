#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import sys


def _pairs_from_args(args: argparse.Namespace) -> list[tuple[str, str]]:
    if args.pairs:
        try:
            parsed = json.loads(args.pairs)
        except json.JSONDecodeError as exc:
            print(f"ERROR: --pairs is not valid JSON: {exc}", file=sys.stderr)
            raise SystemExit(2) from exc
        pairs = []
        for index, item in enumerate(parsed):
            if not isinstance(item, list) or len(item) != 2 or not all(isinstance(value, str) for value in item):
                print(f"ERROR: --pairs entry {index} must be [material, defect] strings", file=sys.stderr)
                raise SystemExit(2)
            pairs.append((item[0], item[1]))
        return pairs

    if args.material and args.defects:
        try:
            parsed_defects = json.loads(args.defects)
        except json.JSONDecodeError as exc:
            print(f"ERROR: --defects is not valid JSON: {exc}", file=sys.stderr)
            raise SystemExit(2) from exc
        if not isinstance(parsed_defects, list) or not all(isinstance(value, str) for value in parsed_defects):
            print("ERROR: --defects must be a JSON array of strings", file=sys.stderr)
            raise SystemExit(2)
        return [(args.material, defect) for defect in parsed_defects]

    print("ERROR: pass either --pairs or (--material + --defects)", file=sys.stderr)
    raise SystemExit(2)


def main() -> int:
    parser = argparse.ArgumentParser(description="Render AnomalyGen defect_spec.jsonl")
    parser.add_argument("--output", required=True)
    parser.add_argument("--pairs", default="")
    parser.add_argument("--material", default="")
    parser.add_argument("--defects", default="")
    parser.add_argument("--spatial-dependency", default="free", choices=["free", "text", "cad"])
    parser.add_argument("--roi-prompt", default="")
    args = parser.parse_args()

    if args.spatial_dependency == "text" and not args.roi_prompt:
        print("ERROR: --roi-prompt is required when --spatial-dependency=text", file=sys.stderr)
        return 2

    pairs = _pairs_from_args(args)
    with open(args.output, "w", encoding="utf-8") as output_file:
        for material, defect in pairs:
            output_file.write(
                json.dumps(
                    {
                        "defect_type": f"{material}+{defect}",
                        "spatial_dependency": args.spatial_dependency,
                        "roi_prompt_defect_location": args.roi_prompt,
                    }
                )
                + "\n"
            )
    print(f"wrote {len(pairs)} entries to {args.output} (spatial_dependency={args.spatial_dependency})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
