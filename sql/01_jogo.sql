-- =====================================================================
-- TRILHA 151 — banco de dados completo (Supabase / PostgreSQL)
-- Rode este arquivo UMA vez no SQL Editor do Supabase. Depois rode 02_pokemon.sql.
-- Todas as regras do jogo ficam aqui: o navegador só lê dados e pede ações.
-- =====================================================================

create schema if not exists extensions;
create extension if not exists citext with schema extensions;

do $$ begin create type public.app_role    as enum ('admin');                                     exception when duplicate_object then null; end $$;
do $$ begin create type public.char_class  as enum ('guerreiro','mago','arqueiro');               exception when duplicate_object then null; end $$;
do $$ begin create type public.puzzle_mode as enum ('classico','cartao','descricao','silhueta');  exception when duplicate_object then null; end $$;

-- ---------------------------------------------------------------------
-- TABELAS
-- ---------------------------------------------------------------------
create table if not exists public.game_config (
  version    serial primary key,
  config     jsonb not null,
  active     boolean not null default false,
  created_by uuid,
  created_at timestamptz not null default now()
);
create unique index if not exists game_config_one_active on public.game_config(active) where active;

create table if not exists public.profiles (
  id         uuid primary key references auth.users(id) on delete cascade,
  username   extensions.citext not null unique check (username ~ '^[A-Za-z0-9_]{3,16}$'),
  status     text not null default 'ativo' check (status in ('ativo','bloqueado')),
  created_at timestamptz not null default now()
);

create table if not exists public.user_roles (
  user_id    uuid not null references auth.users(id) on delete cascade,
  role       public.app_role not null,
  granted_at timestamptz not null default now(),
  primary key (user_id, role)
);

create table if not exists public.pokemon (
  id        int primary key check (id between 1 and 151),
  name      text not null unique,
  type1     text not null,
  type2     text,
  habitat   text not null,
  color     text not null,
  stage     int  not null,
  height_dm int  not null,
  weight_hg int  not null
);

-- Imagens e descrições ficam escondidas dos jogadores (sem política de leitura).
create table if not exists public.pokemon_media (
  pokemon_id   int primary key references public.pokemon(id) on delete cascade,
  silhouette   text,      -- imagem já pintada de preto (data URL)
  pixel_levels jsonb,     -- lista de imagens, da mais pixelada à nítida (data URLs)
  description  text,      -- descrição com o nome escondido
  updated_at   timestamptz not null default now()
);

create table if not exists public.daily_puzzles (
  puzzle_date date not null,
  mode        public.puzzle_mode not null,
  pokemon_id  int not null references public.pokemon(id),
  primary key (puzzle_date, mode)
);

create table if not exists public.characters (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null unique references auth.users(id) on delete cascade,
  name          extensions.citext not null unique check (name ~ '^[A-Za-zÀ-ÿ0-9_ ]{3,16}$'),
  class         public.char_class not null,
  level         int not null default 1,
  xp_total      int not null default 0,
  coins         int not null default 0 check (coins >= 0),
  progress      int not null default 0 check (progress >= 0),  -- casas andadas no total
  best_lap      int not null default 0,                         -- maior volta já premiada
  outfit        jsonb not null default '{}'::jsonb,             -- {"chapeu":"...", "capa":"...", ...}
  owned_items   text[] not null default '{}',
  last_move_date date,
  created_at    timestamptz not null default now()
);

create table if not exists public.guess_sessions (
  user_id     uuid not null references auth.users(id) on delete cascade,
  puzzle_date date not null,
  mode        public.puzzle_mode not null,
  attempts    int not null default 0,
  solved      boolean not null default false,
  failed      boolean not null default false,
  finished_at timestamptz,
  primary key (user_id, puzzle_date, mode)
);

create table if not exists public.guesses (
  id          bigserial primary key,
  user_id     uuid not null references auth.users(id) on delete cascade,
  puzzle_date date not null,
  mode        public.puzzle_mode not null,
  pokemon_id  int not null references public.pokemon(id),
  correct     boolean not null,
  feedback    jsonb,
  created_at  timestamptz not null default now(),
  unique (user_id, puzzle_date, mode, pokemon_id)
);

create table if not exists public.daily_moves (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null references auth.users(id) on delete cascade,
  move_date     date not null,
  score         int not null,
  mode_points   jsonb not null,
  base_steps    int not null,
  die           int not null,
  from_progress int not null,
  to_progress   int not null,
  xp_gained     int not null,
  coins_gained  int not null,
  events        jsonb not null default '[]'::jsonb,
  created_at    timestamptz not null default now(),
  unique (user_id, move_date)                         -- trava: só um movimento por dia
);

create table if not exists public.board_squares (
  idx   int primary key,
  kind  text not null check (kind in ('inicio','normal','avanco','recuo','bau','xp','raio','troca')),
  value int not null default 0
);

create table if not exists public.traps (
  id           uuid primary key default gen_random_uuid(),
  square       int not null,
  owner_id     uuid not null references auth.users(id) on delete cascade,
  created_at   timestamptz not null default now(),
  triggered_by uuid,
  triggered_at timestamptz
);
create unique index if not exists traps_one_per_square on public.traps(square) where triggered_at is null;
create unique index if not exists traps_one_per_owner  on public.traps(owner_id) where triggered_at is null;

create table if not exists public.shop_items (
  id        text primary key,
  name      text not null,
  slot      text not null check (slot in ('chapeu','capa','roupa','aura')),
  price     int  not null,
  min_level int  not null default 1,
  rarity    text not null check (rarity in ('comum','incomum','raro','epico','lendario')),
  data      jsonb not null default '{}'::jsonb
);

create table if not exists public.event_log (
  id         bigserial primary key,
  user_id    uuid,
  kind       text not null,
  message    text not null,
  data       jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create table if not exists public.admin_audit_log (
  id         bigserial primary key,
  admin_id   uuid not null,
  action     text not null,
  target     text,
  before     jsonb,
  after      jsonb,
  reason     text,
  created_at timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- DADOS INICIAIS
-- ---------------------------------------------------------------------
insert into public.game_config (config, active)
select '{
  "timezone": "America/Sao_Paulo",
  "points": {"1":100,"2":85,"3":70,"4":55,"5":40,"6":25,"7":10},
  "max_guesses": 20,
  "board_size": 60,
  "steps_divisor": 40,
  "dice_sides": 6,
  "xp_daily_bonus": 20,
  "coins_divisor": 4,
  "lap_bonus_coins": 100,
  "trap_price": 60, "trap_push": 3, "trap_reward": 20,
  "duel_push": 2, "duel_coins": 30, "duel_level_factor": 3, "guerreiro_duel_bonus": 15,
  "mago_resist_pct": 30, "arqueiro_min_die": 2,
  "storm_push": 3, "chest_coins": 30, "xp_square": 50
}'::jsonb, true
where not exists (select 1 from public.game_config);

insert into public.board_squares (idx, kind, value)
select i,
  case
    when i = 0 then 'inicio'
    when i in (7,23,38,52) then 'avanco'
    when i in (12,29,44,57) then 'recuo'
    when i in (18,41) then 'raio'
    when i in (26,49) then 'troca'
    when i in (3,33,47) then 'xp'
    when i % 10 = 5 then 'bau'
    else 'normal'
  end,
  case when i in (7,23,38,52,12,29,44,57) then 3 else 0 end
from generate_series(0,59) i
on conflict (idx) do nothing;

insert into public.shop_items (id,name,slot,price,min_level,rarity,data) values
 ('chapeu_palha','Chapéu de palha','chapeu',40,1,'comum','{"c1":"#e3c26b","c2":"#a8822f"}'),
 ('capuz_verde','Capuz de explorador','chapeu',80,2,'incomum','{"c1":"#4f8a3a","c2":"#2f5a24"}'),
 ('chapeu_estrela','Chapéu estrelado','chapeu',150,4,'raro','{"c1":"#4b3f9e","c2":"#f2d14b"}'),
 ('elmo_ferro','Elmo de ferro','chapeu',150,4,'raro','{"c1":"#b9c2cc","c2":"#6c7682"}'),
 ('coroa','Coroa do campeão','chapeu',600,10,'lendario','{"c1":"#f5c542","c2":"#d1453b"}'),
 ('capa_vermelha','Capa vermelha','capa',70,1,'comum','{"c1":"#c8423a","c2":"#7e231e"}'),
 ('capa_azul','Capa do mar','capa',120,3,'incomum','{"c1":"#3a7bc8","c2":"#1f4a80"}'),
 ('capa_real','Capa real','capa',400,8,'epico','{"c1":"#7a2fb3","c2":"#f2d14b"}'),
 ('tunica_floresta','Túnica da floresta','roupa',60,1,'comum','{"c1":"#5e9e45","c2":"#36632a"}'),
 ('armadura_bronze','Armadura de bronze','roupa',200,5,'raro','{"c1":"#c98a3e","c2":"#7d5222"}'),
 ('manto_noite','Manto da noite','roupa',300,6,'epico','{"c1":"#2c3550","c2":"#7f8fd6"}'),
 ('aura_dourada','Aura dourada','aura',500,8,'epico','{"c1":"#ffd54a"}'),
 ('aura_eletrica','Aura elétrica','aura',900,12,'lendario','{"c1":"#7fe3ff"}')
on conflict (id) do nothing;

-- ---------------------------------------------------------------------
-- FUNÇÕES AUXILIARES
-- ---------------------------------------------------------------------
create or replace function public.cfg() returns jsonb
language sql stable security definer set search_path = public, extensions as $$
  select config from game_config where active limit 1
$$;

create or replace function public.game_today() returns date
language sql stable security definer set search_path = public, extensions as $$
  select (now() at time zone coalesce(cfg()->>'timezone','America/Sao_Paulo'))::date
$$;

create or replace function public.has_role(_user_id uuid, _role public.app_role) returns boolean
language sql stable security definer set search_path = public, extensions as $$
  select exists (select 1 from user_roles where user_id = _user_id and role = _role)
$$;

create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = public, extensions as $$
  select public.has_role(auth.uid(), 'admin')
$$;

create or replace function public.assert_active() returns uuid
language plpgsql stable security definer set search_path = public, extensions as $$
declare uid uuid := auth.uid();
begin
  if uid is null then raise exception 'Faça login para continuar.'; end if;
  if not exists (select 1 from profiles where id = uid and status = 'ativo') then
    raise exception 'Sua conta está bloqueada. Fale com o administrador.';
  end if;
  return uid;
end $$;

create or replace function public.assert_admin() returns uuid
language plpgsql stable security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active();
begin
  if not public.has_role(uid, 'admin') then raise exception 'Apenas o administrador pode fazer isso.'; end if;
  return uid;
end $$;

create or replace function public.audit(_action text, _target text, _before jsonb, _after jsonb, _reason text) returns void
language sql security definer set search_path = public, extensions as $$
  insert into admin_audit_log(admin_id, action, target, before, after, reason)
  values (auth.uid(), _action, _target, _before, _after, _reason)
$$;

create or replace function public.level_for_xp(_xp int) returns int
language sql immutable as $$ select 1 + floor(sqrt(greatest(_xp,0) / 150.0))::int $$;

-- ---------------------------------------------------------------------
-- CADASTRO
-- ---------------------------------------------------------------------
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public, extensions as $$
declare u text := trim(coalesce(new.raw_user_meta_data->>'username',''));
begin
  if u !~ '^[A-Za-z0-9_]{3,16}$' then raise exception 'Nome de usuário inválido.'; end if;
  if lower(u) = 'karneiro' and lower(coalesce(new.email,'')) <> 'carneirohenrique@hotmail.com' then
    raise exception 'Este nome de usuário é reservado.';
  end if;
  insert into profiles(id, username) values (new.id, u);
  return new;
end $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

create or replace function public.username_available(_username text) returns boolean
language sql stable security definer set search_path = public, extensions as $$
  select _username ~ '^[A-Za-z0-9_]{3,16}$'
     and lower(_username) <> 'karneiro'
     and not exists (select 1 from profiles where username = _username::citext)
$$;

create or replace function public.create_character(_name text, _class public.char_class) returns public.characters
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); r characters;
begin
  if exists (select 1 from characters where user_id = uid) then raise exception 'Você já tem um personagem.'; end if;
  if trim(_name) !~ '^[A-Za-zÀ-ÿ0-9_ ]{3,16}$' then raise exception 'O nome deve ter de 3 a 16 letras ou números.'; end if;
  if exists (select 1 from characters where name = trim(_name)::citext) then raise exception 'Esse nome de personagem já existe.'; end if;
  insert into characters(user_id, name, class, coins) values (uid, trim(_name), _class, 50) returning * into r;
  insert into event_log(user_id, kind, message) values (uid, 'chegada', r.name || ' entrou na trilha.');
  return r;
end $$;

-- ---------------------------------------------------------------------
-- DESAFIO DIÁRIO
-- ---------------------------------------------------------------------
create or replace function public.ensure_puzzles(_d date) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare m public.puzzle_mode; pid int;
begin
  foreach m in array enum_range(null::public.puzzle_mode) loop
    if exists (select 1 from daily_puzzles where puzzle_date = _d and mode = m) then continue; end if;
    select p.id into pid
    from pokemon p left join pokemon_media pm on pm.pokemon_id = p.id
    where (m = 'classico'
        or (m = 'descricao' and pm.description is not null)
        or (m in ('cartao','silhueta') and pm.silhouette is not null and pm.pixel_levels is not null))
      and p.id not in (select pokemon_id from daily_puzzles where puzzle_date > _d - 30 and puzzle_date <= _d)
    order by random() limit 1;
    if pid is null then   -- poucos Pokémon com mídia: aceita repetir
      select p.id into pid
      from pokemon p left join pokemon_media pm on pm.pokemon_id = p.id
      where (m = 'classico'
          or (m = 'descricao' and pm.description is not null)
          or (m in ('cartao','silhueta') and pm.silhouette is not null and pm.pixel_levels is not null))
        and p.id not in (select pokemon_id from daily_puzzles where puzzle_date = _d)
      order by random() limit 1;
    end if;
    if pid is not null then
      insert into daily_puzzles(puzzle_date, mode, pokemon_id) values (_d, m, pid) on conflict do nothing;
    end if;
  end loop;
end $$;

create or replace function public.compare_pokemon(_guess int, _answer int) returns jsonb
language plpgsql stable security definer set search_path = public, extensions as $$
declare g pokemon; a pokemon;
begin
  select * into g from pokemon where id = _guess;
  select * into a from pokemon where id = _answer;
  return jsonb_build_object(
    'type1',   jsonb_build_object('v', g.type1, 's',
                 case when g.type1 = a.type1 then 'certo' when g.type1 = a.type2 then 'parcial' else 'errado' end),
    'type2',   jsonb_build_object('v', coalesce(g.type2,'Nenhum'), 's',
                 case when coalesce(g.type2,'') = coalesce(a.type2,'') then 'certo'
                      when g.type2 is not null and g.type2 = a.type1 then 'parcial' else 'errado' end),
    'habitat', jsonb_build_object('v', g.habitat, 's', case when g.habitat = a.habitat then 'certo' else 'errado' end),
    'color',   jsonb_build_object('v', g.color,   's', case when g.color = a.color then 'certo' else 'errado' end),
    'stage',   jsonb_build_object('v', g.stage,     's', case when g.stage = a.stage then 'certo' when a.stage > g.stage then 'maior' else 'menor' end),
    'height',  jsonb_build_object('v', g.height_dm, 's', case when g.height_dm = a.height_dm then 'certo' when a.height_dm > g.height_dm then 'maior' else 'menor' end),
    'weight',  jsonb_build_object('v', g.weight_hg, 's', case when g.weight_hg = a.weight_hg then 'certo' when a.weight_hg > g.weight_hg then 'maior' else 'menor' end)
  );
end $$;

create or replace function public.mode_points(_attempts int, _solved boolean) returns int
language sql stable security definer set search_path = public, extensions as $$
  select case when not _solved then 0
              else coalesce((cfg()->'points'->>least(_attempts,7)::text)::int, 0) end
$$;

create or replace function public.puzzle_state(_mode public.puzzle_mode) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); d date := public.game_today();
  ans int; s guess_sessions; media pokemon_media; clue jsonb := '{}'::jsonb;
  moved boolean; finished boolean; lvl int; n int;
begin
  perform public.ensure_puzzles(d);
  select pokemon_id into ans from daily_puzzles where puzzle_date = d and mode = _mode;
  if ans is null then
    return jsonb_build_object('mode', _mode, 'date', d, 'available', false);
  end if;
  select * into s from guess_sessions where user_id = uid and puzzle_date = d and mode = _mode;
  moved := exists (select 1 from daily_moves where user_id = uid and move_date = d);
  finished := coalesce(s.solved,false) or coalesce(s.failed,false) or moved;
  select * into media from pokemon_media where pokemon_id = ans;

  if _mode = 'descricao' then
    clue := jsonb_build_object('text', media.description);
  elsif _mode = 'silhueta' then
    clue := jsonb_build_object('image', media.silhouette, 'zoom_step', coalesce(s.attempts,0));
  elsif _mode = 'cartao' then
    n := jsonb_array_length(media.pixel_levels);
    lvl := case when finished then n - 1 else least(coalesce(s.attempts,0), n - 2) end;
    clue := jsonb_build_object('image', media.pixel_levels->>lvl, 'level', lvl, 'levels', n);
  end if;

  return jsonb_build_object(
    'mode', _mode, 'date', d, 'available', true,
    'attempts', coalesce(s.attempts,0),
    'solved', coalesce(s.solved,false),
    'failed', coalesce(s.failed,false) or (moved and not coalesce(s.solved,false)),
    'finished', finished,
    'max_guesses', (cfg()->>'max_guesses')::int,
    'points', public.mode_points(coalesce(s.attempts,0), coalesce(s.solved,false)),
    'clue', clue,
    'answer', case when finished then (select jsonb_build_object('id', id, 'name', name) from pokemon where id = ans) end,
    'guesses', coalesce((select jsonb_agg(jsonb_build_object('pokemon_id', pokemon_id, 'correct', correct, 'feedback', feedback) order by id)
                         from guesses where user_id = uid and puzzle_date = d and mode = _mode), '[]'::jsonb)
  );
end $$;

create or replace function public.make_guess(_mode public.puzzle_mode, _pokemon_id int) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); d date := public.game_today();
  ans int; s guess_sessions; ok boolean; fb jsonb; maxg int := (public.cfg()->>'max_guesses')::int;
begin
  if not exists (select 1 from characters where user_id = uid) then raise exception 'Crie seu personagem primeiro.'; end if;
  if exists (select 1 from daily_moves where user_id = uid and move_date = d) then
    raise exception 'Você já andou hoje. O desafio de hoje está encerrado para você.';
  end if;
  if not exists (select 1 from pokemon where id = _pokemon_id) then raise exception 'Pokémon desconhecido.'; end if;
  perform public.ensure_puzzles(d);
  select pokemon_id into ans from daily_puzzles where puzzle_date = d and mode = _mode;
  if ans is null then raise exception 'Este modo ainda não está disponível. O administrador precisa importar a Pokédex.'; end if;

  insert into guess_sessions(user_id, puzzle_date, mode) values (uid, d, _mode) on conflict do nothing;
  select * into s from guess_sessions where user_id = uid and puzzle_date = d and mode = _mode for update;
  if s.solved or s.failed then raise exception 'Você já concluiu este modo hoje.'; end if;
  if exists (select 1 from guesses where user_id = uid and puzzle_date = d and mode = _mode and pokemon_id = _pokemon_id) then
    raise exception 'Você já tentou esse Pokémon neste modo.';
  end if;

  ok := _pokemon_id = ans;
  if _mode = 'classico' then fb := public.compare_pokemon(_pokemon_id, ans); end if;
  insert into guesses(user_id, puzzle_date, mode, pokemon_id, correct, feedback) values (uid, d, _mode, _pokemon_id, ok, fb);
  update guess_sessions set attempts = attempts + 1, solved = ok,
         failed = (not ok and attempts + 1 >= maxg),
         finished_at = case when ok or attempts + 1 >= maxg then now() end
   where user_id = uid and puzzle_date = d and mode = _mode;
  return public.puzzle_state(_mode);
end $$;

create or replace function public.today_overview() returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); d date := public.game_today(); m public.puzzle_mode;
  modes jsonb := '{}'::jsonb; s guess_sessions; avail boolean; total int := 0; pts int; mv daily_moves;
begin
  perform public.ensure_puzzles(d);
  select * into mv from daily_moves where user_id = uid and move_date = d;
  foreach m in array enum_range(null::public.puzzle_mode) loop
    s := null;
    select * into s from guess_sessions where user_id = uid and puzzle_date = d and mode = m;
    avail := exists (select 1 from daily_puzzles where puzzle_date = d and mode = m);
    pts := public.mode_points(coalesce(s.attempts,0), coalesce(s.solved,false));
    total := total + pts;
    modes := modes || jsonb_build_object(m::text, jsonb_build_object(
      'available', avail, 'attempts', coalesce(s.attempts,0), 'solved', coalesce(s.solved,false),
      'failed', coalesce(s.failed,false), 'points', pts));
  end loop;
  return jsonb_build_object('date', d, 'modes', modes, 'score', total,
    'moved', mv.id is not null, 'move', case when mv.id is not null then to_jsonb(mv) end,
    'server_time', now());
end $$;

-- ---------------------------------------------------------------------
-- TABULEIRO: andar uma vez por dia
-- ---------------------------------------------------------------------
create or replace function public.move_today() returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  uid uuid := public.assert_active(); d date := public.game_today(); c jsonb := public.cfg();
  me characters; other characters; sq board_squares; tr traps;
  size int := (c->>'board_size')::int;
  score int := 0; mp jsonb := '{}'::jsonb; m public.puzzle_mode; s guess_sessions; pts int;
  base int; die int; pos int; old_pos int; ev jsonb := '[]'::jsonb;
  xp_gain int; coin_gain int; extra_xp int := 0; extra_coins int := 0;
  resist boolean; chance int; steal int; new_lap int; tmp int; new_level int; mv_id uuid;
begin
  select * into me from characters where user_id = uid for update;
  if me.id is null then raise exception 'Crie seu personagem primeiro.'; end if;
  if exists (select 1 from daily_moves where user_id = uid and move_date = d) then
    raise exception 'Você já andou hoje. Volte amanhã!';
  end if;

  -- pontuação do dia
  foreach m in array enum_range(null::public.puzzle_mode) loop
    s := null;
    select * into s from guess_sessions where user_id = uid and puzzle_date = d and mode = m;
    pts := public.mode_points(coalesce(s.attempts,0), coalesce(s.solved,false));
    score := score + pts;
    mp := mp || jsonb_build_object(m::text, jsonb_build_object('attempts', coalesce(s.attempts,0), 'solved', coalesce(s.solved,false), 'points', pts));
  end loop;

  base := floor(score / (c->>'steps_divisor')::numeric);
  die  := 1 + floor(random() * (c->>'dice_sides')::int)::int;
  if me.class = 'arqueiro' and die < (c->>'arqueiro_min_die')::int then
    die := (c->>'arqueiro_min_die')::int;
    ev := ev || jsonb_build_object('t','arqueiro','msg','Olho de arqueiro: o dado vale no mínimo ' || die || '.');
  end if;
  old_pos := me.progress;
  pos := me.progress + base + die;

  -- 1) armadilha de outro jogador
  select * into tr from traps where square = pos % size and triggered_at is null and owner_id <> uid for update;
  if tr.id is not null then
    update traps set triggered_by = uid, triggered_at = now() where id = tr.id;
    select * into other from characters where user_id = tr.owner_id;
    resist := me.class = 'mago' and random() * 100 < (c->>'mago_resist_pct')::int;
    if resist then
      ev := ev || jsonb_build_object('t','armadilha','msg','Você desfez com magia a armadilha de ' || other.name || '.');
    else
      pos := greatest(0, pos - (c->>'trap_push')::int);
      update characters set coins = coins + (c->>'trap_reward')::int where user_id = tr.owner_id;
      ev := ev || jsonb_build_object('t','armadilha','msg','Você caiu na armadilha de ' || other.name || ' e voltou ' || (c->>'trap_push') || ' casas.');
      insert into event_log(user_id, kind, message) values (uid, 'armadilha', me.name || ' caiu na armadilha de ' || other.name || '.');
    end if;
  else
    -- 2) efeito da casa
    select * into sq from board_squares where idx = pos % size;
    if sq.kind = 'avanco' then
      pos := pos + sq.value;
      ev := ev || jsonb_build_object('t','avanco','msg','Vento a favor! Avançou ' || sq.value || ' casas.');
    elsif sq.kind = 'recuo' then
      if me.class = 'mago' and random() * 100 < (c->>'mago_resist_pct')::int then
        ev := ev || jsonb_build_object('t','recuo','msg','Escorregou, mas a magia segurou você no lugar.');
      else
        pos := greatest(0, pos - sq.value);
        ev := ev || jsonb_build_object('t','recuo','msg','Lamaçal! Voltou ' || sq.value || ' casas.');
      end if;
    elsif sq.kind = 'bau' then
      extra_coins := extra_coins + (c->>'chest_coins')::int;
      ev := ev || jsonb_build_object('t','bau','msg','Achou um baú com ' || (c->>'chest_coins') || ' moedas.');
    elsif sq.kind = 'xp' then
      extra_xp := extra_xp + (c->>'xp_square')::int;
      ev := ev || jsonb_build_object('t','xp','msg','Treino na clareira: +' || (c->>'xp_square') || ' XP.');
    elsif sq.kind = 'raio' then
      select * into other from characters order by progress desc, last_move_date asc nulls last limit 1 for update;
      if other.user_id = uid or other.progress <= pos then
        ev := ev || jsonb_build_object('t','raio','msg','A tempestade caiu longe. Você é quem lidera agora!');
      elsif other.user_id is not null then
        if other.class = 'mago' and random() * 100 < (c->>'mago_resist_pct')::int then
          ev := ev || jsonb_build_object('t','raio','msg','Você chamou um raio em ' || other.name || ', mas a magia dele desviou.');
        else
          update characters set progress = greatest(0, progress - (c->>'storm_push')::int) where id = other.id;
          ev := ev || jsonb_build_object('t','raio','msg','Você chamou um raio no líder ' || other.name || ': ele voltou ' || (c->>'storm_push') || ' casas.');
          insert into event_log(user_id, kind, message) values (uid, 'raio', me.name || ' derrubou um raio no líder ' || other.name || '.');
        end if;
      end if;
    elsif sq.kind = 'troca' then
      select * into other from characters where user_id <> uid and progress > pos order by progress asc limit 1 for update;
      if other.id is not null then
        tmp := other.progress;
        update characters set progress = pos where id = other.id;
        ev := ev || jsonb_build_object('t','troca','msg','Portal! Você trocou de lugar com ' || other.name || '.');
        insert into event_log(user_id, kind, message) values (uid, 'troca', me.name || ' trocou de lugar com ' || other.name || ' pelo portal.');
        pos := tmp;
      else
        ev := ev || jsonb_build_object('t','troca','msg','O portal não encontrou ninguém à sua frente.');
      end if;
    end if;
  end if;

  -- 3) duelo com quem estiver na mesma casa
  select * into other from characters
   where user_id <> uid and progress % size = pos % size
   order by random() limit 1 for update;
  if other.id is not null then
    chance := 50 + (me.level - other.level) * (c->>'duel_level_factor')::int
                 + case when me.class = 'guerreiro' then (c->>'guerreiro_duel_bonus')::int else 0 end
                 - case when other.class = 'guerreiro' then (c->>'guerreiro_duel_bonus')::int else 0 end;
    chance := greatest(25, least(75, chance));
    if random() * 100 < chance then
      steal := least((c->>'duel_coins')::int, other.coins);
      update characters set coins = coins - steal, progress = greatest(0, progress - (c->>'duel_push')::int) where id = other.id;
      extra_coins := extra_coins + steal;
      ev := ev || jsonb_build_object('t','duelo','msg','Duelo contra ' || other.name || ': vitória! Ganhou ' || steal || ' moedas e empurrou o rival.');
      insert into event_log(user_id, kind, message) values (uid, 'duelo', me.name || ' venceu um duelo contra ' || other.name || '.');
    else
      steal := least((c->>'duel_coins')::int, me.coins + extra_coins);
      update characters set coins = coins + steal where id = other.id;
      extra_coins := extra_coins - steal;
      pos := greatest(0, pos - (c->>'duel_push')::int);
      ev := ev || jsonb_build_object('t','duelo','msg','Duelo contra ' || other.name || ': derrota. Perdeu ' || steal || ' moedas e voltou ' || (c->>'duel_push') || ' casas.');
      insert into event_log(user_id, kind, message) values (uid, 'duelo', other.name || ' defendeu sua casa contra ' || me.name || '.');
    end if;
  end if;

  -- 4) volta completa
  new_lap := pos / size;
  if new_lap > me.best_lap then
    extra_coins := extra_coins + (new_lap - me.best_lap) * (c->>'lap_bonus_coins')::int;
    ev := ev || jsonb_build_object('t','volta','msg','Volta completa! +' || ((new_lap - me.best_lap) * (c->>'lap_bonus_coins')::int) || ' moedas.');
    insert into event_log(user_id, kind, message) values (uid, 'volta', me.name || ' completou a volta ' || new_lap || '!');
  end if;

  xp_gain := score + (c->>'xp_daily_bonus')::int + extra_xp;
  coin_gain := floor(score / (c->>'coins_divisor')::numeric)::int + extra_coins;
  new_level := public.level_for_xp(me.xp_total + xp_gain);
  if new_level > me.level then
    ev := ev || jsonb_build_object('t','nivel','msg','Subiu para o nível ' || new_level || '!');
    insert into event_log(user_id, kind, message) values (uid, 'nivel', me.name || ' chegou ao nível ' || new_level || '.');
  end if;

  update characters set
    progress = pos, best_lap = greatest(best_lap, new_lap),
    xp_total = xp_total + xp_gain, level = new_level,
    coins = greatest(0, coins + coin_gain), last_move_date = d
  where id = me.id;

  insert into daily_moves(user_id, move_date, score, mode_points, base_steps, die, from_progress, to_progress, xp_gained, coins_gained, events)
  values (uid, d, score, mp, base, die, old_pos, pos, xp_gain, coin_gain, ev) returning id into mv_id;

  insert into event_log(user_id, kind, message, data)
  values (uid, 'andou', me.name || ' fez ' || score || ' pontos e andou ' || (base + die) || ' casas.', jsonb_build_object('score', score, 'steps', base + die));

  return jsonb_build_object('score', score, 'mode_points', mp, 'base', base, 'die', die,
    'from', old_pos, 'landed', old_pos + base + die, 'to', pos, 'events', ev,
    'xp', xp_gain, 'coins', coin_gain, 'level', new_level, 'leveled', new_level > me.level);
end $$;

-- ---------------------------------------------------------------------
-- LOJA, VISUAL E ARMADILHAS
-- ---------------------------------------------------------------------
create or replace function public.buy_item(_item text) returns public.characters
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); me characters; it shop_items;
begin
  select * into me from characters where user_id = uid for update;
  select * into it from shop_items where id = _item;
  if it.id is null then raise exception 'Item inexistente.'; end if;
  if _item = any(me.owned_items) then raise exception 'Você já tem esse item.'; end if;
  if me.level < it.min_level then raise exception 'Precisa do nível % para comprar.', it.min_level; end if;
  if me.coins < it.price then raise exception 'Moedas insuficientes.'; end if;
  update characters set coins = coins - it.price, owned_items = array_append(owned_items, _item),
         outfit = outfit || jsonb_build_object(it.slot, it.id)
   where id = me.id returning * into me;
  if it.rarity in ('epico','lendario') then
    insert into event_log(user_id, kind, message) values (uid, 'loja', me.name || ' conseguiu ' || it.name || '!');
  end if;
  return me;
end $$;

create or replace function public.equip_item(_slot text, _item text) returns public.characters
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); me characters;
begin
  select * into me from characters where user_id = uid for update;
  if _item is null then
    update characters set outfit = outfit - _slot where id = me.id returning * into me;
  else
    if not (_item = any(me.owned_items)) then raise exception 'Você não tem esse item.'; end if;
    if not exists (select 1 from shop_items where id = _item and slot = _slot) then raise exception 'Item não serve nesse espaço.'; end if;
    update characters set outfit = outfit || jsonb_build_object(_slot, _item) where id = me.id returning * into me;
  end if;
  return me;
end $$;

create or replace function public.place_trap(_square int) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); c jsonb := public.cfg(); me characters;
begin
  select * into me from characters where user_id = uid for update;
  if _square <= 0 or _square >= (c->>'board_size')::int then raise exception 'Casa inválida.'; end if;
  if exists (select 1 from traps where owner_id = uid and triggered_at is null) then raise exception 'Você já tem uma armadilha armada.'; end if;
  if exists (select 1 from traps where square = _square and triggered_at is null) then raise exception 'Já existe uma armadilha nessa casa. Escolha outra.'; end if;
  if me.coins < (c->>'trap_price')::int then raise exception 'Moedas insuficientes.'; end if;
  update characters set coins = coins - (c->>'trap_price')::int where id = me.id;
  insert into traps(square, owner_id) values (_square, uid);
end $$;

-- ---------------------------------------------------------------------
-- PAINEL DO DIA E RANKINGS (escondem resultados de quem ainda não jogou)
-- ---------------------------------------------------------------------
create or replace function public.today_board() returns table (
  user_id uuid, char_name text, class public.char_class, level int, outfit jsonb, progress int,
  modes_done int, moved boolean, score int, detail jsonb)
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); d date := public.game_today();
  can_see boolean := public.has_role(uid,'admin') or exists (select 1 from daily_moves where daily_moves.user_id = uid and move_date = d);
begin
  return query
  select ch.user_id, ch.name::text, ch.class, ch.level, ch.outfit, ch.progress,
    (select count(*)::int from guess_sessions gs where gs.user_id = ch.user_id and gs.puzzle_date = d and (gs.solved or gs.failed)),
    mv.id is not null,
    case when can_see or ch.user_id = uid then mv.score end,
    case when can_see or ch.user_id = uid then mv.mode_points end
  from characters ch
  left join daily_moves mv on mv.user_id = ch.user_id and mv.move_date = d
  order by mv.score desc nulls last, ch.name;
end $$;

create or replace function public.ranking_period(_kind text) returns table (
  user_id uuid, char_name text, class public.char_class, level int, outfit jsonb, total int, days int)
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); d date := public.game_today(); start date;
  incl_today boolean := public.has_role(uid,'admin') or exists (select 1 from daily_moves where daily_moves.user_id = uid and move_date = d);
begin
  start := case _kind when 'semana' then date_trunc('week', d)::date when 'mes' then date_trunc('month', d)::date else '2000-01-01'::date end;
  return query
  select ch.user_id, ch.name::text, ch.class, ch.level, ch.outfit,
         coalesce(sum(mv.score),0)::int, count(mv.id)::int
  from characters ch
  left join daily_moves mv on mv.user_id = ch.user_id and mv.move_date >= start
       and (mv.move_date < d or incl_today)
  group by ch.user_id, ch.name, ch.class, ch.level, ch.outfit
  order by 6 desc, ch.name;
end $$;

-- ---------------------------------------------------------------------
-- ADMINISTRAÇÃO (toda função confere o papel no banco)
-- ---------------------------------------------------------------------
create or replace function public.admin_players() returns table (
  user_id uuid, email text, username text, status text, is_admin boolean,
  char_name text, class public.char_class, level int, xp_total int, coins int, progress int, created_at timestamptz)
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform public.assert_admin();
  return query
  select p.id, u.email::text, p.username::text, p.status, public.has_role(p.id,'admin'),
         ch.name::text, ch.class, ch.level, ch.xp_total, ch.coins, ch.progress, p.created_at
  from profiles p join auth.users u on u.id = p.id
  left join characters ch on ch.user_id = p.id
  order by p.created_at;
end $$;

create or replace function public.admin_set_status(_user uuid, _status text, _reason text) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare b profiles;
begin
  perform public.assert_admin();
  if _user = auth.uid() then raise exception 'Você não pode bloquear a própria conta.'; end if;
  select * into b from profiles where id = _user;
  update profiles set status = _status where id = _user;
  perform public.audit('status', _user::text, to_jsonb(b), jsonb_build_object('status', _status), _reason);
end $$;

create or replace function public.admin_adjust(_user uuid, _coins int, _xp int, _progress int, _reason text) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare b characters; a characters;
begin
  perform public.assert_admin();
  if coalesce(trim(_reason),'') = '' then raise exception 'Informe o motivo do ajuste.'; end if;
  select * into b from characters where user_id = _user for update;
  if b.id is null then raise exception 'Jogador sem personagem.'; end if;
  update characters set
    coins = greatest(0, coins + coalesce(_coins,0)),
    xp_total = greatest(0, xp_total + coalesce(_xp,0)),
    level = public.level_for_xp(greatest(0, xp_total + coalesce(_xp,0))),
    progress = coalesce(greatest(0,_progress), progress)
  where id = b.id returning * into a;
  perform public.audit('ajuste', _user::text, to_jsonb(b), to_jsonb(a), _reason);
end $$;

create or replace function public.admin_reset_day(_user uuid, _date date, _reason text) returns void
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform public.assert_admin();
  if exists (select 1 from daily_moves where user_id = _user and move_date = _date) then
    raise exception 'Esse jogador já andou nesse dia. Use o ajuste manual de posição e moedas.';
  end if;
  perform public.audit('reset_dia', _user::text,
    (select jsonb_agg(to_jsonb(g)) from guesses g where user_id = _user and puzzle_date = _date), null, _reason);
  delete from guesses where user_id = _user and puzzle_date = _date;
  delete from guess_sessions where user_id = _user and puzzle_date = _date;
end $$;

create or replace function public.admin_set_config(_patch jsonb, _reason text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare old jsonb := public.cfg(); new_cfg jsonb;
begin
  perform public.assert_admin();
  new_cfg := old || _patch;
  update game_config set active = false where active;
  insert into game_config(config, active, created_by) values (new_cfg, true, auth.uid());
  perform public.audit('config', null, old, new_cfg, _reason);
  return new_cfg;
end $$;

create or replace function public.admin_save_media(_id int, _silhouette text, _pixel_levels jsonb, _description text) returns void
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform public.assert_admin();
  insert into pokemon_media(pokemon_id, silhouette, pixel_levels, description, updated_at)
  values (_id, _silhouette, _pixel_levels, _description, now())
  on conflict (pokemon_id) do update set
    silhouette   = coalesce(excluded.silhouette, pokemon_media.silhouette),
    pixel_levels = coalesce(excluded.pixel_levels, pokemon_media.pixel_levels),
    description  = coalesce(excluded.description, pokemon_media.description),
    updated_at   = now();
end $$;

create or replace function public.admin_media_status() returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform public.assert_admin();
  return jsonb_build_object(
    'images', (select count(*) from pokemon_media where silhouette is not null and pixel_levels is not null),
    'descriptions', (select count(*) from pokemon_media where description is not null),
    'missing_ids', (select coalesce(jsonb_agg(p.id order by p.id), '[]'::jsonb) from pokemon p
                    left join pokemon_media pm on pm.pokemon_id = p.id
                    where pm.silhouette is null or pm.pixel_levels is null or pm.description is null));
end $$;

create or replace function public.admin_set_square(_idx int, _kind text, _value int, _reason text) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare b board_squares;
begin
  perform public.assert_admin();
  select * into b from board_squares where idx = _idx;
  update board_squares set kind = _kind, value = coalesce(_value,0) where idx = _idx;
  perform public.audit('casa', _idx::text, to_jsonb(b), jsonb_build_object('kind',_kind,'value',_value), _reason);
end $$;

-- ---------------------------------------------------------------------
-- SEGURANÇA: RLS + permissões
-- ---------------------------------------------------------------------
alter table public.game_config     enable row level security;
alter table public.profiles        enable row level security;
alter table public.user_roles      enable row level security;
alter table public.pokemon         enable row level security;
alter table public.pokemon_media   enable row level security;
alter table public.daily_puzzles   enable row level security;
alter table public.characters      enable row level security;
alter table public.guess_sessions  enable row level security;
alter table public.guesses         enable row level security;
alter table public.daily_moves     enable row level security;
alter table public.board_squares   enable row level security;
alter table public.traps           enable row level security;
alter table public.shop_items      enable row level security;
alter table public.event_log       enable row level security;
alter table public.admin_audit_log enable row level security;

-- Ninguém do navegador escreve direto em tabela nenhuma.
revoke all on all tables    in schema public from anon, authenticated;
revoke all on all sequences in schema public from anon, authenticated;

grant select on public.game_config, public.profiles, public.user_roles, public.pokemon, public.characters,
                public.guess_sessions, public.guesses, public.daily_moves, public.board_squares, public.traps,
                public.shop_items, public.event_log, public.admin_audit_log to authenticated;

drop policy if exists p_cfg on public.game_config;       create policy p_cfg on public.game_config for select to authenticated using (true);
drop policy if exists p_prof on public.profiles;         create policy p_prof on public.profiles for select to authenticated using (true);
drop policy if exists p_roles on public.user_roles;      create policy p_roles on public.user_roles for select to authenticated using (user_id = auth.uid() or public.is_admin());
drop policy if exists p_poke on public.pokemon;          create policy p_poke on public.pokemon for select to authenticated using (true);
drop policy if exists p_char on public.characters;       create policy p_char on public.characters for select to authenticated using (true);
drop policy if exists p_sess on public.guess_sessions;   create policy p_sess on public.guess_sessions for select to authenticated using (user_id = auth.uid() or public.is_admin());
drop policy if exists p_guess on public.guesses;         create policy p_guess on public.guesses for select to authenticated using (user_id = auth.uid() or public.is_admin());
drop policy if exists p_moves on public.daily_moves;     create policy p_moves on public.daily_moves for select to authenticated using (user_id = auth.uid() or public.is_admin());
drop policy if exists p_sq on public.board_squares;      create policy p_sq on public.board_squares for select to authenticated using (true);
drop policy if exists p_traps on public.traps;           create policy p_traps on public.traps for select to authenticated using ((owner_id = auth.uid() and triggered_at is null) or public.is_admin());
drop policy if exists p_shop on public.shop_items;       create policy p_shop on public.shop_items for select to authenticated using (true);
drop policy if exists p_events on public.event_log;      create policy p_events on public.event_log for select to authenticated using (true);
drop policy if exists p_audit on public.admin_audit_log; create policy p_audit on public.admin_audit_log for select to authenticated using (public.is_admin());
-- pokemon_media e daily_puzzles: sem política = respostas invisíveis para jogadores.

-- Funções: só as ações do jogo ficam acessíveis.
revoke execute on all functions in schema public from public, anon, authenticated;
grant execute on function public.username_available(text) to anon, authenticated;
grant execute on function
  public.is_admin(), public.create_character(text, public.char_class),
  public.puzzle_state(public.puzzle_mode), public.make_guess(public.puzzle_mode, int),
  public.today_overview(), public.move_today(), public.buy_item(text), public.equip_item(text, text),
  public.place_trap(int), public.today_board(), public.ranking_period(text),
  public.admin_players(), public.admin_set_status(uuid, text, text), public.admin_adjust(uuid, int, int, int, text),
  public.admin_reset_day(uuid, date, text), public.admin_set_config(jsonb, text),
  public.admin_save_media(int, text, jsonb, text), public.admin_media_status(), public.admin_set_square(int, text, int, text)
to authenticated;
-- usadas dentro das políticas RLS:
grant execute on function public.has_role(uuid, public.app_role) to authenticated;

-- Tempo real: o tabuleiro e o mural atualizam sozinhos.
do $$ begin
  begin alter publication supabase_realtime add table public.characters; exception when duplicate_object then null; end;
  begin alter publication supabase_realtime add table public.event_log;  exception when duplicate_object then null; end;
end $$;
