# 🍱 오늘점심

> 오늘 같이 식당 가요 — 사내 식당 점심 멤버 확인 서비스

매일 점심, 오늘 사내 식당에 누가 가는지 한눈에 확인하고 자연스럽게 동행하는 웹 서비스입니다.
Supabase(Postgres + Auth 대체 자체 로그인 + Realtime 인프라) 기반으로 동작합니다.

## 주요 기능

- 🔐 아이디/비밀번호 회원가입 (개인정보 최소 수집), 이메일 등록자는 셀프 비밀번호 재설정 가능
- 🏠 점심방 생성·복수 운영, 초대 링크(7일 만료) + 방 코드(영구)로 참여
- 🟢 오늘 같이 가요 / ⚫ 오늘은 안 가요 — 실시간 현황 확인 (미응답자는 접기)
- 💬 방별 간단 채팅 (당일만 보관)
- 📅 월간(최근 30일) 참여 히스토리 달력
- 🔔 이메일 알림 (선택 수집, 호스트가 방별 발송 시각 설정)
- 📖 첫 접속 온보딩 안내 (설정에서 다시 보기)
- 👑 호스트·공동 호스트 방 관리 (멤버 관리, 방 삭제는 호스트 전용)
- ⏳ 모든 액션에 실행 중 표시 (상단 로딩 바 + 버튼 비활성화)

## 서비스 주소

**https://gomsbox.github.io/lunchbuddy/** (GitHub Pages — 저장소/URL은 이전 이름 유지, 화면상 서비스명만 "오늘점심"으로 변경됨)

## 구조 및 저장소 구성

프론트엔드는 GitHub Pages가 서빙하고, 백엔드는 **Supabase**(Postgres RPC 함수 + pg_cron + pg_net)가 처리합니다.

| 경로 | 내용 |
|------|------|
| [`docs/index.html`](docs/index.html) | **프론트엔드** (서비스 화면 전체 — GitHub Pages가 서빙, Supabase JS 클라이언트로 통신) |
| [`supabase/`](supabase/) | **백엔드** SQL 스키마·RPC 함수·크론 (Supabase SQL Editor에서 실행) |
| [`docs/index-appsscript-legacy.html`](docs/index-appsscript-legacy.html) | (배포 안 됨) 이전 구글 앱스크립트 버전 백업 — 참고용 |
| [`lunchbuddy-gas/`](lunchbuddy-gas/) | (더 이상 운영에 사용 안 함) 이전 구글 앱스크립트 백엔드 소스 — 참고용 |

## 배포 방법

1. Supabase 프로젝트 생성
2. `supabase/01_schema.sql` → `02_functions.sql` → `03_cron.sql`을 SQL Editor에서 순서대로 실행
3. `03_cron.sql` 하단 안내에 따라 `app_config`에 `resend_api_key`, `owner_email`, `frontend_url` 값 등록 (이메일 알림용)
4. `docs/index.html`의 `SUPABASE_URL` / `SUPABASE_ANON_KEY`를 프로젝트 값으로 교체 후 push

프론트 수정은 push만 하면 1~2분 내 자동 반영됩니다. 백엔드(SQL) 수정은 Supabase SQL Editor에서 `create or replace function`으로 재실행하면 됩니다 (재배포 절차 없음).
