-- ============================================================
-- 🍱 오늘점심 v2 — 1단계: 방 목적 프리셋 (REQ-16)
-- 08_v2_schema.sql 실행 후 이 파일 전체를 SQL Editor에 붙여넣고 Run 하세요.
--
-- 프리셋 5종: cafeteria(사내식당형) / outside(외부 점심형) / poll(메뉴 투표형)
--             event(이벤트형·게스트 참여) / custom(자유 설정)
-- ============================================================

-- ---------- 프리셋별 기본 토글 값 ----------
-- cafeteria: 아무것도 안 켬 (v1과 동일한 경험)
-- outside  : 장소·메뉴 기록 on
-- poll     : 메뉴 투표 on (가요/안가요는 그대로 유지 — 대체하지 않음)
-- event    : 메뉴 투표 on (+ 게스트 참여는 purpose 자체로 결정)
-- custom   : 둘 다 off로 시작하고 호스트가 직접 켠다
create or replace function fn_preset_toggles(p_purpose text)
returns table(track_meal_log boolean, enable_menu_poll boolean)
language sql immutable as $$
  select
    (p_purpose = 'outside'),
    (p_purpose in ('poll', 'event'));
$$;

create or replace function fn_is_valid_purpose(p_purpose text) returns boolean
language sql immutable as $$
  select p_purpose in ('cafeteria', 'outside', 'poll', 'event', 'custom');
$$;

-- ---------- REQ-03 방 생성 — 목적 프리셋 선택 추가 ----------
-- ⚠️ 파라미터가 늘어나므로 기존 2개짜리 함수를 먼저 삭제한다.
--    (그냥 create or replace 하면 오버로드가 생겨서 PostgREST가 "어느 함수인지 모르겠다"는 오류를 냄)
drop function if exists api_create_room(uuid, text);

create or replace function api_create_room(p_token uuid, p_room_name text, p_purpose text default 'cafeteria') returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_me record;
  v_name text := trim(coalesce(p_room_name, ''));
  v_purpose text := coalesce(nullif(trim(coalesce(p_purpose, '')), ''), 'cafeteria');
  v_toggles record;
  v_room_id uuid;
begin
  select * into v_me from fn_auth(p_token);
  if v_me.user_id is null then return fn_err('AUTH'); end if;
  if length(v_name) < 2 or length(v_name) > 20 then
    return fn_err('방 이름은 2~20자로 입력해주세요.');
  end if;
  if not fn_is_valid_purpose(v_purpose) then
    return fn_err('방 종류가 올바르지 않습니다.');
  end if;

  select * into v_toggles from fn_preset_toggles(v_purpose);

  -- 이벤트형 방은 초대 링크가 "방이 열려 있는 동안" 유효하다 (7일 만료 대신 사실상 무기한 + event_status로 차단)
  insert into rooms (name, host_user_id, room_code, purpose, track_meal_log, enable_menu_poll, invite_expires_at)
  values (
    v_name, v_me.user_id, fn_new_room_code(), v_purpose,
    v_toggles.track_meal_log, v_toggles.enable_menu_poll,
    case when v_purpose = 'event' then now() + interval '10 years' else now() + interval '7 days' end
  )
  returning id into v_room_id;

  -- 방 닉네임은 계정 닉네임으로 시작하되, 이후 방마다 독립적으로 변경 가능 (REQ-09)
  insert into members (room_id, user_id, role, nickname) values (v_room_id, v_me.user_id, 'host', v_me.nickname);

  return fn_ok(jsonb_build_object('roomId', v_room_id, 'purpose', v_purpose));
end;
$$;

-- ---------- REQ-16 방 목적·세부 토글 변경 ----------
-- 프리셋 상태에서 세부 토글을 프리셋 기본값과 다르게 바꾸면 자동으로 custom으로 전환한다 (명세서 3.1.1).
-- 단 event는 이 자동 전환에서 제외되고, 다른 목적으로 바꾸거나 다른 방을 event로 바꿀 수도 없다
-- (게스트 참여 구조 자체가 계정 기반 방과 다른 별도 트랙이라, 중간에 갈아타면 이미 참여한 게스트 처리가 모호해짐).
create or replace function api_set_room_purpose(
  p_token uuid, p_room_id uuid, p_purpose text,
  p_track_meal_log boolean default null, p_enable_menu_poll boolean default null
) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_me record;
  v_room record;
  v_purpose text := coalesce(nullif(trim(coalesce(p_purpose, '')), ''), 'cafeteria');
  v_preset record;
  v_track boolean;
  v_poll boolean;
  v_switched boolean := false;
begin
  select * into v_me from fn_auth(p_token);
  if v_me.user_id is null then return fn_err('AUTH'); end if;
  if fn_require_manager(p_room_id, v_me.user_id) is null then return fn_err('권한이 없습니다.'); end if;
  if not fn_is_valid_purpose(v_purpose) then return fn_err('방 종류가 올바르지 않습니다.'); end if;

  select * into v_room from rooms where id = p_room_id;
  if v_room.id is null then return fn_err('방을 찾을 수 없습니다.'); end if;

  if v_room.purpose = 'event' then
    -- 이벤트형 방은 목적을 바꿀 수 없고, 세부 토글만 조정 가능
    v_purpose := 'event';
  elsif v_purpose = 'event' then
    return fn_err('이미 만든 방을 이벤트형으로 바꿀 수는 없습니다. 이벤트형 방을 새로 만들어주세요.');
  end if;

  select * into v_preset from fn_preset_toggles(v_purpose);
  -- 토글을 넘기지 않았으면 프리셋 기본값을 그대로 적용 (프리셋 카드만 눌렀을 때)
  v_track := coalesce(p_track_meal_log, v_preset.track_meal_log);
  v_poll  := coalesce(p_enable_menu_poll, v_preset.enable_menu_poll);

  -- 프리셋(cafeteria/outside/poll)인데 토글이 프리셋 기본값과 다르면 → custom으로 자동 전환
  if v_purpose not in ('custom', 'event')
     and (v_track <> v_preset.track_meal_log or v_poll <> v_preset.enable_menu_poll) then
    v_purpose := 'custom';
    v_switched := true;
  end if;

  update rooms set purpose = v_purpose, track_meal_log = v_track, enable_menu_poll = v_poll
  where id = p_room_id;

  return fn_ok(jsonb_build_object(
    'purpose', v_purpose, 'trackMealLog', v_track, 'enableMenuPoll', v_poll,
    'switchedToCustom', v_switched
  ));
end;
$$;

-- ---------- 메뉴 투표 세부 설정 (마감 시각 / 멤버 후보 추가 허용) ----------
create or replace function api_set_menu_poll_config(
  p_token uuid, p_room_id uuid, p_deadline text default null, p_member_add boolean default true
) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_me record;
  v_deadline text := nullif(trim(coalesce(p_deadline, '')), '');
begin
  select * into v_me from fn_auth(p_token);
  if v_me.user_id is null then return fn_err('AUTH'); end if;
  if fn_require_manager(p_room_id, v_me.user_id) is null then return fn_err('권한이 없습니다.'); end if;
  if v_deadline is not null and v_deadline !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$' then
    return fn_err('마감 시각 형식이 올바르지 않습니다 (예: 11:30).');
  end if;

  update rooms set menu_poll_deadline = v_deadline, menu_poll_member_add = coalesce(p_member_add, true)
  where id = p_room_id;

  return fn_ok(jsonb_build_object('menuPollDeadline', v_deadline, 'menuPollMemberAdd', coalesce(p_member_add, true)));
end;
$$;

-- ---------- 방 목록 — 방 종류 배지 표시용 purpose 추가 ----------
create or replace function api_get_my_rooms(p_token uuid) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_me record;
  v_today date := fn_today();
  v_host jsonb;
  v_other jsonb;
begin
  select * into v_me from fn_auth(p_token);
  if v_me.user_id is null then return fn_err('AUTH'); end if;

  select coalesce(jsonb_agg(x), '[]'::jsonb) into v_host from (
    select r.id as "roomId", r.name as "roomName", m.role,
      r.purpose, r.event_status as "eventStatus",
      (select count(*) from responses resp where resp.room_id = r.id and resp.date = v_today and resp.status = 'going') as "goingCount",
      (select count(*) from members mm where mm.room_id = r.id) as "memberCount"
    from members m join rooms r on r.id = m.room_id
    where m.user_id = v_me.user_id and m.role = 'host'
  ) x;

  select coalesce(jsonb_agg(x), '[]'::jsonb) into v_other from (
    select r.id as "roomId", r.name as "roomName", m.role,
      r.purpose, r.event_status as "eventStatus",
      (select count(*) from responses resp where resp.room_id = r.id and resp.date = v_today and resp.status = 'going') as "goingCount",
      (select count(*) from members mm where mm.room_id = r.id) as "memberCount"
    from members m join rooms r on r.id = m.room_id
    where m.user_id = v_me.user_id and m.role <> 'host'
  ) x;

  return fn_ok(jsonb_build_object('hostRooms', v_host, 'otherRooms', v_other));
end;
$$;

-- ---------- 방 코드 참여 — 이벤트형 방은 코드로 참여 불가 (URL 전용) ----------
create or replace function api_join_by_code(p_token uuid, p_code text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_me record;
  v_room record;
  v_code text := upper(trim(coalesce(p_code, '')));
begin
  select * into v_me from fn_auth(p_token);
  if v_me.user_id is null then return fn_err('AUTH'); end if;
  if v_code !~ '^[A-Z0-9]{6}$' then
    return fn_err('방 코드는 6자리 영문·숫자입니다.');
  end if;

  select * into v_room from rooms where room_code = v_code;
  if v_room.id is null then
    return fn_err('일치하는 방이 없습니다. 코드를 다시 확인해주세요.');
  end if;
  -- 이벤트형 방은 방 코드를 화면에 노출하지 않으므로 정상 흐름에서는 올 일이 없지만, 서버에서도 막는다 (REQ-25)
  if v_room.purpose = 'event' then
    return fn_err('이 방은 초대 링크로만 참여할 수 있습니다.');
  end if;

  if fn_member_role(v_room.id, v_me.user_id) is not null then
    return fn_ok(jsonb_build_object('roomId', v_room.id, 'already', true));
  end if;

  insert into members (room_id, user_id, role, nickname) values (v_room.id, v_me.user_id, 'member', v_me.nickname)
  on conflict do nothing;
  return fn_ok(jsonb_build_object('roomId', v_room.id, 'already', false));
end;
$$;

-- ---------- 방 홈 조회 — v2 필드 추가 (07_chat_read_receipts.sql 버전 기반) ----------
create or replace function api_get_room_home(p_token uuid, p_room_id uuid) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_me record;
  v_role text;
  v_room record;
  v_today date := fn_today();
  v_going jsonb;
  v_not_going jsonb;
  v_no_response jsonb;
  v_my_status text;
  v_my_nickname text;
  v_messages jsonb;
begin
  select * into v_me from fn_auth(p_token);
  if v_me.user_id is null then return fn_err('AUTH'); end if;

  v_role := fn_member_role(p_room_id, v_me.user_id);
  if v_role is null then return fn_err('NOT_MEMBER'); end if;

  select * into v_room from rooms where id = p_room_id;
  if v_room.id is null then return fn_err('방을 찾을 수 없습니다.'); end if;

  -- 방 화면을 여는 것 = 읽음 처리 (REQ-13 읽음 표시)
  update members set last_read_at = now() where room_id = p_room_id and user_id = v_me.user_id;

  select coalesce(jsonb_agg(jsonb_build_object('userId', m.user_id, 'nickname', m.nickname)), '[]'::jsonb) into v_going
    from members m
    join responses r on r.room_id = m.room_id and r.user_id = m.user_id and r.date = v_today
    where m.room_id = p_room_id and r.status = 'going';

  select coalesce(jsonb_agg(jsonb_build_object('userId', m.user_id, 'nickname', m.nickname)), '[]'::jsonb) into v_not_going
    from members m
    join responses r on r.room_id = m.room_id and r.user_id = m.user_id and r.date = v_today
    where m.room_id = p_room_id and r.status = 'not-going';

  select coalesce(jsonb_agg(jsonb_build_object('userId', m.user_id, 'nickname', m.nickname)), '[]'::jsonb) into v_no_response
    from members m
    where m.room_id = p_room_id
      and not exists (select 1 from responses r where r.room_id = m.room_id and r.user_id = m.user_id and r.date = v_today);

  select status into v_my_status from responses where room_id = p_room_id and user_id = v_me.user_id and date = v_today;
  select nickname into v_my_nickname from members where room_id = p_room_id and user_id = v_me.user_id;

  -- unreadCount: 이 메시지를 보낸 사람을 제외하고, 아직 이 메시지 이후로 방을 안 연(last_read_at이 이전인) 멤버 수
  select coalesce(jsonb_agg(jsonb_build_object(
      'messageId', msg.id, 'userId', msg.user_id, 'nickname', coalesce(msg.nickname, '(알수없음)'), 'text', msg.text,
      'sentAt', (msg.sent_at at time zone 'Asia/Seoul'),
      'unreadCount', (
        select count(*) from members mm
        where mm.room_id = msg.room_id and mm.user_id <> msg.user_id and mm.last_read_at < msg.sent_at
      )
    ) order by msg.sent_at), '[]'::jsonb) into v_messages
    from messages msg
    where msg.room_id = p_room_id and (msg.sent_at at time zone 'Asia/Seoul')::date = v_today;

  return fn_ok(jsonb_build_object(
    'roomName', v_room.name, 'date', v_today, 'myRole', v_role, 'myUserId', v_me.user_id, 'myNickname', v_my_nickname,
    'myStatus', v_my_status, 'going', v_going, 'notGoing', v_not_going, 'noResponse', v_no_response,
    'inviteToken', v_room.invite_token, 'roomCode', v_room.room_code, 'messages', v_messages,
    -- v2 신규 필드 (프론트는 없어도 동작하도록 옵셔널 처리)
    'purpose', v_room.purpose, 'trackMealLog', v_room.track_meal_log, 'enableMenuPoll', v_room.enable_menu_poll,
    'eventStatus', v_room.event_status
  ));
end;
$$;

-- ---------- 방 설정 조회 — v2 필드 추가 (06_notify_days.sql 버전 기반) ----------
create or replace function api_get_room_settings(p_token uuid, p_room_id uuid) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_me record;
  v_room record;
  v_recipients int;
begin
  select * into v_me from fn_auth(p_token);
  if v_me.user_id is null then return fn_err('AUTH'); end if;
  if fn_require_manager(p_room_id, v_me.user_id) is null then return fn_err('권한이 없습니다.'); end if;

  select * into v_room from rooms where id = p_room_id;
  if v_room.id is null then return fn_err('방을 찾을 수 없습니다.'); end if;

  select count(*) into v_recipients from members m join users u on u.id = m.user_id
    where m.room_id = p_room_id and u.email is not null;

  return fn_ok(jsonb_build_object(
    'notifyEnabled', v_room.notify_enabled, 'notifyTime', v_room.notify_time,
    'notifyDays', jsonb_build_object(
      'mon', v_room.notify_mon, 'tue', v_room.notify_tue, 'wed', v_room.notify_wed,
      'thu', v_room.notify_thu, 'fri', v_room.notify_fri, 'sat', v_room.notify_sat, 'sun', v_room.notify_sun
    ),
    'recipientCount', v_recipients,
    -- v2 신규 필드
    'purpose', v_room.purpose, 'trackMealLog', v_room.track_meal_log, 'enableMenuPoll', v_room.enable_menu_poll,
    'menuPollDeadline', v_room.menu_poll_deadline, 'menuPollMemberAdd', v_room.menu_poll_member_add,
    'eventStatus', v_room.event_status
  ));
end;
$$;

grant execute on all functions in schema public to anon, authenticated;

-- ============================================================
-- 실행 후 확인
--   select name, purpose, track_meal_log, enable_menu_poll from rooms order by created_at;
-- ============================================================
