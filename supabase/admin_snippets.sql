-- ============================================================
-- 🍱 오늘점심 — 운영용 SQL 스니펫 모음
--
-- ⚠️⚠️ 이 파일은 **통째로 실행하면 안 됩니다.** ⚠️⚠️
--    01~17 마이그레이션 파일과 달리, 여기 있는 것은 "필요할 때 하나씩 골라 쓰는" 명령입니다.
--    실행 방법: 필요한 블록만 드래그해서 선택 → Supabase SQL Editor에서 Run
--               (SQL Editor는 선택 영역만 실행할 수 있습니다)
--
-- 💡 왜 함수(admin_reset_password 같은)로 만들지 않았나?
--    Postgres는 함수를 만들면 기본으로 PUBLIC에 EXECUTE를 부여합니다.
--    관리자 함수를 만들어두면, 공개 anon 키를 아는 누구나
--      select admin_reset_password('남의아이디', '아무비번');
--    를 호출해 **다른 사람 계정을 탈취할 수 있습니다.**
--    (12_v2_grants_fix.sql은 api_*/fn_* 접두어만 회수하므로 admin_* 는 걸러지지도 않습니다)
--    그래서 함수로 만들지 않고, SQL Editor 접근 권한이 있어야만 실행되는
--    생 SQL 스니펫으로 둡니다. 이 방침을 바꾸지 마세요.
-- ============================================================


-- ────────────────────────────────────────────────────────────
-- [1] 임시 비밀번호 발급  ★가장 자주 쓰는 작업
-- ────────────────────────────────────────────────────────────
-- 사용 전 확인:
--   · 이메일이 등록된 사용자라면 이 작업이 필요 없습니다.
--     앱 로그인 화면의 "비밀번호를 잊으셨나요?"로 본인이 직접 재설정하게 안내하세요.
--     (운영자가 비밀번호를 알게 되지 않으므로 그쪽이 안전합니다)
--   · 임시 비밀번호는 앱 규칙(8자 이상 + 영문 + 숫자)을 만족해야
--     사용자가 로그인 후 스스로 변경할 수 있습니다.
--   · 혼동되는 문자(0 O 1 l I)는 빼고 만드세요.

-- [1-1] 먼저 계정과 이메일 등록 여부 확인  ← 아이디만 바꿔서 실행
select login_id, nickname, (email is not null) as 이메일등록됨, created_at
from users
where login_id = '여기에_아이디';

-- [1-2] 이메일이 없을 때만 아래 블록을 실행 (아이디와 임시비번 2군데씩 총 3곳 수정)
/*
set search_path = public, extensions;

update users
set password_hash = crypt('여기에_임시비밀번호', gen_salt('bf'))
where login_id = '여기에_아이디'
  and coalesce(is_guest, false) = false;

-- 비밀번호를 5회 틀려 10분 차단된 상태일 수 있으므로 함께 해제
delete from login_attempts where login_id = '여기에_아이디';

-- 적용 확인 — 임시비번_적용됨 이 true 면 완료 (행이 안 나오면 아이디가 틀린 것)
select login_id, nickname,
       (password_hash = crypt('여기에_임시비밀번호', password_hash)) as 임시비번_적용됨
from users
where login_id = '여기에_아이디';
*/

-- [1-3] (선택) 보안상 기존 로그인 세션까지 전부 끊고 싶을 때
--       평소에는 실행하지 마세요. 다른 기기에서 로그인 중이면 그것까지 로그아웃됩니다.
/*
delete from sessions
where user_id = (select id from users where login_id = '여기에_아이디');
*/


-- ────────────────────────────────────────────────────────────
-- [2] 로그인 차단만 해제 (비밀번호는 그대로)
--     "비밀번호는 아는데 여러 번 틀려서 잠겼다"고 할 때
-- ────────────────────────────────────────────────────────────
select login_id, fail_count, blocked_until
from login_attempts
where login_id = '여기에_아이디';

/*
delete from login_attempts where login_id = '여기에_아이디';
*/


-- ────────────────────────────────────────────────────────────
-- [3] 이메일 미등록자 현황
--     미등록자가 많으면 비밀번호 분실 요청이 계속 들어옵니다.
--     앱의 이메일 등록 유도 배너가 이분들에게 노출됩니다.
-- ────────────────────────────────────────────────────────────
select count(*) filter (where email is null)     as 이메일없음_셀프복구불가,
       count(*) filter (where email is not null) as 이메일있음_셀프복구가능
from users
where not coalesce(is_guest, false);

-- 누가 미등록인지 (닉네임만 확인 — 필요할 때만)
select login_id, nickname, created_at
from users
where email is null and not coalesce(is_guest, false)
order by created_at;


-- ────────────────────────────────────────────────────────────
-- [4] 크론 상태 점검
--     크론이 멈춰도 화면에는 아무 표시가 없습니다.
--     "어제 채팅이 안 지워졌다", "알림 메일이 안 온다" 같은 제보가 오면 여기부터 보세요.
-- ────────────────────────────────────────────────────────────
select jobname, schedule, active, command
from cron.job
where jobname like 'lunchbuddy%' or jobname like 'today-lunch%'
order by jobname;

-- 최근 실행 이력과 실패 여부 (status가 'failed'면 return_message 확인)
select j.jobname, r.status, r.return_message, r.start_time
from cron.job_run_details r
join cron.job j on j.jobid = r.jobid
order by r.start_time desc
limit 20;


-- ────────────────────────────────────────────────────────────
-- [5] 함수 실행 권한 점검
--     api_* 만 true 여야 정상입니다. fn_* 이 true 로 보이면
--     12_v2_grants_fix.sql 을 다시 실행하세요.
--     (02·06·07 파일을 재실행하면 예전 blanket grant 때문에 다시 열립니다)
-- ────────────────────────────────────────────────────────────
select p.proname, has_function_privilege('anon', p.oid, 'execute') as anon_can_run
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' and (p.proname like 'api\_%' or p.proname like 'fn\_%')
order by anon_can_run desc, p.proname;


-- ────────────────────────────────────────────────────────────
-- [6] RLS 잠금 점검
--     모든 테이블이 rls_enabled = true 이고 정책 수가 0 이어야 정상입니다.
--     (정책 없이 RLS만 켜면 = 함수를 통해서만 접근 가능)
-- ────────────────────────────────────────────────────────────
select c.relname as 테이블,
       c.relrowsecurity as rls_enabled,
       (select count(*) from pg_policies p
         where p.schemaname = 'public' and p.tablename = c.relname) as 정책수
from pg_class c
join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public' and c.relkind = 'r'
order by c.relrowsecurity, c.relname;


-- ────────────────────────────────────────────────────────────
-- [7] 서비스 현황 요약
-- ────────────────────────────────────────────────────────────
select
  (select count(*) from users where not coalesce(is_guest,false)) as 회원수,
  (select count(*) from users where coalesce(is_guest,false))     as 게스트수,
  (select count(*) from rooms)                                    as 방수,
  (select count(*) from rooms where purpose = 'event')            as 이벤트방수,
  (select count(*) from responses where date = (now() at time zone 'Asia/Seoul')::date) as 오늘응답수,
  (select count(*) from sessions where expires_at > now())        as 유효세션수;


-- ────────────────────────────────────────────────────────────
-- [8] 알림 메일 설정 확인
--     frontend_url 이 실제 서비스 주소와 다르면
--     알림·비밀번호 재설정 메일이 죽은 링크를 보냅니다.
-- ────────────────────────────────────────────────────────────
select key,
       case when key in ('mail_relay_secret', 'resend_api_key')
            then '(비밀값 — 표시 생략)' else value end as value
from app_config
order by key;
