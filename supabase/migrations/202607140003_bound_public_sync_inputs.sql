-- Bound anonymous RPC inputs so a public capability endpoint cannot store oversized
-- snapshots or spend unbounded work hashing attacker-controlled token strings.

create or replace function public.cloud_token_hash(p_token text)
returns bytea
language plpgsql
immutable
strict
set search_path = pg_catalog, public, extensions
as $$
begin
  if char_length(p_token) < 32 or char_length(p_token) > 256 then
    raise exception using
      errcode = '22023',
      message = 'capability token must be between 32 and 256 characters';
  end if;

  return extensions.digest(p_token, 'sha256');
end;
$$;

create or replace function public.validate_cloud_trip_payload()
returns trigger
language plpgsql
set search_path = pg_catalog, public
as $$
begin
  if jsonb_typeof(new.payload) <> 'object' then
    raise exception using errcode = '22023', message = 'trip payload must be a JSON object';
  end if;

  if pg_column_size(new.payload) > 1048576 then
    raise exception using errcode = '22023', message = 'trip payload exceeds the 1 MiB limit';
  end if;

  return new;
end;
$$;

drop trigger if exists cloud_trips_validate_payload on public.cloud_trips;
create trigger cloud_trips_validate_payload
before insert or update of payload on public.cloud_trips
for each row execute function public.validate_cloud_trip_payload();

revoke all on function public.cloud_token_hash(text) from public, anon, authenticated;
revoke all on function public.validate_cloud_trip_payload() from public, anon, authenticated;
