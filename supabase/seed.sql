-- Données fictives de démonstration. À jouer après avoir créé 3 utilisateurs dans Authentication > Users :
-- salarie@test.com, manager@test.com, rh@test.com, drh@test.com (Auto Confirm User coché).
-- Idempotent : ne fait rien pour les emails absents.
insert into public.profiles (id, full_name, role, manager_id)
select id, 'Marie Manager', 'manager', null from auth.users where email = 'manager@test.com'
on conflict (id) do nothing;

insert into public.profiles (id, full_name, role, manager_id)
select id, 'Rachid RH', 'hr', null from auth.users where email = 'rh@test.com'
on conflict (id) do nothing;

insert into public.profiles (id, full_name, role, manager_id)
select id, 'Diane DRH', 'drh', null from auth.users where email = 'drh@test.com'
on conflict (id) do nothing;

insert into public.profiles (id, full_name, role, manager_id)
select u.id, 'Sam Salarié', 'employee', m.id
from auth.users u, auth.users m
where u.email = 'salarie@test.com' and m.email = 'manager@test.com'
on conflict (id) do nothing;

insert into public.leave_balances (user_id, days_left)
select id, 25 from auth.users where email = 'salarie@test.com'
on conflict (user_id) do nothing;
