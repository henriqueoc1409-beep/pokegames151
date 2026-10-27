-- =====================================================================
-- POKEGAMES — Prêmio do Quiz entregue sozinho (pedido do dono em 27/10/2026).
--
-- Ao criar o quiz, o admin escolhe o prêmio de verdade (moedas, dicas,
-- "tente outra vez", bolas, pedras e itens da bolsa, e visuais da loja).
-- Quando o quiz fecha (quiz_tick), o vencedor recebe na hora: entra na conta,
-- aparece como presente no Correio e o Jornal conta o que ele ganhou.
-- O texto do prêmio continua sendo o que aparece para os jogadores.
-- Quiz sem prêmio de verdade continua como antes (botão "Dar o prêmio").
-- Depende do 34 e do 38. Antes de rodar à mão, faça a cópia de segurança.
-- =====================================================================

alter table public.quizzes add column if not exists prize_coins int not null default 0;
alter table public.quizzes add column if not exists prize_hints int not null default 0;
alter table public.quizzes add column if not exists prize_retries int not null default 0;
alter table public.quizzes add column if not exists prize_bag jsonb not null default '{}'::jsonb;
alter table public.quizzes add column if not exists prize_items text[] not null default '{}';
alter table public.quizzes add column if not exists prize_given_at timestamptz;

-- confere um prêmio (mesmas regras dos presentes do admin) e devolve ele arrumado
create or replace function public.gift_check(_items text[], _coins int, _hints int, _retries int, _bag jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, extensions as $$
declare bad text; k text; q int; bag jsonb := '{}'::jsonb;
begin
  _coins := coalesce(_coins, 0); _hints := coalesce(_hints, 0); _retries := coalesce(_retries, 0);
  if _coins not between 0 and 100000 then raise exception 'Moedas: de 0 a 100000.'; end if;
  if _hints not between 0 and 99 or _retries not between 0 and 99 then raise exception 'Dicas e "tente outra vez": de 0 a 99.'; end if;
  select string_agg(x, ', ') into bad from unnest(coalesce(_items, '{}')) x where not exists (select 1 from shop_items s where s.id = x);
  if bad is not null then raise exception 'Item inexistente: %', bad; end if;
  for k, q in select key, value::int from jsonb_each_text(coalesce(_bag, '{}'::jsonb)) loop
    if q is null or q = 0 then continue; end if;
    if not public.gift_bag_ok(k) then raise exception 'Item da bolsa inválido: %', k; end if;
    if q not between 1 and 99 then raise exception 'Quantidade de itens da bolsa: de 1 a 99.'; end if;
    bag := bag || jsonb_build_object(k, q);
  end loop;
  return jsonb_build_object('items', to_jsonb(coalesce(_items, '{}')), 'coins', _coins, 'hints', _hints, 'retries', _retries, 'bag', bag);
end $$;

-- entrega um presente (usado pelo quiz; o admin_gift do 34 continua igual): conta, bolsa e Correio
create or replace function public.gift_give(_user uuid, _message text, _items text[], _coins int, _hints int, _retries int, _bag jsonb, _by uuid)
returns public.gifts
language plpgsql security definer set search_path = public, extensions as $$
declare me characters; g gifts; chk jsonb := public.gift_check(_items, _coins, _hints, _retries, _bag); gave text[] := '{}'; it text; k text; q int;
begin
  select * into me from characters where user_id = _user for update;
  if me.id is null then return null; end if;
  foreach it in array array(select jsonb_array_elements_text(chk->'items')) loop
    if not (it = any(me.owned_items)) and not (it = any(gave)) then gave := gave || it; end if;
  end loop;
  update characters set owned_items = owned_items || gave, coins = coins + (chk->>'coins')::int,
         hints = hints + (chk->>'hints')::int, retries = retries + (chk->>'retries')::int where id = me.id;
  for k, q in select key, value::int from jsonb_each_text(chk->'bag') loop
    insert into bag_items(user_id, item, qty) values (_user, k, q) on conflict (user_id, item) do update set qty = bag_items.qty + q;
  end loop;
  insert into gifts(user_id, items, bag, coins, hints, retries, message, created_by)
  values (_user, gave, chk->'bag', (chk->>'coins')::int, (chk->>'hints')::int, (chk->>'retries')::int, left(coalesce(btrim(_message), ''), 500), _by)
  returning * into g;
  return g;
end $$;

drop function if exists public.admin_quiz_save(text, text, text, text, numeric, int, int);

-- cria o quiz (versão do 38 + prêmio de verdade, entregue sozinho ao vencedor)
create or replace function public.admin_quiz_save(_title text, _intro text, _prize text, _question text, _answer numeric, _seconds int default 15, _hours int default 24,
  _prize_coins int default 0, _prize_hints int default 0, _prize_retries int default 0, _prize_bag jsonb default '{}'::jsonb, _prize_items text[] default '{}')
returns public.quizzes
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); q quizzes; chk jsonb;
begin
  if not public.has_role(uid, 'admin') then raise exception 'Só o administrador cria quiz.'; end if;
  if exists (select 1 from quizzes where status = 'aberto') then raise exception 'Já existe um quiz aberto. Encerre ele antes de criar outro.'; end if;
  if char_length(btrim(coalesce(_title, ''))) not between 2 and 80 then raise exception 'Título: de 2 a 80 letras.'; end if;
  if char_length(btrim(coalesce(_question, ''))) not between 5 and 300 then raise exception 'Pergunta: de 5 a 300 letras.'; end if;
  if _answer is null then raise exception 'Informe a resposta certa (um número).'; end if;
  if coalesce(_seconds, 15) not between 5 and 120 then raise exception 'Tempo para responder: de 5 a 120 segundos.'; end if;
  if coalesce(_hours, 24) not between 1 and 168 then raise exception 'Prazo: de 1 a 168 horas.'; end if;
  chk := public.gift_check(_prize_items, _prize_coins, _prize_hints, _prize_retries, _prize_bag);   -- confere o prêmio antes de publicar
  insert into quizzes(title, intro, prize, question, answer, seconds, closes_at, created_by, prize_coins, prize_hints, prize_retries, prize_bag, prize_items)
  values (btrim(_title), left(btrim(coalesce(_intro, '')), 500), left(btrim(coalesce(_prize, '')), 200), btrim(_question), _answer,
          coalesce(_seconds, 15), now() + make_interval(hours => coalesce(_hours, 24)), uid,
          (chk->>'coins')::int, (chk->>'hints')::int, (chk->>'retries')::int, chk->'bag', array(select jsonb_array_elements_text(chk->'items')))
  returning * into q;
  insert into admin_audit_log(admin_id, action, target, after) values (uid, 'quiz', q.id::text, to_jsonb(q));
  return q;
end $$;

-- fecha o quiz (versão do 38 + entrega do prêmio)
create or replace function public.quiz_tick(_id bigint) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare q quizzes; total int; done int; w uuid; g gifts;
begin
  select * into q from quizzes where id = _id for update;
  if q.id is null or q.status <> 'aberto' then return; end if;
  select count(*) into total from public.day_active(public.game_today()) a where not public.has_role(a.user_id, 'admin');
  -- já participou = respondeu ou deixou o tempo acabar
  select count(*) into done from quiz_entries e where e.quiz_id = _id and not public.has_role(e.user_id, 'admin')
     and (e.answered_at is not null or now() > e.revealed_at + make_interval(secs => q.seconds) + public.quiz_grace());
  if now() < q.closes_at and (total = 0 or done < total) then return; end if;
  select e.user_id into w from quiz_entries e
   where e.quiz_id = _id and e.guess is not null
   order by abs(e.guess - q.answer), e.answered_at limit 1;
  update quizzes set status = 'encerrado', closed_at = now(), winner = w where id = _id;
  if w is not null then
    -- prêmio de verdade (arquivo 51): entregue na hora, com presente no Correio
    if q.prize_coins > 0 or q.prize_hints > 0 or q.prize_retries > 0 or q.prize_bag <> '{}'::jsonb or cardinality(q.prize_items) > 0 then
      g := public.gift_give(w, '🏆 Prêmio do Quiz "' || q.title || '"' || case when q.prize <> '' then ': ' || q.prize else '' end || '. Parabéns!',
             q.prize_items, q.prize_coins, q.prize_hints, q.prize_retries, q.prize_bag, null);
      update quizzes set prize_given_at = now() where id = _id;
    end if;
    insert into event_log(user_id, kind, message)
    select w, 'quiz', ch.name || ' venceu o Quiz surpresa "' || q.title || '"' || case when q.prize <> '' then ' e ganhou ' || q.prize else '' end || '!' from characters ch where ch.user_id = w;
  end if;
end $$;

-- ---------- permissões ----------
revoke execute on function public.gift_check(text[], int, int, int, jsonb), public.gift_give(uuid, text, text[], int, int, int, jsonb, uuid),
  public.quiz_tick(bigint) from public, anon, authenticated;
revoke execute on function public.admin_quiz_save(text, text, text, text, numeric, int, int, int, int, int, jsonb, text[]) from public, anon;
grant execute on function public.admin_quiz_save(text, text, text, text, numeric, int, int, int, int, int, jsonb, text[]) to authenticated;
