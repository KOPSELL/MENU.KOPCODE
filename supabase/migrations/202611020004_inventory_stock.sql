-- MENU.KOPCODE | Controle de estoque por restaurante.
-- Execute no SQL Editor do Supabase EXCLUSIVO do MENU.KOPCODE.

alter table public.products
  add column if not exists track_stock boolean not null default false,
  add column if not exists stock_quantity integer not null default 0 check (stock_quantity >= 0),
  add column if not exists low_stock_threshold integer not null default 5 check (low_stock_threshold >= 0);

create table if not exists public.stock_movements (
  id uuid primary key default gen_random_uuid(),
  restaurant_id uuid not null references public.restaurants(id) on delete cascade,
  product_id uuid references public.products(id) on delete set null,
  product_name text not null,
  movement_type text not null check (movement_type in ('sale','adjustment','restock')),
  quantity integer not null check (quantity <> 0),
  order_id uuid references public.orders(id) on delete set null,
  note text,
  created_at timestamptz not null default now()
);

create index if not exists stock_movements_restaurant_created_idx
  on public.stock_movements(restaurant_id, created_at desc);
create index if not exists stock_movements_product_created_idx
  on public.stock_movements(product_id, created_at desc);

alter table public.stock_movements enable row level security;
drop policy if exists "restaurant owners read stock movements" on public.stock_movements;
create policy "restaurant owners read stock movements"
on public.stock_movements for select to authenticated
using (exists (
  select 1 from public.restaurants r
  where r.id = stock_movements.restaurant_id and r.owner_id = auth.uid()
));

-- Registra criação/ajuste manual de quantidade. Alterações internas da venda
-- são marcadas para não gerar uma segunda movimentação duplicada.
create or replace function public.log_manual_stock_change()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_delta integer;
begin
  if current_setting('app.stock_sale_update', true) = 'on' then
    return new;
  end if;

  if tg_op = 'INSERT' then
    if new.track_stock and new.stock_quantity > 0 then
      insert into public.stock_movements(restaurant_id, product_id, product_name, movement_type, quantity, note)
      values(new.restaurant_id, new.id, new.name, 'restock', new.stock_quantity, 'Estoque inicial cadastrado');
    end if;
    return new;
  end if;

  if new.track_stock and (
    old.track_stock is distinct from new.track_stock
    or old.stock_quantity is distinct from new.stock_quantity
  ) then
    v_delta := new.stock_quantity - case when old.track_stock then old.stock_quantity else 0 end;
    if v_delta <> 0 then
      insert into public.stock_movements(restaurant_id, product_id, product_name, movement_type, quantity, note)
      values(new.restaurant_id, new.id, new.name,
        case when v_delta > 0 then 'restock' else 'adjustment' end,
        v_delta,
        case when v_delta > 0 then 'Entrada/reposição manual' else 'Ajuste manual de estoque' end);
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists products_log_manual_stock_change on public.products;
create trigger products_log_manual_stock_change
after insert or update of track_stock, stock_quantity
on public.products
for each row execute function public.log_manual_stock_change();

-- Baixa automática e atômica: trava a linha do produto, confere saldo e
-- impede que duas compras simultâneas vendam a última unidade duas vezes.
create or replace function public.decrease_stock_after_order_item()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_product public.products%rowtype;
begin
  select * into v_product
  from public.products
  where id = new.product_id
  for update;

  if not found then
    return new;
  end if;

  if v_product.track_stock then
    if v_product.stock_quantity < new.quantity then
      raise exception 'Estoque insuficiente para "%". Disponível: %, solicitado: %.',
        v_product.name, v_product.stock_quantity, new.quantity;
    end if;

    perform set_config('app.stock_sale_update', 'on', true);
    update public.products
      set stock_quantity = stock_quantity - new.quantity,
          available = case when stock_quantity - new.quantity <= 0 then false else available end
      where id = new.product_id;
    perform set_config('app.stock_sale_update', 'off', true);

    insert into public.stock_movements(
      restaurant_id, product_id, product_name, movement_type, quantity, order_id, note
    ) values (
      v_product.restaurant_id, v_product.id, v_product.name, 'sale',
      -new.quantity, new.order_id, 'Saída automática por venda'
    );
  end if;
  return new;
end;
$$;

drop trigger if exists order_items_decrease_stock on public.order_items;
create trigger order_items_decrease_stock
after insert on public.order_items
for each row execute function public.decrease_stock_after_order_item();

-- Ao cancelar um pedido, devolve ao estoque os itens que tiveram baixa.
create or replace function public.restore_stock_on_cancelled_order()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_item record;
  v_product public.products%rowtype;
begin
  if new.status = 'cancelled' and old.status is distinct from 'cancelled' then
    for v_item in
      select oi.product_id, oi.product_name, oi.quantity
      from public.order_items oi
      where oi.order_id = new.id and oi.product_id is not null
    loop
      select * into v_product from public.products where id = v_item.product_id for update;
      if found and v_product.track_stock then
        perform set_config('app.stock_sale_update', 'on', true);
        update public.products
          set stock_quantity = stock_quantity + v_item.quantity,
              available = true
          where id = v_product.id;
        perform set_config('app.stock_sale_update', 'off', true);
        insert into public.stock_movements(
          restaurant_id, product_id, product_name, movement_type, quantity, order_id, note
        ) values (
          v_product.restaurant_id, v_product.id, v_product.name, 'restock',
          v_item.quantity, new.id, 'Devolução automática por cancelamento de pedido'
        );
      end if;
    end loop;
  end if;
  return new;
end;
$$;

drop trigger if exists orders_restore_stock_on_cancel on public.orders;
create trigger orders_restore_stock_on_cancel
after update of status on public.orders
for each row execute function public.restore_stock_on_cancelled_order();

grant select on public.stock_movements to authenticated;
