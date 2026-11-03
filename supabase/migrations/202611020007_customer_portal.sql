-- MENU.KOPCODE | Central do Cliente para Premium e Gestão Completa
-- Execute no SQL Editor do projeto Supabase exclusivo do MENU.KOPCODE.

create extension if not exists pgcrypto;

create table if not exists public.restaurant_customers (
  id uuid primary key default gen_random_uuid(),
  restaurant_id uuid not null references public.restaurants(id) on delete cascade,
  customer_name text not null,
  customer_phone text not null,
  device_token_hash text not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (restaurant_id, device_token_hash)
);

create table if not exists public.restaurant_customer_addresses (
  id uuid primary key default gen_random_uuid(),
  customer_id uuid not null references public.restaurant_customers(id) on delete cascade,
  label text not null default 'Casa',
  address text not null,
  created_at timestamptz not null default now()
);

alter table public.orders
  add column if not exists customer_id uuid
  references public.restaurant_customers(id) on delete set null;

create index if not exists restaurant_customers_phone_idx
  on public.restaurant_customers(restaurant_id, customer_phone);
create index if not exists restaurant_customer_addresses_customer_idx
  on public.restaurant_customer_addresses(customer_id);
create index if not exists orders_customer_created_idx
  on public.orders(customer_id, created_at desc);

alter table public.restaurant_customers enable row level security;
alter table public.restaurant_customer_addresses enable row level security;

revoke all on public.restaurant_customers from anon, authenticated;
revoke all on public.restaurant_customer_addresses from anon, authenticated;

create or replace function public.customer_portal_register(
  p_restaurant_id uuid,
  p_customer_name text,
  p_customer_phone text,
  p_device_token text
) returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_customer public.restaurant_customers%rowtype;
  v_hash text;
begin
  if length(trim(coalesce(p_customer_name,''))) < 2 then
    raise exception 'Informe seu nome completo.';
  end if;
  if length(regexp_replace(coalesce(p_customer_phone,''),'[^0-9]','','g')) < 10 then
    raise exception 'Informe um celular válido com DDD.';
  end if;
  if length(coalesce(p_device_token,'')) < 30 then
    raise exception 'Não foi possível identificar este dispositivo. Atualize a página.';
  end if;
  if not exists (
    select 1 from public.restaurants
    where id=p_restaurant_id and plan in ('pro','complete')
  ) then
    raise exception 'A Central do Cliente está disponível nos planos Premium e Gestão Completa.';
  end if;

  v_hash := encode(digest(convert_to(p_device_token,'UTF8'),'sha256'),'hex');
  insert into public.restaurant_customers
    (restaurant_id,customer_name,customer_phone,device_token_hash)
  values
    (p_restaurant_id,trim(p_customer_name),trim(p_customer_phone),v_hash)
  on conflict (restaurant_id,device_token_hash)
  do update set
    customer_name=excluded.customer_name,
    customer_phone=excluded.customer_phone,
    updated_at=now()
  returning * into v_customer;

  return jsonb_build_object(
    'id',v_customer.id,
    'name',v_customer.customer_name,
    'phone',v_customer.customer_phone
  );
end;
$$;

create or replace function public.customer_portal_data(
  p_restaurant_id uuid,
  p_device_token text
) returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_customer public.restaurant_customers%rowtype;
  v_addresses jsonb;
  v_orders jsonb;
begin
  if length(coalesce(p_device_token,'')) < 30 then
    raise exception 'Sessão do cliente inválida.';
  end if;

  select * into v_customer
  from public.restaurant_customers
  where restaurant_id=p_restaurant_id
    and device_token_hash=encode(digest(convert_to(p_device_token,'UTF8'),'sha256'),'hex');

  if not found then
    raise exception 'Cliente não encontrado neste dispositivo.';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'id',a.id,'label',a.label,'address',a.address
  ) order by a.created_at desc),'[]'::jsonb)
  into v_addresses
  from public.restaurant_customer_addresses a
  where a.customer_id=v_customer.id;

  select coalesce(jsonb_agg(x.order_data order by x.created_at desc),'[]'::jsonb)
  into v_orders
  from (
    select o.created_at,
      jsonb_build_object(
        'id',o.id,'customer_name',o.customer_name,'customer_phone',o.customer_phone,
        'delivery_type',o.delivery_type,'address',o.address,'notes',o.notes,
        'total',o.total,'status',o.status,'created_at',o.created_at,
        'items',coalesce((
          select jsonb_agg(jsonb_build_object(
            'name',oi.product_name,'quantity',oi.quantity,'total',oi.total
          ) order by oi.created_at)
          from public.order_items oi where oi.order_id=o.id
        ),'[]'::jsonb)
      ) as order_data
    from public.orders o
    where o.restaurant_id=p_restaurant_id and o.customer_id=v_customer.id
    order by o.created_at desc
    limit 100
  ) x;

  return jsonb_build_object(
    'customer',jsonb_build_object(
      'id',v_customer.id,'name',v_customer.customer_name,'phone',v_customer.customer_phone
    ),
    'addresses',v_addresses,
    'orders',v_orders,
    'orders_count',jsonb_array_length(v_orders)
  );
end;
$$;

create or replace function public.customer_portal_save_address(
  p_restaurant_id uuid,
  p_device_token text,
  p_label text,
  p_address text
) returns uuid
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_customer_id uuid;
  v_address_id uuid;
begin
  select id into v_customer_id
  from public.restaurant_customers
  where restaurant_id=p_restaurant_id
    and device_token_hash=encode(digest(convert_to(p_device_token,'UTF8'),'sha256'),'hex');

  if v_customer_id is null then
    raise exception 'Faça seu acesso à Central do Cliente novamente.';
  end if;
  if length(trim(coalesce(p_address,''))) < 5 then
    raise exception 'Informe um endereço válido.';
  end if;

  insert into public.restaurant_customer_addresses(customer_id,label,address)
  values(v_customer_id,coalesce(nullif(trim(p_label),''),'Casa'),trim(p_address))
  returning id into v_address_id;

  return v_address_id;
end;
$$;

create or replace function public.submit_restaurant_order_for_customer(
  p_restaurant_id uuid,
  p_customer_name text,
  p_customer_phone text,
  p_delivery_type text,
  p_address text,
  p_notes text,
  p_items jsonb,
  p_device_token text
) returns uuid
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_customer_id uuid;
  v_order_id uuid;
begin
  select id into v_customer_id
  from public.restaurant_customers
  where restaurant_id=p_restaurant_id
    and device_token_hash=encode(digest(convert_to(p_device_token,'UTF8'),'sha256'),'hex');

  if v_customer_id is null then
    raise exception 'Identifique-se novamente para concluir o pedido.';
  end if;

  v_order_id := public.submit_restaurant_order(
    p_restaurant_id,p_customer_name,p_customer_phone,
    p_delivery_type,p_address,p_notes,p_items
  );

  update public.orders
  set customer_id=v_customer_id
  where id=v_order_id and restaurant_id=p_restaurant_id;

  if p_delivery_type='delivery' and length(trim(coalesce(p_address,''))) >= 5
     and not exists (
       select 1 from public.restaurant_customer_addresses
       where customer_id=v_customer_id and lower(address)=lower(trim(p_address))
     ) then
    insert into public.restaurant_customer_addresses(customer_id,label,address)
    values(v_customer_id,'Entrega',trim(p_address));
  end if;

  return v_order_id;
end;
$$;

revoke all on function public.customer_portal_register(uuid,text,text,text) from public;
revoke all on function public.customer_portal_data(uuid,text) from public;
revoke all on function public.customer_portal_save_address(uuid,text,text,text) from public;
revoke all on function public.submit_restaurant_order_for_customer(uuid,text,text,text,text,text,jsonb,text) from public;

grant execute on function public.customer_portal_register(uuid,text,text,text) to anon, authenticated;
grant execute on function public.customer_portal_data(uuid,text) to anon, authenticated;
grant execute on function public.customer_portal_save_address(uuid,text,text,text) to anon, authenticated;
grant execute on function public.submit_restaurant_order_for_customer(uuid,text,text,text,text,text,jsonb,text) to anon, authenticated;
