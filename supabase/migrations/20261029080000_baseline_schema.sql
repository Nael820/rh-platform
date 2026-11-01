-- Migration 1/6 — Schéma de base (idempotent : peut être rejoué sur une base qui contient déjà les tables)

do $$ begin
  create type public.user_role as enum ('employee', 'manager', 'hr');
exception when duplicate_object then null; end $$;

do $$ begin
  create type public.request_status as enum
    ('pending', 'ai_review', 'manager_review', 'hr_review', 'approved', 'rejected');
exception when duplicate_object then null; end $$;

create table if not exists public.profiles (
  id         uuid primary key references auth.users on delete cascade,
  full_name  text not null,
  role       public.user_role not null default 'employee',
  manager_id uuid references public.profiles(id)
);

create table if not exists public.request_types (
  id           serial primary key,
  label        text not null unique,
  hr_threshold numeric
);

create table if not exists public.requests (
  id           uuid primary key default gen_random_uuid(),
  requester_id uuid not null references public.profiles(id),
  type_id      int  not null references public.request_types(id),
  start_date   date,
  end_date     date,
  amount       numeric,
  comment      text,
  status       public.request_status not null default 'pending',
  created_at   timestamptz default now(),
  check (end_date >= start_date)
);

create table if not exists public.request_history (
  id         bigserial primary key,
  request_id uuid not null references public.requests(id) on delete cascade,
  old_status public.request_status,
  new_status public.request_status not null,
  actor_id   uuid references public.profiles(id),
  note       text,
  changed_at timestamptz default now()
);

create table if not exists public.leave_balances (
  user_id   uuid primary key references public.profiles(id),
  days_left numeric not null default 25
);

insert into public.request_types (label, hr_threshold) values
  ('Congés', 10), ('Télétravail', null), ('Matériel', 500), ('Formation', 1000)
on conflict (label) do nothing;

create index if not exists idx_requests_requester on public.requests(requester_id);
create index if not exists idx_requests_status    on public.requests(status);
create index if not exists idx_history_request    on public.request_history(request_id, changed_at);
