# Зачем этот форк

Апстрим `BEDOLAGA-DEV/bedolaga-cabinet` публикует `ghcr.io/bedolaga-dev/bedolaga-cabinet`,
но этот образ нам не подходит: `VITE_TELEGRAM_BOT_USERNAME` — build-time `ARG`
**без дефолта**, то есть в публичном образе он пустой, и deep-link авторизация
через Telegram не работает. Нужен свой билд с `vpn_edde_bot`.

Форк существует только ради `.gitlab-ci.yml` и `.ci/` — код приложения не патчим,
чтобы `gh repo sync` с апстримом оставался тривиальным.

## Как это едет в прод

```
GitHub (source of truth)
  └─> GitLab github-mirror/bedolaga-cabinet (pull mirror, project 17)
        └─> раннер prod-build (.66, rootless BuildKit, без docker socket)
              ├─> Nexus staging  ──> Trivy: SBOM + гейт по CRITICAL
              ├─> Nexus prod: sha-<commit> (immutable) + main (канал)
              └─> Coolify: пин CABINET_IMAGE_TAG=sha-<commit> + деплой сервиса
```

Секреты в CI не хранятся: GitLab OIDC меняется на короткоживущий Vault-токен
(роль `github-mirror-build`, привязана к namespace 155 и protected-ветке),
оттуда берутся креды Nexus и токен Coolify.

## Обновить с апстрима

```bash
gh repo sync edmiachkov/bedolaga-cabinet --source BEDOLAGA-DEV/bedolaga-cabinet --branch main
```

Push в `main` → зеркало → пайплайн сам соберёт и задеплоит. Проверять после
обновления апстрима: `ARG VITE_TELEGRAM_BOT_USERNAME` должен остаться в
`Dockerfile` — на это есть проверка в стадии `validate`, она упадёт громко.
