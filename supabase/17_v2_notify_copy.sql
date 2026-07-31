-- ============================================================
-- 🍱 오늘점심 v2 — 7단계: 알림 메일 문구 일반화 (REQ-16)
-- 08~16 실행 후 이 파일 전체를 SQL Editor에 붙여넣고 Run 하세요.
--
-- 알림 메일이 "점심"에만 맞춰진 문구였는데, v2에서 방 종류가 늘어나
-- 모임·회식·메뉴 투표 방에도 쓰이므로 중립 표현으로 바꾼다.
-- 발송 로직(요일별 판단·발송 창·1일 1회)은 06_notify_days.sql 그대로 유지한다.
-- ============================================================

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
  v_subject text;
  v_headline text;
  v_lead text;
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

    -- 마감된 이벤트형 방에는 알림을 보내지 않는다 (REQ-25)
    if v_room.purpose = 'event' and v_room.event_status = 'closed' then continue; end if;

    v_target_min := (split_part(v_room.notify_time, ':', 1))::int * 60 + (split_part(v_room.notify_time, ':', 2))::int;
    if v_now_min < v_target_min or v_now_min >= v_target_min + 60 then
      continue;
    end if;

    update rooms set last_notified_date = v_today where id = v_room.id;

    select array_agg(u.email) into v_recipients
      from members m join users u on u.id = m.user_id
      where m.room_id = v_room.id and u.email is not null;

    if v_recipients is null or array_length(v_recipients, 1) = 0 then continue; end if;

    -- 방 종류에 맞는 문구 (REQ-16 카피 일반화)
    if v_room.purpose = 'event' then
      v_subject  := '🎉 [오늘점심] ' || v_room.name || ' 참석 여부를 알려주세요';
      v_headline := '🎉 참석하시나요?';
      v_lead     := '<b>' || v_room.name || '</b> 모임의 참석 여부를 응답해주세요.';
    elsif v_room.enable_menu_poll then
      v_subject  := '🗳 [오늘점심] ' || v_room.name || ' 오늘 메뉴 투표해요';
      v_headline := '🗳 오늘 뭐 먹을까요?';
      v_lead     := '<b>' || v_room.name || '</b> 방의 참여 여부를 알려주고, 오늘 메뉴 투표에도 참여해주세요.';
    else
      v_subject  := '🍱 [오늘점심] ' || v_room.name || ' 오늘 같이 드실래요?';
      v_headline := '🍱 오늘 같이 드실래요?';
      v_lead     := '<b>' || v_room.name || '</b> 방의 오늘 참여 여부를 응답해주세요.';
    end if;

    perform net.http_post(
      url := v_relay_url,
      headers := jsonb_build_object('Content-Type', 'application/json'),
      body := jsonb_build_object(
        'secret', v_relay_secret,
        'to', v_owner_email,
        'bcc', to_jsonb(v_recipients),
        'subject', v_subject,
        'html', '<div style="font-family:sans-serif;max-width:480px;margin:0 auto;">' ||
          '<h2>' || v_headline || '</h2>' ||
          '<p>' || v_lead || '</p>' ||
          '<p><a href="' || v_frontend_url || '" target="_blank" style="display:inline-block;background:#22a45d;color:#fff;' ||
          'padding:12px 24px;border-radius:10px;text-decoration:none;font-weight:bold;">오늘점심 열기</a></p>' ||
          '<p style="color:#555;font-size:13px;">버튼이 안 열리면 아래 주소를 브라우저에 직접 붙여넣어 접속해주세요.</p>' ||
          '<p style="font-size:13px;"><a href="' || v_frontend_url || '">' || v_frontend_url || '</a></p></div>'
      )
    );
  end loop;
end;
$$;

-- 크론 전용 함수 — 외부에 열지 않는다 (12_v2_grants_fix.sql 방침)
revoke execute on function fn_send_notifications() from public;
revoke execute on function fn_send_notifications() from anon, authenticated;

-- ============================================================
-- 실행 후 확인 — 크론은 06에서 등록한 lunchbuddy-notify가 그대로 이 함수를 호출한다
--   select jobname, schedule, command from cron.job where jobname like 'lunchbuddy%' order by jobname;
-- ============================================================
