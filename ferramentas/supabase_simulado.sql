-- Simula o mínimo do Supabase num PostgreSQL comum, só para testes locais.
create schema if not exists extensions;
create extension if not exists citext with schema extensions;
create extension if not exists pgcrypto with schema extensions;
do $$ begin create role anon nologin; exception when others then null; end $$;
do $$ begin create role authenticated nologin; exception when others then null; end $$;
create schema auth;
create table auth.users(id uuid primary key default gen_random_uuid(), email text, raw_user_meta_data jsonb, email_confirmed_at timestamptz);
create function auth.uid() returns uuid language sql stable as $$ select nullif(current_setting('request.jwt.claim.sub', true),'')::uuid $$;
grant usage on schema auth to authenticated, anon;
grant execute on function auth.uid() to authenticated, anon;
grant usage on schema public to authenticated, anon;
create publication supabase_realtime;
