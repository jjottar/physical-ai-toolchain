#!/usr/bin/env bash
# Preview, validate, and submit DIG Azure ML jobs
set -o errexit -o nounset -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || (cd "$SCRIPT_DIR/../.." && pwd))"

should_load_env_local=false
for arg in "$@"; do
  case "$arg" in
    --submit) should_load_env_local=true ;;
    --) break ;;
  esac
done
if [[ "$should_load_env_local" != "true" ]]; then
  export PHYSICAL_AI_SKIP_ENV_LOCAL=true
fi

# shellcheck source=../../scripts/lib/common.sh
source "$REPO_ROOT/scripts/lib/common.sh"
# shellcheck source=../../scripts/lib/terraform-outputs.sh
source "$REPO_ROOT/scripts/lib/terraform-outputs.sh"

unset HF_TOKEN HUGGING_FACE_HUB_TOKEN NGC_API_KEY
unset should_load_env_local

show_help() {
  cat << 'EOF'
Usage: submit-azureml-dig.sh [OPTIONS]

Preview, validate, or submit live-validated DIG Azure ML command jobs on attached AKS compute.

WORKFLOW:
  -w, --workflow NAME              DIG workflow: setup-pretrained, setup-pcb, setup-metal,
                    setup-glass, finetune, day1-manual-roi
                    (default: setup-metal)
        --data-factory-source DIR    physical-ai-data-factory checkout path
        --source-path DIR            Alias for --data-factory-source
        --job-file PATH              Azure ML commandJob YAML template path

AZURE CONTEXT:
        --subscription-id ID         Azure subscription ID
        --resource-group NAME        Azure resource group
        --workspace-name NAME        Azure ML workspace
        --compute NAME               Azure ML Kubernetes compute target
        --instance-type NAME         Azure ML Kubernetes InstanceType
        --datastore NAME             Azure ML datastore name
        --pretrained-datastore NAME  Azure ML datastore for cached pretrained inputs
        --cosmos-cache-datastore NAME
                    Azure ML datastore for cached Cosmos inputs
        --storage-account NAME       Expected Azure Storage account for raw azure:// inputs
        --storage-container NAME     Expected Azure Storage container for raw azure:// inputs
    -t, --tf-dir DIR                 Terraform directory for fallback outputs

DATA AND SECRETS:
        --storage-root PATH          Datastore prefix root or raw Azure storage root (default: dig)
        --pretrained-storage-root PATH
                    Datastore prefix root for cached pretrained inputs
        --cosmos-cache-root PATH      Datastore prefix root for cached Cosmos inputs
        --glass-zip-path PATH         Datastore path to staged mobile_screen.zip
        --output-prefix PATH         Datastore output prefix or raw Azure storage root (default: dig/runs)
        --run-name NAME              Logical DIG run name for run output paths
        --usecase NAME               Use case: pcb, metal_surface, or glass where supported
        --checkpoint-step STEP       Checkpoint step for Day 1 manual ROI
        --anomaly-types-json JSON    Defect taxonomy JSON for Day 1 manual ROI
        --num-sdg N                  Number of SDG entries for Day 1 manual ROI (default: 30)
        --default-spatial-dependency MODE
                    Spatial fallback for Day 1: free, text, cad (default: free)
        --model-size SIZE            AnomalyGen model size for Day 1: 2b or 14b (default: 2b)
        --num-gpus N                 GPU count for finetune jobs (default: 1)
        --min-gpu-memory-gb N        Minimum GPU memory preflight for GPU jobs (default: 40)
        --max-iter N                 Finetune trainer.max_iter override; 0 uses cookbook default
        --save-iter N                Finetune checkpoint.save_iter override; 0 uses cookbook default
        --use-pretrained-checkpoint BOOL
                    Day 1 mode flag; false is rejected in Phase 8
        --pretrained-model-sizes SIZES
                    Pretrained setup model sizes (default: 2B)
        --key-vault-url URL          Key Vault URL reference for runtime secret retrieval
        --hf-token-secret-name NAME  Key Vault secret name for HF token
        --hf-secret-name NAME        Alias for --hf-token-secret-name
        --ngc-api-key-secret-name NAME
                                      Optional Key Vault secret name for NGC API access
        --ngc-secret-name NAME       Alias for --ngc-api-key-secret-name

JOB ASSETS:
        --image IMAGE                AnomalyGen image reference (default: nvcr.io/nvidia/paidf-anomalygen:1.0.0)
        --rendered-job-output PATH   Write the rendered Azure ML commandJob YAML to PATH
        --assets-only                Render and validate local assets without cloud calls or submission
        --validate-cloud             Run read-only Azure ML, Key Vault, datastore, and InstanceType checks
        --submit                     Submit the rendered commandJob to Azure ML
        --stream                     Stream logs after a submitted job returns a name
        --config-preview             Print redacted configuration and exit without submission
    -h, --help                       Show this help message

Values resolve as CLI > environment variables > Terraform outputs.
Arguments after -- are rejected. Use the explicit submitter options above so
secret-bearing Azure ML overrides cannot bypass local validation.
EOF
}

require_option_value() {
  local option_name="$1" option_value="${2:-}"

  [[ -n "$option_value" && "$option_value" != --* ]] || fatal "$option_name requires a value"
  echo "$option_value"
}

ensure_ml_extension() {
  az extension show --name ml &>/dev/null ||
    fatal "Azure ML CLI extension not installed. Run: az extension add --name ml"
}

looks_like_secret_value() {
  local value="$1"

  [[ "$value" =~ ^hf_[A-Za-z0-9_=-]{20,}$ ]] || \
    [[ "$value" =~ ^(nvapi|ngc)[_-][A-Za-z0-9_=-]{20,}$ ]] || \
    [[ "$value" =~ ^[A-Za-z0-9_=-]{64,}$ ]]
}

normalize_optional_secret_name() {
  local value="$1"

  case "$value" in
    ""|none|null|false) echo "" ;;
    *) echo "$value" ;;
  esac
}

redacted_reference() {
  local value="$1"

  if [[ -z "$value" ]]; then
    echo "<none>"
  else
    echo "<key-vault:${value}>"
  fi
}

validate_secret_name() {
  local option_name="$1" secret_name="$2"

  if looks_like_secret_value "$secret_name"; then
    fatal "$option_name must not contain a token value"
  fi
  [[ "$secret_name" =~ ^[A-Za-z0-9-]{1,127}$ ]] || fatal "$option_name must be a Key Vault secret name"
}

validate_job_environment_override() {
  local override="$1" override_value

  case "$override" in
    environment_variables.*=*)
      override_value="${override#*=}"
      if looks_like_secret_value "$override_value"; then
        fatal "Azure ML job environment variable overrides must not contain token values"
      fi
      ;;
  esac
}

validate_key_vault_url() {
  local value="$1"

  [[ "$value" =~ ^https://[A-Za-z0-9-]+\.vault\.azure\.net/?$ ]] || \
    fatal "--key-vault-url must be an Azure Key Vault URL"
}

validate_simple_name() {
  local option_name="$1" value="$2"

  [[ "$value" =~ ^[A-Za-z0-9_.-]+$ ]] || fatal "$option_name contains unsupported characters"
}

validate_image_reference() {
  local value="$1"
  local raw_storage_prefix="azure:/"

  [[ "$value" =~ ^[A-Za-z0-9./:_-]+$ ]] || fatal "--image contains unsupported characters"
  [[ "$value" != *"${raw_storage_prefix}/"* ]] || fatal "--image must not contain raw storage paths"
}

validate_usecase() {
  local value="$1"

  case "$value" in
    pcb|metal_surface|glass) ;;
    *) fatal "--usecase must be one of: pcb, metal_surface, glass" ;;
  esac
}

validate_relative_path_value() {
  local option_name="$1" value="$2"

  [[ -n "$value" ]] || fatal "$option_name must not be empty"
  [[ "$value" != /* && "$value" != *".."* && "$value" != *"//"* ]] || \
    fatal "$option_name must be a relative path without '..' or empty segments"
}

default_usecase_for_workflow() {
  local selected_workflow="$1"

  case "$selected_workflow" in
    setup-pcb|finetune) echo "pcb" ;;
    setup-metal|day1-manual-roi) echo "metal_surface" ;;
    setup-glass) echo "glass" ;;
    setup-pretrained) echo "pcb" ;;
    *) fatal "Unsupported workflow: $selected_workflow" ;;
  esac
}

default_run_name_for_workflow() {
  local selected_workflow="$1"

  case "$selected_workflow" in
    setup-pretrained) echo "setup-pretrained" ;;
    setup-pcb) echo "setup-pcb" ;;
    setup-metal) echo "setup-metal" ;;
    setup-glass) echo "setup-glass" ;;
    finetune) echo "finetune" ;;
    day1-manual-roi) echo "texture_defect_gen_day1_manual_roi" ;;
    *) fatal "Unsupported workflow: $selected_workflow" ;;
  esac
}

default_checkpoint_step_for_usecase() {
  local value="$1"

  case "$value" in
    pcb) echo "14000" ;;
    metal_surface) echo "10000" ;;
    glass) echo "9000" ;;
    *) fatal "Unsupported usecase: $value" ;;
  esac
}

default_anomaly_types_for_usecase() {
  local value="$1"

  case "$value" in
    pcb) echo '[["passive_component","missing"]]' ;;
    metal_surface) echo '[["metal_surface","MT_Blowhole"],["metal_surface","MT_Break"],["metal_surface","MT_Crack"],["metal_surface","MT_Fray"],["metal_surface","MT_Uneven"]]' ;;
    glass) echo '[["Phone","oil"],["Phone","scratch"],["Phone","stain"]]' ;;
    *) fatal "Unsupported usecase: $value" ;;
  esac
}

default_anomaly_types_for_workflow() {
  local selected_workflow="$1" selected_usecase="$2"

  default_anomaly_types_for_usecase "$selected_usecase"
}

normalize_bool() {
  local option_name="$1" value="$2" normalized

  normalized="$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]')"
  case "$normalized" in
    true|1|yes) echo "true" ;;
    false|0|no) echo "false" ;;
    *) fatal "$option_name must be true or false" ;;
  esac
}

validate_json_value() {
  local option_name="$1" value="$2"

  python3 -c 'import json, sys; json.loads(sys.argv[1])' "$value" >/dev/null 2>&1 || \
    fatal "$option_name must be valid JSON"
}

validate_matrix_options() {
  validate_usecase "$usecase"
  validate_simple_name "--run-name" "$run_name"
  [[ "$checkpoint_step" =~ ^[0-9]+$ ]] || fatal "--checkpoint-step must be a non-negative integer"
  [[ "$num_sdg" =~ ^[0-9]+$ ]] || fatal "--num-sdg must be a non-negative integer"
  [[ "$num_gpus" =~ ^[1-9][0-9]*$ ]] || fatal "--num-gpus must be a positive integer"
  [[ "$min_gpu_memory_gb" =~ ^[0-9]+$ ]] || fatal "--min-gpu-memory-gb must be a non-negative integer"
  [[ "$max_iter" =~ ^[0-9]+$ ]] || fatal "--max-iter must be a non-negative integer"
  [[ "$save_iter" =~ ^[0-9]+$ ]] || fatal "--save-iter must be a non-negative integer"
  validate_json_value "--anomaly-types-json" "$anomaly_types_json"
  case "$default_spatial_dependency" in
    free|text|cad) ;;
    *) fatal "--default-spatial-dependency must be one of: free, text, cad" ;;
  esac
  case "$model_size" in
    2b|14b) ;;
    *) fatal "--model-size must be one of: 2b, 14b" ;;
  esac
  [[ "$pretrained_model_sizes" =~ ^[A-Za-z0-9[:space:]]+$ ]] || \
    fatal "--pretrained-model-sizes contains unsupported characters"
  if [[ "$workflow" == "finetune" && "$usecase" != "pcb" ]]; then
    fatal "finetune is live-validated only for --usecase pcb in this commit"
  fi
}

is_raw_storage_uri() {
  local value="$1"

  [[ "$value" == azure://* ]]
}

raw_storage_account_from_uri() {
  local value="$1" remainder

  remainder="${value#azure://}"
  echo "${remainder%%/*}"
}

raw_storage_container_from_uri() {
  local value="$1" remainder

  remainder="${value#azure://}"
  [[ "$remainder" == */* ]] || return 0
  remainder="${remainder#*/}"
  echo "${remainder%%/*}"
}

validate_raw_storage_uri_shape() {
  local value="$1"

  [[ "$value" =~ ^azure://[^/]+/[^/]+/.+ ]] || \
    fatal "Raw storage URI must use azure://<account>/<container>/<path>"
}

validate_raw_storage_authority() {
  local value="$1" expected_account="$2" expected_container="$3"
  local account container

  validate_raw_storage_uri_shape "$value"
  account="$(raw_storage_account_from_uri "$value")"
  container="$(raw_storage_container_from_uri "$value")"

  [[ "$account" =~ ^[a-z0-9]{3,24}$ ]] || fatal "Raw storage URI account must be a lowercase Azure Storage account name"
  [[ "$container" =~ ^[a-z0-9]([a-z0-9-]{1,61}[a-z0-9])?$ ]] || \
    fatal "Raw storage URI container must be a valid Azure Storage container name"
  [[ -n "$expected_account" ]] || fatal "Raw storage URI requires --storage-account or DIG_STORAGE_ACCOUNT"
  [[ -n "$expected_container" ]] || fatal "Raw storage URI requires --storage-container or DIG_STORAGE_CONTAINER"
  [[ "$account" == "$expected_account" ]] || \
    fatal "Raw storage URI account '$account' does not match expected account '$expected_account'"
  [[ "$container" == "$expected_container" ]] || \
    fatal "Raw storage URI container '$container' does not match expected container '$expected_container'"
}

resolve_raw_storage_authority() {
  local current_account="$1" current_container="$2"
  shift 2
  local value account container

  for value in "$@"; do
    if is_raw_storage_uri "$value"; then
      validate_raw_storage_uri_shape "$value"
      account="$(raw_storage_account_from_uri "$value")"
      container="$(raw_storage_container_from_uri "$value")"
      if [[ -z "$current_account" ]]; then
        current_account="$account"
      elif [[ "$current_account" != "$account" ]]; then
        fatal "Raw storage URI account '$account' does not match expected account '$current_account'"
      fi
      if [[ -z "$current_container" ]]; then
        current_container="$container"
      elif [[ "$current_container" != "$container" ]]; then
        fatal "Raw storage URI container '$container' does not match expected container '$current_container'"
      fi
    fi
  done

  printf '%s\t%s\n' "$current_account" "$current_container"
}

normalize_datastore_path() {
  local value="$1" expected_account="$2" expected_container="$3" normalized remainder

  case "$value" in
    azure://*)
      validate_raw_storage_authority "$value" "$expected_account" "$expected_container"
      remainder="${value#azure://}"
      remainder="${remainder#*/}"
      normalized="${remainder#*/}"
      ;;
    azureml://*)
      fatal "Storage path options accept datastore-relative paths or raw Azure storage roots, not azureml:// URIs"
      ;;
    *)
      normalized="$value"
      ;;
  esac

  normalized="${normalized#/}"
  normalized="${normalized%/}"
  [[ -n "$normalized" ]] || fatal "Storage path must include a datastore-relative path"
  [[ "$normalized" != *".."* ]] || fatal "Storage path must not contain '..'"
  [[ "$normalized" != *"//"* ]] || fatal "Storage path must not contain empty segments"
  echo "$normalized"
}

azureml_uri() {
  local datastore_name="$1" path_value="$2" normalized_path

  normalized_path="$(normalize_datastore_path "$path_value" "$raw_storage_account" "$raw_storage_container")"
  printf 'azureml://datastores/%s/paths/%s\n' "$datastore_name" "$normalized_path"
}

require_path() {
  local path_value="$1" description="$2"

  [[ -e "$path_value" ]] || fatal "$description not found: $path_value"
}

validate_source_inventory() {
  local source_root="$1" selected_workflow="$2" selected_usecase="${3:-}" dig_root

  [[ -d "$source_root" ]] || fatal "physical-ai-data-factory source path not found: $source_root"
  [[ "$source_root" != *"/.azure"* && "$source_root" != *"/.ngc"* && "$source_root" != *"/.huggingface"* ]] || \
    fatal "Refusing to use a credential cache path as data-factory source"

  dig_root="$source_root/skills/physical-ai-defect-image-generation"
  require_path "$dig_root/SKILL.md" "DIG skill card"
  require_path "$dig_root/references/container-images.md" "DIG image reference"
  require_path "$dig_root/scripts/preflight_credentials.sh" "DIG credential preflight"
  require_path "$dig_root/scripts/preflight_urls.sh" "DIG URL preflight"

  case "$selected_workflow" in
    setup-pretrained)
      require_path "$dig_root/assets/configs/setup/setup_pretrained.yaml" "DIG setup-pretrained workflow config"
      require_path "$dig_root/references/setup.md" "DIG setup reference"
      ;;
    setup-pcb)
      require_path "$dig_root/assets/configs/setup/setup_pcb.yaml" "DIG setup-pcb workflow config"
      require_path "$dig_root/references/setup.md" "DIG setup reference"
      ;;
    setup-metal)
      require_path "$dig_root/assets/configs/setup/setup_metal.yaml" "DIG setup-metal workflow config"
      require_path "$dig_root/references/setup.md" "DIG setup reference"
      ;;
    setup-glass)
      require_path "$dig_root/assets/configs/setup/setup_glass.yaml" "DIG setup-glass workflow config"
      require_path "$dig_root/references/setup.md" "DIG setup reference"
      require_path "$source_root/docs/workflows/physical-ai-defect-image-generation/media/glass_dataset_download_instructions.md" "DIG glass dataset instructions"
      ;;
    finetune)
      require_path "$dig_root/assets/configs/finetune.yaml" "DIG finetune workflow config"
      require_path "$dig_root/references/flows/finetune.md" "DIG finetune flow reference"
      require_path "$dig_root/assets/cookbooks/$selected_usecase/ag_config.yaml" "DIG $selected_usecase cookbook"
      ;;
    day1-manual-roi)
      require_path "$dig_root/assets/configs/texture_defect_generation_day1_manual_roi.yaml" "DIG Day 1 manual ROI config"
      require_path "$dig_root/assets/cookbooks/$selected_usecase/ag_config.yaml" "DIG $selected_usecase cookbook"
      require_path "$dig_root/scripts/render_defect_spec.py" "DIG defect spec renderer"
      require_path "$dig_root/references/flows/texture_defect_generation_day1_manual_roi.md" "DIG Day 1 manual ROI flow reference"
      ;;
    *)
      fatal "Unsupported workflow: $selected_workflow"
      ;;
  esac
}

validate_local_assets() {
  local selected_workflow="$1" template_file="$2"

  require_path "$template_file" "Azure ML job template"
  require_path "$REPO_ROOT/data-factory/.amlignore" "Azure ML ignore file"
  require_path "$REPO_ROOT/data-factory/workflows/azureml/common/keyvault-env.sh" "Key Vault runtime wrapper"

  case "$selected_workflow" in
    setup-pretrained)
      require_path "$REPO_ROOT/data-factory/workflows/azureml/dig/run-setup-pretrained.sh" "setup-pretrained runner"
      ;;
    setup-pcb)
      require_path "$REPO_ROOT/data-factory/workflows/azureml/dig/run-setup-pcb.sh" "setup-pcb runner"
      ;;
    setup-metal)
      require_path "$REPO_ROOT/data-factory/workflows/azureml/dig/run-setup-metal.sh" "setup-metal runner"
      ;;
    setup-glass)
      require_path "$REPO_ROOT/data-factory/workflows/azureml/dig/run-setup-glass.sh" "setup-glass runner"
      ;;
    finetune)
      require_path "$REPO_ROOT/data-factory/workflows/azureml/dig/run-finetune.sh" "finetune runner"
      ;;
    day1-manual-roi)
      require_path "$REPO_ROOT/data-factory/workflows/azureml/dig/run-day1-manual-roi.sh" "Day 1 manual ROI runner"
      ;;
  esac
}

render_job_file() {
  local selected_workflow="$1" source_file="$2" rendered_file="$3"
  local compute_name="$4" instance_type_name="$5" datastore_name="$6"
  local storage_root_path="$7" output_prefix_path="$8" vault_url="$9"
  local hf_secret_name="${10}" ngc_secret_name="${11}" image_reference="${12}"
  local pretrained_datastore_name="${13}" pretrained_storage_root_path="${14}"
  local cosmos_cache_datastore_name="${15}" cosmos_cache_root_path="${16}"
  local selected_usecase="${17}" run_output_name="${18}" checkpoint_step_value="${19}"
  local anomaly_types_json_value="${20}" num_sdg_value="${21}" spatial_dependency_value="${22}"
  local model_size_value="${23}" num_gpus_value="${24}" min_gpu_memory_gb_value="${25}"
  local max_iter_value="${26}" save_iter_value="${27}" use_pretrained_checkpoint_value="${28}"
  local pretrained_model_sizes_value="${29}"
  local glass_zip_path="${30}"
  local usecase_model_uri raw_dataset_uri pcb_assets_uri pretrained_output_uri pretrained_uri cosmos_cache_uri glass_zip_uri results_uri
  local rendered_ngc_secret_name="${ngc_secret_name:-none}"
  local code_path="$REPO_ROOT/data-factory"

  usecase_model_uri="$(azureml_uri "$datastore_name" "$storage_root_path/models/$selected_usecase")"
  raw_dataset_uri="$(azureml_uri "$datastore_name" "$storage_root_path/datasets/$selected_usecase/raw")"
  pcb_assets_uri="$(azureml_uri "$datastore_name" "$storage_root_path/datasets/pcb/assets")"
  pretrained_output_uri="$(azureml_uri "$datastore_name" "$storage_root_path/models/pretrained")"
  pretrained_uri="$(azureml_uri "$pretrained_datastore_name" "$pretrained_storage_root_path/models/pretrained")"
  cosmos_cache_uri="$(azureml_uri "$cosmos_cache_datastore_name" "$cosmos_cache_root_path")"
  glass_zip_uri="$(azureml_uri "$datastore_name" "$glass_zip_path")"
  case "$selected_workflow" in
    finetune) results_uri="$(azureml_uri "$datastore_name" "$output_prefix_path/$run_output_name/finetune")" ;;
    day1-manual-roi) results_uri="$(azureml_uri "$datastore_name" "$output_prefix_path/$run_output_name/day1-manual-roi")" ;;
    *) results_uri="$(azureml_uri "$datastore_name" "$output_prefix_path/$run_output_name")" ;;
  esac

  awk \
    -v selected_workflow="$selected_workflow" \
    -v selected_usecase="$selected_usecase" \
    -v run_output_name="$run_output_name" \
    -v checkpoint_step_value="$checkpoint_step_value" \
    -v anomaly_types_json_value="$anomaly_types_json_value" \
    -v num_sdg_value="$num_sdg_value" \
    -v spatial_dependency_value="$spatial_dependency_value" \
    -v model_size_value="$model_size_value" \
    -v num_gpus_value="$num_gpus_value" \
    -v min_gpu_memory_gb_value="$min_gpu_memory_gb_value" \
    -v max_iter_value="$max_iter_value" \
    -v save_iter_value="$save_iter_value" \
    -v use_pretrained_checkpoint_value="$use_pretrained_checkpoint_value" \
    -v pretrained_model_sizes_value="$pretrained_model_sizes_value" \
    -v code_path="$code_path" \
    -v compute_name="azureml:${compute_name}" \
    -v instance_type_name="$instance_type_name" \
    -v image_reference="$image_reference" \
    -v vault_url="$vault_url" \
    -v hf_secret_name="$hf_secret_name" \
    -v ngc_secret_name="$rendered_ngc_secret_name" \
    -v usecase_model_uri="$usecase_model_uri" \
    -v raw_dataset_uri="$raw_dataset_uri" \
    -v pcb_assets_uri="$pcb_assets_uri" \
    -v pretrained_output_uri="$pretrained_output_uri" \
    -v pretrained_uri="$pretrained_uri" \
    -v cosmos_cache_uri="$cosmos_cache_uri" \
    -v glass_zip_uri="$glass_zip_uri" \
    -v results_uri="$results_uri" '
      BEGIN { quote = sprintf("%c", 39) }
      /^code:/ {
        print "code: " code_path
        next
      }
      /^environment:/ {
        print "environment:"
        print "  image: " image_reference
        next
      }
      /^  image:/ { next }
      /^compute:/ {
        print "compute: " compute_name
        next
      }
      /instance_type:/ {
        print "  instance_type: " instance_type_name
        next
      }
      /KEY_VAULT_URL:/ {
        print "  KEY_VAULT_URL: \"" vault_url "\""
        next
      }
      /HF_TOKEN_SECRET_NAME:/ {
        print "  HF_TOKEN_SECRET_NAME: \"" hf_secret_name "\""
        next
      }
      /NGC_API_KEY_SECRET_NAME:/ {
        print "  NGC_API_KEY_SECRET_NAME: \"" ngc_secret_name "\""
        next
      }
      /path: azureml:\/\/datastores\/datasets\/paths\/dig\/models\/pretrained/ {
        if (selected_workflow == "setup-pretrained") {
          print "    path: " pretrained_output_uri
        } else {
          print "    path: " pretrained_uri
        }
        next
      }
      /path: azureml:\/\/datastores\/datasets\/paths\/dig\/models\/(metal_surface|pcb|glass)/ {
        print "    path: " usecase_model_uri
        next
      }
      /path: azureml:\/\/datastores\/datasets\/paths\/dig\/datasets\/(metal_surface|pcb|glass)\/raw/ {
        print "    path: " raw_dataset_uri
        next
      }
      /path: azureml:\/\/datastores\/datasets\/paths\/dig\/uploads\/glass-zip\/mobile_screen.zip/ {
        print "    path: " glass_zip_uri
        next
      }
      /path: azureml:\/\/datastores\/datasets\/paths\/dig\/datasets\/pcb\/assets/ {
        print "    path: " pcb_assets_uri
        next
      }
      /path: azureml:\/\/datastores\/datasets\/paths\/data\/models\/cosmos_transfer/ {
        print "    path: " cosmos_cache_uri
        next
      }
      /path: azureml:\/\/datastores\/datasets\/paths\/dig\/runs\/\$\{\{name\}\}\/day1-manual-roi/ {
        print "    path: " results_uri
        next
      }
      /path: azureml:\/\/datastores\/datasets\/paths\/dig\/runs\/\$\{\{name\}\}\/finetune/ {
        print "    path: " results_uri
        next
      }
      /^  run_name:/ {
        print "  run_name: " run_output_name
        next
      }
      /^  usecase:/ {
        print "  usecase: " selected_usecase
        next
      }
      /^  use_pretrained_checkpoint:/ {
        print "  use_pretrained_checkpoint: \"" use_pretrained_checkpoint_value "\""
        next
      }
      /^  checkpoint_step:/ {
        print "  checkpoint_step: \"" checkpoint_step_value "\""
        next
      }
      /^  anomaly_types_json:/ {
        print "  anomaly_types_json: " quote anomaly_types_json_value quote
        next
      }
      /^  num_sdg:/ {
        print "  num_sdg: \"" num_sdg_value "\""
        next
      }
      /^  default_spatial_dependency:/ {
        print "  default_spatial_dependency: " spatial_dependency_value
        next
      }
      /^  model_size:/ {
        print "  model_size: " model_size_value
        next
      }
      /^  num_gpus:/ {
        print "  num_gpus: \"" num_gpus_value "\""
        next
      }
      /^  min_gpu_memory_gb:/ {
        print "  min_gpu_memory_gb: \"" min_gpu_memory_gb_value "\""
        next
      }
      /^  max_iter:/ {
        print "  max_iter: \"" max_iter_value "\""
        next
      }
      /^  save_iter:/ {
        print "  save_iter: \"" save_iter_value "\""
        next
      }
      /^  pretrained_model_sizes:/ {
        print "  pretrained_model_sizes: " pretrained_model_sizes_value
        next
      }
      { print }
    ' "$source_file" >"$rendered_file"

  local raw_storage_prefix="azure:/"
  if grep -q "${raw_storage_prefix}/" "$rendered_file"; then
    fatal "Rendered Azure ML job contains a raw storage path: $rendered_file"
  fi
}

validate_rendered_job() {
  local rendered_file="$1"

  if grep -q "^\\\$schema: https://azuremlschemas.azureedge.net/latest/commandJob.schema.json$" "$rendered_file"; then
    grep -q '^type: command$' "$rendered_file" || fatal "Rendered job type must be command"
    grep -q '^identity:$' "$rendered_file" || fatal "Rendered job must declare managed identity"
    grep -q '^compute: azureml:' "$rendered_file" || fatal "Rendered job must target Azure ML compute"
    grep -Eq 'mode: (download|upload)' "$rendered_file" || fatal "Rendered job must declare Azure ML data modes"
  else
    fatal "Rendered job is not an Azure ML commandJob schema: $rendered_file"
  fi
  grep -q 'azureml://datastores/' "$rendered_file" || fatal "Rendered job must use Azure ML datastore URIs"
  local raw_storage_prefix="azure:/"
  if grep -q "${raw_storage_prefix}/" "$rendered_file"; then
    fatal "Rendered job contains raw storage paths"
  fi
}

write_rendered_job_output() {
  local rendered_file="$1" output_file="$2" output_dir

  [[ -n "$output_file" ]] || return 0
  [[ "$output_file" != azure://* && "$output_file" != azureml://* ]] || \
    fatal "--rendered-job-output must be a local file path"
  [[ "$output_file" != */ ]] || fatal "--rendered-job-output must include a file name"
  if [[ "$output_file" == */* ]]; then
    output_dir="${output_file%/*}"
  else
    output_dir="."
  fi
  [[ -d "$output_dir" ]] || fatal "--rendered-job-output directory does not exist: $output_dir"
  [[ ! -d "$output_file" ]] || fatal "--rendered-job-output must not be a directory: $output_file"

  cp "$rendered_file" "$output_file"
  chmod 600 "$output_file"
}

print_artifact_expectations() {
  local selected_workflow="$1" selected_usecase="$2" selected_run_name="$3"

  section "Artifact Verification Hooks"
  case "$selected_workflow" in
    setup-pretrained)
      print_kv "Expected Output" "models/pretrained/pretrained"
      print_kv "Required Evidence" "artifact_manifest.txt plus non-empty pretrained provider subtrees"
      ;;
    setup-pcb)
      print_kv "Expected Outputs" "models/pcb, datasets/pcb/raw, datasets/pcb/assets"
      print_kv "Required Evidence" "ag_config.yaml, iter_*.pt, defect_spec.jsonl, USD asset files, artifact_manifest.txt"
      ;;
    setup-metal)
      print_kv "Expected Outputs" "models/metal_surface, datasets/metal_surface/raw"
      print_kv "Required Evidence" "ag_config.yaml, iter_*.pt, defect_spec.jsonl, non-empty raw data"
      ;;
    setup-glass)
      print_kv "Expected Outputs" "models/glass, datasets/glass/raw"
      print_kv "Required Input" "uploads/glass-zip/mobile_screen.zip"
      print_kv "Required Evidence" "ag_config.yaml, iter_*.pt, defect_spec.jsonl, Phone dataset tree, artifact_manifest.txt"
      ;;
    finetune)
      print_kv "Expected Output" "runs/$selected_run_name/finetune"
      print_kv "Required Evidence" "validation.jsonl, best_step.txt, iter_*.pt, artifact_manifest.txt"
      ;;
    day1-manual-roi)
      print_kv "Expected Output" "runs/$selected_run_name/day1-manual-roi"
      print_kv "Required Evidence" "verify_output.sh success, artifact_manifest.txt, non-empty inference output for $selected_usecase"
      ;;
  esac
}

validate_registry_network() {
  local image_reference="$1" status_code

  case "$image_reference" in
    nvcr.io/*)
      if command -v curl >/dev/null 2>&1; then
        status_code=$(curl --silent --output /dev/null --write-out '%{http_code}' --head https://nvcr.io/v2/ || true)
        case "$status_code" in
          200|401) info "NVCR registry endpoint reachable; image entitlement is validated by the job image pull" ;;
          000) fatal "NVCR registry endpoint is not reachable from this host" ;;
          *) warn "NVCR registry endpoint returned HTTP $status_code; image pull may fail" ;;
        esac
        warn "Exact NVCR image tag and entitlement validation is deferred to an approved Azure ML smoke job"
      else
        warn "curl not available; skipping NVCR endpoint reachability check"
      fi
      ;;
    *)
      info "Registry reachability check is only categorized for nvcr.io images"
      ;;
  esac
}

key_vault_name_from_url() {
  local value="$1" host

  host="${value#https://}"
  host="${host%%/*}"
  echo "${host%%.vault.azure.net}"
}

validate_cloud_state() {
  local subscription="$1" resource_group_name="$2" workspace="$3" compute_name="$4"
  local instance_type_name="$5" datastore_name="$6" vault_url="$7" hf_secret_name="$8"
  local ngc_secret_name="$9" image_reference="${10}"
  local pretrained_datastore_name="${11:-$datastore_name}"
  local cosmos_cache_datastore_name="${12:-$pretrained_datastore_name}"
  local vault_name

  require_tools az kubectl
  ensure_ml_extension
  [[ -n "$subscription" ]] && az account set --subscription "$subscription"

  az ml compute show --name "$compute_name" \
    --resource-group "$resource_group_name" --workspace-name "$workspace" >/dev/null || \
    fatal "Azure ML compute not found or not readable: $compute_name"

  az ml datastore show --name "$datastore_name" \
    --resource-group "$resource_group_name" --workspace-name "$workspace" >/dev/null || \
    fatal "Azure ML datastore not found or not readable: $datastore_name"

  if [[ "$pretrained_datastore_name" != "$datastore_name" ]]; then
    az ml datastore show --name "$pretrained_datastore_name" \
      --resource-group "$resource_group_name" --workspace-name "$workspace" >/dev/null || \
      fatal "Azure ML pretrained datastore not found or not readable: $pretrained_datastore_name"
  fi

  if [[ "$cosmos_cache_datastore_name" != "$datastore_name" && "$cosmos_cache_datastore_name" != "$pretrained_datastore_name" ]]; then
    az ml datastore show --name "$cosmos_cache_datastore_name" \
      --resource-group "$resource_group_name" --workspace-name "$workspace" >/dev/null || \
      fatal "Azure ML Cosmos cache datastore not found or not readable: $cosmos_cache_datastore_name"
  fi

  kubectl get instancetype.amlarc.azureml.com "$instance_type_name" >/dev/null || \
    fatal "Azure ML Kubernetes InstanceType not found in the current cluster: $instance_type_name"

  vault_name="$(key_vault_name_from_url "$vault_url")"
  az keyvault show --name "$vault_name" --query id -o tsv >/dev/null || \
    fatal "Key Vault not found or not readable: $vault_name"
  warn "Key Vault secret names validated by shape only; managed-identity secret access requires an approved smoke job"
  print_kv "HF Secret Reference" "$(redacted_reference "$hf_secret_name")"
  print_kv "NGC Secret Reference" "$(redacted_reference "$ngc_secret_name")"

  validate_registry_network "$image_reference"
}

#------------------------------------------------------------------------------
# Defaults
#------------------------------------------------------------------------------

workflow="setup-metal"
data_factory_source="${DATA_FACTORY_SOURCE:-${PAIDF_SOURCE_PATH:-${HOME:-$REPO_ROOT/..}/code/physical-ai-data-factory}}"
job_file=""
tf_dir="${TERRAFORM_DIR:-$REPO_ROOT/infrastructure/terraform}"

subscription_id="${AZURE_SUBSCRIPTION_ID:-}"
resource_group="${AZURE_RESOURCE_GROUP:-}"
workspace_name="${AZUREML_WORKSPACE_NAME:-}"
compute="${AZUREML_COMPUTE:-}"
instance_type="${AZUREML_INSTANCE_TYPE:-}"
datastore="${AZUREML_DATASTORE:-datasets}"
pretrained_datastore="${AZUREML_PRETRAINED_DATASTORE:-}"
cosmos_cache_datastore="${AZUREML_COSMOS_CACHE_DATASTORE:-}"
raw_storage_account="${DIG_STORAGE_ACCOUNT:-${AZURE_STORAGE_ACCOUNT:-}}"
raw_storage_container="${DIG_STORAGE_CONTAINER:-${AZURE_STORAGE_CONTAINER:-}}"

storage_root="${DIG_STORAGE_ROOT:-dig}"
pretrained_storage_root="${DIG_PRETRAINED_STORAGE_ROOT:-}"
cosmos_cache_root="${DIG_COSMOS_CACHE_ROOT:-data/models/cosmos_transfer/hub/models--nvidia--Cosmos-Predict2.5-2B/snapshots/f176dc95b4a70f53ce01c4b302851595e7322b00}"
glass_zip_path="${DIG_GLASS_ZIP_PATH:-dig/uploads/glass-zip/mobile_screen.zip}"
output_prefix="${DIG_OUTPUT_PREFIX:-dig/runs}"
run_name="${DIG_RUN_NAME:-}"
usecase="${DIG_USECASE:-}"
checkpoint_step="${DIG_CHECKPOINT_STEP:-}"
anomaly_types_json="${DIG_ANOMALY_TYPES_JSON:-}"
num_sdg="${DIG_NUM_SDG:-30}"
default_spatial_dependency="${DIG_DEFAULT_SPATIAL_DEPENDENCY:-}"
model_size="${DIG_MODEL_SIZE:-2b}"
num_gpus="${DIG_NUM_GPUS:-1}"
min_gpu_memory_gb="${DIG_MIN_GPU_MEMORY_GB:-40}"
max_iter="${DIG_MAX_ITER:-0}"
save_iter="${DIG_SAVE_ITER:-0}"
use_pretrained_checkpoint="${DIG_USE_PRETRAINED_CHECKPOINT:-true}"
pretrained_model_sizes="${DIG_PRETRAINED_MODEL_SIZES:-2B}"
key_vault_url="${KEY_VAULT_URL:-}"
hf_secret_name="${HF_TOKEN_SECRET_NAME:-paidf-hf-token}"
ngc_secret_name="${NGC_API_KEY_SECRET_NAME:-none}"
image="${PAIDF_ANOMALYGEN_IMAGE:-nvcr.io/nvidia/paidf-anomalygen:1.0.0}"
rendered_job_output=""

assets_only=false
validate_cloud=false
submit_requested=false
stream_logs=false
config_preview=false

#------------------------------------------------------------------------------
# Parse Arguments
#------------------------------------------------------------------------------

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)                           show_help; exit 0 ;;
    -w|--workflow)                       workflow="$(require_option_value "$1" "${2:-}")"; shift 2 ;;
    --data-factory-source|--source-path) data_factory_source="$(require_option_value "$1" "${2:-}")"; shift 2 ;;
    --job-file)                          job_file="$(require_option_value "$1" "${2:-}")"; shift 2 ;;
    --subscription-id)                   subscription_id="$(require_option_value "$1" "${2:-}")"; shift 2 ;;
    --resource-group)                    resource_group="$(require_option_value "$1" "${2:-}")"; shift 2 ;;
    --workspace-name)                    workspace_name="$(require_option_value "$1" "${2:-}")"; shift 2 ;;
    --compute)                           compute="$(require_option_value "$1" "${2:-}")"; shift 2 ;;
    --instance-type)                     instance_type="$(require_option_value "$1" "${2:-}")"; shift 2 ;;
    --datastore)                         datastore="$(require_option_value "$1" "${2:-}")"; shift 2 ;;
    --pretrained-datastore)              pretrained_datastore="$(require_option_value "$1" "${2:-}")"; shift 2 ;;
    --cosmos-cache-datastore)            cosmos_cache_datastore="$(require_option_value "$1" "${2:-}")"; shift 2 ;;
    --storage-account)                   raw_storage_account="$(require_option_value "$1" "${2:-}")"; shift 2 ;;
    --storage-container)                 raw_storage_container="$(require_option_value "$1" "${2:-}")"; shift 2 ;;
    --storage-root)                      storage_root="$(require_option_value "$1" "${2:-}")"; shift 2 ;;
    --pretrained-storage-root)           pretrained_storage_root="$(require_option_value "$1" "${2:-}")"; shift 2 ;;
    --cosmos-cache-root)                 cosmos_cache_root="$(require_option_value "$1" "${2:-}")"; shift 2 ;;
    --glass-zip-path)                    glass_zip_path="$(require_option_value "$1" "${2:-}")"; shift 2 ;;
    --output-prefix)                     output_prefix="$(require_option_value "$1" "${2:-}")"; shift 2 ;;
    --run-name)                          run_name="$(require_option_value "$1" "${2:-}")"; shift 2 ;;
    --usecase)                           usecase="$(require_option_value "$1" "${2:-}")"; shift 2 ;;
    --checkpoint-step)                   checkpoint_step="$(require_option_value "$1" "${2:-}")"; shift 2 ;;
    --anomaly-types-json)                anomaly_types_json="$(require_option_value "$1" "${2:-}")"; shift 2 ;;
    --num-sdg)                           num_sdg="$(require_option_value "$1" "${2:-}")"; shift 2 ;;
    --default-spatial-dependency)        default_spatial_dependency="$(require_option_value "$1" "${2:-}")"; shift 2 ;;
    --model-size)                        model_size="$(require_option_value "$1" "${2:-}")"; shift 2 ;;
    --num-gpus)                          num_gpus="$(require_option_value "$1" "${2:-}")"; shift 2 ;;
    --min-gpu-memory-gb)                 min_gpu_memory_gb="$(require_option_value "$1" "${2:-}")"; shift 2 ;;
    --max-iter)                          max_iter="$(require_option_value "$1" "${2:-}")"; shift 2 ;;
    --save-iter)                         save_iter="$(require_option_value "$1" "${2:-}")"; shift 2 ;;
    --use-pretrained-checkpoint)         use_pretrained_checkpoint="$(require_option_value "$1" "${2:-}")"; shift 2 ;;
    --pretrained-model-sizes)            pretrained_model_sizes="$(require_option_value "$1" "${2:-}")"; shift 2 ;;
    --key-vault-url)                     key_vault_url="$(require_option_value "$1" "${2:-}")"; shift 2 ;;
    --hf-token-secret-name|--hf-secret-name) hf_secret_name="$(require_option_value "$1" "${2:-}")"; shift 2 ;;
    --ngc-api-key-secret-name|--ngc-secret-name) ngc_secret_name="$(require_option_value "$1" "${2:-}")"; shift 2 ;;
    --image)                             image="$(require_option_value "$1" "${2:-}")"; shift 2 ;;
    --rendered-job-output)               rendered_job_output="$(require_option_value "$1" "${2:-}")"; shift 2 ;;
    --assets-only)                       assets_only=true; shift ;;
    --validate-cloud)                    validate_cloud=true; shift ;;
    --submit)                            submit_requested=true; shift ;;
    --stream)                            stream_logs=true; shift ;;
    --config-preview)                    config_preview=true; shift ;;
    -t|--tf-dir)                         tf_dir="$(require_option_value "$1" "${2:-}")"; shift 2 ;;
    --)                                  shift; [[ $# -eq 0 ]] || fatal "Forwarded az ml job create arguments are not supported; use explicit submitter options"; break ;;
    *)                                   fatal "Unknown option: $1" ;;
  esac
done

#------------------------------------------------------------------------------
# Gather Configuration
#------------------------------------------------------------------------------

if command -v jq >/dev/null 2>&1; then
  read_terraform_outputs "$tf_dir" 2>/dev/null || true
else
  warn "jq not available; Terraform output fallback is disabled"
fi

if [[ -z "$subscription_id" ]] && command -v az >/dev/null 2>&1; then
  subscription_id="$(get_subscription_id)"
fi
resource_group="${resource_group:-$(get_resource_group)}"
workspace_name="${workspace_name:-$(get_azureml_workspace)}"
compute="${compute:-$(get_compute_target)}"
hf_secret_name="$(normalize_optional_secret_name "$hf_secret_name")"
ngc_secret_name="$(normalize_optional_secret_name "$ngc_secret_name")"
raw_storage_paths=("$storage_root" "$output_prefix")
if [[ "$workflow" == "setup-glass" ]]; then
  raw_storage_paths+=("$glass_zip_path")
fi
IFS=$'\t' read -r raw_storage_account raw_storage_container < <(
  resolve_raw_storage_authority "$raw_storage_account" "$raw_storage_container" "${raw_storage_paths[@]}"
)
storage_root="$(normalize_datastore_path "$storage_root" "$raw_storage_account" "$raw_storage_container")"
output_prefix="$(normalize_datastore_path "$output_prefix" "$raw_storage_account" "$raw_storage_container")"
if [[ "$workflow" == "setup-glass" ]]; then
  glass_zip_path="$(normalize_datastore_path "$glass_zip_path" "$raw_storage_account" "$raw_storage_container")"
else
  glass_zip_path="dig/uploads/glass-zip/mobile_screen.zip"
fi
unset raw_storage_paths
pretrained_datastore="${pretrained_datastore:-$datastore}"
pretrained_storage_root="${pretrained_storage_root:-$storage_root}"
pretrained_storage_root="$(normalize_datastore_path "$pretrained_storage_root" "" "")"
cosmos_cache_datastore="${cosmos_cache_datastore:-$pretrained_datastore}"
cosmos_cache_root="$(normalize_datastore_path "$cosmos_cache_root" "" "")"
usecase="${usecase:-$(default_usecase_for_workflow "$workflow")}"
run_name="${run_name:-$(default_run_name_for_workflow "$workflow")}"
checkpoint_step="${checkpoint_step:-$(default_checkpoint_step_for_usecase "$usecase")}"
anomaly_types_json="${anomaly_types_json:-$(default_anomaly_types_for_workflow "$workflow" "$usecase")}"
default_spatial_dependency="${default_spatial_dependency:-free}"
use_pretrained_checkpoint="$(normalize_bool "--use-pretrained-checkpoint" "$use_pretrained_checkpoint")"
validate_matrix_options

if [[ "$workflow" == "day1-manual-roi" && "$use_pretrained_checkpoint" == "false" ]]; then
  fatal "day1-manual-roi with use_pretrained_checkpoint=false is not supported in Phase 8; run --workflow finetune first and stage the resulting checkpoint before inference"
fi

case "$workflow" in
  setup-pretrained)
    job_file="${job_file:-$REPO_ROOT/data-factory/workflows/azureml/dig/setup-pretrained.yaml}"
    instance_type="${instance_type:-defaultinstancetype}"
    ;;
  setup-pcb)
    job_file="${job_file:-$REPO_ROOT/data-factory/workflows/azureml/dig/setup-pcb.yaml}"
    instance_type="${instance_type:-defaultinstancetype}"
    ;;
  setup-metal)
    job_file="${job_file:-$REPO_ROOT/data-factory/workflows/azureml/dig/setup-metal.yaml}"
    instance_type="${instance_type:-defaultinstancetype}"
    ;;
  setup-glass)
    job_file="${job_file:-$REPO_ROOT/data-factory/workflows/azureml/dig/setup-glass.yaml}"
    instance_type="${instance_type:-defaultinstancetype}"
    ;;
  finetune)
    job_file="${job_file:-$REPO_ROOT/data-factory/workflows/azureml/dig/finetune.yaml}"
    instance_type="${instance_type:-h100dedicated}"
    ;;
  day1-manual-roi)
    job_file="${job_file:-$REPO_ROOT/data-factory/workflows/azureml/dig/day1-manual-roi.yaml}"
    instance_type="${instance_type:-h100dedicated}"
    ;;
  *)
    fatal "Unsupported workflow: $workflow (use: setup-pretrained, setup-pcb, setup-metal, setup-glass, finetune, day1-manual-roi)"
    ;;
esac

[[ -n "$subscription_id" ]] || fatal "--subscription-id or AZURE_SUBSCRIPTION_ID is required"
[[ -n "$resource_group" ]] || fatal "--resource-group, AZURE_RESOURCE_GROUP, or Terraform output is required"
[[ -n "$workspace_name" ]] || fatal "--workspace-name, AZUREML_WORKSPACE_NAME, or Terraform output is required"
[[ -n "$compute" ]] || fatal "--compute, AZUREML_COMPUTE, or Terraform output is required"
[[ -n "$datastore" ]] || fatal "--datastore or AZUREML_DATASTORE is required"
[[ -n "$pretrained_datastore" ]] || fatal "--pretrained-datastore or AZUREML_PRETRAINED_DATASTORE is required"
[[ -n "$cosmos_cache_datastore" ]] || fatal "--cosmos-cache-datastore or AZUREML_COSMOS_CACHE_DATASTORE is required"
[[ -n "$key_vault_url" ]] || fatal "--key-vault-url or KEY_VAULT_URL is required"
[[ -n "$hf_secret_name" ]] || fatal "--hf-token-secret-name or HF_TOKEN_SECRET_NAME is required"

validate_simple_name "--datastore" "$datastore"
validate_simple_name "--pretrained-datastore" "$pretrained_datastore"
validate_simple_name "--cosmos-cache-datastore" "$cosmos_cache_datastore"
validate_simple_name "--compute" "$compute"
validate_simple_name "--instance-type" "$instance_type"
[[ -z "$raw_storage_account" ]] || [[ "$raw_storage_account" =~ ^[a-z0-9]{3,24}$ ]] || \
  fatal "--storage-account must be a lowercase Azure Storage account name"
[[ -z "$raw_storage_container" ]] || [[ "$raw_storage_container" =~ ^[a-z0-9]([a-z0-9-]{1,61}[a-z0-9])?$ ]] || \
  fatal "--storage-container must be a valid Azure Storage container name"
validate_key_vault_url "$key_vault_url"
validate_secret_name "--hf-token-secret-name" "$hf_secret_name"
[[ -n "$ngc_secret_name" ]] && validate_secret_name "--ngc-api-key-secret-name" "$ngc_secret_name"
validate_image_reference "$image"

validate_source_inventory "$data_factory_source" "$workflow" "$usecase"
validate_local_assets "$workflow" "$job_file"

rendered_job_file="$(mktemp "${TMPDIR:-/tmp}/paidf-dig-${workflow}.XXXXXX")"
trap 'rm -f "${rendered_job_file:-}"' EXIT
render_job_file "$workflow" "$job_file" "$rendered_job_file" "$compute" "$instance_type" \
  "$datastore" "$storage_root" "$output_prefix" "$key_vault_url" "$hf_secret_name" "$ngc_secret_name" "$image" \
  "$pretrained_datastore" "$pretrained_storage_root" "$cosmos_cache_datastore" "$cosmos_cache_root" \
  "$usecase" "$run_name" "$checkpoint_step" "$anomaly_types_json" "$num_sdg" "$default_spatial_dependency" \
  "$model_size" "$num_gpus" "$min_gpu_memory_gb" "$max_iter" "$save_iter" "$use_pretrained_checkpoint" \
  "$pretrained_model_sizes" "$glass_zip_path"
validate_rendered_job "$rendered_job_file"
write_rendered_job_output "$rendered_job_file" "$rendered_job_output"

if [[ "$config_preview" == "true" ]]; then
  section "Configuration Preview"
  print_kv "Workflow" "$workflow"
  print_kv "Job Template" "$job_file"
  print_kv "Rendered Job" "$rendered_job_file"
  print_kv "Rendered Job Output" "${rendered_job_output:-<none>}"
  print_kv "Data Factory Source" "$data_factory_source"
  print_kv "Subscription" "$subscription_id"
  print_kv "Resource Group" "$resource_group"
  print_kv "Workspace" "$workspace_name"
  print_kv "Compute" "$compute"
  print_kv "Instance Type" "$instance_type"
  print_kv "Datastore" "$datastore"
  print_kv "Pretrained Datastore" "$pretrained_datastore"
  print_kv "Cosmos Cache Datastore" "$cosmos_cache_datastore"
  print_kv "Raw Storage Account" "${raw_storage_account:-<none>}"
  print_kv "Raw Storage Container" "${raw_storage_container:-<none>}"
  print_kv "Storage Root" "$storage_root"
  print_kv "Pretrained Storage Root" "$pretrained_storage_root"
  print_kv "Cosmos Cache Root" "$cosmos_cache_root"
  print_kv "Glass Zip Path" "$glass_zip_path"
  print_kv "Output Prefix" "$output_prefix"
  print_kv "Run Name" "$run_name"
  print_kv "Use Case" "$usecase"
  print_kv "Checkpoint Step" "$checkpoint_step"
  print_kv "Number Of SDG" "$num_sdg"
  print_kv "Spatial Dependency" "$default_spatial_dependency"
  print_kv "Model Size" "$model_size"
  print_kv "GPU Count" "$num_gpus"
  print_kv "Minimum GPU Memory" "$min_gpu_memory_gb GiB"
  print_kv "Max Iter" "$max_iter"
  print_kv "Save Iter" "$save_iter"
  print_kv "Use Pretrained Checkpoint" "$use_pretrained_checkpoint"
  print_kv "Pretrained Model Sizes" "$pretrained_model_sizes"
  print_kv "Key Vault URL" "$key_vault_url"
  print_kv "HF Token" "$(redacted_reference "$hf_secret_name")"
  print_kv "NGC API Key" "$(redacted_reference "$ngc_secret_name")"
  print_kv "Image" "$image"
  print_kv "Assets Only" "$assets_only"
  print_kv "Validate Cloud" "$validate_cloud"
  print_kv "Submit Requested" "$submit_requested"
  exit 0
fi

section "Asset Validation"
print_kv "Workflow" "$workflow"
print_kv "Job Template" "$job_file"
print_kv "Rendered Job" "$rendered_job_file"
print_kv "Rendered Job Output" "${rendered_job_output:-<none>}"
print_kv "Data Factory Source" "$data_factory_source"
print_kv "Run Name" "$run_name"
print_kv "Use Case" "$usecase"
print_kv "HF Token" "$(redacted_reference "$hf_secret_name")"
print_kv "NGC API Key" "$(redacted_reference "$ngc_secret_name")"
info "Rendered Azure ML job uses datastore URIs only"
print_artifact_expectations "$workflow" "$usecase" "$run_name"

if [[ "$validate_cloud" == "true" || "$submit_requested" == "true" ]]; then
  section "Read-Only Cloud Validation"
  validate_cloud_state "$subscription_id" "$resource_group" "$workspace_name" "$compute" \
    "$instance_type" "$datastore" "$key_vault_url" "$hf_secret_name" "$ngc_secret_name" "$image" \
    "$pretrained_datastore" "$cosmos_cache_datastore"
fi

if [[ "$assets_only" == "true" ]]; then
  section "Deployment Summary"
  print_kv "Workflow" "$workflow"
  print_kv "Use Case" "$usecase"
  print_kv "Run Name" "$run_name"
  print_kv "Mode" "Assets only"
  print_kv "Compute" "$compute"
  print_kv "Instance Type" "$instance_type"
  print_kv "Datastore" "$datastore"
  print_kv "Pretrained Datastore" "$pretrained_datastore"
  print_kv "Cosmos Cache Datastore" "$cosmos_cache_datastore"
  print_kv "Workspace" "$workspace_name"
  info "Assets validated; no job submitted per --assets-only"
  exit 0
fi

if [[ "$submit_requested" != "true" ]]; then
  [[ "$stream_logs" == "true" ]] && warn "--stream has no effect without --submit"
  section "Deployment Summary"
  print_kv "Workflow" "$workflow"
  print_kv "Use Case" "$usecase"
  print_kv "Run Name" "$run_name"
  print_kv "Mode" "Validation only"
  print_kv "Compute" "$compute"
  print_kv "Instance Type" "$instance_type"
  print_kv "Datastore" "$datastore"
  print_kv "Pretrained Datastore" "$pretrained_datastore"
  print_kv "Cosmos Cache Datastore" "$cosmos_cache_datastore"
  print_kv "Workspace" "$workspace_name"
  info "No job submitted; pass --submit to create an Azure ML job"
  exit 0
fi

#------------------------------------------------------------------------------
# Submit Job
#------------------------------------------------------------------------------

require_tools az
ensure_ml_extension

az_args=(
  az ml job create
  --resource-group "$resource_group"
  --workspace-name "$workspace_name"
  --subscription "$subscription_id"
  --file "$rendered_job_file"
)

az_args+=(--set "code=$REPO_ROOT/data-factory")

az_args+=(--query "name" -o "tsv")

for az_arg in "${az_args[@]}"; do
  validate_job_environment_override "$az_arg"
done

info "Submitting Azure ML DIG job..."
job_result="$("${az_args[@]}")" || fatal "Job submission failed"

info "Job submitted: $job_result"
info "Portal: https://ml.azure.com/runs/$job_result?wsid=/subscriptions/$subscription_id/resourceGroups/$resource_group/providers/Microsoft.MachineLearningServices/workspaces/$workspace_name"

if [[ "$stream_logs" == "true" ]]; then
  info "Streaming job logs (Ctrl+C to stop)..."
  az ml job stream --name "$job_result" \
    --resource-group "$resource_group" --workspace-name "$workspace_name" || true
fi

section "Deployment Summary"
print_kv "Job Name" "$job_result"
print_kv "Workflow" "$workflow"
print_kv "Use Case" "$usecase"
print_kv "Run Name" "$run_name"
print_kv "Compute" "$compute"
print_kv "Instance Type" "$instance_type"
print_kv "Datastore" "$datastore"
print_kv "Pretrained Datastore" "$pretrained_datastore"
print_kv "Cosmos Cache Datastore" "$cosmos_cache_datastore"
print_kv "Workspace" "$workspace_name"
exit 0
