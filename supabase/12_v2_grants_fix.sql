-- ============================================================
-- 🍱 오늘점심 v2 — 함수 실행 권한 정리 (보안 수정)
-- 08~11 실행 후 이 파일 전체를 SQL Editor에 붙여넣고 Run 하세요.
--
-- 【문제】
-- 지금까지 각 SQL 파일 끝에 아래 한 줄을 넣어 왔다.
--   grant execute on all functions in schema public to anon, authenticated;
-- 이 문장은 프론트가 호출해야 하는 api_* 함수만이 아니라 **내부 헬퍼(fn_*)까지 전부**
-- 공개 anon 키로 호출할 수 있게 만든다. 게다가 Postgres는 함수를 만들 때 기본적으로
-- PUBLIC에 EXECUTE를 주므로, grant 문을 지우는 것만으로는 막히지 않는다.
--
-- 실제 확인된 노출 (anon 키는 docs/index.html에 들어 있어 누구나 볼 수 있음):
--   - fn_meal_logs_between(room_id, from, to)
--       ⚠️ 가장 문제. 인증 검사가 없어서 방 UUID를 알면 그 방의 식사 기록
--          (userId·닉네임·장소·메뉴)을 그대로 읽을 수 있다. 3단계에서 추가한 헬퍼로,
--          다른 fn_* 헬퍼와 달리 사용자 콘텐츠를 직접 반환한다.
--   - fn_daily_reset() / fn_send_notifications()
--       크론 전용 함수인데 외부에서 호출 가능. (다만 fn_daily_reset은 "어제 이전"
--       데이터만 다루고 fn_send_notifications는 발송 창·1일 1회 제한이 있어
--       실제 피해는 제한적 — 그래도 외부에 열려 있을 이유가 없다.)
--   - fn_auth / fn_member_role / fn_require_manager / fn_new_room_code 등 내부 헬퍼
--
-- 【수정】
-- 우리가 만든 함수(api_*, fn_*)에 대해 PUBLIC·anon·authenticated의 EXECUTE를 모두 회수한 뒤,
-- **api_* 함수만** anon·authenticated에 다시 부여한다.
--   - 프론트는 api_* 함수만 호출하므로(docs/index.html의 RPC_MAP 전체가 api_*) 영향 없음
--   - api_* 함수는 SECURITY DEFINER라 내부에서 fn_* 헬퍼를 호출할 때
--     소유자 권한으로 실행되므로, 헬퍼 권한을 회수해도 정상 동작한다
--   - pg_cron 잡도 스케줄을 만든 계정(소유자) 권한으로 돌기 때문에 영향 없음
--
-- ⚠️ 02_functions.sql / 06_notify_days.sql / 07_chat_read_receipts.sql 에는 아직
--    예전 blanket grant 한 줄이 남아 있다. 그 파일들을 다시 실행하면 권한이 다시 열리므로,
--    **재실행했다면 이 파일을 마지막에 한 번 더 돌려야 한다.**
-- ============================================================

do $$
declare
  r record;
  v_revoked int := 0;
  v_granted int := 0;
begin
  for r in
    select p.oid::regprocedure::text as sig, p.proname
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      -- 우리가 만든 함수만 건드린다 (확장 함수 등은 그대로 둠)
      and (p.proname like 'api\_%' or p.proname like 'fn\_%')
  loop
    -- 함수 생성 시 기본으로 붙는 PUBLIC 권한까지 회수해야 실제로 막힌다
    execute format('revoke execute on function %s from public', r.sig);
    execute format('revoke execute on function %s from anon, authenticated', r.sig);
    v_revoked := v_revoked + 1;

    -- 프론트가 호출하는 api_* 함수만 다시 허용
    if r.proname like 'api\_%' then
      execute format('grant execute on function %s to anon, authenticated', r.sig);
      v_granted := v_granted + 1;
    end if;
  end loop;

  raise notice '권한 정리 완료 — 대상 함수 %개, 이 중 api_* %개만 anon/authenticated 실행 허용',
    v_revoked, v_granted;
end $$;

-- ============================================================
-- 실행 후 확인 — anon이 실행할 수 있는 함수 목록 (api_* 만 나와야 정상)
-- ============================================================
-- select p.proname, has_function_privilege('anon', p.oid, 'execute') as anon_can_run
-- from pg_proc p join pg_namespace n on n.oid = p.pronamespace
-- where n.nspname = 'public' and (p.proname like 'api\_%' or p.proname like 'fn\_%')
-- order by anon_can_run desc, p.proname;
