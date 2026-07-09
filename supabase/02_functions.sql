-- ============================================================
-- 🍱 오늘점심 — Supabase 스키마 (2/3: RPC 함수)
-- 01_schema.sql 실행 후 이 파일 전체를 SQL Editor에 붙여넣고 Run 하세요.
-- 프론트엔드는 supabase.rpc('api_xxx', {...}) 형태로 이 함수들을 호출합니다.
-- ============================================================

-- ---------- 공통 헬퍼 ----------

create or replace function fn_ok(p_data jsonb default 'null'::jsonb) returns jsonb
language sql immutable as $$
  select jsonb_build_object('ok', true, 'data', p_data);
$$;

create or replace function fn_err(p_msg text) returns jsonb
language sql immutable as $$
  select jsonb_build_object('ok', false, 'error', p_msg);
$$;

create or replace function fn_today() returns date
language sql stable as $$
  select (now() at time zone 'Asia/Seoul')::date;
$$;

-- 세션 토큰 검증 → 사용자 정보 (없으면 null)
create or replace function fn_auth(p_token uuid)
returns table(user_id uuid, login_id text, nickname text, email text)
language plpgsql security definer set search_path = public, extensions as $$
begin
  if p_token is null then return; end if;
  return query
    select u.id, u.login_id, u.nickname, coalesce(u.email, '')
    from sessions s join users u on u.id = s.user_id
    where s.token = p_token and s.expires_at > now();
end;
$$;

-- 방 멤버 역할 조회 (없으면 null)
create or replace function fn_member_role(p_room_id uuid, p_user_id uuid) returns text
language sql stable security definer set search_path = public, extensions as $$
  select role from members where room_id = p_room_id and user_id = p_user_id;
$$;

create or replace function fn_new_room_code() returns text
language plpgsql security definer set search_path = public, extensions as $$
declare
  chars text := 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';
  v_code text;
begin
  loop
    v_code := '';
    for i in 1..6 loop
      v_code := v_code || substr(chars, 1 + floor(random() * length(chars))::int, 1);
    end loop;
    exit when not exists (select 1 from rooms where room_code = v_code);
  end loop;
  return v_code;
end;
$$;

-- ---------- REQ-01·02 회원가입 / 로그인 / 세션 ----------

create or replace function api_signup(p_login_id text, p_password text, p_email text default null)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_login_id text := lower(trim(coalesce(p_login_id, '')));
  v_email text := nullif(trim(coalesce(p_email, '')), '');
  v_user_id uuid;
  v_token uuid;
begin
  if v_login_id !~ '^[a-z0-9]{4,20}$' then
    return fn_err('아이디는 4~20자의 영문 소문자와 숫자만 사용할 수 있습니다.');
  end if;
  if p_password is null or length(p_password) < 8 or p_password !~ '[A-Za-z]' or p_password !~ '[0-9]' then
    return fn_err('비밀번호는 8자 이상이며 영문과 숫자를 모두 포함해야 합니다.');
  end if;
  if v_email is not null and v_email !~ '^[^\s@]+@[^\s@]+\.[^\s@]+$' then
    return fn_err('이메일 형식이 올바르지 않습니다. (선택 항목이므로 비워둘 수 있습니다)');
  end if;
  if exists (select 1 from users where login_id = v_login_id) then
    return fn_err('이미 사용 중인 아이디입니다.');
  end if;

  insert into users (login_id, password_hash, nickname, email)
  values (v_login_id, crypt(p_password, gen_salt('bf')), v_login_id, v_email)
  returning id into v_user_id;

  insert into sessions (user_id, expires_at) values (v_user_id, now() + interval '30 days')
  returning token into v_token;

  return fn_ok(jsonb_build_object('token', v_token, 'user', jsonb_build_object(
    'userId', v_user_id, 'loginId', v_login_id, 'nickname', v_login_id, 'email', coalesce(v_email, '')
  )));
exception when unique_violation then
  return fn_err('이미 사용 중인 아이디입니다.');
end;
$$;

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

  select * into v_user from users where login_id = v_login_id;

  if v_user.id is null or v_user.password_hash <> crypt(p_password, v_user.password_hash) then
    select coalesce(fail_count, 0) + 1 into v_fail from login_attempts where login_id = v_login_id;
    v_fail := coalesce(v_fail, 1);
    if v_fail >= 5 then
      insert into login_attempts (login_id, fail_count, blocked_until) values (v_login_id, 0, now() + interval '10 minutes')
      on conflict (login_id) do update set fail_count = 0, blocked_until = now() + interval '10 minutes';
      return fn_err('아이디 또는 비밀번호가 올바르지 않습니다. 5회 실패로 10분간 차단됩니다.');
    else
      insert into login_attempts (login_id, fail_count, blocked_until) values (v_login_id, v_fail, null)
      on conflict (login_id) do update set fail_count = v_fail, blocked_until = null;
      return fn_err('아이디 또는 비밀번호가 올바르지 않습니다. (' || v_fail || '/5회)');
    end if;
  end if;

  delete from login_attempts where login_id = v_login_id;
  insert into sessions (user_id, expires_at) values (v_user.id, now() + interval '30 days')
  returning token into v_token;

  return fn_ok(jsonb_build_object('token', v_token, 'user', jsonb_build_object(
    'userId', v_user.id, 'loginId', v_user.login_id, 'nickname', v_user.nickname, 'email', coalesce(v_user.email, '')
  )));
end;
$$;

create or replace function api_logout(p_token uuid) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
begin
  delete from sessions where token = p_token;
  return fn_ok();
end;
$$;

create or replace function api_get_me(p_token uuid) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare v_me record;
begin
  select * into v_me from fn_auth(p_token);
  if v_me.user_id is null then return fn_err('AUTH'); end if;
  return fn_ok(jsonb_build_object('user', jsonb_build_object(
    'userId', v_me.user_id, 'loginId', v_me.login_id, 'nickname', v_me.nickname, 'email', v_me.email
  )));
end;
$$;

-- ---------- REQ-03·04 방 생성 / 초대 ----------

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
      (select count(*) from responses resp where resp.room_id = r.id and resp.date = v_today and resp.status = 'going') as "goingCount",
      (select count(*) from members mm where mm.room_id = r.id) as "memberCount"
    from members m join rooms r on r.id = m.room_id
    where m.user_id = v_me.user_id and m.role = 'host'
  ) x;

  select coalesce(jsonb_agg(x), '[]'::jsonb) into v_other from (
    select r.id as "roomId", r.name as "roomName", m.role,
      (select count(*) from responses resp where resp.room_id = r.id and resp.date = v_today and resp.status = 'going') as "goingCount",
      (select count(*) from members mm where mm.room_id = r.id) as "memberCount"
    from members m join rooms r on r.id = m.room_id
    where m.user_id = v_me.user_id and m.role <> 'host'
  ) x;

  return fn_ok(jsonb_build_object('hostRooms', v_host, 'otherRooms', v_other));
end;
$$;

create or replace function api_create_room(p_token uuid, p_room_name text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_me record;
  v_name text := trim(coalesce(p_room_name, ''));
  v_room_id uuid;
begin
  select * into v_me from fn_auth(p_token);
  if v_me.user_id is null then return fn_err('AUTH'); end if;
  if length(v_name) < 2 or length(v_name) > 20 then
    return fn_err('방 이름은 2~20자로 입력해주세요.');
  end if;

  insert into rooms (name, host_user_id, room_code) values (v_name, v_me.user_id, fn_new_room_code())
  returning id into v_room_id;
  insert into members (room_id, user_id, role) values (v_room_id, v_me.user_id, 'host');

  return fn_ok(jsonb_build_object('roomId', v_room_id));
end;
$$;

create or replace function api_join_by_invite(p_token uuid, p_invite_token uuid) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_me record;
  v_room record;
begin
  select * into v_me from fn_auth(p_token);
  if v_me.user_id is null then return fn_err('AUTH'); end if;

  select * into v_room from rooms where invite_token = p_invite_token;
  if v_room.id is null or v_room.invite_expires_at < now() then
    return fn_err('EXPIRED');
  end if;

  if fn_member_role(v_room.id, v_me.user_id) is not null then
    return fn_ok(jsonb_build_object('roomId', v_room.id, 'already', true));
  end if;

  insert into members (room_id, user_id, role) values (v_room.id, v_me.user_id, 'member')
  on conflict do nothing;
  return fn_ok(jsonb_build_object('roomId', v_room.id, 'already', false));
end;
$$;

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

  if fn_member_role(v_room.id, v_me.user_id) is not null then
    return fn_ok(jsonb_build_object('roomId', v_room.id, 'already', true));
  end if;

  insert into members (room_id, user_id, role) values (v_room.id, v_me.user_id, 'member')
  on conflict do nothing;
  return fn_ok(jsonb_build_object('roomId', v_room.id, 'already', false));
end;
$$;

-- ---------- REQ-05·06·13 현황 + 채팅 통합 조회 / 참여 등록 ----------

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
  v_messages jsonb;
begin
  select * into v_me from fn_auth(p_token);
  if v_me.user_id is null then return fn_err('AUTH'); end if;

  v_role := fn_member_role(p_room_id, v_me.user_id);
  if v_role is null then return fn_err('NOT_MEMBER'); end if;

  select * into v_room from rooms where id = p_room_id;
  if v_room.id is null then return fn_err('방을 찾을 수 없습니다.'); end if;

  select coalesce(jsonb_agg(jsonb_build_object('userId', m.user_id, 'nickname', u.nickname)), '[]'::jsonb) into v_going
    from members m join users u on u.id = m.user_id
    join responses r on r.room_id = m.room_id and r.user_id = m.user_id and r.date = v_today
    where m.room_id = p_room_id and r.status = 'going';

  select coalesce(jsonb_agg(jsonb_build_object('userId', m.user_id, 'nickname', u.nickname)), '[]'::jsonb) into v_not_going
    from members m join users u on u.id = m.user_id
    join responses r on r.room_id = m.room_id and r.user_id = m.user_id and r.date = v_today
    where m.room_id = p_room_id and r.status = 'not-going';

  select coalesce(jsonb_agg(jsonb_build_object('userId', m.user_id, 'nickname', u.nickname)), '[]'::jsonb) into v_no_response
    from members m join users u on u.id = m.user_id
    where m.room_id = p_room_id
      and not exists (select 1 from responses r where r.room_id = m.room_id and r.user_id = m.user_id and r.date = v_today);

  select status into v_my_status from responses where room_id = p_room_id and user_id = v_me.user_id and date = v_today;

  -- sentAt: timestamptz를 서울 시각의 "naive" 타임스탬프로 변환해 반환 (그대로 두면 UTC로 직렬화되어 프론트 시간 표시가 9시간 어긋남)
  select coalesce(jsonb_agg(jsonb_build_object(
      'messageId', msg.id, 'userId', msg.user_id, 'nickname', u.nickname, 'text', msg.text,
      'sentAt', (msg.sent_at at time zone 'Asia/Seoul')
    ) order by msg.sent_at), '[]'::jsonb) into v_messages
    from messages msg join users u on u.id = msg.user_id
    where msg.room_id = p_room_id and (msg.sent_at at time zone 'Asia/Seoul')::date = v_today;

  return fn_ok(jsonb_build_object(
    'roomName', v_room.name, 'date', v_today, 'myRole', v_role, 'myUserId', v_me.user_id,
    'myStatus', v_my_status, 'going', v_going, 'notGoing', v_not_going, 'noResponse', v_no_response,
    'inviteToken', v_room.invite_token, 'roomCode', v_room.room_code, 'messages', v_messages
  ));
end;
$$;

create or replace function api_set_response(p_token uuid, p_room_id uuid, p_status text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_me record;
  v_today date := fn_today();
begin
  select * into v_me from fn_auth(p_token);
  if v_me.user_id is null then return fn_err('AUTH'); end if;
  if fn_member_role(p_room_id, v_me.user_id) is null then return fn_err('NOT_MEMBER'); end if;
  if p_status not in ('going', 'not-going', 'clear') then return fn_err('잘못된 응답 값입니다.'); end if;

  if p_status = 'clear' then
    delete from responses where room_id = p_room_id and user_id = v_me.user_id and date = v_today;
  else
    insert into responses (date, room_id, user_id, status) values (v_today, p_room_id, v_me.user_id, p_status)
    on conflict (date, room_id, user_id) do update set status = excluded.status, updated_at = now();
  end if;
  return fn_ok();
end;
$$;

create or replace function api_send_message(p_token uuid, p_room_id uuid, p_text text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_me record;
  v_text text := trim(coalesce(p_text, ''));
begin
  select * into v_me from fn_auth(p_token);
  if v_me.user_id is null then return fn_err('AUTH'); end if;
  if fn_member_role(p_room_id, v_me.user_id) is null then return fn_err('NOT_MEMBER'); end if;
  if v_text = '' then return fn_err('메시지를 입력해주세요.'); end if;
  if length(v_text) > 300 then return fn_err('메시지는 300자 이내로 입력해주세요.'); end if;

  insert into messages (room_id, user_id, text) values (p_room_id, v_me.user_id, v_text);
  return fn_ok();
end;
$$;

-- ---------- REQ-08 월간 히스토리 ----------

create or replace function api_get_history(p_token uuid, p_room_id uuid) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_me record;
  v_today date := fn_today();
  v_cutoff date := v_today - interval '29 days';
  v_entries jsonb := '{}'::jsonb;
  v_today_going text[];
  v_today_not text[];
begin
  select * into v_me from fn_auth(p_token);
  if v_me.user_id is null then return fn_err('AUTH'); end if;
  if fn_member_role(p_room_id, v_me.user_id) is null then return fn_err('NOT_MEMBER'); end if;

  select coalesce(jsonb_object_agg(to_char(h.date, 'YYYY-MM-DD'), jsonb_build_object(
      'going', case when h.going_names = '' then '[]'::jsonb else to_jsonb(string_to_array(h.going_names, ',')) end,
      'notGoing', case when h.not_going_names = '' then '[]'::jsonb else to_jsonb(string_to_array(h.not_going_names, ',')) end
    )), '{}'::jsonb) into v_entries
    from history h where h.room_id = p_room_id and h.date >= v_cutoff and h.date <= v_today;

  select array_agg(u.nickname) into v_today_going
    from responses r join users u on u.id = r.user_id
    where r.room_id = p_room_id and r.date = v_today and r.status = 'going';
  select array_agg(u.nickname) into v_today_not
    from responses r join users u on u.id = r.user_id
    where r.room_id = p_room_id and r.date = v_today and r.status = 'not-going';

  if v_today_going is not null or v_today_not is not null then
    v_entries := v_entries || jsonb_build_object(to_char(v_today, 'YYYY-MM-DD'), jsonb_build_object(
      'going', to_jsonb(coalesce(v_today_going, array[]::text[])),
      'notGoing', to_jsonb(coalesce(v_today_not, array[]::text[]))
    ));
  end if;

  return fn_ok(jsonb_build_object('entries', v_entries, 'today', v_today, 'cutoff', v_cutoff));
end;
$$;

-- ---------- REQ-09 개인 설정 ----------

create or replace function api_update_nickname(p_token uuid, p_nickname text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_me record;
  v_nick text := trim(coalesce(p_nickname, ''));
begin
  select * into v_me from fn_auth(p_token);
  if v_me.user_id is null then return fn_err('AUTH'); end if;
  if v_nick !~ '^[가-힣A-Za-z0-9]{2,10}$' then
    return fn_err('닉네임은 2~10자의 한글/영문/숫자만 사용할 수 있습니다.');
  end if;
  update users set nickname = v_nick where id = v_me.user_id;
  return fn_ok(jsonb_build_object('nickname', v_nick));
end;
$$;

create or replace function api_change_password(p_token uuid, p_current_pw text, p_new_pw text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_me record;
  v_hash text;
begin
  select * into v_me from fn_auth(p_token);
  if v_me.user_id is null then return fn_err('AUTH'); end if;
  if p_new_pw is null or length(p_new_pw) < 8 or p_new_pw !~ '[A-Za-z]' or p_new_pw !~ '[0-9]' then
    return fn_err('새 비밀번호는 8자 이상이며 영문과 숫자를 모두 포함해야 합니다.');
  end if;
  select password_hash into v_hash from users where id = v_me.user_id;
  if v_hash <> crypt(p_current_pw, v_hash) then
    return fn_err('현재 비밀번호가 올바르지 않습니다.');
  end if;
  update users set password_hash = crypt(p_new_pw, gen_salt('bf')) where id = v_me.user_id;
  return fn_ok();
end;
$$;

create or replace function api_update_email(p_token uuid, p_email text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_me record;
  v_email text := nullif(trim(coalesce(p_email, '')), '');
begin
  select * into v_me from fn_auth(p_token);
  if v_me.user_id is null then return fn_err('AUTH'); end if;
  if v_email is not null and v_email !~ '^[^\s@]+@[^\s@]+\.[^\s@]+$' then
    return fn_err('이메일 형식이 올바르지 않습니다.');
  end if;
  update users set email = v_email where id = v_me.user_id;
  return fn_ok(jsonb_build_object('email', coalesce(v_email, '')));
exception when unique_violation then
  return fn_err('이미 다른 계정에서 사용 중인 이메일입니다.');
end;
$$;

-- ---------- REQ-15 셀프 비밀번호 찾기 (이메일 등록자만) ----------

create or replace function api_request_password_reset(p_login_id text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_user record;
  v_reset_token uuid;
  v_api_key text;
  v_frontend_url text := coalesce((select value from app_config where key = 'frontend_url'), 'https://gomsbox.github.io/lunchbuddy/');
begin
  select * into v_user from users where login_id = lower(trim(coalesce(p_login_id, '')));
  -- 계정 존재 여부를 노출하지 않기 위해 항상 동일한 성공 메시지 반환
  if v_user.id is not null and v_user.email is not null then
    insert into password_resets (user_id, expires_at) values (v_user.id, now() + interval '30 minutes')
    returning token into v_reset_token;

    select value into v_api_key from app_config where key = 'resend_api_key';
    if v_api_key is not null then
      perform net.http_post(
        url := 'https://api.resend.com/emails',
        headers := jsonb_build_object('Authorization', 'Bearer ' || v_api_key, 'Content-Type', 'application/json'),
        body := jsonb_build_object(
          'from', '오늘점심 <onboarding@resend.dev>',
          'to', jsonb_build_array(v_user.email),
          'subject', '🍱 [오늘점심] 비밀번호 재설정',
          'html', '<div style="font-family:sans-serif;max-width:480px;margin:0 auto;">' ||
            '<h2>🍱 비밀번호를 재설정해주세요</h2>' ||
            '<p>아래 버튼을 눌러 새 비밀번호를 설정하세요. 이 링크는 30분간 유효합니다.</p>' ||
            '<p><a href="' || v_frontend_url || '?reset=' || v_reset_token::text ||
              '" style="display:inline-block;background:#22a45d;color:#fff;padding:12px 24px;border-radius:10px;text-decoration:none;font-weight:bold;">비밀번호 재설정</a></p>' ||
            '<p style="color:#888;font-size:12px;">본인이 요청하지 않았다면 이 메일을 무시하세요.</p></div>'
        )
      );
    end if;
  end if;

  return fn_ok(jsonb_build_object('message', '등록된 이메일이 있다면 재설정 링크를 보냈습니다.'));
end;
$$;

create or replace function api_reset_password(p_reset_token uuid, p_new_password text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_reset record;
begin
  if p_new_password is null or length(p_new_password) < 8 or p_new_password !~ '[A-Za-z]' or p_new_password !~ '[0-9]' then
    return fn_err('새 비밀번호는 8자 이상이며 영문과 숫자를 모두 포함해야 합니다.');
  end if;

  select * into v_reset from password_resets where token = p_reset_token and used = false and expires_at > now();
  if v_reset.token is null then
    return fn_err('링크가 만료되었거나 이미 사용되었습니다. 다시 요청해주세요.');
  end if;

  update users set password_hash = crypt(p_new_password, gen_salt('bf')) where id = v_reset.user_id;
  update password_resets set used = true where token = p_reset_token;
  delete from sessions where user_id = v_reset.user_id;      -- 기존 세션 전체 만료 (보안)
  delete from login_attempts where login_id = (select login_id from users where id = v_reset.user_id);

  return fn_ok();
end;
$$;

-- ---------- REQ-10·11 방 관리 / 공동 호스트 ----------

create or replace function fn_require_manager(p_room_id uuid, p_user_id uuid) returns text
language sql stable security definer set search_path = public, extensions as $$
  select role from members where room_id = p_room_id and user_id = p_user_id and role in ('host', 'co-host');
$$;

create or replace function api_get_members(p_token uuid, p_room_id uuid) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_me record;
  v_myrole text;
  v_members jsonb;
begin
  select * into v_me from fn_auth(p_token);
  if v_me.user_id is null then return fn_err('AUTH'); end if;
  v_myrole := fn_require_manager(p_room_id, v_me.user_id);
  if v_myrole is null then return fn_err('권한이 없습니다.'); end if;

  select coalesce(jsonb_agg(jsonb_build_object(
      'userId', m.user_id, 'nickname', u.nickname, 'role', m.role, 'joinedAt', m.joined_at
    ) order by case m.role when 'host' then 0 when 'co-host' then 1 else 2 end, u.nickname), '[]'::jsonb)
    into v_members
    from members m join users u on u.id = m.user_id where m.room_id = p_room_id;

  return fn_ok(jsonb_build_object('members', v_members, 'myRole', v_myrole, 'myUserId', v_me.user_id));
end;
$$;

create or replace function api_rename_room(p_token uuid, p_room_id uuid, p_room_name text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_me record;
  v_name text := trim(coalesce(p_room_name, ''));
begin
  select * into v_me from fn_auth(p_token);
  if v_me.user_id is null then return fn_err('AUTH'); end if;
  if fn_require_manager(p_room_id, v_me.user_id) is null then return fn_err('권한이 없습니다.'); end if;
  if length(v_name) < 2 or length(v_name) > 20 then return fn_err('방 이름은 2~20자로 입력해주세요.'); end if;

  update rooms set name = v_name where id = p_room_id;
  return fn_ok(jsonb_build_object('roomName', v_name));
end;
$$;

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
    'notifyWeekday', v_room.notify_weekday, 'notifyWeekend', v_room.notify_weekend,
    'recipientCount', v_recipients
  ));
end;
$$;

-- 평일/주말 중복 선택 가능 — 둘 다 켜면 7일 내내, 평일만 켜면 월~금 5일, 주말만 켜면 토~일 2일 발송
create or replace function api_set_notify(p_token uuid, p_room_id uuid, p_enabled boolean, p_time text, p_weekday boolean default true, p_weekend boolean default false) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_me record;
  v_time text := trim(coalesce(p_time, ''));
begin
  select * into v_me from fn_auth(p_token);
  if v_me.user_id is null then return fn_err('AUTH'); end if;
  if fn_require_manager(p_room_id, v_me.user_id) is null then return fn_err('권한이 없습니다.'); end if;
  if p_enabled and v_time !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$' then
    return fn_err('발송 시각 형식이 올바르지 않습니다 (예: 10:30).');
  end if;
  if p_enabled and not coalesce(p_weekday, false) and not coalesce(p_weekend, false) then
    return fn_err('평일 또는 주말 중 최소 하나는 선택해주세요.');
  end if;
  if v_time = '' then v_time := '10:30'; end if;

  update rooms set notify_enabled = p_enabled, notify_time = v_time,
    notify_weekday = coalesce(p_weekday, true), notify_weekend = coalesce(p_weekend, false)
    where id = p_room_id;
  return fn_ok(jsonb_build_object(
    'notifyEnabled', p_enabled, 'notifyTime', v_time,
    'notifyWeekday', coalesce(p_weekday, true), 'notifyWeekend', coalesce(p_weekend, false)
  ));
end;
$$;

create or replace function api_regenerate_invite(p_token uuid, p_room_id uuid) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_me record;
  v_new_token uuid := gen_random_uuid();
begin
  select * into v_me from fn_auth(p_token);
  if v_me.user_id is null then return fn_err('AUTH'); end if;
  if fn_require_manager(p_room_id, v_me.user_id) is null then return fn_err('권한이 없습니다.'); end if;

  update rooms set invite_token = v_new_token, invite_expires_at = now() + interval '7 days' where id = p_room_id;
  return fn_ok(jsonb_build_object('inviteToken', v_new_token));
end;
$$;

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

  update members set role = p_role where room_id = p_room_id and user_id = p_target_user_id;
  return fn_ok();
end;
$$;

create or replace function api_kick_member(p_token uuid, p_room_id uuid, p_target_user_id uuid) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_me record;
  v_my_role text;
  v_target_role text;
begin
  select * into v_me from fn_auth(p_token);
  if v_me.user_id is null then return fn_err('AUTH'); end if;
  v_my_role := fn_require_manager(p_room_id, v_me.user_id);
  if v_my_role is null then return fn_err('권한이 없습니다.'); end if;
  if p_target_user_id = v_me.user_id then return fn_err('자기 자신은 내보낼 수 없습니다.'); end if;

  v_target_role := fn_member_role(p_room_id, p_target_user_id);
  if v_target_role is null then return fn_err('해당 멤버를 찾을 수 없습니다.'); end if;
  if v_target_role = 'host' then return fn_err('호스트는 내보낼 수 없습니다.'); end if;
  if v_my_role = 'co-host' and v_target_role = 'co-host' then
    return fn_err('공동 호스트는 다른 공동 호스트를 내보낼 수 없습니다.');
  end if;

  delete from members where room_id = p_room_id and user_id = p_target_user_id;
  return fn_ok();
end;
$$;

create or replace function api_delete_room(p_token uuid, p_room_id uuid) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare v_me record;
begin
  select * into v_me from fn_auth(p_token);
  if v_me.user_id is null then return fn_err('AUTH'); end if;
  if fn_member_role(p_room_id, v_me.user_id) <> 'host' then
    return fn_err('방 삭제는 호스트만 할 수 있습니다.');
  end if;
  delete from rooms where id = p_room_id;  -- members/responses/history/messages는 on delete cascade로 함께 삭제
  return fn_ok();
end;
$$;

-- ============================================================
-- 실행 권한 부여 — anon(로그인 전) · authenticated 둘 다 호출 가능해야 함
-- (이 앱은 자체 세션 토큰 방식이라 Supabase Auth의 authenticated 롤을 쓰지 않고 anon으로만 호출됨)
-- ============================================================
grant execute on all functions in schema public to anon, authenticated;
