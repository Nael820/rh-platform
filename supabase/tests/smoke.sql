-- Test de bout en bout des règles métier. Rejouable sur une base locale où les migrations sont appliquées.
-- Simule des utilisateurs via les claims JWT (comme PostgREST). Toutes les données sont fictives.
\set ON_ERROR_STOP on
begin;

insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-0000000000a1', 'salarie@test.com'),
  ('00000000-0000-0000-0000-0000000000a2', 'manager@test.com'),
  ('00000000-0000-0000-0000-0000000000a3', 'rh@test.com'),
  ('00000000-0000-0000-0000-0000000000a4', 'drh@test.com'),
  ('00000000-0000-0000-0000-0000000000a5', 'autre@test.com');
insert into public.profiles (id, full_name, role, manager_id) values
  ('00000000-0000-0000-0000-0000000000a2', 'Marie Manager', 'manager', null),
  ('00000000-0000-0000-0000-0000000000a3', 'Rachid RH', 'hr', null),
  ('00000000-0000-0000-0000-0000000000a4', 'Diane DRH', 'drh', null),
  ('00000000-0000-0000-0000-0000000000a1', 'Sam Salarié', 'employee', '00000000-0000-0000-0000-0000000000a2'),
  ('00000000-0000-0000-0000-0000000000a5', 'Alex Autre', 'manager', null);
insert into public.leave_balances values ('00000000-0000-0000-0000-0000000000a1', 25);

create or replace function pg_temp.as_user(p_id text) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub', p_id, true);
  perform set_config('request.jwt.claim.role', 'authenticated', true);
end $$;

-- 1. Un salarié crée 3 demandes : routage selon type et montant ------------------------
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000000a1');
insert into public.requests (id, requester_id, type_id, start_date, end_date) values
  ('11111111-1111-1111-1111-111111111111', '00000000-0000-0000-0000-0000000000a1', 1, current_date + 10, current_date + 12);  -- 3 j  -> manager
insert into public.requests (id, requester_id, type_id, start_date, end_date) values
  ('22222222-2222-2222-2222-222222222222', '00000000-0000-0000-0000-0000000000a1', 1, current_date + 30, current_date + 44);  -- 15 j -> hr
insert into public.requests (id, requester_id, type_id, amount) values
  ('33333333-3333-3333-3333-333333333333', '00000000-0000-0000-0000-0000000000a1', 3, 2500);                                  -- 2500 € -> drh
do $$ begin
  assert (select required_level from public.requests where id = '11111111-1111-1111-1111-111111111111') = 'manager', 'routage 3 jours';
  assert (select required_level from public.requests where id = '22222222-2222-2222-2222-222222222222') = 'hr',      'routage 15 jours';
  assert (select required_level from public.requests where id = '33333333-3333-3333-3333-333333333333') = 'drh',     'routage 2500 EUR';
end $$;

-- 2. Un salarié ne peut pas s'auto-approuver ni forger un statut -----------------------
do $$ begin
  begin
    insert into public.requests (requester_id, type_id, amount, status)
    values ('00000000-0000-0000-0000-0000000000a1', 3, 100, 'approved');
    raise exception 'FAIL: insertion avec statut approved acceptée';
  exception when insufficient_privilege then null; end;   -- bloqué par la policy d'insertion
end $$;
update public.requests set status = 'approved' where id = '11111111-1111-1111-1111-111111111111';
do $$ begin
  assert (select status from public.requests where id = '11111111-1111-1111-1111-111111111111') = 'pending', 'update direct bloqué';
  begin perform public.approve_request('11111111-1111-1111-1111-111111111111');
        raise exception 'FAIL: auto-approbation acceptée';
  exception when insufficient_privilege then null; end;
end $$;

-- 3. Contrôles IA et enregistrement (rôle service_role) ---------------------------------
reset role;
set local role service_role;
do $$ declare c jsonb; begin
  c := public.check_request('22222222-2222-2222-2222-222222222222');
  assert (c->>'verdict') = 'ok', 'contrôle OK attendu';
  c := public.check_request('11111111-1111-1111-1111-111111111111');
  assert (c->>'balance_ok')::boolean, 'solde suffisant';
  perform public.ai_record_review('11111111-1111-1111-1111-111111111111', 'ok', c, 'Synthèse test', 'test-model', 1500, 200, 0.0007);
  perform public.ai_record_review('22222222-2222-2222-2222-222222222222', 'ok', '{}', 'Synthèse test', 'test-model', 1500, 200, 0.0007);
  perform public.ai_record_review('33333333-3333-3333-3333-333333333333', 'ok', '{}', 'Synthèse test', 'test-model', 1500, 200, 0.0007);
  assert (select status from public.requests where id = '11111111-1111-1111-1111-111111111111') = 'manager_review', 'passage manager_review';
end $$;
reset role;

-- 4. Doublon : une demande de congés qui chevauche la première est signalée ----------------
insert into public.requests (id, requester_id, type_id, start_date, end_date) values
  ('44444444-4444-4444-4444-444444444444', '00000000-0000-0000-0000-0000000000a1', 1, current_date + 11, current_date + 13);
set local role service_role;
do $$ declare c jsonb; begin
  c := public.check_request('44444444-4444-4444-4444-444444444444');
  assert (c->>'verdict') = 'to_check', 'doublon détecté';
  assert jsonb_array_length(c->'duplicate_ids') = 1, 'un doublon';
end $$;
reset role;

-- 5. Solde insuffisant détecté par le contrôle IA ------------------------------------------
insert into public.requests (id, requester_id, type_id, start_date, end_date) values
  ('55555555-5555-5555-5555-555555555555', '00000000-0000-0000-0000-0000000000a1', 1, current_date + 100, current_date + 140);  -- 41 j > 25
set local role service_role;
do $$ declare c jsonb; begin
  c := public.check_request('55555555-5555-5555-5555-555555555555');
  assert not (c->>'balance_ok')::boolean, 'solde insuffisant détecté';
end $$;
reset role;

-- 6. Validation multi-niveaux ---------------------------------------------------------------
set local role authenticated;
-- un manager étranger à l'équipe ne peut pas valider
select pg_temp.as_user('00000000-0000-0000-0000-0000000000a5');
do $$ begin
  begin perform public.approve_request('11111111-1111-1111-1111-111111111111');
        raise exception 'FAIL: manager étranger accepté';
  exception when insufficient_privilege then null; end;
end $$;
-- le bon manager valide la demande de 3 jours : approuvée directement, solde débité
select pg_temp.as_user('00000000-0000-0000-0000-0000000000a2');
do $$ begin
  assert public.approve_request('11111111-1111-1111-1111-111111111111', 'OK pour moi') = 'approved', 'approbation niveau manager';
  assert (select days_left from public.leave_balances where user_id = '00000000-0000-0000-0000-0000000000a1') = 22, 'solde débité (25-3)';
end $$;
-- la demande de 15 jours : manager -> RH
do $$ begin assert public.approve_request('22222222-2222-2222-2222-222222222222') = 'hr_review', 'manager vers RH'; end $$;
select pg_temp.as_user('00000000-0000-0000-0000-0000000000a3');
do $$ begin assert public.approve_request('22222222-2222-2222-2222-222222222222', 'Validé RH') = 'approved', 'RH approuve'; end $$;
-- la demande de 2500 EUR : manager -> RH -> DRH
select pg_temp.as_user('00000000-0000-0000-0000-0000000000a2');
do $$ begin assert public.approve_request('33333333-3333-3333-3333-333333333333') = 'hr_review', 'manager vers RH (2500)'; end $$;
select pg_temp.as_user('00000000-0000-0000-0000-0000000000a3');
do $$ begin assert public.approve_request('33333333-3333-3333-3333-333333333333') = 'drh_review', 'RH vers DRH'; end $$;
select pg_temp.as_user('00000000-0000-0000-0000-0000000000a4');
do $$ begin assert public.approve_request('33333333-3333-3333-3333-333333333333', 'Budget accordé') = 'approved', 'DRH approuve'; end $$;
-- un refus exige un motif
select pg_temp.as_user('00000000-0000-0000-0000-0000000000a2');
do $$ begin
  begin perform public.reject_request('44444444-4444-4444-4444-444444444444', '');
        raise exception 'FAIL: refus sans motif';
  exception when invalid_parameter_value then null; end;
  assert public.reject_request('44444444-4444-4444-4444-444444444444', 'Doublon') = 'rejected', 'refus avec motif';
end $$;

-- 7. Traçabilité et visibilité -----------------------------------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000000a3');
do $$ begin
  assert (select count(*) from public.request_history where request_id = '33333333-3333-3333-3333-333333333333') >= 5, 'historique complet';
  assert exists (select 1 from public.request_history where request_id = '33333333-3333-3333-3333-333333333333' and note = 'Budget accordé'), 'motif tracé';
  assert (select count(*) from public.requests) = 5, 'la RH voit toutes les demandes';
end $$;
select pg_temp.as_user('00000000-0000-0000-0000-0000000000a5');
do $$ begin assert (select count(*) from public.requests) = 0, 'un manager étranger ne voit rien'; end $$;

-- 8. Vues de mesure ------------------------------------------------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000000a3');
do $$ begin
  assert (select decided_count from public.v_dora_lead_time where type_label = 'Toutes les demandes') = 4, 'vue DORA';
  assert (select count(*) from public.v_stage_durations) >= 1, 'vue durées par étape';
  assert (select reviews from public.v_ai_costs_monthly limit 1) = 3, 'vue coûts IA';
end $$;
reset role;
select 'TOUS LES TESTS PASSENT' as resultat;
rollback;
