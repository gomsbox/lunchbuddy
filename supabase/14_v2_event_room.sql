-- ============================================================
-- 🍱 오늘점심 v2 — 5단계: 이벤트형 방 게스트 참여 (REQ-25)
-- 08~13 실행 후 이 파일 전체를 SQL Editor에 붙여넣고 Run 하세요.
--
-- 이벤트형(event) 방은 초대 URL만으로 참여하고, 참여자는 회원가입 없이 이름만 입력한다.
-- 새 인증 체계를 만들지 않고 기존 sessions 메커니즘을 그대로 재사용한다.
--   · 이름 입력 → users(is_guest=true, login_id/password_hash는 null) + sessions 발급
--   · 이후 응답·투표·채팅은 기존 api_* 함수를 게스트 세션으로 그대로 호출
--   · 게스트 식별은 브라우저에 저장된 세션 토큰 기준 (다른 기기로 접속하면 별도 참가자 — NFR-14)
--
-- 1회용 라이프사이클: open → (수동/자동) 마감 → 일정 기간 후 자동 삭제
-- ============================================================

-- ------------------------------------------------------------
-- 1) ⚠️ 게스트 계정으로는 절대 로그인할 수 없게 막는다
--    08단계에서 users.login_id / password_hash의 not null을 풀었으므로,
--    로그인 경로에서 게스트를 명시적으로 배제해야 한다.
--    (게스트는 login_id가 null이라 현재도 매칭되지 않지만, 방어적으로 못박아 둔다)
-- ------------------------------------------------------------
create or replace function api_login(p_login_id text, p_password text)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_login_id text := lower(trim(coalesce(p_login_id, '')));
  v_user record;
  v_fail int;
  v_blocked_until timestamptz;
  v_token uuid;
begin
  select blocked_until into v_blocked_until from login_attempts where login_id = v_login_id;
  if v_blocked_until is not null and v_blocked_until > now() then
    return fn_err('로그인 5회 실패로 10분간 차단되었습니다. 잠시 후 다시 시도해주세요.');
  end if;

  -- is_guest 계정은 조회 대상에서 제외 + 비밀번호 해시가 없는 계정도 제외
  select * into v_user from users
    where login_id = v_login_id and coalesce(is_guest, false) = false and password_hash is not null;

  if v_user.id is null or v_user.password_hash <> crypt(p_password, v_user.password_hash) then
    select coalesce(fail_count, 0) + 1 into v_fail from login_attempts where login_id = v_login_id;
    v_fail := coalesce(v_fail, 1);
    if v_fail >= 5 then
      insert into login_attempts (login_id, fail_count, blocked_until) values (v_login_id, 0, now() + interval '10 minutes')
      on conflict (login_id) do update set fail_count = 0, blocked_until = now() + interval '10 minutes';
      return fn_err('로그인 5회 실패로 10분간 차단되었습니다. 잠시 후 다시 시도해주세요.');
    end if;
    insert into login_attempts (login_id, fail_count) values (v_login_id, v_fail)
    on conflict (login_id) do update set fail_count = v_fail;
    return fn_err('아이디 또는 비밀번호가 올바르지 않습니다. (' || v_fail || '/5회)');
  end if;

  delete from login_attempts where login_id = v_login_id;
  insert into sessions (user_id, expires_at) values (v_user.id, now() + interval '30 days')
  returning token into v_token;

  return fn_ok(jsonb_build_object('token', v_token, 'user', jsonb_build_object(
    'userId', v_user.id, 'loginId', v_user.login_id, 'nickname', v_user.nickname,
    'email', coalesce(v_user.email, '')
  )));
end;
$$;

-- ------------------------------------------------------------
-- 2) 내 정보 조회 — 게스트 여부와 (게스트라면) 소속 방을 함께 반환
--    게스트는 방 목록 화면을 쓰지 않고 바로 그 방으로 들어간다
-- ------------------------------------------------------------
create or replace function api_get_me(p_token uuid) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_me record;
  v_is_guest boolean;
  v_room_id uuid;
begin
  select * into v_me from fn_auth(p_token);
  if v_me.user_id is null then return fn_err('AUTH'); end if;

  select coalesce(is_guest, false) into v_is_guest from users where id = v_me.user_id;
  if v_is_guest then
    select room_id into v_room_id from members where user_id = v_me.user_id limit 1;
  end if;

  return fn_ok(jsonb_build_object('user', jsonb_build_object(
    'userId', v_me.user_id, 'loginId', v_me.login_id, 'nickname', v_me.nickname, 'email', v_me.email,
    'isGuest', v_is_guest, 'guestRoomId', v_room_id
  )));
end;
$$;

-- ------------------------------------------------------------
-- 3) 초대 링크 정보 미리보기 (로그인 없이 호출 가능)
--    링크를 열었을 때 "어떤 방인지 / 이름만 입력하면 되는지"를 먼저 보여주기 위한 함수.
--    방 이름 외에는 아무 정보도 노출하지 않는다.
-- ------------------------------------------------------------
create or replace function api_peek_invite(p_invite_token uuid) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare v_room record;
begin
  if p_invite_token is null then return fn_err('초대 링크가 올바르지 않습니다.'); end if;
  select * into v_room from rooms where invite_token = p_invite_token;
  if v_room.id is null then return fn_err('EXPIRED'); end if;

  -- 일반 방은 기존 흐름(로그인 후 api_join_by_invite) 그대로 — 게스트 입력 화면을 띄우지 않는다
  if v_room.purpose <> 'event' then
    return fn_ok(jsonb_build_object('isEvent', false, 'roomName', v_room.name,
      'expired', (v_room.invite_expires_at < now())));
  end if;

  return fn_ok(jsonb_build_object(
    'isEvent', true, 'roomName', v_room.name,
    'closed', (v_room.event_status = 'closed'),
    'expired', false   -- 이벤트형 방은 마감 여부로만 판단한다 (링크 자체는 만료시키지 않음)
  ));
end;
$$;

-- ------------------------------------------------------------
-- 4) 게스트로 참여 — 이름만 입력 (로그인 불필요)
--    회원이 로그인한 상태로 이 링크를 열면 프론트가 api_join_by_invite를 쓰므로,
--    이 함수는 "가입 없이 참여"하는 경로만 담당한다.
-- ------------------------------------------------------------
create or replace function api_join_event_as_guest(p_invite_token uuid, p_name text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_room record;
  v_name text := trim(coalesce(p_name, ''));
  v_user_id uuid;
  v_token uuid;
begin
  if p_invite_token is null then return fn_err('초대 링크가 올바르지 않습니다.'); end if;
  select * into v_room from rooms where invite_token = p_invite_token;
  if v_room.id is null then return fn_err('EXPIRED'); end if;
  if v_room.purpose <> 'event' then
    return fn_err('이 방은 회원가입 후 참여할 수 있어요.');
  end if;
  if v_room.event_status = 'closed' then
    return fn_err('이미 마감된 모임이에요.');
  end if;

  if length(v_name) < 2 or length(v_name) > 10 then
    return fn_err('이름은 2~10자로 입력해주세요.');
  end if;

  -- 게스트 계정: 로그인 아이디·비밀번호 없음 (api_login에서 별도로 차단)
  insert into users (login_id, password_hash, nickname, email, is_guest)
  values (null, null, v_name, null, true)
  returning id into v_user_id;

  insert into sessions (user_id, expires_at) values (v_user_id, now() + interval '30 days')
  returning token into v_token;

  -- 게스트는 항상 일반 멤버 (공동호스트로 승격 불가 — api_set_role에서도 막는다)
  insert into members (room_id, user_id, role, nickname)
  values (v_room.id, v_user_id, 'member', v_name);

  return fn_ok(jsonb_build_object(
    'token', v_token, 'roomId', v_room.id, 'roomName', v_room.name,
    'user', jsonb_build_object('userId', v_user_id, 'loginId', null, 'nickname', v_name,
                              'email', '', 'isGuest', true, 'guestRoomId', v_room.id)
  ));
end;
$$;

-- ------------------------------------------------------------
-- 5) 게스트는 공동호스트로 승격할 수 없다
-- ------------------------------------------------------------
create or replace function api_set_role(p_token uuid, p_room_id uuid, p_target_user_id uuid, p_role text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_me record;
  v_target_role text;
begin
  select * into v_me from fn_auth(p_token);
  if v_me.user_id is null then return fn_err('AUTH'); end if;
  if fn_member_role(p_room_id, v_me.user_id) <> 'host' then
    return fn_err('호스트만 공동 호스트를 지정/해제할 수 있습니다.');
  end if;
  if p_role not in ('member', 'co-host') then return fn_err('잘못된 역할 값입니다.'); end if;

  v_target_role := fn_member_role(p_room_id, p_target_user_id);
  if v_target_role is null then return fn_err('해당 멤버를 찾을 수 없습니다.'); end if;
  if v_target_role = 'host' then return fn_err('호스트의 역할은 변경할 수 없습니다.'); end if;

  -- 게스트 세션은 일회성 신원이라 방 관리 권한을 위임할 대상으로 부적절 (명세서 3.4)
  if p_role = 'co-host' and (select coalesce(is_guest, false) from users where id = p_target_user_id) then
    return fn_err('이름만 입력해 참여한 게스트는 공동 호스트로 지정할 수 없어요.');
  end if;

  update members set role = p_role where room_id = p_room_id and user_id = p_target_user_id;
  return fn_ok();
end;
$$;

-- ------------------------------------------------------------
-- 6) 행사 마감 (호스트·공동호스트)
--    마감 시 응답·투표를 잠그고, 열려 있던 메뉴 투표는 결과를 확정한다.
-- ------------------------------------------------------------
create or replace function api_close_event(p_token uuid, p_room_id uuid) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_me record;
  v_room record;
  v_poll record;
begin
  select * into v_me from fn_auth(p_token);
  if v_me.user_id is null then return fn_err('AUTH'); end if;
  if fn_require_manager(p_room_id, v_me.user_id) is null then return fn_err('권한이 없습니다.'); end if;

  select * into v_room from rooms where id = p_room_id;
  if v_room.id is null then return fn_err('방을 찾을 수 없습니다.'); end if;
  if v_room.purpose <> 'event' then return fn_err('이벤트형 방에서만 마감할 수 있어요.'); end if;
  if v_room.event_status = 'closed' then return fn_err('이미 마감된 모임이에요.'); end if;

  -- 열려 있는 투표가 있으면 결과를 확정하고 닫는다
  for v_poll in select id from menu_polls where room_id = p_room_id and status = 'open' loop
    perform fn_close_poll(v_poll.id);
  end loop;

  update rooms set event_status = 'closed', event_closed_at = now() where id = p_room_id;

  return fn_ok(jsonb_build_object('eventStatus', 'closed',
    'purgeAfterDays', v_room.event_purge_after_days));
end;
$$;

-- ------------------------------------------------------------
-- 7) 자동 마감 / 자동 삭제 크론 (하루 1회)
-- ------------------------------------------------------------
create or replace function fn_auto_close_events() returns void
language plpgsql security definer set search_path = public as $$
declare
  v_room record;
  v_poll record;
begin
  for v_room in
    select * from rooms
    where purpose = 'event' and event_status = 'open'
      and created_at < now() - (event_auto_close_days || ' days')::interval
  loop
    for v_poll in select id from menu_polls where room_id = v_room.id and status = 'open' loop
      perform fn_close_poll(v_poll.id);
    end loop;
    update rooms set event_status = 'closed', event_closed_at = now() where id = v_room.id;
  end loop;
end;
$$;

create or replace function fn_purge_closed_events() returns void
language plpgsql security definer set search_path = public as $$
declare
  v_room record;
begin
  for v_room in
    select * from rooms
    where purpose = 'event' and event_status = 'closed' and event_closed_at is not null
      and event_closed_at < now() - (event_purge_after_days || ' days')::interval
  loop
    -- 이 방에만 속해 있던 게스트 계정을 함께 정리한다.
    -- (방을 지우면 members는 cascade로 사라지지만 users 행은 남으므로 직접 삭제)
    delete from users u
    where u.is_guest = true
      and exists (select 1 from members m where m.user_id = u.id and m.room_id = v_room.id)
      and not exists (select 1 from members m2 where m2.user_id = u.id and m2.room_id <> v_room.id);

    -- 방 삭제 → members·responses·history·messages·menu_polls 모두 cascade
    delete from rooms where id = v_room.id;
  end loop;
end;
$$;

do $$ begin perform cron.unschedule('lunchbuddy-auto-close-events'); exception when others then null; end $$;
do $$ begin perform cron.unschedule('lunchbuddy-purge-events'); exception when others then null; end $$;
-- 서울 01:10 / 01:20 = UTC 16:10 / 16:20 (자정 초기화 이후에 돌도록 시간차를 둠)
select cron.schedule('lunchbuddy-auto-close-events', '10 16 * * *', 'select fn_auto_close_events();');
select cron.schedule('lunchbuddy-purge-events',      '20 16 * * *', 'select fn_purge_closed_events();');

-- ------------------------------------------------------------
-- 8) 권한 — 게스트 참여·초대 미리보기는 로그인 전에 호출되므로 anon에 열어야 한다
-- ------------------------------------------------------------
grant execute on function api_login(text, text) to anon, authenticated;
grant execute on function api_get_me(uuid) to anon, authenticated;
grant execute on function api_peek_invite(uuid) to anon, authenticated;
grant execute on function api_join_event_as_guest(uuid, text) to anon, authenticated;
grant execute on function api_set_role(uuid, uuid, uuid, text) to anon, authenticated;
grant execute on function api_close_event(uuid, uuid) to anon, authenticated;

revoke execute on function fn_auto_close_events() from public;
revoke execute on function fn_auto_close_events() from anon, authenticated;
revoke execute on function fn_purge_closed_events() from public;
revoke execute on function fn_purge_closed_events() from anon, authenticated;

-- ============================================================
-- 실행 후 확인
--   select * from cron.job where jobname like 'lunchbuddy%';
--   select name, purpose, event_status, event_closed_at from rooms where purpose = 'event';
--   select count(*) from users where is_guest;
-- ============================================================
