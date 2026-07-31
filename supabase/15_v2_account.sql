-- ============================================================
-- 🍱 오늘점심 v2 — 6단계: 자동완성·랜덤 추천 + 회원 탈퇴 (REQ-20, REQ-21)
-- 08~14 실행 후 이 파일 전체를 SQL Editor에 붙여넣고 Run 하세요.
-- ============================================================

-- ------------------------------------------------------------
-- 1) REQ-20 · 내가 최근에 입력한 장소·메뉴 (자동완성 + 랜덤 추천용)
--    "본인이 최근 30일간 입력한 값"만 돌려준다. 다른 사람 기록은 노출하지 않는다.
--    같은 값은 묶어서 최근 사용 순 + 사용 횟수 순으로 정렬한다.
-- ------------------------------------------------------------
create or replace function api_get_my_meal_suggestions(p_token uuid, p_room_id uuid) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_me record;
  v_today date := fn_today();
  v_from date := v_today - interval '29 days';
  v_menus jsonb;
  v_places jsonb;
begin
  select * into v_me from fn_auth(p_token);
  if v_me.user_id is null then return fn_err('AUTH'); end if;
  if fn_member_role(p_room_id, v_me.user_id) is null then return fn_err('NOT_MEMBER'); end if;

  -- 방을 가리지 않고 "내가 쓴 값" 전체에서 모은다 (여러 방을 쓰는 사람에게 더 유용)
  select coalesce(jsonb_agg(label order by cnt desc, label asc), '[]'::jsonb) into v_menus from (
    select mode() within group (order by menu) as label, count(*)::int as cnt
    from (
      select (e->>'menu') as menu
      from history h, jsonb_array_elements(h.meal_logs) e
      where h.date between v_from and v_today and (e->>'userId')::uuid = v_me.user_id
        and nullif(trim(coalesce(e->>'menu', '')), '') is not null
      union all
      select r.menu_name
      from responses r
      where r.user_id = v_me.user_id and r.date between v_from and v_today
        and nullif(trim(coalesce(r.menu_name, '')), '') is not null
    ) s
    group by lower(regexp_replace(menu, '\s+', '', 'g'))
    order by cnt desc
    limit 12
  ) t;

  select coalesce(jsonb_agg(label order by cnt desc, label asc), '[]'::jsonb) into v_places from (
    select mode() within group (order by place) as label, count(*)::int as cnt
    from (
      select (e->>'place') as place
      from history h, jsonb_array_elements(h.meal_logs) e
      where h.date between v_from and v_today and (e->>'userId')::uuid = v_me.user_id
        and nullif(trim(coalesce(e->>'place', '')), '') is not null
      union all
      select r.place_name
      from responses r
      where r.user_id = v_me.user_id and r.date between v_from and v_today
        and nullif(trim(coalesce(r.place_name, '')), '') is not null
    ) s
    group by lower(regexp_replace(place, '\s+', '', 'g'))
    order by cnt desc
    limit 12
  ) t;

  return fn_ok(jsonb_build_object('menus', v_menus, 'places', v_places));
end;
$$;

-- ------------------------------------------------------------
-- 2) REQ-21 · 회원 탈퇴
--    비밀번호로 본인 확인 후 계정을 삭제한다.
--    · 채팅·히스토리는 닉네임 스냅샷으로 남으므로 기록이 깨지지 않는다
--      (messages.nickname / responses.nickname / history.meal_logs 모두 스냅샷 구조)
--    · 내가 유일한 호스트인 방은 남은 멤버에게 넘길 수 없으므로 함께 삭제한다.
--      단 다른 멤버가 있으면 실수로 방이 사라지지 않도록 기본적으로 막고,
--      p_delete_my_rooms = true를 명시했을 때만 삭제한다 (프론트에서 2차 확인).
-- ------------------------------------------------------------
create or replace function api_delete_account(
  p_token uuid, p_password text, p_delete_my_rooms boolean default false
) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_me record;
  v_user record;
  v_blocking jsonb;
  v_room record;
begin
  select * into v_me from fn_auth(p_token);
  if v_me.user_id is null then return fn_err('AUTH'); end if;

  select * into v_user from users where id = v_me.user_id;
  if v_user.id is null then return fn_err('계정을 찾을 수 없습니다.'); end if;

  -- 게스트는 비밀번호가 없다 — "이 브라우저에서 나가기"(로그아웃)로 안내한다
  if coalesce(v_user.is_guest, false) then
    return fn_err('이름만 입력해 참여한 모임은 탈퇴 대신 "이 브라우저에서 나가기"를 사용해주세요.');
  end if;
  if v_user.password_hash is null
     or v_user.password_hash <> crypt(coalesce(p_password, ''), v_user.password_hash) then
    return fn_err('비밀번호가 올바르지 않습니다.');
  end if;

  -- 내가 호스트이고 다른 멤버가 남아 있는 방 목록
  select coalesce(jsonb_agg(jsonb_build_object(
      'roomId', r.id, 'roomName', r.name,
      'otherMembers', (select count(*) from members m2 where m2.room_id = r.id and m2.user_id <> v_me.user_id)
    )), '[]'::jsonb) into v_blocking
    from rooms r
    where r.host_user_id = v_me.user_id
      and exists (select 1 from members m2 where m2.room_id = r.id and m2.user_id <> v_me.user_id);

  -- 다른 멤버가 남아 있는 방이 있으면, 명시적으로 동의하지 않은 경우 중단
  if jsonb_array_length(v_blocking) > 0 and not coalesce(p_delete_my_rooms, false) then
    return fn_err('HOST_ROOMS');
  end if;

  -- 내가 호스트인 방을 모두 삭제 (members·responses·history·messages·menu_polls cascade)
  for v_room in select id from rooms where host_user_id = v_me.user_id loop
    delete from rooms where id = v_room.id;
  end loop;

  -- 계정 삭제 → sessions·members·responses·votes cascade.
  -- messages·history는 닉네임 스냅샷이 남지만, messages.user_id는 cascade라 메시지 자체는 삭제된다.
  delete from users where id = v_me.user_id;

  return fn_ok(jsonb_build_object('deleted', true));
end;
$$;

-- ------------------------------------------------------------
-- 3) 탈퇴 전 확인용 — 내가 호스트인 방과 남은 멤버 수를 미리 보여준다
-- ------------------------------------------------------------
create or replace function api_get_delete_preview(p_token uuid) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_me record;
  v_rooms jsonb;
  v_is_guest boolean;
begin
  select * into v_me from fn_auth(p_token);
  if v_me.user_id is null then return fn_err('AUTH'); end if;
  select coalesce(is_guest, false) into v_is_guest from users where id = v_me.user_id;

  select coalesce(jsonb_agg(jsonb_build_object(
      'roomId', r.id, 'roomName', r.name,
      'otherMembers', (select count(*) from members m2 where m2.room_id = r.id and m2.user_id <> v_me.user_id)
    ) order by r.created_at), '[]'::jsonb) into v_rooms
    from rooms r where r.host_user_id = v_me.user_id;

  return fn_ok(jsonb_build_object('isGuest', v_is_guest, 'hostRooms', v_rooms));
end;
$$;

-- ------------------------------------------------------------
-- 4) 권한 — api_* 만
-- ------------------------------------------------------------
grant execute on function api_get_my_meal_suggestions(uuid, uuid) to anon, authenticated;
grant execute on function api_delete_account(uuid, text, boolean) to anon, authenticated;
grant execute on function api_get_delete_preview(uuid) to anon, authenticated;

-- ============================================================
-- 실행 후 확인
--   select p.proname, has_function_privilege('anon', p.oid, 'execute') as anon_can_run
--   from pg_proc p join pg_namespace n on n.oid = p.pronamespace
--   where n.nspname = 'public' and (p.proname like 'api\_%' or p.proname like 'fn\_%')
--   order by anon_can_run desc, p.proname;
-- ============================================================
