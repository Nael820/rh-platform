-- Migration 6/6 — Mesure DORA (délais), goulots d'étranglement, coûts LLM, conservation RGPD.
-- Les vues sont en security_invoker : elles respectent le RLS de l'utilisateur qui les interroge.

create or replace view public.v_dora_lead_time with (security_invoker = true) as
select coalesce(t.label, 'Toutes les demandes') as type_label,
       count(*) as decided_count,
       round(avg(extract(epoch from (r.decided_at - r.created_at)) / 3600)::numeric, 2) as avg_hours,
       round((percentile_cont(0.5) within group
         (order by extract(epoch from (r.decided_at - r.created_at)) / 3600))::numeric, 2) as median_hours,
       round((percentile_cont(0.9) within group
         (order by extract(epoch from (r.decided_at - r.created_at)) / 3600))::numeric, 2) as p90_hours
from public.requests r
join public.request_types t on t.id = r.type_id
where r.decided_at is not null
group by rollup (t.label);

create or replace view public.v_stage_durations with (security_invoker = true) as
select s.new_status as status,
       count(*) as passages,
       round(avg(extract(epoch from s.d) / 3600)::numeric, 2) as avg_hours
from (
  select h.new_status,
         lead(h.changed_at) over (partition by h.request_id order by h.changed_at, h.id) - h.changed_at as d
  from public.request_history h
) s
where s.d is not null
group by s.new_status;

create or replace view public.v_ai_costs_monthly with (security_invoker = true) as
select date_trunc('month', created_at)::date as month,
       count(*)                 as reviews,
       sum(tokens_in)           as tokens_in,
       sum(tokens_out)          as tokens_out,
       round(sum(cost_eur), 4)  as cost_eur
from public.ai_reviews
group by 1;

-- RGPD : durée de conservation. Les demandes tranchées depuis plus de p_months mois sont supprimées
-- (l'historique et les contrôles IA suivent par cascade). À planifier avec pg_cron ou un workflow n8n.
create or replace function public.purge_old_requests(p_months int default 24)
returns int language plpgsql security definer set search_path = public as $$
declare n int;
begin
  delete from public.requests
   where decided_at is not null and decided_at < now() - make_interval(months => p_months);
  get diagnostics n = row_count;
  return n;
end $$;

revoke all on function public.purge_old_requests(int) from public, anon, authenticated;
grant execute on function public.purge_old_requests(int) to service_role;

comment on table public.requests        is 'Données personnelles (RGPD) : durée de conservation via purge_old_requests()';
comment on table public.ai_reviews      is 'Synthèses IA et coûts LLM ; l''IA ne décide jamais, elle pré-qualifie';
comment on table public.request_history is 'Traçabilité des changements de statut (qui, quand, motif)';
