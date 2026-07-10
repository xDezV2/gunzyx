-- ============================================================
-- xvy — BASCULE SÉCURITÉ (à appliquer AU MOMENT du déploiement du
-- nouveau front, PAS avant : ce script casse volontairement l'accès
-- direct anon aux écritures dont dépend l'ANCIEN front.
--
-- ÉTAPE 2 : à lancer APRÈS scripts/1-provision.sql, dans Supabase > SQL Editor.
-- (L'inscription passe par la fonction serveur `signup` -> aucun réglage Auth
--  dashboard requis. Optionnel : activer "Leaked password protection".)
-- Email + Discord sont déjà activés côté Auth.
-- ============================================================

begin;

-- ---------- PROFILES : plus AUCUNE écriture directe client ----------
drop policy if exists "Anyone can update profiles"  on public.profiles;
drop policy if exists "Anyone can delete profiles"  on public.profiles;
drop policy if exists "Anyone can create a profile" on public.profiles;
-- lecture publique conservée ("Profiles are publicly readable")
-- NB: auth_user_id (UUID inoffensif) reste lisible ; staff_note idem pour l'instant
-- (à déplacer vers profile_private dans une itération future — non bloquant).

-- le hash SHA-256 (crown jewel) disparaît définitivement
-- signup_profile n'en a plus besoin :
create or replace function public.signup_profile(p_username text, p_display text default '')
returns public.profiles language plpgsql security definer set search_path = public as $$
declare v_row public.profiles; v_name text := trim(p_username);
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if exists (select 1 from public.profiles where auth_user_id = auth.uid()) then raise exception 'profile already exists'; end if;
  if char_length(v_name) < 2 or char_length(v_name) > 20 then raise exception 'invalid username length'; end if;
  if v_name !~ '^[A-Za-z0-9_.]+$' then raise exception 'invalid username chars'; end if;
  if exists (select 1 from public.profiles where lower(username)=lower(v_name)) then raise exception 'username taken'; end if;
  insert into public.profiles (username, tag, bio, accent, links, theme, display_name, auth_user_id, account_type)
  values (v_name, '@'||lower(v_name), 'Nouveau membre.', '#8fb39d', '[]'::jsonb, 'glass',
          coalesce(nullif(trim(p_display),''), v_name), auth.uid(), 'real')
  returning * into v_row;
  insert into public.profile_private (uid, email) values (v_row.uid, (select email from auth.users where id = auth.uid())) on conflict (uid) do nothing;
  if (select count(*) from public.profiles) = 1 then
    update public.profiles set role='superadmin', is_admin=true where uid = v_row.uid returning * into v_row;
  end if;
  return v_row;
end $$;

alter table public.profiles drop column if exists password_hash;

-- ---------- GUESTBOOK : lecture publique, écriture via RPC ----------
drop policy if exists "guestbook insert" on public.guestbook;
drop policy if exists "guestbook delete" on public.guestbook;
-- "guestbook read" (select true) conservé

-- ---------- GAME_SCORES : lecture publique, écriture via RPC ----------
drop policy if exists "scores insert" on public.game_scores;
drop policy if exists "scores delete" on public.game_scores;

-- ---------- POLL_VOTES : lecture publique (tally), écriture via RPC ----------
drop policy if exists "poll_votes insert" on public.poll_votes;
-- unicité d'un vote par votant/profil/sondage : on ne peut pas connaître le votant
-- (pas de colonne voter) -> on garde l'anti-abus applicatif + rate-limit RPC.

-- ---------- PROFILE_EVENTS : privé, tout via RPC (track_event / my_analytics) ----------
drop policy if exists "events insert" on public.profile_events;
drop policy if exists "events read"   on public.profile_events;

-- ---------- ADMIN_LOGS : lecture staff, écriture via RPC ----------
drop policy if exists "admin_logs insert" on public.admin_logs;
drop policy if exists "admin_logs read"   on public.admin_logs;
create policy "admin_logs read staff" on public.admin_logs for select using (public.is_staff());

-- ---------- BADGE_DEFS : lecture publique, écriture via RPC ----------
drop policy if exists "badge_defs write" on public.badge_defs;
-- "badge_defs public read" conservé

-- ---------- BADGE_GRANTS : lecture publique, écriture via RPC ----------
drop policy if exists "badge_grants write" on public.badge_grants;

-- ---------- APP_SETTINGS : lecture publique (flags non secrets), écriture via RPC ----------
drop policy if exists "app_settings write" on public.app_settings;
-- "app_settings read" conservé

-- ---------- STORAGE backgrounds : chacun n'écrit que son fichier bg-<uid>.mp4 ----------
drop policy if exists "backgrounds public insert" on storage.objects;
drop policy if exists "backgrounds public update" on storage.objects;
drop policy if exists "backgrounds public delete" on storage.objects;
drop policy if exists "backgrounds public read"   on storage.objects; -- bucket public => URL directe, pas besoin de listing
create policy "backgrounds owner insert" on storage.objects for insert to authenticated
  with check (bucket_id='backgrounds' and name = 'bg-'||public.my_uid()||'.mp4');
create policy "backgrounds owner update" on storage.objects for update to authenticated
  using (bucket_id='backgrounds' and name = 'bg-'||public.my_uid()||'.mp4');
create policy "backgrounds owner delete" on storage.objects for delete to authenticated
  using (bucket_id='backgrounds' and name = 'bg-'||public.my_uid()||'.mp4');

-- ---------- DURCISSEMENT : exécution des RPCs SECURITY DEFINER par rôle ----------
-- Par défaut une fonction est exécutable par PUBLIC (donc anon). On restreint :
-- seules 'authenticated' (et 3 fonctions publiques pour anon) peuvent les appeler.
do $$
declare f record;
begin
  for f in
    select p.oid::regprocedure as sig
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname='public' and p.prosecdef
      -- garder exécutables : compteurs hérités (site) + helpers utilisés DANS les policies RLS
      and p.proname not in ('increment_views','increment_likes','decrement_likes','set_first_admin',
                            'my_uid','my_role','is_staff','track_event','auth_email_for_login','public_profiles')
  loop
    execute format('revoke execute on function %s from public', f.sig);
    execute format('revoke execute on function %s from anon', f.sig);
    execute format('grant execute on function %s to authenticated', f.sig);
  end loop;
end $$;
-- accès anonyme explicite uniquement pour les fonctions réellement publiques
grant execute on function public.track_event(bigint,text,jsonb,text) to anon;
grant execute on function public.auth_email_for_login(text) to anon;
grant execute on function public.public_profiles(bigint[]) to anon;

commit;

-- Après COMMIT : lancer get_advisors(security). Résiduel attendu :
--   - rls_enabled_no_policy sur ai_config (intentionnel : accès service_role uniquement)
--   - auth_leaked_password_protection (à activer dans le dashboard Auth)
--   - quelques fonctions encore anon-exécutables (increment_* héritées + les 3 publiques) : OK.
