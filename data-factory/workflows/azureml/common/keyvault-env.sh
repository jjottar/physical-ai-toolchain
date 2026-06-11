#!/usr/bin/env bash
# Retrieve Key Vault secrets with workload identity and launch the workload
set -o errexit -o nounset -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || (cd "$SCRIPT_DIR/../../.." && pwd))"

info() { printf '[INFO]  %s\n' "$*"; }
error() { printf '[ERROR] %s\n' "$*" >&2; }
fatal() { error "$@"; exit 1; }

require_option_value() {
  local option_name="$1" option_value="${2:-}"

  [[ -n "$option_value" && "$option_value" != --* ]] || fatal "$option_name requires a value"
  echo "$option_value"
}

show_help() {
  cat << 'EOF'
Usage: keyvault-env.sh [OPTIONS] -- COMMAND [ARGS...]

Retrieve configured Azure Key Vault secrets through the job managed identity,
export them only for the child process, and exec the workload command.

OPTIONS:
    --optional-hf              Do not require HF_TOKEN_SECRET_NAME
    -h, --help                 Show this help message

ENVIRONMENT:
    KEY_VAULT_URL              Required Key Vault URL, for example https://name.vault.azure.net
    HF_TOKEN_SECRET_NAME       Required by default; Key Vault secret name for HF_TOKEN
    NGC_API_KEY_SECRET_NAME    Optional Key Vault secret name for NGC_API_KEY
EOF
}

json_value() {
  local key="$1"

  "$PYTHON_BIN" -c 'import json, sys; print(json.load(sys.stdin).get(sys.argv[1], ""))' "$key"
}

url_encode() {
  "$PYTHON_BIN" -c 'import urllib.parse, sys; print(urllib.parse.quote(sys.argv[1], safe=""))' "$1"
}

resolve_python() {
  if command -v python3 >/dev/null 2>&1; then
    command -v python3
  elif command -v python >/dev/null 2>&1; then
    command -v python
  else
    fatal "Missing required tool: python or python3"
  fi
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
    ""|none|null|false)
      echo ""
      ;;
    *)
      echo "$value"
      ;;
  esac
}

validate_secret_name() {
  local env_name="$1" secret_name="$2"

  [[ "$secret_name" =~ ^[A-Za-z0-9-]{1,127}$ ]] || fatal "$env_name must be a Key Vault secret name"
  if looks_like_secret_value "$secret_name"; then
    fatal "$env_name must not contain a token value"
  fi
}

get_access_token_with_federated_identity() {
  local assertion token_response

  [[ -n "${AZURE_CLIENT_ID:-}" ]] || return 1
  [[ -n "${AZURE_TENANT_ID:-}" ]] || return 1
  [[ -n "${AZURE_FEDERATED_TOKEN_FILE:-}" ]] || return 1
  [[ -f "$AZURE_FEDERATED_TOKEN_FILE" ]] || return 1

  assertion=$(<"$AZURE_FEDERATED_TOKEN_FILE")
  if command -v curl >/dev/null 2>&1; then
    token_response=$(curl --silent --show-error --fail \
      --request POST "https://login.microsoftonline.com/${AZURE_TENANT_ID}/oauth2/v2.0/token" \
      --data-urlencode "client_id=${AZURE_CLIENT_ID}" \
      --data-urlencode "scope=https://vault.azure.net/.default" \
      --data-urlencode "grant_type=client_credentials" \
      --data-urlencode "client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer" \
      --data-urlencode "client_assertion=${assertion}") || return 1
  else
    token_response=$(
      CLIENT_ASSERTION="$assertion" "$PYTHON_BIN" - <<'PY'
import os
import urllib.parse
import urllib.request

url = f"https://login.microsoftonline.com/{os.environ['AZURE_TENANT_ID']}/oauth2/v2.0/token"
data = urllib.parse.urlencode(
    {
        "client_id": os.environ["AZURE_CLIENT_ID"],
        "scope": "https://vault.azure.net/.default",
        "grant_type": "client_credentials",
        "client_assertion_type": "urn:ietf:params:oauth:client-assertion-type:jwt-bearer",
        "client_assertion": os.environ["CLIENT_ASSERTION"],
    }
).encode()
request = urllib.request.Request(url, data=data, method="POST")
with urllib.request.urlopen(request, timeout=30) as response:
    print(response.read().decode())
PY
  ) || return 1
  fi

  json_value access_token <<<"$token_response"
}

get_access_token_with_msi_endpoint() {
  local endpoint token_response token_url
  local encoded_resource="https%3A%2F%2Fvault.azure.net" # cspell:disable-line

  [[ -n "${MSI_ENDPOINT:-}" ]] || return 1
  endpoint="$MSI_ENDPOINT"
  if [[ "$endpoint" == *\?* ]]; then
    token_url="${endpoint}&api-version=2017-09-01&resource=${encoded_resource}"
  else
    token_url="${endpoint}?api-version=2017-09-01&resource=${encoded_resource}"
  fi

  if command -v curl >/dev/null 2>&1 && [[ -n "${MSI_SECRET:-}" ]]; then
    token_response=$(curl --silent --show-error --fail \
      --header "Secret: ${MSI_SECRET}" \
      "$token_url") || return 1
  elif command -v curl >/dev/null 2>&1; then
    token_response=$(curl --silent --show-error --fail \
      --header Metadata:true \
      "$token_url") || return 1
  else
    token_response=$(
      MSI_TOKEN_URL="$token_url" "$PYTHON_BIN" - <<'PY'
import os
import urllib.request

request = urllib.request.Request(os.environ["MSI_TOKEN_URL"])
if os.environ.get("MSI_SECRET"):
    request.add_header("Secret", os.environ["MSI_SECRET"])
else:
    request.add_header("Metadata", "true")
with urllib.request.urlopen(request, timeout=30) as response:
    print(response.read().decode())
PY
  ) || return 1
  fi

  json_value access_token <<<"$token_response"
}

get_access_token_with_imds() {
  local client_query token_response

  client_query=""
  if [[ -n "${AZURE_CLIENT_ID:-}" ]]; then
    client_query="&client_id=$(url_encode "$AZURE_CLIENT_ID")"
  fi

  if command -v curl >/dev/null 2>&1; then
    token_response=$(curl --silent --show-error --fail \
      --header Metadata:true \
      "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https%3A%2F%2Fvault.azure.net${client_query}") || return 1
  else
    token_response=$(
      IMDS_CLIENT_QUERY="$client_query" "$PYTHON_BIN" - <<'PY'
import os
import urllib.request

url = "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https%3A%2F%2Fvault.azure.net"
url += os.environ.get("IMDS_CLIENT_QUERY", "")
request = urllib.request.Request(url, headers={"Metadata": "true"})
with urllib.request.urlopen(request, timeout=30) as response:
    print(response.read().decode())
PY
  ) || return 1
  fi

  json_value access_token <<<"$token_response"
}

get_access_token() {
  local token

  token=$(get_access_token_with_msi_endpoint || true)
  if [[ -z "$token" ]]; then
    token=$(get_access_token_with_federated_identity || true)
  fi
  if [[ -z "$token" ]]; then
    token=$(get_access_token_with_imds || true)
  fi
  [[ -n "$token" ]] || fatal "Unable to acquire a managed identity token for Key Vault"
  echo "$token"
}

fetch_secret() {
  local key_vault_url="$1" secret_name="$2" access_token="$3" secret_response

  if command -v curl >/dev/null 2>&1; then
    secret_response=$(curl --silent --show-error --fail \
      --header "Authorization: Bearer ${access_token}" \
      "${key_vault_url%/}/secrets/${secret_name}?api-version=7.4") || return 1
  else
    secret_response=$(
      KEY_VAULT_REQUEST_URL="${key_vault_url%/}/secrets/${secret_name}?api-version=7.4" \
        KEY_VAULT_ACCESS_TOKEN="$access_token" "$PYTHON_BIN" - <<'PY'
import os
import urllib.request

request = urllib.request.Request(
    os.environ["KEY_VAULT_REQUEST_URL"],
    headers={"Authorization": f"Bearer {os.environ['KEY_VAULT_ACCESS_TOKEN']}"},
)
with urllib.request.urlopen(request, timeout=30) as response:
    print(response.read().decode())
PY
  ) || return 1
  fi
  json_value value <<<"$secret_response"
}

require_hf=true
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)       show_help; exit 0 ;;
    --optional-hf)   require_hf=false; shift ;;
    --)              shift; break ;;
    *)               break ;;
  esac
done

[[ $# -gt 0 ]] || fatal "Workload command is required after --"
command=("$@")

PYTHON_BIN="$(resolve_python)"

key_vault_url="${KEY_VAULT_URL:-}"
hf_secret_name="$(normalize_optional_secret_name "${HF_TOKEN_SECRET_NAME:-}")"
ngc_secret_name="$(normalize_optional_secret_name "${NGC_API_KEY_SECRET_NAME:-}")"

[[ -n "$key_vault_url" ]] || fatal "KEY_VAULT_URL is required"
[[ "$key_vault_url" =~ ^https://[A-Za-z0-9-]+\.vault\.azure\.net/?$ ]] || fatal "KEY_VAULT_URL must be an Azure Key Vault URL"

if [[ "$require_hf" == "true" ]]; then
  [[ -n "$hf_secret_name" ]] || fatal "HF_TOKEN_SECRET_NAME is required"
fi
[[ -n "$hf_secret_name" ]] && validate_secret_name HF_TOKEN_SECRET_NAME "$hf_secret_name"
[[ -n "$ngc_secret_name" ]] && validate_secret_name NGC_API_KEY_SECRET_NAME "$ngc_secret_name"

info "Retrieving configured Key Vault secrets"
access_token="$(get_access_token)"

if [[ -n "$hf_secret_name" ]]; then
  hf_secret_value="$(fetch_secret "$key_vault_url" "$hf_secret_name" "$access_token")" || \
    fatal "Failed to retrieve HF token from Key Vault"
  [[ -n "$hf_secret_value" ]] || fatal "HF token secret is empty"
  hf_env_name="HF_TOKEN"
  export "$hf_env_name=$hf_secret_value"
  info "HF_TOKEN loaded from Key Vault reference"
fi

if [[ -n "$ngc_secret_name" ]]; then
  ngc_secret_value="$(fetch_secret "$key_vault_url" "$ngc_secret_name" "$access_token")" || \
    fatal "Failed to retrieve NGC API key from Key Vault"
  [[ -n "$ngc_secret_value" ]] || fatal "NGC API key secret is empty"
  ngc_env_name="NGC_API_KEY"
  export "$ngc_env_name=$ngc_secret_value"
  info "NGC_API_KEY loaded from Key Vault reference"
fi

unset access_token hf_secret_value ngc_secret_value hf_env_name ngc_env_name
info "Launching workload command from $REPO_ROOT"
exec "${command[@]}"
