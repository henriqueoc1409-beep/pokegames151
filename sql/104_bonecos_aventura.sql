-- 104_bonecos_aventura.sql
-- Pedido do dono em 12/11/2026: na Aventura o boneco veste os equipamentos (todos veem) e a peça muda com o "+"
-- (couro, malha, aço, ouro). Tudo no site: bonecos em camadas do Liberated Pixel Cup (deploy/rpg-bonecos.js,
-- licenças OGA-BY 3.0 / CC-BY / CC0, créditos na Biblioteca). Este arquivo só publica a novidade no Jornal.

insert into public.posts(kind, title, body, created_by)
select 'novidade', x.title, x.body, coalesce((select user_id from public.user_roles where role = 'admin' order by user_id limit 1), '00000000-0000-0000-0000-000000000000'::uuid)
  from (values ('🧍 Aventura: boneco novo, vestindo os seus equipamentos', 'O seu herói na Aventura ganhou um boneco novo, maior e mais detalhado, que anda nas 4 direções:
• Ele veste as peças que você equipou, e todo mundo vê o que você está usando.
• A peça muda com o "+": couro (do +0 ao +2), malha (do +3 ao +5), aço (do +6 ao +8) e ouro brilhante no +9.
• Sem a peça, a roupa fica na cor do seu herói (vermelho do Guerreiro, roxo do Mago com chapéu de estrelas, verde do Arqueiro, capuz branco do Clérigo…). Cada jogador tem o seu cabelo.
• Os Líderes de Ginásio vestem armadura de aço (e o do Pico Gelado, de ouro).
• No tabuleiro, o boneco continua o de sempre.')) x(title, body)
 where not exists (select 1 from public.posts p where p.title = x.title);
