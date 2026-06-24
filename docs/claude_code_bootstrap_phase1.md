# Claude Code 부트스트랩 — Phase 1, Epic A (스캐폴딩)

> 사용법: 이 파일 전체를 복사해 **Claude Code 첫 세션에 붙여넣으세요.**
> 같은 레포 루트에 `PRD_realestate_agent_phase1.md`를 함께 두면 Claude Code가 상세 스펙을 참조합니다.

---

너는 이 레포에서 **공공데이터 기반 분석 에이전트 플랫폼**의 Phase 1을 구현한다.
시작 전에 같은 디렉터리의 `PRD_realestate_agent_phase1.md`를 **먼저 읽고**, 그 스펙을 진실의 원천으로 삼아라.

## 확정된 결정 (변경 금지)
- 아키텍처: **폴리글랏 MSA**
  - `core-api` = **Spring Boot 3.x (Java 21)** — Job 상태머신, 휴먼 승인 게이트, 실거래가 API 캐시 프록시, trace/비용 집계, SSE
  - `agent-runtime` = **Python 3.12 + FastAPI** — tool_use 루프(에이전트의 심장)
  - `web` = **Next.js 14 (App Router, TypeScript)** — 질문 입력/승인/trace 뷰어/차트
- 메시징 = **RabbitMQ** (Kafka 아님 — Kafka는 Phase 3)
- DB = **PostgreSQL 16**
- 데이터 소스 = 국토교통부 아파트 매매 실거래가 OpenAPI
- **기본 데모 지역 = 서울 양천구 (LAWD_CD `11470`)** — 단, 지역은 하드코딩이 아니라 런타임 입력이다.

## 작업 방식 (하네스 원칙)
1. **한 번에 다 만들지 마라.** 이번 세션은 **Epic A(스캐폴딩)만** 한다. Epic B~E는 다음 세션.
2. 코드를 짜기 전에 **이번 세션 작업 계획을 먼저 제시하고 내 확인을 받아라.** (휴먼 게이트)
3. 비밀키는 코드에 하드코딩하지 말고 전부 `.env`로 주입. `ANTHROPIC_MODEL`도 환경변수로.
4. 각 서비스는 `docker compose up`으로 한 번에 떠야 한다.

## 이번 세션 산출물 (Epic A)
1. **모노레포 스캐폴딩**: `core-api/`, `agent-runtime/`, `web/`, `data/` + 루트 `README.md`
2. **docker-compose.yml**: postgres, rabbitmq, core-api, agent-runtime, web (헬스체크 포함)
3. **.env.example**: 아래 변수 포함
   ```
   ANTHROPIC_API_KEY=
   ANTHROPIC_MODEL=
   DATA_GO_KR_SERVICE_KEY=
   POSTGRES_URL=
   RABBITMQ_URL=
   AGENT_MAX_STEPS=20
   AGENT_BUDGET_TOKENS=200000
   AGENT_TIMEOUT_SEC=120
   ```
4. **DB 마이그레이션**: PRD §7 스키마(jobs, traces, api_cache, region_codes, results) 생성.
5. **region_codes 시드 로더 + 시드 데이터**: 아래 서울 25개 구를 `data/region_codes_seed.csv`로 만들고
   부팅 시(또는 마이그레이션 시) 적재. 양천구가 포함돼야 한다.
6. **각 서비스 헬스 엔드포인트**: core-api `GET /health`, agent-runtime `GET /health`, web 기본 페이지.
7. **연결 검증**: core-api가 postgres·rabbitmq에 붙고, agent-runtime이 rabbitmq에 붙는 것까지 확인하는
   최소 스모크 테스트 또는 기동 로그.

> 이번 세션에서는 **실제 에이전트 루프/실거래가 호출/비즈니스 로직을 구현하지 않는다.** 뼈대와 연결만.

## 서울 25개 구 시드 (data/region_codes_seed.csv)
```
lawd_cd,sido,sigungu,full_name
11110,서울특별시,종로구,서울특별시 종로구
11140,서울특별시,중구,서울특별시 중구
11170,서울특별시,용산구,서울특별시 용산구
11200,서울특별시,성동구,서울특별시 성동구
11215,서울특별시,광진구,서울특별시 광진구
11230,서울특별시,동대문구,서울특별시 동대문구
11260,서울특별시,중랑구,서울특별시 중랑구
11290,서울특별시,성북구,서울특별시 성북구
11305,서울특별시,강북구,서울특별시 강북구
11320,서울특별시,도봉구,서울특별시 도봉구
11350,서울특별시,노원구,서울특별시 노원구
11380,서울특별시,은평구,서울특별시 은평구
11410,서울특별시,서대문구,서울특별시 서대문구
11440,서울특별시,마포구,서울특별시 마포구
11470,서울특별시,양천구,서울특별시 양천구
11500,서울특별시,강서구,서울특별시 강서구
11530,서울특별시,구로구,서울특별시 구로구
11545,서울특별시,금천구,서울특별시 금천구
11560,서울특별시,영등포구,서울특별시 영등포구
11590,서울특별시,동작구,서울특별시 동작구
11620,서울특별시,관악구,서울특별시 관악구
11650,서울특별시,서초구,서울특별시 서초구
11680,서울특별시,강남구,서울특별시 강남구
11710,서울특별시,송파구,서울특별시 송파구
11740,서울특별시,강동구,서울특별시 강동구
```
> 전국 확장 시: code.go.kr "법정동코드 전체자료"에서 앞 5자리·시군구만 추려 같은 포맷으로 더 채우면 됨.

## 다음 세션을 위한 참고 (이번엔 구현 X, Epic B 캐시 프록시용 메모)
- 엔드포인트(상세자료): `https://apis.data.go.kr/1613000/RTMSDataSvcAptTradeDev/getRTMSDataSvcAptTradeDev`
- 파라미터: `serviceKey`, `LAWD_CD`(5자리), `DEAL_YMD`(YYYYMM), `pageNo`, `numOfRows`
- 응답(XML) 필드 매핑:
  `dealYear/dealMonth/dealDay`→계약일, `aptNm`→아파트명, `umdNm`→법정동,
  `dealAmount`→거래금액(만원, 콤마 제거 후 int), `excluUseAr`→전용면적(㎡, float),
  `buildYear`→건축년도, `floor`→층, `roadNm`→도로명
- 평 환산: `전용면적_평 = 전용면적_㎡ / 3.3`
- rate-limit: 일 1,000회 기본 → (lawd_cd, deal_ymd) 캐시 필수

---

**먼저 PRD를 읽고, 이번 세션(Epic A)의 구체 작업 계획을 제시한 뒤 내 확인을 기다려라.**
