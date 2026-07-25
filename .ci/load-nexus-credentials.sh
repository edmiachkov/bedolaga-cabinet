#!/usr/bin/env bash
# Source from a protected GitLab job. GitLab OIDC is exchanged for a short-lived
# Vault token; Nexus credentials are never stored in GitLab CI variables.

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  echo "source this file from GitLab CI; do not execute it" >&2
  exit 2
fi

set -euo pipefail

: "${CI_PROJECT_DIR:?CI_PROJECT_DIR is required}"
: "${VAULT_ID_TOKEN:?GitLab id_tokens must provide VAULT_ID_TOKEN}"

VAULT_ADDR="${VAULT_ADDR:-https://vault.lab.oh-my-devops.space}"
VAULT_AUTH_ROLE="${VAULT_AUTH_ROLE:-github-mirror-build}"
VAULT_NEXUS_SECRET_PATH="${VAULT_NEXUS_SECRET_PATH:-infra/ci/github-mirror/nexus}"

vault_login_payload="$(
  jq -cn \
    --arg role "$VAULT_AUTH_ROLE" \
    --arg jwt "$VAULT_ID_TOKEN" \
    '{role: $role, jwt: $jwt}'
)"
vault_login_response="$(
  curl --silent --show-error --fail \
    --request POST \
    --header "Content-Type: application/json" \
    --data-binary "$vault_login_payload" \
    "${VAULT_ADDR}/v1/auth/gitlab-jwt/login"
)"
VAULT_CLIENT_TOKEN="$(jq -er '.auth.client_token' <<<"$vault_login_response")"

nexus_secret_response="$(
  curl --silent --show-error --fail \
    --header "X-Vault-Token: ${VAULT_CLIENT_TOKEN}" \
    "${VAULT_ADDR}/v1/secret/data/${VAULT_NEXUS_SECRET_PATH}"
)"

NEXUS_USERNAME="$(jq -er '.data.data.username' <<<"$nexus_secret_response")"
NEXUS_PASSWORD="$(jq -er '.data.data.password' <<<"$nexus_secret_response")"
NEXUS_PROD_REGISTRY="$(jq -er '.data.data.prod_registry' <<<"$nexus_secret_response")"
NEXUS_STAGING_REGISTRY="$(jq -er '.data.data.staging_registry' <<<"$nexus_secret_response")"
NEXUS_CACHE_REGISTRY="$(jq -er '.data.data.cache_registry' <<<"$nexus_secret_response")"

export NEXUS_USERNAME NEXUS_PASSWORD
export NEXUS_PROD_REGISTRY NEXUS_STAGING_REGISTRY NEXUS_CACHE_REGISTRY

DOCKER_CONFIG="${CI_PROJECT_DIR}/.docker"
export DOCKER_CONFIG
install -d -m 0700 "$DOCKER_CONFIG"

nexus_auth="$(printf '%s:%s' "$NEXUS_USERNAME" "$NEXUS_PASSWORD" | base64 | tr -d '\n')"
umask 077
jq -n \
  --arg prod "$NEXUS_PROD_REGISTRY" \
  --arg staging "$NEXUS_STAGING_REGISTRY" \
  --arg cache "$NEXUS_CACHE_REGISTRY" \
  --arg auth "$nexus_auth" \
  '{auths: {
    ($prod): {auth: $auth},
    ($staging): {auth: $auth},
    ($cache): {auth: $auth}
  }}' >"${DOCKER_CONFIG}/config.json"

unset vault_login_payload vault_login_response nexus_secret_response nexus_auth
unset VAULT_ID_TOKEN VAULT_CLIENT_TOKEN

_cleanup_nexus_credentials() {
  rm -f -- "${DOCKER_CONFIG}/config.json"
  unset NEXUS_USERNAME NEXUS_PASSWORD
}
trap _cleanup_nexus_credentials EXIT
