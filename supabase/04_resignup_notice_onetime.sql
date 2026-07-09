-- ============================================================
-- 🍱 오늘점심 — 재가입 + 방 코드 안내 메일 (1회성, 2026-07-10 08:30 KST 발송)
-- SQL Editor에서 이 파일 전체를 한 번만 실행하세요.
-- 발송 후에는 함수가 스스로 크론 등록을 해제합니다 (다음 해 같은 시각 재발송 방지).
-- ============================================================

create or replace function fn_send_resignup_notice() returns void
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_api_key text;
  v_owner_email text := 'yujeong.chae@daekyo.co.kr';
  v_frontend_url text := coalesce((select value from app_config where key = 'frontend_url'), 'https://gomsbox.github.io/lunchbuddy/');
  v_room_code text := 'RVUJVJ';
  v_recipients text[] := array[
    'yujeong.chae@daekyo.co.kr',
    'eunju.kim@daekyo.co.kr',
    'hyowon_lim@daekyo.co.kr',
    'jikyung_yoo@daekyo.co.kr',
    'eunbi.kim@daekyo.co.kr'
  ];
begin
  select value into v_api_key from app_config where key = 'resend_api_key';

  if v_api_key is not null then
    perform net.http_post(
      url := 'https://api.resend.com/emails',
      headers := jsonb_build_object('Authorization', 'Bearer ' || v_api_key, 'Content-Type', 'application/json'),
      body := jsonb_build_object(
        'from', '오늘점심 <onboarding@resend.dev>',
        'to', jsonb_build_array(v_owner_email),
        'bcc', to_jsonb(v_recipients),
        'subject', '🍱 [오늘점심] 서비스 이전 안내 — 재가입 후 방 코드로 입장해주세요',
        'html', '<div style="font-family:sans-serif;max-width:480px;margin:0 auto;">' ||
          '<h2>🍱 오늘점심으로 이전했어요!</h2>' ||
          '<p>서비스를 더 빠른 시스템으로 옮기면서 <b>기존 계정 정보가 이전되지 않았습니다.</b> ' ||
          '아래 순서로 다시 가입해주세요 (1분이면 충분해요):</p>' ||
          '<ol style="line-height:1.8;">' ||
          '<li>아래 버튼으로 접속</li>' ||
          '<li>아이디 / 비밀번호로 <b>회원가입</b> (이메일도 등록하면 알림 메일을 받을 수 있어요)</li>' ||
          '<li>방 목록 화면에서 <b>"🔑 방 코드로 참여"</b> 클릭 후 아래 코드 입력</li>' ||
          '</ol>' ||
          '<p style="text-align:center;margin:16px 0;">' ||
          '<span style="display:inline-block;background:#eef7ef;color:#1b8a4d;font-size:22px;font-weight:800;' ||
          'letter-spacing:3px;padding:10px 22px;border-radius:10px;">' || v_room_code || '</span></p>' ||
          '<p><a href="' || v_frontend_url || '" target="_blank" style="display:inline-block;background:#22a45d;color:#fff;' ||
          'padding:12px 24px;border-radius:10px;text-decoration:none;font-weight:bold;">오늘점심 열기</a></p>' ||
          '<p style="color:#555;font-size:13px;">버튼이 안 열리면 아래 주소를 브라우저에 직접 붙여넣어 접속해주세요.</p>' ||
          '<p style="font-size:13px;"><a href="' || v_frontend_url || '">' || v_frontend_url || '</a></p>' ||
          '</div>'
      )
    );
  end if;

  -- 1회성 발송이므로 실행 후 스스로 크론 등록 해제 (다음 해 같은 날짜 재발송 방지)
  perform cron.unschedule('today-lunch-resignup-notice');
end;
$$;

do $$ begin perform cron.unschedule('today-lunch-resignup-notice'); exception when others then null; end $$;

-- 2026-07-09 23:30 UTC = 2026-07-10 08:30 KST (1회만 발송)
select cron.schedule('today-lunch-resignup-notice', '30 23 9 7 *', 'select fn_send_resignup_notice();');
