-- ============================================================
-- 🍱 오늘점심 — Supabase 스키마 (1/3: 확장 + 테이블)
-- Supabase 대시보드 > SQL Editor에 전체를 붙여넣고 Run 하세요.
-- ============================================================

-- 확장 활성화
create extension if not exists pgcrypto;   -- 비밀번호 해시(bcrypt)
create extension if not exists pg_cron;    -- 자정 초기화 / 알림 발송 스케줄
create extension if not exists pg_net;     -- Resend 이메일 API 호출 (서버 안에서 HTTP 요청)

-- ============================================================
-- 테이블
-- ============================================================

create table if not exists users (
  id uuid primary key default gen_random_uuid(),
  login_id text unique not null,
  password_hash text not null,
  nickname text not null,
  email text,
  created_at timestamptz not null default now()
);
create unique index if not exists users_email_unique on users (email) where email is not null;

create table if not exists login_attempts (
  login_id text primary key,
  fail_count int not null default 0,
  blocked_until timestamptz
);

create table if not exists sessions (
  token uuid primary key default gen_random_uuid(),
  user_id uuid not null references users(id) on delete cascade,
  expires_at timestamptz not null
);
create index if not exists sessions_user_id_idx on sessions (user_id);

create table if not exists password_resets (
  token uuid primary key default gen_random_uuid(),
  user_id uuid not null references users(id) on delete cascade,
  expires_at timestamptz not null,
  used boolean not null default false
);

create table if not exists rooms (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  host_user_id uuid not null references users(id),
  invite_token uuid not null default gen_random_uuid(),
  invite_expires_at timestamptz not null default (now() + interval '7 days'),
  room_code text unique not null,
  notify_enabled boolean not null default false,
  notify_time text not null default '10:30',
  notify_weekday boolean not null default true,   -- 평일(월~금) 발송 여부
  notify_weekend boolean not null default false,   -- 주말(토~일) 발송 여부 — 둘 다 켜면 매일 발송
  last_notified_date date,
  created_at timestamptz not null default now()
);
create index if not exists rooms_invite_token_idx on rooms (invite_token);
create index if not exists rooms_room_code_idx on rooms (room_code);

-- 기존에 만들어진 rooms 테이블에 새 컬럼 추가 (이미 실행했던 설치본도 안전하게 재실행 가능)
alter table rooms add column if not exists notify_weekday boolean not null default true;
alter table rooms add column if not exists notify_weekend boolean not null default false;

create table if not exists members (
  room_id uuid not null references rooms(id) on delete cascade,
  user_id uuid not null references users(id) on delete cascade,
  role text not null check (role in ('host', 'co-host', 'member')),
  nickname text not null default '',   -- 방별 닉네임 (계정 닉네임과 독립적으로 방마다 다르게 설정 가능)
  joined_at timestamptz not null default now(),
  primary key (room_id, user_id)
);
create index if not exists members_user_id_idx on members (user_id);

-- 기존 members 테이블에 닉네임 컬럼 추가 (없는 경우) + 계정 닉네임으로 초기값 채움
alter table members add column if not exists nickname text;
update members m set nickname = u.nickname from users u where u.id = m.user_id and (m.nickname is null or m.nickname = '');
alter table members alter column nickname set not null;

create table if not exists responses (
  date date not null,
  room_id uuid not null references rooms(id) on delete cascade,
  user_id uuid not null references users(id) on delete cascade,
  status text not null check (status in ('going', 'not-going')),
  nickname text,   -- 응답 시점의 방 닉네임 스냅샷 (나중에 강퇴/탈퇴해도 히스토리 집계에 이름이 남도록)
  updated_at timestamptz not null default now(),
  primary key (date, room_id, user_id)
);
create index if not exists responses_room_date_idx on responses (room_id, date);
alter table responses add column if not exists nickname text;

create table if not exists history (
  date date not null,
  room_id uuid not null references rooms(id) on delete cascade,
  going_names text not null default '',
  not_going_names text not null default '',
  primary key (date, room_id)
);

create table if not exists messages (
  id uuid primary key default gen_random_uuid(),
  room_id uuid not null references rooms(id) on delete cascade,
  user_id uuid not null references users(id) on delete cascade,
  nickname text,   -- 전송 시점의 방 닉네임 스냅샷 (나중에 강퇴/탈퇴해도 채팅 기록에 이름이 남도록)
  text text not null,
  sent_at timestamptz not null default now()
);
create index if not exists messages_room_date_idx on messages (room_id, sent_at);
alter table messages add column if not exists nickname text;

-- 기존 responses/messages 행에 남아있던 값이 있다면 방 닉네임으로 백필 (신규 설치에서는 대상 행이 없어 영향 없음)
update responses r set nickname = m.nickname from members m where m.room_id = r.room_id and m.user_id = r.user_id and r.nickname is null;
update messages msg set nickname = m.nickname from members m where m.room_id = msg.room_id and m.user_id = msg.user_id and msg.nickname is null;

-- 운영 설정 저장용 (Resend API 키 등). RLS로 잠가서 RPC 함수 내부에서만 접근.
create table if not exists app_config (
  key text primary key,
  value text
);

-- ============================================================
-- RLS 잠금: 모든 테이블은 앱(anon 키)에서 직접 접근 불가.
-- 모든 읽기/쓰기는 아래 02_functions.sql의 SECURITY DEFINER 함수를 통해서만 이뤄짐.
-- ============================================================
alter table users enable row level security;
alter table login_attempts enable row level security;
alter table sessions enable row level security;
alter table password_resets enable row level security;
alter table rooms enable row level security;
alter table members enable row level security;
alter table responses enable row level security;
alter table history enable row level security;
alter table messages enable row level security;
alter table app_config enable row level security;
-- (정책을 하나도 만들지 않음 = anon/authenticated 역할은 아무 것도 못 봄/못 씀. 함수만 우회 가능)
