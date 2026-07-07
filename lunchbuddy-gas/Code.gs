/************************************************************
 * 🍱 런치버디 (LunchBuddy) — 백엔드 (JSON API)
 * 요구사항 명세서 v1.3 기준 / Google Apps Script (컨테이너 바인딩)
 *
 * 구조: 프론트엔드는 GitHub Pages(docs/index.html)에서 서빙,
 *       이 스크립트는 fetch(POST)로 호출되는 JSON API 서버.
 *
 * 사용법:
 *  1) 구글 시트 생성 → 확장 프로그램 > Apps Script
 *  2) 이 파일(Code.gs) 붙여넣기 (HTML 파일 불필요)
 *  3) setup() 1회 실행 (시트 생성 + 자정 트리거 등록)
 *  4) 배포 > 새 배포 > 웹 앱 (실행: 나 / 액세스: 모든 사용자)
 *  5) 발급된 /exec URL을 docs/index.html의 API_URL에 입력
 ************************************************************/

/** 프론트엔드(GitHub Pages) 주소 — 초대 링크가 이 주소로 생성됨 */
const FRONTEND_URL = 'https://gomsbox.github.io/lunchbuddy/';

const SHEETS = {
  Users:     ['userId', 'loginId', 'passwordHash', 'salt', 'nickname', 'createdAt'],
  Sessions:  ['token', 'userId', 'expiresAt'],
  Rooms:     ['roomId', 'roomName', 'hostUserId', 'inviteToken', 'inviteExpiresAt', 'createdAt', 'roomCode'],
  Members:   ['roomId', 'userId', 'role', 'joinedAt'],
  Responses: ['date', 'roomId', 'userId', 'status', 'updatedAt'],
  History:   ['date', 'roomId', 'goingNames', 'notGoingNames'],
  Messages:  ['messageId', 'roomId', 'userId', 'text', 'sentAt'],
};

const SESSION_DAYS = 30;      // REQ-02 세션 유효기간
const INVITE_DAYS = 7;        // REQ-04 초대 링크 만료
const RETENTION_DAYS = 30;    // NFR-06 히스토리·채팅 보관 기간
const CHAT_FETCH_LIMIT = 100; // REQ-13 채팅 조회 범위

/* ==================== 초기 설정 ==================== */

/** 최초 1회 실행: 시트 탭 생성 + 자정 트리거 등록 (재실행해도 안전 — 열 추가 시 마이그레이션 포함) */
function setup() {
  const ss = SpreadsheetApp.getActiveSpreadsheet();
  Object.keys(SHEETS).forEach(function (name) {
    let sh = ss.getSheetByName(name);
    if (!sh) sh = ss.insertSheet(name);
    // 헤더 행을 항상 최신 스키마로 갱신 (새 열 추가 반영)
    sh.getRange(1, 1, 1, SHEETS[name].length).setValues([SHEETS[name]]);
    // 날짜 자동 변환 방지: 전체 열을 일반 텍스트로 고정
    sh.getRange(1, 1, sh.getMaxRows(), SHEETS[name].length).setNumberFormat('@');
    sh.setFrozenRows(1);
  });
  // 마이그레이션: 방 코드가 없는 기존 방에 코드 발급
  rows_('Rooms').forEach(function (r, i) {
    if (!String(r[6])) sheet_('Rooms').getRange(i + 2, 7).setValue(newRoomCode_());
  });
  // 기본 'Sheet1(시트1)' 정리
  const first = ss.getSheets()[0];
  if (first && !SHEETS[first.getName()] && ss.getSheets().length > Object.keys(SHEETS).length) {
    ss.deleteSheet(first);
  }
  // 자정 트리거 재등록 (REQ-07)
  ScriptApp.getProjectTriggers().forEach(function (t) {
    if (t.getHandlerFunction() === 'dailyReset') ScriptApp.deleteTrigger(t);
  });
  ScriptApp.newTrigger('dailyReset').timeBased().everyDays(1).atHour(0).create();
  Logger.log('설정 완료: 시트 7개 + 자정 트리거 등록됨');
}

/* ==================== 웹앱 진입점 (JSON API) ==================== */

/** exec URL로 직접 접속한 경우 프론트엔드로 안내 */
function doGet() {
  return HtmlService.createHtmlOutput(
    '<div style="font-family:sans-serif; text-align:center; padding:60px 20px;">' +
    '<h2>🍱 런치버디</h2><p>서비스 주소로 이동해주세요.</p>' +
    '<p><a href="' + FRONTEND_URL + '" target="_top" rel="noopener">' + FRONTEND_URL + '</a></p></div>'
  ).setTitle('런치버디 🍱');
}

/**
 * JSON API 라우터 — 프론트엔드가 fetch(POST, text/plain)로 호출
 * 요청: { fn: 'api_함수명', args: [인자...] } / 응답: { ok, data | error }
 */
function doPost(e) {
  let res;
  try {
    const API = {
      api_signup: api_signup, api_login: api_login, api_logout: api_logout, api_getMe: api_getMe,
      api_getMyRooms: api_getMyRooms, api_createRoom: api_createRoom,
      api_joinByInvite: api_joinByInvite, api_joinByCode: api_joinByCode,
      api_getRoomToday: api_getRoomToday, api_setResponse: api_setResponse,
      api_getMessages: api_getMessages, api_sendMessage: api_sendMessage,
      api_getHistory: api_getHistory,
      api_updateNickname: api_updateNickname, api_changePassword: api_changePassword,
      api_getMembers: api_getMembers, api_renameRoom: api_renameRoom,
      api_regenerateInvite: api_regenerateInvite, api_setRole: api_setRole,
      api_kickMember: api_kickMember, api_deleteRoom: api_deleteRoom,
    };
    const req = JSON.parse(e.postData.contents);
    const fn = String(req.fn || '');
    const args = Array.isArray(req.args) ? req.args : [];
    res = API[fn] ? API[fn].apply(null, args) : err_('알 수 없는 요청입니다: ' + fn);
  } catch (ex) {
    res = err_('요청 처리에 실패했습니다: ' + ex.message);
  }
  return ContentService.createTextOutput(JSON.stringify(res))
    .setMimeType(ContentService.MimeType.JSON);
}

/* ==================== 공통 헬퍼 ==================== */

function sheet_(name) { return SpreadsheetApp.getActiveSpreadsheet().getSheetByName(name); }

function rows_(name) {
  const sh = sheet_(name);
  const lr = sh.getLastRow();
  if (lr < 2) return [];
  return sh.getRange(2, 1, lr - 1, SHEETS[name].length).getValues();
}

function tz_() { return Session.getScriptTimeZone() || 'Asia/Seoul'; }
function todayStr_() { return Utilities.formatDate(new Date(), tz_(), 'yyyy-MM-dd'); }
function nowIso_() { return Utilities.formatDate(new Date(), tz_(), "yyyy-MM-dd'T'HH:mm:ss"); }
function uuid_() { return Utilities.getUuid(); }

function addDaysIso_(days) {
  return Utilities.formatDate(new Date(Date.now() + days * 86400000), tz_(), "yyyy-MM-dd'T'HH:mm:ss");
}
function addDaysDateStr_(days) {
  return Utilities.formatDate(new Date(Date.now() + days * 86400000), tz_(), 'yyyy-MM-dd');
}

/** 셀 값을 'yyyy-MM-dd' 문자열로 정규화 (Date 자동 변환 방어) */
function dateStr_(v) {
  return (v instanceof Date) ? Utilities.formatDate(v, tz_(), 'yyyy-MM-dd') : String(v).slice(0, 10);
}

/** 솔트 + SHA-256 해시 (REQ-01) */
function hash_(password, salt) {
  const bytes = Utilities.computeDigest(Utilities.DigestAlgorithm.SHA_256, String(salt) + String(password), Utilities.Charset.UTF_8);
  return bytes.map(function (b) { return ('0' + ((b + 256) % 256).toString(16)).slice(-2); }).join('');
}

/** 시트 쓰기 작업 잠금 (NFR-02) */
function withLock_(fn) {
  const lock = LockService.getScriptLock();
  lock.waitLock(10000);
  try { return fn(); } finally { lock.releaseLock(); }
}

function ok_(data) { return { ok: true, data: data === undefined ? null : data }; }
function err_(msg) { return { ok: false, error: msg }; }

/** userId → nickname 맵 */
function nickMap_() {
  const map = {};
  rows_('Users').forEach(function (r) { map[String(r[0])] = String(r[4]); });
  return map;
}

/** 조건에 맞는 행 삭제 (아래에서 위로) */
function deleteRowsWhere_(name, predicate) {
  const sh = sheet_(name);
  const lr = sh.getLastRow();
  if (lr < 2) return 0;
  const data = sh.getRange(2, 1, lr - 1, SHEETS[name].length).getValues();
  let n = 0;
  for (let i = data.length - 1; i >= 0; i--) {
    if (predicate(data[i])) { sh.deleteRow(i + 2); n++; }
  }
  return n;
}

/** 조건에 맞는 첫 행의 시트 행 번호 (없으면 -1) */
function findRowIndex_(name, predicate) {
  const data = rows_(name);
  for (let i = 0; i < data.length; i++) {
    if (predicate(data[i])) return i + 2;
  }
  return -1;
}

function findRoom_(roomId) {
  const r = rows_('Rooms').find(function (x) { return String(x[0]) === String(roomId); });
  if (!r) return null;
  return {
    roomId: String(r[0]), roomName: String(r[1]), hostUserId: String(r[2]),
    inviteToken: String(r[3]), inviteExpiresAt: String(r[4]), createdAt: String(r[5]),
    roomCode: String(r[6]),
  };
}

/** 영구 방 코드 생성 — 6자리, 혼동 문자(I/L/O/0/1) 제외, 유니크 보장 (REQ-04) */
function newRoomCode_() {
  const chars = 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';
  const existing = {};
  rows_('Rooms').forEach(function (r) { existing[String(r[6])] = true; });
  for (var attempt = 0; attempt < 20; attempt++) {
    var code = '';
    for (var i = 0; i < 6; i++) code += chars.charAt(Math.floor(Math.random() * chars.length));
    if (!existing[code]) return code;
  }
  throw new Error('방 코드 생성에 실패했습니다.');
}

function memberRole_(roomId, userId) {
  const m = rows_('Members').find(function (r) {
    return String(r[0]) === String(roomId) && String(r[1]) === String(userId);
  });
  return m ? String(m[2]) : null;
}

/* ==================== REQ-01·02 회원가입 / 로그인 / 세션 ==================== */

function createSession_(userId) {
  const token = uuid_();
  sheet_('Sessions').appendRow([token, userId, addDaysIso_(SESSION_DAYS)]);
  return token;
}

/** 세션 토큰 검증 → 사용자 반환 (실패 시 null) */
function auth_(token) {
  if (!token) return null;
  const s = rows_('Sessions').find(function (r) { return String(r[0]) === String(token); });
  if (!s) return null;
  if (new Date(String(s[2])) < new Date()) return null;
  const u = rows_('Users').find(function (r) { return String(r[0]) === String(s[1]); });
  if (!u) return null;
  return { userId: String(u[0]), loginId: String(u[1]), nickname: String(u[4]) };
}

function api_signup(loginId, password) {
  try {
    loginId = String(loginId || '').trim().toLowerCase();
    if (!/^[a-z0-9]{4,20}$/.test(loginId)) return err_('아이디는 4~20자의 영문 소문자와 숫자만 사용할 수 있습니다.');
    if (!/^(?=.*[A-Za-z])(?=.*[0-9]).{8,}$/.test(String(password || ''))) return err_('비밀번호는 8자 이상이며 영문과 숫자를 모두 포함해야 합니다.');
    return withLock_(function () {
      const dup = rows_('Users').some(function (r) { return String(r[1]).toLowerCase() === loginId; });
      if (dup) return err_('이미 사용 중인 아이디입니다.');
      const userId = uuid_();
      const salt = uuid_();
      // 닉네임 기본값 = 아이디 (REQ-01)
      sheet_('Users').appendRow([userId, loginId, hash_(password, salt), salt, loginId, nowIso_()]);
      const token = createSession_(userId);
      return ok_({ token: token, user: { userId: userId, loginId: loginId, nickname: loginId } });
    });
  } catch (e) { return err_('처리 중 오류가 발생했습니다: ' + e.message); }
}

function api_login(loginId, password) {
  try {
    loginId = String(loginId || '').trim().toLowerCase();
    const cache = CacheService.getScriptCache();
    if (cache.get('block_' + loginId)) return err_('로그인 5회 실패로 10분간 차단되었습니다. 잠시 후 다시 시도해주세요.');

    const u = rows_('Users').find(function (r) { return String(r[1]).toLowerCase() === loginId; });
    const failed = function () {
      const n = Number(cache.get('fail_' + loginId) || 0) + 1;
      if (n >= 5) {
        cache.put('block_' + loginId, '1', 600); // 10분 차단 (REQ-02)
        cache.remove('fail_' + loginId);
        return err_('아이디 또는 비밀번호가 올바르지 않습니다. 5회 실패로 10분간 차단됩니다.');
      }
      cache.put('fail_' + loginId, String(n), 600);
      return err_('아이디 또는 비밀번호가 올바르지 않습니다. (' + n + '/5회)');
    };
    if (!u) return failed();
    if (hash_(password, String(u[3])) !== String(u[2])) return failed();

    cache.remove('fail_' + loginId);
    const token = createSession_(String(u[0]));
    return ok_({ token: token, user: { userId: String(u[0]), loginId: loginId, nickname: String(u[4]) } });
  } catch (e) { return err_('처리 중 오류가 발생했습니다: ' + e.message); }
}

function api_logout(token) {
  try {
    withLock_(function () {
      deleteRowsWhere_('Sessions', function (r) { return String(r[0]) === String(token); });
    });
    return ok_();
  } catch (e) { return err_('처리 중 오류가 발생했습니다: ' + e.message); }
}

function api_getMe(token) {
  const me = auth_(token);
  if (!me) return err_('AUTH');
  return ok_({ user: me });
}

/* ==================== REQ-03·04 방 생성 / 초대 ==================== */

function api_getMyRooms(token) {
  try {
    const me = auth_(token);
    if (!me) return err_('AUTH');
    const memberships = rows_('Members').filter(function (r) { return String(r[1]) === me.userId; });
    const rooms = rows_('Rooms');
    const allMembers = rows_('Members');
    const today = todayStr_();
    const goingToday = rows_('Responses').filter(function (r) {
      return dateStr_(r[0]) === today && String(r[3]) === 'going';
    });
    const list = [];
    memberships.forEach(function (m) {
      const roomId = String(m[0]);
      const room = rooms.find(function (r) { return String(r[0]) === roomId; });
      if (!room) return;
      list.push({
        roomId: roomId,
        roomName: String(room[1]),
        role: String(m[2]),
        goingCount: goingToday.filter(function (r) { return String(r[1]) === roomId; }).length,
        memberCount: allMembers.filter(function (r) { return String(r[0]) === roomId; }).length,
      });
    });
    return ok_({
      hostRooms: list.filter(function (r) { return r.role === 'host'; }),
      otherRooms: list.filter(function (r) { return r.role !== 'host'; }),
    });
  } catch (e) { return err_('처리 중 오류가 발생했습니다: ' + e.message); }
}

function api_createRoom(token, roomName) {
  try {
    const me = auth_(token);
    if (!me) return err_('AUTH');
    roomName = String(roomName || '').trim();
    if (roomName.length < 2 || roomName.length > 20) return err_('방 이름은 2~20자로 입력해주세요.');
    return withLock_(function () {
      const roomId = uuid_();
      sheet_('Rooms').appendRow([roomId, roomName, me.userId, uuid_(), addDaysIso_(INVITE_DAYS), nowIso_(), newRoomCode_()]);
      sheet_('Members').appendRow([roomId, me.userId, 'host', nowIso_()]);
      return ok_({ roomId: roomId });
    });
  } catch (e) { return err_('처리 중 오류가 발생했습니다: ' + e.message); }
}

function api_joinByInvite(token, inviteToken) {
  try {
    const me = auth_(token);
    if (!me) return err_('AUTH');
    const room = rows_('Rooms').find(function (r) { return String(r[3]) === String(inviteToken); });
    if (!room) return err_('EXPIRED'); // 재생성으로 무효화된 링크 포함
    if (new Date(String(room[4])) < new Date()) return err_('EXPIRED'); // 7일 만료 (REQ-04)
    const roomId = String(room[0]);
    if (memberRole_(roomId, me.userId)) return ok_({ roomId: roomId, already: true });
    return withLock_(function () {
      if (!memberRole_(roomId, me.userId)) {
        sheet_('Members').appendRow([roomId, me.userId, 'member', nowIso_()]);
      }
      return ok_({ roomId: roomId, already: false });
    });
  } catch (e) { return err_('처리 중 오류가 발생했습니다: ' + e.message); }
}

/** 방 코드로 참여 — 만료 없음 (REQ-04 방법 2) */
function api_joinByCode(token, code) {
  try {
    const me = auth_(token);
    if (!me) return err_('AUTH');
    code = String(code || '').trim().toUpperCase();
    if (!/^[A-Z0-9]{6}$/.test(code)) return err_('방 코드는 6자리 영문·숫자입니다.');
    const room = rows_('Rooms').find(function (r) { return String(r[6]) === code; });
    if (!room) return err_('일치하는 방이 없습니다. 코드를 다시 확인해주세요.');
    const roomId = String(room[0]);
    if (memberRole_(roomId, me.userId)) return ok_({ roomId: roomId, already: true });
    return withLock_(function () {
      if (!memberRole_(roomId, me.userId)) {
        sheet_('Members').appendRow([roomId, me.userId, 'member', nowIso_()]);
      }
      return ok_({ roomId: roomId, already: false });
    });
  } catch (e) { return err_('처리 중 오류가 발생했습니다: ' + e.message); }
}

/* ==================== REQ-05·06 참여 등록 / 현황 ==================== */

function api_getRoomToday(token, roomId) {
  try {
    const me = auth_(token);
    if (!me) return err_('AUTH');
    const role = memberRole_(roomId, me.userId);
    if (!role) return err_('NOT_MEMBER');
    const room = findRoom_(roomId);
    if (!room) return err_('방을 찾을 수 없습니다.');

    const nicks = nickMap_();
    const members = rows_('Members').filter(function (r) { return String(r[0]) === String(roomId); });
    const today = todayStr_();
    const statusMap = {};
    rows_('Responses').forEach(function (r) {
      if (dateStr_(r[0]) === today && String(r[1]) === String(roomId)) {
        statusMap[String(r[2])] = String(r[3]);
      }
    });

    const going = [], notGoing = [], noResponse = [];
    members.forEach(function (m) {
      const uid = String(m[1]);
      const item = { userId: uid, nickname: nicks[uid] || '(탈퇴)' };
      const st = statusMap[uid];
      if (st === 'going') going.push(item);
      else if (st === 'not-going') notGoing.push(item);
      else noResponse.push(item);
    });

    return ok_({
      roomName: room.roomName,
      date: today,
      myRole: role,
      myUserId: me.userId,
      myStatus: statusMap[me.userId] || null,
      going: going,
      notGoing: notGoing,
      noResponse: noResponse,
      inviteUrl: FRONTEND_URL + '?invite=' + room.inviteToken,
      roomCode: room.roomCode,
    });
  } catch (e) { return err_('처리 중 오류가 발생했습니다: ' + e.message); }
}

function api_setResponse(token, roomId, status) {
  try {
    const me = auth_(token);
    if (!me) return err_('AUTH');
    if (!memberRole_(roomId, me.userId)) return err_('NOT_MEMBER');
    if (status !== 'going' && status !== 'not-going') return err_('잘못된 응답 값입니다.');
    return withLock_(function () {
      const today = todayStr_();
      const idx = findRowIndex_('Responses', function (r) {
        return dateStr_(r[0]) === today && String(r[1]) === String(roomId) && String(r[2]) === me.userId;
      });
      if (idx > 0) {
        sheet_('Responses').getRange(idx, 4, 1, 2).setValues([[status, nowIso_()]]);
      } else {
        sheet_('Responses').appendRow([today, String(roomId), me.userId, status, nowIso_()]);
      }
      return ok_();
    });
  } catch (e) { return err_('처리 중 오류가 발생했습니다: ' + e.message); }
}

/* ==================== REQ-13 방 채팅 ==================== */

function api_getMessages(token, roomId) {
  try {
    const me = auth_(token);
    if (!me) return err_('AUTH');
    if (!memberRole_(roomId, me.userId)) return err_('NOT_MEMBER');
    const nicks = nickMap_();
    const all = rows_('Messages').filter(function (r) { return String(r[1]) === String(roomId); });
    const recent = all.slice(-CHAT_FETCH_LIMIT); // 최근 100개 (REQ-13)
    return ok_({
      messages: recent.map(function (r) {
        return {
          messageId: String(r[0]),
          userId: String(r[2]),
          nickname: nicks[String(r[2])] || '(탈퇴)',
          text: String(r[3]),
          sentAt: String(r[4]),
        };
      }),
      myUserId: me.userId,
    });
  } catch (e) { return err_('처리 중 오류가 발생했습니다: ' + e.message); }
}

function api_sendMessage(token, roomId, text) {
  try {
    const me = auth_(token);
    if (!me) return err_('AUTH');
    if (!memberRole_(roomId, me.userId)) return err_('NOT_MEMBER');
    text = String(text || '').trim();
    if (!text) return err_('메시지를 입력해주세요.');
    if (text.length > 300) return err_('메시지는 300자 이내로 입력해주세요.');
    return withLock_(function () {
      sheet_('Messages').appendRow([uuid_(), String(roomId), me.userId, text, nowIso_()]);
      return ok_();
    });
  } catch (e) { return err_('처리 중 오류가 발생했습니다: ' + e.message); }
}

/* ==================== REQ-08 월간 히스토리 ==================== */

function api_getHistory(token, roomId) {
  try {
    const me = auth_(token);
    if (!me) return err_('AUTH');
    if (!memberRole_(roomId, me.userId)) return err_('NOT_MEMBER');
    const cutoff = addDaysDateStr_(-(RETENTION_DAYS - 1)); // 오늘 포함 최근 30일
    const entries = {};
    rows_('History').forEach(function (r) {
      const d = dateStr_(r[0]);
      if (String(r[1]) !== String(roomId) || d < cutoff) return;
      entries[d] = {
        going: String(r[2]) ? String(r[2]).split(',') : [],
        notGoing: String(r[3]) ? String(r[3]).split(',') : [],
      };
    });
    // 오늘 실시간 데이터 포함
    const nicks = nickMap_();
    const today = todayStr_();
    const tGoing = [], tNot = [];
    rows_('Responses').forEach(function (r) {
      if (dateStr_(r[0]) !== today || String(r[1]) !== String(roomId)) return;
      const name = nicks[String(r[2])] || '(탈퇴)';
      if (String(r[3]) === 'going') tGoing.push(name);
      else if (String(r[3]) === 'not-going') tNot.push(name);
    });
    if (tGoing.length || tNot.length) entries[today] = { going: tGoing, notGoing: tNot };
    return ok_({ entries: entries, today: today, cutoff: cutoff });
  } catch (e) { return err_('처리 중 오류가 발생했습니다: ' + e.message); }
}

/* ==================== REQ-09 개인 설정 ==================== */

function api_updateNickname(token, nickname) {
  try {
    const me = auth_(token);
    if (!me) return err_('AUTH');
    nickname = String(nickname || '').trim();
    if (!/^[가-힣A-Za-z0-9]{2,10}$/.test(nickname)) return err_('닉네임은 2~10자의 한글/영문/숫자만 사용할 수 있습니다.');
    return withLock_(function () {
      const idx = findRowIndex_('Users', function (r) { return String(r[0]) === me.userId; });
      if (idx < 0) return err_('사용자를 찾을 수 없습니다.');
      sheet_('Users').getRange(idx, 5).setValue(nickname);
      return ok_({ nickname: nickname });
    });
  } catch (e) { return err_('처리 중 오류가 발생했습니다: ' + e.message); }
}

function api_changePassword(token, currentPw, newPw) {
  try {
    const me = auth_(token);
    if (!me) return err_('AUTH');
    if (!/^(?=.*[A-Za-z])(?=.*[0-9]).{8,}$/.test(String(newPw || ''))) return err_('새 비밀번호는 8자 이상이며 영문과 숫자를 모두 포함해야 합니다.');
    return withLock_(function () {
      const idx = findRowIndex_('Users', function (r) { return String(r[0]) === me.userId; });
      if (idx < 0) return err_('사용자를 찾을 수 없습니다.');
      const row = sheet_('Users').getRange(idx, 1, 1, SHEETS.Users.length).getValues()[0];
      if (hash_(currentPw, String(row[3])) !== String(row[2])) return err_('현재 비밀번호가 올바르지 않습니다.');
      const salt = uuid_();
      sheet_('Users').getRange(idx, 3, 1, 2).setValues([[hash_(newPw, salt), salt]]);
      return ok_();
    });
  } catch (e) { return err_('처리 중 오류가 발생했습니다: ' + e.message); }
}

/* ==================== REQ-10·11 방 관리 / 공동 호스트 ==================== */

function requireManager_(roomId, userId) {
  const role = memberRole_(roomId, userId);
  return (role === 'host' || role === 'co-host') ? role : null;
}

function api_getMembers(token, roomId) {
  try {
    const me = auth_(token);
    if (!me) return err_('AUTH');
    if (!requireManager_(roomId, me.userId)) return err_('권한이 없습니다.');
    const nicks = nickMap_();
    const members = rows_('Members')
      .filter(function (r) { return String(r[0]) === String(roomId); })
      .map(function (r) {
        return {
          userId: String(r[1]),
          nickname: nicks[String(r[1])] || '(탈퇴)',
          role: String(r[2]),
          joinedAt: String(r[3]),
        };
      });
    const order = { host: 0, 'co-host': 1, member: 2 };
    members.sort(function (a, b) { return (order[a.role] - order[b.role]) || a.nickname.localeCompare(b.nickname, 'ko'); });
    return ok_({ members: members, myRole: memberRole_(roomId, me.userId), myUserId: me.userId });
  } catch (e) { return err_('처리 중 오류가 발생했습니다: ' + e.message); }
}

function api_renameRoom(token, roomId, roomName) {
  try {
    const me = auth_(token);
    if (!me) return err_('AUTH');
    if (!requireManager_(roomId, me.userId)) return err_('권한이 없습니다.');
    roomName = String(roomName || '').trim();
    if (roomName.length < 2 || roomName.length > 20) return err_('방 이름은 2~20자로 입력해주세요.');
    return withLock_(function () {
      const idx = findRowIndex_('Rooms', function (r) { return String(r[0]) === String(roomId); });
      if (idx < 0) return err_('방을 찾을 수 없습니다.');
      sheet_('Rooms').getRange(idx, 2).setValue(roomName);
      return ok_({ roomName: roomName });
    });
  } catch (e) { return err_('처리 중 오류가 발생했습니다: ' + e.message); }
}

/** 초대 링크 재생성 — 이전 링크 즉시 무효화 (REQ-04) */
function api_regenerateInvite(token, roomId) {
  try {
    const me = auth_(token);
    if (!me) return err_('AUTH');
    if (!requireManager_(roomId, me.userId)) return err_('권한이 없습니다.');
    return withLock_(function () {
      const idx = findRowIndex_('Rooms', function (r) { return String(r[0]) === String(roomId); });
      if (idx < 0) return err_('방을 찾을 수 없습니다.');
      const newToken = uuid_();
      sheet_('Rooms').getRange(idx, 4, 1, 2).setValues([[newToken, addDaysIso_(INVITE_DAYS)]]);
      return ok_({ inviteUrl: FRONTEND_URL + '?invite=' + newToken });
    });
  } catch (e) { return err_('처리 중 오류가 발생했습니다: ' + e.message); }
}

/** 공동 호스트 지정/해제 — 호스트만 가능 (REQ-11) */
function api_setRole(token, roomId, targetUserId, role) {
  try {
    const me = auth_(token);
    if (!me) return err_('AUTH');
    if (memberRole_(roomId, me.userId) !== 'host') return err_('호스트만 공동 호스트를 지정/해제할 수 있습니다.');
    if (role !== 'member' && role !== 'co-host') return err_('잘못된 역할 값입니다.');
    const targetRole = memberRole_(roomId, targetUserId);
    if (!targetRole) return err_('해당 멤버를 찾을 수 없습니다.');
    if (targetRole === 'host') return err_('호스트의 역할은 변경할 수 없습니다.');
    return withLock_(function () {
      const idx = findRowIndex_('Members', function (r) {
        return String(r[0]) === String(roomId) && String(r[1]) === String(targetUserId);
      });
      sheet_('Members').getRange(idx, 3).setValue(role);
      return ok_();
    });
  } catch (e) { return err_('처리 중 오류가 발생했습니다: ' + e.message); }
}

function api_kickMember(token, roomId, targetUserId) {
  try {
    const me = auth_(token);
    if (!me) return err_('AUTH');
    const myRole = requireManager_(roomId, me.userId);
    if (!myRole) return err_('권한이 없습니다.');
    if (String(targetUserId) === me.userId) return err_('자기 자신은 내보낼 수 없습니다.');
    const targetRole = memberRole_(roomId, targetUserId);
    if (!targetRole) return err_('해당 멤버를 찾을 수 없습니다.');
    if (targetRole === 'host') return err_('호스트는 내보낼 수 없습니다.');
    if (myRole === 'co-host' && targetRole === 'co-host') return err_('공동 호스트는 다른 공동 호스트를 내보낼 수 없습니다.');
    return withLock_(function () {
      deleteRowsWhere_('Members', function (r) {
        return String(r[0]) === String(roomId) && String(r[1]) === String(targetUserId);
      });
      return ok_();
    });
  } catch (e) { return err_('처리 중 오류가 발생했습니다: ' + e.message); }
}

/** 방 삭제 — 호스트 전용, 관련 데이터 전체 삭제 (REQ-10) */
function api_deleteRoom(token, roomId) {
  try {
    const me = auth_(token);
    if (!me) return err_('AUTH');
    if (memberRole_(roomId, me.userId) !== 'host') return err_('방 삭제는 호스트만 할 수 있습니다.');
    return withLock_(function () {
      const match = function (r) { return String(r[0]) === String(roomId); };       // roomId가 1열
      const matchCol2 = function (r) { return String(r[1]) === String(roomId); };  // roomId가 2열
      deleteRowsWhere_('Members', match);
      deleteRowsWhere_('Responses', matchCol2);
      deleteRowsWhere_('History', matchCol2);
      deleteRowsWhere_('Messages', matchCol2);
      deleteRowsWhere_('Rooms', match);
      return ok_();
    });
  } catch (e) { return err_('처리 중 오류가 발생했습니다: ' + e.message); }
}

/* ==================== REQ-07 자동 초기화 (자정 트리거) ==================== */

function dailyReset() {
  withLock_(function () {
    const today = todayStr_();

    // 1) 과거 날짜 응답 → History 집계 후 삭제
    //    (응답은 날짜 키로 저장되므로 트리거가 지연·실패해도 당일 화면은 정상 동작 — C-06)
    const past = rows_('Responses').filter(function (r) { return dateStr_(r[0]) < today; });
    if (past.length) {
      const nicks = nickMap_();
      const groups = {};
      past.forEach(function (r) {
        const key = dateStr_(r[0]) + '|' + String(r[1]);
        if (!groups[key]) groups[key] = { going: [], notGoing: [] };
        const name = nicks[String(r[2])] || '(탈퇴)';
        if (String(r[3]) === 'going') groups[key].going.push(name);
        else if (String(r[3]) === 'not-going') groups[key].notGoing.push(name);
      });
      const existing = {};
      rows_('History').forEach(function (r) { existing[dateStr_(r[0]) + '|' + String(r[1])] = true; });
      const histSh = sheet_('History');
      Object.keys(groups).forEach(function (key) {
        if (existing[key]) return;
        const parts = key.split('|');
        histSh.appendRow([parts[0], parts[1], groups[key].going.join(','), groups[key].notGoing.join(',')]);
      });
      deleteRowsWhere_('Responses', function (r) { return dateStr_(r[0]) < today; });
    }

    // 2) 30일 경과 데이터 삭제 (히스토리·채팅)
    const cutoff = addDaysDateStr_(-RETENTION_DAYS);
    deleteRowsWhere_('History', function (r) { return dateStr_(r[0]) < cutoff; });
    deleteRowsWhere_('Messages', function (r) { return dateStr_(r[4]) < cutoff; });

    // 3) 만료 세션 정리
    const now = new Date();
    deleteRowsWhere_('Sessions', function (r) { return new Date(String(r[2])) < now; });
  });
}

/* ==================== 운영자 도구 (명세서 9.1 A안) ==================== */

/**
 * 비밀번호 분실 시 운영자가 앱스크립트 편집기에서 직접 실행.
 * 예: 아래 두 값을 수정한 뒤 이 함수를 실행 → 사용자에게 임시 비밀번호 전달
 */
function adminResetPassword() {
  const TARGET_LOGIN_ID = '여기에아이디입력';
  const TEMP_PASSWORD = 'temp1234';

  const idx = findRowIndex_('Users', function (r) {
    return String(r[1]).toLowerCase() === TARGET_LOGIN_ID.toLowerCase();
  });
  if (idx < 0) { Logger.log('사용자를 찾을 수 없습니다: ' + TARGET_LOGIN_ID); return; }
  const salt = uuid_();
  sheet_('Users').getRange(idx, 3, 1, 2).setValues([[hash_(TEMP_PASSWORD, salt), salt]]);
  // 해당 사용자의 기존 세션 전체 만료
  const userId = String(sheet_('Users').getRange(idx, 1).getValue());
  deleteRowsWhere_('Sessions', function (r) { return String(r[1]) === userId; });
  Logger.log('완료: ' + TARGET_LOGIN_ID + ' 비밀번호가 임시 비밀번호로 초기화되었습니다. 로그인 후 설정에서 변경하도록 안내하세요.');
}
