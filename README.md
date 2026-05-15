# Atualei Infra

Stack integrada de desenvolvimento e operacao para os projetos Atualei.

Este repo centraliza a infraestrutura compartilhada:

- MVP
- legal crawler
- Postgres local opcional
- Prometheus
- Grafana
- Loki
- Tempo
- Alloy

## Layout esperado

```text
atualei/
  atualei-infra/
  atualei-legal-crawler/
  mvp-plataforma-anotacoes-juridicas/
```

## Desenvolvimento local

Com banco externo configurado em `.runtime/db.env`:

```sh
docker compose up -d --build
```

Com Postgres local do compose:

```sh
docker compose -f compose.yml -f compose.local-db.yml --profile local-db up -d --build
```

## Staging/producao

Use imagens versionadas em vez de `build.context` local:

```sh
CRAWLER_TAG=sha-or-version MVP_TAG=sha-or-version \
  docker compose -f compose.release.yml up -d
```

Os apps continuam com compose standalone nos respectivos repos. Este repo e o unico lugar que conhece a topologia integrada entre MVP, crawler e observability compartilhada.
