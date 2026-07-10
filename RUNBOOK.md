# xvy — Refonte totale · Runbook de déploiement

Refonte réalisée sur la branche **`refonte`** (non déployée). `main` = prod live inchangée.

## Ce qui a changé

### Sécurité (backend Supabase `qasngtowguktqgjjajjy`, déjà appliqué en additif)
- Auth SHA-256 maison (cassable) → **Supabase Auth** (email/mot de passe + Discord).
- E-mails isolés dans `profile_private`. `profiles` reste public **sans fuite**.
- **~46 RPCs `SECURITY DEFINER`** : toutes les écritures passent par des fonctions qui vérifient identité/rôle.
- Edge function `ai` v2 : auth par JWT.

### Front (`index.html`, mono-fichier)
- Auth réécrite sur Supabase Auth ; toutes les écritures recâblées sur les RPCs.
- **Discover** (hub social), **Premium** (pricing + codes), **follow/notifications/analytics**, identité (nom affiché, pronoms, lieu, bannière), gating premium serveur.

## Déploiement / BASCULE (ordre strict)

> ⚠️ Ne PAS déployer le nouveau front sans avoir fait les étapes 1→3 : le login dépend de Supabase Auth.

### 1. Dashboard Supabase → Authentication → Providers
- **Email** : *Enabled* ; **Confirm email** : *OFF*
- **Discord** : *Enabled* (+ *Manual Linking* : ON si liaison Discord souhaitée)
- Policies → **Leaked password protection** : ON

### 2. Migrer les comptes existants (SQL editor)
```sql
-- copier le contenu de scripts/migrate-existing-users.sql, puis :
select public.provision_existing_users('UnMotDePasseTemporaire');
-- communiquer ce mdp temporaire aux membres (login = pseudo + ce mdp), puis :
drop function public.provision_existing_users(text);
```

### 3. Verrouiller la sécurité (SQL editor)
```sql
-- exécuter l'intégralité de scripts/cutover-security.sql
```
Puis vérifier : `get_advisors(security)` — résiduel attendu documenté en fin de script.

### 4. Déployer le front
```sh
git checkout main && git merge refonte && git push   # déclenche le déploiement Pages/Netlify
```

### 5. Vérifier en prod
- Créer un compte test (pseudo+mdp), login, login Discord, éditer le profil, follow, like, guestbook, notifications, analytics, redeem d'un code premium (en générer un via la page Premium en tant que staff).

## Rollback
- Front : `git revert` du merge (ou repointer Pages sur le commit précédent).
- DB : les policies permissives peuvent être recréées si besoin (voir historique migrations). Garder une fenêtre de test avant de supprimer définitivement.

## Reste (post-lancement, non bloquant)
- Harmonisation visuelle landing/dashboard existants.
- Upload de bannière (storage) ; feed d'activité des abonnements ; gating premium visuel dans l'éditeur d'effets.
