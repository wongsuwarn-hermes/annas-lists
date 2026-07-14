# Anna's Lists Supabase backend

The production project is `dmnzxxnauzcggrfiwkaw` in `eu-west-2` (London).

## Security model

- Browser clients receive only the public project URL and publishable key from `config/public-config.json`.
- Capability secrets are generated in the browser, kept in URL fragments/local metadata, and stored by Postgres only as SHA-256 hashes.
- `cloud_trips` has RLS enabled and no direct app-role policies or grants. Browser operations use the narrow security-definer RPCs in the migrations.
- Service-role keys and the database password must never enter this repository or browser output.
- Public RPC payloads are limited to JSON objects no larger than 1 MiB; capability strings are limited to 32–256 characters.

## Apply configuration and migrations

```sh
npx --yes supabase@latest login
npx --yes supabase@latest link --project-ref dmnzxxnauzcggrfiwkaw
npx --yes supabase@latest db push
npx --yes supabase@latest config push
```

Do not pass database credentials in committed scripts. The operator copy is stored outside the repository.

## Verification

Dependency-free hosted capability test:

```sh
npm run test:hosted
```

The authenticated owner contract can be checked with `scripts/verify-hosted-owner-db.py` using a temporary Python environment with `psycopg[binary]` and `SUPABASE_DB_PASSWORD` supplied at runtime. It runs transactionally and rolls back its users and trip.

`supabase/tests/cross_device_sync.sql` is the equivalent transactional psql contract test.

## Authentication providers

- Email magic-link authentication: enabled.
- Google OAuth: intentionally disabled until a dedicated production Google web OAuth client and secret are configured.
- Email/password UI: not implemented and must not be added.

Canonical production Auth URL and redirect allowlist are defined in `supabase/config.toml`.
