-- =====================================================================
-- POKEGAMES 127 — Quiz com perguntas de lógica e explicação da resposta
-- (pedido do dono em 19/11/2026: "as perguntas estão genéricas; quero lógica com
-- peso, altura e habilidades dos Pokémon, e uma explicação de como chegou no número").
--  * quiz_banco.explicacao e quizzes.explicacao: a conta que leva à resposta.
--  * As perguntas absurdas antigas do jogo (arquivo 86) são DESLIGADAS (não apagadas:
--    o admin pode ligar de novo). As que o admin cadastrou continuam como estão.
--  * 113 perguntas novas, calculadas com os dados do próprio jogo (altura e peso da
--    Pokédex do sql/02, atributos e poder dos golpes do sql/16) e com o número do
--    mundo real dentro da pergunta, para dar para raciocinar em vez de chutar.
--    Geradas por ferramentas/gerar_quiz_logica.py.
--  * A explicação só aparece no resultado, depois que o quiz fecha (quiz_current e
--    quiz_resultado_json). Enquanto está aberto, ninguém a recebe.
--  * O admin escreve a explicação ao criar um quiz e ao cadastrar uma pergunta no banco.
-- Nada de pontos, moedas ou prêmios muda.
-- =====================================================================

alter table public.quiz_banco add column if not exists explicacao text;
alter table public.quizzes add column if not exists explicacao text;

-- desliga as absurdas antigas do jogo (ficam no banco, o admin pode religar)
update public.quiz_banco set ativo = false where autor = 'jogo' and explicacao is null;

insert into public.quiz_banco(pergunta, resposta, explicacao) values
  ('Quantos Pikachu empilhados, um em cima do outro, alcançam o topo do Cristo Redentor (30 m)?', 75, 'Na Pokédex, o Pikachu mede 0,4 m. A estátua do Cristo Redentor tem 30 m (sem o pedestal). Então: 30 ÷ 0,4 = 75.'),
  ('Quantos Diglett empilhados, um em cima do outro, alcançam a trave do gol (2,44 m)?', 12, 'Na Pokédex, o Diglett mede 0,2 m. A trave de um gol oficial tem 2,44 m de altura. Então: 2,44 ÷ 0,2 = 12,2 → arredondando, 12.'),
  ('Quantos Diglett empilhados, um em cima do outro, alcançam o aro de uma cesta de basquete (3,05 m)?', 15, 'Na Pokédex, o Diglett mede 0,2 m. O aro do basquete fica a 3,05 m do chão. Então: 3,05 ÷ 0,2 = 15,25 → arredondando, 15.'),
  ('Quantos Onix empilhados, um em cima do outro, alcançam o topo do Monte Everest (8.849 m)?', 1006, 'Na Pokédex, o Onix mede 8,8 m. O Everest tem 8.849 m. Então: 8.849 ÷ 8,8 = 1.005,57… → arredondando, 1.006.'),
  ('Quantos Onix empilhados, um em cima do outro, alcançam o topo da Torre Eiffel (330 m)?', 38, 'Na Pokédex, o Onix mede 8,8 m. A Torre Eiffel tem 330 m. Então: 330 ÷ 8,8 = 37,5 → arredondando, 38.'),
  ('Quantos Onix empilhados, um em cima do outro, alcançam o topo do Pão de Açúcar (396 m)?', 45, 'Na Pokédex, o Onix mede 8,8 m. O Pão de Açúcar tem 396 m. Então: 396 ÷ 8,8 = 45.'),
  ('Quantos Snorlax empilhados, um em cima do outro, alcançam o topo do Cristo Redentor (30 m)?', 14, 'Na Pokédex, o Snorlax mede 2,1 m. A estátua do Cristo Redentor tem 30 m (sem o pedestal). Então: 30 ÷ 2,1 = 14,29… → arredondando, 14.'),
  ('Quantos Dragonite empilhados, um em cima do outro, alcançam o telhado de um prédio de 10 andares (30 m)?', 14, 'Na Pokédex, o Dragonite mede 2,2 m. Um prédio de 10 andares tem cerca de 30 m (3 m por andar). Então: 30 ÷ 2,2 = 13,64… → arredondando, 14.'),
  ('Quantos Mew empilhados, um em cima do outro, alcançam o topo da Torre Eiffel (330 m)?', 825, 'Na Pokédex, o Mew mede 0,4 m. A Torre Eiffel tem 330 m. Então: 330 ÷ 0,4 = 825.'),
  ('Quantos Jigglypuff empilhados, um em cima do outro, alcançam a cabeça de uma girafa (5,5 m)?', 11, 'Na Pokédex, o Jigglypuff mede 0,5 m. Uma girafa adulta tem cerca de 5,5 m. Então: 5,5 ÷ 0,5 = 11.'),
  ('Quantos Mewtwo empilhados, um em cima do outro, alcançam o topo do Pão de Açúcar (396 m)?', 198, 'Na Pokédex, o Mewtwo mede 2 m. O Pão de Açúcar tem 396 m. Então: 396 ÷ 2 = 198.'),
  ('Quantos Pidgey empilhados, um em cima do outro, alcançam a altura de um jogador de basquete (2,1 m)?', 7, 'Na Pokédex, o Pidgey mede 0,3 m. O jogador tem 2,10 m. Então: 2,1 ÷ 0,3 = 7.'),
  ('Quantos Bulbasaur empilhados, um em cima do outro, alcançam o topo do Cristo Redentor (30 m)?', 43, 'Na Pokédex, o Bulbasaur mede 0,7 m. A estátua do Cristo Redentor tem 30 m (sem o pedestal). Então: 30 ÷ 0,7 = 42,86… → arredondando, 43.'),
  ('Quantos Gyarados empilhados, um em cima do outro, alcançam o topo da Torre Eiffel (330 m)?', 51, 'Na Pokédex, o Gyarados mede 6,5 m. A Torre Eiffel tem 330 m. Então: 330 ÷ 6,5 = 50,77… → arredondando, 51.'),
  ('Quantos Onix deitados em fila, cabeça com rabo, cobrem a Ponte Rio–Niterói (13.290 m)?', 1510, 'O Onix mede 8,8 m na Pokédex (vamos usar a altura como o comprimento dele deitado). A Ponte Rio–Niterói tem 13.290 m. Então: 13.290 ÷ 8,8 = 1.510,23… → arredondando, 1.510.'),
  ('Quantos Gyarados deitados em fila, cabeça com rabo, cobrem um campo de futebol oficial (105 m)?', 16, 'O Gyarados mede 6,5 m na Pokédex (vamos usar a altura como o comprimento dele deitado). Um campo oficial tem 105 m de comprimento. Então: 105 ÷ 6,5 = 16,15… → arredondando, 16.'),
  ('Quantos Magikarp deitados em fila, cabeça com rabo, cobrem uma piscina olímpica (50 m)?', 56, 'O Magikarp mede 0,9 m na Pokédex (vamos usar a altura como o comprimento dele deitado). A piscina olímpica tem 50 m. Então: 50 ÷ 0,9 = 55,56… → arredondando, 56.'),
  ('Quantos Caterpie deitados em fila, cabeça com rabo, cobrem a pista dos 100 metros rasos (100 m)?', 333, 'O Caterpie mede 0,3 m na Pokédex (vamos usar a altura como o comprimento dele deitado). A pista tem 100 m. Então: 100 ÷ 0,3 = 333,33… → arredondando, 333.'),
  ('Quantos Ekans deitados em fila, cabeça com rabo, cobrem uma quadra de vôlei (18 m)?', 9, 'O Ekans mede 2 m na Pokédex (vamos usar a altura como o comprimento dele deitado). A quadra de vôlei tem 18 m de comprimento. Então: 18 ÷ 2 = 9.'),
  ('Quantos Arbok deitados em fila, cabeça com rabo, cobrem um campo de futebol oficial (105 m)?', 30, 'O Arbok mede 3,5 m na Pokédex (vamos usar a altura como o comprimento dele deitado). Um campo oficial tem 105 m de comprimento. Então: 105 ÷ 3,5 = 30.'),
  ('Quantos Dragonair deitados em fila, cabeça com rabo, cobrem uma piscina olímpica (50 m)?', 13, 'O Dragonair mede 4 m na Pokédex (vamos usar a altura como o comprimento dele deitado). A piscina olímpica tem 50 m. Então: 50 ÷ 4 = 12,5 → arredondando, 13.'),
  ('Quantos Lapras deitados em fila, cabeça com rabo, cobrem um ônibus urbano (12 m)?', 5, 'O Lapras mede 2,5 m na Pokédex (vamos usar a altura como o comprimento dele deitado). Um ônibus urbano tem cerca de 12 m. Então: 12 ÷ 2,5 = 4,8 → arredondando, 5.'),
  ('Quantos Pikachu deitados em fila, cabeça com rabo, cobrem uma quadra de futsal (40 m)?', 100, 'O Pikachu mede 0,4 m na Pokédex (vamos usar a altura como o comprimento dele deitado). Uma quadra de futsal tem 40 m de comprimento. Então: 40 ÷ 0,4 = 100.'),
  ('Quantos Seaking deitados em fila, cabeça com rabo, cobrem uma piscina olímpica (50 m)?', 38, 'O Seaking mede 1,3 m na Pokédex (vamos usar a altura como o comprimento dele deitado). A piscina olímpica tem 50 m. Então: 50 ÷ 1,3 = 38,46… → arredondando, 38.'),
  ('Quantos Rattata deitados em fila, cabeça com rabo, cobrem um campo de futebol oficial (105 m)?', 350, 'O Rattata mede 0,3 m na Pokédex (vamos usar a altura como o comprimento dele deitado). Um campo oficial tem 105 m de comprimento. Então: 105 ÷ 0,3 = 350.'),
  ('Quantos Dratini deitados em fila, cabeça com rabo, cobrem um ônibus urbano (12 m)?', 7, 'O Dratini mede 1,8 m na Pokédex (vamos usar a altura como o comprimento dele deitado). Um ônibus urbano tem cerca de 12 m. Então: 12 ÷ 1,8 = 6,67… → arredondando, 7.'),
  ('Quantos Pikachu juntos pesam o mesmo que o limite de um elevador de 8 pessoas (600 kg)?', 100, 'Na Pokédex, o Pikachu pesa 6 kg. O elevador aguenta 600 kg. Então: 600 ÷ 6 = 100.'),
  ('Quantos Pikachu juntos pesam o mesmo que um botijão de gás cheio (28 kg)?', 5, 'Na Pokédex, o Pikachu pesa 6 kg. O botijão cheio pesa cerca de 28 kg. Então: 28 ÷ 6 = 4,67… → arredondando, 5.'),
  ('Quantos Snorlax juntos pesam o mesmo que um elefante africano (6.000 kg)?', 13, 'Na Pokédex, o Snorlax pesa 460 kg. Um elefante africano pesa cerca de 6.000 kg. Então: 6.000 ÷ 460 = 13,04… → arredondando, 13.'),
  ('Quantos Snorlax juntos pesam o mesmo que uma baleia-azul (150.000 kg)?', 326, 'Na Pokédex, o Snorlax pesa 460 kg. A baleia-azul pesa cerca de 150.000 kg. Então: 150.000 ÷ 460 = 326,09… → arredondando, 326.'),
  ('Quantos Gastly juntos pesam o mesmo que uma pessoa (70 kg)?', 700, 'Na Pokédex, o Gastly pesa 0,1 kg. A pessoa pesa 70 kg. Então: 70 ÷ 0,1 = 700.'),
  ('Quantos Gastly juntos pesam o mesmo que uma tonelada (1.000 kg)?', 10000, 'Na Pokédex, o Gastly pesa 0,1 kg. Uma tonelada são 1.000 kg. Então: 1.000 ÷ 0,1 = 10.000.'),
  ('Quantos Golem juntos pesam o mesmo que um elefante africano (6.000 kg)?', 20, 'Na Pokédex, o Golem pesa 300 kg. Um elefante africano pesa cerca de 6.000 kg. Então: 6.000 ÷ 300 = 20.'),
  ('Quantos Golem juntos pesam o mesmo que um Fusca (800 kg)?', 3, 'Na Pokédex, o Golem pesa 300 kg. O Fusca pesa cerca de 800 kg. Então: 800 ÷ 300 = 2,67… → arredondando, 3.'),
  ('Quantos Eevee juntos pesam o mesmo que uma pessoa (70 kg)?', 11, 'Na Pokédex, o Eevee pesa 6,5 kg. A pessoa pesa 70 kg. Então: 70 ÷ 6,5 = 10,77… → arredondando, 11.'),
  ('Quantos Jigglypuff juntos pesam o mesmo que um saco de cimento (50 kg)?', 9, 'Na Pokédex, o Jigglypuff pesa 5,5 kg. O saco de cimento pesa 50 kg. Então: 50 ÷ 5,5 = 9,09… → arredondando, 9.'),
  ('Quantos Onix juntos pesam o mesmo que um carro popular (1.000 kg)?', 5, 'Na Pokédex, o Onix pesa 210 kg. O carro popular pesa cerca de 1.000 kg. Então: 1.000 ÷ 210 = 4,76… → arredondando, 5.'),
  ('Quantos Mew juntos pesam o mesmo que uma pessoa (70 kg)?', 18, 'Na Pokédex, o Mew pesa 4 kg. A pessoa pesa 70 kg. Então: 70 ÷ 4 = 17,5 → arredondando, 18.'),
  ('Quantos Charmander juntos pesam o mesmo que uma geladeira (70 kg)?', 8, 'Na Pokédex, o Charmander pesa 8,5 kg. A geladeira pesa 70 kg. Então: 70 ÷ 8,5 = 8,24… → arredondando, 8.'),
  ('Quantos Pidgey juntos pesam o mesmo que um peru de Natal (7 kg)?', 4, 'Na Pokédex, o Pidgey pesa 1,8 kg. O peru pesa 7 kg. Então: 7 ÷ 1,8 = 3,89… → arredondando, 4.'),
  ('Quantos Dragonite juntos pesam o mesmo que um carro popular (1.000 kg)?', 5, 'Na Pokédex, o Dragonite pesa 210 kg. O carro popular pesa cerca de 1.000 kg. Então: 1.000 ÷ 210 = 4,76… → arredondando, 5.'),
  ('Quantos Haunter juntos pesam o mesmo que uma bola de futebol (0,43 kg)?', 4, 'Na Pokédex, o Haunter pesa 0,1 kg. A bola oficial pesa cerca de 0,43 kg. Então: 0,43 ÷ 0,1 = 4,3 → arredondando, 4.'),
  ('Quantos Lapras juntos pesam o mesmo que um caminhão carregado (15.000 kg)?', 68, 'Na Pokédex, o Lapras pesa 220 kg. O caminhão pesa 15.000 kg. Então: 15.000 ÷ 220 = 68,18… → arredondando, 68.'),
  ('Quantos Diglett juntos pesam o mesmo que um saco de arroz (5 kg)?', 6, 'Na Pokédex, o Diglett pesa 0,8 kg. O saco de arroz pesa 5 kg. Então: 5 ÷ 0,8 = 6,25 → arredondando, 6.'),
  ('Quantas pessoas de 70 kg seria preciso pôr na balança para igualar o peso de um Snorlax?', 7, 'O Snorlax pesa 460 kg na Pokédex. Cada pessoa pesa 70 kg. Então: 460 ÷ 70 = 6,57… → arredondando, 7.'),
  ('Quantas pessoas de 70 kg seria preciso pôr na balança para igualar o peso de um Gyarados?', 3, 'O Gyarados pesa 235 kg na Pokédex. Cada pessoa pesa 70 kg. Então: 235 ÷ 70 = 3,36… → arredondando, 3.'),
  ('Quantas pessoas de 70 kg seria preciso pôr na balança para igualar o peso de um Golem?', 4, 'O Golem pesa 300 kg na Pokédex. Cada pessoa pesa 70 kg. Então: 300 ÷ 70 = 4,29… → arredondando, 4.'),
  ('Quantas pessoas de 70 kg seria preciso pôr na balança para igualar o peso de um Onix?', 3, 'O Onix pesa 210 kg na Pokédex. Cada pessoa pesa 70 kg. Então: 210 ÷ 70 = 3.'),
  ('Quantas pessoas de 70 kg seria preciso pôr na balança para igualar o peso de um Lapras?', 3, 'O Lapras pesa 220 kg na Pokédex. Cada pessoa pesa 70 kg. Então: 220 ÷ 70 = 3,14… → arredondando, 3.'),
  ('Quantas pessoas de 70 kg seria preciso pôr na balança para igualar o peso de um Dragonite?', 3, 'O Dragonite pesa 210 kg na Pokédex. Cada pessoa pesa 70 kg. Então: 210 ÷ 70 = 3.'),
  ('Quantos Magikarp juntos seria preciso pôr na balança para igualar o peso de um Gyarados?', 24, 'O Magikarp pesa 10 kg e o Gyarados pesa 235 kg. Então: 235 ÷ 10 = 23,5 → arredondando, 24.'),
  ('Quantos Caterpie juntos seria preciso pôr na balança para igualar o peso de um Butterfree?', 11, 'O Caterpie pesa 2,9 kg e o Butterfree pesa 32 kg. Então: 32 ÷ 2,9 = 11,03… → arredondando, 11.'),
  ('Quantos Gastly juntos seria preciso pôr na balança para igualar o peso de um Gengar?', 405, 'O Gastly pesa 0,1 kg e o Gengar pesa 40,5 kg. Então: 40,5 ÷ 0,1 = 405.'),
  ('Quantos Geodude juntos seria preciso pôr na balança para igualar o peso de um Golem?', 15, 'O Geodude pesa 20 kg e o Golem pesa 300 kg. Então: 300 ÷ 20 = 15.'),
  ('Quantos Charmander juntos seria preciso pôr na balança para igualar o peso de um Charizard?', 11, 'O Charmander pesa 8,5 kg e o Charizard pesa 90,5 kg. Então: 90,5 ÷ 8,5 = 10,65… → arredondando, 11.'),
  ('Quantos Squirtle juntos seria preciso pôr na balança para igualar o peso de um Blastoise?', 10, 'O Squirtle pesa 9 kg e o Blastoise pesa 85,5 kg. Então: 85,5 ÷ 9 = 9,5 → arredondando, 10.'),
  ('Quantos Bulbasaur juntos seria preciso pôr na balança para igualar o peso de um Venusaur?', 14, 'O Bulbasaur pesa 6,9 kg e o Venusaur pesa 100 kg. Então: 100 ÷ 6,9 = 14,49… → arredondando, 14.'),
  ('Quantos Pidgey juntos seria preciso pôr na balança para igualar o peso de um Pidgeot?', 22, 'O Pidgey pesa 1,8 kg e o Pidgeot pesa 39,5 kg. Então: 39,5 ÷ 1,8 = 21,94… → arredondando, 22.'),
  ('Quantos Pikachu juntos seria preciso pôr na balança para igualar o peso de um Raichu?', 5, 'O Pikachu pesa 6 kg e o Raichu pesa 30 kg. Então: 30 ÷ 6 = 5.'),
  ('Quantos Mew juntos seria preciso pôr na balança para igualar o peso de um Mewtwo?', 31, 'O Mew pesa 4 kg e o Mewtwo pesa 122 kg (o Mewtwo foi criado a partir do DNA do Mew). Então: 122 ÷ 4 = 30,5 → arredondando, 31.'),
  ('Quantos Onix juntos seria preciso pôr na balança para igualar o peso de um Snorlax?', 2, 'O Onix pesa 210 kg e o Snorlax pesa 460 kg. Então: 460 ÷ 210 = 2,19… → arredondando, 2.'),
  ('Quantos Dratini juntos seria preciso pôr na balança para igualar o peso de um Dragonite?', 64, 'O Dratini pesa 3,3 kg e o Dragonite pesa 210 kg. Então: 210 ÷ 3,3 = 63,64… → arredondando, 64.'),
  ('Quantos Machop juntos seria preciso pôr na balança para igualar o peso de um Machamp?', 7, 'O Machop pesa 19,5 kg e o Machamp pesa 130 kg. Então: 130 ÷ 19,5 = 6,67… → arredondando, 7.'),
  ('Quantos Weedle juntos seria preciso pôr na balança para igualar o peso de um Beedrill?', 9, 'O Weedle pesa 3,2 kg e o Beedrill pesa 29,5 kg. Então: 29,5 ÷ 3,2 = 9,22… → arredondando, 9.'),
  ('Quantos Poliwag juntos seria preciso pôr na balança para igualar o peso de um Poliwrath?', 4, 'O Poliwag pesa 12,4 kg e o Poliwrath pesa 54 kg. Então: 54 ÷ 12,4 = 4,35… → arredondando, 4.'),
  ('Quantos kg pesa, ao todo, um time com Charizard, Blastoise e Venusaur?', 276, 'Pela Pokédex: Charizard 90,5 kg, Blastoise 85,5 kg, Venusaur 100 kg. Somando: 90,5 + 85,5 + 100 = 276.'),
  ('Quantos kg pesa, ao todo, um time com Snorlax, Onix e Gyarados?', 905, 'Pela Pokédex: Snorlax 460 kg, Onix 210 kg, Gyarados 235 kg. Somando: 460 + 210 + 235 = 905.'),
  ('Quantos kg pesa, ao todo, um time com Articuno, Zapdos e Moltres?', 168, 'Pela Pokédex: Articuno 55,4 kg, Zapdos 52,6 kg, Moltres 60 kg. Somando: 55,4 + 52,6 + 60 = 168.'),
  ('Quantos kg pesa, ao todo, um time com Pikachu, Eevee, Jigglypuff e Meowth?', 22, 'Pela Pokédex: Pikachu 6 kg, Eevee 6,5 kg, Jigglypuff 5,5 kg, Meowth 4,2 kg. Somando: 6 + 6,5 + 5,5 + 4,2 = 22,2 → arredondando, 22.'),
  ('Quantos kg pesa, ao todo, um time com Machamp, Golem, Gengar e Alakazam?', 519, 'Pela Pokédex: Machamp 130 kg, Golem 300 kg, Gengar 40,5 kg, Alakazam 48 kg. Somando: 130 + 300 + 40,5 + 48 = 518,5 → arredondando, 519.'),
  ('Se Onix, Gyarados e Dragonair deitassem em fila, quantos metros a fila teria?', 19.3, 'Pela Pokédex: Onix 8,8 m, Gyarados 6,5 m, Dragonair 4 m. Somando: 8,8 + 6,5 + 4 = 19,3.'),
  ('Se Snorlax, Lapras e Dragonite deitassem em fila, quantos metros a fila teria?', 6.8, 'Pela Pokédex: Snorlax 2,1 m, Lapras 2,5 m, Dragonite 2,2 m. Somando: 2,1 + 2,5 + 2,2 = 6,8.'),
  ('Quantos metros o Onix é mais alto que o Pikachu?', 8.4, 'O Onix tem 8,8 m e o Pikachu tem 0,4 m. Então: 8,8 − 0,4 = 8,4.'),
  ('Quantos kg o Snorlax é mais pesado que o Pikachu?', 454, 'O Snorlax tem 460 kg e o Pikachu tem 6 kg. Então: 460 − 6 = 454.'),
  ('Quantos metros o Gyarados é mais alto que o Magikarp?', 5.6, 'O Gyarados tem 6,5 m e o Magikarp tem 0,9 m. Então: 6,5 − 0,9 = 5,6.'),
  ('Quantos kg o Golem é mais pesado que o Graveler?', 195, 'O Golem tem 300 kg e o Graveler tem 105 kg. Então: 300 − 105 = 195.'),
  ('Quantos metros o Mewtwo é mais alto que o Mew?', 1.6, 'O Mewtwo tem 2 m e o Mew tem 0,4 m. Então: 2 − 0,4 = 1,6.'),
  ('No atributo base de pontos de vida (o número da espécie na Red/Blue), quantas vezes o Chansey tem mais que o Pikachu?', 7.1, 'Na tabela da 1ª geração, o Chansey tem 250 de pontos de vida e o Pikachu tem 35. Então: 250 ÷ 35 = 7,14… → arredondando, 7,1.'),
  ('No atributo base de velocidade (o número da espécie na Red/Blue), quantas vezes o Electrode tem mais que o Slowpoke?', 9.3, 'Na tabela da 1ª geração, o Electrode tem 140 de velocidade e o Slowpoke tem 15. Então: 140 ÷ 15 = 9,33… → arredondando, 9,3.'),
  ('No atributo base de especial (o número da espécie na Red/Blue), quantas vezes o Alakazam tem mais que o Magikarp?', 6.8, 'Na tabela da 1ª geração, o Alakazam tem 135 de especial e o Magikarp tem 20. Então: 135 ÷ 20 = 6,75 → arredondando, 6,8.'),
  ('No atributo base de defesa (o número da espécie na Red/Blue), quantas vezes o Cloyster tem mais que o Abra?', 12, 'Na tabela da 1ª geração, o Cloyster tem 180 de defesa e o Abra tem 15. Então: 180 ÷ 15 = 12.'),
  ('No atributo base de ataque (o número da espécie na Red/Blue), quantas vezes o Machamp tem mais que o Chansey?', 26, 'Na tabela da 1ª geração, o Machamp tem 130 de ataque e o Chansey tem 5. Então: 130 ÷ 5 = 26.'),
  ('No atributo base de pontos de vida (o número da espécie na Red/Blue), quantas vezes o Snorlax tem mais que o Diglett?', 16, 'Na tabela da 1ª geração, o Snorlax tem 160 de pontos de vida e o Diglett tem 10. Então: 160 ÷ 10 = 16.'),
  ('No atributo base de velocidade (o número da espécie na Red/Blue), quantas vezes o Jolteon tem mais que o Snorlax?', 4.3, 'Na tabela da 1ª geração, o Jolteon tem 130 de velocidade e o Snorlax tem 30. Então: 130 ÷ 30 = 4,33… → arredondando, 4,3.'),
  ('Somando os 5 atributos base do Mewtwo (vida, ataque, defesa, velocidade e especial), quanto dá?', 590, 'Na tabela da 1ª geração, o Mewtwo tem vida 106, ataque 110, defesa 90, velocidade 130 e especial 154. Somando: 106 + 110 + 90 + 130 + 154 = 590.'),
  ('Somando os 5 atributos base do Snorlax (vida, ataque, defesa, velocidade e especial), quanto dá?', 430, 'Na tabela da 1ª geração, o Snorlax tem vida 160, ataque 110, defesa 65, velocidade 30 e especial 65. Somando: 160 + 110 + 65 + 30 + 65 = 430.'),
  ('Somando os 5 atributos base do Dragonite (vida, ataque, defesa, velocidade e especial), quanto dá?', 500, 'Na tabela da 1ª geração, o Dragonite tem vida 91, ataque 134, defesa 95, velocidade 80 e especial 100. Somando: 91 + 134 + 95 + 80 + 100 = 500.'),
  ('Somando os 5 atributos base do Pikachu (vida, ataque, defesa, velocidade e especial), quanto dá?', 260, 'Na tabela da 1ª geração, o Pikachu tem vida 35, ataque 55, defesa 30, velocidade 90 e especial 50. Somando: 35 + 55 + 30 + 90 + 50 = 260.'),
  ('Somando os 5 atributos base do Magikarp (vida, ataque, defesa, velocidade e especial), quanto dá?', 185, 'Na tabela da 1ª geração, o Magikarp tem vida 20, ataque 10, defesa 55, velocidade 80 e especial 20. Somando: 20 + 10 + 55 + 80 + 20 = 185.'),
  ('Quantos Tackle somam o mesmo poder de um único Hyper Beam?', 4.3, 'No jogo, o Tackle tem poder 35 e o Hyper Beam tem poder 150. Então: 150 ÷ 35 = 4,29… → arredondando, 4,3.'),
  ('Quantos Scratch somam o mesmo poder de um único Explosion?', 4.3, 'No jogo, o Scratch tem poder 40 e o Explosion tem poder 170. Então: 170 ÷ 40 = 4,25 → arredondando, 4,3.'),
  ('Quantos Ember somam o mesmo poder de um único Fire Blast?', 3, 'No jogo, o Ember tem poder 40 e o Fire Blast tem poder 120. Então: 120 ÷ 40 = 3.'),
  ('Quantos Water Gun somam o mesmo poder de um único Hydro Pump?', 3, 'No jogo, o Water Gun tem poder 40 e o Hydro Pump tem poder 120. Então: 120 ÷ 40 = 3.'),
  ('Quantos Pound somam o mesmo poder de um único Hyper Beam?', 3.8, 'No jogo, o Pound tem poder 40 e o Hyper Beam tem poder 150. Então: 150 ÷ 40 = 3,75 → arredondando, 3,8.'),
  ('A Pokédex diz que o Snorlax come 400 kg de comida por dia. Quantos pratos de feijoada de 500 g ele comeria num dia?', 800, '400 kg = 400.000 g. Cada prato tem 500 g. Então: 400.000 ÷ 500 = 800 pratos.'),
  ('O Snorlax come 400 kg de comida por dia. Em quantos dias ele comeria 1 tonelada (1.000 kg) de comida?', 2.5, '1.000 ÷ 400 = 2,5 dias.'),
  ('A Pokédex diz que o Dragonite dá a volta ao mundo (40.000 km) em 16 horas. Quantas horas ele levaria de São Paulo a Lisboa (7.900 km)?', 3.2, 'Velocidade: 40.000 ÷ 16 = 2.500 km por hora. São Paulo a Lisboa: 7.900 ÷ 2.500 = 3,16… arredondando, 3,2 horas.'),
  ('O Dragonite dá a volta ao mundo (40.000 km) em 16 horas. Quantos minutos ele levaria do Rio a São Paulo (430 km)?', 10, 'Velocidade: 40.000 ÷ 16 = 2.500 km por hora. 430 ÷ 2.500 = 0,172 hora. 0,172 × 60 = 10,32… arredondando, 10 minutos.'),
  ('A Pokédex diz que o Arcanine corre 10.000 km num dia. Quantos dias ele levaria para dar a volta na Terra (40.000 km)?', 4, '40.000 ÷ 10.000 = 4 dias.'),
  ('O Arcanine corre 10.000 km em 24 horas. Quantas horas ele levaria de Porto Alegre a Manaus (cerca de 4.500 km)?', 10.8, 'Velocidade: 10.000 ÷ 24 = 416,7 km por hora. 4.500 ÷ 416,7 = 10,8 horas.'),
  ('Dizem que o Alakazam tem QI de 5.000. Quantas pessoas com QI 100 seria preciso somar para dar o QI de um Alakazam?', 50, '5.000 ÷ 100 = 50 pessoas.'),
  ('Dizem que o Machamp dá 1.000 socos em 2 segundos. Quantos socos ele daria numa partida de futebol de 90 minutos?', 2700000, '1.000 socos em 2 s = 500 socos por segundo. 90 minutos = 5.400 s. 500 × 5.400 = 2.700.000 socos.'),
  ('Dizem que o Machamp dá 1.000 socos em 2 segundos. Quantos socos em 1 minuto?', 30000, '500 socos por segundo × 60 s = 30.000 socos.'),
  ('A Pokédex diz que o Onix cava túneis a 80 km/h. Quantos minutos ele levaria para cavar um túnel de 20 km?', 15, '20 ÷ 80 = 0,25 hora. 0,25 × 60 = 15 minutos.'),
  ('Cada Exeggcute é um grupo de 6 ovos e pesa 2,5 kg. Quantos gramas pesa cada ovo?', 417, '2,5 kg = 2.500 g. 2.500 ÷ 6 = 416,7… arredondando, 417 g.'),
  ('O Dugtrio são 3 Diglett juntos, mas pesa 33,3 kg. Quantos kg ele pesa A MAIS do que 3 Diglett somados?', 30.9, 'Cada Diglett pesa 0,8 kg; 3 Diglett = 2,4 kg. 33,3 − 2,4 = 30,9 kg.'),
  ('O Magneton é feito de 3 Magnemite. Quantos kg ele pesa A MAIS do que 3 Magnemite somados?', 42, 'O Magnemite pesa 6 kg; 3 deles = 18 kg. O Magneton pesa 60 kg. 60 − 18 = 42 kg.'),
  ('Num time de 6 Machamp, quantos braços tem ao todo?', 24, 'Cada Machamp tem 4 braços. 6 × 4 = 24 braços.'),
  ('Quantas cabeças somam, juntos, 1 Dodrio, 1 Dugtrio, 1 Exeggutor e 1 Magneton?', 12, 'Dodrio 3, Dugtrio 3, Exeggutor 3 (as cabeças de coco) e Magneton 3 (os 3 Magnemite). 3 + 3 + 3 + 3 = 12.'),
  ('Se o Onix ficasse em pé ao lado de um prédio, ele chegaria a qual andar? (cada andar tem 3 m)', 3, 'O Onix mede 8,8 m. 8,8 ÷ 3 = 2,93… arredondando, ele chega no 3º andar.'),
  ('Um Gyarados cabe numa piscina de casa de 8 m? Responda quantos metros SOBRAM (ou negativo se faltar).', 1.5, 'O Gyarados mede 6,5 m. 8 − 6,5 = 1,5 m de sobra.'),
  ('Um Snorlax dorme no meio da estrada. Quantos guinchos que puxam 120 kg cada seriam precisos para tirar ele de lá?', 4, 'O Snorlax pesa 460 kg. 460 ÷ 120 = 3,83. Como não dá para usar pedaço de guincho, são 4.'),
  ('Uma ponte de madeira aguenta 100 kg. Quantos Pikachu inteiros podem atravessar juntos sem ela quebrar?', 16, 'O Pikachu pesa 6 kg. 100 ÷ 6 = 16,67…, então cabem 16 inteiros (o 17º quebraria a ponte).')
on conflict (pergunta) do update set resposta = excluded.resposta, explicacao = excluded.explicacao, ativo = true;

-- sorteio (versão do 86 + explicação)
create or replace function public.quiz_sorteio() returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare b quiz_banco; c jsonb := public.quiz_auto_cfg(); pr jsonb;
begin
  select * into b from quiz_banco where ativo order by usos, random() limit 1;
  if b.id is null then return null; end if;
  update quiz_banco set usos = usos + 1, usado_em = now() where id = b.id;
  select x into pr from jsonb_array_elements(coalesce(c->'premios', '[]'::jsonb)) x order by random() limit 1;
  return jsonb_build_object('id', b.id, 'question', b.pergunta, 'answer', b.resposta, 'explicacao', b.explicacao,
    'prize', coalesce(pr, '{}'::jsonb), 'prize_txt', public.quiz_premio_txt(coalesce(pr, '{}'::jsonb)),
    'seconds', coalesce((c->>'segundos')::int, 20));
end $$;

-- quiz automático (versão do 86 + explicação e o texto novo)
create or replace function public.quiz_auto_tick() returns void
language plpgsql security definer set search_path = public, extensions as $$
declare c jsonb := public.quiz_auto_cfg(); tz text := coalesce(public.cfg()->>'timezone', 'America/Sao_Paulo'); loc timestamp := now() at time zone tz;
  d date := (now() at time zone tz)::date; h int; mi int; st timestamptz; s jsonb; chk jsonb; pr jsonb;
begin
  if not coalesce((c->>'on')::boolean, true) or public.jogo_pausado() then return; end if;
  if to_regclass('public.sql_aplicados') is null then return; end if;
  if not (extract(dow from loc)::int in (select x::int from jsonb_array_elements_text(coalesce(c->'dias', '[]'::jsonb)) x)) then return; end if;
  h := (c->>'hora_min')::int + abs(hashtext('quiz' || d::text)) % greatest(1, (c->>'hora_max')::int - (c->>'hora_min')::int);
  mi := abs(hashtext('quizmin' || d::text)) % 60;
  st := (d + make_interval(hours => h, mins => mi)) at time zone tz;
  if now() < st or now() > st + interval '3 hours' then return; end if;
  if exists (select 1 from quizzes where status = 'aberto') or exists (select 1 from quizzes where auto and created_at >= st - interval '1 hour') then return; end if;
  perform pg_advisory_xact_lock(3838);
  if exists (select 1 from quizzes where status = 'aberto') or exists (select 1 from quizzes where auto and created_at >= st - interval '1 hour') then return; end if;
  s := public.quiz_sorteio(); if s is null then return; end if;
  pr := s->'prize';
  chk := public.gift_check(array(select jsonb_array_elements_text(coalesce(pr->'items', '[]'::jsonb))), coalesce((pr->>'coins')::int, 0),
           coalesce((pr->>'hints')::int, 0), coalesce((pr->>'retries')::int, 0), coalesce(pr->'bag', '{}'::jsonb));
  insert into quizzes(title, intro, prize, question, answer, explicacao, seconds, closes_at, created_by, prize_coins, prize_hints, prize_retries, prize_bag, prize_items, auto)
  values ('Quiz surpresa!', case when s->>'explicacao' is not null
            then 'Pergunta de lógica com os dados dos Pokémon! Pense rápido e faça a conta: quem chegar mais perto ganha. A explicação sai junto com o resultado.'
            else 'Pergunta surpresa do mundo Pokémon! Quem chegar mais perto ganha.' end, s->>'prize_txt',
          s->>'question', (s->>'answer')::numeric, s->>'explicacao', (s->>'seconds')::int, now() + make_interval(hours => coalesce((c->>'prazo_horas')::int, 24)),
          (select user_id from user_roles where role = 'admin' order by user_id limit 1),
          (chk->>'coins')::int, (chk->>'hints')::int, (chk->>'retries')::int, chk->'bag', array(select jsonb_array_elements_text(chk->'items')), true);
end $$;

-- banco de perguntas (versão do 86 + explicação)
drop function if exists public.admin_quiz_banco_save(bigint, text, numeric, boolean);
create or replace function public.admin_quiz_banco_save(_id bigint, _pergunta text, _resposta numeric, _ativo boolean default true, _explicacao text default null) returns public.quiz_banco
language plpgsql security definer set search_path = public, extensions as $$
declare b quiz_banco; ex text := nullif(left(btrim(coalesce(_explicacao, '')), 1000), '');
begin
  perform public.assert_admin();
  if char_length(btrim(coalesce(_pergunta, ''))) not between 5 and 300 then raise exception 'Pergunta: de 5 a 300 letras.'; end if;
  if _resposta is null then raise exception 'Informe a resposta oficial (um número).'; end if;
  if _id is null then
    insert into quiz_banco(pergunta, resposta, autor, ativo, explicacao) values (btrim(_pergunta), _resposta, 'admin', coalesce(_ativo, true), ex) returning * into b;
  else
    -- sem explicação nova, mantém a que já tinha (ligar/desligar não apaga)
    update quiz_banco set pergunta = btrim(_pergunta), resposta = _resposta, ativo = coalesce(_ativo, true), explicacao = coalesce(ex, explicacao)
     where id = _id returning * into b;
    if b.id is null then raise exception 'Pergunta não encontrada.'; end if;
  end if;
  return b;
exception when unique_violation then raise exception 'Essa pergunta já está no banco.';
end $$;
revoke execute on function public.admin_quiz_banco_save(bigint, text, numeric, boolean, text) from public, anon;
grant execute on function public.admin_quiz_banco_save(bigint, text, numeric, boolean, text) to authenticated;

-- criar quiz (versão do 51 + explicação)
drop function if exists public.admin_quiz_save(text, text, text, text, numeric, int, int, int, int, int, jsonb, text[]);
create or replace function public.admin_quiz_save(_title text, _intro text, _prize text, _question text, _answer numeric, _seconds int default 15, _hours int default 24,
  _prize_coins int default 0, _prize_hints int default 0, _prize_retries int default 0, _prize_bag jsonb default '{}'::jsonb, _prize_items text[] default '{}',
  _explicacao text default null)
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
  chk := public.gift_check(_prize_items, _prize_coins, _prize_hints, _prize_retries, _prize_bag);
  insert into quizzes(title, intro, prize, question, answer, explicacao, seconds, closes_at, created_by, prize_coins, prize_hints, prize_retries, prize_bag, prize_items)
  values (btrim(_title), left(btrim(coalesce(_intro, '')), 500), left(btrim(coalesce(_prize, '')), 200), btrim(_question), _answer,
          nullif(left(btrim(coalesce(_explicacao, '')), 1000), ''),
          coalesce(_seconds, 15), now() + make_interval(hours => coalesce(_hours, 24)), uid,
          (chk->>'coins')::int, (chk->>'hints')::int, (chk->>'retries')::int, chk->'bag', array(select jsonb_array_elements_text(chk->'items')))
  returning * into q;
  insert into admin_audit_log(admin_id, action, target, after) values (uid, 'quiz', q.id::text, to_jsonb(q));
  return q;
end $$;
revoke execute on function public.admin_quiz_save(text, text, text, text, numeric, int, int, int, int, int, jsonb, text[], text) from public, anon;
grant execute on function public.admin_quiz_save(text, text, text, text, numeric, int, int, int, int, int, jsonb, text[], text) to authenticated;

-- resultado de um quiz encerrado (versão do 125 + explicação)
create or replace function public.quiz_resultado_json(_q public.quizzes) returns jsonb
language plpgsql stable security definer set search_path = public, extensions as $$
declare res jsonb; wname text;
begin
  if _q.id is null then return null; end if;
  select coalesce(jsonb_agg(jsonb_build_object('user_id', r.user_id, 'name', r.name, 'guess', r.guess, 'diff', r.diff, 'tempo', r.tempo)
                            order by r.diff, r.tempo, r.answered_at), '[]'::jsonb)
    into res
    from (select x.user_id, ch.name, x.guess, abs(x.guess - _q.answer) diff, x.answered_at,
                 round(extract(epoch from x.answered_at - x.revealed_at)::numeric, 1) tempo
            from quiz_entries x join characters ch on ch.user_id = x.user_id
           where x.quiz_id = _q.id and x.guess is not null) r;
  select name into wname from characters where user_id = _q.winner;
  return jsonb_build_object(
    'id', _q.id, 'title', _q.title, 'intro', _q.intro, 'prize', _q.prize, 'seconds', _q.seconds,
    'status', 'encerrado', 'closes_at', _q.closes_at, 'closed_at', _q.closed_at,
    'question', _q.question, 'answer', _q.answer, 'explicacao', _q.explicacao,
    'winner', _q.winner, 'winner_name', wname, 'results', res
  );
end $$;
revoke execute on function public.quiz_resultado_json(public.quizzes) from public, anon, authenticated;

-- quiz da vez (versão do 125 + explicação, só depois de encerrado)
create or replace function public.quiz_current() returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); q quizzes; ult quizzes; e quiz_entries; total int; done int; res jsonb; left_s numeric; ult_json jsonb;
begin
  perform public.quiz_auto_tick();
  select * into q from quizzes where status = 'aberto' order by id desc limit 1;
  if q.id is not null then perform public.quiz_tick(q.id); select * into q from quizzes where id = q.id; end if;

  select * into ult from quizzes where status = 'encerrado' order by closed_at desc nulls last, id desc limit 1;
  ult_json := public.quiz_resultado_json(ult);

  if q.id is null or q.status <> 'aberto' then
    q := ult;
  end if;
  if q.id is null then return null; end if;

  select * into e from quiz_entries where quiz_id = q.id and user_id = uid;
  select count(*) into total from public.day_active(public.game_today()) a where not public.has_role(a.user_id, 'admin');
  select count(*) into done from quiz_entries x where x.quiz_id = q.id and x.answered_at is not null and not public.has_role(x.user_id, 'admin');
  left_s := case when e.revealed_at is not null and e.answered_at is null
                 then greatest(0, extract(epoch from (e.revealed_at + make_interval(secs => q.seconds) - now()))) end;
  if q.status = 'encerrado' then
    res := ult_json->'results';
  end if;
  return jsonb_build_object(
    'id', q.id, 'title', q.title, 'intro', q.intro, 'prize', q.prize, 'seconds', q.seconds,
    'status', q.status, 'closes_at', q.closes_at, 'closed_at', q.closed_at,
    'answered', done, 'total', total,
    'me', case when e.user_id is null then 'novo' when e.answered_at is not null then 'respondeu'
               when left_s > 0 then 'respondendo' else 'perdeu' end,
    'my_guess', e.guess, 'left', left_s,
    'question', case when q.status = 'encerrado' or e.user_id is not null then q.question end,
    'answer', case when q.status = 'encerrado' then q.answer end,
    'explicacao', case when q.status = 'encerrado' then q.explicacao end,
    'winner', q.winner, 'winner_name', case when q.status = 'encerrado' then ult_json->>'winner_name' end,
    'results', res, 'ultimo', ult_json);
end $$;

-- Jornal (regra 10)
insert into public.posts(kind, title, body, created_by)
select 'novidade', x.title, x.body, coalesce((select user_id from public.user_roles where role = 'admin' order by user_id limit 1), '00000000-0000-0000-0000-000000000000'::uuid)
  from (values ('🧠 Quiz novo: perguntas de lógica com explicação', 'As perguntas do Quiz mudaram! Saem as perguntas absurdas e entram mais de 100 perguntas de lógica com os dados dos próprios Pokémon: altura e peso da Pokédex, atributos de batalha, poder dos golpes e o que eles fariam no nosso mundo.
• Exemplo: "Quantos Onix empilhados alcançam o topo da Torre Eiffel (330 m)?"
• O número do mundo real vem na pergunta: pense no tamanho do Pokémon e faça a conta, nada de chute!
• Quando o quiz fecha, o resultado mostra a explicação: de onde veio cada número e a conta até a resposta.')) x(title, body)
 where not exists (select 1 from public.posts p where p.title = x.title);
