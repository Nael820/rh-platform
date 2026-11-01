-- Migration 5/6 — Agent IA : contrôles déterministes en base + traçabilité des synthèses et des coûts.
-- Principe : la base calcule les faits (dates, solde, doublons) ; le LLM rédige seulement la synthèse.
-- L'IA ne décide jamais : elle pré-qualifie, un humain valide.

create table if not exists public.ai_reviews (
  id         bigserial primary key,
  request_id uuid not null references public.requests(id) on delete cascade,
  verdict    text not null check (verdict in ('ok', 'to_check')),
  checks     jsonb not null default '{}'::jsonb,
  summary    text,
  model      text,
  tokens_in  int  not null default 0,
  tokens_out int  not null default 0,
  cost_eur   numeric(10, 6) not null default 0,
  created_at timestamptz not null default now()
);
create index if not exists idx_ai_reviews_request on public.ai_reviews(request_id);

alter table public.ai_reviews enable row level security;

drop policy if exists "voir contrôles IA" on public.ai_reviews;
create policy "voir contrôles IA" on public.ai_reviews for select using (
  exists (select 1 from public.requests r where r.id = ai_reviews.request_id)
);
-- Aucune policy d'écriture : seul un appel avec la clé service_role (n8n) peut écrire.

create or replace function public.check_request(p_request uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  r public.requests; t public.request_types;
  dates_ok boolean; amount_ok boolean; balance_ok boolean := true; bal numeric;
  dups uuid[]; issues text[] := '{}';
begin
  select * into r from public.requests where id = p_request;
  if not found then raise exception 'demande introuvable' using errcode = 'P0002'; end if;
  select * into t from public.request_types where id = r.type_id;

  dates_ok := not t.needs_dates
    or (r.start_date is not null and r.end_date is not null and r.end_date >= r.start_date);
  if not dates_ok then issues := array_append(issues, 'dates absentes ou incohérentes'); end if;

  amount_ok := not t.needs_amount or (r.amount is not null and r.amount > 0);
  if not amount_ok then issues := array_append(issues, 'montant absent ou nul'); end if;

  if t.consumes_leave then
    select days_left into bal from public.leave_balances where user_id = r.requester_id;
    balance_ok := coalesce(bal, 0) >= coalesce(r.days_requested, 0);
    if not balance_ok then
      issues := array_append(issues, format('solde insuffisant (%s jours restants, %s demandés)',
                                 coalesce(bal, 0), coalesce(r.days_requested, 0)));
    end if;
  end if;

  select coalesce(array_agg(o.id), '{}') into dups
  from public.requests o
  where o.id <> r.id and o.requester_id = r.requester_id and o.type_id = r.type_id
    and o.status <> 'rejected'
    and (
      (t.needs_dates and o.start_date <= r.end_date and o.end_date >= r.start_date)
      or (t.needs_amount and o.amount = r.amount and o.created_at > r.created_at - interval '7 days')
    );
  if array_length(dups, 1) > 0 then issues := array_append(issues, 'doublon possible'); end if;

  return jsonb_build_object(
    'request_id', r.id,
    'type', t.label,
    'dates_ok', dates_ok,
    'amount_ok', amount_ok,
    'balance_ok', balance_ok,
    'days_left', bal,
    'days_requested', r.days_requested,
    'amount', r.amount,
    'start_in_past', coalesce(r.start_date < current_date, false),
    'duplicate_ids', to_jsonb(dups),
    'required_level', r.required_level,
    'issues', to_jsonb(issues),
    'verdict', case when cardinality(issues) = 0 then 'ok' else 'to_check' end
  );
end $$;

create or replace function public.ai_record_review(
  p_request uuid, p_verdict text, p_checks jsonb, p_summary text, p_model text,
  p_tokens_in int default 0, p_tokens_out int default 0, p_cost_eur numeric default 0)
returns void language plpgsql security definer set search_path = public as $$
begin
  if p_verdict not in ('ok', 'to_check') then
    raise exception 'verdict invalide : %', p_verdict using errcode = '22023';
  end if;
  insert into public.ai_reviews (request_id, verdict, checks, summary, model, tokens_in, tokens_out, cost_eur)
  values (p_request, p_verdict, coalesce(p_checks, '{}'::jsonb), p_summary, p_model,
          coalesce(p_tokens_in, 0), coalesce(p_tokens_out, 0), coalesce(p_cost_eur, 0));
  perform set_config('app.note', 'Contrôle IA : ' || p_verdict, true);
  update public.requests set status = 'manager_review'
   where id = p_request and status in ('pending', 'ai_review');
end $$;

revoke all on function public.check_request(uuid) from public, anon, authenticated;
revoke all on function public.ai_record_review(uuid, text, jsonb, text, text, int, int, numeric)
  from public, anon, authenticated;
grant execute on function public.check_request(uuid) to service_role;
grant execute on function public.ai_record_review(uuid, text, jsonb, text, text, int, int, numeric) to service_role;

do $$ begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime')
     and not exists (select 1 from pg_publication_tables
                     where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'ai_reviews') then
    alter publication supabase_realtime add table public.ai_reviews;
  end if;
end $$;
