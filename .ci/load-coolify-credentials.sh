#!/usr/bin/env bash
# Source from a protected GitLab job. GitLab OIDC is exchanged for a short-lived
# Vault token; the Coolify deploy token is never stored in GitLab CI variables.
#
# В Vault лежит только сам токен, и путь общий для всех проектов, которые
# деплоятся в этот Coolify. Адрес инстанса и uuid приложения — не секреты:
# первый имеет дефолт ниже, второй задаётся переменной проекта
# COOLIFY_APPLICATION_UUID. Иначе общий путь пришлось бы расширять ключом на
# каждое новое приложение.
#
# Путь намеренно отдельный от secret/infra/coolify/homework-ai-reviewer: там
# лежат runtime-секреты приложения (Django key, пароль PostgreSQL, токен
# GitLab), и раннеру сборки они не нужны.

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  echo "source this file from GitLab CI; do not execute it" >&2
  exit 2
fi

set -euo pipefail

: "${VAULT_ID_TOKEN:?GitLab id_tokens must provide VAULT_ID_TOKEN}"

VAULT_ADDR="${VAULT_ADDR:-https://vault.lab.oh-my-devops.space}"
VAULT_AUTH_ROLE="${VAULT_AUTH_ROLE:-github-mirror-build}"
VAULT_COOLIFY_SECRET_PATH="${VAULT_COOLIFY_SECRET_PATH:-infra/ci/coolify}"
COOLIFY_BASE_URL="${COOLIFY_BASE_URL:-https://coolify.lab.oh-my-devops.space}"

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

coolify_secret_response="$(
  curl --silent --show-error --fail \
    --header "X-Vault-Token: ${VAULT_CLIENT_TOKEN}" \
    "${VAULT_ADDR}/v1/secret/data/${VAULT_COOLIFY_SECRET_PATH}"
)"

COOLIFY_API_TOKEN="$(jq -er '.data.data.api_token' <<<"$coolify_secret_response")"

export COOLIFY_API_TOKEN COOLIFY_BASE_URL

unset vault_login_payload vault_login_response coolify_secret_response
unset VAULT_ID_TOKEN VAULT_CLIENT_TOKEN

_cleanup_coolify_credentials() {
  unset COOLIFY_API_TOKEN
}
trap _cleanup_coolify_credentials EXIT
