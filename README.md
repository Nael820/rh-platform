# Plateforme de gestion des demandes RH — NovaCorp (Fil Rouge M1 DFS)

Stack : Supabase (Postgres, Auth, RLS, Realtime) · React + Vite · n8n · LLM Gemini. Données fictives uniquement.

## Contenu
| Dossier | Quoi |
|---|---|
| `supabase/migrations/` | schéma, sécurité (RLS), routage manager→RH→DRH, validation par fonctions SQL, contrôle IA, vues DORA, purge RGPD |
| `supabase/seed.sql` | profils et solde de test |
| `supabase/tests/smoke.sql` | test de bout en bout (rollback à la fin) |
| `front/` | interface React (composants dans `src/components`) |
| `n8n/` | workflows exportés |
| `docs/` | dossier technique |

## Installer
```
npm i -g supabase
supabase login
supabase link --project-ref eljsnrtxyiypqaeirvwd
supabase db push
```
Puis créer 4 utilisateurs (manager, rh, drh, salarie @test.com) dans Authentication et exécuter `supabase/seed.sql`.
Front : `cd front && cp .env.example .env && npm install && npm run dev`.

## IA
`check_request` (SQL) valide dates, solde, doublons et niveau requis ; le LLM rédige seulement la synthèse ; `ai_record_review` trace tokens et coût.
L'IA ne décide jamais, l'humain valide.
