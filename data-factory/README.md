---
description: Azure ML DIG operator guide for setup, finetune, Day 0, and Day 1 workflows
ms.date: 2026-06-11
ms.topic: how-to
---

<!-- cspell:ignore abin CIFS GiB NIMService NVPCB OVSL Roboflow dinov vLLM -->

# Data Factory Azure ML Workflows

Azure ML assets in this directory run NVIDIA physical-ai-data-factory Defect Image Generation workflows on the toolchain AKS cluster attached to Azure ML. Use this README as the operator entrypoint for data preparation, secrets, endpoint checks, workflow order, validation, and live submissions while preserving the NVIDIA OSMO workflow route.

## 📋 Prerequisites

| Requirement                  | Value or command                                                                             |
|------------------------------|----------------------------------------------------------------------------------------------|
| Azure CLI                    | `az login`                                                                                   |
| Azure ML CLI extension       | `az extension add --name ml`                                                                 |
| Bash, `kubectl`, `jq`        | Required for submitter commands, cluster checks, and JSON probes                             |
| Kubernetes access            | `az aks get-credentials --resource-group <resource-group> --name <aks-name>`                 |
| Private cluster access       | Connect VPN before direct `kubectl` or private ADLS checks                                   |
| NVIDIA data factory checkout | Local clone of `NVIDIA/physical-ai-data-factory`, passed with `--data-factory-source`        |
| Azure ML workspace           | Existing workspace with AKS attached as Kubernetes compute                                   |
| Azure ML compute             | Attached AKS compute, for example `<attached-compute-name>`                                  |
| Generated data datastore     | `datasets`                                                                                  |
| Pretrained input datastore   | `datasets` for setup-pretrained outputs, or `osmo_datasets` for compatible legacy caches     |
| Key Vault                    | Runtime secret source, for example `https://<key-vault-name>.vault.azure.net`                |
| Hugging Face token secret    | Key Vault secret name, default `paidf-hf-token`                                              |
| NGC API key secret           | Optional Key Vault secret name, default `none`                                               |
| H100 InstanceType            | `h100spot` for validated H100 spot runs, `h100dedicated` for the dedicated H100 route        |
| Image-Edit endpoint          | Required for Day 0. Must serve `nvidia/Qwen-Image-Edit-NVPCB-OVSL2SL`                       |

The validated live route uses attached AKS compute, `datasets` for generated ADLS artifacts, `osmo_datasets` for compatible blob-backed cache inputs, and Key Vault secret `paidf-hf-token`.

## 🔎 Preflight

Validate the Azure ML and Kubernetes control plane before rendering or submitting jobs. Use placeholders for documentation examples, then replace them with the target workspace values at runtime.

```bash
az account show --query '{name:name,id:id,tenantId:tenantId}' -o table

az ml workspace show \
  --resource-group <resource-group> \
  --name <workspace-name> \
  --query '{name:name,location:location}' \
  -o table

az ml compute show \
  --resource-group <resource-group> \
  --workspace-name <workspace-name> \
  --name <compute-name> \
  --query '{name:name,type:type,provisioningState:provisioningState}' \
  -o table

az ml datastore show \
  --resource-group <resource-group> \
  --workspace-name <workspace-name> \
  --name datasets \
  --query '{name:name,type:type}' \
  -o table

kubectl get instancetypes.amlarc.azureml.com
```

If the Azure ML Kubernetes compute is missing, run the Azure ML extension setup before submitting DIG jobs:

```bash
source infrastructure/terraform/prerequisites/az-sub-init.sh
infrastructure/setup/02-deploy-azureml-extension.sh --config-preview
infrastructure/setup/02-deploy-azureml-extension.sh
```

For private clusters where the local Kubernetes API route is unavailable, run read-only Kubernetes checks through `az aks command invoke` or reconnect VPN before using direct `kubectl` commands.

## 🧭 Workflow Status

| Workflow                    | Status                            | Required inputs                                                | Output root shape                                      |
|-----------------------------|-----------------------------------|----------------------------------------------------------------|--------------------------------------------------------|
| `setup-pretrained`          | Live validated                    | Hugging Face gated pretrained repos                            | `<output-prefix>/models/pretrained`                    |
| `setup-pcb`                 | Live validated                    | Hugging Face PCBA checkpoint, dataset, and USD repos           | `<output-prefix>/models`, `raw_dataset`, `assets`      |
| `setup-metal`               | Live validated                    | Hugging Face metal checkpoint and public metal raw dataset     | `<output-prefix>/models`, `raw_dataset`                |
| `setup-glass`               | Live validated                    | Roboflow Mobile Screen ZIP plus Hugging Face glass repos       | `<output-prefix>/models/glass`, `datasets/glass/raw`   |
| `finetune`                  | Live validated with bounded run   | `setup-pretrained` and `setup-pcb` outputs                     | `<output-prefix>/finetune/finetune`                    |
| `day1-manual-roi`           | Live validated for PCB, metal, glass | Setup output for selected use case plus pretrained output   | `<output-prefix>/day1-manual-roi`                      |
| `day1-real-photo-alignment` | Live validated for PCBA           | `setup-pcb` assets, `setup-pretrained` output, real image, USD scene | `<output-prefix>/day1-usd2roi`, `anomaly`        |
| `day0-texture-defects`      | Live validated                     | `setup-pcb`, `setup-pretrained`, exact Image-Edit endpoint  | `<output-prefix>/day0-usd2roi`, `day0-image-edit`, `anomaly` |
| `day0-good-image`           | Live validated                     | `setup-pcb`, exact Image-Edit endpoint                      | `<output-prefix>/day0-usd2roi`, `day0-image-edit`      |
| `day0-structural-defects`   | Live validated                     | `setup-pcb`, exact Image-Edit endpoint                      | `<output-prefix>/structural-render`, `structural-image-edit` |

> [!IMPORTANT]
> Day 0 workflows must not use a generic Qwen image-edit service. Validate `/v1/models` and require the exact model ID `nvidia/Qwen-Image-Edit-NVPCB-OVSL2SL` before live submission.

## 🧩 Image-Edit Endpoint

Day 0 workflows require the NVIDIA Qwen Image-Edit NVPCB OVSL2SL endpoint in the same cluster network as the Azure ML worker pods. Use the NVIDIA NIMService manifest from the physical-ai-data-factory checkout and verify the OpenAI-compatible `/v1/models` response before submitting Azure ML jobs.

| Requirement       | Value                                                                                  |
|-------------------|----------------------------------------------------------------------------------------|
| Namespace         | `osmo-nims`                                                                            |
| NIMService name   | `qwen-image-edit-nvpcb-ovsl2sl`                                                        |
| Model ID          | `nvidia/Qwen-Image-Edit-NVPCB-OVSL2SL`                                                 |
| Service endpoint  | `http://qwen-image-edit-nvpcb-ovsl2sl.osmo-nims.svc.cluster.local:8000/v1`             |
| HF token secret   | Kubernetes secret `hf-token-secret` with key `HF_TOKEN`; token account must have access to the gated Qwen model |
| NGC secret        | Kubernetes secret `ngc-api-secret`, required by the NIMService auth configuration      |
| Runtime image     | `vllm/vllm-omni:v0.20.0` from the NVIDIA manifest                                      |
| Model cache       | 150 GiB persistent volume mounted at `/model-store`                                    |
| Startup timeouts  | `--stage-init-timeout 1800 --init-timeout 1800`                                        |

Create the namespace and token secrets before applying the manifest. Do not source `.env.local` for these commands, and do not paste token values into shell history; use files from an approved secret store or direct terminal input.

```bash
kubectl create namespace osmo-nims --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic hf-token-secret \
  --namespace osmo-nims \
  --from-file=HF_TOKEN=/path/to/hf-token.txt \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic ngc-api-secret \
  --namespace osmo-nims \
  --from-file=NGC_API_KEY=/path/to/non-sensitive-placeholder.txt \
  --dry-run=client -o yaml | kubectl apply -f -
```

For this vLLM-based Image-Edit endpoint only, the manifest requires an `ngc-api-secret` object but model access uses `HF_TOKEN`. Create `ngc-api-secret` from a non-sensitive placeholder file instead of placing a personal NGC key in shared cluster state. Replace the placeholder with a service-owned NGC key before deploying official NGC-backed NIMs that require NGC authentication.

Apply the NVIDIA manifest directly when the cluster storage class supports `ReadWriteMany` volumes:

```bash
kubectl apply -f <nvidia-data-factory>/skills/physical-ai-defect-image-generation/references/nim/qwen-image-edit-nvpcb-ovsl2sl.yaml
```

On AKS clusters where the default `ReadWriteMany` Azure Files volume fails with CIFS `Permission denied`, run a single-replica endpoint with Azure Disk by patching the manifest at apply time. This keeps the NVIDIA image, command, model ID, secrets, mount paths, and service name unchanged while switching the cache PVC to `ReadWriteOnce`.

The validated AKS route used the Azure Disk `ReadWriteOnce` cache and the 1800-second vLLM startup timeouts. Keep both settings in place for first startup, when the model cache is empty and `/v1/models` is not ready until the full model load completes.

```bash
kubectl apply -f <(awk '
  /size: "150Gi"/ {
    print
    print "      storageClass: default"
    next
  }
  /volumeAccessMode: ReadWriteMany/ {
    print "      volumeAccessMode: ReadWriteOnce"
    next
  }
  { print }
' <nvidia-data-factory>/skills/physical-ai-defect-image-generation/references/nim/qwen-image-edit-nvpcb-ovsl2sl.yaml)
```

Watch the pod until the model finishes downloading and vLLM starts serving. The first startup downloads roughly tens of GiB of model blobs and can take several minutes.

```bash
kubectl -n osmo-nims get nimservice,deploy,pod,pvc \
  -l app.kubernetes.io/name=qwen-image-edit-nvpcb-ovsl2sl

pod=$(kubectl -n osmo-nims get pod \
  -l app.kubernetes.io/name=qwen-image-edit-nvpcb-ovsl2sl \
  -o jsonpath='{.items[0].metadata.name}')

kubectl -n osmo-nims logs "$pod" --tail=200
kubectl -n osmo-nims exec "$pod" -- df -h /model-store /dev/shm
```

Proceed only after the pod is ready and the exact model identity probe returns `OK` from inside the cluster.

```bash
kubectl run qwen-models-check -n osmo-nims --rm -i --restart=Never \
  --image=curlimages/curl --command -- sh -c \
  'curl -fsS --max-time 20 http://qwen-image-edit-nvpcb-ovsl2sl.osmo-nims.svc.cluster.local:8000/v1/models | grep -q "nvidia/Qwen-Image-Edit-NVPCB-OVSL2SL" && echo OK || echo NOT_READY'
```

Use the service URL and exact model ID in all Day 0 submissions:

```bash
day0_image_edit_args=(--image-edit-endpoint http://qwen-image-edit-nvpcb-ovsl2sl.osmo-nims.svc.cluster.local:8000/v1)
day0_image_edit_args+=(--image-edit-model nvidia/Qwen-Image-Edit-NVPCB-OVSL2SL)
```

## 📦 Source Data

Accept gated licenses once with the Hugging Face account tied to the Key Vault token before running live jobs. Use the same approved Hugging Face account for the Qwen `hf-token-secret`, or use a service-owned account that has accepted the same gated repository terms.

| Data                     | Source                                                                                           | Operator action |
|--------------------------|--------------------------------------------------------------------------------------------------|-----------------|
| Pretrained Cosmos bundle | Hugging Face `nvidia/Cosmos-Predict2-2B-Text2Image` plus public pretrained providers             | Run `setup-pretrained`; use this output for Finetune Only and Day 1 workflows |
| PCBA data                | Hugging Face `nvidia/Cosmos-AnomalyGen-PCB-2B`, `nvidia/Cosmos-AnomalyGen-PCB-Dataset`, `nvidia/Spark-AnomalyGen-USD` | Run `setup-pcb` before PCBA workflows |
| Metal data               | Hugging Face metal checkpoint plus public magnetic-tile raw data used by NVIDIA setup scripts    | Run `setup-metal` before metal Day 1 manual ROI |
| Glass model and masks    | Hugging Face `nvidia/Cosmos-AnomalyGen-Glass-2B` and `nvidia/Cosmos-AnomalyGen-Glass-Masks`      | Accept licenses and run `setup-glass` |
| Glass raw images         | Roboflow Mobile Screen export                                                                    | Follow NVIDIA [docs/workflows/physical-ai-defect-image-generation/media/glass_dataset_download_instructions.md](https://github.com/NVIDIA/physical-ai-data-factory/blob/main/docs/workflows/physical-ai-defect-image-generation/media/glass_dataset_download_instructions.md), rename the export to `mobile_screen.zip`, and stage it |
| Day 1 real photo         | `setup-pcb` output asset `input_real_image/0603_H100.jpg`                                        | Use default `--real-image-filename input_real_image/0603_H100.jpg` unless validating another board image |

The Hugging Face account behind the Key Vault token and Qwen Kubernetes secret must be able to read these gated NVIDIA repositories:

| Repository | Required by | Notes |
|------------|-------------|-------|
| `nvidia/Cosmos-Predict2-2B-Text2Image` | `setup-pretrained`, Finetune Only, Day 1, Day 0 texture defects | Default validated pretrained model size |
| `nvidia/Cosmos-Predict2-14B-Text2Image` | `setup-pretrained` | Required only when `--pretrained-model-sizes "2B 14B"` or `DIG_PRETRAINED_MODEL_SIZES="2B 14B"` is used |
| `nvidia/Cosmos-AnomalyGen-PCB-2B` | `setup-pcb`, PCBA Day 1 and Day 0 texture defects | PCBA AnomalyGen checkpoint |
| `nvidia/Cosmos-AnomalyGen-Metal-2B` | `setup-metal`, metal Day 1 manual ROI | Metal AnomalyGen checkpoint |
| `nvidia/Cosmos-AnomalyGen-Glass-2B` | `setup-glass`, glass Day 1 manual ROI | Glass AnomalyGen checkpoint |
| `nvidia/Cosmos-AnomalyGen-PCB-Dataset` | `setup-pcb` | PCBA raw dataset |
| `nvidia/Spark-AnomalyGen-USD` | `setup-pcb`, Day 0, Day 1 real-photo alignment | PCBA USD assets and board reference images |
| `nvidia/Cosmos-AnomalyGen-Glass-Masks` | `setup-glass` | Glass masks and defect specification overlays |
| `nvidia/Qwen-Image-Edit-NVPCB-OVSL2SL` | Qwen Image-Edit endpoint, Day 0 workflows | Exact OVSL2SL endpoint model; generic Qwen Image-Edit is not a substitute |

The pretrained setup also downloads public Hugging Face providers, including `nvidia/C-RADIOv3-B`, `google-t5/t5-large`, and `facebook/dinov2-large`. They do not require gated NVIDIA license acceptance. The metal raw dataset comes from the public GitHub `abin24/Magnetic-tile-defect-datasets` repository. Compatible legacy caches may contain other Cosmos repositories, but they are not required for the validated Azure ML DIG setup path.

The glass ZIP is not redistributed with the NVIDIA checkout. The validated setup used `dig/uploads/glass-zip/mobile_screen.zip` in the `datasets` datastore. No manual extraction is required; `setup-glass` extracts `Phone/anomaly_image/` and `Phone/clean_image/`, then pulls masks and `defect_spec.jsonl` from Hugging Face.

```bash
az storage fs directory create \
  --account-name <adls-account> \
  --file-system datasets \
  --name dig/uploads/glass-zip \
  --auth-mode login

az storage fs file upload \
  --account-name <adls-account> \
  --file-system datasets \
  --path dig/uploads/glass-zip/mobile_screen.zip \
  --source /path/to/mobile_screen.zip \
  --auth-mode login \
  --overwrite true

az storage fs file show \
  --account-name <adls-account> \
  --file-system datasets \
  --path dig/uploads/glass-zip/mobile_screen.zip \
  --auth-mode login \
  --query '{name:name,size:size,isDirectory:isDirectory}'
```

## 🔐 Secret Setup

Store token values in Key Vault and pass only secret names to the submitter. Do not pass token values through CLI arguments, rendered YAML, checked-in files, or Azure ML `--set` overrides.

Azure ML jobs read Hugging Face and optional NGC credentials from Key Vault at runtime. The Qwen Image-Edit endpoint reads Kubernetes secrets because it runs as an in-cluster service, not as an Azure ML job.

Do not keep raw `HF_TOKEN`, `HUGGING_FACE_HUB_TOKEN`, or `NGC_API_KEY` values in `.env.local` for this Azure ML route. Move the Hugging Face token to Key Vault, use a Kubernetes `hf-token-secret` only for the Qwen endpoint, and use a non-sensitive `ngc-api-secret` placeholder unless an official NGC-backed endpoint requires a service-owned NGC key.

The Hugging Face token must come from an account with access to every gated NVIDIA repository used by the selected workflows, including setup models, pretrained bundles, glass masks, PCBA assets, and Qwen Image-Edit. For shared deployments, create a service-owned Hugging Face account, accept or request the same gated repository access, then rotate both Key Vault `paidf-hf-token` and Kubernetes `hf-token-secret` to that service token.

```bash
read -r -s HF_TOKEN
tmp=$(mktemp)
printf '%s' "$HF_TOKEN" > "$tmp"
az keyvault secret set --vault-name <key-vault-name> --name paidf-hf-token --file "$tmp"
rm -f "$tmp"; unset HF_TOKEN tmp

vault_scope=$(az keyvault show --name <key-vault-name> --query id -o tsv)
az role assignment create --assignee <managed-identity-principal-id> --role "Key Vault Secrets User" --scope "$vault_scope"
az keyvault secret show --vault-name <key-vault-name> --name paidf-hf-token --query id -o tsv
```

Set `paidf-ngc-api-key` the same way only when an NVIDIA image or endpoint deployment requires NGC authentication. Successful AML user logs include `HF_TOKEN loaded` without printing the token value.

## ⚙️ Environment

Use CLI arguments for reviewable runs. For repeated local use, put only non-secret defaults in `.env.local`; the submitter sources it only for `--submit` and strips token-shaped environment variables before rendering jobs.

```bash
export AZURE_SUBSCRIPTION_ID=<subscription-id>
export AZURE_RESOURCE_GROUP=<resource-group>
export AZUREML_WORKSPACE_NAME=<workspace-name>
export AZUREML_COMPUTE_NAME=<compute-name>
export KEY_VAULT_URL=https://<key-vault-name>.vault.azure.net
export HF_TOKEN_SECRET_NAME=paidf-hf-token
export NGC_API_KEY_SECRET_NAME=none
export DATA_FACTORY_SOURCE=../physical-ai-data-factory
export DIG_STORAGE_ACCOUNT=<storage-account>
export DIG_STORAGE_CONTAINER=datasets
export DIG_GLASS_ZIP_PATH=dig/uploads/glass-zip/mobile_screen.zip
```

| Option                      | Purpose |
|-----------------------------|---------|
| `--workflow`                | Selects any setup, Finetune, Day 0, or Day 1 workflow listed above |
| `--usecase`                 | Selects `pcb`, `metal_surface`, or `glass` where supported |
| `--instance-type`           | Overrides the workflow InstanceType. Use `h100spot` for validated H100 spot execution |
| `--datastore`               | Stores generated setup and run artifacts |
| `--pretrained-datastore`    | Reads setup-pretrained output or compatible pretrained cache artifacts |
| `--pretrained-storage-root` | Datastore root whose child path is `models/pretrained` |
| `--cosmos-cache-datastore`  | Reads reusable Cosmos cache artifacts for Day 1 manual ROI |
| `--cosmos-cache-root`       | Datastore root for reusable Cosmos cache artifacts |
| `--glass-zip-path`          | Datastore path to staged `mobile_screen.zip` for `setup-glass` |
| `--storage-root`            | Datastore path for setup outputs or workflow inputs |
| `--output-prefix`           | Datastore path for run outputs |
| `--board`                   | PCBA cookbook board. `0603_H100` is the validated NVIDIA board asset, not a GPU requirement |
| `--scene-filename`          | USD scene under setup-pcb assets. Default validated scene is `spark_lighting.usd` |
| `--real-image-filename`     | Real image under setup-pcb assets for Day 1 real-photo alignment |
| `--image-edit-endpoint`     | OpenAI-compatible endpoint for Day 0 Image-Edit stages |
| `--image-edit-model`        | Exact model ID for Day 0 Image-Edit stages |
| `--max-iter`, `--save-iter` | Finetune iteration and checkpoint overrides. `0` keeps NVIDIA cookbook defaults |
| `--assets-only`             | Validates local assets without cloud calls |
| `--validate-cloud`          | Runs read-only Azure ML, Key Vault, datastore, and InstanceType checks |
| `--config-preview`          | Prints a redacted configuration and exits without submitting work |
| `--submit`, `--stream`      | Submits the rendered job and optionally streams logs |

Arguments after `--` are rejected so secret-bearing Azure ML overrides cannot bypass local validation.

## 🚀 Quick Start

Use one unique run ID and carry setup output roots into dependent workflows. Keep these roots in your shell history or notes; downstream jobs do not discover them automatically.

```bash
run_id=$(date -u +%Y%m%d%H%M%S)
setup_pretrained_root="dig/runs/setup-pretrained-$run_id"
setup_pcb_root="dig/runs/setup-pcb-$run_id"
setup_metal_root="dig/runs/setup-metal-$run_id"
setup_glass_root="dig/runs/setup-glass-$run_id"

az ml workspace show --resource-group <resource-group> --name <workspace-name> -o table
az ml compute show --name <compute-name> --resource-group <resource-group> --workspace-name <workspace-name> -o table
az ml datastore list --resource-group <resource-group> --workspace-name <workspace-name> -o table
kubectl get instancetypes.amlarc.azureml.com

common_args=(
  --data-factory-source ../physical-ai-data-factory --resource-group <resource-group>
  --workspace-name <workspace-name> --compute <compute-name> --instance-type h100spot
  --datastore datasets --key-vault-url https://<key-vault-name>.vault.azure.net
  --hf-token-secret-name paidf-hf-token
)

preview_args=(--workflow setup-pcb --output-prefix "$setup_pcb_root")
data-factory/scripts/submit-azureml-dig.sh "${common_args[@]}" "${preview_args[@]}" \
  --rendered-job-output /tmp/paidf-dig-setup-pcb.yaml --validate-cloud --config-preview

az ml job validate \
  --file /tmp/paidf-dig-setup-pcb.yaml \
  --resource-group <resource-group> \
  --workspace-name <workspace-name>
```

Run `--assets-only --config-preview` first when changing board, scene, endpoint, datastore, or root paths. Add `--validate-cloud --config-preview` before live submission to verify the workspace, compute, datastore, Key Vault, and InstanceType references without launching work. Start live submissions from the ordered setup commands below so dependent roots exist before downstream workflows run.

## 🧭 Run Order

| Order | Workflow | Required before running |
|-------|----------|-------------------------|
| 1 | `setup-pretrained` | Hugging Face licenses and Key Vault HF token |
| 2 | `setup-pcb` | Hugging Face licenses and Key Vault HF token |
| 3 | `setup-metal` | Hugging Face licenses and Key Vault HF token |
| 4 | `setup-glass` | Roboflow Mobile Screen ZIP staged at `--glass-zip-path` |
| 5 | `finetune` | `setup-pretrained` and `setup-pcb` roots |
| 6 | `day1-manual-roi` | Setup root for selected use case and `setup-pretrained` root |
| 7 | `day1-real-photo-alignment` | `setup-pcb` and `setup-pretrained` roots |
| 8 | Day 0 workflows | `setup-pcb` root and exact Qwen Image-Edit endpoint; texture defects also require `setup-pretrained` root |

## 🧱 Workflow Runs

Run setup workflows before dependent jobs. Use a unique `--output-prefix` for each setup run.

```bash
data-factory/scripts/submit-azureml-dig.sh "${common_args[@]}" \
  --workflow setup-pretrained \
  --output-prefix "$setup_pretrained_root" \
  --validate-cloud --submit

data-factory/scripts/submit-azureml-dig.sh "${common_args[@]}" \
  --workflow setup-pcb \
  --output-prefix "$setup_pcb_root" \
  --validate-cloud --submit

data-factory/scripts/submit-azureml-dig.sh "${common_args[@]}" \
  --workflow setup-metal \
  --output-prefix "$setup_metal_root" \
  --validate-cloud --submit

glass_setup_args=(--workflow setup-glass --usecase glass)
glass_setup_args+=(--glass-zip-path dig/uploads/glass-zip/mobile_screen.zip)
glass_setup_args+=(--output-prefix "$setup_glass_root")
data-factory/scripts/submit-azureml-dig.sh "${common_args[@]}" "${glass_setup_args[@]}" --validate-cloud --submit
```

Run Finetune Only and Day 1 workflows after setup outputs exist:

```bash
finetune_args=(--workflow finetune --pretrained-datastore datasets)
finetune_args+=(--pretrained-storage-root "$setup_pretrained_root")
finetune_args+=(--storage-root "$setup_pcb_root" --output-prefix "dig/runs/finetune-$run_id")
data-factory/scripts/submit-azureml-dig.sh "${common_args[@]}" "${finetune_args[@]}" --max-iter 2000 --save-iter 2000 --submit

manual_roi_args=(--workflow day1-manual-roi --usecase pcb --pretrained-datastore datasets)
manual_roi_args+=(--pretrained-storage-root "$setup_pretrained_root")
manual_roi_args+=(--storage-root "$setup_pcb_root" --output-prefix "dig/runs/day1-manual-roi-pcb-$run_id")
data-factory/scripts/submit-azureml-dig.sh "${common_args[@]}" "${manual_roi_args[@]}" --submit --stream

metal_roi_args=(--workflow day1-manual-roi --usecase metal_surface --pretrained-datastore datasets)
metal_roi_args+=(--pretrained-storage-root "$setup_pretrained_root")
metal_roi_args+=(--storage-root "$setup_metal_root" --output-prefix "dig/runs/day1-manual-roi-metal-$run_id")
data-factory/scripts/submit-azureml-dig.sh "${common_args[@]}" "${metal_roi_args[@]}" --submit --stream

glass_roi_args=(--workflow day1-manual-roi --usecase glass --pretrained-datastore datasets)
glass_roi_args+=(--pretrained-storage-root "$setup_pretrained_root")
glass_roi_args+=(--storage-root "$setup_glass_root" --output-prefix "dig/runs/day1-manual-roi-glass-$run_id")
data-factory/scripts/submit-azureml-dig.sh "${common_args[@]}" "${glass_roi_args[@]}" --submit --stream

real_align_args=(--workflow day1-real-photo-alignment --pretrained-datastore datasets)
real_align_args+=(--pretrained-storage-root "$setup_pretrained_root")
real_align_args+=(--storage-root "$setup_pcb_root")
real_align_args+=(--output-prefix "dig/runs/day1-real-photo-alignment-$run_id")
real_align_args+=(--board 0603_H100 --scene-filename spark_lighting.usd)
real_align_args+=(--real-image-filename input_real_image/0603_H100.jpg)
data-factory/scripts/submit-azureml-dig.sh "${common_args[@]}" "${real_align_args[@]}" --instance-type h100spot --submit --stream
```

Use `--usecase metal_surface` with `setup-metal`, or `--usecase glass` with `setup-glass`, for non-PCB Day 1 manual ROI. Day 1 real-photo alignment uses `paidf-simulation` for render, registration, and crop, then `paidf-anomalygen` for inference. Kit-backed simulation stages use `DIG_AML_KIT_TIMEOUT_SECONDS=1200` to bound Isaac Sim hangs.

Day 0 workflows require the exact Image-Edit endpoint before live submission:

```bash
curl -sS <image-edit-endpoint>/v1/models | jq -r '.data[].id'

day0_texture_args=(--workflow day0-texture-defects --pretrained-datastore datasets)
day0_texture_args+=(--pretrained-storage-root "$setup_pretrained_root")
day0_texture_args+=(--storage-root "$setup_pcb_root")
day0_texture_args+=(--output-prefix "dig/runs/day0-texture-defects-$run_id")
day0_texture_args+=(--image-edit-endpoint <image-edit-endpoint>)
day0_texture_args+=(--image-edit-model nvidia/Qwen-Image-Edit-NVPCB-OVSL2SL)
data-factory/scripts/submit-azureml-dig.sh "${common_args[@]}" "${day0_texture_args[@]}" --submit --stream

day0_good_args=(--workflow day0-good-image)
day0_good_args+=(--storage-root "$setup_pcb_root")
day0_good_args+=(--output-prefix "dig/runs/day0-good-image-$run_id")
day0_good_args+=(--image-edit-endpoint <image-edit-endpoint>)
day0_good_args+=(--image-edit-model nvidia/Qwen-Image-Edit-NVPCB-OVSL2SL)
data-factory/scripts/submit-azureml-dig.sh "${common_args[@]}" "${day0_good_args[@]}" --submit --stream

day0_structural_args=(--workflow day0-structural-defects)
day0_structural_args+=(--storage-root "$setup_pcb_root")
day0_structural_args+=(--output-prefix "dig/runs/day0-structural-defects-$run_id")
day0_structural_args+=(--image-edit-endpoint <image-edit-endpoint>)
day0_structural_args+=(--image-edit-model nvidia/Qwen-Image-Edit-NVPCB-OVSL2SL)
day0_structural_args+=(--render-patches 5 --defect-modes all --crop-offset 10)
data-factory/scripts/submit-azureml-dig.sh "${common_args[@]}" "${day0_structural_args[@]}" --submit --stream
```

Use `--crop-max-emit` for Day 0 USD-to-ROI crop limits. Use `--assets-only --config-preview` with any argument array before submission to verify local cookbooks, stage runners, and rendered paths without starting Azure ML work.

## 🔍 Validation And Artifacts

Every live validation follows the same ladder:

| Stage                 | Command or check                                                                       |
|-----------------------|----------------------------------------------------------------------------------------|
| Local assets          | `data-factory/scripts/submit-azureml-dig.sh ... --assets-only`                         |
| Render preview        | `data-factory/scripts/submit-azureml-dig.sh ... --rendered-job-output <file> --config-preview` |
| Azure ML schema       | `az ml job validate --file <rendered-file> --resource-group <rg> --workspace-name <workspace>` |
| Cloud preflight       | `data-factory/scripts/submit-azureml-dig.sh ... --validate-cloud --config-preview`     |
| Live completion       | `az ml job show --name <job-name> --query '{name:name,status:status,error:error}'`      |
| Artifact verification | `az storage fs file list` or `az storage blob list` on the output root                  |

| Workflow                    | Required evidence                                                                      |
|-----------------------------|----------------------------------------------------------------------------------------|
| `setup-pretrained`          | `artifact_manifest.txt` plus non-empty pretrained provider subtrees                    |
| `setup-pcb`                 | `ag_config.yaml`, `iter_*.pt`, `defect_spec.jsonl`, USD assets, real image, `artifact_manifest.txt` |
| `setup-metal`               | `ag_config.yaml`, `iter_*.pt`, `defect_spec.jsonl`, non-empty raw data                 |
| `setup-glass`               | `ag_config.yaml`, `iter_*.pt`, `defect_spec.jsonl`, `Phone/` dataset tree, `artifact_manifest.txt` |
| `finetune`                  | `validation.jsonl`, `best_step.txt`, `iter_*.pt`, validation images, `artifact_manifest.txt` |
| `day1-manual-roi`           | `verify_output.sh` success, `artifact_manifest.txt`, `SDG_result.csv`, images, `inference_daft_v3/` |
| `day1-real-photo-alignment` | Aligned ROI crops, `verify_output.sh` success, `artifact_manifest.txt`, `SDG_result.csv`, images, `inference_daft_v3/` |
| `day0-texture-defects`      | ROI crops, Image-Edit outputs, anomaly outputs, `verify_output.sh` success, `artifact_manifest.txt` |
| `day0-good-image`           | ROI crops, Image-Edit outputs, `artifact_manifest.txt`                                 |
| `day0-structural-defects`   | Structural RGB crops, Image-Edit outputs, `artifact_manifest.txt`                      |

Inspect active Azure ML jobs before starting expensive work:

```bash
az ml job list \
  --resource-group <resource-group> \
  --workspace-name <workspace-name> \
  --query "[?contains(['Running','Queued','Preparing','Starting'], status)].{name:name,status:status}" \
  -o table
```

## 🧪 Tested Results

Live Azure ML validation on the attached AKS compute proved these paths:

| Workflow                    | Live result                                                                                                           |
|-----------------------------|-----------------------------------------------------------------------------------------------------------------------|
| `setup-pretrained`          | Completed and produced Cosmos Predict2 2B pretrained layout in `datasets`                                             |
| `setup-pcb`                 | Completed and produced PCBA checkpoints, raw dataset, USD assets, and the default `0603_H100` real image              |
| `setup-metal`               | Completed and produced metal checkpoint and raw dataset artifacts                                                     |
| `setup-glass`               | Completed and produced glass checkpoint and raw Mobile Screen dataset artifacts                                       |
| `day1-manual-roi`           | Completed for PCB, metal, and glass paths, with expected TAO DAFT output counts                                      |
| `day1-real-photo-alignment` | Completed as an Azure ML pipeline; verified 25 USD-to-ROI objects and 288 anomaly objects                            |
| `finetune`                  | Completed a bounded PCB run with Key Vault, H100, `/dev/shm`, checkpoint, manifest, and validation-image verification |
| `day0-good-image`           | Completed with exact Qwen Image-Edit endpoint; verified 30 USD-to-ROI objects and 5 Image-Edit objects               |
| `day0-texture-defects`      | Completed with exact Qwen Image-Edit endpoint; verified 73 USD-to-ROI objects, 25 Image-Edit objects, and 287 anomaly objects |
| `day0-structural-defects`   | Completed with exact Qwen Image-Edit endpoint; verified 76 structural render objects and 22 structural Image-Edit objects |

The Day 0 live validations used the exact `nvidia/Qwen-Image-Edit-NVPCB-OVSL2SL` model, verified `/v1/models` from inside the cluster, and checked ADLS output counts after Azure ML completion.

## 🧭 Troubleshooting

| Symptom                                                       | Fix                                                                        |
|---------------------------------------------------------------|----------------------------------------------------------------------------|
| `HF_TOKEN loaded` does not appear in logs                     | Check Key Vault URL, secret name, and `Key Vault Secrets User` permission  |
| Hugging Face downloads fail with access errors                | Accept the gated NVIDIA license with the account tied to the Key Vault token |
| Finetune fails with `/dev/shm` too small                      | Ensure the rendered job includes `resources.shm_size: 32g`                 |
| Finetune cannot find `Cosmos-Predict2-2B-Text2Image/model.pt` | Use a successful `setup-pretrained` output as `--pretrained-storage-root`  |
| `setup-glass` cannot find `mobile_screen.zip`                 | Follow the Roboflow export instructions, rename the ZIP, and stage it at `--glass-zip-path` |
| Direct ADLS checks return network or authorization errors     | Connect VPN for private network access and use `--auth-mode login`         |
| Day 0 fails endpoint identity checks                          | Restore or provide an endpoint whose `/v1/models` includes the exact NVPCB model ID |
| Qwen endpoint fails with CIFS `Permission denied`              | Use the single-replica Azure Disk `ReadWriteOnce` cache patch              |
| Qwen endpoint starts but `/v1/models` stays unavailable        | Keep `--stage-init-timeout 1800 --init-timeout 1800` and wait for model load |
| Job remains queued on `h100dedicated`                         | Check H100 node-pool scale state, or rerun with `--instance-type h100spot` |
| H100 spot job is interrupted                                  | Retry the workflow with a new `--output-prefix`; spot drain can evict long GPU jobs |
| Isaac Sim stage runs without producing outputs                | Keep the default Kit timeout and inspect the worker pod logs before retrying |

Read focused user logs when Azure ML streaming lags:

```bash
kubectl exec -n azureml <worker-pod> \
  -c <job-id>-execution-wrapper -- \
  /bin/sh -c 'tail -120 /tmp/azureml/cr/j/<job-id>/exe/wd/user_logs/std_log.txt'
```

## 📝 State And Review

Durable implementation state, validation evidence, decisions, and review handoff details are managed through `.copilot-tracking/` folder files. Current Day 0 validation covers good-image generation, texture defects, and structural defects with the exact Qwen Image-Edit endpoint.
