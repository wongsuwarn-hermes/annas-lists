-- Anna's Lists cross-device sync: capability-link access plus optional ownership.
-- Tokens are accepted only by RPCs and persisted as SHA-256 digests, never plaintext.

create schema if not exists extensions;
create extension if not exists pgcrypto with schema extensions;

create table if not exists public.cloud_trips (
  id uuid primary key default extensions.gen_random_uuid(),
  short_id text not null unique,
  owner_id uuid references auth.users (id) on delete set null,
  payload jsonb not null,
  version bigint not null default 1 check (version >= 1),
  read_token_hash bytea not null check (octet_length(read_token_hash) = 32),
  edit_token_hash bytea not null check (octet_length(edit_token_hash) = 32),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (read_token_hash <> edit_token_hash)
);

comment on table public.cloud_trips is
  'Versioned cloud trip snapshots. Capability tokens are never stored; only SHA-256 digests are retained.';

create index if not exists cloud_trips_owner_id_updated_at_idx
  on public.cloud_trips (owner_id, updated_at desc)
  where owner_id is not null;

create or replace function public.set_cloud_trip_updated_at()
returns trigger
language plpgsql
set search_path = pg_catalog, public
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

drop trigger if exists cloud_trips_set_updated_at on public.cloud_trips;
create trigger cloud_trips_set_updated_at
before update on public.cloud_trips
for each row execute function public.set_cloud_trip_updated_at();

-- Functions below deliberately use SECURITY DEFINER because RLS has no table policies.
-- Each function authorizes its own narrow operation and fixes search_path to trusted schemas.
create or replace function public.cloud_token_hash(p_token text)
returns bytea
language plpgsql
immutable
strict
set search_path = pg_catalog, public, extensions
as $$
begin
  if char_length(p_token) < 32 then
    raise exception using
      errcode = '22023',
      message = 'capability token must be at least 32 characters';
  end if;

  return extensions.digest(p_token, 'sha256');
end;
$$;

create or replace function public.new_cloud_trip_short_id()
returns text
language sql
volatile
set search_path = pg_catalog, public, extensions
as $$
  select encode(extensions.gen_random_bytes(12), 'hex')
$$;

create or replace function public.create_cloud_trip(
  p_data jsonb,
  p_read_token text,
  p_edit_token text
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, extensions
as $$
declare
  v_short_id text;
  v_read_hash bytea;
  v_edit_hash bytea;
  v_trip public.cloud_trips%rowtype;
begin
  if p_data is null then
    raise exception using errcode = '22023', message = 'trip payload is required';
  end if;

  v_read_hash := public.cloud_token_hash(p_read_token);
  v_edit_hash := public.cloud_token_hash(p_edit_token);
  if v_read_hash = v_edit_hash then
    raise exception using errcode = '22023', message = 'read and edit capability tokens must differ';
  end if;

  -- A 96-bit random short ID makes collisions exceptionally unlikely; retain a retry for
  -- the unique constraint so concurrent creation remains correct if one ever occurs.
  loop
    v_short_id := public.new_cloud_trip_short_id();
    begin
      insert into public.cloud_trips (short_id, owner_id, payload, read_token_hash, edit_token_hash)
      values (v_short_id, auth.uid(), p_data, v_read_hash, v_edit_hash)
      returning * into v_trip;
      exit;
    exception when unique_violation then
      null;
    end;
  end loop;

  return jsonb_build_object(
    'status', 'created',
    'short_id', v_trip.short_id,
    'version', v_trip.version,
    'payload', v_trip.payload,
    'created_at', v_trip.created_at,
    'updated_at', v_trip.updated_at
  );
end;
$$;

create or replace function public.read_cloud_trip(
  p_short_id text,
  p_token text
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, extensions
as $$
declare
  v_trip public.cloud_trips%rowtype;
  v_token_hash bytea;
begin
  v_token_hash := public.cloud_token_hash(p_token);

  select * into v_trip
  from public.cloud_trips
  where short_id = p_short_id;

  if not found
     or (v_trip.read_token_hash <> v_token_hash and v_trip.edit_token_hash <> v_token_hash) then
    raise exception using errcode = '42501', message = 'invalid trip capability';
  end if;

  return jsonb_build_object(
    'status', 'ok',
    'short_id', v_trip.short_id,
    'version', v_trip.version,
    'payload', v_trip.payload,
    'can_edit', v_trip.edit_token_hash = v_token_hash,
    'is_owner', v_trip.owner_id is not null and v_trip.owner_id = auth.uid(),
    'owner_id', v_trip.owner_id,
    'created_at', v_trip.created_at,
    'updated_at', v_trip.updated_at
  );
end;
$$;

create or replace function public.write_cloud_trip(
  p_short_id text,
  p_edit_token text,
  p_expected_version bigint,
  p_data jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, extensions
as $$
declare
  v_trip public.cloud_trips%rowtype;
  v_saved public.cloud_trips%rowtype;
  v_token_hash bytea;
begin
  if p_expected_version is null or p_expected_version < 1 then
    raise exception using errcode = '22023', message = 'expected version must be at least 1';
  end if;
  if p_data is null then
    raise exception using errcode = '22023', message = 'trip payload is required';
  end if;

  v_token_hash := public.cloud_token_hash(p_edit_token);
  select * into v_trip from public.cloud_trips where short_id = p_short_id;
  if not found or v_trip.edit_token_hash <> v_token_hash then
    raise exception using errcode = '42501', message = 'invalid edit capability';
  end if;

  update public.cloud_trips
  set payload = p_data,
      version = version + 1
  where short_id = p_short_id
    and edit_token_hash = v_token_hash
    and version = p_expected_version
  returning * into v_saved;

  if found then
    return jsonb_build_object(
      'status', 'saved',
      'short_id', v_saved.short_id,
      'version', v_saved.version,
      'payload', v_saved.payload,
      'updated_at', v_saved.updated_at
    );
  end if;

  -- Re-read only after capability verification. This returns the authoritative snapshot
  -- for client-side recovery-copy handling and never overwrites a stale writer.
  select * into v_trip from public.cloud_trips where short_id = p_short_id;
  return jsonb_build_object(
    'status', 'conflict',
    'short_id', v_trip.short_id,
    'version', v_trip.version,
    'payload', v_trip.payload,
    'updated_at', v_trip.updated_at
  );
end;
$$;

create or replace function public.claim_cloud_trip(
  p_short_id text,
  p_edit_token text
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, extensions
as $$
declare
  v_user_id uuid := auth.uid();
  v_trip public.cloud_trips%rowtype;
  v_claimed public.cloud_trips%rowtype;
  v_token_hash bytea;
begin
  if v_user_id is null then
    raise exception using errcode = '42501', message = 'authentication is required to claim a trip';
  end if;

  v_token_hash := public.cloud_token_hash(p_edit_token);
  select * into v_trip from public.cloud_trips where short_id = p_short_id;
  if not found or v_trip.edit_token_hash <> v_token_hash then
    raise exception using errcode = '42501', message = 'invalid edit capability';
  end if;

  update public.cloud_trips
  set owner_id = v_user_id
  where short_id = p_short_id
    and owner_id is null
  returning * into v_claimed;

  if found then
    return jsonb_build_object('status', 'claimed', 'short_id', v_claimed.short_id);
  end if;

  select * into v_trip from public.cloud_trips where short_id = p_short_id;
  if v_trip.owner_id = v_user_id then
    return jsonb_build_object('status', 'already_claimed', 'short_id', v_trip.short_id);
  end if;

  raise exception using errcode = '42501', message = 'trip is already owned';
end;
$$;

create or replace function public.list_owned_cloud_trips()
returns table (
  short_id text,
  payload jsonb,
  version bigint,
  created_at timestamptz,
  updated_at timestamptz
)
language plpgsql
security definer
set search_path = pg_catalog, public, extensions
as $$
declare
  v_user_id uuid := auth.uid();
begin
  if v_user_id is null then
    raise exception using errcode = '42501', message = 'authentication is required to list owned trips';
  end if;

  return query
  select t.short_id, t.payload, t.version, t.created_at, t.updated_at
  from public.cloud_trips t
  where t.owner_id = v_user_id
  order by t.updated_at desc;
end;
$$;

create or replace function public.rotate_cloud_trip_tokens(
  p_short_id text,
  p_new_read_token text,
  p_new_edit_token text
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, extensions
as $$
declare
  v_user_id uuid := auth.uid();
  v_read_hash bytea;
  v_edit_hash bytea;
  v_trip public.cloud_trips%rowtype;
begin
  if v_user_id is null then
    raise exception using errcode = '42501', message = 'authentication is required to rotate trip capabilities';
  end if;

  v_read_hash := public.cloud_token_hash(p_new_read_token);
  v_edit_hash := public.cloud_token_hash(p_new_edit_token);
  if v_read_hash = v_edit_hash then
    raise exception using errcode = '22023', message = 'read and edit capability tokens must differ';
  end if;

  update public.cloud_trips
  set read_token_hash = v_read_hash,
      edit_token_hash = v_edit_hash
  where short_id = p_short_id
    and owner_id = v_user_id
  returning * into v_trip;

  if not found then
    raise exception using errcode = '42501', message = 'only the trip owner may rotate capabilities';
  end if;

  return jsonb_build_object(
    'status', 'rotated',
    'short_id', v_trip.short_id,
    'updated_at', v_trip.updated_at
  );
end;
$$;

alter table public.cloud_trips enable row level security;

-- No direct-table policies: every app operation must traverse the RPC boundary.
revoke all on table public.cloud_trips from public, anon, authenticated;
-- Helper functions are implementation details; only the named RPC contract is callable.
revoke all on function public.cloud_token_hash(text) from public, anon, authenticated;
revoke all on function public.new_cloud_trip_short_id() from public, anon, authenticated;
revoke all on function public.create_cloud_trip(jsonb, text, text) from public;
revoke all on function public.read_cloud_trip(text, text) from public;
revoke all on function public.write_cloud_trip(text, text, bigint, jsonb) from public;
revoke all on function public.claim_cloud_trip(text, text) from public;
revoke all on function public.list_owned_cloud_trips() from public;
revoke all on function public.rotate_cloud_trip_tokens(text, text, text) from public;

grant execute on function public.create_cloud_trip(jsonb, text, text) to anon, authenticated;
grant execute on function public.read_cloud_trip(text, text) to anon, authenticated;
grant execute on function public.write_cloud_trip(text, text, bigint, jsonb) to anon, authenticated;
grant execute on function public.claim_cloud_trip(text, text) to authenticated;
grant execute on function public.list_owned_cloud_trips() to authenticated;
grant execute on function public.rotate_cloud_trip_tokens(text, text, text) to authenticated;
