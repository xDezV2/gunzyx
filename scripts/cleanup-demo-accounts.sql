-- Nettoyage manuel des comptes demo/test (xdez-network, Supabase SQL editor)
-- A utiliser si le bouton "Supprimer tous les comptes demo/test" du panel admin
-- n'est pas accessible, ou pour un nettoyage planifié (cron externe, etc.)

-- 1. Aperçu avant suppression
select uid, username, account_type, seed_batch, created_at
from public.profiles
where account_type in ('demo', 'test')
order by created_at desc;

-- 2. Suppression de tous les comptes demo/test (irréversible, pas de corbeille)
delete from public.profiles
where account_type in ('demo', 'test');

-- 3. Variante : ne nettoyer qu'un lot précis (remplacer la valeur de seed_batch)
-- delete from public.profiles where seed_batch = '2026-07-07T12:00:00.000Z';

-- 4. Trace de l'action dans les logs admin (facultatif, actor_uid à adapter)
insert into public.admin_logs (actor_uid, actor_name, action, new_value)
values (null, 'sql-script', 'cleanup_demo_accounts', 'nettoyage manuel via script SQL');
