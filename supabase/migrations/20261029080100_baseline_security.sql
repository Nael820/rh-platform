-- Migration 2/6 — Sécurité de base : RLS, policies de lecture, trigger d'historique, temps réel (idempotent)

alter table public.profiles        enable row level security;
alter table public.request_types   enable row level security;
alter table public.requests        enable row level security;
alter table public.request_history enable row level security;
alter table public.leave_balances  enable row level security;

create or replace function public.is_hr()
returns boolean language sql security definer stable set search_path = public
as $$ select exists (select 1 from public.profiles where id = auth.uid() and role = 'hr') $$;

drop policy if exists "voir profils" on public.profiles;
create policy "voir profils" on public.profiles for select using (
  id = auth.uid() or manager_id = auth.uid() or public.is_hr()
);

drop policy if exists "voir soldes" on public.leave_balances;
create policy "voir soldes" on public.leave_balances for select using (
  user_id = auth.uid() or public.is_hr()
);

drop policy if exists "lire types" on public.request_types;
create policy "lire types" on public.request_types for select to authenticated using (true);

drop policy if exists "voir ses demandes" on public.requests;
create policy "voir ses demandes" on public.requests for select using (
  requester_id = auth.uid()
  or exists (select 1 from public.profiles p where p.id = requests.requester_id and p.manager_id = auth.uid())
  or public.is_hr()
);

drop policy if exists "créer sa demande" on public.requests;
create policy "créer sa demande" on public.requests for insert
  with check (requester_id = auth.uid());

drop policy if exists "valideurs modifient" on public.requests;
create policy "valideurs modifient" on public.requests for update
using (
  public.is_hr()
  or exists (select 1 from public.profiles p where p.id = requests.requester_id and p.manager_id = auth.uid())
)
with check (
  public.is_hr()
  or exists (select 1 from public.profiles p where p.id = requests.requester_id and p.manager_id = auth.uid())
);

drop policy if exists "voir historique" on public.request_history;
create policy "voir historique" on public.request_history for select using (
  exists (select 1 from public.requests r where r.id = request_history.request_id)
);

create or replace function public.log_request_status()
returns trigger language plpgsql security definer set search_path = public
as $$
begin
  if tg_op = 'INSERT' then
    insert into public.request_history (request_id, old_status, new_status, actor_id, note)
    values (new.id, null, new.status, auth.uid(), 'Demande créée');
  elsif new.status is distinct from old.status then
    insert into public.request_history (request_id, old_status, new_status, actor_id)
    values (new.id, old.status, new.status, auth.uid());
  end if;
  return new;
end;
$$;

drop trigger if exists trg_log_request_status on public.requests;
create trigger trg_log_request_status
after insert or update on public.requests
for each row execute function public.log_request_status();

-- Temps réel pour le tableau de bord (ignoré si la publication n'existe pas ou contient déjà la table)
do $$ begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime')
     and not exists (select 1 from pg_publication_tables
                     where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'requests') then
    alter publication supabase_realtime add table public.requests;
  end if;
end $$;
