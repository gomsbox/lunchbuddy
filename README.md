# 🍱 오늘점심

> 오늘 누구랑 먹을지, 뭘 먹을지 — 점심 멤버 확인 · 메뉴 투표 서비스

방을 만들어 링크만 공유하면, 오늘 누가 같이 가는지 한눈에 확인하고 메뉴는 투표로 정할 수 있는 웹 서비스입니다.
구내식당 동행 확인부터 외부 식당 메뉴 기록, 회식·워크숍 참석 조사까지 쓸 수 있습니다.
Supabase(Postgres + Auth 대체 자체 로그인 + pg_cron + pg_net) 기반으로 동작합니다.

## 주요 기능

- 🔐 아이디/비밀번호 회원가입 (개인정보 최소 수집), 이메일 등록자는 셀프 비밀번호 재설정 가능
- 🏠 방 생성·복수 운영, 초대 링크(7일 만료) + 방 코드(영구)로 참여, ↕ 방 목록 순서 편집
- 🏢 **방 종류 프리셋 5종** — 사내식당형 / 외부 점심형 / 메뉴 투표형 / 이벤트형(1회용) / 자유 설정
- 🟢 오늘 같이 가요 / ⚫ 오늘은 안 가요 — 실시간 현황 확인 (미응답자는 접기)
- 🍽 **먹은 장소·메뉴 기록** (선택) + 자동완성 + 🎲 최근 먹은 것 중 랜덤 추천
- 🏆 **최근 30일 메뉴 랭킹** — 방 전체 Top5 / 내 Top3 / 많이 간 곳 Top3
- 🗳 **메뉴 투표** — 후보 2~6개, 1인 1표(재투표 가능), 마감 시각 자동 마감, 동점이면 룰렛 🎲
- 🎉 **이벤트형 방** — 초대 링크만으로 참여, 받은 사람은 **가입 없이 이름만** 입력. 마감 후 결과 요약, 일정 기간 뒤 자동 삭제
- 💬 방별 간단 채팅 (당일만 보관, 읽음 표시)
- 📅 최근 30일 참여 히스토리 달력 (날짜별 장소·메뉴 포함)
- 🔔 이메일 알림 (선택 수집, 호스트가 방별 발송 요일·시각 설정)
- 📖 첫 접속 온보딩 안내 (설정에서 다시 보기)
- 👑 호스트·공동 호스트 방 관리 (멤버 관리, 방 삭제는 호스트 전용)
- 🚪 회원 탈퇴 (비밀번호 확인, 호스트인 방은 명시 동의 후 함께 삭제)
- ⏳ 모든 액션에 실행 중 표시 (상단 로딩 바 + 버튼 비활성화)

## 서비스 주소

**https://gomsbox.github.io/lunchbuddy/** (GitHub Pages — 저장소/URL은 이전 이름 유지, 화면상 서비스명만 "오늘점심"으로 변경됨)

## 구조 및 저장소 구성

프론트엔드는 GitHub Pages가 서빙하고, 백엔드는 **Supabase**(Postgres RPC 함수 + pg_cron + pg_net)가 처리합니다.

| 경로 | 내용 |
|------|------|
| [`docs/index.html`](docs/index.html) | **프론트엔드** (서비스 화면 전체 — GitHub Pages가 서빙, Supabase JS 클라이언트로 통신) |
| [`supabase/`](supabase/) | **백엔드** SQL 스키마·RPC 함수·크론 (Supabase SQL Editor에서 실행) |
| [`mail-relay/`](mail-relay/) | **메일 릴레이** 앱스크립트 (구글 계정으로 알림 메일 발송 — Resend 403 대체) |
| [`docs/index-appsscript-legacy.html`](docs/index-appsscript-legacy.html) | (배포 안 됨) 이전 구글 앱스크립트 버전 백업 — 참고용 |
| [`lunchbuddy-gas/`](lunchbuddy-gas/) | (더 이상 운영에 사용 안 함) 이전 구글 앱스크립트 백엔드 소스 — 참고용 |

## 배포 방법

1. Supabase 프로젝트 생성
2. `supabase/` 의 SQL을 **번호 순서대로** SQL Editor에서 실행
   - v1 기본: `01_schema.sql` → `02_functions.sql` → `03_cron.sql` → `05_mail_relay.sql` → `06_notify_days.sql` → `07_chat_read_receipts.sql`
   - v2: `08_v2_schema.sql` → `09_v2_room_purpose.sql` → `10_v2_meal_log.sql` → `11_v2_menu_ranking.sql` → `12_v2_grants_fix.sql` → `13_v2_menu_poll.sql` → `14_v2_event_room.sql` → `15_v2_account.sql` → `16_v2_room_order.sql` → `17_v2_notify_copy.sql`
   - 모든 파일은 재실행해도 안전합니다 (`add column if not exists`, `create or replace`)
3. 이메일 알림용 설정:
   - `mail-relay/Code.gs`를 새 앱스크립트 프로젝트로 만들어 웹 앱 배포 (파일 상단 설치 방법 참고)
   - `app_config`에 `mail_relay_url`, `mail_relay_secret`, `owner_email`, `frontend_url` 값 등록 (`05_mail_relay.sql` 하단 안내 참고)
   - ⚠️ Resend는 사용하지 않음 — 도메인 인증 없이는 테스트 발신 주소가 계정 본인에게만 발송 가능(그 외 수신자는 403 거부)해서 앱스크립트(MailApp) 릴레이로 교체함
4. `docs/index.html`의 `SUPABASE_URL` / `SUPABASE_ANON_KEY`를 프로젝트 값으로 교체 후 push

프론트 수정은 push만 하면 1~2분 내 자동 반영됩니다. 백엔드(SQL) 수정은 Supabase SQL Editor에서 `create or replace function`으로 재실행하면 됩니다 (재배포 절차 없음).

## 함수 실행 권한 (중요)

프론트가 호출하는 **`api_*` 함수만** `anon`·`authenticated`에 실행 권한을 줍니다. `fn_*` 내부 헬퍼와 크론 전용 함수는 열지 않습니다.

- 새 SQL 파일에는 `grant execute on all functions in schema public ...` 를 **쓰지 마세요.** 이 문장은 내부 헬퍼까지 공개 anon 키로 호출 가능하게 만듭니다.
- Postgres는 함수 생성 시 기본으로 `PUBLIC`에 EXECUTE를 부여하므로, 막으려면 `revoke ... from public` 까지 해야 합니다.
- `02`·`06`·`07` 에는 아직 예전 blanket grant가 남아 있습니다. **그 파일들을 재실행했다면 `12_v2_grants_fix.sql`을 마지막에 다시 실행**하세요.

권한 상태 확인:

```sql
select p.proname, has_function_privilege('anon', p.oid, 'execute') as anon_can_run
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' and (p.proname like 'api\_%' or p.proname like 'fn\_%')
order by anon_can_run desc, p.proname;
```

## 운영 절차

자주 쓰는 운영 SQL은 [`supabase/admin_snippets.sql`](supabase/admin_snippets.sql)에 모아뒀습니다.
**이 파일은 통째로 실행하지 마세요.** 필요한 블록만 드래그해서 선택한 뒤 SQL Editor에서 Run 합니다.

> ⚠️ 관리자 기능을 **함수로 만들지 않은 이유**: Postgres는 함수 생성 시 기본으로 `PUBLIC`에 EXECUTE를 부여합니다. `admin_reset_password()` 같은 함수를 두면 공개 anon 키를 아는 누구나 남의 계정 비밀번호를 바꿀 수 있습니다. (`12_v2_grants_fix.sql`은 `api_*`/`fn_*` 접두어만 회수하므로 `admin_*`는 걸러지지도 않습니다.) 그래서 SQL Editor 접근 권한이 있어야만 실행되는 생 SQL로 둡니다.

### 비밀번호 분실 문의가 왔을 때

1. **이메일 등록 여부부터 확인** (스니펫 `[1-1]`)
   - 등록돼 있으면 → 앱 로그인 화면의 **"비밀번호를 잊으셨나요?"** 를 안내. 운영자가 비밀번호를 알게 되지 않아 더 안전합니다. 여기서 끝입니다.
   - 미등록이면 → 2번으로
2. **임시 비밀번호 발급** (스니펫 `[1-2]`)
   - 8자 이상 + 영문 + 숫자 (앱 규칙을 만족해야 사용자가 로그인 후 스스로 변경 가능)
   - 혼동 문자(`0` `O` `1` `l` `I`) 제외
   - 로그인 5회 실패로 잠긴 상태일 수 있으므로 `login_attempts` 삭제가 스니펫에 포함돼 있습니다
3. **전달** — 단톡방이 아닌 **개인 메시지**로
4. **안내** — 로그인 후 ① 설정에서 비밀번호 즉시 변경 ② **이메일 등록**(다음부터 셀프 재설정 가능)

> 앱에는 이메일 미등록자에게 등록을 권하는 배너가 방 목록 상단에 뜹니다. "나중에"를 누르면 14일간 숨겨집니다. 미등록자 현황은 스니펫 `[3]`으로 확인하세요.

### 이상 징후가 보일 때

| 증상 | 확인할 것 |
|------|-----------|
| 어제 채팅이 안 지워짐 / 알림 메일이 안 옴 / 투표가 자동 마감 안 됨 | 스니펫 `[4]` 크론 상태 — **크론이 멈춰도 화면에는 아무 표시가 없습니다** |
| 데이터가 이상하게 보임·수정됨 | 스니펫 `[5]` 함수 권한, `[6]` RLS 잠금 |
| 알림 메일의 링크가 죽어 있음 | 스니펫 `[8]` — `app_config.frontend_url`이 실제 주소와 같은지 |

## 크론 작업

| 잡 이름 | 주기 (UTC) | 내용 |
|---------|-----------|------|
| `lunchbuddy-daily-reset` | `0 15 * * *` (서울 00:00) | 전일 응답 → 히스토리 집계, 채팅 리셋, 30일 경과 데이터 삭제, 열린 투표 마감 |
| `lunchbuddy-notify` | `*/5 * * * *` | 방별 알림 메일 발송 시각 확인 |
| `lunchbuddy-close-polls` | `*/5 * * * *` | 마감 시각이 지난 메뉴 투표 자동 마감 |
| `lunchbuddy-auto-close-events` | `10 16 * * *` (서울 01:10) | 기간이 지난 이벤트형 방 자동 마감 |
| `lunchbuddy-purge-events` | `20 16 * * *` (서울 01:20) | 마감 후 기간이 지난 이벤트형 방·게스트 데이터 삭제 |

```sql
select jobname, schedule from cron.job where jobname like 'lunchbuddy%' order by jobname;
```
