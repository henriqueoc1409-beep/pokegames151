-- 108_bolsa_nova.sql
-- Pedido do dono em 13/11/2026: a bolsa das batalhas com cara de bolsa de jogo (bolsos, lista com quantidades, seta e a
-- caixa com a descrição). A mudança é toda no site; este arquivo só publica a novidade no Jornal. As regras não mudam.

insert into public.posts(kind, title, body, created_by)
select 'novidade', x.title, x.body, coalesce((select user_id from public.user_roles where role = 'admin' order by user_id limit 1), '00000000-0000-0000-0000-000000000000'::uuid)
  from (values ('🎒 Bolsa nova nas batalhas', 'A bolsa das batalhas ficou nova:
• Abre com tudo o que você tem, separado em bolsos: Curas, Estados, Reviver, Itens X e Outros.
• Cada item aparece com a quantidade. Escolha um e a descrição aparece embaixo.
• O que não faria efeito agora fica apagadinho, e o botão Usar só acende quando dá para usar.
• No computador: setas para escolher, Enter para usar, Esc para voltar.
• O limite continua: usar um item gasta a sua vez, e há um número máximo de itens por batalha.')) x(title, body)
 where not exists (select 1 from public.posts p where p.title = x.title);
