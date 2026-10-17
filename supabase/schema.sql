-- ============================================================
--  OpenTrack — self-hosted laptop anti-theft tracker
--  Supabase schema. Run this in the Supabase SQL editor.
--
--  Model: each registered user (Supabase Auth) owns one or more
--  devices. The PC agent authenticates per-device with an
--  agent_key via SECURITY DEFINER RPCs, so it never needs a
--  user login and the anon key is safe to ship in the agent.
--  Row Level Security keeps every user's data private to them.
-- ============================================================

create extension if not exists "pgcrypto";

-- ---------- Devices --------------------------------------------------
create table if not exists public.devices (
    id          uuid primary key default gen_random_uuid(),
    owner       uuid not null references auth.users (id) on delete cascade,
    name        text not null,
    agent_key   uuid not null default gen_random_uuid(),   -- secret, lives in the agent config
    created_at  timestamptz not null default now(),
    last_seen   timestamptz,
    -- command channel: set from the web dashboard, consumed by the agent
    lost_mode   boolean not null default false,
    lost_message text not null default '',
    want_photo  boolean not null default false
);

alter table public.devices enable row level security;

-- Owners can see / manage only their own devices from the dashboard.
create policy "owner can read devices"   on public.devices
    for select using (auth.uid() = owner);
create policy "owner can insert devices" on public.devices
    for insert with check (auth.uid() = owner);
create policy "owner can update devices" on public.devices
    for update using (auth.uid() = owner);
create policy "owner can delete devices" on public.devices
    for delete using (auth.uid() = owner);
-- Note: agent_key is only ever returned to the authenticated owner.

-- ---------- Location history ----------------------------------------
create table if not exists public.locations (
    id         bigserial primary key,
    device_id  uuid not null references public.devices (id) on delete cascade,
    ts         timestamptz not null default now(),
    lat        double precision,
    lng        double precision,
    accuracy   double precision,          -- meters, if known
    source     text,                      -- 'wifi' | 'ip' | 'gps'
    battery    int,                        -- percent, if known
    public_ip  text
);

alter table public.locations enable row level security;

create policy "owner can read locations" on public.locations
    for select using (
        exists (select 1 from public.devices d
                where d.id = locations.device_id and d.owner = auth.uid())
    );
-- Inserts happen only through report_location() (SECURITY DEFINER), never directly.

create index if not exists locations_device_ts_idx
    on public.locations (device_id, ts desc);

-- ---------- Evidence photos (lost mode) -----------------------------
create table if not exists public.photos (
    id         bigserial primary key,
    device_id  uuid not null references public.devices (id) on delete cascade,
    ts         timestamptz not null default now(),
    image      text        -- base64 JPEG (small webcam capture)
);

alter table public.photos enable row level security;

create policy "owner can read photos" on public.photos
    for select using (
        exists (select 1 from public.devices d
                where d.id = photos.device_id and d.owner = auth.uid())
    );
create policy "owner can delete photos" on public.photos
    for delete using (
        exists (select 1 from public.devices d
                where d.id = photos.device_id and d.owner = auth.uid())
    );

-- ============================================================
--  Agent-facing RPCs (SECURITY DEFINER).
--  The agent calls these with the anon key + its agent_key.
--  They validate the agent_key before touching any row, so the
--  anon role can never read or write arbitrary data.
-- ============================================================

-- Report a location sample and receive the current command state.
create or replace function public.report_location(
    p_device_id uuid,
    p_agent_key uuid,
    p_lat       double precision,
    p_lng       double precision,
    p_accuracy  double precision,
    p_source    text,
    p_battery   int,
    p_public_ip text
) returns json
language plpgsql
security definer
set search_path = public
as $$
declare
    v_dev public.devices%rowtype;
begin
    select * into v_dev from public.devices
        where id = p_device_id and agent_key = p_agent_key;
    if not found then
        raise exception 'invalid device credentials';
    end if;

    insert into public.locations (device_id, lat, lng, accuracy, source, battery, public_ip)
        values (p_device_id, p_lat, p_lng, p_accuracy, p_source, p_battery, p_public_ip);

    update public.devices set last_seen = now() where id = p_device_id;

    -- Free-tier guard: location rows are tiny, but cap history at 90 days.
    delete from public.locations
    where device_id = p_device_id and ts < now() - interval '90 days';

    return json_build_object(
        'lost_mode',    v_dev.lost_mode,
        'lost_message', v_dev.lost_message,
        'want_photo',   v_dev.want_photo
    );
end;
$$;

-- Upload one evidence photo and clear the want_photo flag.
create or replace function public.upload_photo(
    p_device_id uuid,
    p_agent_key uuid,
    p_image     text
) returns void
language plpgsql
security definer
set search_path = public
as $$
begin
    if not exists (select 1 from public.devices
                   where id = p_device_id and agent_key = p_agent_key) then
        raise exception 'invalid device credentials';
    end if;

    insert into public.photos (device_id, image) values (p_device_id, p_image);
    update public.devices set want_photo = false where id = p_device_id;

    -- Free-tier guard: keep only the newest 20 photos per device.
    delete from public.photos
    where device_id = p_device_id
      and id not in (
          select id from public.photos
          where device_id = p_device_id
          order by ts desc
          limit 20
      );
end;
$$;

-- Allow the anon role to call only these two functions.
grant execute on function public.report_location(uuid,uuid,double precision,double precision,double precision,text,int,text) to anon;
grant execute on function public.upload_photo(uuid,uuid,text) to anon;
