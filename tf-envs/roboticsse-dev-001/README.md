---
title: Robotics Sweden Central Environment
description: Terraform commands for the roboticsse-dev-001 Sweden Central environment
---

## Overview

Use these commands to manage the `roboticsse-dev-001` Terraform environment in Sweden Central.

## Setup

Run the following commands from the repository root before you initialize or apply Terraform:

```bash
cd infrastructure/terraform
unset ARM_SUBSCRIPTION_ID AZURE_SUBSCRIPTION_ID
source prerequisites/az-sub-init.sh
```

## Deploy main Components

Run the following commands from the `infrastructure/terraform` directory:

```bash
terraform init -reconfigure -backend-config=../../tf-envs/roboticsse-dev-001/backend.hcl
terraform apply -var-file=../../tf-envs/roboticsse-dev-001/terraform.swedencentral.tfvars
```

## Deploy VPN Components

Run the following commands from the `infrastructure/terraform` directory:

```bash
terraform -chdir=vpn init -reconfigure -backend-config=../../../tf-envs/roboticsse-dev-001/vpn-backend.hcl
terraform -chdir=vpn apply -var-file=../../../tf-envs/roboticsse-dev-001/terraform.swedencentral.vpn.tfvars
```

## One-Time State Migration

> This migration has already been completed. Do not run it again; it is documented here for reference only.

Run the following commands once when migrating the local state to the configured backend:

```bash
# Core components
terraform init -migrate-state -backend-config=../../tf-envs/roboticsse-dev-001/backend.hcl

# VPN
terraform -chdir=vpn init -migrate-state -backend-config=../../../tf-envs/roboticsse-dev-001/vpn-backend.hcl
```

## OSMO


OSMO has been updated to version 6.3. To use it:

1. Install tools if needed: `sudo az aks install-cli`
1. Connect to AKS: `az aks get-credentials --resource-group rg-roboticsse-dev-001 --name aks-roboticsse-dev-001`
1. Connect to VPN (if private cluster) and check connectivity `kubectl cluster-info`
1. In terminal 1, port-foward OSMO service: `kubectl port-forward svc/osmo-gateway 9001:80 -n osmo-control-plane`
1. Open OSMO dashboard <http://localhost:9001/>
1. Login with OSMO cli: `osmo login http://localhost:9001/ --method token --token "$(kubectl get secret osmo-default-admin -n osmo-control-plane -o jsonpath='{.data.password}' | base64 -d)"`
1. List OSMO pools: `osmo pool list`
1. Submit hello world job: `osmo workflow submit <(curl -fsSL https://raw.githubusercontent.com/NVIDIA/OSMO/refs/heads/main/cookbook/tutorials/hello_world.yaml)`



