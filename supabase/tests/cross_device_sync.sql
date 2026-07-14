-- Cross-device sync RPC contract test.
-- Run after the migration with a local Supabase/Postgres admin connection:
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/cross_device_sync.sql
-- For Supabase CLI, start/reset first, then use the local DB URL shown by `supabase status`.
-- The test is transactional and rolls back its auth user and cloud trip fixture.

\set ON_ERROR_STOP on

begin;

-- Fixed, non-secret test fixtures. Each capability exceeds the >=32-character contract.
-- The auth fixture is needed because claim_cloud_trip persists auth.users(id).
insert into auth.users (id, aud, role, email, encrypted_password)
values
  (
    '11111111-1111-4111-8111-111111111111'::uuid,
    'authenticated',
    'authenticated',
    'cross-device-sync-contract@example.test',
    ''
  ),
  (
    '22222222-2222-4222-8222-222222222222'::uuid,
    'authenticated',
    'authenticated',
    'cross-device-sync-other-user@example.test',
    ''
  )
on conflict (id) do nothing;

-- No direct table grants or RLS policies are allowed. The RPC boundary is the only app path.
do $$
begin
  if has_table_privilege('anon', 'public.cloud_trips', 'select')
     or has_table_privilege('anon', 'public.cloud_trips', 'insert')
     or has_table_privilege('authenticated', 'public.cloud_trips', 'update') then
    raise exception 'cloud_trips direct app-role privileges must be revoked';
  end if;

  if exists (
    select 1 from pg_policies
    where schemaname = 'public' and tablename = 'cloud_trips'
  ) then
    raise exception 'cloud_trips must have no direct RLS policies';
  end if;
end;
$$;

set local role anon;

-- Guest creation works without an account and returns no capability secret.
select public.create_cloud_trip(
  '{"name":"Camp","groups":[]}'::jsonb,
  'read-token-0123456789abcdef-0123456789abcdef',
  'edit-token-0123456789abcdef-0123456789abcdef'
) ->> 'short_id' as short_id \gset
select set_config('test.cloud_trip_short_id', :'short_id', true);

do $$
declare
  v_short_id text := current_setting('test.cloud_trip_short_id');
begin
  if length(v_short_id) < 16 then
    raise exception 'short_id was not generated';
  end if;
end;
$$;

-- A read capability can read but cannot write.
do $$
declare
  v_short_id text := current_setting('test.cloud_trip_short_id');
  v_result jsonb;
begin
  v_result := public.read_cloud_trip(v_short_id, 'read-token-0123456789abcdef-0123456789abcdef');
  if v_result->>'status' <> 'ok'
     or (v_result->'payload')->>'name' <> 'Camp'
     or (v_result->>'version')::bigint <> 1 then
    raise exception 'read RPC did not return the initial snapshot';
  end if;

  begin
    perform public.write_cloud_trip(
      v_short_id,
      'read-token-0123456789abcdef-0123456789abcdef',
      1,
      '{"name":"read-only overwrite"}'::jsonb
    );
    raise exception 'read token unexpectedly wrote a trip';
  exception when insufficient_privilege then
    null;
  end;
end;
$$;

-- A valid edit capability atomically advances the version and returns saved.
do $$
declare
  v_short_id text := current_setting('test.cloud_trip_short_id');
  v_result jsonb;
begin
  v_result := public.write_cloud_trip(
    v_short_id,
    'edit-token-0123456789abcdef-0123456789abcdef',
    1,
    '{"name":"Edited on device A","groups":[{"name":"Tent"}]}'::jsonb
  );
  if v_result->>'status' <> 'saved'
     or (v_result->>'version')::bigint <> 2
     or (v_result->'payload')->>'name' <> 'Edited on device A' then
    raise exception 'successful write did not return saved version 2';
  end if;
end;
$$;

-- Stale optimistic write returns the server state and never mutates it.
do $$
declare
  v_short_id text := current_setting('test.cloud_trip_short_id');
  v_conflict jsonb;
  v_server jsonb;
begin
  v_conflict := public.write_cloud_trip(
    v_short_id,
    'edit-token-0123456789abcdef-0123456789abcdef',
    1,
    '{"name":"Stale device B overwrite"}'::jsonb
  );
  if v_conflict->>'status' <> 'conflict'
     or (v_conflict->>'version')::bigint <> 2
     or (v_conflict->'payload')->>'name' <> 'Edited on device A' then
    raise exception 'stale write did not return the authoritative conflict snapshot';
  end if;

  v_server := public.read_cloud_trip(v_short_id, 'edit-token-0123456789abcdef-0123456789abcdef');
  if (v_server->'payload')->>'name' <> 'Edited on device A'
     or (v_server->>'version')::bigint <> 2 then
    raise exception 'stale write mutated server data';
  end if;
end;
$$;

-- Optional ownership: capability use above needed no account; only authenticated users can claim.
reset role;
set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-111111111111', true);

do $$
declare
  v_short_id text := current_setting('test.cloud_trip_short_id');
  v_claim jsonb;
  v_owned_count integer;
begin
  v_claim := public.claim_cloud_trip(v_short_id, 'edit-token-0123456789abcdef-0123456789abcdef');
  if v_claim->>'status' <> 'claimed' then
    raise exception 'authenticated owner could not claim trip: %', v_claim;
  end if;

  select count(*) into v_owned_count
  from public.list_owned_cloud_trips()
  where short_id = v_short_id;
  if v_owned_count <> 1 then
    raise exception 'claimed trip was absent from owner listing';
  end if;
end;
$$;

-- An edit capability can claim an unowned trip but cannot steal it once it has an owner.
reset role;
set local role authenticated;
select set_config('request.jwt.claim.sub', '22222222-2222-4222-8222-222222222222', true);

do $$
declare
  v_short_id text := current_setting('test.cloud_trip_short_id');
begin
  begin
    perform public.claim_cloud_trip(v_short_id, 'edit-token-0123456789abcdef-0123456789abcdef');
    raise exception 'second authenticated user stole an owned trip';
  exception when insufficient_privilege then
    null;
  end;
end;
$$;

-- Rotation is owner-only and invalidates the previous read capability.
reset role;
set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-111111111111', true);

do $$
declare
  v_short_id text := current_setting('test.cloud_trip_short_id');
  v_rotation jsonb;
begin
  v_rotation := public.rotate_cloud_trip_tokens(
    v_short_id,
    'rotated-read-token-0123456789abcdef-012345',
    'rotated-edit-token-0123456789abcdef-012345'
  );
  if v_rotation->>'status' <> 'rotated' then
    raise exception 'owner token rotation failed: %', v_rotation;
  end if;
end;
$$;

reset role;
set local role anon;

do $$
declare
  v_short_id text := current_setting('test.cloud_trip_short_id');
  v_result jsonb;
begin
  begin
    perform public.read_cloud_trip(v_short_id, 'read-token-0123456789abcdef-0123456789abcdef');
    raise exception 'pre-rotation read token remained valid';
  exception when insufficient_privilege then
    null;
  end;

  v_result := public.read_cloud_trip(v_short_id, 'rotated-read-token-0123456789abcdef-012345');
  if v_result->>'status' <> 'ok'
     or (v_result->'payload')->>'name' <> 'Edited on device A' then
    raise exception 'rotated read token did not retrieve trip';
  end if;
end;
$$;

reset role;
rollback;

\echo 'cross_device_sync.sql: PASS'
