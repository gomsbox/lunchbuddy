-- ============================================================
-- 🍱 오늘점심 — 알림 발송 요일을 월~일 개별 선택으로 세분화
-- SQL Editor에서 이 파일 전체를 실행하세요. (01~05 실행 후 적용)
-- 기존 notify_weekday/notify_weekend 값은 그대로 두고, 대신
-- 요일별 컬럼 7개를 새 기준으로 사용합니다 (평일=월~금 켜짐, 주말=꺼짐 기본값).
-- ============================================================

alter table rooms add column if not exists notify_mon boolean not null default true;
alter table rooms add column if not exists notify_tue boolean not null default true;
alter table rooms add column if not exists notify_wed boolean not null default true;
alter table rooms add column if not exists notify_thu boolean not null default true;
alter table rooms add column if not exists notify_fri boolean not null default true;
alter table rooms add column if not exists notify_sat boolean not null default false;
alter table rooms add column if not exists notify_sun boolean not null default false;

-- 기존 평일/주말 설정값을 요일별 컬럼으로 1회 이관 (이미 방을 만든 경우 반영)
update rooms set
  notify_mon = notify_weekday, notify_tue = notify_weekday, notify_wed = notify_weekday,
  notify_thu = notify_weekday, notify_fri = notify_weekday,
  notify_sat = notify_weekend, notify_sun = notify_weekend;

-- ---------- 방 알림 설정 조회 — 요일별 값 반환 ----------
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
    'recipientCount', v_recipients
  ));
end;
$$;

-- ---------- 방 알림 설정 저장 — 요일별 선택 (최소 1일 이상 선택 필요) ----------
create or replace function api_set_notify(
  p_token uuid, p_room_id uuid, p_enabled boolean, p_time text,
  p_mon boolean default true, p_tue boolean default true, p_wed boolean default true,
  p_thu boolean default true, p_fri boolean default true, p_sat boolean default false, p_sun boolean default false
) returns jsonb
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
  if p_enabled and not (coalesce(p_mon,false) or coalesce(p_tue,false) or coalesce(p_wed,false)
      or coalesce(p_thu,false) or coalesce(p_fri,false) or coalesce(p_sat,false) or coalesce(p_sun,false)) then
    return fn_err('요일을 최소 하나는 선택해주세요.');
  end if;
  if v_time = '' then v_time := '10:30'; end if;

  update rooms set
    notify_enabled = p_enabled, notify_time = v_time,
    notify_mon = coalesce(p_mon,false), notify_tue = coalesce(p_tue,false), notify_wed = coalesce(p_wed,false),
    notify_thu = coalesce(p_thu,false), notify_fri = coalesce(p_fri,false),
    notify_sat = coalesce(p_sat,false), notify_sun = coalesce(p_sun,false),
    -- 평일/주말 컬럼도 참고용으로 함께 갱신 (전부 켜짐일 때만 true)
    notify_weekday = (coalesce(p_mon,false) and coalesce(p_tue,false) and coalesce(p_wed,false) and coalesce(p_thu,false) and coalesce(p_fri,false)),
    notify_weekend = (coalesce(p_sat,false) and coalesce(p_sun,false))
  where id = p_room_id;

  return fn_ok(jsonb_build_object(
    'notifyEnabled', p_enabled, 'notifyTime', v_time,
    'notifyDays', jsonb_build_object(
      'mon', coalesce(p_mon,false), 'tue', coalesce(p_tue,false), 'wed', coalesce(p_wed,false),
      'thu', coalesce(p_thu,false), 'fri', coalesce(p_fri,false), 'sat', coalesce(p_sat,false), 'sun', coalesce(p_sun,false)
    )
  ));
end;
$$;

grant execute on all functions in schema public to anon, authenticated;

-- ---------- 알림 발송 확인 — 요일별 판단 (메일 릴레이 버전, 05_mail_relay.sql 대체) ----------
create or replace function fn_send_notifications() returns void
language plpgsql security definer set search_path = public as $$
declare
  v_now_seoul timestamp := now() at time zone 'Asia/Seoul';
  v_dow int := extract(dow from v_now_seoul)::int;   -- 0=일요일 .. 6=토요일
  v_now_min int := extract(hour from v_now_seoul)::int * 60 + extract(minute from v_now_seoul)::int;
  v_today date := v_now_seoul::date;
  v_relay_url text;
  v_relay_secret text;
  v_owner_email text;
  v_frontend_url text;
  v_room record;
  v_target_min int;
  v_recipients text[];
  v_today_on boolean;
begin
  select value into v_relay_url from app_config where key = 'mail_relay_url';
  select value into v_relay_secret from app_config where key = 'mail_relay_secret';
  select value into v_owner_email from app_config where key = 'owner_email';
  select coalesce((select value from app_config where key = 'frontend_url'), 'https://gomsbox.github.io/lunchbuddy/') into v_frontend_url;
  if v_relay_url is null or v_relay_secret is null or v_owner_email is null then return; end if;

  for v_room in select * from rooms where notify_enabled = true and (last_notified_date is distinct from v_today) loop
    -- 오늘 요일에 맞는 컬럼만 확인 (0=일 1=월 2=화 3=수 4=목 5=금 6=토)
    v_today_on := case v_dow
      when 0 then v_room.notify_sun
      when 1 then v_room.notify_mon
      when 2 then v_room.notify_tue
      when 3 then v_room.notify_wed
      when 4 then v_room.notify_thu
      when 5 then v_room.notify_fri
      when 6 then v_room.notify_sat
    end;
    if not coalesce(v_today_on, false) then continue; end if;

    v_target_min := (split_part(v_room.notify_time, ':', 1))::int * 60 + (split_part(v_room.notify_time, ':', 2))::int;
    if v_now_min < v_target_min or v_now_min >= v_target_min + 60 then
      continue;
    end if;

    update rooms set last_notified_date = v_today where id = v_room.id;

    select array_agg(u.email) into v_recipients
      from members m join users u on u.id = m.user_id
      where m.room_id = v_room.id and u.email is not null;

    if v_recipients is null or array_length(v_recipients, 1) = 0 then continue; end if;

    perform net.http_post(
      url := v_relay_url,
      headers := jsonb_build_object('Content-Type', 'application/json'),
      body := jsonb_build_object(
        'secret', v_relay_secret,
        'to', v_owner_email,
        'bcc', to_jsonb(v_recipients),
        'subject', '🍱 [오늘점심] ' || v_room.name || ' 오늘 점심 같이 가요?',
        'html', '<div style="font-family:sans-serif;max-width:480px;margin:0 auto;">' ||
          '<h2>🍱 오늘 점심, 같이 가요?</h2>' ||
          '<p><b>' || v_room.name || '</b> 방의 오늘 점심 참여 여부를 응답해주세요.</p>' ||
          '<p><a href="' || v_frontend_url || '" target="_blank" style="display:inline-block;background:#22a45d;color:#fff;' ||
          'padding:12px 24px;border-radius:10px;text-decoration:none;font-weight:bold;">오늘점심 열기</a></p>' ||
          '<p style="color:#555;font-size:13px;">버튼이 안 열리면 아래 주소를 브라우저에 직접 붙여넣어 접속해주세요.</p>' ||
          '<p style="font-size:13px;"><a href="' || v_frontend_url || '">' || v_frontend_url || '</a></p></div>'
      )
    );
  end loop;
end;
$$;
