-- ============================================================
-- 🍱 오늘점심 v2 — 4단계: 메뉴 투표 (REQ-19)
-- 08~12 실행 후 이 파일 전체를 SQL Editor에 붙여넣고 Run 하세요.
--
-- 핵심 원칙
--   · 메뉴 투표는 가요/안가요 응답(REQ-05)을 대체하지 않고 병행한다.
--   · 방 × 날짜당 투표 1개, 후보 2~6개, 1인 1표(재투표는 덮어씀).
--   · 동률이면 "동점 안내 후 룰렛 랜덤"으로 자동 확정한다 (재투표 없음 — 고정 동작).
--     서버가 무작위로 한 번 뽑아 저장하므로 모든 사람이 같은 결과를 본다.
--     프론트는 was_tie=true를 보고 룰렛 애니메이션을 돌린 뒤 저장된 결과를 공개한다.
-- ============================================================

-- ------------------------------------------------------------
-- 1) 투표 현황 요약 (jsonb) — api_get_menu_poll과 api_get_room_home이 공유
--    내부 헬퍼이므로 권한을 주지 않는다 (12_v2_grants_fix.sql 방침)
-- ------------------------------------------------------------
create or replace function fn_menu_poll_summary(p_room_id uuid, p_user_id uuid, p_date date)
returns jsonb
language plpgsql stable security definer set search_path = public, extensions as $$
declare
  v_poll record;
  v_role text;
  v_room record;
  v_options jsonb;
  v_my_vote uuid;
  v_total int;
begin
  select * into v_room from rooms where id = p_room_id;
  if v_room.id is null or not v_room.enable_menu_poll then return 'null'::jsonb; end if;

  select * into v_poll from menu_polls where room_id = p_room_id and date = p_date;
  v_role := fn_member_role(p_room_id, p_user_id);

  -- 아직 오늘 투표가 없으면, 시작할 수 있는지만 알려준다
  if v_poll.id is null then
    return jsonb_build_object(
      'exists', false,
      'canStart', (v_role in ('host', 'co-host') and v_room.event_status <> 'closed'),
      'deadline', v_room.menu_poll_deadline
    );
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
      'optionId', o.id, 'label', o.label,
      'count', (select count(*)::int from menu_poll_votes v where v.option_id = o.id),
      'addedBy', o.created_by_nickname
    ) order by (select count(*) from menu_poll_votes v2 where v2.option_id = o.id) desc, o.created_at asc),
    '[]'::jsonb) into v_options
    from menu_poll_options o where o.poll_id = v_poll.id;

  select option_id into v_my_vote from menu_poll_votes where poll_id = v_poll.id and user_id = p_user_id;
  select count(*)::int into v_total from menu_poll_votes where poll_id = v_poll.id;

  return jsonb_build_object(
    'exists', true,
    'pollId', v_poll.id,
    'status', v_poll.status,
    'options', v_options,
    'myVote', v_my_vote,
    'totalVotes', v_total,
    'wasTie', v_poll.was_tie,
    'confirmedLabel', v_poll.confirmed_label,
    'confirmedOptionId', v_poll.confirmed_option_id,
    'deadlineAt', (v_poll.deadline_at at time zone 'Asia/Seoul'),
    'canAddOption', (v_poll.status = 'open' and v_role is not null
                     and (v_role in ('host', 'co-host') or v_room.menu_poll_member_add)),
    'canClose', (v_poll.status = 'open' and v_role in ('host', 'co-host')),
    'canVote', (v_poll.status = 'open' and v_role is not null and v_room.event_status <> 'closed')
  );
end;
$$;

-- ------------------------------------------------------------
-- 2) 투표 마감 처리 (공용) — 수동 마감·자동 마감·자정 정리에서 모두 사용
--    최다 득표가 여럿이면 무작위 1개를 뽑고 was_tie를 남긴다.
-- ------------------------------------------------------------
create or replace function fn_close_poll(p_poll_id uuid) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_poll record;
  v_max int;
  v_tied int;
  v_win record;
  v_msg text;
begin
  select * into v_poll from menu_polls where id = p_poll_id;
  if v_poll.id is null then return fn_err('투표를 찾을 수 없습니다.'); end if;
  if v_poll.status = 'closed' then
    return fn_ok(jsonb_build_object('already', true, 'confirmedLabel', v_poll.confirmed_label));
  end if;

  -- 후보별 득표 수 중 최다 득표
  select coalesce(max(cnt), 0) into v_max from (
    select (select count(*)::int from menu_poll_votes v where v.option_id = o.id) as cnt
    from menu_poll_options o where o.poll_id = p_poll_id
  ) t;

  -- 아무도 투표하지 않았으면 메뉴를 정하지 않고 그냥 닫는다
  if v_max = 0 then
    update menu_polls set status = 'closed', closed_at = now() where id = p_poll_id;
    return fn_ok(jsonb_build_object('confirmedLabel', null, 'wasTie', false, 'noVotes', true));
  end if;

  -- 최다 득표가 몇 개인지 (2개 이상이면 동률)
  select count(*)::int into v_tied from (
    select (select count(*)::int from menu_poll_votes v where v.option_id = o.id) as cnt
    from menu_poll_options o where o.poll_id = p_poll_id
  ) t where cnt = v_max;

  -- 동률이면 무작위 1개 (룰렛) — 서버가 한 번만 뽑아 저장해 모든 사람이 같은 결과를 본다
  select option_id, label, cnt into v_win from (
    select o.id as option_id, o.label,
           (select count(*)::int from menu_poll_votes v where v.option_id = o.id) as cnt
    from menu_poll_options o where o.poll_id = p_poll_id
  ) t where cnt = v_max order by random() limit 1;

  update menu_polls set
    status = 'closed', closed_at = now(),
    confirmed_option_id = v_win.option_id, confirmed_label = v_win.label,
    was_tie = (v_tied > 1)
  where id = p_poll_id;

  -- 결과를 방 채팅에 공지 (REQ-19) — 시스템 메시지는 투표를 만든 사람 계정으로 남긴다
  v_msg := case when v_tied > 1
    then '🎲 동점이라 룰렛으로 «' || v_win.label || '» 이 뽑혔어요! (' || v_win.cnt || '표씩 동점)'
    else '🗳 오늘의 메뉴는 «' || v_win.label || '» 으로 정해졌어요! (' || v_win.cnt || '표)'
  end;
  insert into messages (room_id, user_id, text, nickname)
  values (v_poll.room_id, v_poll.created_by, v_msg, '📢 메뉴 투표');

  return fn_ok(jsonb_build_object(
    'confirmedLabel', v_win.label, 'confirmedOptionId', v_win.option_id,
    'wasTie', (v_tied > 1), 'votes', v_win.cnt
  ));
end;
$$;

-- ------------------------------------------------------------
-- 3) 투표 시작 (호스트·공동호스트)
-- ------------------------------------------------------------
create or replace function api_start_menu_poll(p_token uuid, p_room_id uuid, p_options text[]) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_me record;
  v_room record;
  v_today date := fn_today();
  v_nick text;
  v_poll_id uuid;
  v_clean text[];
  v_label text;
  v_deadline timestamptz;
begin
  select * into v_me from fn_auth(p_token);
  if v_me.user_id is null then return fn_err('AUTH'); end if;
  if fn_require_manager(p_room_id, v_me.user_id) is null then return fn_err('권한이 없습니다.'); end if;

  select * into v_room from rooms where id = p_room_id;
  if v_room.id is null then return fn_err('방을 찾을 수 없습니다.'); end if;
  if not v_room.enable_menu_poll then return fn_err('이 방은 메뉴 투표를 쓰지 않도록 설정돼 있어요. 설정에서 켜주세요.'); end if;
  if v_room.purpose = 'event' and v_room.event_status = 'closed' then
    return fn_err('이미 마감된 모임이라 투표를 시작할 수 없습니다.');
  end if;
  if exists (select 1 from menu_polls where room_id = p_room_id and date = v_today) then
    return fn_err('오늘 투표가 이미 있어요.');
  end if;

  -- 공백 정리 + 중복 제거(공백·대소문자 무시) + 20자 제한
  v_clean := array[]::text[];
  foreach v_label in array coalesce(p_options, array[]::text[]) loop
    v_label := trim(coalesce(v_label, ''));
    if v_label = '' then continue; end if;
    if length(v_label) > 20 then return fn_err('후보는 각각 20자 이내로 입력해주세요.'); end if;
    if exists (
      select 1 from unnest(v_clean) c
      where lower(regexp_replace(c, '\s+', '', 'g')) = lower(regexp_replace(v_label, '\s+', '', 'g'))
    ) then continue; end if;
    v_clean := array_append(v_clean, v_label);
  end loop;

  if array_length(v_clean, 1) is null or array_length(v_clean, 1) < 2 then
    return fn_err('후보를 2개 이상 입력해주세요.');
  end if;
  if array_length(v_clean, 1) > 6 then return fn_err('후보는 최대 6개까지예요.'); end if;

  -- 자동 마감 시각이 설정돼 있으면 오늘 그 시각으로 계산 (서울 기준)
  if v_room.menu_poll_deadline is not null then
    v_deadline := (v_today::text || ' ' || v_room.menu_poll_deadline)::timestamp at time zone 'Asia/Seoul';
  end if;

  select nickname into v_nick from members where room_id = p_room_id and user_id = v_me.user_id;

  insert into menu_polls (room_id, date, created_by, deadline_at)
  values (p_room_id, v_today, v_me.user_id, v_deadline)
  returning id into v_poll_id;

  insert into menu_poll_options (poll_id, label, created_by, created_by_nickname)
  select v_poll_id, c, v_me.user_id, v_nick from unnest(v_clean) c;

  return fn_ok(fn_menu_poll_summary(p_room_id, v_me.user_id, v_today));
end;
$$;

-- ------------------------------------------------------------
-- 4) 후보 추가 (멤버 허용 설정에 따름)
-- ------------------------------------------------------------
create or replace function api_add_poll_option(p_token uuid, p_room_id uuid, p_label text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_me record;
  v_room record;
  v_role text;
  v_today date := fn_today();
  v_poll record;
  v_label text := trim(coalesce(p_label, ''));
  v_nick text;
begin
  select * into v_me from fn_auth(p_token);
  if v_me.user_id is null then return fn_err('AUTH'); end if;
  v_role := fn_member_role(p_room_id, v_me.user_id);
  if v_role is null then return fn_err('NOT_MEMBER'); end if;

  select * into v_room from rooms where id = p_room_id;
  if v_role not in ('host', 'co-host') and not v_room.menu_poll_member_add then
    return fn_err('이 방은 호스트만 후보를 추가할 수 있어요.');
  end if;

  select * into v_poll from menu_polls where room_id = p_room_id and date = v_today;
  if v_poll.id is null then return fn_err('진행 중인 투표가 없어요.'); end if;
  if v_poll.status = 'closed' then return fn_err('이미 마감된 투표예요.'); end if;

  if v_label = '' then return fn_err('후보 이름을 입력해주세요.'); end if;
  if length(v_label) > 20 then return fn_err('후보는 20자 이내로 입력해주세요.'); end if;
  if (select count(*) from menu_poll_options where poll_id = v_poll.id) >= 6 then
    return fn_err('후보는 최대 6개까지예요.');
  end if;
  if exists (
    select 1 from menu_poll_options o where o.poll_id = v_poll.id
      and lower(regexp_replace(o.label, '\s+', '', 'g')) = lower(regexp_replace(v_label, '\s+', '', 'g'))
  ) then
    return fn_err('이미 있는 후보예요.');
  end if;

  select nickname into v_nick from members where room_id = p_room_id and user_id = v_me.user_id;
  insert into menu_poll_options (poll_id, label, created_by, created_by_nickname)
  values (v_poll.id, v_label, v_me.user_id, v_nick);

  return fn_ok(fn_menu_poll_summary(p_room_id, v_me.user_id, v_today));
end;
$$;

-- ------------------------------------------------------------
-- 5) 투표 / 투표 취소 (p_option_id를 null로 보내면 취소)
-- ------------------------------------------------------------
create or replace function api_vote_poll(p_token uuid, p_room_id uuid, p_option_id uuid default null) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_me record;
  v_room record;
  v_today date := fn_today();
  v_poll record;
  v_nick text;
begin
  select * into v_me from fn_auth(p_token);
  if v_me.user_id is null then return fn_err('AUTH'); end if;
  select nickname into v_nick from members where room_id = p_room_id and user_id = v_me.user_id;
  if v_nick is null then return fn_err('NOT_MEMBER'); end if;

  select * into v_room from rooms where id = p_room_id;
  if v_room.purpose = 'event' and v_room.event_status = 'closed' then
    return fn_err('이미 마감된 모임이라 투표할 수 없습니다.');
  end if;

  select * into v_poll from menu_polls where room_id = p_room_id and date = v_today;
  if v_poll.id is null then return fn_err('진행 중인 투표가 없어요.'); end if;
  if v_poll.status = 'closed' then return fn_err('이미 마감된 투표예요.'); end if;

  if p_option_id is null then
    delete from menu_poll_votes where poll_id = v_poll.id and user_id = v_me.user_id;
  else
    if not exists (select 1 from menu_poll_options where id = p_option_id and poll_id = v_poll.id) then
      return fn_err('없는 후보예요. 새로고침 후 다시 시도해주세요.');
    end if;
    -- 1인 1표 — 재투표는 option_id만 갈아끼운다
    insert into menu_poll_votes (poll_id, option_id, user_id, nickname)
    values (v_poll.id, p_option_id, v_me.user_id, v_nick)
    on conflict (poll_id, user_id) do update
      set option_id = excluded.option_id, nickname = excluded.nickname, voted_at = now();
  end if;

  return fn_ok(fn_menu_poll_summary(p_room_id, v_me.user_id, v_today));
end;
$$;

-- ------------------------------------------------------------
-- 6) 수동 마감 (호스트·공동호스트)
-- ------------------------------------------------------------
create or replace function api_close_poll(p_token uuid, p_room_id uuid) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_me record;
  v_today date := fn_today();
  v_poll record;
  v_res jsonb;
begin
  select * into v_me from fn_auth(p_token);
  if v_me.user_id is null then return fn_err('AUTH'); end if;
  if fn_require_manager(p_room_id, v_me.user_id) is null then return fn_err('권한이 없습니다.'); end if;

  select * into v_poll from menu_polls where room_id = p_room_id and date = v_today;
  if v_poll.id is null then return fn_err('진행 중인 투표가 없어요.'); end if;

  v_res := fn_close_poll(v_poll.id);
  if not (v_res->>'ok')::boolean then return v_res; end if;

  return fn_ok(fn_menu_poll_summary(p_room_id, v_me.user_id, v_today));
end;
$$;

-- ------------------------------------------------------------
-- 7) 투표 현황 단독 조회 (홈 화면 폴링에도 포함되지만, 필요할 때 따로 부를 수 있게)
-- ------------------------------------------------------------
create or replace function api_get_menu_poll(p_token uuid, p_room_id uuid) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_me record;
begin
  select * into v_me from fn_auth(p_token);
  if v_me.user_id is null then return fn_err('AUTH'); end if;
  if fn_member_role(p_room_id, v_me.user_id) is null then return fn_err('NOT_MEMBER'); end if;
  return fn_ok(fn_menu_poll_summary(p_room_id, v_me.user_id, fn_today()));
end;
$$;

-- ------------------------------------------------------------
-- 8) 방 홈 조회 — 투표 현황(menuPoll)을 함께 반환
--    폴링 1회 호출로 현황·채팅·투표를 모두 갱신하는 기존 최적화 방침 유지
-- ------------------------------------------------------------
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
  v_my record;
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

  select coalesce(jsonb_agg(jsonb_build_object(
      'userId', m.user_id, 'nickname', m.nickname, 'place', r.place_name, 'menu', r.menu_name
    )), '[]'::jsonb) into v_going
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

  select status, place_name, menu_name into v_my
    from responses where room_id = p_room_id and user_id = v_me.user_id and date = v_today;
  select nickname into v_my_nickname from members where room_id = p_room_id and user_id = v_me.user_id;

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
    'myStatus', v_my.status, 'going', v_going, 'notGoing', v_not_going, 'noResponse', v_no_response,
    'inviteToken', v_room.invite_token, 'roomCode', v_room.room_code, 'messages', v_messages,
    'purpose', v_room.purpose, 'trackMealLog', v_room.track_meal_log, 'enableMenuPoll', v_room.enable_menu_poll,
    'eventStatus', v_room.event_status,
    'myPlace', v_my.place_name, 'myMenu', v_my.menu_name,
    -- 메뉴 투표 현황 (REQ-19) — 투표를 안 쓰는 방이면 null
    'menuPoll', fn_menu_poll_summary(p_room_id, v_me.user_id, v_today)
  ));
end;
$$;

-- ------------------------------------------------------------
-- 9) 자동 마감 크론 — 마감 시각이 지난 투표를 닫는다 (5분마다)
-- ------------------------------------------------------------
create or replace function fn_close_due_polls() returns void
language plpgsql security definer set search_path = public as $$
declare v_poll record;
begin
  for v_poll in
    select id from menu_polls
    where status = 'open' and deadline_at is not null and deadline_at <= now()
  loop
    perform fn_close_poll(v_poll.id);
  end loop;
end;
$$;

do $$ begin perform cron.unschedule('lunchbuddy-close-polls'); exception when others then null; end $$;
select cron.schedule('lunchbuddy-close-polls', '*/5 * * * *', 'select fn_close_due_polls();');

-- ------------------------------------------------------------
-- 10) 랭킹 집계에 "투표로 확정된 메뉴" 포함 (REQ-18·19 연결)
--     하루 1건, 방 전체 기준으로만 센다 (user_id를 null로 둬서 개인 랭킹에는 안 들어감)
-- ------------------------------------------------------------
create or replace function fn_meal_logs_between(p_room_id uuid, p_from date, p_to date)
returns table(user_id uuid, nickname text, place text, menu text)
language sql stable security definer set search_path = public as $$
  select (e->>'userId')::uuid, e->>'nickname',
         nullif(trim(coalesce(e->>'place', '')), ''), nullif(trim(coalesce(e->>'menu', '')), '')
  from history h, jsonb_array_elements(h.meal_logs) e
  where h.room_id = p_room_id and h.date between p_from and p_to
  union all
  select r.user_id, r.nickname,
         nullif(trim(coalesce(r.place_name, '')), ''), nullif(trim(coalesce(r.menu_name, '')), '')
  from responses r
  where r.room_id = p_room_id and r.date between p_from and p_to and r.status = 'going'
    and not exists (select 1 from history h2 where h2.room_id = r.room_id and h2.date = r.date)
  union all
  -- 히스토리에 기록된 확정 메뉴
  select null::uuid, null::text, null::text, nullif(trim(h.confirmed_menu), '')
  from history h
  where h.room_id = p_room_id and h.date between p_from and p_to and h.confirmed_menu is not null
  union all
  -- 아직 히스토리로 안 넘어간 확정 메뉴 (오늘 등)
  select null::uuid, null::text, null::text, nullif(trim(mp.confirmed_label), '')
  from menu_polls mp
  where mp.room_id = p_room_id and mp.date between p_from and p_to and mp.confirmed_label is not null
    and not exists (
      select 1 from history h2
      where h2.room_id = mp.room_id and h2.date = mp.date and h2.confirmed_menu is not null
    )
$$;

-- ------------------------------------------------------------
-- 11) 자정 초기화 — 확정 메뉴를 히스토리에 남기고, 열린 채 넘어간 투표를 닫는다
-- ------------------------------------------------------------
create or replace function fn_daily_reset() returns void
language plpgsql security definer set search_path = public as $$
declare
  v_today date := fn_today();
  v_cutoff date := v_today - interval '29 days';
  v_poll record;
begin
  -- 0) 어제까지의 투표가 아직 열려 있으면 먼저 마감해 결과를 확정한다
  for v_poll in select id from menu_polls where status = 'open' and date < v_today loop
    perform fn_close_poll(v_poll.id);
  end loop;

  -- 1) 과거 응답 → History 집계 후 삭제 (당일 데이터는 그대로 유지)
  insert into history (date, room_id, going_names, not_going_names, meal_logs)
  select r.date, r.room_id,
    coalesce(string_agg(coalesce(r.nickname, '(알수없음)'), ',') filter (where r.status = 'going'), ''),
    coalesce(string_agg(coalesce(r.nickname, '(알수없음)'), ',') filter (where r.status = 'not-going'), ''),
    coalesce(jsonb_agg(jsonb_build_object(
        'userId', r.user_id, 'nickname', coalesce(r.nickname, '(알수없음)'),
        'place', r.place_name, 'menu', r.menu_name
      )) filter (where r.status = 'going' and (r.place_name is not null or r.menu_name is not null)), '[]'::jsonb)
  from responses r
  where r.date < v_today
  group by r.date, r.room_id
  on conflict (date, room_id) do nothing;

  delete from responses where date < v_today;

  -- 1-2) 투표로 확정된 메뉴를 히스토리에 기록
  --      응답이 하나도 없어 히스토리 행이 안 만들어진 날짜도 있을 수 있으므로 먼저 행을 만든다
  insert into history (date, room_id, going_names, not_going_names)
  select mp.date, mp.room_id, '', ''
  from menu_polls mp
  where mp.date < v_today and mp.confirmed_label is not null
  on conflict (date, room_id) do nothing;

  update history h set confirmed_menu = mp.confirmed_label
  from menu_polls mp
  where mp.room_id = h.room_id and mp.date = h.date
    and mp.confirmed_label is not null and h.confirmed_menu is null;

  -- 2) 채팅은 매일 리셋 (오늘 이전 메시지 삭제)
  delete from messages where (sent_at at time zone 'Asia/Seoul')::date < v_today;

  -- 3) 30일 지난 히스토리·투표 삭제
  delete from history where date < v_cutoff;
  delete from menu_polls where date < v_cutoff;

  -- 4) 만료 세션 · 미사용 비밀번호 재설정 토큰 정리
  delete from sessions where expires_at < now();
  delete from password_resets where expires_at < now();
end;
$$;

-- ------------------------------------------------------------
-- 12) 권한 — 프론트가 호출하는 api_* 함수만 (fn_* 헬퍼는 열지 않는다)
-- ------------------------------------------------------------
grant execute on function api_start_menu_poll(uuid, uuid, text[]) to anon, authenticated;
grant execute on function api_add_poll_option(uuid, uuid, text) to anon, authenticated;
grant execute on function api_vote_poll(uuid, uuid, uuid) to anon, authenticated;
grant execute on function api_close_poll(uuid, uuid) to anon, authenticated;
grant execute on function api_get_menu_poll(uuid, uuid) to anon, authenticated;
grant execute on function api_get_room_home(uuid, uuid) to anon, authenticated;

revoke execute on function fn_menu_poll_summary(uuid, uuid, date) from public;
revoke execute on function fn_menu_poll_summary(uuid, uuid, date) from anon, authenticated;
revoke execute on function fn_close_poll(uuid) from public;
revoke execute on function fn_close_poll(uuid) from anon, authenticated;
revoke execute on function fn_close_due_polls() from public;
revoke execute on function fn_close_due_polls() from anon, authenticated;
revoke execute on function fn_meal_logs_between(uuid, date, date) from public;
revoke execute on function fn_meal_logs_between(uuid, date, date) from anon, authenticated;
revoke execute on function fn_daily_reset() from public;
revoke execute on function fn_daily_reset() from anon, authenticated;

-- ============================================================
-- 실행 후 확인
--   select * from cron.job where jobname like 'lunchbuddy%';
--   select date, status, confirmed_label, was_tie from menu_polls order by date desc limit 5;
-- ============================================================
