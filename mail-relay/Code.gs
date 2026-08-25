/************************************************************
 * 🍱 오늘점심 — 메일 릴레이 (Google Apps Script, 별도 신규 프로젝트)
 *
 * 왜 필요한가:
 *   Supabase 이전 후 메일을 Resend로 보내는데, 도메인 인증 없이 쓰는
 *   테스트 발신 주소(onboarding@resend.dev)는 Resend 계정 본인에게만
 *   발송 가능해서 팀원 수신자가 있으면 403으로 전부 거부됨.
 *   이 스크립트는 구 서비스처럼 본인 구글 계정(MailApp)으로 발송하는
 *   HTTP 릴레이 — 도메인 인증 없이 누구에게나 보낼 수 있음.
 *   (Gmail 개인 계정 기준 일일 수신자 100명 한도 — 점심방 규모엔 충분)
 *
 * ⚠️ 이 파일은 공개 저장소(GitHub)에 올라갑니다.
 *    비밀키와 수신자 이메일은 코드에 절대 쓰지 말고
 *    아래 "스크립트 속성"에만 넣으세요.
 *
 * 설치 방법 (기존 lunchbuddy-gas 프로젝트가 아닌 "새 프로젝트"로!):
 *   1) script.new 접속 → 이 파일 내용 전체 붙여넣기
 *   2) 왼쪽 ⚙ 프로젝트 설정 → 맨 아래 [스크립트 속성] → 속성 추가
 *      ┌──────────────────────┬────────────────────────────────────┐
 *      │ RELAY_SECRET         │ 아무 긴 무작위 문자열 (필수)        │
 *      │ RESIGNUP_RECIPIENTS  │ 수신자 이메일, 쉼표로 구분 (1회성)  │
 *      │ RESIGNUP_ROOM_CODE   │ 안내에 넣을 방 코드 (1회성)         │
 *      │ FRONTEND_URL         │ 생략 가능 (기본값이 이미 서비스 주소)│
 *      └──────────────────────┴────────────────────────────────────┘
 *      → 값을 넣은 뒤 checkSetup 함수를 실행하면 잘 들어갔는지 확인됩니다
 *   3) [재가입 메일 즉시 발송] 편집기에서 sendResignupNotice 선택 → 실행
 *      (최초 실행 시 권한 승인 필요. 배포 없이 바로 발송됨)
 *   4) [매일 알림 메일 연동] 배포 > 새 배포 > 웹 앱
 *      (실행: 나 / 액세스: 모든 사용자) → /exec URL 복사
 *   5) Supabase SQL Editor에서 supabase/05_mail_relay.sql 실행 후
 *      하단 안내대로 app_config에 mail_relay_url·mail_relay_secret 등록
 *      (mail_relay_secret은 위 RELAY_SECRET과 같은 값이어야 함)
 ************************************************************/

/** 스크립트 속성에서 설정값을 읽는다 (코드에 값을 직접 쓰지 않기 위함) */
function prop_(key, fallback) {
  const v = PropertiesService.getScriptProperties().getProperty(key);
  if (v === null || String(v).trim() === '') {
    return fallback === undefined ? '' : fallback;
  }
  return String(v).trim();
}

/** 쉼표로 구분된 속성값을 배열로 (빈 항목·공백 제거) */
function propList_(key) {
  return prop_(key)
    .split(',')
    .map(function (s) { return s.trim(); })
    .filter(function (s) { return s !== ''; });
}

/** 서비스 주소 — 공개 정보라 기본값을 그대로 둬도 됩니다 */
function frontendUrl_() {
  return prop_('FRONTEND_URL', 'https://gomsbox.github.io/lunchbuddy/');
}

/* ==================== 설정 점검 ====================
 * 편집기에서 이 함수를 선택하고 ▶실행 → 하단 [실행 로그]에 결과가 뜹니다.
 * (메일은 발송되지 않습니다)
 */
function checkSetup() {
  const secret = prop_('RELAY_SECRET');
  const recipients = propList_('RESIGNUP_RECIPIENTS');
  const roomCode = prop_('RESIGNUP_ROOM_CODE');

  const lines = [
    'RELAY_SECRET        : ' + (secret ? '설정됨 (' + secret.length + '자)' : '❌ 비어 있음 — 릴레이가 동작하지 않습니다'),
    'RESIGNUP_RECIPIENTS : ' + (recipients.length ? recipients.length + '명' : '(비어 있음 — 1회성 안내 메일을 안 보낼 거면 정상)'),
    'RESIGNUP_ROOM_CODE  : ' + (roomCode || '(비어 있음)'),
    'FRONTEND_URL        : ' + frontendUrl_(),
    '남은 일일 발송 한도  : ' + MailApp.getRemainingDailyQuota(),
  ];
  Logger.log(lines.join('\n'));
}

/* ==================== 1회성: 재가입 + 방 코드 안내 메일 ====================
 * 편집기에서 이 함수를 선택하고 ▶실행 하면 즉시 발송됩니다.
 * (supabase/04_resignup_notice_onetime.sql의 크론은 Resend 403으로 실패한 뒤
 *  스스로 등록 해제됐으므로, 이 함수가 그 발송을 대신합니다)
 *
 * 수신자와 방 코드는 스크립트 속성에서 읽습니다:
 *   RESIGNUP_RECIPIENTS = a@x.com, b@x.com, ...
 *   RESIGNUP_ROOM_CODE  = ABCDEF
 */
function sendResignupNotice() {
  const roomCode = prop_('RESIGNUP_ROOM_CODE');
  const recipients = propList_('RESIGNUP_RECIPIENTS');

  if (!recipients.length) {
    throw new Error('스크립트 속성 RESIGNUP_RECIPIENTS 가 비어 있습니다. 프로젝트 설정 > 스크립트 속성에서 수신자 이메일을 쉼표로 구분해 넣어주세요.');
  }
  if (!roomCode) {
    throw new Error('스크립트 속성 RESIGNUP_ROOM_CODE 가 비어 있습니다. 안내에 넣을 방 코드를 넣어주세요.');
  }

  const frontendUrl = frontendUrl_();

  MailApp.sendEmail({
    to: Session.getEffectiveUser().getEmail(),
    bcc: recipients.join(','),
    subject: '🍱 [오늘점심] 서비스 이전 안내 — 재가입 후 방 코드로 입장해주세요',
    name: '오늘점심',
    htmlBody:
      '<div style="font-family:sans-serif;max-width:480px;margin:0 auto;">' +
      '<h2>🍱 오늘점심으로 이전했어요!</h2>' +
      '<p>서비스를 더 빠른 시스템으로 옮기면서 <b>기존 계정 정보가 이전되지 않았습니다.</b> ' +
      '아래 순서로 다시 가입해주세요 (1분이면 충분해요):</p>' +
      '<ol style="line-height:1.8;">' +
      '<li>아래 버튼으로 접속</li>' +
      '<li>아이디 / 비밀번호로 <b>회원가입</b> (이메일도 등록하면 알림 메일을 받을 수 있어요)</li>' +
      '<li>방 목록 화면에서 <b>"🔑 방 코드로 참여"</b> 클릭 후 아래 코드 입력</li>' +
      '</ol>' +
      '<p style="text-align:center;margin:16px 0;">' +
      '<span style="display:inline-block;background:#eef7ef;color:#1b8a4d;font-size:22px;font-weight:800;' +
      'letter-spacing:3px;padding:10px 22px;border-radius:10px;">' + roomCode + '</span></p>' +
      '<p><a href="' + frontendUrl + '" target="_blank" style="display:inline-block;background:#22a45d;color:#fff;' +
      'padding:12px 24px;border-radius:10px;text-decoration:none;font-weight:bold;">오늘점심 열기</a></p>' +
      '<p style="color:#555;font-size:13px;">버튼이 안 열리면 아래 주소를 브라우저에 직접 붙여넣어 접속해주세요.</p>' +
      '<p style="font-size:13px;"><a href="' + frontendUrl + '">' + frontendUrl + '</a></p>' +
      '</div>',
  });
  Logger.log('재가입 안내 메일 발송 완료 (수신 ' + recipients.length + '명, 남은 일일 발송 한도:' + MailApp.getRemainingDailyQuota() + ')');
}

/* ==================== 상시: Supabase → 메일 릴레이 ====================
 * 요청: POST { secret, to, bcc: [..], subject, html }
 * 응답: { ok: true } | { ok: false, error }
 * 참고: Supabase(pg_net) 쪽 net._http_response에는 GAS 특성상 302가
 *       기록될 수 있음 — doPost는 이미 실행된 뒤의 리다이렉트라 정상.
 */
function doPost(e) {
  let res;
  try {
    const relaySecret = prop_('RELAY_SECRET');
    const req = JSON.parse(e.postData.contents);
    if (!relaySecret || req.secret !== relaySecret) {
      res = { ok: false, error: 'unauthorized' };
    } else {
      MailApp.sendEmail({
        to: String(req.to || Session.getEffectiveUser().getEmail()),
        bcc: (Array.isArray(req.bcc) ? req.bcc : []).join(','),
        subject: String(req.subject || '(제목 없음)'),
        htmlBody: String(req.html || ''),
        name: '오늘점심',
      });
      res = { ok: true, remainingQuota: MailApp.getRemainingDailyQuota() };
    }
  } catch (ex) {
    res = { ok: false, error: ex.message };
  }
  return ContentService.createTextOutput(JSON.stringify(res))
    .setMimeType(ContentService.MimeType.JSON);
}
