-- Migration 4/6 — Routage multi-niveaux (manager -> RH -> DRH), validation en un clic via RPC, traçabilité.

-- 1. Paramètres de routage par type de demande ------------------------------------------
alter table public.request_types
  add column if not exists threshold_unit text    not null default 'eur' check (threshold_unit in ('days', 'eur')),
  add column if not exists drh_threshold  numeric,
  add column if not exists needs_dates    boolean not null default false,
  add column if not exists needs_amount   boolean not null default false,
  add column if not exists consumes_leave boolean not null default false;

comment on column public.request_types.hr_threshold  is 'Au-delà de ce seuil (jours ou euros selon threshold_unit), la demande passe aussi par la RH';
comment on column public.request_types.drh_threshold is 'Au-delà de ce seuil, la demande passe aussi par le DRH';

update public.request_types set threshold_unit = 'days', hr_threshold = 10,   drh_threshold = 20,
       needs_dates = true,  needs_amount = false, consumes_leave = true  where label = 'Congés';
update public.request_types set threshold_unit = 'days', hr_threshold = null, drh_threshold = null,
       needs_dates = true,  needs_amount = false, consumes_leave = false where label = 'Télétravail';
update public.request_types set threshold_unit = 'eur',  hr_threshold = 500,  drh_threshold = 2000,
       needs_dates = false, needs_amount = true,  consumes_leave = false where label = 'Matériel';
update public.request_types set threshold_unit = 'eur',  hr_threshold = 1000, drh_threshold = 5000,
       needs_dates = false, needs_amount = true,  consumes_leave = false where label = 'Formation';

-- 2. Colonnes de suivi sur les demandes ------------------------------------------------
alter table public.requests
  add column if not exists days_requested int generated always as
    (case when start_date is not null and end_date is not null then end_date - start_date + 1 end) stored,
  add column if not exists required_level text not null default 'manager'
    check (required_level in ('manager', 'hr', 'drh')),
  add column if not exists decided_at timestamptz,
  add column if not exists decided_by uuid references public.profiles(id);

-- 3. Niveau de validation exigé, calculé par la base (non falsifiable par le client) -----
create or replace function public.route_level(p_type int, p_amount numeric, p_days int)
returns text language sql stable set search_path = public as $$
  select coalesce((
    select case
      when x.m is null or t.hr_threshold is null           then 'manager'
      when t.drh_threshold is not null and x.m > t.drh_threshold then 'drh'
      when x.m > t.hr_threshold                            then 'hr'
      else 'manager'
    end
    from public.request_types t
    cross join lateral (select case t.threshold_unit when 'days' then p_days::numeric else p_amount end as m) x
    where t.id = p_type
  ), 'manager')
$$;

create or replace function public.requests_set_level()
returns trigger language plpgsql set search_path = public as $$
begin
  new.required_level := public.route_level(
    new.type_id, new.amount,
    case when new.start_date is not null and new.end_date is not null then new.end_date - new.start_date + 1 end);
  return new;
end $$;

drop trigger if exists trg_requests_set_level on public.requests;
create trigger trg_requests_set_level
before insert or update of type_id, amount, start_date, end_date on public.requests
for each row execute function public.requests_set_level();

-- 4. Historique : l'auteur et le commentaire de chaque changement de statut ----------------
create or replace function public.log_request_status()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    insert into public.request_history (request_id, old_status, new_status, actor_id, note)
    values (new.id, null, new.status, auth.uid(), 'Demande créée');
  elsif new.status is distinct from old.status then
    insert into public.request_history (request_id, old_status, new_status, actor_id, note)
    values (new.id, old.status, new.status, auth.uid(), nullif(current_setting('app.note', true), ''));
  end if;
  return new;
end $$;

-- 5. Le DRH voit tout comme la RH -------------------------------------------------------
create or replace function public.is_hr()
returns boolean language sql security definer stable set search_path = public
as $$ select exists (select 1 from public.profiles where id = auth.uid() and role in ('hr', 'drh')) $$;

-- 5 bis. Un manager voit le solde de congés de son équipe (utile pour valider en connaissance de cause)
drop policy if exists "voir soldes" on public.leave_balances;
create policy "voir soldes" on public.leave_balances for select using (
  user_id = auth.uid()
  or exists (select 1 from public.profiles p where p.id = leave_balances.user_id and p.manager_id = auth.uid())
  or public.is_hr()
);

-- 6. Plus aucune modification directe des demandes depuis le navigateur ------------------
--    Les changements de statut passent uniquement par approve_request / reject_request
--    (ou par n8n avec la clé service_role). Un manager ne peut plus modifier les montants.
drop policy if exists "valideurs modifient" on public.requests;

drop policy if exists "créer sa demande" on public.requests;
create policy "créer sa demande" on public.requests for insert
  with check (requester_id = auth.uid() and status = 'pending');

-- 7. Validation en un clic ---------------------------------------------------------------
create or replace function public._level_rank(p_level text)
returns int language sql immutable as $$
  select case p_level when 'manager' then 1 when 'hr' then 2 else 3 end
$$;

create or replace function public._stage_of(p_status public.request_status)
returns text language sql immutable as $$
  select case p_status
    when 'pending'        then 'manager'   -- repli si le contrôle IA n'a pas tourné
    when 'manager_review' then 'manager'
    when 'hr_review'      then 'hr'
    when 'drh_review'     then 'drh'
  end
$$;

create or replace function public._can_validate(r public.requests, p_uid uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select case public._stage_of(r.status)
    when 'manager' then exists (select 1 from public.profiles me, public.profiles req
                                where me.id = p_uid and me.role = 'manager'
                                  and req.id = r.requester_id and req.manager_id = me.id)
    when 'hr'      then exists (select 1 from public.profiles where id = p_uid and role in ('hr', 'drh'))
    when 'drh'     then exists (select 1 from public.profiles where id = p_uid and role = 'drh')
    else false
  end and r.requester_id <> p_uid
$$;

create or replace function public.approve_request(p_request uuid, p_comment text default null)
returns public.request_status language plpgsql security definer set search_path = public as $$
declare
  r public.requests; stage text; nxt public.request_status; t public.request_types; bal numeric;
begin
  if auth.uid() is null then raise exception 'authentification requise' using errcode = '28000'; end if;
  select * into r from public.requests where id = p_request for update;
  if not found then raise exception 'demande introuvable' using errcode = 'P0002'; end if;
  stage := public._stage_of(r.status);
  if stage is null then
    raise exception 'la demande n''attend aucune validation (statut %)', r.status using errcode = '22023';
  end if;
  if not public._can_validate(r, auth.uid()) then
    raise exception 'validation non autorisée à l''étape %', stage using errcode = '42501';
  end if;

  if public._level_rank(stage) >= public._level_rank(r.required_level) then
    nxt := 'approved';
    select * into t from public.request_types where id = r.type_id;
    if t.consumes_leave then
      select days_left into bal from public.leave_balances where user_id = r.requester_id for update;
      if bal is null or bal < coalesce(r.days_requested, 0) then
        raise exception 'solde de congés insuffisant (% jours restants, % demandés)',
          coalesce(bal, 0), coalesce(r.days_requested, 0) using errcode = '22023';
      end if;
      update public.leave_balances set days_left = days_left - r.days_requested where user_id = r.requester_id;
    end if;
  elsif stage = 'manager' then nxt := 'hr_review';
  else nxt := 'drh_review';
  end if;

  perform set_config('app.note', coalesce(p_comment, ''), true);
  update public.requests
     set status = nxt,
         decided_at = case when nxt = 'approved' then now() end,
         decided_by = case when nxt = 'approved' then auth.uid() end
   where id = p_request;
  return nxt;
end $$;

create or replace function public.reject_request(p_request uuid, p_comment text)
returns public.request_status language plpgsql security definer set search_path = public as $$
declare r public.requests;
begin
  if auth.uid() is null then raise exception 'authentification requise' using errcode = '28000'; end if;
  if coalesce(btrim(p_comment), '') = '' then
    raise exception 'un motif de refus est obligatoire' using errcode = '22023';
  end if;
  select * into r from public.requests where id = p_request for update;
  if not found then raise exception 'demande introuvable' using errcode = 'P0002'; end if;
  if public._stage_of(r.status) is null then
    raise exception 'la demande n''attend aucune validation (statut %)', r.status using errcode = '22023';
  end if;
  if not public._can_validate(r, auth.uid()) then
    raise exception 'refus non autorisé à cette étape' using errcode = '42501';
  end if;
  perform set_config('app.note', p_comment, true);
  update public.requests set status = 'rejected', decided_at = now(), decided_by = auth.uid() where id = p_request;
  return 'rejected';
end $$;

revoke all on function public._level_rank(text)                      from public, anon, authenticated;
revoke all on function public._stage_of(public.request_status)       from public, anon, authenticated;
revoke all on function public._can_validate(public.requests, uuid)   from public, anon, authenticated;
revoke all on function public.approve_request(uuid, text)            from public, anon;
revoke all on function public.reject_request(uuid, text)             from public, anon;
grant execute on function public.approve_request(uuid, text) to authenticated;
grant execute on function public.reject_request(uuid, text)  to authenticated;
