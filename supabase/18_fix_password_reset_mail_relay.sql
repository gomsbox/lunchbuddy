-- ============================================================
-- 🍱 오늘점심 — 비밀번호 찾기(REQ-15) 메일이 안 오던 문제 수정
--
-- 원인: 05_mail_relay.sql에서 "알림 메일"(fn_send_notifications)만
--   Resend → 앱스크립트 메일 릴레이로 옮겼고, 02_functions.sql의
--   api_request_password_reset()은 옮겨지지 않은 채 예전 Resend 직접
--   호출(onboarding@resend.dev, 도메인 미인증)로 남아 있었음.
--   Resend는 그 발신 주소로는 계정 소유자 본인 메일함 외에는 403으로
--   거부하는데, perform net.http_post(...)는 응답을 확인하지 않으므로
--   실패해도 조용히 무시되고 화면에는 "보냈습니다" 메시지만 나옴.
--
-- 조치: fn_send_notifications과 동일하게 mail_relay_url/secret을 쓰도록
--   교체. resend_api_key/app_config 값은 그대로 둬도 무방(더 이상 안 씀).
--
-- 실행 순서: 이 파일 전체를 Supabase SQL Editor에서 Run
--   (사전 조건: app_config에 mail_relay_url, mail_relay_secret, owner_email
--    이미 등록돼 있어야 함 — 알림 메일이 정상 발송 중이면 이미 돼 있는 상태)
-- ============================================================

create or replace function api_request_password_reset(p_login_id text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_user record;
  v_reset_token uuid;
  v_relay_url text;
  v_relay_secret text;
  v_owner_email text;
  v_frontend_url text := coalesce((select value from app_config where key = 'frontend_url'), 'https://gomsbox.github.io/lunchbuddy/');
begin
  select * into v_user from users where login_id = lower(trim(coalesce(p_login_id, '')));
  -- 계정 존재 여부를 노출하지 않기 위해 항상 동일한 성공 메시지 반환
  if v_user.id is not null and v_user.email is not null then
    insert into password_resets (user_id, expires_at) values (v_user.id, now() + interval '30 minutes')
    returning token into v_reset_token;

    select value into v_relay_url from app_config where key = 'mail_relay_url';
    select value into v_relay_secret from app_config where key = 'mail_relay_secret';
    select value into v_owner_email from app_config where key = 'owner_email';

    if v_relay_url is not null and v_relay_secret is not null and v_owner_email is not null then
      perform net.http_post(
        url := v_relay_url,
        headers := jsonb_build_object('Content-Type', 'application/json'),
        body := jsonb_build_object(
          'secret', v_relay_secret,
          'to', v_owner_email,
          'bcc', to_jsonb(array[v_user.email]),
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

-- ============================================================
-- 실행 후 확인
-- ============================================================
-- 1) 릴레이 설정이 비어 있지 않은지 먼저 확인 (비어 있으면 위 함수가 조용히 아무것도 안 보냄)
--    select key, case when key='mail_relay_secret' then '(비밀값)' else value end as value
--    from app_config where key in ('mail_relay_url','mail_relay_secret','owner_email');
--
-- 2) 실제로 이메일 등록된 계정의 login_id로 아래를 실행해 재설정 메일이 오는지 확인
--    select api_request_password_reset('여기에_이메일등록된_아이디');
--    (성공 메시지는 항상 같게 나오므로, 진짜 확인은 메일함 도착 여부로 해야 함)
