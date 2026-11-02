-- MENU.KOPCODE | Painel administrativo da plataforma
-- Execute no projeto Supabase exclusivo nwznpaybbqpuqbowllzx.
-- Acesso administrativo é concedido manualmente ao usuário indicado no final deste arquivo.

create table if not exists public.platform_admins (
  user_id uuid primary key references auth.users(id) on delete cascade,
  created_at timestamptz not null default now()
);

alter table public.platform_admins enable row level security;
revoke all on public.platform_admins from anon, authenticated;

create or replace function public.is_platform_admin()
returns boolean
language sql
stable
security definer
set search_path = pg_catalog, public
as $$
  select exists (
    select 1 from public.platform_admins a
    where a.user_id = auth.uid()
  );
$$;

revoke all on function public.is_platform_admin() from public, anon;
grant execute on function public.is_platform_admin() to authenticated;

create or replace function public.admin_dashboard_stats()
returns jsonb
language plpgsql
stable
security definer
set search_path = pg_catalog, public, auth
as $$
declare
  v_result jsonb;
begin
  if not public.is_platform_admin() then
    raise exception 'Acesso restrito ao administrador da plataforma.';
  end if;

  select jsonb_build_object(
    'restaurants_total', (select count(*) from public.restaurants),
    'restaurants_open', (select count(*) from public.restaurants where is_open),
    'restaurants_closed', (select count(*) from public.restaurants where not is_open),
    'orders_total', (select count(*) from public.orders),
    'orders_today', (select count(*) from public.orders where created_at >= date_trunc('day', now())),
    'revenue_total', coalesce((select sum(total) from public.orders where status <> 'cancelled'), 0),
    'revenue_today', coalesce((select sum(total) from public.orders where status <> 'cancelled' and created_at >= date_trunc('day', now())), 0),
    'plan_basic', (select count(*) from public.restaurants where plan = 'basic'),
    'plan_pro', (select count(*) from public.restaurants where plan = 'pro'),
    'plan_complete', (select count(*) from public.restaurants where plan = 'complete')
  ) into v_result;

  return v_result;
end;
$$;

create or replace function public.admin_list_restaurants(p_search text default '')
returns jsonb
language plpgsql
stable
security definer
set search_path = pg_catalog, public, auth
as $$
declare
  v_result jsonb;
begin
  if not public.is_platform_admin() then
    raise exception 'Acesso restrito ao administrador da plataforma.';
  end if;

  select coalesce(jsonb_agg(to_jsonb(x) order by x.created_at desc), '[]'::jsonb)
  into v_result
  from (
    select
      r.id, r.name, r.slug, r.phone, r.plan, r.is_open, r.created_at,
      u.email as owner_email,
      (select count(*) from public.orders o where o.restaurant_id = r.id) as orders_count,
      coalesce((select sum(o.total) from public.orders o where o.restaurant_id = r.id and o.status <> 'cancelled'), 0) as revenue_total
    from public.restaurants r
    left join auth.users u on u.id = r.owner_id
    where coalesce(p_search, '') = ''
      or r.name ilike '%' || p_search || '%'
      or r.slug ilike '%' || p_search || '%'
      or coalesce(u.email, '') ilike '%' || p_search || '%'
      or coalesce(r.phone, '') ilike '%' || p_search || '%'
  ) x;

  return v_result;
end;
$$;

create or replace function public.admin_update_restaurant(
  p_restaurant_id uuid,
  p_name text,
  p_phone text,
  p_plan text,
  p_is_open boolean
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, auth
as $$
declare
  v_row public.restaurants%rowtype;
begin
  if not public.is_platform_admin() then
    raise exception 'Acesso restrito ao administrador da plataforma.';
  end if;
  if p_plan not in ('basic','pro','complete') then
    raise exception 'Plano inválido.';
  end if;
  if length(trim(coalesce(p_name,''))) < 2 then
    raise exception 'Informe um nome válido para o restaurante.';
  end if;

  update public.restaurants
  set name = trim(p_name),
      phone = coalesce(trim(p_phone),''),
      plan = p_plan,
      is_open = coalesce(p_is_open, is_open)
  where id = p_restaurant_id
  returning * into v_row;

  if not found then
    raise exception 'Restaurante não encontrado.';
  end if;

  return jsonb_build_object(
    'id', v_row.id, 'name', v_row.name, 'phone', v_row.phone,
    'plan', v_row.plan, 'is_open', v_row.is_open
  );
end;
$$;

create or replace function public.admin_recent_orders(p_limit integer default 12)
returns jsonb
language plpgsql
stable
security definer
set search_path = pg_catalog, public, auth
as $$
declare
  v_result jsonb;
begin
  if not public.is_platform_admin() then
    raise exception 'Acesso restrito ao administrador da plataforma.';
  end if;

  select coalesce(jsonb_agg(to_jsonb(x) order by x.created_at desc), '[]'::jsonb)
  into v_result
  from (
    select o.id, o.customer_name, o.customer_phone, o.total, o.status,
           o.created_at, o.delivery_type, r.name as restaurant_name
    from public.orders o
    join public.restaurants r on r.id = o.restaurant_id
    order by o.created_at desc
    limit greatest(1, least(coalesce(p_limit, 12), 50))
  ) x;

  return v_result;
end;
$$;

revoke all on function public.admin_dashboard_stats() from public, anon;
revoke all on function public.admin_list_restaurants(text) from public, anon;
revoke all on function public.admin_update_restaurant(uuid,text,text,text,boolean) from public, anon;
revoke all on function public.admin_recent_orders(integer) from public, anon;

grant execute on function public.admin_dashboard_stats() to authenticated;
grant execute on function public.admin_list_restaurants(text) to authenticated;
grant execute on function public.admin_update_restaurant(uuid,text,text,text,boolean) to authenticated;
grant execute on function public.admin_recent_orders(integer) to authenticated;

-- CONCEDER ACESSO AO ADMINISTRADOR:
-- 1) Crie sua conta normalmente em /cadastro e confirme que consegue entrar.
-- 2) Troque o e-mail abaixo pelo e-mail EXATO usado no cadastro.
-- 3) Execute este INSERT uma única vez.
-- insert into public.platform_admins(user_id)
-- select id from auth.users where lower(email) = lower('SEU-EMAIL@EXEMPLO.COM')
-- on conflict (user_id) do nothing;
