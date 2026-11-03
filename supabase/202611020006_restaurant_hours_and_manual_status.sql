-- MENU.KOPCODE | Horários, abertura manual e validação de pedidos.
-- Execute somente no Supabase exclusivo do MENU.KOPCODE (nwznpaybbqpuqbowllzx).

alter table public.restaurants
  add column if not exists opening_hours jsonb not null default '{}'::jsonb,
  add column if not exists manual_status text not null default 'auto';

alter table public.restaurants
  drop constraint if exists restaurants_manual_status_check;
alter table public.restaurants
  add constraint restaurants_manual_status_check
  check (manual_status in ('auto','open','closed'));

-- Visitantes anônimos precisam ler apenas a configuração pública do expediente.
grant select (opening_hours, manual_status) on public.restaurants to anon;

create or replace function public.enforce_restaurant_order_hours()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_shop public.restaurants%rowtype;
  v_day_key text;
  v_day jsonb;
  v_now time;
  v_open time;
  v_close time;
begin
  select * into v_shop
  from public.restaurants
  where id = new.restaurant_id;

  if not found then
    raise exception 'Restaurante não encontrado.';
  end if;

  if v_shop.manual_status = 'closed'
     or (v_shop.manual_status <> 'open' and v_shop.is_open = false) then
    raise exception 'Restaurante fechado no momento.';
  end if;

  -- A abertura forçada ignora completamente a grade semanal.
  if v_shop.manual_status = 'open' then
    return new;
  end if;

  v_day_key := case extract(isodow from timezone('America/Sao_Paulo', now()))::integer
    when 1 then 'mon'
    when 2 then 'tue'
    when 3 then 'wed'
    when 4 then 'thu'
    when 5 then 'fri'
    when 6 then 'sat'
    else 'sun'
  end;

  v_day := v_shop.opening_hours -> v_day_key;

  -- Lojas que ainda não configuraram horários continuam seguindo o campo legado is_open.
  if v_day is null then
    return new;
  end if;

  if coalesce((v_day ->> 'enabled')::boolean, false) = false then
    raise exception 'Restaurante fechado neste dia da semana.';
  end if;

  v_open := (v_day ->> 'open')::time;
  v_close := (v_day ->> 'close')::time;
  v_now := timezone('America/Sao_Paulo', now())::time;

  if v_open = v_close then
    raise exception 'Restaurante fechado neste horário.';
  elsif v_close > v_open then
    if v_now < v_open or v_now >= v_close then
      raise exception 'Estamos fora do horário de atendimento.';
    end if;
  else
    -- Expediente que atravessa a meia-noite.
    if v_now < v_open and v_now >= v_close then
      raise exception 'Estamos fora do horário de atendimento.';
    end if;
  end if;

  return new;
end;
$$;

drop trigger if exists enforce_restaurant_order_hours on public.orders;
create trigger enforce_restaurant_order_hours
before insert on public.orders
for each row
execute function public.enforce_restaurant_order_hours();

