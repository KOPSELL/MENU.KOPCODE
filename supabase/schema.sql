-- MENU.KOPCODE | Execute once in Supabase SQL Editor.
-- Each restaurant owns its own data. Public visitors can read active menus and submit orders,
-- but can never read another customer's orders or access the admin tables.

create extension if not exists pgcrypto;

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  full_name text,
  phone text,
  created_at timestamptz not null default now()
);

create table if not exists public.restaurants (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null unique references auth.users(id) on delete cascade,
  name text not null,
  slug text not null unique,
  phone text not null default '',
  description text not null default '',
  logo_url text not null default '',
  cover_url text not null default '',
  address text not null default '',
  plan text not null default 'basic' check (plan in ('basic','pro','complete')),
  accent_color text not null default '#d97736',
  is_open boolean not null default true,
  created_at timestamptz not null default now()
);

create table if not exists public.categories (
  id uuid primary key default gen_random_uuid(),
  restaurant_id uuid not null references public.restaurants(id) on delete cascade,
  name text not null,
  sort_order integer not null default 0,
  created_at timestamptz not null default now(),
  unique (restaurant_id, name)
);

create table if not exists public.products (
  id uuid primary key default gen_random_uuid(),
  restaurant_id uuid not null references public.restaurants(id) on delete cascade,
  category_id uuid references public.categories(id) on delete set null,
  name text not null,
  description text not null default '',
  price numeric(12,2) not null default 0 check (price >= 0),
  image_url text not null default '',
  available boolean not null default true,
  featured boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.orders (
  id uuid primary key default gen_random_uuid(),
  restaurant_id uuid not null references public.restaurants(id) on delete cascade,
  customer_name text not null,
  customer_phone text not null,
  delivery_type text not null default 'delivery' check (delivery_type in ('delivery','pickup')),
  address text,
  notes text,
  total numeric(12,2) not null check (total >= 0),
  status text not null default 'new' check (status in ('new','preparing','ready','completed','cancelled')),
  created_at timestamptz not null default now()
);

create table if not exists public.order_items (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.orders(id) on delete cascade,
  product_id uuid references public.products(id) on delete set null,
  product_name text not null,
  unit_price numeric(12,2) not null check (unit_price >= 0),
  quantity integer not null check (quantity > 0),
  total numeric(12,2) not null check (total >= 0),
  created_at timestamptz not null default now()
);

create index if not exists categories_restaurant_idx on public.categories(restaurant_id, sort_order);
create index if not exists products_restaurant_idx on public.products(restaurant_id, available);
create index if not exists orders_restaurant_created_idx on public.orders(restaurant_id, created_at desc);
create index if not exists order_items_order_idx on public.order_items(order_id);

alter table public.profiles enable row level security;
alter table public.restaurants enable row level security;
alter table public.categories enable row level security;
alter table public.products enable row level security;
alter table public.orders enable row level security;
alter table public.order_items enable row level security;

-- Profiles: each authenticated user can access only their own profile.
drop policy if exists "profile owner read" on public.profiles;
create policy "profile owner read" on public.profiles for select to authenticated using (id = auth.uid());
drop policy if exists "profile owner insert" on public.profiles;
create policy "profile owner insert" on public.profiles for insert to authenticated with check (id = auth.uid());
drop policy if exists "profile owner update" on public.profiles;
create policy "profile owner update" on public.profiles for update to authenticated using (id = auth.uid()) with check (id = auth.uid());

-- Restaurant public data is used to render the customer's menu. Writes remain owner-only.
drop policy if exists "public can read restaurants" on public.restaurants;
create policy "public can read restaurants" on public.restaurants for select to anon, authenticated using (true);
drop policy if exists "owner creates restaurant" on public.restaurants;
create policy "owner creates restaurant" on public.restaurants for insert to authenticated with check (owner_id = auth.uid());
drop policy if exists "owner updates restaurant" on public.restaurants;
create policy "owner updates restaurant" on public.restaurants for update to authenticated using (owner_id = auth.uid()) with check (owner_id = auth.uid());
drop policy if exists "owner deletes restaurant" on public.restaurants;
create policy "owner deletes restaurant" on public.restaurants for delete to authenticated using (owner_id = auth.uid());

-- Categories and products: public read; only the restaurant owner may change them.
drop policy if exists "public reads categories" on public.categories;
create policy "public reads categories" on public.categories for select to anon, authenticated using (true);
drop policy if exists "owner manages categories" on public.categories;
create policy "owner manages categories" on public.categories for all to authenticated
using (exists (select 1 from public.restaurants r where r.id = restaurant_id and r.owner_id = auth.uid()))
with check (exists (select 1 from public.restaurants r where r.id = restaurant_id and r.owner_id = auth.uid()));

drop policy if exists "public reads products" on public.products;
create policy "public reads products" on public.products for select to anon, authenticated using (true);
drop policy if exists "owner manages products" on public.products;
create policy "owner manages products" on public.products for all to authenticated
using (exists (select 1 from public.restaurants r where r.id = restaurant_id and r.owner_id = auth.uid()))
with check (exists (select 1 from public.restaurants r where r.id = restaurant_id and r.owner_id = auth.uid()));

-- Customers can create an order for a restaurant. Only that restaurant's owner can read/update it.
drop policy if exists "customers submit orders" on public.orders;
create policy "customers submit orders" on public.orders for insert to anon, authenticated
with check (exists (select 1 from public.restaurants r where r.id = restaurant_id));
drop policy if exists "owner reads orders" on public.orders;
create policy "owner reads orders" on public.orders for select to authenticated
using (exists (select 1 from public.restaurants r where r.id = restaurant_id and r.owner_id = auth.uid()));
drop policy if exists "owner updates orders" on public.orders;
create policy "owner updates orders" on public.orders for update to authenticated
using (exists (select 1 from public.restaurants r where r.id = restaurant_id and r.owner_id = auth.uid()))
with check (exists (select 1 from public.restaurants r where r.id = restaurant_id and r.owner_id = auth.uid()));

-- Order item inserts are public only when attached to a valid order; only owner can read them.
drop policy if exists "customers add order items" on public.order_items;
create policy "customers add order items" on public.order_items for insert to anon, authenticated
with check (exists (select 1 from public.orders o where o.id = order_id));
drop policy if exists "owner reads order items" on public.order_items;
create policy "owner reads order items" on public.order_items for select to authenticated
using (exists (select 1 from public.orders o join public.restaurants r on r.id=o.restaurant_id where o.id=order_id and r.owner_id=auth.uid()));

-- Public image bucket. Uploads are isolated by first folder = restaurant UUID.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('restaurant-media','restaurant-media',true,5242880,array['image/jpeg','image/png','image/webp'])
on conflict (id) do update set public=true, file_size_limit=5242880, allowed_mime_types=array['image/jpeg','image/png','image/webp'];

drop policy if exists "public reads restaurant media" on storage.objects;
create policy "public reads restaurant media" on storage.objects for select to anon, authenticated using (bucket_id='restaurant-media');
drop policy if exists "restaurant owners upload media" on storage.objects;
create policy "restaurant owners upload media" on storage.objects for insert to authenticated
with check (bucket_id='restaurant-media' and exists (
  select 1 from public.restaurants r where r.id::text=(storage.foldername(name))[1] and r.owner_id=auth.uid()
));
drop policy if exists "restaurant owners update media" on storage.objects;
create policy "restaurant owners update media" on storage.objects for update to authenticated
using (bucket_id='restaurant-media' and exists (
  select 1 from public.restaurants r where r.id::text=(storage.foldername(name))[1] and r.owner_id=auth.uid()
))
with check (bucket_id='restaurant-media' and exists (
  select 1 from public.restaurants r where r.id::text=(storage.foldername(name))[1] and r.owner_id=auth.uid()
));
drop policy if exists "restaurant owners delete media" on storage.objects;
create policy "restaurant owners delete media" on storage.objects for delete to authenticated
using (bucket_id='restaurant-media' and exists (
  select 1 from public.restaurants r where r.id::text=(storage.foldername(name))[1] and r.owner_id=auth.uid()
));

-- Enable realtime for new order notifications in the admin panel.
do $$
begin
  alter publication supabase_realtime add table public.orders;
exception when duplicate_object then null;
when undefined_object then null;
end $$;


-- Atomic, price-safe checkout for Pro/Complete plans.
-- The browser sends only product IDs and quantities; prices/names are read from the database.
create or replace function public.submit_restaurant_order(
  p_restaurant_id uuid,
  p_customer_name text,
  p_customer_phone text,
  p_delivery_type text,
  p_address text,
  p_notes text,
  p_items jsonb
) returns uuid
language plpgsql
security definer
set search_path = pg_catalog, public
as $
declare
  v_order_id uuid;
  v_total numeric(12,2) := 0;
  v_item record;
  v_product public.products%rowtype;
  v_qty integer;
begin
  if length(trim(coalesce(p_customer_name,''))) < 2 then
    raise exception 'Informe seu nome.';
  end if;
  if length(regexp_replace(coalesce(p_customer_phone,''),'[^0-9]','','g')) < 8 then
    raise exception 'Informe um WhatsApp válido.';
  end if;
  if p_delivery_type not in ('delivery','pickup') then
    raise exception 'Tipo de entrega inválido.';
  end if;
  if p_delivery_type='delivery' and length(trim(coalesce(p_address,''))) < 4 then
    raise exception 'Informe o endereço de entrega.';
  end if;
  if coalesce(jsonb_typeof(p_items),'') <> 'array' or jsonb_array_length(p_items)=0 or jsonb_array_length(p_items)>50 then
    raise exception 'A sacola está vazia.';
  end if;
  if not exists(select 1 from public.restaurants where id=p_restaurant_id and is_open=true and plan in ('pro','complete')) then
    raise exception 'Restaurante indisponível para pedidos online.';
  end if;

  for v_item in select * from jsonb_to_recordset(p_items) as x(product_id uuid, quantity integer)
  loop
    v_qty := v_item.quantity;
    if v_qty is null or v_qty < 1 or v_qty > 50 then
      raise exception 'Quantidade inválida.';
    end if;
    select * into v_product from public.products
      where id=v_item.product_id and restaurant_id=p_restaurant_id and available=true;
    if not found then
      raise exception 'Um dos produtos não está mais disponível.';
    end if;
    v_total := v_total + (v_product.price * v_qty);
  end loop;

  insert into public.orders(restaurant_id,customer_name,customer_phone,delivery_type,address,notes,total,status)
  values(p_restaurant_id,trim(p_customer_name),trim(p_customer_phone),p_delivery_type,
    case when p_delivery_type='delivery' then trim(p_address) else null end,
    nullif(trim(coalesce(p_notes,'')),''),v_total,'new')
  returning id into v_order_id;

  for v_item in select * from jsonb_to_recordset(p_items) as x(product_id uuid, quantity integer)
  loop
    select * into v_product from public.products
      where id=v_item.product_id and restaurant_id=p_restaurant_id and available=true;
    insert into public.order_items(order_id,product_id,product_name,unit_price,quantity,total)
    values(v_order_id,v_product.id,v_product.name,v_product.price,v_item.quantity,v_product.price*v_item.quantity);
  end loop;
  return v_order_id;
end;
$$;

revoke all on function public.submit_restaurant_order(uuid,text,text,text,text,text,jsonb) from public;
grant execute on function public.submit_restaurant_order(uuid,text,text,text,text,text,jsonb) to anon, authenticated;


-- SECURITY HARDENING (safe to run again).
-- All order creation must pass through the atomic, price-validating RPC.
drop policy if exists "customers submit orders" on public.orders;
drop policy if exists "customers add order items" on public.order_items;
revoke insert on public.orders, public.order_items from anon, authenticated;

-- Do not expose the internal account-owner UUID to anonymous menu visitors.
-- Authenticated owners retain normal access subject to RLS.
revoke select on public.restaurants from anon;
grant select (
  id, name, slug, phone, description, logo_url, cover_url, address,
  plan, accent_color, is_open, created_at
) on public.restaurants to anon;

-- A product can only reference a category belonging to the same restaurant.
create or replace function public.validate_product_category_tenant()
returns trigger
language plpgsql
set search_path = pg_catalog, public
as $$
begin
  if new.category_id is not null and not exists (
    select 1 from public.categories c
    where c.id = new.category_id
      and c.restaurant_id = new.restaurant_id
  ) then
    raise exception 'A categoria selecionada não pertence a este restaurante.';
  end if;
  return new;
end;
$$;

drop trigger if exists validate_product_category_tenant on public.products;
create trigger validate_product_category_tenant
before insert or update of category_id, restaurant_id
on public.products
for each row execute function public.validate_product_category_tenant();
