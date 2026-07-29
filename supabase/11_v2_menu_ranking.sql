-- ============================================================
-- 🍱 오늘점심 v2 — 3단계: 메뉴 랭킹 (최근 30일) (REQ-18)
-- 08~10 실행 후 이 파일 전체를 SQL Editor에 붙여넣고 Run 하세요.
--
-- 최근 30일(오늘 포함) 기록을 집계해 방 전체 Top5 / 내 Top3를 보여준다.
-- 달력 월(1일~말일)이 아니라 30일 롤링 윈도우를 쓰는 이유:
--   ① 히스토리 보관 기간(30일)과 정확히 일치해서 "보이는 기록 = 집계 대상"이 된다
--   ② 월초에 랭킹이 텅 비는 문제가 없다 (매월 1일에 지난달 집계가 통째로 사라지지 않음)
-- 매칭은 "단순 매칭"으로 시작한다 (공백 제거 + 소문자화만) — 오타·표기 차이까지
-- 묶는 고도화는 v3 로드맵(V3-09)으로 미뤘다.
-- ============================================================

-- ------------------------------------------------------------
-- 1) 자정 집계에 userId를 함께 남긴다
--    meal_logs에 닉네임만 있으면 "내가 많이 먹은 메뉴"를 낼 수 없다
--    (닉네임은 방마다 다르고 언제든 바뀔 수 있어 사람을 특정하는 키가 될 수 없음).
--    ⚠️ 2단계 배포 직후이고 자정 배치가 아직 안 돌았으므로 기존 데이터 형태 변환은 불필요하다.
--       혹시 userId 없이 집계된 행이 있어도 e->>'userId'가 null이 되어 오류 없이
--       "방 전체 랭킹"에만 반영된다 (개인 랭킹에서만 빠짐).
-- ------------------------------------------------------------
create or replace function fn_daily_reset() returns void
language plpgsql security definer set search_path = public as $$
declare
  v_today date := fn_today();
  v_cutoff date := v_today - interval '29 days';
begin
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

  -- 2) 채팅은 매일 리셋 (오늘 이전 메시지 삭제)
  delete from messages where (sent_at at time zone 'Asia/Seoul')::date < v_today;

  -- 3) 30일 지난 히스토리 삭제
  delete from history where date < v_cutoff;

  -- 4) 만료 세션 · 미사용 비밀번호 재설정 토큰 정리
  delete from sessions where expires_at < now();
  delete from password_resets where expires_at < now();
end;
$$;

-- ------------------------------------------------------------
-- 2) 기간 내 식사 기록을 한 줄씩 펼쳐주는 헬퍼
--    과거(history.meal_logs) + 아직 집계 안 된 응답(responses)을 합친다.
--    크론이 실패해 두 곳에 같은 날짜가 남아 있을 수 있으므로,
--    이미 history에 있는 날짜는 responses에서 제외해 중복 집계를 막는다.
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
$$;

-- ------------------------------------------------------------
-- 3) 메뉴 랭킹 조회 — 최근 30일 (REQ-18)
--    방 전체 Top5 + 내 Top3. 정규화 키로 묶고, 표시는 가장 많이 쓰인 표기를 고른다.
--    집계 범위는 히스토리 보관 기간과 동일한 30일 (오늘 포함 → today - 29일 ~ today).
-- ------------------------------------------------------------
create or replace function api_get_menu_ranking(p_token uuid, p_room_id uuid) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_me record;
  v_today date := fn_today();
  v_from date := v_today - interval '29 days';
  v_room_top jsonb;
  v_my_top jsonb;
  v_place_top jsonb;
  v_total int;
  v_my_total int;
begin
  select * into v_me from fn_auth(p_token);
  if v_me.user_id is null then return fn_err('AUTH'); end if;
  if fn_member_role(p_room_id, v_me.user_id) is null then return fn_err('NOT_MEMBER'); end if;

  -- 방 전체 메뉴 Top 5
  select coalesce(jsonb_agg(jsonb_build_object('menu', label, 'count', cnt) order by cnt desc, label asc), '[]'::jsonb)
  into v_room_top from (
    select mode() within group (order by menu) as label, count(*)::int as cnt
    from fn_meal_logs_between(p_room_id, v_from, v_today)
    where menu is not null
    group by lower(regexp_replace(menu, '\s+', '', 'g'))
    order by cnt desc, label asc
    limit 5
  ) t;

  -- 내 메뉴 Top 3
  select coalesce(jsonb_agg(jsonb_build_object('menu', label, 'count', cnt) order by cnt desc, label asc), '[]'::jsonb)
  into v_my_top from (
    select mode() within group (order by menu) as label, count(*)::int as cnt
    from fn_meal_logs_between(p_room_id, v_from, v_today)
    where menu is not null and user_id = v_me.user_id
    group by lower(regexp_replace(menu, '\s+', '', 'g'))
    order by cnt desc, label asc
    limit 3
  ) t;

  -- 방 전체 장소 Top 3 (장소를 적은 기록이 있을 때만 의미 있음)
  select coalesce(jsonb_agg(jsonb_build_object('place', label, 'count', cnt) order by cnt desc, label asc), '[]'::jsonb)
  into v_place_top from (
    select mode() within group (order by place) as label, count(*)::int as cnt
    from fn_meal_logs_between(p_room_id, v_from, v_today)
    where place is not null
    group by lower(regexp_replace(place, '\s+', '', 'g'))
    order by cnt desc, label asc
    limit 3
  ) t;

  select count(*)::int into v_total
    from fn_meal_logs_between(p_room_id, v_from, v_today) where menu is not null;
  select count(*)::int into v_my_total
    from fn_meal_logs_between(p_room_id, v_from, v_today) where menu is not null and user_id = v_me.user_id;

  return fn_ok(jsonb_build_object(
    'fromDate', v_from, 'today', v_today, 'days', 30,
    'roomTop', v_room_top, 'myTop', v_my_top, 'placeTop', v_place_top,
    'totalCount', v_total, 'myCount', v_my_total,
    'trackMealLog', (select track_meal_log from rooms where id = p_room_id)
  ));
end;
$$;

-- ------------------------------------------------------------
-- 4) 히스토리 조회 — 날짜별 상세에 장소·메뉴 함께 반환 (REQ-17·18, SCR-05)
-- ------------------------------------------------------------
create or replace function api_get_history(p_token uuid, p_room_id uuid) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_me record;
  v_today date := fn_today();
  v_cutoff date := v_today - interval '29 days';
  v_entries jsonb := '{}'::jsonb;
  v_today_going text[];
  v_today_not text[];
  v_today_meals jsonb;
begin
  select * into v_me from fn_auth(p_token);
  if v_me.user_id is null then return fn_err('AUTH'); end if;
  if fn_member_role(p_room_id, v_me.user_id) is null then return fn_err('NOT_MEMBER'); end if;

  select coalesce(jsonb_object_agg(to_char(h.date, 'YYYY-MM-DD'), jsonb_build_object(
      'going', case when h.going_names = '' then '[]'::jsonb else to_jsonb(string_to_array(h.going_names, ',')) end,
      'notGoing', case when h.not_going_names = '' then '[]'::jsonb else to_jsonb(string_to_array(h.not_going_names, ',')) end,
      'meals', coalesce(h.meal_logs, '[]'::jsonb)
    )), '{}'::jsonb) into v_entries
    from history h where h.room_id = p_room_id and h.date >= v_cutoff and h.date <= v_today;

  -- 응답 시점 스냅샷(responses.nickname) 사용 — 이후 강퇴/탈퇴돼도 오늘 기록은 유지됨
  select array_agg(coalesce(r.nickname, '(알수없음)')) into v_today_going
    from responses r where r.room_id = p_room_id and r.date = v_today and r.status = 'going';
  select array_agg(coalesce(r.nickname, '(알수없음)')) into v_today_not
    from responses r where r.room_id = p_room_id and r.date = v_today and r.status = 'not-going';

  -- 오늘은 아직 히스토리로 안 넘어갔으므로 responses에서 직접 조립
  select coalesce(jsonb_agg(jsonb_build_object(
      'userId', r.user_id, 'nickname', coalesce(r.nickname, '(알수없음)'),
      'place', r.place_name, 'menu', r.menu_name
    )) filter (where r.place_name is not null or r.menu_name is not null), '[]'::jsonb)
  into v_today_meals
    from responses r where r.room_id = p_room_id and r.date = v_today and r.status = 'going';

  if v_today_going is not null or v_today_not is not null then
    v_entries := v_entries || jsonb_build_object(to_char(v_today, 'YYYY-MM-DD'), jsonb_build_object(
      'going', to_jsonb(coalesce(v_today_going, array[]::text[])),
      'notGoing', to_jsonb(coalesce(v_today_not, array[]::text[])),
      'meals', coalesce(v_today_meals, '[]'::jsonb)
    ));
  end if;

  return fn_ok(jsonb_build_object('entries', v_entries, 'today', v_today, 'cutoff', v_cutoff));
end;
$$;

-- 프론트가 호출하는 api_* 함수에만 실행 권한을 준다 (12_v2_grants_fix.sql 참고)
grant execute on function api_get_menu_ranking(uuid, uuid) to anon, authenticated;
grant execute on function api_get_history(uuid, uuid) to anon, authenticated;
-- ⚠️ fn_meal_logs_between은 인증 검사가 없는 내부 헬퍼다. 절대 외부에 열지 말 것
--    (api_get_menu_ranking이 SECURITY DEFINER로 대신 호출해준다)
revoke execute on function fn_meal_logs_between(uuid, date, date) from public;
revoke execute on function fn_meal_logs_between(uuid, date, date) from anon, authenticated;

-- ============================================================
-- 실행 후 확인 (방 id를 넣어 직접 집계 확인)
--   select * from fn_meal_logs_between('방ID'::uuid, current_date - 29, current_date);
-- ============================================================
