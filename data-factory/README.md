---
description: Azure ML DIG operator guide for live-validated setup, finetune, and Day 1 manual ROI workflows
ms.date: 2026-06-05
ms.topic: how-to
---

# Data Factory Azure ML Workflows

Azure ML commandJob assets run live-validated NVIDIA physical-ai-data-factory DIG workflows on the toolchain AKS cluster attached to Azure ML. This path preserves the NVIDIA OSMO workflow route while adding an Azure ML execution surface for setup, Finetune Only, and Day 1 manual ROI.

## 📋 Prerequisites

| Requirement                  | Value or command                                                                             |
|------------------------------|----------------------------------------------------------------------------------------------|
| Azure CLI                    | `az login`                                                                                   |
| Azure ML CLI extension       | `az extension add --name ml`                                                                 |
| Kubernetes access            | `az aks get-credentials --resource-group <resource-group> --name <aks-name>`                 |
| NVIDIA data factory checkout | Local clone of `NVIDIA/physical-ai-data-factory`                                             |
| Azure ML workspace           | Existing workspace with AKS attached as Kubernetes compute                                   |
| Azure ML compute             | Attached AKS compute, for example `<attached-compute-name>`                                  |
| Generated data datastore     | `datasets`                                                                                  |
| Pretrained input datastore   | `datasets` for setup-pretrained outputs, or `osmo_datasets` for compatible legacy caches     |
| Cosmos cache datastore       | Datastore containing reusable Cosmos cache artifacts                                         |
| Key Vault                    | Runtime secret source, for example `https://<key-vault-name>.vault.azure.net`                |
| Hugging Face token secret    | Key Vault secret name, default `paidf-hf-token`                                              |
| NGC API key secret           | Optional Key Vault secret name, default `none`                                               |
| H100 InstanceType            | `h100spot` for validated H100 spot runs, `h100dedicated` for the dedicated H100 route        |

The validated live route uses attached AKS compute, `datasets` for generated ADLS artifacts, `osmo_datasets` for compatible blob-backed cache inputs, and the Key Vault secret reference `paidf-hf-token`.

## 🔐 Secret Setup

Store token values in Key Vault and pass only secret names to the submitter. Do not pass token values through CLI arguments, rendered YAML, checked-in files, or Azure ML `--set` overrides.

Set a Hugging Face token for gated model access:

```bash
read -r -s HF_TOKEN
tmp=$(mktemp)
printf '%s' "$HF_TOKEN" > "$tmp"
az keyvault secret set --vault-name <key-vault-name> --name paidf-hf-token --file "$tmp"
rm -f "$tmp"; unset HF_TOKEN tmp
```

Set an optional NGC API key only when the selected NVIDIA image requires NGC authentication:

```bash
read -r -s NGC_API_KEY
tmp=$(mktemp)
printf '%s' "$NGC_API_KEY" > "$tmp"
az keyvault secret set --vault-name <key-vault-name> --name paidf-ngc-api-key --file "$tmp"
rm -f "$tmp"; unset NGC_API_KEY tmp
```

Grant the Azure ML workload identity permission to read secrets. Use the managed identity principal created for the Azure ML AKS attachment:

```bash
vault_scope=$(az keyvault show --name <key-vault-name> --query id -o tsv)
az role assignment create --assignee <managed-identity-principal-id> --role "Key Vault Secrets User" --scope "$vault_scope"
```

Validate secret names and access before submitting work:

```bash
az keyvault secret show --vault-name <key-vault-name> --name paidf-hf-token --query id -o tsv
```

## ⚙️ Environment

Use CLI arguments for reviewable runs. For repeated local use, put non-secret defaults in `.env.local`; the submitter sources it only for `--submit` and strips token-shaped environment variables before rendering jobs.

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
```

Common submitter options:

| Option                      | Purpose                                                                                  |
|-----------------------------|------------------------------------------------------------------------------------------|
| `--workflow`                | Selects `setup-pretrained`, `setup-pcb`, `setup-metal`, `finetune`, or `day1-manual-roi` |
| `--usecase`                 | Selects `pcb` or `metal_surface` where supported                                         |
| `--instance-type`           | Overrides the workflow InstanceType. Use `h100spot` for validated H100 spot execution    |
| `--datastore`               | Stores generated setup and run artifacts                                                 |
| `--pretrained-datastore`    | Reads setup-pretrained output or compatible pretrained cache artifacts                    |
| `--pretrained-storage-root` | Datastore path that contains `models/pretrained`                                         |
| `--storage-root`            | Datastore path for setup outputs or workflow inputs                                      |
| `--output-prefix`           | Datastore path for run outputs                                                           |
| `--max-iter`, `--save-iter` | Finetune iteration and checkpoint overrides. `0` keeps the NVIDIA cookbook defaults      |
| `--assets-only`             | Validates local assets without cloud calls                                               |
| `--validate-cloud`          | Runs read-only Azure ML, Key Vault, datastore, and InstanceType checks                   |
| `--config-preview`          | Prints a redacted configuration and exits without submitting work                        |
| `--submit`, `--stream`      | Submits the rendered job and optionally streams logs                                     |

## 🚀 Quick Start

Check workspace, compute, datastores, and InstanceTypes:

```bash
az ml workspace show --resource-group <resource-group> --name <workspace-name> -o table
az ml compute show --name <compute-name> --resource-group <resource-group> --workspace-name <workspace-name> -o table
az ml datastore list --resource-group <resource-group> --workspace-name <workspace-name> -o table
kubectl get instancetypes.amlarc.azureml.com
```

Define shared arguments for repeated workflow runs:

```bash
common_args=(
  --data-factory-source ../physical-ai-data-factory --resource-group <resource-group>
  --workspace-name <workspace-name> --compute <compute-name> --instance-type h100spot
  --datastore datasets --key-vault-url https://<key-vault-name>.vault.azure.net
  --hf-token-secret-name paidf-hf-token
)
```

Preview, schema-validate, then submit after both checks pass:

```bash
job_args=(--workflow day1-manual-roi --usecase pcb --pretrained-datastore datasets)
job_args+=(--pretrained-storage-root dig/<setup-pretrained-run-root>/models/pretrained)
job_args+=(--storage-root dig/<setup-pcb-run-root>)

data-factory/scripts/submit-azureml-dig.sh "${common_args[@]}" "${job_args[@]}" \
  --rendered-job-output /tmp/paidf-dig-day1-manual-roi.yaml --validate-cloud --config-preview
az ml job validate --file /tmp/paidf-dig-day1-manual-roi.yaml --resource-group <resource-group> --workspace-name <workspace-name>

data-factory/scripts/submit-azureml-dig.sh "${common_args[@]}" "${job_args[@]}" --output-prefix dig/runs/<run-id> --submit --stream
```

## 🧱 Workflow Order

Run setup workflows before workflow jobs that consume their outputs.

| Step | Workflow           | Required for                           | Output root shape                                                           |
|------|--------------------|----------------------------------------|-----------------------------------------------------------------------------|
| 1    | `setup-pretrained` | Finetune Only and Day 1 manual ROI     | `<output-prefix>/models/pretrained`                                         |
| 2    | `setup-pcb`        | PCB Finetune Only and Day 1 manual ROI | `<output-prefix>/models`, `<output-prefix>/raw_dataset`, `<output-prefix>/assets` |
| 3    | `setup-metal`      | Metal Day 1 manual ROI                 | `<output-prefix>/models`, `<output-prefix>/raw_dataset`                     |
| 4    | `finetune`         | PCB fine-tuned AnomalyGen checkpoint   | `<output-prefix>/finetune/finetune`                                         |
| 5    | `day1-manual-roi`  | Pretrained Day 1 inference             | `<output-prefix>/day1-manual-roi`                                           |

Run setup workflows in order:

```bash
for workflow in setup-pretrained setup-pcb setup-metal; do
  data-factory/scripts/submit-azureml-dig.sh "${common_args[@]}" \
    --workflow "$workflow" --output-prefix dig/runs/$workflow-<run-id> --validate-cloud --submit
done
```

Run Finetune Only after setup-pretrained and setup-pcb outputs exist:

```bash
finetune_args=(--workflow finetune --pretrained-datastore datasets)
finetune_args+=(--pretrained-storage-root dig/runs/setup-pretrained-<run-id>/models/pretrained)
finetune_args+=(--storage-root dig/runs/setup-pcb-<run-id> --output-prefix dig/runs/finetune-<run-id>)
data-factory/scripts/submit-azureml-dig.sh "${common_args[@]}" "${finetune_args[@]}" --max-iter 2000 --save-iter 2000 --submit
```

Run Day 1 manual ROI after setup outputs exist:

```bash
manual_roi_args=(--workflow day1-manual-roi --usecase pcb --pretrained-datastore datasets)
manual_roi_args+=(--pretrained-storage-root dig/runs/setup-pretrained-<run-id>/models/pretrained)
manual_roi_args+=(--storage-root dig/runs/setup-pcb-<run-id> --output-prefix dig/runs/day1-manual-roi-<run-id>)
data-factory/scripts/submit-azureml-dig.sh "${common_args[@]}" "${manual_roi_args[@]}" --submit --stream
```

Use `--usecase metal_surface` with `--storage-root` pointing at a completed `setup-metal` output for the validated metal Day 1 manual ROI path.

## 📤 Input Data

Use Azure ML datastore paths for portable job YAML. Raw `azure://<account>/<container>/...` paths are accepted only when `--storage-account` and `--storage-container` match the target account and container.

Verify the required setup-pretrained layout before Finetune Only:

```bash
az storage fs file list \
  --account-name <adls-account> \
  --file-system datasets \
  --path dig/runs/setup-pretrained-<run-id>/models/pretrained \
  --recursive \
  --auth-mode login \
  --query "[?contains(name, 'Cosmos-Predict2-2B-Text2Image/model.pt')].name" \
  -o tsv
```

## 🔍 Validation And Artifacts

Every live validation follows the same ladder:

| Stage                 | Command or check                                                                       |
|-----------------------|-----------------------------------------------------------------------------------------|
| Local assets          | `data-factory/scripts/submit-azureml-dig.sh ... --assets-only`                         |
| Render preview        | `data-factory/scripts/submit-azureml-dig.sh ... --rendered-job-output <file> --config-preview` |
| Azure ML schema       | `az ml job validate --file <rendered-file> --resource-group <rg> --workspace-name <workspace>` |
| Cloud preflight       | `data-factory/scripts/submit-azureml-dig.sh ... --validate-cloud --config-preview`     |
| Live completion       | `az ml job show --name <job-name> --query '{name:name,status:status,error:error}'`      |
| Artifact verification | `az storage fs file list` or `az storage blob list` on the output root                  |

Finetune output verification checks these files under `<output-prefix>/finetune/finetune`:

| Artifact                | Purpose                                            |
|-------------------------|----------------------------------------------------|
| `validation.jsonl`      | Validation prompt and ROI contract                 |
| `best_step.txt`         | Selected checkpoint step                           |
| `iter_*.pt`             | Model, optimizer, scheduler, or trainer checkpoint |
| `artifact_manifest.txt` | Runtime output manifest                            |

Example ADLS artifact query:

```bash
base='dig/runs/finetune-<run-id>/finetune/finetune'
az storage fs file list \
  --account-name <adls-account> \
  --file-system datasets \
  --path "$base" \
  --recursive \
  --auth-mode login \
  --query "[?contains(name, 'validation.jsonl') || contains(name, 'best_step.txt') || contains(name, 'artifact_manifest.txt') || ends_with(name, '.pt')].name" \
  -o tsv
```

## 🧪 Tested Results

Live Azure ML validation on the attached AKS compute proved these paths:

| Workflow           | Live result                                                                                                            |
|--------------------|------------------------------------------------------------------------------------------------------------------------|
| `setup-pretrained` | Completed and produced Cosmos Predict2 2B pretrained layout in `datasets`                                             |
| `setup-pcb`        | Completed and produced PCBA checkpoints, raw dataset, and USD assets                                                  |
| `setup-metal`      | Completed and produced metal checkpoint and raw dataset artifacts                                                     |
| `day1-manual-roi`  | Completed for PCB and metal paths, with expected TAO DAFT output counts                                               |
| `finetune`         | Completed a bounded PCB run with Key Vault, H100, `/dev/shm`, checkpoint, manifest, and validation-image verification |

## 🧭 Troubleshooting

| Symptom                                                       | Fix                                                                        |
|---------------------------------------------------------------|----------------------------------------------------------------------------|
| `HF_TOKEN loaded` does not appear in logs                     | Check Key Vault URL, secret name, and `Key Vault Secrets User` permission  |
| Finetune fails with `/dev/shm` too small                      | Ensure the rendered job includes `resources.shm_size: 32g`                 |
| Finetune cannot find `Cosmos-Predict2-2B-Text2Image/model.pt` | Use a successful `setup-pretrained` output as `--pretrained-storage-root`  |
| Job remains queued on `h100dedicated`                         | Check H100 node-pool scale state, or rerun with `--instance-type h100spot` |

Read focused user logs when Azure ML streaming lags:

```bash
kubectl exec -n azureml <worker-pod> \
  -c <job-id>-execution-wrapper -- \
  /bin/sh -c 'tail -120 /tmp/azureml/cr/j/<job-id>/exe/wd/user_logs/std_log.txt'
```

## 📝 State And Review

Use this README for live-validated operator guidance. Durable implementation state, validation evidence, decisions, and review handoff details are managed through `.copilot-tracking/` folder files. After Task Implementation completes, the next agent instructions are Task Reviewer, and the user switches to Task Reviewer for implementation review.
