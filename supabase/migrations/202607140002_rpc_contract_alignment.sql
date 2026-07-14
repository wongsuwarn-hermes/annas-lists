-- Align the hosted RPC argument names and response contract with the browser client.
-- The first migration was applied before these contract fixes, so this follow-up is
-- intentionally explicit and safe on both the hosted database and fresh resets.

drop function if exists public.create_cloud_trip(jsonb, text, text);
drop function if exists public.read_cloud_trip(text, text);
drop function if exists public.write_cloud_trip(text, text, bigint, jsonb);
drop function if exists public.claim_cloud_trip(text, text);
drop function if exists public.list_owned_cloud_trips();
drop function if exists public.rotate_cloud_trip_tokens(text, text, text);

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
