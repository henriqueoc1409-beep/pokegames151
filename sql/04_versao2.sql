-- =====================================================================
-- TRILHA 151 — VERSÃO 2
-- Mapa grande com bifurcações, rodada diária (menos tentativas vence),
-- roleta da sorte, ajudas no desafio e temporadas.
-- Rode UMA vez no SQL Editor, depois de 01 e 02 já terem sido rodados.
-- Mantém contas, personagens, moedas, nível, visual e a Pokédex importada.
-- As posições no tabuleiro recomeçam do início.
-- =====================================================================

-- 1) Remove o tabuleiro antigo -----------------------------------------
drop function if exists public.move_today();
drop function if exists public.today_board();
drop function if exists public.ranking_period(text);
drop function if exists public.place_trap(int);
drop function if exists public.admin_players();
drop function if exists public.admin_adjust(uuid, int, int, int, text);
drop function if exists public.admin_set_square(int, text, int, text);
drop table if exists public.daily_moves cascade;
drop table if exists public.traps cascade;
drop table if exists public.board_squares cascade;
alter table public.characters drop column if exists progress;
alter table public.characters drop column if exists best_lap;

-- 2) Novas tabelas e colunas -------------------------------------------
create table if not exists public.board_nodes (
  id     int primary key,
  x      int not null,
  y      int not null,
  kind   text not null check (kind in ('inicio','normal','bifurcacao','avanco','recuo','bau','xp','raio','troca','pagamento','carta','castelo')),
  value  int not null default 0,
  region text not null,
  branch text not null check (branch in ('tronco','seguro','arriscado')),
  next_a int,          -- caminho padrão (seguro)
  next_b int,          -- caminho arriscado (só nas bifurcações)
  dist   int not null  -- casas que faltam até o Castelo pelo caminho mais curto
);

create table if not exists public.seasons (
  id         serial primary key,
  started_on date not null,
  status     text not null default 'ativa' check (status in ('ativa','encerrada')),
  ended_on   date
);

create table if not exists public.season_results (
  season_id int not null references public.seasons(id),
  user_id   uuid not null references auth.users(id) on delete cascade,
  rank      int not null,
  primary key (season_id, user_id)
);

alter table public.characters
  add column if not exists node         int not null default 0,
  add column if not exists path         int[] not null default '{0}',
  add column if not exists route        jsonb not null default '{}'::jsonb,
  add column if not exists hints        int not null default 1 check (hints >= 0),
  add column if not exists retries      int not null default 1 check (retries >= 0),
  add column if not exists bonus_steps  int not null default 0,
  add column if not exists arrived_rank int,
  add column if not exists arrived_at   timestamptz;
update public.characters set node = 0, path = '{0}', route = '{}'::jsonb, arrived_rank = null, arrived_at = null, last_move_date = null;

alter table public.guess_sessions
  add column if not exists hints_used   int not null default 0,
  add column if not exists retries_used int not null default 0;
alter table public.guesses add column if not exists annulled boolean not null default false;

create table public.daily_moves (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references auth.users(id) on delete cascade,
  move_date   date not null,
  modes       jsonb not null,
  base_steps  int not null,
  roll        int not null,
  bonus_steps int not null,
  from_node   int not null,
  to_node     int not null,
  xp_gained   int not null,
  coins_gained int not null,
  events      jsonb not null default '[]'::jsonb,
  created_at  timestamptz not null default now(),
  unique (user_id, move_date)
);

create table public.traps (
  id           uuid primary key default gen_random_uuid(),
  node         int not null,
  owner_id     uuid not null references auth.users(id) on delete cascade,
  created_at   timestamptz not null default now(),
  triggered_by uuid,
  triggered_at timestamptz
);
create unique index traps_one_per_node  on public.traps(node) where triggered_at is null;
create unique index traps_one_per_owner on public.traps(owner_id) where triggered_at is null;

create table if not exists public.round_days (d date primary key, settled_at timestamptz not null default now());
create table if not exists public.round_results (
  d            date not null,
  user_id      uuid not null references auth.users(id) on delete cascade,
  rank         int not null,
  attempts     int not null,
  modes_solved int not null,
  bonus_steps  int not null default 0,
  bonus_coins  int not null default 0,
  primary key (d, user_id)
);
create table if not exists public.daily_spins (
  user_id    uuid not null references auth.users(id) on delete cascade,
  d          date not null,
  prize      text not null,
  created_at timestamptz not null default now(),
  primary key (user_id, d)
);

-- 3) Regras novas (mantém as antigas) ----------------------------------
update public.game_config set config = config || '{
  "steps_table": {"1":5,"2":4,"3":3,"4":2,"5":1,"6":1,"7":0},
  "roll_min": 1, "roll_max": 3, "arqueiro_min_die": 2,
  "unsolved_rank_attempts": 10,
  "round_bonus_steps": [3,2,1], "round_bonus_coins": [100,50,0],
  "salary_base": 40, "salary_per_level": 5,
  "castle_prizes": [500,300,150], "season_arrivals": 3,
  "hint_price": 30, "retry_price": 50, "max_hints_per_mode": 3,
  "xp_per_step": 15, "coins_per_step": 3, "xp_daily_bonus": 20,
  "card_coins_win": 50, "card_coins_lose": 30, "card_steps": 3
}'::jsonb where active;

insert into public.seasons (started_on) select public.game_today() where not exists (select 1 from public.seasons);

-- 4) Mapa (228 casas) ---------------------------------------------------
insert into public.board_nodes (id,x,y,kind,value,region,branch,next_a,next_b,dist) values
(0,300,160,'inicio',0,'Floresta','tronco',1,null,163),
(1,360,160,'normal',0,'Floresta','tronco',2,null,162),
(2,420,160,'normal',0,'Floresta','tronco',3,null,161),
(3,480,160,'carta',0,'Floresta','tronco',4,null,160),
(4,540,160,'normal',0,'Floresta','tronco',5,null,159),
(5,600,160,'normal',0,'Floresta','tronco',6,null,158),
(6,660,160,'pagamento',0,'Floresta','tronco',7,null,157),
(7,720,160,'normal',0,'Floresta','tronco',8,null,156),
(8,780,160,'normal',0,'Floresta','tronco',9,null,155),
(9,840,160,'bau',0,'Floresta','tronco',10,null,154),
(10,900,160,'carta',0,'Floresta','tronco',11,null,153),
(11,960,160,'xp',0,'Floresta','tronco',12,null,152),
(12,1020,160,'normal',0,'Floresta','tronco',13,null,151),
(13,1080,160,'avanco',3,'Floresta','tronco',14,null,150),
(14,1140,160,'normal',0,'Floresta','tronco',15,null,149),
(15,1200,160,'normal',0,'Floresta','tronco',16,null,148),
(16,1260,160,'normal',0,'Floresta','tronco',17,null,147),
(17,1320,160,'troca',0,'Floresta','tronco',18,null,146),
(18,1380,160,'pagamento',0,'Floresta','tronco',19,null,145),
(19,1440,160,'bau',0,'Floresta','tronco',20,null,144),
(20,1500,160,'normal',0,'Floresta','tronco',21,null,143),
(21,1560,160,'recuo',3,'Floresta','tronco',22,null,142),
(22,1620,160,'normal',0,'Floresta','tronco',23,null,141),
(23,1680,160,'normal',0,'Floresta','tronco',24,null,140),
(24,1740,160,'raio',0,'Floresta','tronco',25,null,139),
(25,1800,160,'normal',0,'Floresta','tronco',26,null,138),
(26,1860,160,'normal',0,'Floresta','tronco',27,null,137),
(27,1920,160,'normal',0,'Floresta','tronco',28,null,136),
(28,1980,160,'normal',0,'Floresta','tronco',29,null,135),
(29,2040,160,'bau',0,'Floresta','tronco',30,null,134),
(30,2100,160,'bifurcacao',0,'Floresta','tronco',31,51,133),
(31,2151,160,'normal',0,'Bosque Antigo','seguro',32,null,140),
(32,2202,160,'normal',0,'Bosque Antigo','seguro',33,null,139),
(33,2253,160,'normal',0,'Bosque Antigo','seguro',34,null,138),
(34,2304,160,'normal',0,'Bosque Antigo','seguro',35,null,137),
(35,2355,160,'normal',0,'Bosque Antigo','seguro',36,null,136),
(36,2360,206,'bau',0,'Bosque Antigo','seguro',37,null,135),
(37,2360,257,'normal',0,'Bosque Antigo','seguro',38,null,134),
(38,2360,308,'normal',0,'Bosque Antigo','seguro',39,null,133),
(39,2360,359,'normal',0,'Bosque Antigo','seguro',40,null,132),
(40,2360,410,'normal',0,'Bosque Antigo','seguro',41,null,131),
(41,2360,460,'pagamento',0,'Bosque Antigo','seguro',42,null,130),
(42,2360,511,'normal',0,'Bosque Antigo','seguro',43,null,129),
(43,2360,562,'normal',0,'Bosque Antigo','seguro',44,null,128),
(44,2360,613,'normal',0,'Bosque Antigo','seguro',45,null,127),
(45,2360,664,'normal',0,'Bosque Antigo','seguro',46,null,126),
(46,2355,710,'xp',0,'Bosque Antigo','seguro',47,null,125),
(47,2304,710,'normal',0,'Bosque Antigo','seguro',48,null,124),
(48,2253,710,'normal',0,'Bosque Antigo','seguro',49,null,123),
(49,2202,710,'normal',0,'Bosque Antigo','seguro',50,null,122),
(50,2151,710,'normal',0,'Bosque Antigo','seguro',63,null,121),
(51,2074,200,'carta',0,'Caverna Escura','arriscado',52,null,132),
(52,2047,240,'normal',0,'Caverna Escura','arriscado',53,null,131),
(53,2021,279,'recuo',4,'Caverna Escura','arriscado',54,null,130),
(54,1995,319,'bau',0,'Caverna Escura','arriscado',55,null,129),
(55,1991,359,'carta',0,'Caverna Escura','arriscado',56,null,128),
(56,2015,400,'avanco',4,'Caverna Escura','arriscado',57,null,127),
(57,2040,441,'recuo',4,'Caverna Escura','arriscado',58,null,126),
(58,2065,482,'bau',0,'Caverna Escura','arriscado',59,null,125),
(59,2090,522,'carta',0,'Caverna Escura','arriscado',60,null,124),
(60,2100,567,'normal',0,'Caverna Escura','arriscado',61,null,123),
(61,2100,615,'bau',0,'Caverna Escura','arriscado',62,null,122),
(62,2100,662,'recuo',4,'Caverna Escura','arriscado',63,null,121),
(63,2100,710,'normal',0,'Praia','tronco',64,null,120),
(64,2042,710,'normal',0,'Praia','tronco',65,null,119),
(65,1984,710,'normal',0,'Praia','tronco',66,null,118),
(66,1926,710,'carta',0,'Praia','tronco',67,null,117),
(67,1868,710,'normal',0,'Praia','tronco',68,null,116),
(68,1810,710,'normal',0,'Praia','tronco',69,null,115),
(69,1752,710,'pagamento',0,'Praia','tronco',70,null,114),
(70,1694,710,'normal',0,'Praia','tronco',71,null,113),
(71,1635,710,'normal',0,'Praia','tronco',72,null,112),
(72,1577,710,'bau',0,'Praia','tronco',73,null,111),
(73,1519,710,'carta',0,'Praia','tronco',74,null,110),
(74,1461,710,'xp',0,'Praia','tronco',75,null,109),
(75,1403,710,'normal',0,'Praia','tronco',76,null,108),
(76,1345,710,'avanco',3,'Praia','tronco',77,null,107),
(77,1287,710,'normal',0,'Praia','tronco',78,null,106),
(78,1229,710,'normal',0,'Praia','tronco',79,null,105),
(79,1171,710,'normal',0,'Praia','tronco',80,null,104),
(80,1113,710,'troca',0,'Praia','tronco',81,null,103),
(81,1055,710,'pagamento',0,'Praia','tronco',82,null,102),
(82,997,710,'bau',0,'Praia','tronco',83,null,101),
(83,939,710,'normal',0,'Praia','tronco',84,null,100),
(84,881,710,'recuo',3,'Praia','tronco',85,null,99),
(85,823,710,'normal',0,'Praia','tronco',86,null,98),
(86,765,710,'normal',0,'Praia','tronco',87,null,97),
(87,706,710,'raio',0,'Praia','tronco',88,null,96),
(88,648,710,'normal',0,'Praia','tronco',89,null,95),
(89,590,710,'normal',0,'Praia','tronco',90,null,94),
(90,532,710,'normal',0,'Praia','tronco',91,null,93),
(91,474,710,'normal',0,'Praia','tronco',92,null,92),
(92,416,710,'bau',0,'Praia','tronco',93,null,91),
(93,358,710,'pagamento',0,'Praia','tronco',94,null,90),
(94,300,710,'bifurcacao',0,'Praia','tronco',95,117,89),
(95,253,710,'normal',0,'Cidade Portuária','seguro',96,null,97),
(96,207,710,'normal',0,'Cidade Portuária','seguro',97,null,96),
(97,160,710,'normal',0,'Cidade Portuária','seguro',98,null,95),
(98,114,710,'normal',0,'Cidade Portuária','seguro',99,null,94),
(99,67,710,'normal',0,'Cidade Portuária','seguro',100,null,93),
(100,40,729,'bau',0,'Cidade Portuária','seguro',101,null,92),
(101,40,776,'normal',0,'Cidade Portuária','seguro',102,null,91),
(102,40,822,'normal',0,'Cidade Portuária','seguro',103,null,90),
(103,40,869,'normal',0,'Cidade Portuária','seguro',104,null,89),
(104,40,915,'normal',0,'Cidade Portuária','seguro',105,null,88),
(105,40,962,'normal',0,'Cidade Portuária','seguro',106,null,87),
(106,40,1008,'pagamento',0,'Cidade Portuária','seguro',107,null,86),
(107,40,1055,'normal',0,'Cidade Portuária','seguro',108,null,85),
(108,40,1101,'normal',0,'Cidade Portuária','seguro',109,null,84),
(109,40,1148,'normal',0,'Cidade Portuária','seguro',110,null,83),
(110,40,1194,'normal',0,'Cidade Portuária','seguro',111,null,82),
(111,40,1241,'xp',0,'Cidade Portuária','seguro',112,null,81),
(112,67,1260,'normal',0,'Cidade Portuária','seguro',113,null,80),
(113,114,1260,'normal',0,'Cidade Portuária','seguro',114,null,79),
(114,160,1260,'normal',0,'Cidade Portuária','seguro',115,null,78),
(115,207,1260,'normal',0,'Cidade Portuária','seguro',116,null,77),
(116,253,1260,'normal',0,'Cidade Portuária','seguro',130,null,76),
(117,324,747,'carta',0,'Ponte Velha','arriscado',118,null,88),
(118,349,784,'normal',0,'Ponte Velha','arriscado',119,null,87),
(119,373,821,'recuo',4,'Ponte Velha','arriscado',120,null,86),
(120,398,858,'bau',0,'Ponte Velha','arriscado',121,null,85),
(121,418,895,'carta',0,'Ponte Velha','arriscado',122,null,84),
(122,395,933,'avanco',4,'Ponte Velha','arriscado',123,null,83),
(123,372,970,'recuo',4,'Ponte Velha','arriscado',124,null,82),
(124,349,1008,'bau',0,'Ponte Velha','arriscado',125,null,81),
(125,326,1046,'carta',0,'Ponte Velha','arriscado',126,null,80),
(126,303,1084,'normal',0,'Ponte Velha','arriscado',127,null,79),
(127,300,1127,'bau',0,'Ponte Velha','arriscado',128,null,78),
(128,300,1171,'recuo',4,'Ponte Velha','arriscado',129,null,77),
(129,300,1216,'carta',0,'Ponte Velha','arriscado',130,null,76),
(130,300,1260,'normal',0,'Montanha','tronco',131,null,75),
(131,355,1260,'normal',0,'Montanha','tronco',132,null,74),
(132,409,1260,'normal',0,'Montanha','tronco',133,null,73),
(133,464,1260,'carta',0,'Montanha','tronco',134,null,72),
(134,518,1260,'normal',0,'Montanha','tronco',135,null,71),
(135,573,1260,'normal',0,'Montanha','tronco',136,null,70),
(136,627,1260,'pagamento',0,'Montanha','tronco',137,null,69),
(137,682,1260,'normal',0,'Montanha','tronco',138,null,68),
(138,736,1260,'normal',0,'Montanha','tronco',139,null,67),
(139,791,1260,'bau',0,'Montanha','tronco',140,null,66),
(140,845,1260,'carta',0,'Montanha','tronco',141,null,65),
(141,900,1260,'xp',0,'Montanha','tronco',142,null,64),
(142,955,1260,'normal',0,'Montanha','tronco',143,null,63),
(143,1009,1260,'avanco',3,'Montanha','tronco',144,null,62),
(144,1064,1260,'normal',0,'Montanha','tronco',145,null,61),
(145,1118,1260,'normal',0,'Montanha','tronco',146,null,60),
(146,1173,1260,'normal',0,'Montanha','tronco',147,null,59),
(147,1227,1260,'troca',0,'Montanha','tronco',148,null,58),
(148,1282,1260,'pagamento',0,'Montanha','tronco',149,null,57),
(149,1336,1260,'bau',0,'Montanha','tronco',150,null,56),
(150,1391,1260,'normal',0,'Montanha','tronco',151,null,55),
(151,1445,1260,'recuo',3,'Montanha','tronco',152,null,54),
(152,1500,1260,'normal',0,'Montanha','tronco',153,null,53),
(153,1555,1260,'normal',0,'Montanha','tronco',154,null,52),
(154,1609,1260,'raio',0,'Montanha','tronco',155,null,51),
(155,1664,1260,'normal',0,'Montanha','tronco',156,null,50),
(156,1718,1260,'normal',0,'Montanha','tronco',157,null,49),
(157,1773,1260,'normal',0,'Montanha','tronco',158,null,48),
(158,1827,1260,'normal',0,'Montanha','tronco',159,null,47),
(159,1882,1260,'bau',0,'Montanha','tronco',160,null,46),
(160,1936,1260,'pagamento',0,'Montanha','tronco',161,null,45),
(161,1991,1260,'carta',0,'Montanha','tronco',162,null,44),
(162,2045,1260,'normal',0,'Montanha','tronco',163,null,43),
(163,2100,1260,'bifurcacao',0,'Montanha','tronco',164,186,42),
(164,2147,1260,'normal',0,'Estrada do Vulcão','seguro',165,null,50),
(165,2193,1260,'normal',0,'Estrada do Vulcão','seguro',166,null,49),
(166,2240,1260,'normal',0,'Estrada do Vulcão','seguro',167,null,48),
(167,2286,1260,'normal',0,'Estrada do Vulcão','seguro',168,null,47),
(168,2333,1260,'normal',0,'Estrada do Vulcão','seguro',169,null,46),
(169,2360,1279,'bau',0,'Estrada do Vulcão','seguro',170,null,45),
(170,2360,1326,'normal',0,'Estrada do Vulcão','seguro',171,null,44),
(171,2360,1372,'normal',0,'Estrada do Vulcão','seguro',172,null,43),
(172,2360,1419,'normal',0,'Estrada do Vulcão','seguro',173,null,42),
(173,2360,1465,'normal',0,'Estrada do Vulcão','seguro',174,null,41),
(174,2360,1512,'normal',0,'Estrada do Vulcão','seguro',175,null,40),
(175,2360,1558,'pagamento',0,'Estrada do Vulcão','seguro',176,null,39),
(176,2360,1605,'normal',0,'Estrada do Vulcão','seguro',177,null,38),
(177,2360,1651,'normal',0,'Estrada do Vulcão','seguro',178,null,37),
(178,2360,1698,'normal',0,'Estrada do Vulcão','seguro',179,null,36),
(179,2360,1744,'normal',0,'Estrada do Vulcão','seguro',180,null,35),
(180,2360,1791,'xp',0,'Estrada do Vulcão','seguro',181,null,34),
(181,2333,1810,'normal',0,'Estrada do Vulcão','seguro',182,null,33),
(182,2286,1810,'normal',0,'Estrada do Vulcão','seguro',183,null,32),
(183,2240,1810,'normal',0,'Estrada do Vulcão','seguro',184,null,31),
(184,2193,1810,'normal',0,'Estrada do Vulcão','seguro',185,null,30),
(185,2147,1810,'normal',0,'Estrada do Vulcão','seguro',199,null,29),
(186,2076,1297,'carta',0,'Cratera','arriscado',187,null,41),
(187,2051,1334,'normal',0,'Cratera','arriscado',188,null,40),
(188,2027,1371,'recuo',4,'Cratera','arriscado',189,null,39),
(189,2002,1408,'bau',0,'Cratera','arriscado',190,null,38),
(190,1982,1445,'carta',0,'Cratera','arriscado',191,null,37),
(191,2005,1483,'avanco',4,'Cratera','arriscado',192,null,36),
(192,2028,1520,'recuo',4,'Cratera','arriscado',193,null,35),
(193,2051,1558,'bau',0,'Cratera','arriscado',194,null,34),
(194,2074,1596,'carta',0,'Cratera','arriscado',195,null,33),
(195,2097,1634,'normal',0,'Cratera','arriscado',196,null,32),
(196,2100,1677,'bau',0,'Cratera','arriscado',197,null,31),
(197,2100,1721,'recuo',4,'Cratera','arriscado',198,null,30),
(198,2100,1766,'carta',0,'Cratera','arriscado',199,null,29),
(199,2100,1810,'normal',0,'Planalto Real','tronco',200,null,28),
(200,2036,1810,'normal',0,'Planalto Real','tronco',201,null,27),
(201,1971,1810,'normal',0,'Planalto Real','tronco',202,null,26),
(202,1907,1810,'carta',0,'Planalto Real','tronco',203,null,25),
(203,1843,1810,'normal',0,'Planalto Real','tronco',204,null,24),
(204,1779,1810,'normal',0,'Planalto Real','tronco',205,null,23),
(205,1714,1810,'pagamento',0,'Planalto Real','tronco',206,null,22),
(206,1650,1810,'normal',0,'Planalto Real','tronco',207,null,21),
(207,1586,1810,'normal',0,'Planalto Real','tronco',208,null,20),
(208,1521,1810,'bau',0,'Planalto Real','tronco',209,null,19),
(209,1457,1810,'carta',0,'Planalto Real','tronco',210,null,18),
(210,1393,1810,'xp',0,'Planalto Real','tronco',211,null,17),
(211,1329,1810,'normal',0,'Planalto Real','tronco',212,null,16),
(212,1264,1810,'avanco',3,'Planalto Real','tronco',213,null,15),
(213,1200,1810,'normal',0,'Planalto Real','tronco',214,null,14),
(214,1136,1810,'normal',0,'Planalto Real','tronco',215,null,13),
(215,1071,1810,'normal',0,'Planalto Real','tronco',216,null,12),
(216,1007,1810,'troca',0,'Planalto Real','tronco',217,null,11),
(217,943,1810,'pagamento',0,'Planalto Real','tronco',218,null,10),
(218,879,1810,'bau',0,'Planalto Real','tronco',219,null,9),
(219,814,1810,'normal',0,'Planalto Real','tronco',220,null,8),
(220,750,1810,'recuo',3,'Planalto Real','tronco',221,null,7),
(221,686,1810,'normal',0,'Planalto Real','tronco',222,null,6),
(222,621,1810,'normal',0,'Planalto Real','tronco',223,null,5),
(223,557,1810,'raio',0,'Planalto Real','tronco',224,null,4),
(224,493,1810,'normal',0,'Planalto Real','tronco',225,null,3),
(225,429,1810,'normal',0,'Planalto Real','tronco',226,null,2),
(226,364,1810,'normal',0,'Planalto Real','tronco',227,null,1),
(227,300,1810,'castelo',0,'Castelo da Liga','tronco',null,null,0);

-- 5) Funções do jogo ----------------------------------------------------
create or replace function public.mode_steps(_attempts int, _solved boolean) returns int
language sql stable security definer set search_path = public, extensions as $$
  select case when not _solved then 0
              else coalesce((cfg()->'steps_table'->>least(greatest(_attempts,1),7)::text)::int, 0) end
$$;

-- tentativas que contam no ranking da rodada: palpites feitos + 1 por ajuda usada
create or replace function public.rank_attempts(_attempts int, _solved boolean, _hints int, _retries int) returns int
language sql stable security definer set search_path = public, extensions as $$
  select case when _solved then _attempts + 2 * _retries + _hints
              else (cfg()->>'unsolved_rank_attempts')::int end
$$;

create or replace function public.start_new_season() returns void
language plpgsql security definer set search_path = public, extensions as $$
declare nid int;
begin
  update seasons set status = 'encerrada', ended_on = coalesce(ended_on, game_today()) where status = 'ativa';
  insert into seasons(started_on) values (game_today()) returning id into nid;
  update characters set node = 0, path = '{0}', route = '{}'::jsonb, arrived_rank = null, arrived_at = null, bonus_steps = 0;
  update traps set triggered_at = now() where triggered_at is null;
  insert into event_log(kind, message) values ('temporada', 'A temporada ' || nid || ' começou! Todos voltaram para a largada.');
end $$;

-- Fecha rodadas passadas e vira a temporada. Chamada automaticamente pelo jogo.
create or replace function public.settle() returns void
language plpgsql security definer set search_path = public, extensions as $$
declare d date := game_today(); c jsonb := cfg(); r record; x record; pos int; bs int; bc int; s seasons; names text := '';
begin
  perform pg_advisory_xact_lock(151151);
  for r in select distinct puzzle_date as pd from guess_sessions
           where puzzle_date < d and puzzle_date not in (select rd.d from round_days rd) order by 1 loop
    insert into round_days(d) values (r.pd);
    pos := 0; names := '';
    for x in
      select p.user_id,
             sum(public.rank_attempts(coalesce(gs.attempts,0), coalesce(gs.solved,false), coalesce(gs.hints_used,0), coalesce(gs.retries_used,0)))::int as total,
             count(*) filter (where gs.solved)::int as solved,
             max(gs.finished_at) as fin
      from (select distinct user_id from guess_sessions where puzzle_date = r.pd) p
      join characters ch on ch.user_id = p.user_id
      cross join (select mode from daily_puzzles where puzzle_date = r.pd) m
      left join guess_sessions gs on gs.user_id = p.user_id and gs.puzzle_date = r.pd and gs.mode = m.mode
      group by p.user_id
      order by 2 asc, 4 asc nulls last
    loop
      pos := pos + 1;
      bs := coalesce((c->'round_bonus_steps'->>(pos-1))::int, 0);
      bc := coalesce((c->'round_bonus_coins'->>(pos-1))::int, 0);
      insert into round_results(d, user_id, rank, attempts, modes_solved, bonus_steps, bonus_coins)
      values (r.pd, x.user_id, pos, x.total, x.solved, bs, bc);
      if bs > 0 or bc > 0 then
        update characters set bonus_steps = bonus_steps + bs, coins = coins + bc where user_id = x.user_id;
      end if;
      if pos = 1 then
        names := (select name from characters where user_id = x.user_id) || ' venceu a rodada de ' || to_char(r.pd, 'DD/MM') || ' com ' || x.total || ' tentativas';
      end if;
    end loop;
    if names <> '' then insert into event_log(kind, message) values ('rodada', names || '.'); end if;
  end loop;

  select * into s from seasons order by id desc limit 1;
  if s.status = 'encerrada' and s.ended_on < d then perform public.start_new_season(); end if;
end $$;

-- Anda casa a casa seguindo as escolhas de caminho do jogador. Paga salário ao passar no "Dia de pagamento".
create or replace function public.walk(_cid uuid, _steps int) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare ch characters; n board_nodes; cur int; p int[]; sal int := 0; c jsonb := cfg(); i int;
begin
  select * into ch from characters where id = _cid;
  cur := ch.node; p := ch.path;
  for i in 1..greatest(_steps,0) loop
    select * into n from board_nodes where id = cur;
    exit when n.kind = 'castelo' or n.next_a is null;
    cur := case when n.next_b is not null and ch.route->>(n.id::text) = 'b' then n.next_b else n.next_a end;
    p := p || cur;
    if (select kind from board_nodes where id = cur) = 'pagamento' then
      sal := sal + (c->>'salary_base')::int + (c->>'salary_per_level')::int * ch.level;
    end if;
  end loop;
  update characters set node = cur, path = p, coins = coins + sal where id = _cid;
  return jsonb_build_object('node', cur, 'salary', sal);
end $$;

-- Volta casas pelo caminho que o próprio jogador fez.
create or replace function public.go_back(_cid uuid, _k int) returns int
language plpgsql security definer set search_path = public, extensions as $$
declare p int[]; l int;
begin
  select path into p from characters where id = _cid;
  l := greatest(1, coalesce(array_length(p,1),1) - _k);
  update characters set path = p[1:l], node = p[l] where id = _cid;
  return p[l];
end $$;

create or replace function public.check_arrival(_cid uuid) returns text
language plpgsql security definer set search_path = public, extensions as $$
declare ch characters; s seasons; rk int; prize int; c jsonb := cfg();
begin
  select * into ch from characters where id = _cid for update;
  if ch.arrived_rank is not null or (select kind from board_nodes where id = ch.node) <> 'castelo' then return null; end if;
  select * into s from seasons order by id desc limit 1 for update;
  rk := (select count(*) from characters where arrived_rank is not null) + 1;
  prize := case when s.status = 'ativa' then coalesce((c->'castle_prizes'->>(rk-1))::int, 0) else 0 end;
  update characters set arrived_rank = rk, arrived_at = now(), coins = coins + prize where id = _cid;
  if s.status = 'ativa' and rk <= (c->>'season_arrivals')::int then
    insert into season_results(season_id, user_id, rank) values (s.id, ch.user_id, rk) on conflict do nothing;
  end if;
  insert into event_log(user_id, kind, message) values (ch.user_id, 'castelo', ch.name || ' chegou ao Castelo da Liga em ' || rk || 'º lugar!');
  if s.status = 'ativa' and rk >= (c->>'season_arrivals')::int then
    update seasons set status = 'encerrada', ended_on = game_today() where id = s.id;
    insert into event_log(kind, message) values ('temporada', 'Temporada ' || s.id || ' encerrada! Amanhã começa uma nova.');
  end if;
  return 'Você chegou ao Castelo da Liga em ' || rk || 'º lugar!' || case when prize > 0 then ' Prêmio: ' || prize || ' moedas.' else '' end;
end $$;

-- Desafio: estado do modo, com dicas e "tente outra vez"
create or replace function public.puzzle_state(_mode public.puzzle_mode) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); d date := public.game_today();
  ans int; a pokemon; s guess_sessions; media pokemon_media; clue jsonb := '{}'::jsonb;
  moved boolean; finished boolean; lvl int; n int; made int; hints jsonb := '[]'::jsonb; last guesses;
begin
  perform public.ensure_puzzles(d);
  select pokemon_id into ans from daily_puzzles where puzzle_date = d and mode = _mode;
  if ans is null then return jsonb_build_object('mode', _mode, 'date', d, 'available', false); end if;
  select * into a from pokemon where id = ans;
  select * into s from guess_sessions where user_id = uid and puzzle_date = d and mode = _mode;
  moved := exists (select 1 from daily_moves where user_id = uid and move_date = d);
  finished := coalesce(s.solved,false) or coalesce(s.failed,false) or moved;
  made := coalesce(s.attempts,0) + coalesce(s.retries_used,0);
  select * into media from pokemon_media where pokemon_id = ans;

  if _mode = 'descricao' then
    clue := jsonb_build_object('text', media.description);
  elsif _mode = 'silhueta' then
    clue := jsonb_build_object('image', media.silhouette, 'zoom_step', made);
  elsif _mode = 'cartao' then
    n := jsonb_array_length(media.pixel_levels);
    lvl := case when finished then n - 1 else least(made, n - 2) end;
    clue := jsonb_build_object('image', media.pixel_levels->>lvl, 'level', lvl, 'levels', n);
  end if;

  if coalesce(s.hints_used,0) >= 1 then hints := hints || to_jsonb('Tipo principal: ' || a.type1); end if;
  if coalesce(s.hints_used,0) >= 2 then hints := hints || to_jsonb('Habitat: ' || a.habitat); end if;
  if coalesce(s.hints_used,0) >= 3 then hints := hints || to_jsonb('Começa com a letra ' || left(a.name,1)); end if;

  select * into last from guesses where user_id = uid and puzzle_date = d and mode = _mode order by id desc limit 1;

  return jsonb_build_object(
    'mode', _mode, 'date', d, 'available', true,
    'attempts', coalesce(s.attempts,0),
    'solved', coalesce(s.solved,false),
    'failed', coalesce(s.failed,false) or (moved and not coalesce(s.solved,false)),
    'finished', finished,
    'max_guesses', (cfg()->>'max_guesses')::int,
    'steps', public.mode_steps(coalesce(s.attempts,0), coalesce(s.solved,false)),
    'rank_attempts', case when coalesce(s.solved,false) then public.rank_attempts(s.attempts, true, s.hints_used, s.retries_used) end,
    'hints_used', coalesce(s.hints_used,0), 'retries_used', coalesce(s.retries_used,0),
    'max_hints', (cfg()->>'max_hints_per_mode')::int,
    'hints', hints,
    'can_retry', not finished and coalesce(s.retries_used,0) < 1 and last.id is not null and not last.correct and not last.annulled,
    'clue', clue,
    'answer', case when finished then jsonb_build_object('id', a.id, 'name', a.name) end,
    'guesses', coalesce((select jsonb_agg(jsonb_build_object('pokemon_id', pokemon_id, 'correct', correct, 'annulled', annulled, 'feedback', feedback) order by id)
                         from guesses where user_id = uid and puzzle_date = d and mode = _mode), '[]'::jsonb)
  );
end $$;

create or replace function public.use_hint(_mode public.puzzle_mode) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); d date := public.game_today(); s guess_sessions; me characters;
begin
  if exists (select 1 from daily_moves where user_id = uid and move_date = d) then raise exception 'Você já andou hoje.'; end if;
  perform public.ensure_puzzles(d);
  if not exists (select 1 from daily_puzzles where puzzle_date = d and mode = _mode) then raise exception 'Modo indisponível hoje.'; end if;
  insert into guess_sessions(user_id, puzzle_date, mode) values (uid, d, _mode) on conflict do nothing;
  select * into s from guess_sessions where user_id = uid and puzzle_date = d and mode = _mode for update;
  if s.solved or s.failed then raise exception 'Você já concluiu este modo.'; end if;
  if s.hints_used >= (public.cfg()->>'max_hints_per_mode')::int then raise exception 'Você já usou todas as dicas deste modo.'; end if;
  select * into me from characters where user_id = uid for update;
  if me.hints < 1 then raise exception 'Você não tem dicas. Compre na loja ou ganhe na roleta.'; end if;
  update characters set hints = hints - 1 where id = me.id;
  update guess_sessions set hints_used = hints_used + 1 where user_id = uid and puzzle_date = d and mode = _mode;
  return public.puzzle_state(_mode);
end $$;

create or replace function public.use_retry(_mode public.puzzle_mode) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); d date := public.game_today(); s guess_sessions; me characters; last guesses;
begin
  if exists (select 1 from daily_moves where user_id = uid and move_date = d) then raise exception 'Você já andou hoje.'; end if;
  select * into s from guess_sessions where user_id = uid and puzzle_date = d and mode = _mode for update;
  if s.user_id is null then raise exception 'Faça um palpite antes.'; end if;
  if s.solved or s.failed then raise exception 'Você já concluiu este modo.'; end if;
  if s.retries_used >= 1 then raise exception 'Só dá para usar Tente outra vez uma vez por modo.'; end if;
  select * into last from guesses where user_id = uid and puzzle_date = d and mode = _mode order by id desc limit 1;
  if last.id is null or last.correct or last.annulled then raise exception 'Use logo depois de um palpite errado.'; end if;
  select * into me from characters where user_id = uid for update;
  if me.retries < 1 then raise exception 'Você não tem Tente outra vez. Compre na loja ou ganhe na roleta.'; end if;
  update guesses set annulled = true where id = last.id;
  update guess_sessions set attempts = attempts - 1, retries_used = retries_used + 1 where user_id = uid and puzzle_date = d and mode = _mode;
  update characters set retries = retries - 1 where id = me.id;
  return public.puzzle_state(_mode);
end $$;

create or replace function public.buy_help(_kind text) returns public.characters
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); me characters; price int;
begin
  if _kind not in ('dica','retry') then raise exception 'Ajuda inexistente.'; end if;
  price := (public.cfg()->>(case _kind when 'dica' then 'hint_price' else 'retry_price' end))::int;
  select * into me from characters where user_id = uid for update;
  if me.coins < price then raise exception 'Moedas insuficientes.'; end if;
  update characters set coins = coins - price,
    hints = hints + case when _kind = 'dica' then 1 else 0 end,
    retries = retries + case when _kind = 'retry' then 1 else 0 end
  where id = me.id returning * into me;
  return me;
end $$;

-- Roleta da sorte: uma vez por dia
create or replace function public.spin_wheel() returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); d date := public.game_today(); r numeric := random(); idx int; me characters;
  labels text[] := array['30 moedas','Dica','+2 casas','Nada','60 moedas','Tente outra vez'];
begin
  select * into me from characters where user_id = uid for update;
  if me.id is null then raise exception 'Crie seu personagem primeiro.'; end if;
  if exists (select 1 from daily_spins where user_id = uid and daily_spins.d = game_today()) then raise exception 'Você já girou a roleta hoje. Volte amanhã!'; end if;
  idx := case when r < .28 then 0 when r < .48 then 1 when r < .60 then 2 when r < .78 then 3 when r < .90 then 4 else 5 end;
  update characters set
    coins = coins + case idx when 0 then 30 when 4 then 60 else 0 end,
    hints = hints + case when idx = 1 then 1 else 0 end,
    bonus_steps = bonus_steps + case when idx = 2 then 2 else 0 end,
    retries = retries + case when idx = 5 then 1 else 0 end
  where id = me.id;
  insert into daily_spins(user_id, d, prize) values (uid, d, labels[idx+1]);
  return jsonb_build_object('index', idx, 'prize', labels[idx+1]);
end $$;

create or replace function public.set_route(_fork int, _choice text) returns public.characters
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); me characters;
begin
  if _choice not in ('a','b') then raise exception 'Escolha inválida.'; end if;
  if not exists (select 1 from board_nodes where id = _fork and next_b is not null) then raise exception 'Isso não é uma bifurcação.'; end if;
  update characters set route = route || jsonb_build_object(_fork::text, _choice) where user_id = uid returning * into me;
  return me;
end $$;

create or replace function public.today_overview() returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); d date := public.game_today(); m public.puzzle_mode;
  modes jsonb := '{}'::jsonb; s guess_sessions; avail boolean; steps int := 0; ra int := 0; done int := 0; mv daily_moves; sp daily_spins; se seasons;
begin
  perform public.settle();
  perform public.ensure_puzzles(d);
  select * into mv from daily_moves where user_id = uid and move_date = d;
  select * into sp from daily_spins where user_id = uid and daily_spins.d = game_today();
  select * into se from seasons order by id desc limit 1;
  foreach m in array enum_range(null::public.puzzle_mode) loop
    s := null;
    select * into s from guess_sessions where user_id = uid and puzzle_date = d and mode = m;
    avail := exists (select 1 from daily_puzzles where puzzle_date = d and mode = m);
    steps := steps + public.mode_steps(coalesce(s.attempts,0), coalesce(s.solved,false));
    if avail then
      ra := ra + public.rank_attempts(coalesce(s.attempts,0), coalesce(s.solved,false), coalesce(s.hints_used,0), coalesce(s.retries_used,0));
      if coalesce(s.solved,false) or coalesce(s.failed,false) then done := done + 1; end if;
    end if;
    modes := modes || jsonb_build_object(m::text, jsonb_build_object(
      'available', avail, 'attempts', coalesce(s.attempts,0), 'solved', coalesce(s.solved,false), 'failed', coalesce(s.failed,false),
      'steps', public.mode_steps(coalesce(s.attempts,0), coalesce(s.solved,false)),
      'hints_used', coalesce(s.hints_used,0), 'retries_used', coalesce(s.retries_used,0)));
  end loop;
  return jsonb_build_object('date', d, 'modes', modes, 'steps', steps, 'rank_attempts', ra, 'modes_done', done,
    'moved', mv.id is not null, 'move', case when mv.id is not null then to_jsonb(mv) end,
    'spin', case when sp.user_id is not null then sp.prize end,
    'season', jsonb_build_object('id', se.id, 'status', se.status, 'started_on', se.started_on,
       'arrivals', coalesce((select jsonb_agg(jsonb_build_object('user_id', user_id, 'name', name, 'rank', arrived_rank) order by arrived_rank)
                             from characters where arrived_rank is not null), '[]'::jsonb)),
    'yesterday', coalesce((select jsonb_agg(jsonb_build_object('user_id', rr.user_id, 'name', ch.name, 'rank', rr.rank, 'attempts', rr.attempts) order by rr.rank)
                           from round_results rr join characters ch on ch.user_id = rr.user_id
                           where rr.d = public.game_today() - 1 and rr.rank <= 3), '[]'::jsonb));
end $$;

-- Andar: uma vez por dia
create or replace function public.move_today() returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  uid uuid := public.assert_active(); d date := public.game_today(); c jsonb;
  me characters; other characters; nd board_nodes; tr traps; w jsonb;
  m public.puzzle_mode; s guess_sessions; st int; modes jsonb := '{}'::jsonb;
  base int := 0; roll int; bonus int; total int; from_node int; landed int;
  ev jsonb := '[]'::jsonb; sal int := 0; extra_coins int := 0; extra_xp int := 0;
  card int; chance int; steal int; my_dist int; tmp_node int; tmp_path int[]; msg text;
  xp_gain int; coin_gain int; new_level int; old_level int;
begin
  perform public.settle();
  c := public.cfg();
  select * into me from characters where user_id = uid for update;
  if me.id is null then raise exception 'Crie seu personagem primeiro.'; end if;
  if exists (select 1 from daily_moves where user_id = uid and move_date = d) then raise exception 'Você já andou hoje. Volte amanhã!'; end if;
  old_level := me.level;

  foreach m in array enum_range(null::public.puzzle_mode) loop
    s := null;
    select * into s from guess_sessions where user_id = uid and puzzle_date = d and mode = m;
    st := public.mode_steps(coalesce(s.attempts,0), coalesce(s.solved,false));
    base := base + st;
    modes := modes || jsonb_build_object(m::text, jsonb_build_object('attempts', coalesce(s.attempts,0), 'solved', coalesce(s.solved,false), 'steps', st));
  end loop;
  roll := (c->>'roll_min')::int + floor(random() * ((c->>'roll_max')::int - (c->>'roll_min')::int + 1))::int;
  if me.class = 'arqueiro' and roll < (c->>'arqueiro_min_die')::int then
    roll := (c->>'arqueiro_min_die')::int;
    ev := ev || jsonb_build_object('t','arqueiro','msg','Olho de arqueiro: a roleta vale no mínimo ' || roll || '.');
  end if;
  bonus := me.bonus_steps;
  total := base + roll + bonus;
  from_node := me.node;

  if me.arrived_rank is not null then
    ev := ev || jsonb_build_object('t','castelo','msg','Você já está no Castelo. Continue jogando para ganhar moedas, XP e vencer rodadas.');
    total := 0;
  else
    update characters set bonus_steps = 0 where id = me.id;
    w := public.walk(me.id, total);
    sal := sal + (w->>'salary')::int;
    landed := (w->>'node')::int;

    -- 1) armadilha de outro jogador
    select * into tr from traps where node = landed and triggered_at is null and owner_id <> uid for update;
    if tr.id is not null then
      update traps set triggered_by = uid, triggered_at = now() where id = tr.id;
      select * into other from characters where user_id = tr.owner_id;
      if me.class = 'mago' and random() * 100 < (c->>'mago_resist_pct')::int then
        ev := ev || jsonb_build_object('t','armadilha','msg','Você desfez com magia a armadilha de ' || other.name || '.');
      else
        perform public.go_back(me.id, (c->>'trap_push')::int);
        update characters set coins = coins + (c->>'trap_reward')::int where user_id = tr.owner_id;
        ev := ev || jsonb_build_object('t','armadilha','msg','Você caiu na armadilha de ' || other.name || ' e voltou ' || (c->>'trap_push') || ' casas.');
        insert into event_log(user_id, kind, message) values (uid, 'armadilha', me.name || ' caiu na armadilha de ' || other.name || '.');
      end if;
    else
      -- 2) efeito da casa
      select * into nd from board_nodes where id = landed;
      if nd.kind = 'avanco' then
        w := public.walk(me.id, nd.value); sal := sal + (w->>'salary')::int;
        ev := ev || jsonb_build_object('t','avanco','msg','Vento a favor! Avançou mais ' || nd.value || ' casas.');
      elsif nd.kind = 'recuo' then
        if me.class = 'mago' and random() * 100 < (c->>'mago_resist_pct')::int then
          ev := ev || jsonb_build_object('t','recuo','msg','Escorregou, mas a magia segurou você no lugar.');
        else
          perform public.go_back(me.id, nd.value);
          ev := ev || jsonb_build_object('t','recuo','msg','Lamaçal! Voltou ' || nd.value || ' casas.');
        end if;
      elsif nd.kind = 'bau' then
        extra_coins := extra_coins + (c->>'chest_coins')::int;
        ev := ev || jsonb_build_object('t','bau','msg','Achou um baú com ' || (c->>'chest_coins') || ' moedas.');
      elsif nd.kind = 'xp' then
        extra_xp := extra_xp + (c->>'xp_square')::int;
        ev := ev || jsonb_build_object('t','xp','msg','Treino na clareira: +' || (c->>'xp_square') || ' XP.');
      elsif nd.kind = 'pagamento' then
        ev := ev || jsonb_build_object('t','pagamento','msg','Parou no Dia de pagamento.');
      elsif nd.kind = 'carta' then
        card := floor(random() * 6)::int;
        if card = 0 then
          extra_coins := extra_coins + (c->>'card_coins_win')::int;
          ev := ev || jsonb_build_object('t','carta','msg','Carta da sorte: um treinador agradecido te deu ' || (c->>'card_coins_win') || ' moedas.');
        elsif card = 1 then
          extra_coins := extra_coins - (c->>'card_coins_lose')::int;
          ev := ev || jsonb_build_object('t','carta','msg','Carta do azar: sua mochila rasgou e você perdeu ' || (c->>'card_coins_lose') || ' moedas.');
        elsif card = 2 then
          w := public.walk(me.id, (c->>'card_steps')::int); sal := sal + (w->>'salary')::int;
          ev := ev || jsonb_build_object('t','carta','msg','Carta da sorte: atalho secreto! Avançou ' || (c->>'card_steps') || ' casas.');
        elsif card = 3 then
          perform public.go_back(me.id, (c->>'card_steps')::int);
          ev := ev || jsonb_build_object('t','carta','msg','Carta do azar: você se perdeu e voltou ' || (c->>'card_steps') || ' casas.');
        elsif card = 4 then
          update characters set hints = hints + 1 where id = me.id;
          ev := ev || jsonb_build_object('t','carta','msg','Carta da sorte: ganhou 1 Dica.');
        else
          update characters set retries = retries + 1 where id = me.id;
          ev := ev || jsonb_build_object('t','carta','msg','Carta da sorte: ganhou 1 Tente outra vez.');
        end if;
      elsif nd.kind = 'raio' then
        select ch.* into other from characters ch join board_nodes b on b.id = ch.node
         where ch.arrived_rank is null and ch.user_id <> uid order by b.dist asc limit 1 for update of ch;
        my_dist := (select dist from board_nodes where id = landed);
        if other.id is null or (select dist from board_nodes where id = other.node) >= my_dist then
          ev := ev || jsonb_build_object('t','raio','msg','A tempestade caiu longe: ninguém está à sua frente.');
        elsif other.class = 'mago' and random() * 100 < (c->>'mago_resist_pct')::int then
          ev := ev || jsonb_build_object('t','raio','msg','Você chamou um raio em ' || other.name || ', mas a magia dele desviou.');
        else
          perform public.go_back(other.id, (c->>'storm_push')::int);
          ev := ev || jsonb_build_object('t','raio','msg','Você chamou um raio no líder ' || other.name || ': ele voltou ' || (c->>'storm_push') || ' casas.');
          insert into event_log(user_id, kind, message) values (uid, 'raio', me.name || ' derrubou um raio no líder ' || other.name || '.');
        end if;
      elsif nd.kind = 'troca' then
        my_dist := (select dist from board_nodes where id = landed);
        select ch.* into other from characters ch join board_nodes b on b.id = ch.node
         where ch.arrived_rank is null and ch.user_id <> uid and b.dist < my_dist order by b.dist desc limit 1 for update of ch;
        if other.id is not null then
          select node, path into tmp_node, tmp_path from characters where id = me.id;
          update characters set node = other.node, path = other.path where id = me.id;
          update characters set node = tmp_node, path = tmp_path where id = other.id;
          ev := ev || jsonb_build_object('t','troca','msg','Portal! Você trocou de lugar com ' || other.name || '.');
          insert into event_log(user_id, kind, message) values (uid, 'troca', me.name || ' trocou de lugar com ' || other.name || ' pelo portal.');
        else
          ev := ev || jsonb_build_object('t','troca','msg','O portal não encontrou ninguém à sua frente.');
        end if;
      end if;
    end if;

    -- 3) encontro na mesma casa vira duelo
    select * into me from characters where id = me.id;
    select ch.* into other from characters ch join board_nodes b on b.id = ch.node
     where ch.user_id <> uid and ch.node = me.node and ch.arrived_rank is null and b.kind not in ('inicio','castelo')
     order by random() limit 1 for update of ch;
    if other.id is not null then
      chance := 50 + (me.level - other.level) * (c->>'duel_level_factor')::int
                   + case when me.class = 'guerreiro' then (c->>'guerreiro_duel_bonus')::int else 0 end
                   - case when other.class = 'guerreiro' then (c->>'guerreiro_duel_bonus')::int else 0 end;
      chance := greatest(25, least(75, chance));
      if random() * 100 < chance then
        steal := least((c->>'duel_coins')::int, other.coins);
        update characters set coins = coins - steal where id = other.id;
        perform public.go_back(other.id, (c->>'duel_push')::int);
        extra_coins := extra_coins + steal;
        ev := ev || jsonb_build_object('t','duelo','msg','Encontro com ' || other.name || ': você venceu o duelo, ganhou ' || steal || ' moedas e empurrou o rival.');
        insert into event_log(user_id, kind, message) values (uid, 'duelo', me.name || ' venceu um duelo contra ' || other.name || '.');
      else
        steal := least((c->>'duel_coins')::int, greatest(0, me.coins + extra_coins));
        update characters set coins = coins + steal where id = other.id;
        extra_coins := extra_coins - steal;
        perform public.go_back(me.id, (c->>'duel_push')::int);
        ev := ev || jsonb_build_object('t','duelo','msg','Encontro com ' || other.name || ': você perdeu o duelo, ' || steal || ' moedas e voltou ' || (c->>'duel_push') || ' casas.');
        insert into event_log(user_id, kind, message) values (uid, 'duelo', other.name || ' defendeu sua casa contra ' || me.name || '.');
      end if;
    end if;

    if sal > 0 then ev := ev || jsonb_build_object('t','pagamento','msg','Dia de pagamento: +' || sal || ' moedas de salário.'); end if;
    msg := public.check_arrival(me.id);
    if msg is not null then ev := ev || jsonb_build_object('t','castelo','msg', msg); end if;
  end if;

  xp_gain := base * (c->>'xp_per_step')::int + (c->>'xp_daily_bonus')::int + extra_xp;
  coin_gain := base * (c->>'coins_per_step')::int + extra_coins;
  select * into me from characters where id = me.id;
  new_level := public.level_for_xp(me.xp_total + xp_gain);
  if new_level > old_level then
    ev := ev || jsonb_build_object('t','nivel','msg','Subiu para o nível ' || new_level || '!');
    insert into event_log(user_id, kind, message) values (uid, 'nivel', me.name || ' chegou ao nível ' || new_level || '.');
  end if;
  update characters set xp_total = xp_total + xp_gain, level = new_level,
         coins = greatest(0, coins + coin_gain), last_move_date = d
   where id = me.id returning * into me;

  insert into daily_moves(user_id, move_date, modes, base_steps, roll, bonus_steps, from_node, to_node, xp_gained, coins_gained, events)
  values (uid, d, modes, base, roll, bonus, from_node, me.node, xp_gain, coin_gain + sal, ev);
  insert into event_log(user_id, kind, message, data)
  values (uid, 'andou', me.name || ' andou ' || total || ' casas.', jsonb_build_object('steps', total));

  return jsonb_build_object('base', base, 'roll', roll, 'bonus', bonus, 'total', total, 'modes', modes,
    'from', from_node, 'to', me.node, 'path', to_jsonb(me.path), 'events', ev,
    'xp', xp_gain, 'coins', coin_gain + sal, 'level', new_level, 'leveled', new_level > old_level);
end $$;

-- Rodada de hoje (tentativas dos outros só aparecem depois que você anda)
create or replace function public.today_round() returns table (
  user_id uuid, char_name text, class public.char_class, level int, outfit jsonb,
  modes_done int, moved boolean, attempts int, solved int)
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); d date := public.game_today();
  can_see boolean := public.has_role(uid,'admin') or exists (select 1 from daily_moves dm where dm.user_id = uid and dm.move_date = d);
begin
  return query
  with t as (
    select ch.user_id, ch.name::text as nm, ch.class, ch.level, ch.outfit,
      (select count(*)::int from guess_sessions gs where gs.user_id = ch.user_id and gs.puzzle_date = d and (gs.solved or gs.failed)) as done,
      exists (select 1 from daily_moves dm where dm.user_id = ch.user_id and dm.move_date = d) as mv,
      (select sum(public.rank_attempts(coalesce(gs.attempts,0), coalesce(gs.solved,false), coalesce(gs.hints_used,0), coalesce(gs.retries_used,0)))::int
         from daily_puzzles dp left join guess_sessions gs on gs.user_id = ch.user_id and gs.puzzle_date = d and gs.mode = dp.mode
        where dp.puzzle_date = d) as att,
      (select count(*)::int from guess_sessions gs where gs.user_id = ch.user_id and gs.puzzle_date = d and gs.solved) as sol
    from characters ch)
  select t.user_id, t.nm, t.class, t.level, t.outfit, t.done, t.mv,
         case when can_see or t.user_id = uid then t.att end, t.sol
  from t order by t.done desc, (case when can_see or t.user_id = uid then t.att end) asc nulls last, t.nm;
end $$;

-- Rankings de rodadas: vitórias, pódios e média de tentativas
create or replace function public.ranking_period(_kind text) returns table (
  user_id uuid, char_name text, class public.char_class, level int, outfit jsonb, wins int, podiums int, rounds int, avg_attempts numeric)
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); d date := public.game_today(); start date;
begin
  perform public.settle();
  start := case _kind when 'semana' then date_trunc('week', d)::date when 'mes' then date_trunc('month', d)::date else '2000-01-01'::date end;
  return query
  select ch.user_id, ch.name::text, ch.class, ch.level, ch.outfit,
    count(*) filter (where rr.rank = 1)::int, count(*) filter (where rr.rank <= 3)::int, count(rr.d)::int,
    round(avg(rr.attempts), 1)
  from characters ch left join round_results rr on rr.user_id = ch.user_id and rr.d >= start
  group by ch.user_id, ch.name, ch.class, ch.level, ch.outfit
  order by 6 desc, 7 desc, 9 asc nulls last, ch.name;
end $$;

create or replace function public.place_trap(_node int) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); c jsonb := public.cfg(); me characters;
begin
  select * into me from characters where user_id = uid for update;
  if not exists (select 1 from board_nodes where id = _node and kind not in ('inicio','castelo','bifurcacao')) then raise exception 'Não dá para armar nessa casa.'; end if;
  if exists (select 1 from traps where owner_id = uid and triggered_at is null) then raise exception 'Você já tem uma armadilha armada.'; end if;
  if exists (select 1 from traps where node = _node and triggered_at is null) then raise exception 'Já existe uma armadilha nessa casa. Escolha outra.'; end if;
  if me.coins < (c->>'trap_price')::int then raise exception 'Moedas insuficientes.'; end if;
  update characters set coins = coins - (c->>'trap_price')::int where id = me.id;
  insert into traps(node, owner_id) values (_node, uid);
end $$;

-- Admin
create or replace function public.admin_players() returns table (
  user_id uuid, email text, username text, status text, is_admin boolean,
  char_name text, class public.char_class, level int, xp_total int, coins int, node int, dist int, created_at timestamptz)
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform public.assert_admin();
  return query
  select p.id, u.email::text, p.username::text, p.status, public.has_role(p.id,'admin'),
         ch.name::text, ch.class, ch.level, ch.xp_total, ch.coins, ch.node, b.dist, p.created_at
  from profiles p join auth.users u on u.id = p.id
  left join characters ch on ch.user_id = p.id
  left join board_nodes b on b.id = ch.node
  order by p.created_at;
end $$;

create or replace function public.admin_adjust(_user uuid, _coins int, _xp int, _node int, _reason text) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare b characters; a characters;
begin
  perform public.assert_admin();
  if coalesce(trim(_reason),'') = '' then raise exception 'Informe o motivo do ajuste.'; end if;
  if _node is not null and not exists (select 1 from board_nodes where id = _node) then raise exception 'Essa casa não existe.'; end if;
  select * into b from characters where user_id = _user for update;
  if b.id is null then raise exception 'Jogador sem personagem.'; end if;
  update characters set
    coins = greatest(0, coins + coalesce(_coins,0)),
    xp_total = greatest(0, xp_total + coalesce(_xp,0)),
    level = public.level_for_xp(greatest(0, xp_total + coalesce(_xp,0))),
    node = coalesce(_node, node),
    path = case when _node is null then path else path || _node end
  where id = b.id returning * into a;
  perform public.audit('ajuste', _user::text, to_jsonb(b), to_jsonb(a), _reason);
end $$;

create or replace function public.admin_undo_move(_user uuid, _reason text) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare mv daily_moves; b characters;
begin
  perform public.assert_admin();
  select * into mv from daily_moves where user_id = _user and move_date = public.game_today();
  if mv.id is null then raise exception 'Esse jogador ainda não andou hoje.'; end if;
  select * into b from characters where user_id = _user for update;
  update characters set node = mv.from_node, path = path[1:coalesce(array_position(path, mv.from_node), 1)],
    xp_total = greatest(0, xp_total - mv.xp_gained), level = public.level_for_xp(greatest(0, xp_total - mv.xp_gained)),
    coins = greatest(0, coins - mv.coins_gained), bonus_steps = bonus_steps + mv.bonus_steps, last_move_date = null
  where user_id = _user;
  delete from daily_moves where id = mv.id;
  perform public.audit('desfazer_andada', _user::text, to_jsonb(b), to_jsonb(mv), _reason);
end $$;

create or replace function public.admin_new_season(_reason text) returns void
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform public.assert_admin();
  perform public.start_new_season();
  perform public.audit('nova_temporada', null, null, null, _reason);
end $$;

-- 6) Segurança ----------------------------------------------------------
alter table public.board_nodes    enable row level security;
alter table public.seasons        enable row level security;
alter table public.season_results enable row level security;
alter table public.daily_moves    enable row level security;
alter table public.traps          enable row level security;
alter table public.round_days     enable row level security;
alter table public.round_results  enable row level security;
alter table public.daily_spins    enable row level security;

revoke all on all tables    in schema public from anon, authenticated;
revoke all on all sequences in schema public from anon, authenticated;
grant select on public.game_config, public.profiles, public.user_roles, public.pokemon, public.characters,
                public.guess_sessions, public.guesses, public.daily_moves, public.board_nodes, public.traps,
                public.shop_items, public.event_log, public.admin_audit_log, public.seasons, public.season_results,
                public.round_results, public.daily_spins to authenticated;

drop policy if exists p_nodes on public.board_nodes;     create policy p_nodes on public.board_nodes for select to authenticated using (true);
drop policy if exists p_seasons on public.seasons;       create policy p_seasons on public.seasons for select to authenticated using (true);
drop policy if exists p_sres on public.season_results;   create policy p_sres on public.season_results for select to authenticated using (true);
drop policy if exists p_moves on public.daily_moves;     create policy p_moves on public.daily_moves for select to authenticated using (user_id = auth.uid() or public.is_admin());
drop policy if exists p_traps on public.traps;           create policy p_traps on public.traps for select to authenticated using ((owner_id = auth.uid() and triggered_at is null) or public.is_admin());
drop policy if exists p_rres on public.round_results;    create policy p_rres on public.round_results for select to authenticated using (true);
drop policy if exists p_spins on public.daily_spins;     create policy p_spins on public.daily_spins for select to authenticated using (user_id = auth.uid() or public.is_admin());

revoke execute on all functions in schema public from public, anon, authenticated;
grant execute on function public.username_available(text) to anon, authenticated;
grant execute on function public.has_role(uuid, public.app_role) to authenticated;
grant execute on function
  public.is_admin(), public.create_character(text, public.char_class),
  public.puzzle_state(public.puzzle_mode), public.make_guess(public.puzzle_mode, int),
  public.use_hint(public.puzzle_mode), public.use_retry(public.puzzle_mode), public.buy_help(text),
  public.spin_wheel(), public.set_route(int, text),
  public.today_overview(), public.move_today(), public.buy_item(text), public.equip_item(text, text),
  public.place_trap(int), public.today_round(), public.ranking_period(text),
  public.admin_players(), public.admin_set_status(uuid, text, text), public.admin_adjust(uuid, int, int, int, text),
  public.admin_reset_day(uuid, date, text), public.admin_set_config(jsonb, text), public.admin_undo_move(uuid, text),
  public.admin_new_season(text), public.admin_save_media(int, text, jsonb, text), public.admin_media_status()
to authenticated;
