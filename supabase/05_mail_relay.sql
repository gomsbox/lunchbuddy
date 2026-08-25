-- ============================================================
-- 🍱 오늘점심 — 메일 발송 경로 교체: Resend → 앱스크립트 메일 릴레이
--
-- 배경: 도메인 인증 없이 쓰는 Resend 테스트 발신 주소(onboarding@resend.dev)는
--   Resend 계정 본인 주소로만 발송 가능 → 팀원 bcc가 있으면 403으로 전부 거부됨
--   (2026-07-10 재가입 안내 메일 미발송 사고의 원인).
--   구 서비스처럼 구글 계정(MailApp)으로 발송하는 릴레이(mail-relay/Code.gs)로 교체.
--
-- 실행 순서:
--   1) mail-relay/Code.gs를 새 앱스크립트 프로젝트로 배포하고 /exec URL 확보
--   2) 이 파일 전체를 SQL Editor에서 실행
--   3) 맨 아래 안내대로 app_config에 mail_relay_url / mail_relay_secret 등록
-- ============================================================

-- ---------- 이메일 알림 발송 확인 (REQ-14, 5분마다 실행) — 릴레이 발송 버전 ----------
create or replace function fn_send_notifications() returns void
language plpgsql security definer set search_path = public as $$
declare
  v_now_seoul timestamp := now() at time zone 'Asia/Seoul';
  v_dow int := extract(dow from v_now_seoul)::int;   -- 0=일요일, 6=토요일
  v_now_min int := extract(hour from v_now_seoul)::int * 60 + extract(minute from v_now_seoul)::int;
  v_today date := v_now_seoul::date;
  v_relay_url text;
  v_relay_secret text;
  v_owner_email text;
  v_frontend_url text;
  v_room record;
  v_target_min int;
  v_recipients text[];
  v_is_weekend boolean := (v_dow = 0 or v_dow = 6);
begin
  select value into v_relay_url from app_config where key = 'mail_relay_url';
  select value into v_relay_secret from app_config where key = 'mail_relay_secret';
  select value into v_owner_email from app_config where key = 'owner_email';
  select coalesce((select value from app_config where key = 'frontend_url'), 'https://gomsbox.github.io/lunchbuddy/') into v_frontend_url;
  if v_relay_url is null or v_relay_secret is null or v_owner_email is null then return; end if; -- 설정 전이면 조용히 종료

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

    -- 앱스크립트 릴레이가 구글 계정(MailApp)으로 대신 발송
    -- (net._http_response에 302가 남을 수 있음 — 앱스크립트 특성상 정상)
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

-- ---------- 1회성 재가입 안내 정리 ----------
-- 크론은 발송 시도(403 실패) 후 스스로 해제됐지만, 남아 있어도 안전하도록 한 번 더 정리.
-- 재발송은 mail-relay/Code.gs의 sendResignupNotice()를 앱스크립트 편집기에서 실행.
do $$ begin perform cron.unschedule('today-lunch-resignup-notice'); exception when others then null; end $$;
drop function if exists fn_send_resignup_notice();

-- ============================================================
-- ⚠️ 아래 2줄은 반드시 본인 값으로 바꿔서 별도로 실행하세요
--    (mail_relay_secret은 mail-relay/Code.gs의 RELAY_SECRET과 동일해야 함)
-- ============================================================
-- insert into app_config (key, value) values ('mail_relay_url', 'https://script.google.com/macros/s/여기에_배포ID/exec') on conflict (key) do update set value = excluded.value;
-- insert into app_config (key, value) values ('mail_relay_secret', '여기에_긴_무작위_문자열') on conflict (key) do update set value = excluded.value;
