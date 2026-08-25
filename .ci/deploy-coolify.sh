#!/usr/bin/env bash
# Развернуть в Coolify образ этого коммита и дождаться результата.
#
# Запускается последней стадией пайплайна, а не по push в GitHub: образ
# собирает этот же пайплайн, и триггер «на push» разворачивал бы предыдущую
# сборку, потому что новой в Nexus ещё нет.
#
# Тег пинится на sha-<commit>: по мутабельному :main нельзя сказать, какой
# коммит сейчас в проде, и откат превращается в пересборку.
#
# Отличие от homework-ai-reviewer: Bedolaga в Coolify — это service, а не
# application. Для service POST /deploy возвращает только message+resource_uuid
# БЕЗ deployment_uuid, а GET /deployments отдаёт пустой список — опрашивать
# отдельный деплой нечего. Поэтому ждём по агрегированному полю
# GET /services/<uuid> .status (running:healthy / degraded:unhealthy).

set -euo pipefail

: "${COOLIFY_BASE_URL:?задаётся переменной джобы deploy_production}"
: "${COOLIFY_API_TOKEN:?приезжает из Vault через secrets: — см. deploy_production}"
: "${COOLIFY_SERVICE_UUID:?set it in .gitlab-ci.yml variables — это не секрет}"
: "${CABINET_IMAGE_IMMUTABLE_TAG:?build_scan_publish must pass image.env}"

DEPLOY_TIMEOUT_SECONDS="${DEPLOY_TIMEOUT_SECONDS:-900}"
DEPLOY_POLL_SECONDS="${DEPLOY_POLL_SECONDS:-10}"
IMAGE_TAG_KEY="CABINET_IMAGE_TAG"

coolify_api() {
  local method="$1" path="$2"
  shift 2
  curl --silent --show-error --fail \
    --request "$method" \
    --header "Authorization: Bearer ${COOLIFY_API_TOKEN}" \
    --header "Content-Type: application/json" \
    --header "Accept: application/json" \
    "$@" \
    "${COOLIFY_BASE_URL%/}/api/v1${path}"
}

previous_tag="$(
  coolify_api GET "/services/${COOLIFY_SERVICE_UUID}/envs" |
    jq -r --arg key "$IMAGE_TAG_KEY" 'map(select(.key == $key)) | .[0].value // ""'
)"

env_payload="$(
  jq -cn \
    --arg key "$IMAGE_TAG_KEY" \
    --arg value "$CABINET_IMAGE_IMMUTABLE_TAG" \
    '{key: $key, value: $value, is_preview: false}'
)"

echo "Пиню ${IMAGE_TAG_KEY}=${CABINET_IMAGE_IMMUTABLE_TAG}"
if ! coolify_api PATCH "/services/${COOLIFY_SERVICE_UUID}/envs" \
  --data-binary "$env_payload" >/dev/null; then
  # На первом деплое переменной ещё нет — PATCH её не найдёт.
  coolify_api POST "/services/${COOLIFY_SERVICE_UUID}/envs" \
    --data-binary "$env_payload" >/dev/null
fi

applied_tag="$(
  coolify_api GET "/services/${COOLIFY_SERVICE_UUID}/envs" |
    jq -r --arg key "$IMAGE_TAG_KEY" 'map(select(.key == $key)) | .[0].value // ""'
)"
if [[ -z "$applied_tag" ]]; then
  echo "Coolify не отдал значение ${IMAGE_TAG_KEY} обратно — проверьте руками" >&2
elif [[ "$applied_tag" != "$CABINET_IMAGE_IMMUTABLE_TAG" ]]; then
  echo "В Coolify осталось ${IMAGE_TAG_KEY}=${applied_tag}, деплой отменён" >&2
  exit 1
fi

coolify_api POST "/deploy?uuid=${COOLIFY_SERVICE_UUID}" >/dev/null
echo "Деплой сервиса запущен, жду до ${DEPLOY_TIMEOUT_SECONDS}с"

# Coolify отдаёт ещё старый running:healthy до того, как остановит контейнеры,
# поэтому сначала дожидаемся ухода из running и только потом считаем
# running:healthy результатом ЭТОГО деплоя.
#
# Если тег сменился, а сервис так и не перезапустился — деплой НЕ применился, и
# это надо считать провалом. Именно так и было при заводке пайплайна: на хосте
# не было docker login в приватный Nexus, pull падал с "no basic auth
# credentials", Coolify переписывал .env, но контейнеры не пересоздавал, а
# скрипт видел прежний running:healthy и отчитывался успехом.
# Опрос частый: окно перезапуска бывает ~10с, на poll=10с его можно проспать.
restarted=false
grace_deadline=$((SECONDS + 120))
while ((SECONDS < grace_deadline)); do
  status="$(coolify_api GET "/services/${COOLIFY_SERVICE_UUID}" | jq -er '.status')"
  if [[ "$status" != running:* ]]; then
    restarted=true
    break
  fi
  sleep 3
done

if [[ "$restarted" != true ]]; then
  if [[ "$previous_tag" == "$CABINET_IMAGE_IMMUTABLE_TAG" ]]; then
    # Пере-прогон пайплайна на том же коммите: пересоздавать нечего.
    echo "Тег не менялся (${CABINET_IMAGE_IMMUTABLE_TAG}), сервис не перезапускался"
    exit 0
  fi
  echo "Тег сменился на ${CABINET_IMAGE_IMMUTABLE_TAG}, но сервис не перезапустился" >&2
  echo "Coolify принял деплой и не применил его — проверьте docker login в Nexus на целевом сервере" >&2
  exit 1
fi

deadline=$((SECONDS + DEPLOY_TIMEOUT_SECONDS))
while ((SECONDS < deadline)); do
  status="$(coolify_api GET "/services/${COOLIFY_SERVICE_UUID}" | jq -er '.status')"
  case "$status" in
    running:healthy)
      echo "Задеплоен ${CABINET_IMAGE_IMMUTABLE_TAG}"
      exit 0
      ;;
    exited* | degraded:exited*)
      echo "Coolify поднял сервис в состоянии ${status}" >&2
      exit 1
      ;;
    *)
      echo "  ${status}…"
      sleep "$DEPLOY_POLL_SECONDS"
      ;;
  esac
done

# Молча считать деплой успешным по таймауту нельзя: пайплайн зелёный, а в
# проде неизвестно что.
echo "Coolify не привёл сервис в running:healthy за ${DEPLOY_TIMEOUT_SECONDS}с (status=${status})" >&2
exit 1
