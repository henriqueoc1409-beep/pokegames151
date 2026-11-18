-- 126_aventura_isometrica_e_mapa.sql
-- Pedido do dono em 18/11/2026: Aventura renovada em visão 3D diagonal (isométrica) com painéis de RPG nos 4 cantos,
-- janela de Inventário flutuante sem sair do mundo, clique no chão para andar sozinho, Pokémon selvagens passeando
-- visíveis e Mapa Grande novo em 2 abas ("Onde estou" e "Mundo inteiro") com trilha dourada guiada no chão.
-- Não muda nenhuma regra, coordenada, batalha, moeda nem XP no servidor.
-- Este arquivo só:
--   (1) acrescenta o interruptor "aventura_iso" em Ajustes do jogo → Visual (visual_cfg, versão do 124);
--   (2) publica a novidade sozinha no Jornal.

create or replace function public.visual_cfg() returns jsonb
language sql stable security definer set search_path = public, extensions as $$
  select '{"on": true, "tela_cheia_padrao": true, "chat_fixo": true, "herois_novos": true, "mapa_novo": true, "corrida": true, "vila_nova": true, "aventura_viva": true, "tabuleiro_vivo": true, "telas_compactas": true, "aventura_iso": true}'::jsonb || coalesce(public.cfg()->'visual', '{}'::jsonb)
$$;

update public.game_config set config = jsonb_set(config, '{visual}', public.visual_cfg()) where active;

revoke execute on function public.visual_cfg() from public, anon, authenticated;

-- ---------- novidade no Jornal, publicada sozinha ----------
insert into public.posts(kind, title, body, created_by)
select 'novidade', x.title, x.body, coalesce((select user_id from public.user_roles where role = 'admin' order by user_id limit 1), '00000000-0000-0000-0000-000000000000'::uuid)
  from (values ('🧭 Aventura em 3D diagonal, Inventário na tela e Mapa Grande com guia', 'A Aventura ganhou um visual novo em 3D diagonal (estilo RPG isométrico) e um Mapa Grande para ninguém mais se perder — mantendo todas as regras, lutas, Ginásios, rotas e posições exatamente iguais:
• Mundo em 3D diagonal: ruas e praças de pedra em relevo, canais de água cristalina mais fundos que o chão, pontes de madeira, árvores e coqueiros em pé com sombra, casas com paredes e telhados 3D, barraquinhas com toldo listrado, chafarizes, tochas acesas e os 8 Ginásios em 3D! (Quem preferir também pode alternar entre 3D e 2D a qualquer momento pelo botão 3D/2D no topo.)
• Clique no chão para andar: além do teclado (WASD/setas) e dos botões no celular, agora basta clicar ou tocar em qualquer lugar do chão ou numa porta que o seu herói vai andando sozinho até lá desviando dos obstáculos.
• Painéis de RPG e Inventário sem sair do mapa: minimapa com bússola no canto superior esquerdo ao lado da barra de nível, EXP e Missão Diária da Aventura; coordenadas no canto direito; Chat com abas embaixo; e a nova janela flutuante de Inventário (tecla I ou botão 🎒) mostrando seu herói com os 5 equipamentos, itens, bolas, TMs, sua equipe de 6 Pokémon e moedas sem fechar o mundo!
• Cenário mais vivo: Pokémon selvagens da própria área aparecem passeando visíveis no mato e na água, os moradores dão dicas em balões quando você passa por perto, gente passeia pelas ruas da Vila Aurora, sai fumaça das chaminés e passam pássaros no céu durante o dia.
• Mapa Grande novo com guia no chão (botão 🗺️ ou tecla M): dividido em "📍 Onde estou" (mapa grande e nítido da região atual com todas as lojas, casas, estações, Ginásio e saídas marcadas) e "🌍 Mundo inteiro" (todas as rotas, níveis e insígnias). Clique em "🧭 Ir até lá" em qualquer lugar ou região para acender uma trilha dourada no chão te guiando até a porta certa!')) x(title, body)
 where not exists (select 1 from public.posts p where p.title = x.title);
