-- MENU.KOPCODE | Security migration for databases created before this hardening.
-- Run once in Supabase SQL Editor. Safe to run again.

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
