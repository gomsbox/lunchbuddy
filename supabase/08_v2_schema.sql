-- ============================================================
-- 🍱 오늘점심 v2 — 스키마 일괄 마이그레이션 (1/2)
-- 01~07 실행 후 이 파일 전체를 SQL Editor에 붙여넣고 Run 하세요.
-- 여러 번 재실행해도 안전합니다 (add column if not exists / create table if not exists).
--
-- 이 파일은 v2 전체 단계(1~6)에서 쓰는 컬럼·테이블을 한 번에 만들어 둡니다.
-- 기능별 RPC 함수는 09~14 파일에서 단계별로 추가합니다.
-- 기존 방은 전부 purpose='cafeteria' + 토글 off로 채워져 v1과 동일하게 동작합니다 (NFR-10).
-- ============================================================

-- ------------------------------------------------------------
-- 1) rooms — 방 목적(프리셋) + 메뉴 투표 + 이벤트형 방 설정
-- ------------------------------------------------------------
alter table rooms add column if not exists purpose text not null default 'cafeteria'
  check (purpose in ('cafeteria', 'outside', 'poll', 'event', 'custom'));

-- 프리셋이 결정하는 세부 토글 (custom에서는 호스트가 직접 on/off)
alter table rooms add column if not exists track_meal_log boolean not null default false;   -- 응답 시 장소·메뉴 기록 (REQ-17)
alter table rooms add column if not exists enable_menu_poll boolean not null default false; -- 메뉴 투표 사용 (REQ-19)

-- 메뉴 투표 세부 설정 (REQ-19)
alter table rooms add column if not exists menu_poll_deadline text;                              -- 자동 마감 시각 HH:mm (null이면 수동 마감만)
alter table rooms add column if not exists menu_poll_member_add boolean not null default true;   -- 멤버도 후보를 추가할 수 있는지

-- 이벤트형(event) 방 전용 — 1회용 라이프사이클 (REQ-25)
alter table rooms add column if not exists event_status text not null default 'open'
  check (event_status in ('open', 'closed'));
alter table rooms add column if not exists event_closed_at timestamptz;
alter table rooms add column if not exists event_auto_close_days int not null default 14;   -- 미마감 시 자동 마감까지 기간
alter table rooms add column if not exists event_purge_after_days int not null default 7;   -- 마감 후 자동 삭제까지 기간

-- v2.1 예정 (REQ-23 리마인드 알림) — 컬럼만 미리 만들어 두고 이번 v2에서는 사용하지 않음
alter table rooms add column if not exists remind_enabled boolean not null default false;
alter table rooms add column if not exists remind_after_minutes int not null default 90;

-- ------------------------------------------------------------
-- 2) users — 게스트 계정 (REQ-25)
--    이벤트형 방에 이름만 입력해 참여한 사람. 로그인 아이디·비밀번호가 없다.
-- ------------------------------------------------------------
alter table users add column if not exists is_guest boolean not null default false;

-- 게스트는 login_id / password_hash가 null이므로 not null 제약을 완화한다.
-- (기존 회원 데이터는 전부 값이 채워져 있어 영향 없음. login_id의 unique 제약은 null을 여러 개 허용)
alter table users alter column login_id drop not null;
alter table users alter column password_hash drop not null;

-- 게스트 정리 배치에서 쓰는 인덱스
create index if not exists users_is_guest_idx on users (is_guest) where is_guest = true;

-- ------------------------------------------------------------
-- 3) responses — 응답 시 장소·메뉴 기록 (REQ-17)
-- ------------------------------------------------------------
alter table responses add column if not exists place_name text;   -- 장소명 (선택, 최대 20자)
alter table responses add column if not exists menu_name text;    -- 메뉴명 (선택, 최대 20자)

-- 자동완성(REQ-20)에서 "내가 최근에 입력한 값"을 찾는 용도
create index if not exists responses_user_menu_idx on responses (user_id, date desc) where menu_name is not null;

-- ------------------------------------------------------------
-- 4) history — 일별 집계에 장소·메뉴 스냅샷 + 투표 확정 메뉴 (REQ-17·18·19)
-- ------------------------------------------------------------
-- meal_logs 예시: [{"nickname":"유정","place":"김밥천국","menu":"제육덮밥"}, ...]
alter table history add column if not exists meal_logs jsonb not null default '[]'::jsonb;
alter table history add column if not exists confirmed_menu text;   -- 그 날 메뉴 투표로 확정된 메뉴 (없으면 null)

-- ------------------------------------------------------------
-- 5) 메뉴 투표 (REQ-19)
--    방 × 날짜당 투표 1개. 후보는 2~6개, 1인 1표(재투표 시 덮어씀).
-- ------------------------------------------------------------
create table if not exists menu_polls (
  id uuid primary key default gen_random_uuid(),
  room_id uuid not null references rooms(id) on delete cascade,
  date date not null,
  status text not null default 'open' check (status in ('open', 'closed')),
  deadline_at timestamptz,                 -- 자동 마감 예정 시각 (rooms.menu_poll_deadline 기준으로 계산해 저장)
  confirmed_option_id uuid,                -- 확정된 후보 (FK는 아래에서 별도 추가 — 테이블 생성 순서 때문)
  confirmed_label text,                    -- 확정 메뉴명 스냅샷 (responses.nickname과 같은 스냅샷 방식)
  was_tie boolean not null default false,  -- 동률이라 룰렛으로 뽑혔는지 (화면 안내용)
  created_by uuid not null references users(id) on delete cascade,
  created_at timestamptz not null default now(),
  closed_at timestamptz,
  unique (room_id, date)
);
create index if not exists menu_polls_room_date_idx on menu_polls (room_id, date);

create table if not exists menu_poll_options (
  id uuid primary key default gen_random_uuid(),
  poll_id uuid not null references menu_polls(id) on delete cascade,
  label text not null,
  created_by uuid not null references users(id) on delete cascade,
  created_by_nickname text,                -- 후보를 추가한 사람의 방 닉네임 스냅샷
  created_at timestamptz not null default now(),
  unique (poll_id, label)                  -- 같은 투표에 같은 후보 중복 등록 방지
);
create index if not exists menu_poll_options_poll_idx on menu_poll_options (poll_id);

create table if not exists menu_poll_votes (
  poll_id uuid not null references menu_polls(id) on delete cascade,
  option_id uuid not null references menu_poll_options(id) on delete cascade,
  user_id uuid not null references users(id) on delete cascade,
  nickname text,                           -- 투표 시점 방 닉네임 스냅샷
  voted_at timestamptz not null default now(),
  primary key (poll_id, user_id)           -- 1인 1표 — 재투표는 upsert로 option_id만 교체
);
create index if not exists menu_poll_votes_option_idx on menu_poll_votes (option_id);

-- confirmed_option_id의 FK는 menu_poll_options가 만들어진 뒤에 추가 (후보가 지워지면 null로)
do $$ begin
  alter table menu_polls
    add constraint menu_polls_confirmed_option_fk
    foreign key (confirmed_option_id) references menu_poll_options(id) on delete set null;
exception when duplicate_object then null;
end $$;

-- ------------------------------------------------------------
-- 6) RLS 잠금 — 기존 테이블과 동일한 방침
--    정책을 하나도 만들지 않음 = anon/authenticated는 직접 접근 불가.
--    모든 읽기/쓰기는 SECURITY DEFINER RPC 함수를 통해서만 이뤄진다.
-- ------------------------------------------------------------
alter table menu_polls enable row level security;
alter table menu_poll_options enable row level security;
alter table menu_poll_votes enable row level security;

-- ------------------------------------------------------------
-- 7) 확인용 — 실행 후 아래 쿼리로 기존 방이 모두 cafeteria/토글 off인지 점검
-- ------------------------------------------------------------
-- select purpose, track_meal_log, enable_menu_poll, count(*) from rooms group by 1,2,3;
