# Real-Estate Agent

공공데이터(국토교통부 아파트 매매 실거래가) 기반 분석 에이전트 플랫폼.

## 아키텍처

```
[Next.js Web]  ──REST──▶  [core-api (Spring Boot)]  ──RabbitMQ──▶  [agent-runtime (Python)]
                                    │                                         │
                              [PostgreSQL]                        [국토교통부 OpenAPI]
```

| 서비스 | 기술 | 역할 |
|---|---|---|
| `core-api` | Spring Boot 3.x / Java 21 | Job 상태머신, 캐시 프록시, SSE, trace 집계 |
| `agent-runtime` | Python 3.12 / FastAPI | tool_use 루프, Claude 호출 |
| `web` | Next.js 14 / TypeScript | 질문 입력, 승인, trace 뷰어, 차트 |

## 빠른 시작

```bash
# 1. 환경변수 설정
cp .env.example .env
# .env 파일에서 ANTHROPIC_API_KEY, DATA_GO_KR_SERVICE_KEY 입력

# 2. 실행
docker compose up --build

# 3. 확인
curl http://localhost:8080/health   # {"status":"UP","db":"ok","mq":"ok"}
curl http://localhost:8000/health   # {"status":"UP","mq":"ok"}
open http://localhost:3000
open http://localhost:15672         # RabbitMQ 관리 콘솔 (realestate/realestate)
```

## 서비스 포트

| 서비스 | 포트 |
|---|---|
| core-api | 8080 |
| agent-runtime | 8000 |
| web | 3000 |
| PostgreSQL | 5432 |
| RabbitMQ AMQP | 5672 |
| RabbitMQ 관리 콘솔 | 15672 |

## 주요 환경변수

| 변수 | 설명 |
|---|---|
| `ANTHROPIC_API_KEY` | Anthropic API 키 |
| `ANTHROPIC_MODEL` | 사용할 Claude 모델 (기본: claude-sonnet-4-6) |
| `DATA_GO_KR_SERVICE_KEY` | 국토교통부 OpenAPI 키 (data.go.kr 발급) |
| `AGENT_MAX_STEPS` | 에이전트 루프 최대 단계 수 (기본: 20) |
| `AGENT_BUDGET_TOKENS` | 작업당 최대 토큰 예산 (기본: 200,000) |

## ADR

**왜 폴리글랏(Java + Python)?**
비즈니스/오케스트레이션은 Spring(상태머신, JPA, AMQP)이 강하고, AI 런타임은 Python(anthropic SDK, pandas)이 생태계가 풍부하다. 역할 경계가 명확해 각 언어의 장점을 최대화한다.

**왜 캐시 + 큐?**
국토교통부 API는 일 1,000회 제한이고, "3년 추이"는 36회 호출이 필요하다. RabbitMQ로 직렬화해 rate-limit을 제어하고, PostgreSQL 캐시로 재호출을 막아 쿼터를 보호한다.
