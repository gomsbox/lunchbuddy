-- ============================================================
-- 🍱 오늘점심 v2 — 2단계: 응답 시 장소·메뉴 기록 (REQ-17)
-- 08, 09 실행 후 이 파일 전체를 SQL Editor에 붙여넣고 Run 하세요.
--
-- 장소·메뉴는 완전 선택 입력이고, 방의 track_meal_log = true일 때만 저장한다.
-- 자정 배치에서 history.meal_logs로 스냅샷 저장되어 3단계 메뉴 랭킹의 원천 데이터가 된다.
-- ============================================================

-- ---------- REQ-05·17 참여 등록 — 장소·메뉴 파라미터 추가 ----------
-- ⚠️ 파라미터가 늘어나므로 기존 3개짜리 함수를 먼저 삭제 (오버로드 방지 — 09 파일과 같은 이유)
drop function if exists api_set_response(uuid, uuid, text);

create or replace function api_set_response(
  p_token uuid, p_room_id uuid, p_status text,
  p_place_name text default null, p_menu_name text default null
) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_me record;
  v_today date := fn_today();
  v_nick text;
  v_room record;
  v_place text := nullif(trim(coalesce(p_place_name, '')), '');
  v_menu text := nullif(trim(coalesce(p_menu_name, '')), '');
begin
  select * into v_me from fn_auth(p_token);
  if v_me.user_id is null then return fn_err('AUTH'); end if;
  select nickname into v_nick from members where room_id = p_room_id and user_id = v_me.user_id;
  if v_nick is null then return fn_err('NOT_MEMBER'); end if;
  if p_status not in ('going', 'not-going', 'clear') then return fn_err('잘못된 응답 값입니다.'); end if;

  select * into v_room from rooms where id = p_room_id;
  if v_room.id is null then return fn_err('방을 찾을 수 없습니다.'); end if;
  -- 마감된 이벤트형 방은 응답을 바꿀 수 없다 (읽기 전용 — REQ-25)
  if v_room.purpose = 'event' and v_room.event_status = 'closed' then
    return fn_err('이미 마감된 모임이라 응답을 변경할 수 없습니다.');
  end if;

  if length(coalesce(v_place, '')) > 20 then return fn_err('장소는 20자 이내로 입력해주세요.'); end if;
  if length(coalesce(v_menu, '')) > 20 then return fn_err('메뉴는 20자 이내로 입력해주세요.'); end if;

  -- 장소·메뉴 기록을 쓰지 않는 방이면 값이 넘어와도 무시한다 (사내식당형 등)
  if not v_room.track_meal_log then
    v_place := null; v_menu := null;
  end if;
  -- '안 가요'는 먹은 기록이 있을 수 없으므로 함께 비운다
  if p_status = 'not-going' then
    v_place := null; v_menu := null;
  end if;

  if p_status = 'clear' then
    delete from responses where room_id = p_room_id and user_id = v_me.user_id and date = v_today;
  else
    -- nickname은 응답 시점의 방 닉네임 스냅샷 (강퇴/탈퇴 후에도 히스토리 집계에 이름이 남도록)
    insert into responses (date, room_id, user_id, status, nickname, place_name, menu_name)
    values (v_today, p_room_id, v_me.user_id, p_status, v_nick, v_place, v_menu)
    on conflict (date, room_id, user_id) do update
      set status = excluded.status, nickname = excluded.nickname,
          place_name = excluded.place_name, menu_name = excluded.menu_name, updated_at = now();
  end if;
  return fn_ok(jsonb_build_object('status', p_status, 'placeName', v_place, 'menuName', v_menu));
end;
$$;

-- ---------- 방 홈 조회 — 가요 명단에 장소·메뉴, 내 입력값 함께 반환 ----------
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

  -- 가요 명단에는 장소·메뉴를 함께 실어 보낸다 (칩에 "닉네임 · 메뉴" 형태로 표시 — REQ-17)
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
    'myStatus', v_my.status, 'going', v_going, 'notGoing', v_not_going, 'noResponse', v_no_response,
    'inviteToken', v_room.invite_token, 'roomCode', v_room.room_code, 'messages', v_messages,
    'purpose', v_room.purpose, 'trackMealLog', v_room.track_meal_log, 'enableMenuPoll', v_room.enable_menu_poll,
    'eventStatus', v_room.event_status,
    -- 내가 오늘 적어둔 장소·메뉴 (입력란 채워넣기용 — REQ-17)
    'myPlace', v_my.place_name, 'myMenu', v_my.menu_name
  ));
end;
$$;

-- ---------- 자정 초기화 — history에 장소·메뉴 스냅샷 함께 저장 ----------
create or replace function fn_daily_reset() returns void
language plpgsql security definer set search_path = public as $$
declare
  v_today date := fn_today();
  v_cutoff date := v_today - interval '29 days';
begin
  -- 1) 과거 응답 → History 집계 후 삭제 (당일 데이터는 그대로 유지)
  -- nickname은 응답 시점 스냅샷(responses.nickname) — 강퇴/탈퇴된 멤버도 히스토리에 정확히 남음
  -- meal_logs: 장소나 메뉴를 적은 '가요' 응답만 모아 배열로 저장 (3단계 메뉴 랭킹의 원천 데이터 — REQ-18)
  insert into history (date, room_id, going_names, not_going_names, meal_logs)
  select r.date, r.room_id,
    coalesce(string_agg(coalesce(r.nickname, '(알수없음)'), ',') filter (where r.status = 'going'), ''),
    coalesce(string_agg(coalesce(r.nickname, '(알수없음)'), ',') filter (where r.status = 'not-going'), ''),
    coalesce(jsonb_agg(jsonb_build_object(
        'nickname', coalesce(r.nickname, '(알수없음)'), 'place', r.place_name, 'menu', r.menu_name
      )) filter (where r.status = 'going' and (r.place_name is not null or r.menu_name is not null)), '[]'::jsonb)
  from responses r
  where r.date < v_today
  group by r.date, r.room_id
  on conflict (date, room_id) do nothing;

  delete from responses where date < v_today;

  -- 2) 채팅은 매일 리셋 (오늘 이전 메시지 삭제)
  delete from messages where (sent_at at time zone 'Asia/Seoul')::date < v_today;

  -- 3) 30일 지난 히스토리 삭제
  delete from history where date < v_cutoff;

  -- 4) 만료 세션 · 미사용 비밀번호 재설정 토큰 정리
  delete from sessions where expires_at < now();
  delete from password_resets where expires_at < now();
end;
$$;

-- 프론트가 호출하는 api_* 함수에만 실행 권한을 준다 (12_v2_grants_fix.sql 참고)
grant execute on function api_set_response(uuid, uuid, text, text, text) to anon, authenticated;
grant execute on function api_get_room_home(uuid, uuid) to anon, authenticated;
-- fn_daily_reset은 크론 전용 — 외부에 열지 않는다

-- ============================================================
-- 실행 후 확인
--   select date, room_id, going_names, meal_logs from history order by date desc limit 5;
-- ============================================================
