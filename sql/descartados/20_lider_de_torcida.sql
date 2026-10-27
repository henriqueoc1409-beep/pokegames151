-- =====================================================================
-- POKEGAMES — Conjunto "Líder de torcida" para os Pokémon.
-- Serve em TODAS as 151 espécies (sem restrição de espécie) e é grátis:
-- cada jogador pega na Loja Pokémon e veste em quantos Pokémon quiser.
--   * Laço de líder de torcida (cabeça)
--   * Uniforme de líder de torcida com pompons, em 3 cores (pescoço):
--     o uniforme vai no peito e os pompons ficam nos dois lados do corpo.
-- Só visual: não muda força nem chance de vitória. Pixel art original.
-- Só acrescenta itens na loja. Rode depois do 19.
-- =====================================================================
insert into public.shop_items (id, name, slot, price, min_level, rarity, data) values
 ('pk_torcida_laco', 'Laço de líder de torcida', 'pk_cabeca', 0, 1, 'incomum',
  '{"w": 0.7, "px": ["rr.....rr", "rrrr.rrrr", "rrwwwwwrr", "rr.....rr"], "pal": {"r": "#D1453B", "w": "#F4F1E8"}}'),
 ('pk_torcida_vermelho', 'Uniforme de líder de torcida (vermelho)', 'pk_pescoco', 0, 1, 'incomum',
  '{"w": 0.6, "y": 0.5, "px": ["w.......w", "rwwwwwwwr", "rrrwwwrrr", "rrrrwrrrr", "rrrrrrrrr", ".yyyyyyy."],
    "pal": {"r": "#D1453B", "w": "#F4F1E8", "y": "#F5C542"},
    "sides": {"at": 0.6, "px": [".y.y.y.", "yryryry", ".yryry.", "yryryry", ".y.y.y.", "...k..."], "pal": {"y": "#F5C542", "r": "#D1453B", "k": "#7A5028"}}}'),
 ('pk_torcida_azul', 'Uniforme de líder de torcida (azul)', 'pk_pescoco', 0, 1, 'incomum',
  '{"w": 0.6, "y": 0.5, "px": ["w.......w", "bwwwwwwwb", "bbbwwwbbb", "bbbbwbbbb", "bbbbbbbbb", ".wwwwwww."],
    "pal": {"b": "#3653A0", "w": "#F4F1E8"},
    "sides": {"at": 0.6, "px": [".w.w.w.", "wbwbwbw", ".wbwbw.", "wbwbwbw", ".w.w.w.", "...k..."], "pal": {"w": "#F4F1E8", "b": "#3E8FC4", "k": "#7A5028"}}}'),
 ('pk_torcida_rosa', 'Uniforme de líder de torcida (rosa)', 'pk_pescoco', 0, 1, 'incomum',
  '{"w": 0.6, "y": 0.5, "px": ["w.......w", "pwwwwwwwp", "pppwwwppp", "ppppwpppp", "ppppppppp", ".kkkkkkk."],
    "pal": {"p": "#E85A8A", "w": "#F4F1E8", "k": "#B9A4F2"},
    "sides": {"at": 0.6, "px": [".p.p.p.", "pkpkpkp", ".pkpkp.", "pkpkpkp", ".p.p.p.", "...h..."], "pal": {"p": "#F08FB6", "k": "#B9A4F2", "h": "#7A5028"}}}')
on conflict (id) do nothing;
