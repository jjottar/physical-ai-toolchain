// Core Configuration
environment     = "dev"
location        = "swedencentral"
resource_prefix = "roboticsse"
instance        = "001"

// Resource Group
should_create_resource_group = true

// AKS System Node Pool
system_node_pool_vm_size    = "Standard_D8ds_v5"
system_node_pool_node_count = 1

// GPU Node Pools - Spot A10 and H100
node_pools = {
  gpu = {
    vm_size                 = "Standard_NV36ads_A10_v5"
    subnet_address_prefixes = ["10.0.7.0/24"]
    node_taints             = ["nvidia.com/gpu:NoSchedule", "kubernetes.azure.com/scalesetpriority=spot:NoSchedule"]
    gpu_driver              = "Install"
    node_labels = {
      "kubernetes.azure.com/scalesetpriority" = "spot"
    }
    priority                   = "Spot"
    should_enable_auto_scaling = true
    min_count                  = 1
    max_count                  = 1
    zones                      = []
    eviction_policy            = "Delete"
  }
  h100gpu = {
    vm_size                 = "Standard_NC40ads_H100_v5"
    subnet_address_prefixes = ["10.0.8.0/24"]
    node_taints = [
      "nvidia.com/gpu:NoSchedule",
      "kubernetes.azure.com/scalesetpriority=spot:NoSchedule"
    ]
    gpu_driver = "None"
    node_labels = {
    }
    priority                   = "Regular"
    should_enable_auto_scaling = true
    min_count                  = 1
    max_count                  = 4
    zones                      = []
  }
}

// OSMO Backend Services
should_deploy_postgresql = true
should_deploy_redis      = true

// Observability
should_deploy_grafana             = false
should_enable_aml_diagnostic_logs = true

// Network Security - Full Private (VPN required)
should_enable_private_endpoint    = true
should_enable_private_aks_cluster = true

should_enable_public_network_access     = false
should_add_current_user_key_vault_admin = true
should_enable_microsoft_defender        = true

// AzureML workspace managed network isolation is independent from private endpoints.
// Keep the allowlist in Terraform so image builds do not depend on portal-side rules.
aml_managed_network_isolation_mode = "AllowInternetOutbound"

// Storage Lifecycle Management
should_create_data_lake_storage                   = true
should_enable_raw_bags_lifecycle_policy           = true
raw_bags_retention_days                           = 30
should_enable_converted_datasets_lifecycle_policy = true
converted_datasets_cool_tier_days                 = 90
should_enable_reports_lifecycle_policy            = true
reports_cool_tier_days                            = 30
reports_archive_tier_days                         = 180

// Isaac Sim VM Subnet
should_create_vm_subnet = true


// OSMO configuration using workload identity
osmo_config = {
  should_enable_identity   = true
  should_federate_identity = true
  should_create_secret     = true
  control_plane_namespace  = "osmo-control-plane"
  operator_namespace       = "osmo-operator"
  workflows_namespace      = "osmo-workflows"
}
