-- 88_pokebound_para_todos.sql
-- Pedido do dono em 10/11/2026: liberar o PokeBound para todos os jogadores (só no computador).
-- O jogo continua contra o computador e roda inteiro no aparelho de cada um: não guarda nada no banco,
-- não dá nem tira moedas, XP ou itens. Este arquivo só:
--   (1) cria os números do PokeBound no game_config (pokebound_cfg), com o liga/desliga "on";
--   (2) coloca o PokeBound na aba Administração → Ajustes do jogo (admin_cfg_efetiva, versão do 87 + pokebound);
--   (3) publica a novidade no Jornal.

create or replace function public.pokebound_cfg() returns jsonb
language sql stable security definer set search_path = public, extensions as $$
  select '{"on": true, "gravidade": 520, "vento_max": 10, "vento_forca": 14, "vento_turnos": 4, "vel_max": 1600, "carga_vel": 90,
    "turno_seg": 45, "recarga": 3, "raio_jogador": 42, "folego": 160, "zoom": 1.45}'::jsonb || coalesce(public.cfg()->'pokebound', '{}'::jsonb)
$$;
update public.game_config set config = jsonb_set(config, '{pokebound}', public.pokebound_cfg()) where active and not (config ? 'pokebound');
revoke execute on function public.pokebound_cfg() from public, anon, authenticated;

-- ---------- Ajustes do jogo (versão do 87 + PokeBound) ----------
create or replace function public.admin_cfg_efetiva() returns jsonb
language plpgsql stable security definer set search_path = public, extensions as $$
begin
  perform public.assert_admin();
  return jsonb_build_object('treino', public.treino_cfg(), 'pk', public.pk_cfg(), 'casas', public.casas_cfg(), 'itens', public.items_cfg(),
    'war', public.war_cfg(), 'rocket', public.rocket_cfg(), 'desafio', public.desafio_cfg(), 'creche', public.creche_cfg(), 'leilao', public.leilao_cfg(), 'herois', public.herois_cfg(), 'temporada', public.temporada_cfg(), 'liga', public.liga_cfg(), 'pausa', public.pausa_cfg(), 'teto', public.teto_cfg(), 'boas_vindas', public.boas_vindas_cfg(), 'vila_bonus', public.vila_bonus_cfg(), 'tm_nivel', public.tm_nivel_cfg(), 'quiz_auto', public.quiz_auto_cfg(), 'cartas', public.tcg_cfg(), 'pokebound', public.pokebound_cfg(), 'base', public.cfg());
end $$;

-- ---------- novidade no Jornal, publicada sozinha ----------
insert into public.posts(kind, title, body, created_by)
select 'novidade', x.title, x.body, coalesce((select user_id from public.user_roles where role = 'admin' order by user_id limit 1), '00000000-0000-0000-0000-000000000000'::uuid)
  from (values ('💥 Chegou o PokeBound!', 'Mini game novo no menu Competir: o PokeBound, duelo de artilharia com Pokémon. Só no computador.
• Escolha Blastoise, Electrode, Golem ou Dragonite: cada um tem força, alcance e um ataque especial diferente.
• ↑ ↓ mudam o ângulo. Segure ESPAÇO (ou o botão Atirar) e solte na hora certa: a barra de força vai e volta.
• Leia o vento antes de atirar: ele dura alguns turnos e desvia o tiro.
• ← → andam (sobe ladeira e entra em cratera). ⭐ arma o especial antes de carregar a força.
• Arraste a tela e use a rodinha do mouse para ver o campo inteiro.
• Por enquanto é contra o computador, só por diversão: não vale moedas nem XP.')) x(title, body)
 where not exists (select 1 from public.posts p where p.title = x.title);
