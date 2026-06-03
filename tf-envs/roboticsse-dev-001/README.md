---
title: Robotics Sweden Central Environment
description: Terraform commands for the roboticsse-dev-001 Sweden Central environment
---

## Overview

Commands for managing the `roboticsse-dev-001` Terraform environment in Sweden Central.

## Setup

Run these commands from the repository root before initializing or applying Terraform:

```bash
cd infrastructure/terraform
unset ARM_SUBSCRIPTION_ID AZURE_SUBSCRIPTION_ID
source prerequisites/az-sub-init.sh
```

## One-Time State Migration

Run this once when migrating the local state to the configured backend:

```bash
terraform init -migrate-state -backend-config=../../tf-envs/roboticsse-dev-001/backend.hcl
```

## Deploy

Run these commands for normal deployments after the backend migration is complete:

```bash
terraform init -reconfigure -backend-config=../../tf-envs/roboticsse-dev-001/backend.hcl
terraform apply -var-file=../../tf-envs/roboticsse-dev-001/terraform.swedencentral.tfvars
```
