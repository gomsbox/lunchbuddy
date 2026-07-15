-- ============================================================
-- 🍱 오늘점심 — 채팅 읽음 표시 (카카오톡 스타일 미읽음 숫자)
-- SQL Editor에서 이 파일 전체를 실행하세요. (01~06 실행 후 적용)
--
-- 동작 방식:
--   - members.last_read_at = 그 방을 마지막으로 확인한 시각
--   - 방 화면(오늘 탭)을 열어보는 것 자체가 "읽음 처리" — api_get_room_home 호출 시 갱신
--   - 각 메시지마다 "보낸 사람을 제외하고, 이 메시지 이후 아직 확인 안 한 멤버 수"를 계산해 반환
--   - 폴링(15초) 주기로 갱신되므로 카카오톡처럼 즉시는 아니고 최대 15초 지연 후 숫자가 줄어듦
-- ============================================================

-- 기존 멤버는 마이그레이션 시점을 기준으로 "읽음" 처리 (그 이전 메시지에 어색한 숫자가 안 뜨도록)
alter table members add column if not exists last_read_at timestamptz not null default now();

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
    'inviteToken', v_room.invite_token, 'roomCode', v_room.room_code, 'messages', v_messages
  ));
end;
$$;

grant execute on all functions in schema public to anon, authenticated;
