-- Let authenticated owners recover and edit their trips on a new device even when
-- that browser no longer has the original capability secret. Guests still require
-- an unguessable capability. This migration also reports ownership at creation.

drop function if exists public.create_cloud_trip(jsonb, text, text);
drop function if exists public.read_cloud_trip(text, text);
drop function if exists public.write_cloud_trip(text, text, bigint, jsonb);

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
    'is_owner', v_trip.owner_id is not null and v_trip.owner_id = auth.uid(),
    'created_at', v_trip.created_at,
    'updated_at', v_trip.updated_at
  );
end;
$$;

create or replace function public.read_cloud_trip(
  p_short_id text,
  p_token text default null
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, extensions
as $$
declare
  v_trip public.cloud_trips%rowtype;
  v_token_hash bytea;
  v_is_owner boolean;
begin
  select * into v_trip from public.cloud_trips where short_id = p_short_id;
  if not found then
    raise exception using errcode = '42501', message = 'invalid trip capability';
  end if;

  v_is_owner := auth.uid() is not null and v_trip.owner_id = auth.uid();
  if p_token is not null then
    v_token_hash := public.cloud_token_hash(p_token);
  end if;

  if not v_is_owner
     and (v_token_hash is null
       or (v_trip.read_token_hash <> v_token_hash and v_trip.edit_token_hash <> v_token_hash)) then
    raise exception using errcode = '42501', message = 'invalid trip capability';
  end if;

  return jsonb_build_object(
    'status', 'ok',
    'short_id', v_trip.short_id,
    'version', v_trip.version,
    'payload', v_trip.payload,
    'can_edit', v_is_owner or v_trip.edit_token_hash = v_token_hash,
    'is_owner', v_is_owner,
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
  v_is_owner boolean;
begin
  if p_expected_version is null or p_expected_version < 1 then
    raise exception using errcode = '22023', message = 'expected version must be at least 1';
  end if;
  if p_data is null then
    raise exception using errcode = '22023', message = 'trip payload is required';
  end if;

  select * into v_trip from public.cloud_trips where short_id = p_short_id;
  if not found then
    raise exception using errcode = '42501', message = 'invalid edit capability';
  end if;

  v_is_owner := auth.uid() is not null and v_trip.owner_id = auth.uid();
  if p_edit_token is not null then
    v_token_hash := public.cloud_token_hash(p_edit_token);
  end if;
  if not v_is_owner and (v_token_hash is null or v_trip.edit_token_hash <> v_token_hash) then
    raise exception using errcode = '42501', message = 'invalid edit capability';
  end if;

  update public.cloud_trips
  set payload = p_data,
      version = version + 1
  where short_id = p_short_id
    and version = p_expected_version
    and (owner_id = auth.uid() or edit_token_hash = v_token_hash)
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

revoke all on function public.create_cloud_trip(jsonb, text, text) from public;
revoke all on function public.read_cloud_trip(text, text) from public;
revoke all on function public.write_cloud_trip(text, text, bigint, jsonb) from public;
grant execute on function public.create_cloud_trip(jsonb, text, text) to anon, authenticated;
grant execute on function public.read_cloud_trip(text, text) to anon, authenticated;
grant execute on function public.write_cloud_trip(text, text, bigint, jsonb) to anon, authenticated;
