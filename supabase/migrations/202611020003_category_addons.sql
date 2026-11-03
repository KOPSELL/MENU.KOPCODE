-- MENU.KOPCODE: adicionais vinculados a uma ou mais categorias.
create table if not exists public.additional_options (
  id uuid primary key default gen_random_uuid(),
  restaurant_id uuid not null references public.restaurants(id) on delete cascade,
  name text not null,
  price numeric(12,2) not null default 0 check (price >= 0),
  active boolean not null default true,
  created_at timestamptz not null default now(),
  unique (restaurant_id, name)
);
create table if not exists public.additional_option_categories (
  restaurant_id uuid not null references public.restaurants(id) on delete cascade,
  additional_option_id uuid not null references public.additional_options(id) on delete cascade,
  category_id uuid not null references public.categories(id) on delete cascade,
  primary key (additional_option_id, category_id)
);
alter table public.additional_options enable row level security;
alter table public.additional_option_categories enable row level security;
drop policy if exists "public reads active additional options" on public.additional_options;
create policy "public reads active additional options" on public.additional_options for select to anon, authenticated using (active = true);
drop policy if exists "owner manages additional options" on public.additional_options;
create policy "owner manages additional options" on public.additional_options for all to authenticated
using (exists(select 1 from public.restaurants r where r.id=restaurant_id and r.owner_id=auth.uid()))
with check (exists(select 1 from public.restaurants r where r.id=restaurant_id and r.owner_id=auth.uid()));
drop policy if exists "public reads additional option categories" on public.additional_option_categories;
create policy "public reads additional option categories" on public.additional_option_categories for select to anon, authenticated using (true);
drop policy if exists "owner manages additional option categories" on public.additional_option_categories;
create policy "owner manages additional option categories" on public.additional_option_categories for all to authenticated
using (exists(select 1 from public.restaurants r where r.id=restaurant_id and r.owner_id=auth.uid()))
with check (exists(select 1 from public.restaurants r where r.id=restaurant_id and r.owner_id=auth.uid()));
alter table public.order_items add column if not exists addons jsonb not null default '[]'::jsonb;

create or replace function public.submit_restaurant_order(
  p_restaurant_id uuid, p_customer_name text, p_customer_phone text,
  p_delivery_type text, p_address text, p_notes text, p_items jsonb
) returns uuid
language plpgsql security definer set search_path = pg_catalog, public
as $$
declare
  v_order_id uuid;
  v_total numeric(12,2) := 0;
  v_item record;
  v_product public.products%rowtype;
  v_addon record;
  v_qty integer;
  v_addons jsonb;
  v_item_total numeric(12,2);
  v_addon_name text;
  v_addon_price numeric(12,2);
begin
  if length(trim(coalesce(p_customer_name,''))) < 2 then raise exception 'Informe seu nome.'; end if;
  if length(regexp_replace(coalesce(p_customer_phone,''),'[^0-9]','','g')) < 8 then raise exception 'Informe um WhatsApp válido.'; end if;
  if p_delivery_type not in ('delivery','pickup') then raise exception 'Tipo de entrega inválido.'; end if;
  if p_delivery_type='delivery' and length(trim(coalesce(p_address,''))) < 4 then raise exception 'Informe o endereço de entrega.'; end if;
  if coalesce(jsonb_typeof(p_items),'') <> 'array' or jsonb_array_length(p_items)=0 or jsonb_array_length(p_items)>50 then raise exception 'A sacola está vazia.'; end if;
  if not exists(select 1 from public.restaurants where id=p_restaurant_id and is_open=true and plan in ('pro','complete')) then raise exception 'Restaurante indisponível para pedidos online.'; end if;

  for v_item in select * from jsonb_to_recordset(p_items) as x(product_id uuid, quantity integer, addons jsonb) loop
    v_qty := v_item.quantity;
    if v_qty is null or v_qty < 1 or v_qty > 50 then raise exception 'Quantidade inválida.'; end if;
    select * into v_product from public.products where id=v_item.product_id and restaurant_id=p_restaurant_id and available=true;
    if not found then raise exception 'Um dos produtos não está mais disponível.'; end if;
    v_total := v_total + (v_product.price * v_qty);
    if jsonb_typeof(coalesce(v_item.addons,'[]'::jsonb)) <> 'array' then raise exception 'Adicionais inválidos.'; end if;
    for v_addon in select * from jsonb_to_recordset(coalesce(v_item.addons,'[]'::jsonb)) as a(addon_id uuid, quantity integer) loop
      if coalesce(v_addon.quantity,1) < 1 or coalesce(v_addon.quantity,1) > 20 then raise exception 'Quantidade de adicional inválida.'; end if;
      if not exists (
        select 1 from public.additional_options ao
        join public.additional_option_categories aoc on aoc.additional_option_id=ao.id
        where ao.id=v_addon.addon_id and ao.restaurant_id=p_restaurant_id and ao.active=true
          and aoc.category_id=v_product.category_id
      ) then raise exception 'Um adicional selecionado não pertence à categoria deste produto.'; end if;
      select ao.price into v_addon_price from public.additional_options ao where ao.id=v_addon.addon_id and ao.restaurant_id=p_restaurant_id and ao.active=true;
      v_total := v_total + (v_addon_price * coalesce(v_item.quantity,1) * coalesce(v_addon.quantity,1));
    end loop;
  end loop;

  insert into public.orders(restaurant_id,customer_name,customer_phone,delivery_type,address,notes,total,status)
  values(p_restaurant_id,trim(p_customer_name),trim(p_customer_phone),p_delivery_type,
    case when p_delivery_type='delivery' then trim(p_address) else null end,
    nullif(trim(coalesce(p_notes,'')),''),v_total,'new') returning id into v_order_id;

  for v_item in select * from jsonb_to_recordset(p_items) as x(product_id uuid, quantity integer, addons jsonb) loop
    select * into v_product from public.products where id=v_item.product_id and restaurant_id=p_restaurant_id and available=true;
    v_addons := '[]'::jsonb;
    v_item_total := v_product.price;
    for v_addon in select * from jsonb_to_recordset(coalesce(v_item.addons,'[]'::jsonb)) as a(addon_id uuid, quantity integer) loop
      select ao.name,ao.price into v_addon_name,v_addon_price from public.additional_options ao
      join public.additional_option_categories aoc on aoc.additional_option_id=ao.id
      where ao.id=v_addon.addon_id and ao.restaurant_id=p_restaurant_id and ao.active=true and aoc.category_id=v_product.category_id;
      v_addons := v_addons || jsonb_build_array(jsonb_build_object('name',v_addon_name,'price',v_addon_price,'quantity',coalesce(v_addon.quantity,1)));
      v_item_total := v_item_total + (v_addon_price * coalesce(v_addon.quantity,1));
    end loop;
    insert into public.order_items(order_id,product_id,product_name,unit_price,quantity,total,addons)
    values(v_order_id,v_product.id,v_product.name,v_item_total,v_item.quantity,v_item_total*v_item.quantity,v_addons);
  end loop;
  return v_order_id;
end;
$$;
revoke all on function public.submit_restaurant_order(uuid,text,text,text,text,text,jsonb) from public;
grant execute on function public.submit_restaurant_order(uuid,text,text,text,text,text,jsonb) to anon, authenticated;
