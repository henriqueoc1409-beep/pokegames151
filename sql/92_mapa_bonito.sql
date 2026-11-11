-- 92_mapa_bonito.sql
-- Pedido do dono em 10/11/2026: acabamento novo no mapa (chão pintado no lugar dos quadradinhos, trilha
-- marcada ligando as casas, mar em volta, moldura e luz mais suave). Tudo no site, só desenho: o tabuleiro e as regras não mudam. Este arquivo só:
--   (1) acrescenta o liga/desliga "mapa_novo" aos ajustes do visual (visual_cfg, versão do 91 + mapa_novo);
--   (2) publica a novidade no Jornal.

create or replace function public.visual_cfg() returns jsonb
language sql stable security definer set search_path = public, extensions as $$
  select '{"on": true, "tela_cheia_padrao": true, "chat_fixo": true, "herois_novos": true, "mapa_novo": true}'::jsonb || coalesce(public.cfg()->'visual', '{}'::jsonb)
$$;
update public.game_config set config = jsonb_set(config, '{visual}', public.visual_cfg()) where active;
revoke execute on function public.visual_cfg() from public, anon, authenticated;

-- ---------- novidade no Jornal, publicada sozinha ----------
insert into public.posts(kind, title, body, created_by)
select 'novidade', x.title, x.body, coalesce((select user_id from public.user_roles where role = 'admin' order by user_id limit 1), '00000000-0000-0000-0000-000000000000'::uuid)
  from (values ('🗺️ O mapa ficou mais bonito!', 'O tabuleiro ganhou acabamento novo (as casas e os caminhos são os mesmos):
• Trilha bem marcada ligando as casas: clara no caminho seguro e avermelhada no arriscado.
• Mar em volta do mapa, com faixa de areia e moldura.
• Chão novo, pintado: a grama, a areia e a terra se misturam suaves, sem aquele xadrez, com flores e tufos espalhados.
• Luz mais suave nas bordas e cores mais vivas.')) x(title, body)
 where not exists (select 1 from public.posts p where p.title = x.title);
