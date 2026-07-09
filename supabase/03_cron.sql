-- ============================================================
-- 🍱 오늘점심 — Supabase 스키마 (3/3: 자정 초기화 + 알림 발송 크론)
-- 01, 02 실행 후 이 파일을 SQL Editor에 붙여넣고 Run 하세요.
-- ============================================================

-- ---------- 매일 자정 초기화 (REQ-07) ----------
create or replace function fn_daily_reset() returns void
language plpgsql security definer set search_path = public as $$
declare
  v_today date := fn_today();
  v_cutoff date := v_today - interval '29 days';
begin
  -- 1) 과거 응답 → History 집계 후 삭제 (당일 데이터는 그대로 유지)
  -- nickname은 응답 시점 스냅샷(responses.nickname) — 강퇴/탈퇴된 멤버도 히스토리에 정확히 남음
  insert into history (date, room_id, going_names, not_going_names)
  select r.date, r.room_id,
    coalesce(string_agg(coalesce(r.nickname, '(알수없음)'), ',') filter (where r.status = 'going'), ''),
    coalesce(string_agg(coalesce(r.nickname, '(알수없음)'), ',') filter (where r.status = 'not-going'), '')
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

-- ---------- 이메일 알림 발송 확인 (REQ-14, 5분마다 실행) ----------
create or replace function fn_send_notifications() returns void
language plpgsql security definer set search_path = public as $$
declare
  v_now_seoul timestamp := now() at time zone 'Asia/Seoul';
  v_dow int := extract(dow from v_now_seoul)::int;   -- 0=일요일, 6=토요일
  v_now_min int := extract(hour from v_now_seoul)::int * 60 + extract(minute from v_now_seoul)::int;
  v_today date := v_now_seoul::date;
  v_api_key text;
  v_owner_email text;
  v_frontend_url text;
  v_room record;
  v_target_min int;
  v_recipients text[];
  v_is_weekend boolean := (v_dow = 0 or v_dow = 6);
begin
  select value into v_api_key from app_config where key = 'resend_api_key';
  select value into v_owner_email from app_config where key = 'owner_email';
  select coalesce((select value from app_config where key = 'frontend_url'), 'https://gomsbox.github.io/lunchbuddy/') into v_frontend_url;
  if v_api_key is null or v_owner_email is null then return; end if; -- 설정 전이면 조용히 종료

  for v_room in select * from rooms where notify_enabled = true and (last_notified_date is distinct from v_today) loop
    -- 방별 평일/주말 다중 선택: 둘 다 켜면 매일, 평일만 켜면 월~금, 주말만 켜면 토~일
    if v_is_weekend and not v_room.notify_weekend then continue; end if;
    if not v_is_weekend and not v_room.notify_weekday then continue; end if;

    v_target_min := (split_part(v_room.notify_time, ':', 1))::int * 60 + (split_part(v_room.notify_time, ':', 2))::int;
    if v_now_min < v_target_min or v_now_min >= v_target_min + 60 then
      continue; -- 발송 창(시각~+60분) 밖
    end if;

    -- 발송 성공 여부와 무관하게 오늘 처리한 것으로 먼저 기록 (5분마다 재시도되는 것 방지)
    update rooms set last_notified_date = v_today where id = v_room.id;

    select array_agg(u.email) into v_recipients
      from members m join users u on u.id = m.user_id
      where m.room_id = v_room.id and u.email is not null;

    if v_recipients is null or array_length(v_recipients, 1) = 0 then continue; end if;

    perform net.http_post(
      url := 'https://api.resend.com/emails',
      headers := jsonb_build_object('Authorization', 'Bearer ' || v_api_key, 'Content-Type', 'application/json'),
      body := jsonb_build_object(
        'from', '오늘점심 <onboarding@resend.dev>',
        'to', jsonb_build_array(v_owner_email),
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

-- ---------- 크론 등록 (재실행해도 안전하도록 기존 잡 제거 후 재등록) ----------
do $$ begin perform cron.unschedule('lunchbuddy-daily-reset'); exception when others then null; end $$;
do $$ begin perform cron.unschedule('lunchbuddy-notify'); exception when others then null; end $$;

-- 서버 시간은 UTC 기준 → 서울 00:00 = UTC 전날 15:00
select cron.schedule('lunchbuddy-daily-reset', '0 15 * * *', 'select fn_daily_reset();');
-- 5분마다 알림 발송 대상 확인
select cron.schedule('lunchbuddy-notify', '*/5 * * * *', 'select fn_send_notifications();');

-- ============================================================
-- ⚠️ 아래 3줄은 반드시 본인 값으로 바꿔서 별도로 실행하세요 (비밀 값이라 이 파일엔 실제 값을 넣지 않았습니다)
-- ============================================================
-- insert into app_config (key, value) values ('resend_api_key', '여기에_Resend_API_키') on conflict (key) do update set value = excluded.value;
-- insert into app_config (key, value) values ('owner_email', 'yujeong.dk@gmail.com') on conflict (key) do update set value = excluded.value;  -- 메일 발신 to에 표시될 본인 계정
-- insert into app_config (key, value) values ('frontend_url', 'https://gomsbox.github.io/lunchbuddy/') on conflict (key) do update set value = excluded.value;
