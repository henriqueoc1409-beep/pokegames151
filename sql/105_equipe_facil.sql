-- 105_equipe_facil.sql
-- Pedido do dono em 12/11/2026: tela "Minha equipe" (tocar para trocar, arrastar, salva sozinha, suporte, mascote e
-- a opção do Pokémon andando atrás na Aventura) e topo da Aventura mais limpo, com chat que recolhe. Tudo no site
-- (usa o mon_team_set e o mon_set_mascot de sempre). Este arquivo só publica a novidade no Jornal.

insert into public.posts(kind, title, body, created_by)
select 'novidade', x.title, x.body, coalesce((select user_id from public.user_roles where role = 'admin' order by user_id limit 1), '00000000-0000-0000-0000-000000000000'::uuid)
  from (values ('🐾 Minha equipe: arrumar ficou fácil', 'Ficou muito mais fácil arrumar a equipe:
• Nova tela 🐾 Minha equipe (menu Pokémon, e o botão 🐾 Equipe dentro da Aventura).
• Toque num Pokémon e depois em outro para trocar de lugar. No computador, dá para arrastar.
• Salva sozinho, na hora: não tem mais botão de salvar.
• Na mesma tela: buscar na coleção, escolher o Pokémon de suporte da Aventura e o mascote do tabuleiro.
• Você escolhe se quer o 1º da equipe andando atrás de você na Aventura.
• A Aventura ficou mais limpa: no alto, uma linha com onde você está e as lutas do dia, e botões com ícone. O chat pode ser recolhido no ▾.')) x(title, body)
 where not exists (select 1 from public.posts p where p.title = x.title);
