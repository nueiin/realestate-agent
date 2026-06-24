# PRD — 공공데이터 기반 분석 에이전트 플랫폼
## Phase 1: 부동산 실거래가 분석 에이전트 (Real-Estate Insight Agent)

> 이 문서는 **Claude Code에 그대로 넣어 구현을 시작하기 위한 스펙**입니다.
> 대화 설계(Claude.ai)에서 확정한 내용을 구현 가능한 형태로 옮긴 것이며,
> 하네스/루프 엔지니어링 학습 내용을 실제 제품으로 구현하는 것이 목표입니다.

---

## 0. 한눈에 보기

- **무엇을**: 자연어 질문("강남구 vs 마포구 84㎡ 아파트 3년 평단가 추이 비교해줘")을 받아,
  에이전트가 **스스로 공공 API를 호출·분석·자가수정**하여 **차트 + 출처 달린 리포트**를 내는 시스템.
- **왜 이 주제**: 데이터가 공개 API(국토교통부 실거래가)라 **내가 가진 데이터가 0이어도 데모가 됨**.
  단일 API·구조화 데이터·시각적 자가수정 루프라 **에이전트 루프의 심장을 가장 빠르게 완성**할 수 있음.
- **포트폴리오 한 줄**: "메시지 큐 기반으로 장기 실행되는 에이전트 루프를, 휴먼 인 더 루프·trace 관측·
  외부 API rate-limit 처리까지 갖춰 프로덕션 형태로 설계했다."

### 전체 로드맵 (Phase 1이 토대, 이후는 재사용)

| Phase | 주제 | 새로 추가되는 핵심 | 재사용률 |
|---|---|---|---|
| **1 (이 문서)** | 부동산 실거래가 분석 에이전트 | 에이전트 루프 + 큐 + 휴먼게이트 + trace 뷰어 | — |
| **1.5** | Watch + 주간 다이제스트 | **스케줄 루프 + 스냅샷 비교 + 변동 알림** | Phase 1 골격 그대로 |
| 2 | 국가통계(KOSIS) 인사이트 에이전트 | **카탈로그 시맨틱 검색(RAG/pgvector/OpenSearch)** | Phase 1 골격 대부분 |
| 3 | 멀티소스 의사결정 에이전트 | **Kafka 멀티소스 fan-out + orchestrator-workers** | Phase 1+2 전체 |

> Phase 1은 **의도적으로 RAG/벡터/OpenSearch를 넣지 않음**. 루프·큐·관측을 먼저 단단히 만들고,
> 검색 엔지니어링은 Phase 2(KOSIS 13만 통계표 탐색)에서 *진짜 필요할 때* 도입한다.

---

## 1. Phase 1 범위 (Scope)

### In scope
- 자연어 질문 → 분석 작업(job) 생성 → 비동기 실행 → 결과 리포트.
- 에이전트 루프: `계획 → (휴먼 승인) → 도구 호출 → 관찰 → 자가수정 → 종료`.
- 도구 4종: 지역코드 해석 / 실거래가 조회 / 집계·분석 / 차트 스펙 생성.
- 외부 API rate-limit 대응: **응답 캐싱 + 큐 기반 직렬화**.
- 실시간 trace 스트리밍 + trace 뷰어(웹).
- 토큰 비용·단계 수·소요시간 로깅.

### Out of scope (이번엔 안 함)
- 로그인/멀티테넌시(단일 사용자로 시작, 인증은 stub).
- 벡터 검색/RAG/OpenSearch (→ Phase 2).
- Kafka (→ Phase 3; Phase 1은 RabbitMQ 단일 큐).
- 전월세/오피스텔 등 다른 유형(아파트 매매 1종으로 시작, 확장 쉬움).
- 예측·ML 모델(서술형 인사이트 + 기초 통계까지만).

### 완료 기준 (Definition of Done)
1. "서울 종로구 2024년 아파트 평균 매매가 추이" 질문에 차트+리포트가 나온다.
2. 잘못된 지역명("강남")을 줘도 에이전트가 후보를 제시하거나 보정한다(자가수정 루프 관측 가능).
3. 같은 (지역,월) 재질의 시 API를 다시 안 부른다(캐시 hit이 trace에 보인다).
4. 웹에서 `계획 → 도구호출 → 결과`가 실시간으로 흐른다.
5. 작업당 토큰 비용이 대시보드에 집계된다.

---

## 2. 아키텍처

폴리글랏 MSA. "비즈니스/오케스트레이션은 Java(Spring), AI 런타임은 Python"으로 분리 —
실제 중견·대기업 패턴이며 그 자체가 아키텍처 성숙도 시그널.

```
                          ┌─────────────────────────┐
  [Next.js Web]  ──REST──▶│      core-api (Spring)   │
       ▲   ▲              │  - Job 상태머신/영속화    │
       │   │  SSE(trace)  │  - 휴먼 승인 게이트        │
       │   └──────────────│  - 실거래가 응답 캐시      │
       │                  │  - 비용/trace 집계         │
       │                  └─────────┬───────────────┘
       │                            │ publish job
       │                            ▼
       │                      [RabbitMQ]  ── analysis.jobs 큐
       │                            │ consume
       │                            ▼
       │                  ┌─────────────────────────┐
       │   trace 이벤트    │  agent-runtime (Python)  │  ◀── 루프의 심장
       └──────────────────│  - tool_use 루프          │
                          │  - 도구 4종               │
                          │  - 종료조건/자가수정       │
                          └─────────┬───────────────┘
                                    │ tool: fetch_apt_trades
                                    ▼
                        [국토교통부 실거래가 OpenAPI]
                         (core-api 캐시 경유 호출)

  [PostgreSQL]  ← jobs / traces / results / region_codes / api_cache
```

### 서비스 책임 분리
- **core-api (Spring Boot)**: 진실의 원천(상태·영속화). 외부 API 캐시와 rate-limit 게이트키퍼.
  에이전트는 실거래가 API를 *직접* 부르지 않고 **core-api의 캐시 엔드포인트를 경유** → 캐시·쿼터 통제 일원화.
- **agent-runtime (Python/FastAPI)**: LLM 호출과 루프만 담당. 상태를 들고 있지 않음(stateless worker).
- **web (Next.js)**: 입력·승인·trace 뷰어·차트.

> **NestJS로 교체 시**: `core-api`를 NestJS로 바꾸면 됨. 바뀌는 것 = (a) 큐 클라이언트(amqplib/`@nestjs/microservices`),
> (b) SSE(`@Sse()` 데코레이터), (c) ORM(JPA→Prisma/TypeORM). 나머지 계약(REST/큐 메시지/DB 스키마)은 동일.
> Next.js와 언어(TS)가 통일되는 장점이 있고, Spring은 대기업 Java/JPA/Kafka 시그널이 강함 — 둘 다 정답.

---

## 3. 기술 스택 (pinned)

| 레이어 | 선택 | 비고 |
|---|---|---|
| Core API | **Spring Boot 3.x (Java 21)** | JPA, Spring Web, Spring AMQP, SSE |
| Agent Runtime | **Python 3.12 + FastAPI** | `anthropic` SDK, `pandas`, `pika`(RabbitMQ) |
| LLM | **Claude (anthropic API)** | 모델 문자열은 환경변수로 주입 |
| 메시징 | **RabbitMQ** | Phase 1 단일 작업 큐 (Kafka는 Phase 3) |
| DB | **PostgreSQL 16** | jobs/traces/results/region_codes/api_cache |
| 캐시 | Postgres 테이블 또는 **Redis**(택1) | Phase 1은 Postgres 캐시로 충분 |
| Web | **Next.js 14 (App Router) + TypeScript** | SSE 구독, 차트(recharts/visx) |
| 관측 | trace 테이블 + 선택적 **Langfuse(self-host)** | Phase 1은 자체 trace로 시작 |
| 인프라 | **Docker Compose** → AWS(ECS/EC2) | 로컬은 compose 한 방 |

---

## 4. 데이터 소스 스펙 — 국토교통부 아파트 매매 실거래가

- **신청**: data.go.kr → "국토교통부_아파트 매매 실거래가 자료/상세자료" 활용신청(자동승인). 무료.
- **엔드포인트(상세자료 예시)**:
  `https://apis.data.go.kr/1613000/RTMSDataSvcAptTradeDev/getRTMSDataSvcAptTradeDev`
  (일반자료는 `...AptTrade/getRTMSDataSvcAptTrade`. 상세자료가 필드가 더 많아 권장)
- **요청 파라미터**:
  - `serviceKey` (발급키; 인코딩/디코딩 키 구분 주의)
  - `LAWD_CD` (법정동코드 **앞 5자리** = 시군구. 예: 서울 종로구 `11110`)
  - `DEAL_YMD` (계약년월 `YYYYMM`. 예: `202401`)
  - `pageNo`, `numOfRows` (페이지네이션)
- **응답**: XML(기본). 주요 필드 = 거래금액(`dealAmount`, 만원·콤마문자열), 아파트명, 전용면적,
  층, 건축년도, 년/월/일, 법정동, 지번 등. → 파싱 후 **숫자/날짜 정규화 필요**.
- **제약 / 설계 함의**:
  - 일일 호출 **1,000회 기본** → **반드시 캐시**. (LAWD_CD, DEAL_YMD) 단위로 캐싱.
  - 한 번에 한 달치만 옴 → "3년 추이"는 **36회 호출** → 캐시·큐 직렬화가 정당화됨.
  - 데이터는 약 2006년~현재.
  - 법정동코드 마스터: code.go.kr "법정동코드 전체자료" → `region_codes` 테이블로 시드.
- **법적**: 공공데이터법에 따라 영리/비영리 자유 이용(출처 표시 권장).

> 확장 포인트(코드 동일, 서비스명만 교체): 오피스텔 `...OffiTrade`, 전월세 `...AptRent` 등.
> 전세가율 분석은 매매+전월세 조합. Phase 1은 아파트 매매 1종만.

---

## 5. 에이전트 루프 설계 (루프 엔지니어링 핵심)

### 5.1 루프 개요
```
시스템프롬프트(역할/도구/종료조건)
  └▶ LLM: 질문 해석 → 계획 수립 (지역/기간/분석유형 추출)
       └▶ [휴먼 게이트] "종로구 / 2024-01~12 / 평단가 추이 — 진행할까요?"  (승인 대기)
            └▶ tool_use 루프 시작:
                 resolve_region → fetch_apt_trades(×N개월) → analyze → make_chart
                 각 단계 결과를 observe → 필요시 파라미터 교정(자가수정)
            └▶ 종료조건 충족 시 최종 리포트(JSON) 산출
```

### 5.2 도구 스키마 (anthropic tool 정의)
```jsonc
// 1) 지역명 → 법정동코드. 모호하면 후보 반환(자가수정 트리거)
resolve_region(name: string)
  -> { matches: [{ lawd_cd: "11110", sido:"서울", sigungu:"종로구" }, ...] }

// 2) 실거래가 조회 (core-api 캐시 경유). 월 단위.
fetch_apt_trades(lawd_cd: string, deal_ymd: "YYYYMM")
  -> { rows: [{ apt, area_m2, price_manwon, floor, build_year, date }], cached: bool }

// 3) 분석/집계 (pandas). 평단가/거래량/추이/이상치 제거 등.
analyze(dataset_ref: string, ops: ["mean_price_per_pyeong","monthly_trend","volume"], filters?)
  -> { tables: {...}, summary_stats: {...} }

// 4) 차트 스펙 생성 (프론트가 렌더). 데이터 직접 그리지 않음.
make_chart(type: "line"|"bar", series: [...], title: string)
  -> { chart_spec: {...} }
```

### 5.3 하네스 규칙 (이전에 학습한 체크리스트 반영)
- **명시적 종료조건**: `max_steps`(예: 20), `budget_tokens`, `timeout_sec`. 초과 시 안전 종료 + 부분결과.
- **휴먼 인 더 루프**: 실제 API를 다수 호출하기 *전* 계획 승인 1회. (쿼터 보호 + 안전)
- **전 도구 호출 로깅**: 입력·출력·소요·캐시여부를 trace로. (디버깅·데모의 생명줄)
- **자가수정 예시**: 지역 모호("강남"→강남구/강남대로?) → 후보 제시 / 빈 응답(거래 0건 달) → 인접월 보정.
- **컨텍스트 관리**: 원시 거래 rows는 컨텍스트에 다 넣지 말고 `dataset_ref`로 참조, 요약·통계만 모델에.
- **비용 가드**: 작업 시작 시 예상 호출수 안내(예: "36개월 → 최대 36 API 호출, 캐시 후 N회").

---

## 6. 레포 구조 (monorepo)

```
realestate-agent/
├── docker-compose.yml
├── .env.example
├── README.md
├── core-api/                 # Spring Boot
│   ├── src/main/java/.../JobController, ApprovalController, TraceController(SSE)
│   ├── .../job/{Job, JobStatus, JobStateMachine}
│   ├── .../proxy/RealEstateApiClient + Cache(api_cache)
│   ├── .../messaging/JobPublisher, TraceConsumer
│   └── .../trace/{TraceEvent, CostAggregate}
├── agent-runtime/            # Python FastAPI worker
│   ├── app/main.py           # 큐 컨슈머 + (옵션)HTTP
│   ├── app/loop.py           # tool_use 루프 본체
│   ├── app/tools/{region.py, trades.py, analyze.py, chart.py}
│   ├── app/trace.py          # trace 이벤트 발행
│   └── app/prompts/system.md
├── web/                      # Next.js
│   ├── app/(query 입력, 승인 모달, trace 뷰어, 결과 차트)
│   └── lib/sse.ts
└── data/
    └── region_codes_seed.csv # 법정동코드 5자리 마스터(code.go.kr)
```

---

## 7. 데이터 모델 (PostgreSQL)

```sql
-- 분석 작업
jobs(
  id uuid pk, question text, status text,         -- PLANNING/AWAIT_APPROVAL/RUNNING/DONE/FAILED/CANCELLED
  plan jsonb, result jsonb, error text,
  total_tokens int, total_cost_usd numeric, steps int,
  created_at, updated_at
)
-- 루프 trace (한 작업에 여러 이벤트)
traces(
  id bigserial pk, job_id uuid fk, seq int,
  type text,                                       -- PLAN/TOOL_CALL/TOOL_RESULT/SELF_CORRECT/FINAL
  tool_name text, input jsonb, output jsonb,
  duration_ms int, cached bool, tokens int, ts timestamptz
)
-- 외부 API 응답 캐시 (rate-limit 보호)
api_cache(
  lawd_cd text, deal_ymd text, payload jsonb, fetched_at timestamptz,
  primary key (lawd_cd, deal_ymd)
)
-- 법정동코드 마스터 (시드)
region_codes( lawd_cd text pk, sido text, sigungu text, full_name text )
-- 결과 산출물(차트 스펙/리포트)
results( job_id uuid pk fk, report_md text, charts jsonb )
```

---

## 8. Core API 설계 (REST + SSE)

```
POST /api/jobs                  { question }            -> { jobId, plan, status: AWAIT_APPROVAL }
POST /api/jobs/{id}/approve     { approved: bool, edits? } -> 큐 발행, status: RUNNING
GET  /api/jobs/{id}                                     -> job 상태/결과
GET  /api/jobs/{id}/trace       (SSE 스트림)             -> trace 이벤트 실시간
GET  /api/jobs/{id}/result                              -> report_md + charts

# 에이전트 런타임이 사용하는 내부 캐시 프록시
GET  /internal/apt-trades?lawd_cd=&deal_ymd=            -> 캐시 우선, miss 시 국토부 API 호출 후 저장
POST /internal/trace            { jobId, event }        -> trace 적재(+비용 집계)

GET  /api/stats/cost                                    -> 작업별/누적 토큰·비용 대시보드용
```

흐름: `POST /jobs`(LLM이 계획만 수립, API 호출 X) → 사용자 승인 → 큐 발행 →
agent-runtime 소비 → 루프 돌며 `/internal/apt-trades`·`/internal/trace` 호출 → 완료 시 result 저장.

---

## 9. 데모 시나리오 (시연 스크립트)

1. 입력: **"서울 종로구 2024년 아파트 평균 매매가 월별 추이 보여줘"**
2. 화면: 계획 카드 표시 → "종로구(11110) / 2024-01~12 / 월별 평균가 · 최대 12 API 호출" → **[승인]**
3. trace 뷰어가 실시간으로 흐름: `resolve_region`→`fetch_apt_trades`(캐시 miss/hit 뱃지)→`analyze`→`make_chart`
4. 결과: **라인차트 + 출처(국토교통부 실거래가) 명시 리포트** + 작업 비용($0.0x) 표시
5. 추가 시연(자가수정): **"강남 아파트 알려줘"** → 모호 → 에이전트가 "강남구로 해석" 또는 후보 제시하는 trace.
6. 추가 시연(캐시): 같은 질문 재실행 → API 호출 0, 응답 즉시 → "rate-limit을 캐시로 다뤘다" 어필.

---

## 10. Phase 1 작업 분해 (Claude Code 진행용 체크리스트)

**Epic A — 스캐폴딩 & 인프라**
- [ ] docker-compose: postgres, rabbitmq, core-api, agent-runtime, web
- [ ] `.env.example`(SERVICE_KEY, ANTHROPIC_API_KEY, DB/MQ 접속, MODEL 등)
- [ ] DB 마이그레이션(위 스키마) + `region_codes` 시드 로더

**Epic B — core-api (Spring)**
- [ ] Job 엔티티 + 상태머신 + `POST /api/jobs`(계획 수립은 agent-runtime에 위임 or 동기 호출)
- [ ] 승인 엔드포인트 + 큐 발행(Spring AMQP)
- [ ] `/internal/apt-trades` 캐시 프록시(국토부 API 호출·XML 파싱·정규화·`api_cache` 저장)
- [ ] `/internal/trace` 적재 + 비용 집계, `/api/jobs/{id}/trace` SSE
- [ ] `/api/stats/cost`

**Epic C — agent-runtime (Python)**
- [ ] RabbitMQ 컨슈머 + 작업 수명주기
- [ ] tool_use 루프(`loop.py`) + 종료조건(max_steps/budget/timeout)
- [ ] 도구 4종 구현(region/trades/analyze/chart) — trades는 core-api 프록시 호출
- [ ] 자가수정 처리(모호 지역/빈 응답) + trace 발행
- [ ] system 프롬프트 작성(`prompts/system.md`)

**Epic D — web (Next.js)**
- [ ] 질문 입력 + 계획 승인 모달
- [ ] SSE 구독 trace 뷰어(단계별 카드, 캐시 뱃지)
- [ ] 결과 차트(recharts) + 리포트 렌더 + 비용 표시

**Epic E — 마무리**
- [ ] README(아키텍처·실행법·ADR 1~2개: "왜 폴리글랏", "왜 캐시+큐")
- [ ] 데모 시나리오대로 e2e 점검
- [ ] (선택) Langfuse 연동 / AWS 배포

---

## 11. 이후 단계로 가는 다리 (재사용 설계)

- **Phase 2 (KOSIS 인사이트)**: `resolve_region`을 **카탈로그 시맨틱 검색**으로 일반화 —
  "질문 → 통계표/지표 코드" 매핑을 pgvector + OpenSearch 하이브리드로. 나머지 골격(큐·trace·휴먼게이트·차트)은 그대로.
- **Phase 3 (멀티소스 의사결정)**: RabbitMQ를 **Kafka**로 승격, 소스별 워커로 fan-out하고
  **orchestrator-workers**로 병렬 조회 → **evaluator-optimizer**로 리포트 자기검증.

> 즉 Phase 1에서 만든 루프 엔진·trace 파이프라인·캐시/쿼터 계층·차트 프론트는 **버려지지 않고 그대로 성장**한다.

---

## 11.5 Phase 1.5 — Watch + 주간 다이제스트 (MVP 다음 증분)

> **언제**: Phase 1(on-demand 루프) 완성 후 바로 얹는 증분. MVP 골격을 그대로 재사용한다.
> **왜**: 사용자 질문 기반 루프(① on-demand)에 더해, **스케줄 기반 루프(② recurring)**를 갖춰
> "두 종류의 루프를 운영하는 하네스"를 완성한다. 동시에 Phase 3(Kafka 이벤트 드리븐)으로 가는 다리.

### 핵심 아이디어
- 사용자가 **관심지역(Watch)**을 등록(예: 양천구·마포구).
- 스케줄러가 **주기적으로**(예: 매주 금/월 — *요일은 우리가 정하는 값, KB 일정에 종속 X*) 관심지역의
  최근 1~2개월 실거래가를 **다시 당겨온다**. 실거래가는 **신고 지연(계약 후 약 30일 신고기한)**이 있어
  지난달 거래가 뒤늦게 채워지므로, **주기적 재수집이 기술적으로 정당화**된다.
- 직전 **스냅샷과 비교**해 평단가·거래량에 **유의미한 변동**이 있으면 **주간 다이제스트 리포트** 생성 +
  (휴먼 게이트) 알림.

### 데이터 모델 추가 (Postgres)
```sql
watches(
  id uuid pk, lawd_cd text fk->region_codes,
  property_type text default 'APT_TRADE',
  area_band text null,                 -- 선택: 면적대 필터(예: '60-85㎡')
  active bool default true, created_at timestamptz
)
-- 주기 실행마다 남기는 지표 스냅샷 (변동 비교의 기준)
weekly_snapshots(
  id bigserial pk, watch_id uuid fk, run_at timestamptz,
  period_ym text,                      -- 대상 계약년월
  trade_count int, avg_price_manwon numeric, avg_price_per_pyeong numeric,
  raw_stats jsonb
)
-- 변동 감지 결과 / 다이제스트
digests(
  id uuid pk, watch_id uuid fk, run_at timestamptz,
  delta jsonb,                         -- 직전 스냅샷 대비 변화율 등
  significant bool, report_md text, notified bool default false
)
```

### 변동 감지 규칙 (초기값, 환경변수로 조정)
- `avg_price_per_pyeong` 주간 변화율 **±N%**(기본 3%) 이상 → significant.
- `trade_count` 가 직전 대비 **±M%**(기본 50%) 이상 → significant.
- 신규 최고가/최저가 경신 → significant.
- significant=false면 다이제스트는 저장하되 알림은 보내지 않음(노이즈 억제).

### API 추가 (core-api)
```
POST   /api/watches              { lawd_cd, property_type?, area_band? }  -> watch 등록
GET    /api/watches                                                       -> 목록
DELETE /api/watches/{id}                                                  -> 해제
POST   /api/watches/{id}/run     (수동 트리거)  -> 스케줄 파이프라인을 즉시 1회 실행  ★데모용
GET    /api/watches/{id}/digests                                          -> 다이제스트 이력
```

### 스케줄러 & 루프 재사용
- **스케줄러**: Spring `@Scheduled`(cron, 예 `0 0 9 * * FRI`) 또는 Quartz.
  → 활성 watch들에 대해 refresh job을 **RabbitMQ에 enqueue**(Phase 1과 동일 큐 경로).
- **에이전트 루프 재사용**: 기존 `fetch_apt_trades → analyze` 도구를 그대로 호출.
  추가되는 건 `snapshot_compare(watch_id, new_stats)` 도구/스텝과 다이제스트 작성 프롬프트뿐.
- **수동 트리거**(`/run`)는 **스케줄과 동일한 파이프라인**을 즉시 실행 → 스케줄 플로우를 코드 분기 없이
  on-demand로도 호출(좋은 하네스 설계 + 데모 가능).

### 데모 주의 (중요)
- 스케줄 작업은 **라이브 시연이 어렵다**(일주일 대기 불가).
- 따라서 **`POST /api/watches/{id}/run` 수동 트리거 버튼**으로 그 자리에서 주간 파이프라인을 돌려 보여준다:
  "관심지역 등록 → [지금 새로고침] → 스냅샷 비교 trace → 변동 감지 → 다이제스트 리포트".

### 작업 분해 (Epic F — Phase 1.5)
- [ ] `watches/weekly_snapshots/digests` 마이그레이션
- [ ] watch CRUD API + 수동 트리거 `/run`
- [ ] 스케줄러(@Scheduled/cron) → refresh job enqueue
- [ ] `snapshot_compare` 스텝 + 변동 감지 규칙(임계값 env)
- [ ] 다이제스트 작성 프롬프트 + significant 시 알림(우선 웹 인앱 알림으로 시작)
- [ ] web: 관심지역 관리 UI + "지금 새로고침" 버튼 + 다이제스트 타임라인

> **Phase 3 연결**: 이 "주기 트리거 → 변동 감지 → 알림" 구조가 RabbitMQ→**Kafka** 승격 시
> 소스별 이벤트 fan-out으로 자연스럽게 확장된다.

---

## 12. 환경 변수 (.env.example)
```
ANTHROPIC_API_KEY=
ANTHROPIC_MODEL=                 # 모델 문자열 주입(하드코딩 금지)
DATA_GO_KR_SERVICE_KEY=          # 디코딩 키 권장
POSTGRES_URL=
RABBITMQ_URL=
AGENT_MAX_STEPS=20
AGENT_BUDGET_TOKENS=200000
AGENT_TIMEOUT_SEC=120
# --- Phase 1.5 (Watch + 주간 다이제스트) ---
WATCH_SCHEDULE_CRON=0 0 9 * * FRI   # 주간 실행 시각(요일은 자유. KB와 무관)
WATCH_REFRESH_MONTHS=2              # 매 실행 시 다시 당겨올 최근 개월 수(신고 지연 대응)
DIGEST_PRICE_DELTA_PCT=3           # 평단가 변화율 임계값(%)
DIGEST_VOLUME_DELTA_PCT=50         # 거래량 변화율 임계값(%)
```
