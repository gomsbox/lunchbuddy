# 🍱 런치버디 (LunchBuddy) — 배포 가이드

구글 시트(데이터) + 구글 앱스크립트(JSON API 백엔드) + GitHub Pages(프론트엔드)로 동작하는
사내 점심 멤버 확인 서비스입니다. (요구사항 명세서 v1.3 기준)

## 구조

```
사용자 → https://gomsbox.github.io/lunchbuddy/   ← 프론트엔드 (GitHub Pages, docs/index.html)
              ↓ fetch(POST)
         https://script.google.com/.../exec      ← 백엔드 JSON API (Code.gs)
              ↓
         구글 시트                                ← 데이터 저장소
```

| 파일 | 내용 | 위치 |
|------|------|------|
| `Code.gs` | 백엔드 JSON API (인증, 방, 참여, 채팅, 히스토리, 트리거) | 앱스크립트에 붙여넣기 |
| `appsscript.json` | 앱스크립트 프로젝트 설정 | 앱스크립트에 붙여넣기 |
| `../docs/index.html` | 프론트엔드 (서비스 화면 전체) | GitHub Pages가 자동 서빙 |

---

## 배포 순서

### 1. 구글 시트 + 앱스크립트 (백엔드)
1. [sheets.new](https://sheets.new) → 새 스프레드시트 생성 (이름: `런치버디DB` 등)
   - ⚠️ 이 시트가 유일한 데이터 저장소입니다. **다른 사람과 공유하지 마세요**
2. **확장 프로그램 > Apps Script** → 기본 코드를 지우고 **`Code.gs`** 내용 붙여넣기
   - 이제 앱스크립트에 HTML 파일은 필요 없습니다 (기존 `index` HTML 파일이 있다면 삭제)
3. `Code.gs` 상단의 `FRONTEND_URL`이 실제 GitHub Pages 주소인지 확인
   (기본값: `https://gomsbox.github.io/lunchbuddy/`)
4. **⚙ 프로젝트 설정 > appsscript.json 표시** 체크 → 이 폴더의 `appsscript.json`으로 교체
5. 함수 드롭다운에서 **`setup`** 선택 → 실행 (최초 1회, 권한 승인)
6. **배포 > 새 배포 > 웹 앱** — 실행: **나** / 액세스: **모든 사용자** → 배포
7. 발급된 **웹 앱 URL(/exec로 끝남)** 복사 ← 다음 단계에서 사용

### 2. 프론트엔드 연결 (GitHub Pages)
1. `docs/index.html`을 열어 상단 스크립트의
   `var API_URL = 'PASTE_YOUR_APPS_SCRIPT_EXEC_URL';` 부분에 **1-7의 /exec URL** 입력
2. 커밋 & push
3. 깃허브 저장소 **Settings > Pages** → Source: **Deploy from a branch**,
   Branch: **main** / 폴더: **/docs** → Save
   - ⚠️ 무료 계정은 저장소가 **Public**이어야 GitHub Pages를 쓸 수 있습니다
4. 1~2분 후 `https://gomsbox.github.io/lunchbuddy/` 접속 확인

### 3. 사용 시작
- 서비스 URL(`https://gomsbox.github.io/lunchbuddy/`)을 팀에 공유 — 누구나 가입·방 생성 가능
- 방 참여 수단: **초대 링크**(7일 유효) 또는 **방 코드**(6자리, 만료 없음)

---

## 운영 가이드

### 코드 수정 후 반영
| 수정 대상 | 반영 방법 |
|-----------|-----------|
| 프론트 (`docs/index.html`) | 커밋 & push만 하면 1~2분 내 자동 반영 |
| 백엔드 (`Code.gs`) | 앱스크립트에 붙여넣기 → **배포 > 배포 관리 > ✏️ 수정 > 버전: 새 버전 > 배포** ("새 배포"를 만들면 /exec URL이 바뀌니 주의) |

### 비밀번호 초기화 (명세서 9.1 A안)
1. 앱스크립트 편집기에서 `Code.gs` 맨 아래 **`adminResetPassword`** 함수의
   `TARGET_LOGIN_ID`와 `TEMP_PASSWORD` 수정
2. 함수 드롭다운에서 `adminResetPassword` 선택 → 실행
3. 사용자에게 임시 비밀번호 전달 → 로그인 후 **설정 > 비밀번호 변경** 안내

### 자정 초기화가 안 도는 것 같을 때
- 트리거는 00:00~01:00 사이 실행되며 ±15분 오차가 있을 수 있습니다
- 응답 데이터는 날짜 키로 저장되므로 트리거가 지연돼도 당일 화면은 항상 정상입니다
- 편집기 좌측 **트리거(⏰)** 메뉴에서 `dailyReset` 확인, 없으면 `setup()` 재실행

### 데이터 백업 (명세서 9.5 권장)
- 스프레드시트 **파일 > 사본 만들기** 주 1회 권장 (자동화 원하면 요청)

---

## 주요 사양 요약

| 항목 | 값 |
|------|-----|
| 서비스 URL | https://gomsbox.github.io/lunchbuddy/ (GitHub Pages) |
| 세션 유효기간 | 30일 (localStorage 토큰) |
| 로그인 차단 | 5회 연속 실패 시 10분 차단 |
| 초대 링크 만료 | 생성 후 7일, 재생성 시 이전 링크 즉시 무효화 |
| 방 코드 | 6자리 영구 코드 (만료 없음, 방 삭제 시까지 유지) |
| 현황 갱신 | 30초 자동 폴링 + 수동 새로고침 |
| 채팅 | 텍스트 300자, 최근 100개 표시, 15초 폴링 |
| 데이터 보관 | 참여 기록·채팅 30일 후 자동 삭제 |
| 방 삭제 | 호스트 전용 (멤버·기록·채팅 전체 삭제) |
