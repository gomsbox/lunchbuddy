-- ============================================================
-- 🍱 오늘점심 v2 — 방 목록 순서 편집 (REQ-26)
-- 08~15 실행 후 이 파일 전체를 SQL Editor에 붙여넣고 Run 하세요.
--
-- 순서는 **사람마다 다르게** 저장한다. 같은 방을 쓰는 사람들이 서로 다른 순서를
-- 원할 수 있으므로 rooms가 아니라 members(방×사용자)에 저장한다.
-- ============================================================

-- 아직 순서를 정하지 않은 방은 null → 정렬에서 뒤로 밀고 생성일 순으로 이어붙인다
alter table members add column if not exists sort_order int;

-- ------------------------------------------------------------
-- 1) 방 목록 조회 — 저장된 순서를 반영
--    (09_v2_room_purpose.sql 버전에 정렬만 추가)
-- ------------------------------------------------------------
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

  select coalesce(jsonb_agg(jsonb_build_object(
      'roomId', t.id, 'roomName', t.name, 'role', t.role,
      'purpose', t.purpose, 'eventStatus', t.event_status,
      'goingCount', t.going_count, 'memberCount', t.member_count
    ) order by t.sort_order nulls last, t.created_at), '[]'::jsonb) into v_host
  from (
    select r.id, r.name, m.role, r.purpose, r.event_status, m.sort_order, r.created_at,
      (select count(*) from responses resp
        where resp.room_id = r.id and resp.date = v_today and resp.status = 'going') as going_count,
      (select count(*) from members mm where mm.room_id = r.id) as member_count
    from members m join rooms r on r.id = m.room_id
    where m.user_id = v_me.user_id and m.role = 'host'
  ) t;

  select coalesce(jsonb_agg(jsonb_build_object(
      'roomId', t.id, 'roomName', t.name, 'role', t.role,
      'purpose', t.purpose, 'eventStatus', t.event_status,
      'goingCount', t.going_count, 'memberCount', t.member_count
    ) order by t.sort_order nulls last, t.created_at), '[]'::jsonb) into v_other
  from (
    select r.id, r.name, m.role, r.purpose, r.event_status, m.sort_order, r.created_at,
      (select count(*) from responses resp
        where resp.room_id = r.id and resp.date = v_today and resp.status = 'going') as going_count,
      (select count(*) from members mm where mm.room_id = r.id) as member_count
    from members m join rooms r on r.id = m.room_id
    where m.user_id = v_me.user_id and m.role <> 'host'
  ) t;

  return fn_ok(jsonb_build_object('hostRooms', v_host, 'otherRooms', v_other));
end;
$$;

-- ------------------------------------------------------------
-- 2) 순서 저장 — 방 id 배열을 받은 순서대로 1, 2, 3... 부여
--    내가 멤버인 방만 갱신되므로, 남의 방 id를 섞어 보내도 아무 일도 일어나지 않는다.
-- ------------------------------------------------------------
create or replace function api_set_room_order(p_token uuid, p_room_ids uuid[]) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_me record;
  v_updated int;
begin
  select * into v_me from fn_auth(p_token);
  if v_me.user_id is null then return fn_err('AUTH'); end if;
  if p_room_ids is null or array_length(p_room_ids, 1) is null then
    return fn_err('정렬할 방 목록이 비어 있습니다.');
  end if;

  update members m set sort_order = t.ord
  from unnest(p_room_ids) with ordinality as t(room_id, ord)
  where m.user_id = v_me.user_id and m.room_id = t.room_id;

  get diagnostics v_updated = row_count;
  return fn_ok(jsonb_build_object('updated', v_updated));
end;
$$;

grant execute on function api_get_my_rooms(uuid) to anon, authenticated;
grant execute on function api_set_room_order(uuid, uuid[]) to anon, authenticated;

-- ============================================================
-- 실행 후 확인
--   select r.name, m.sort_order from members m join rooms r on r.id = m.room_id
--   where m.user_id = '내_사용자ID'::uuid order by m.sort_order nulls last, r.created_at;
-- ============================================================
