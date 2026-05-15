# Observability

Este backend segue o mesmo padrao operacional do projeto `atualei-legal-crawler`: Actuator, Prometheus, Loki, Grafana Alloy, Tempo, Grafana, logs JSON estruturados, correlacao por request e metricas de uso da API.

## Stack

Servicos no `compose.yml` do repo `atualei-infra`:

- `db`: Postgres 16.
- `mailpit`: SMTP local para fluxos de cadastro, verificacao de email e reset de senha.
- `mvp`: API Spring Boot na porta interna `8082`.
- `prometheus`: coleta `/actuator/prometheus`.
- `loki`: armazena logs.
- `alloy`: le logs dos containers Docker e envia para Loki.
- `tempo`: recebe traces OTLP HTTP/GRPC.
- `grafana`: dashboards provisionados automaticamente.

Portas locais padrao:

| Servico | URL |
| --- | --- |
| API | `http://localhost:8082` |
| Swagger UI | `http://localhost:8082/swagger-ui.html` |
| Actuator health | `http://localhost:8082/actuator/health` |
| Prometheus metrics | `http://localhost:8082/actuator/prometheus` |
| Grafana | `http://localhost:3000` |
| Prometheus | `http://localhost:9090` |
| Loki | `http://localhost:3100` |
| Tempo | `http://localhost:3200` |
| Mailpit UI | `http://localhost:8025` |

MVP e crawler compartilham a mesma stack de observability neste repo.

## Como subir

```bash
docker compose up --build
```

Credenciais padrao do Grafana:

- usuario: `admin`
- senha: `admin`

Dashboard provisionado:

- pasta: `Atualei`
- dashboard: `Atualei Plataforma Observability`

## Health e readiness

Endpoints publicos:

- `GET /api/v1/health`: health simples da API para smoke checks.
- `GET /actuator/health`: health completo do Spring Boot.
- `GET /actuator/health/liveness`: liveness probe.
- `GET /actuator/health/readiness`: readiness probe.

O container `mvp` usa readiness no healthcheck e cai para `/api/v1/health` se necessario.

## Logs estruturados

Arquivo: `src/main/resources/logback-spring.xml`.

Formato: JSON no stdout, coletado pelo Alloy.

Campos fixos:

- `service`: valor de `spring.application.name`.
- `level`
- `logger_name`
- `message`
- `thread_name`
- `@timestamp`

Campos MDC relevantes:

- `traceId`: id do trace atual.
- `spanId`: id do span atual.
- `requestId`: correlacao HTTP, recebido ou gerado via `X-Request-Id`.
- `operation`: metodo e endpoint estavel, por exemplo `GET /api/v1/legal-annotations`.
- `userId`: UUID do usuario autenticado quando houver JWT.
- `legalUnitId`: reservado para logs de unidade legal.
- `annotationId`: reservado para logs de anotacao/grifo/flashcard.
- `targetType`: reservado para logs de tipo de alvo.
- `sessionId`: hash de `X-Atualei-Session-Id`.
- `anonymousId`: hash de `X-Atualei-Anonymous-Id`.

Headers de correlacao aceitos:

- `X-Request-Id`: se vier vazio, ausente ou maior que 80 caracteres, a API gera um UUID.
- `X-Atualei-Session-Id`: hash SHA-256 truncado antes de ir para log.
- `X-Atualei-Anonymous-Id`: hash SHA-256 truncado antes de ir para log.

O salt dos hashes vem de:

```properties
plataforma.analytics.hash-salt=${PLATAFORMA_ANALYTICS_HASH_SALT:dev-observability-salt}
```

## Niveis de log

Mesmo criterio do crawler:

- `ERROR`: falha inesperada, erro 5xx ou exception que exige acao.
- `WARN`: requisicao rejeitada, erro 4xx relevante, integracao externa indisponivel.
- `INFO`: marcos de ciclo de vida e operacoes de negocio importantes.
- `DEBUG`: conclusao de request e detalhes uteis em investigacao.
- `TRACE`: diagnostico local muito detalhado.

Variaveis:

```properties
LOGGING_LEVEL_ROOT=INFO
LOGGING_LEVEL_ATUALEI=INFO
LOGGING_LEVEL_HIBERNATE_SQL=WARN
LOGGING_LEVEL_HIBERNATE_BIND=WARN
PLATAFORMA_OBSERVABILITY_LOG_FORMAT=json
```

## Metricas

Actuator expoe:

- JVM, CPU, threads e GC.
- Hikari/Postgres.
- HTTP server.
- Health/status.
- Metricas customizadas Atualei.

Metricas customizadas:

### `atualei.api.requests.total`

Counter incrementado no fim de cada request MVC.

Labels:

- `area`: `auth`, `legal`, `search`, `health`, `actuator`, `docs` ou `system`.
- `endpoint`: padrao estavel do Spring MVC, por exemplo `/api/v1/legal-annotations/{id}`.
- `method`: `GET`, `POST`, `PATCH`, `DELETE`, etc.
- `status_family`: `2xx`, `4xx`, `5xx`.

### `atualei.api.request.duration`

Timer com a mesma cardinalidade de labels de `atualei.api.requests.total`.

Usado no dashboard para p95 por area:

```promql
histogram_quantile(
  0.95,
  sum by (le, area) (rate(atualei_api_request_duration_seconds_bucket[5m]))
)
```

## Tracing

Traces sao criados por `RequestTracingFilter` e enviados para Tempo via OTLP HTTP.

Configuracao:

```properties
management.tracing.enabled=${MANAGEMENT_TRACING_ENABLED:true}
management.tracing.sampling.probability=${MANAGEMENT_TRACING_SAMPLING_PROBABILITY:1.0}
management.otlp.tracing.endpoint=${MANAGEMENT_OTLP_TRACING_ENDPOINT:http://localhost:4318/v1/traces}
```

No Docker, a API usa:

```text
MANAGEMENT_OTLP_TRACING_ENDPOINT=http://tempo:4318/v1/traces
```

O filtro nao cria spans para `/actuator`, para evitar ruido.

## Prometheus

Arquivo: `observability/prometheus/prometheus.yml`.

Jobs:

- `plataforma-juridica`: coleta `mvp:8082/actuator/prometheus`.
- `prometheus`: self-scrape.
- `loki`: saude e metricas internas.
- `alloy`: saude e metricas internas.

## Loki e Alloy

Arquivo do Alloy: `observability/alloy/config.alloy`.

O Alloy:

- descobre containers Docker rodando.
- mantem apenas containers com nome `/plataforma-juridica-.*`.
- extrai labels `level`, `logger` e `operation` dos logs JSON.
- envia tudo para `http://loki:3100/loki/api/v1/push`.

Labels de Loki intencionalmente baixos em cardinalidade:

- `container`
- `compose_service`
- `stream`
- `level`
- `logger`
- `operation`

Nao promover `userId`, `requestId`, `traceId`, `annotationId` ou `legalUnitId` para label de Loki. Eles devem ficar no corpo do log para evitar explosao de cardinalidade.

## Grafana

Provisionamento:

- Datasources: `observability/grafana/provisioning/datasources/datasources.yml`
- Dashboard provider: `observability/grafana/provisioning/dashboards/dashboards.yml`
- Dashboard JSON: `observability/grafana/dashboards/atualei-plataforma-observability.json`

Paineis principais:

- API Throughput.
- API Latency p95.
- Endpoint Usage 1h.
- JVM Memory.
- CPU Usage.
- DB Connections.
- Business Areas 24h.
- HTTP Server Latency p95.
- Observability Targets.
- Loki Ingestion Rate.
- Recent App Logs.
- Warnings and Errors.

## Smoke test funcional

Script:

```bash
./scripts/observability-functional-test.sh
```

Variaveis:

- `BASE_URL`: default `http://localhost:8082`.
- `MAILPIT_URL`: default `http://localhost:8025`.
- `AUTH_TOKEN`: se informado, pula criacao de usuario e usa este JWT.
- `CREATE_USER`: default `true`; tenta criar usuario usando Mailpit.
- `ITERATIONS`: default `5`; repeticoes dos probes autenticados.

Fluxo:

1. Testa health, Prometheus, OpenAPI e Swagger UI.
2. Tenta criar usuario, ler email no Mailpit, verificar email e logar.
3. Com JWT, chama endpoints de auth, tags, dashboard, biblioteca, feed, busca, unidades e reviews.
4. Sem JWT, gera probes 401 em endpoints protegidos para validar logs/metricas de rejeicao.

Exemplo:

```bash
BASE_URL=http://localhost:8082 ITERATIONS=10 ./scripts/observability-functional-test.sh
```

## Consultas uteis

PromQL:

```promql
sum by (area, status_family) (rate(atualei_api_requests_total[5m]))
```

```promql
topk(15, sum by (endpoint, status_family) (increase(atualei_api_requests_total[1h])))
```

```promql
histogram_quantile(0.95, sum by (le, area) (rate(atualei_api_request_duration_seconds_bucket[5m])))
```

LogQL:

```logql
{compose_service="mvp"}
```

```logql
{compose_service="mvp",level=~"WARN|ERROR"}
```

```logql
{compose_service="mvp"} |= "requestId"
```

## Checklist de operacao

- `docker compose up --build` sobe todos os servicos.
- `GET /actuator/health/readiness` retorna `UP`.
- `GET /actuator/prometheus` expoe `atualei_api_requests_total`.
- Grafana mostra o dashboard `Atualei Plataforma Observability`.
- Loki recebe logs com `service="plataforma-juridica"`.
- Tempo recebe traces de requests nao-Actuator.
- Swagger UI abre e permite autenticar com JWT.
