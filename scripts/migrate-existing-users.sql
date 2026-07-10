-- ============================================================
-- xvy — Migration des comptes EXISTANTS vers Supabase Auth.
-- À exécuter UNE FOIS, au moment de la bascule (avant ou juste après
-- cutover-security.sql). Ne casse rien avant : ajoute seulement des
-- entrées auth.users et lie profiles.auth_user_id.
--
-- Les anciens mots de passe (SHA-256) sont irrécupérables : on attribue
-- un mot de passe TEMPORAIRE commun. Chaque membre se connecte avec son
-- PSEUDO + ce mot de passe temporaire, puis le change dans Réglages.
--
-- Usage (SQL editor Supabase) :
--   select public.provision_existing_users('MotDePasseTemporaire123');
-- Renvoie le nombre de comptes provisionnés. Communique le mot de passe
-- temporaire à tes membres en privé, puis SUPPRIME cette fonction :
--   drop function public.provision_existing_users(text);
-- ============================================================

create or replace function public.provision_existing_users(temp_password text)
returns integer language plpgsql security definer set search_path = public, auth, extensions as $$
declare r record; v_id uuid; v_email text; n int := 0;
begin
  if char_length(coalesce(temp_password,'')) < 6 then raise exception 'temp_password: 6 caractères minimum'; end if;
  for r in
    select uid, username from public.profiles
    where auth_user_id is null and account_type='real' and deleted_at is null
    order by uid
  loop
    v_email := 'u'||regexp_replace(lower(r.username),'[^a-z0-9._-]','','g')||'@id.xvy.lol';
    -- collision d'e-mail éventuelle : suffixe l'uid
    if exists (select 1 from auth.users where email = v_email) then
      v_email := 'u'||regexp_replace(lower(r.username),'[^a-z0-9._-]','','g')||r.uid||'@id.xvy.lol';
    end if;
    v_id := gen_random_uuid();
    insert into auth.users (
      instance_id, id, aud, role, email, encrypted_password,
      email_confirmed_at, created_at, updated_at,
      raw_app_meta_data, raw_user_meta_data, is_super_admin,
      confirmation_token, recovery_token, email_change_token_new, email_change
    ) values (
      '00000000-0000-0000-0000-000000000000', v_id, 'authenticated', 'authenticated', v_email,
      extensions.crypt(temp_password, extensions.gen_salt('bf')),
      now(), now(), now(),
      '{"provider":"email","providers":["email"]}'::jsonb,
      jsonb_build_object('username', r.username),
      false, '', '', '', ''
    );
    insert into auth.identities (
      provider_id, user_id, identity_data, provider, last_sign_in_at, created_at, updated_at
    ) values (
      v_id::text, v_id,
      jsonb_build_object('sub', v_id::text, 'email', v_email),
      'email', now(), now(), now()
    );
    update public.profiles set auth_user_id = v_id where uid = r.uid;
    insert into public.profile_private (uid, email) values (r.uid, v_email)
      on conflict (uid) do update set email = excluded.email;
    n := n + 1;
  end loop;
  return n;
end $$;

-- Vérif post-migration :
--   select uid, username, auth_user_id is not null as linked from public.profiles order by uid;
