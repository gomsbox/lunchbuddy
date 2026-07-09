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
  last_notified_date date,
  created_at timestamptz not null default now()
);
create index if not exists rooms_invite_token_idx on rooms (invite_token);
create index if not exists rooms_room_code_idx on rooms (room_code);

create table if not exists members (
  room_id uuid not null references rooms(id) on delete cascade,
  user_id uuid not null references users(id) on delete cascade,
  role text not null check (role in ('host', 'co-host', 'member')),
  joined_at timestamptz not null default now(),
  primary key (room_id, user_id)
);
create index if not exists members_user_id_idx on members (user_id);

create table if not exists responses (
  date date not null,
  room_id uuid not null references rooms(id) on delete cascade,
  user_id uuid not null references users(id) on delete cascade,
  status text not null check (status in ('going', 'not-going')),
  updated_at timestamptz not null default now(),
  primary key (date, room_id, user_id)
);
create index if not exists responses_room_date_idx on responses (room_id, date);

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
  text text not null,
  sent_at timestamptz not null default now()
);
create index if not exists messages_room_date_idx on messages (room_id, sent_at);

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
