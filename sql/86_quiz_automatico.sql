-- =====================================================================
-- POKEGAMES — Quiz automático com perguntas absurdas (pedido do dono em 09/11/2026).
--  * quiz_banco: 319 perguntas inventadas do mundo Pokémon, com resposta "oficial"
--    inventada (nada de dados reais). O admin cadastra, edita, desliga e apaga as dele.
--  * Quiz automático (game_config.config.quiz_auto, Ajustes do jogo): nos dias
--    marcados (padrão segunda, quarta e sexta), num horário sorteado entre 18h e
--    22h (igual para todos), abre sozinho um quiz com uma pergunta do banco e um
--    prêmio sorteado da lista. Quem chegar mais perto ganha, como sempre.
--    Abre quando alguém estiver com o jogo aberto (quiz_current chama quiz_auto_tick).
--  * Pergunta não repete até todas terem saído (usos).
--  * Botão "Sortear pergunta" no admin: admin_quiz_sortear.
-- Antes de rodar à mão, faça a cópia de segurança.
-- =====================================================================

create table if not exists public.quiz_banco (
  id        bigserial primary key,
  pergunta  text not null unique check (char_length(pergunta) between 5 and 300),
  resposta  numeric not null,
  autor     text not null default 'jogo' check (autor in ('jogo', 'admin')),
  ativo     boolean not null default true,
  usos      int not null default 0,
  usado_em  timestamptz,
  created_at timestamptz not null default now()
);
alter table public.quiz_banco enable row level security;
drop policy if exists quiz_banco_admin on public.quiz_banco;
create policy quiz_banco_admin on public.quiz_banco for select to authenticated using (public.is_admin());
revoke all on public.quiz_banco from anon, authenticated;
grant select on public.quiz_banco to authenticated;

alter table public.quizzes add column if not exists auto boolean not null default false;

insert into public.quiz_banco(pergunta, resposta) values
  ('Quantos kg de sushi o Snorlax come em uma hora?', 47),
  ('Quanto o Mr. Mime ganha por dia como mímico no circo, em moedas?', 85),
  ('Quantas vezes por dia o Psyduck esquece onde deixou as chaves?', 23),
  ('Quantos boletos o Meowth pagou atrasado no último ano?', 11),
  ('Em quantos minutos o Slowpoke termina de ler uma mensagem de "oi"?', 38),
  ('Quantos litros de café o Machamp toma antes do treino?', 6),
  ('Quantas selfies o Jigglypuff tira antes de postar uma?', 64),
  ('Quantos anos o Magikarp passou na faculdade sem se formar?', 9),
  ('Quantas vezes por semana o Gengar assusta o próprio reflexo?', 4),
  ('Quantos centímetros o cabelo da Jynx cresce por mês?', 13),
  ('Quantas vezes o Ditto já fingiu ser outra pessoa numa reunião de condomínio?', 17),
  ('Quanto o Pikachu cobra para carregar um celular, em moedas?', 3),
  ('Quantas pizzas o Snorlax pede num domingo chuvoso?', 19),
  ('Quantos travesseiros o Snorlax usa para dormir?', 12),
  ('Quantas horas por dia o Snorlax passa acordado?', 2),
  ('Quantos cochilos o Snorlax tira entre o café da manhã e o almoço?', 5),
  ('Quantos quilos de pipoca o Snorlax come numa sessão de cinema?', 8),
  ('Quantas vezes o Psyduck já teve dor de cabeça só nesta semana?', 31),
  ('Quantos remédios para dor de cabeça o Psyduck toma por mês?', 42),
  ('Quantos minutos o Slowpoke leva para perceber que está chovendo?', 27),
  ('Quantas vezes o Slowpoke já perdeu o ônibus este ano?', 112),
  ('Quantos anos o Slowpoke levou para terminar o ensino médio?', 14),
  ('Quantos centímetros por hora o Slowpoke anda numa caminhada animada?', 35),
  ('Quantos pulos o Magikarp dá antes de desistir de um problema?', 200),
  ('Quantas entrevistas de emprego o Magikarp já fez sem passar?', 58),
  ('Quantas vezes o Magikarp já se inscreveu no torneio de natação e chegou em último?', 26),
  ('Quantas moedas o Meowth acha no chão num dia bom?', 73),
  ('Quantas vezes por dia o Meowth fala "isso é um absurdo"?', 15),
  ('Quantos planos mirabolantes a Equipe Rocket faz por semana?', 7),
  ('Quantas vezes a Equipe Rocket já "decolou de novo" este mês?', 22),
  ('Quantos balões a Equipe Rocket já perdeu na vida?', 96),
  ('Quantos minutos a Equipe Rocket gasta só no discurso de apresentação?', 4),
  ('Quantas pessoas o Jigglypuff já fez dormir num único show?', 340),
  ('Quantas canetas o Jigglypuff gastou rabiscando a cara de quem dormiu no show?', 51),
  ('Quantos fãs o Jigglypuff tem acordados até o fim do show?', 0),
  ('Quantas horas o Machamp passa na academia por dia?', 5),
  ('Quantas caixas de mudança o Machamp carrega de uma vez?', 16),
  ('Quantos frangos grelhados o Machamp come por semana?', 28),
  ('Quantos pares de luvas o Machamp gasta por ano?', 2),
  ('Quantos copos o Mr. Mime quebra por mês fingindo que eles existem?', 0),
  ('Quantas paredes invisíveis o Mr. Mime constrói num dia de trabalho?', 44),
  ('Quantas vezes o Mr. Mime já ficou preso numa caixa imaginária?', 9),
  ('Quantas formas diferentes o Ditto consegue fazer antes do almoço?', 37),
  ('Quantas vezes o Ditto já esqueceu a própria forma original?', 3),
  ('Quantos sapatos o Ditto tem, sendo que não tem pés?', 21),
  ('Quantos sustos o Gengar dá numa noite de sexta?', 66),
  ('Quantas vezes o Gengar já riu sozinho no escuro esta semana?', 48),
  ('Quantos lençóis o Gengar já pegou emprestado para fazer fantasia?', 13),
  ('Quantos boletos de energia o Pikachu já pagou por conta própria?', 0),
  ('Quantos celulares o Pikachu já queimou carregando rápido demais?', 18),
  ('Quantas vezes o Pikachu se recusou a entrar na Poké Bola só este ano?', 365),
  ('Quanto custa uma consulta com a Chansey, em moedas?', 25),
  ('Quantos ovos a Chansey distribui num plantão de 12 horas?', 60),
  ('Quantos plantões a Chansey faz por mês no Centro Pokémon?', 22),
  ('Quantos curativos a Chansey usa por dia?', 130),
  ('Quantos metros de cachecol a Jynx tricotou neste inverno?', 41),
  ('Quantas músicas a Jynx canta no karaokê antes de soltar o microfone?', 11),
  ('Quantos degraus o Onix desce por minuto quando está atrasado?', 90),
  ('Quantos túneis o Onix cavou sem querer no último mês?', 33),
  ('Quantos óculos escuros o Onix tem na coleção?', 4),
  ('Quantas pedras o Geodude carrega no bolso, sendo que não tem bolso?', 7),
  ('Quantas vezes o Geodude rolou ladeira abaixo sem querer este ano?', 52),
  ('Quantos alho-porós o Farfetch''d tem guardados na despensa?', 29),
  ('Quantas vezes o Farfetch''d já trocou o alho-poró por um novo?', 3),
  ('Quantos metros de língua o Lickitung usa para lamber um sorvete?', 2),
  ('Quantos sorvetes o Lickitung toma num dia de calor?', 14),
  ('Quantos fios a Tangela penteia por dia?', 1000),
  ('Quantas horas a Tangela leva para desembaraçar o cabelo?', 6),
  ('Quantos sacos de compras a Kangaskhan carrega na bolsa?', 5),
  ('Quantas vezes a Kangaskhan já perdeu a chave dentro da própria bolsa?', 19),
  ('Quantas cabeças do Exeggutor concordam com a mesma ideia num dia normal?', 1),
  ('Quantas discussões as cabeças do Exeggutor têm antes do café?', 8),
  ('Quantos ossos o Cubone tem na coleção?', 73),
  ('Quantos chutes por minuto o Hitmonlee dá quando está nervoso?', 120),
  ('Quantos socos o Hitmonchan dá para fechar uma porta emperrada?', 3),
  ('Quantas vezes o Koffing já foi expulso de uma festa por causa do cheiro?', 12),
  ('Quantos sabonetes o Grimer já tentou usar sem sucesso?', 47),
  ('Quantos banhos o Muk tomou este ano?', 0),
  ('Quantas vezes o Voltorb já foi confundido com uma Poké Bola na loja?', 88),
  ('Quantas vezes o Electrode explodiu de raiva numa fila de banco?', 6),
  ('Quantos sonhos o Drowzee come num único jantar?', 24),
  ('Quantas pessoas o Hypno hipnotizou para furar a fila do pão?', 15),
  ('Quantas vezes o Krabby beliscou o próprio dono sem querer?', 41),
  ('Quantos guarda-sóis o Tentacool já furou na praia?', 9),
  ('Quantas estrelas do mar o Staryu cumprimenta numa caminhada na areia?', 57),
  ('Quantas vezes o Starmie girou de alegria numa festa?', 300),
  ('Quantos cavalos-marinhos o Horsea convidou para o aniversário?', 20),
  ('Quantos chifres o Goldeen já entortou batendo no vidro do aquário?', 2),
  ('Quantas vezes o Seaking ganhou o concurso de beleza do rio?', 8),
  ('Quantas evoluções o Eevee já cogitou antes de decidir o café da manhã?', 8),
  ('Quantas vezes o Eevee mudou de ideia sobre qual pedra comprar?', 43),
  ('Quantos vírus o Porygon já pegou navegando na internet?', 12),
  ('Quantas atualizações o Porygon instala por mês?', 31),
  ('Quantos passageiros a Lapras leva de uma vez para o outro lado do lago?', 6),
  ('Quantas músicas tristes a Lapras canta por noite?', 10),
  ('Quantos dinossauros o Aerodactyl lembra de ter conhecido pessoalmente?', 4),
  ('Quantas cartas o Dragonite entrega por dia como carteiro?', 250),
  ('Quantas vezes o Dragonite errou o endereço este mês?', 5),
  ('Quantas colheres o Mewtwo entorta por pura raiva?', 17),
  ('Quantas horas por dia o Mewtwo passa refletindo sobre o sentido da vida?', 11),
  ('Quantas vezes o Mew já se escondeu dentro de uma caixa de sapato?', 29),
  ('Quantos cubos de gelo o Articuno faz por hora para a sorveteria?', 500),
  ('Quantos raios o Zapdos solta quando o Wi-Fi cai?', 14),
  ('Quantas churrasqueiras o Moltres acendeu no último feriado?', 23),
  ('Quantas velas de aniversário o Charizard apaga sem querer?', 60),
  ('Quantas vezes o Charizard se recusou a obedecer só este ano?', 99),
  ('Quantos litros de água o Blastoise gasta para regar o jardim?', 300),
  ('Quantas flores a Venusaur cultiva nas costas?', 1),
  ('Quantos quilos de adubo o Bulbasaur usa por mês?', 3),
  ('Quantos óculos escuros o Squirtle tem guardados?', 5),
  ('Quantas vezes o Squirtle já fez parte de uma gangue de bermuda?', 1),
  ('Quantos marshmallows o Charmander assa com a ponta da cauda numa noite?', 36),
  ('Quantas folhas a Caterpie come antes de dormir?', 45),
  ('Quantas horas por dia o Metapod passa parado esperando algo acontecer?', 24),
  ('Quantas vezes o Weedle picou o dedo do treinador sem querer?', 12),
  ('Quantas vezes a Kakuna já pensou em desistir de virar Beedrill?', 3),
  ('Quantos favos de mel o Beedrill protege por dia?', 80),
  ('Quantas sementes o Pidgey bica no parque numa manhã?', 210),
  ('Quantos queijos o Rattata rouba da cozinha por semana?', 13),
  ('Quantas vezes o Raticate roeu o fio da TV?', 7),
  ('Quantas brigas o Spearow arruma por dia?', 5),
  ('Quantas vezes o Fearow deu bicada no carteiro?', 18),
  ('Quantos nós o Ekans já deu no próprio corpo?', 4),
  ('Quantas vezes o Arbok tentou assustar alguém e assustou a si mesmo?', 9),
  ('Quantos buracos a Sandshrew cava na praia num dia de férias?', 27),
  ('Quantas vezes o Nidoking pisou num brinquedo descalço?', 11),
  ('Quantos pedidos a Clefairy faz para a lua por noite?', 3),
  ('Quantas caudas a Vulpix penteia antes de sair de casa?', 6),
  ('Quantas fofocas a Ninetales lembra de cada vizinho?', 900),
  ('Quantas vezes o Zubat bateu no poste por estar de olhos fechados?', 74),
  ('Quantas vezes o Golbat apareceu numa caverna sem ser convidado?', 500),
  ('Quantos raios de sol o Oddish toma por dia, sendo que só sai à noite?', 0),
  ('Quantos cogumelos o Paras carrega nas costas para vender na feira?', 2),
  ('Quantos insetos o Venonat vê com aqueles olhos enormes por minuto?', 62),
  ('Quantos centímetros do Diglett ninguém nunca viu?', 80),
  ('Quantas vezes os três Dugtrio discordam sobre o caminho?', 10),
  ('Quantos novelos de lã o Persian destrói por mês?', 12),
  ('Quantas vezes por dia o Mankey fica bravo sem motivo?', 40),
  ('Quantas vezes o Primeape ficou bravo só de ler esta pergunta?', 1),
  ('Quantos carteiros o Growlithe já perseguiu?', 35),
  ('Quantos quilômetros o Arcanine corre antes do café da manhã?', 10),
  ('Quantas voltas a espiral da barriga do Poliwag dá?', 7),
  ('Quantas vezes o Abra teleportou para longe de uma conversa chata?', 30),
  ('Quantas colheres o Kadabra tem na gaveta?', 1),
  ('Quantos livros o Alakazam lê por semana?', 150),
  ('Quantos regadores o Bellsprout esvazia num dia de calor?', 4),
  ('Quantos ferros de passar a crina do Ponyta já queimou?', 8),
  ('Quantos quilômetros por hora o Rapidash corre no trânsito da cidade?', 240),
  ('Quantos ímãs de geladeira o Magnemite colou sem querer?', 65),
  ('Quantas vezes as duas cabeças do Doduo brigaram pelo mesmo milho?', 20),
  ('Quantas bolas o Seel equilibra no nariz num show?', 5),
  ('Quantos picolés o Dewgong vende na praia por dia?', 90),
  ('Quantas pérolas o Shellder já escondeu do Cloyster?', 7),
  ('Quantos espinhos o Cloyster lixou para ir a uma festa?', 0),
  ('Quantas vezes o Gastly assustou alguém sem querer só por existir?', 25),
  ('Quantas línguas o Haunter já mostrou numa foto de família?', 14),
  ('Quantas portas o Rhyhorn já derrubou porque esqueceu de virar?', 31),
  ('Quantas vezes o Rhydon esqueceu por que entrou num cômodo?', 19),
  ('Quantos chifres o Tauros afia por semana?', 3),
  ('Quantas vezes o Gyarados se arrependeu do tempo em que foi Magikarp?', 0),
  ('Quantas bolhas o Vaporeon faz no banho?', 400),
  ('Quantos fios de cabelo arrepiado o Jolteon tem depois de acordar?', 9000),
  ('Quantos cobertores o Flareon usa no inverno?', 0),
  ('Quantas voltas o Omanyte dá na concha antes de dormir?', 12),
  ('Quantos milhões de anos o Kabuto acha que tem?', 300),
  ('Quantas escamas brilhantes o Dratini lustra por dia?', 70),
  ('Quantas folhas o Scyther corta por minuto na poda do jardim?', 800),
  ('Quantas vezes o Pinsir apertou demais um abraço?', 6),
  ('Quantas tomadas o Electabuzz já queimou?', 27),
  ('Quantas pizzas o Magmar assa ao mesmo tempo?', 4),
  ('Quantos golpes de nuvem de fumaça o Weezing solta quando espirra?', 2),
  ('Quantas vezes o Marowak lavou o capacete de osso este ano?', 1),
  ('Quantos lenços a Chansey distribui num dia de choro coletivo?', 35),
  ('Quantos minutos o Psyduck consegue ficar sem pensar em nada?', 1440),
  ('Quantas pessoas o Snorlax já bloqueou dormindo no meio da estrada?', 1500),
  ('Quantas vezes o Snorlax já comeu a comida de outro Pokémon por engano?', 86),
  ('Quantos copos de leite o Snorlax toma antes de dormir?', 9),
  ('Quantos despertadores o Snorlax já destruiu?', 57),
  ('Quantos reais em tampinha de garrafa o Meowth já juntou achando que era moeda?', 340),
  ('Quantas vezes o Pikachu ficou com ciúme de outro Pokémon elétrico?', 12),
  ('Quantos chocolates o Gengar esconde embaixo da cama?', 30),
  ('Quantas vezes o Mr. Mime já levou multa por estacionar um carro imaginário?', 4),
  ('Quantos balões de festa o Jigglypuff já confundiu com primos?', 7),
  ('Quantos passos o Slowpoke dá até a padaria que fica do lado de casa?', 900),
  ('Quantas mensagens o Psyduck deixou sem resposta este mês?', 210),
  ('Quantas cadeiras o Machamp quebrou só de sentar?', 13),
  ('Quantas vezes o Magikarp foi pescado e devolvido por pena?', 47),
  ('Quantas vezes o Ditto já virou um Ditto achando que estava virando outra coisa?', 5),
  ('Quantas palavras o Pikachu sabe falar além de "Pika"?', 2),
  ('Quantos sustos o Snorlax tomou na vida?', 0),
  ('Quantas vezes por dia o Psyduck olha para a parede?', 60),
  ('Quanto o Meowth cobra para contar um segredo da Equipe Rocket, em moedas?', 50),
  ('Quantos minutos dura o banho do Lickitung?', 3),
  ('Quantas vezes a Jynx já foi elogiada pelo batom?', 200),
  ('Quantos quilos de pedra o Onix come no café da manhã?', 12),
  ('Quantos lanches a Kangaskhan guarda para o filhote durante uma viagem?', 25),
  ('Quantos ovos o Exeggcute perde de vista numa caminhada?', 2),
  ('Quantas vezes o Cubone ligou para a mãe hoje?', 8),
  ('Quantos degraus por segundo o Hitmonlee sobe numa escada rolante?', 5),
  ('Quantas notas de cinco o Hypno usa no pêndulo, sendo que usa uma moeda?', 1),
  ('Quantas vezes o Krabby andou de lado para entrar numa porta reta?', 100),
  ('Quantas vezes o Voltorb rolou para dentro da loja errada?', 11),
  ('Quantos minutos o Electrode aguenta numa fila antes de explodir?', 7),
  ('Quantas Poké Bolas o Drowzee já tentou comer achando que eram sonhos?', 3),
  ('Quantas vezes o Tentacruel bloqueou a saída da praia?', 16),
  ('Quantos autógrafos o Starmie dá depois de um show de luzes?', 120),
  ('Quantos quilos o Snorlax engorda numa festa junina?', 14),
  ('Quantas vezes o Slowbro esqueceu que tem um Shellder no rabo?', 365),
  ('Quantas mordidas o Shellder dá no rabo do Slowbro por dia?', 3),
  ('Quantas horas o Slowking passa lendo o jornal?', 9),
  ('Quantas vezes o Psyduck pediu desculpa sem saber pelo quê?', 33),
  ('Quantos minutos o Machoke leva para dobrar um lençol de casal?', 1),
  ('Quantos pneus o Machamp levanta no aquecimento?', 40),
  ('Quantas vezes o Haunter lambeu a tela do celular por engano?', 22),
  ('Quantas portas o Gengar atravessou sem bater este mês?', 180),
  ('Quantas máscaras de dormir o Hypno tem?', 11),
  ('Quantas vezes a Lapras deu carona e não recebeu nem um obrigado?', 58),
  ('Quantas vezes o Eevee foi parado na rua para tirar foto?', 500),
  ('Quantas vezes o Porygon travou no meio de uma batalha?', 4),
  ('Quantas partidas de xadrez o Alakazam venceu contra si mesmo?', 1200),
  ('Quantas colheres o Alakazam já perdeu numa mudança?', 6),
  ('Quantas vezes o Abra dormiu durante uma batalha inteira?', 30),
  ('Quantos minutos o Kadabra leva para achar a colher que está na mão?', 8),
  ('Quantas bolinhas de pelo o Persian solta por dia?', 43),
  ('Quantos pentes o Ponyta queimou tentando arrumar a crina?', 26),
  ('Quantas vezes por semana o Growlithe tenta morder o próprio rabo?', 35),
  ('Quantas vezes o Arcanine foi chamado de "cachorrão" na rua?', 1000),
  ('Quantas vezes o Vulpix pediu para aumentar o aquecedor?', 0),
  ('Quantos cobertores a Ninetales tem só por elegância?', 9),
  ('Quantas vezes o Oddish já foi confundido com uma cebola?', 17),
  ('Quantos copos de suco a Gloom derrubou por causa do cheiro?', 12),
  ('Quantas vezes a Vileplume espirrou pólen na cara de alguém?', 28),
  ('Quantos quilos de terra o Diglett tira por hora?', 40),
  ('Quantas vezes o Dugtrio discutiu qual cabeça é a mais bonita?', 99),
  ('Quantos sanduíches o Snorlax come no café da tarde?', 23),
  ('Quantas vezes o Pidgeotto se perdeu seguindo o GPS?', 7),
  ('Quantas penas o Pidgeot troca por mês?', 300),
  ('Quantos queijos o Raticate estoca para o inverno?', 65),
  ('Quantas vezes o Spearow bicou o retrovisor achando que era um rival?', 40),
  ('Quantos metros o Ekans consegue se esticar de preguiça?', 3),
  ('Quantas vezes a Sandslash ficou presa num tapete por causa dos espinhos?', 15),
  ('Quantas vezes a Nidoqueen ganhou queda de braço contra o Nidoking?', 47),
  ('Quantas vezes por dia a Clefable dança quando ninguém está olhando?', 12),
  ('Quantas músicas o Wigglytuff canta para o filho dormir?', 4),
  ('Quantas vezes o Zubat entrou na casa errada por engano?', 60),
  ('Quantos cogumelos o Parasect vende na feira por semana?', 120),
  ('Quantos insetos o Venomoth deixou entrar pela janela aberta?', 80),
  ('Quantas vezes o Golduck ficou de mau humor por causa de uma onda?', 10),
  ('Quantos remos o Poliwrath já quebrou nadando?', 0),
  ('Quantas vezes a Poliwhirl tentou hipnotizar o espelho?', 30),
  ('Quantos frascos de veneno o Weepinbell já derrubou na cozinha?', 5),
  ('Quantos insetos o Victreebel come de sobremesa?', 9),
  ('Quantas vezes o Tentacool se escondeu num saco de plástico na praia?', 3),
  ('Quantas pedras o Graveler arremessa por diversão num sábado?', 75),
  ('Quantas vezes o Golem rolou até a casa do vizinho sem querer?', 8),
  ('Quantos baldes de água o Ponyta já evaporou só de passar perto?', 21),
  ('Quantos dentes o Seel escovou hoje?', 2),
  ('Quantas vezes o Dewgong cantou desafinado no karaokê da praia?', 19),
  ('Quantas vezes o Grimer entupiu o ralo do banheiro?', 14),
  ('Quantas meias o Muk já perdeu dentro de si mesmo?', 62),
  ('Quantas vezes o Cloyster riu de uma piada sem graça?', 1),
  ('Quantas fotos de fantasma o Gastly estragou?', 44),
  ('Quantos travesseiros o Onix já esmagou tentando dormir de lado?', 7),
  ('Quantas horas o Drowzee dorme mesmo vivendo de comer sonhos?', 1),
  ('Quantas vezes o Krabby tentou bater palmas com as pinças?', 300),
  ('Quantos martelos o Kingler quebrou numa reforma?', 4),
  ('Quantas vezes o Voltorb foi chutado num jogo de futebol?', 9),
  ('Quantos ovos o Exeggutor chocou sem querer ao sentar?', 3),
  ('Quantos ossos o Marowak usou como microfone no karaokê?', 2),
  ('Quantas pessoas o Hitmonchan já ensinou a lutar boxe?', 57),
  ('Quantos sorvetes o Lickitung lambeu de outras pessoas?', 80),
  ('Quantas vezes o Koffing achou que era um balão de aniversário?', 6),
  ('Quantas vezes o Rhyhorn bateu de frente com uma parede e pediu desculpa?', 25),
  ('Quantos cachorros-quentes o Snorlax come numa partida de futebol?', 31),
  ('Quantas horas por dia a Chansey trabalha sem reclamar?', 18),
  ('Quantos fios de cabelo a Tangela perde por dia?', 400),
  ('Quantas vezes a Kangaskhan cobrou aluguel da própria bolsa?', 0),
  ('Quantos cavalos-marinhos o Seadra espantou só com a cara feia?', 12),
  ('Quantos peixinhos dourados o Goldeen convidou para o casamento?', 150),
  ('Quantas vezes o Staryu perdeu uma ponta e teve que esperar crescer?', 4),
  ('Quantas vezes o Mr. Mime aplaudiu o próprio show?', 200),
  ('Quantos insetos o Scyther espantou só olhando feio?', 70),
  ('Quantas fotos a Jynx postou fazendo biquinho?', 500),
  ('Quantos fusíveis o Electabuzz já trocou por culpa própria?', 33),
  ('Quantos ovos fritos o Magmar faz na barriga num café da manhã?', 12),
  ('Quantas vezes o Pinsir quis abraçar alguém e assustou todo mundo?', 18),
  ('Quantas vezes o Tauros furou a fila do bebedouro?', 24),
  ('Quantos pulos o Gyarados dá de raiva quando lembra que já foi Magikarp?', 9),
  ('Quantas músicas a Lapras sabe de cor?', 240),
  ('Quantas vezes o Ditto copiou o crachá de alguém para entrar no trabalho?', 11),
  ('Quantos banhos de espuma o Vaporeon toma por semana?', 7),
  ('Quantos choques o Jolteon dá quando alguém faz carinho do lado errado?', 3),
  ('Quantos marshmallows o Flareon tosta sem precisar de fogueira?', 50),
  ('Quantas vezes o Porygon pediu para reiniciar o mundo?', 2),
  ('Quantos fósseis o Omastar tem guardados na estante?', 19),
  ('Quantas vezes o Kabutops reclamou que o mundo era melhor antigamente?', 1000),
  ('Quantos vasos o Aerodactyl quebrou num museu?', 5),
  ('Quantas vezes o Snorlax rolou da cama e continuou dormindo?', 41),
  ('Quantas vezes o Articuno espirrou neve em pleno verão?', 8),
  ('Quantas vezes o Zapdos derrubou a internet do bairro?', 17),
  ('Quantos churrascos o Moltres foi chamado para acender este ano?', 30),
  ('Quantas escamas o Dragonair lustrou para ir a um casamento?', 200),
  ('Quantos abraços o Dragonite dá por dia?', 50),
  ('Quantas vezes o Mewtwo pensou em fazer terapia?', 12),
  ('Quantas vezes o Mew trocou de esconderijo nesta semana?', 26),
  ('Quantas bolhas de sabão o Squirtle soprou numa tarde?', 600),
  ('Quantas vezes o Wartortle penteou as orelhas peludas?', 15),
  ('Quantos chapéus a Venusaur já usou para cobrir a flor?', 3),
  ('Quantos regadores o Ivysaur esqueceu no jardim?', 8),
  ('Quantas vezes o Charmeleon fingiu que não estava com sono?', 20),
  ('Quantos casulos o Butterfree visitou para dar conselhos?', 11),
  ('Quantas vezes o Beedrill ficou preso numa garrafa de refrigerante?', 2),
  ('Quantos quilômetros o Pidgey voa para buscar pão?', 1),
  ('Quantas vezes o Rattata roeu o cabo do carregador do Pikachu?', 9),
  ('Quantos ovos de Páscoa o Snorlax encontrou antes das crianças?', 40),
  ('Quantas vezes o Psyduck usou o Confusion em si mesmo sem querer?', 77),
  ('Quantos minutos o Slowpoke ficou pescando sem perceber que não tinha isca?', 300),
  ('Quantas vezes o Meowth tentou ensinar outros Pokémon a falar?', 25),
  ('Quantas vezes a Equipe Rocket errou a fantasia de disfarce?', 14)
on conflict (pergunta) do nothing;

create or replace function public.quiz_auto_cfg() returns jsonb
language sql stable security definer set search_path = public, extensions as $$
  select '{"on": true, "dias": [1, 3, 5], "hora_min": 18, "hora_max": 22, "segundos": 20, "prazo_horas": 24,
    "premios": [{"coins": 200}, {"coins": 300}, {"hints": 1, "coins": 100}, {"retries": 2}, {"bag": {"great_ball": 3}}]}'::jsonb
    || coalesce(public.cfg()->'quiz_auto', '{}'::jsonb)
$$;
update public.game_config set config = jsonb_set(config, '{quiz_auto}', public.quiz_auto_cfg()) where active and not (config ? 'quiz_auto');

-- texto do prêmio ("200 moedas", "1 dica e 100 moedas"...)
create or replace function public.quiz_premio_txt(_p jsonb) returns text
language sql stable security definer set search_path = public, extensions as $$
  select coalesce(nullif(concat_ws(' e ',
    case when coalesce((_p->>'coins')::int, 0) > 0 then (_p->>'coins') || ' moedas' end,
    case when coalesce((_p->>'hints')::int, 0) > 0 then (_p->>'hints') || case when (_p->>'hints')::int = 1 then ' dica' else ' dicas' end end,
    case when coalesce((_p->>'retries')::int, 0) > 0 then (_p->>'retries') || ' "tente outra vez"' end,
    (select string_agg(b.value || ' ' || replace(initcap(replace(b.key, '_', ' ')), 'Ball', 'Ball') || case when b.value::int > 1 then 's' else '' end, ' e ')
       from jsonb_each_text(coalesce(_p->'bag', '{}'::jsonb)) b)), ''), 'um prêmio surpresa')
$$;

-- sorteia uma pergunta (as menos usadas primeiro: não repete até todas saírem) e um prêmio
create or replace function public.quiz_sorteio() returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare b quiz_banco; c jsonb := public.quiz_auto_cfg(); pr jsonb;
begin
  select * into b from quiz_banco where ativo order by usos, random() limit 1;
  if b.id is null then return null; end if;
  update quiz_banco set usos = usos + 1, usado_em = now() where id = b.id;
  select x into pr from jsonb_array_elements(coalesce(c->'premios', '[]'::jsonb)) x order by random() limit 1;
  return jsonb_build_object('id', b.id, 'question', b.pergunta, 'answer', b.resposta, 'prize', coalesce(pr, '{}'::jsonb), 'prize_txt', public.quiz_premio_txt(coalesce(pr, '{}'::jsonb)),
    'seconds', coalesce((c->>'segundos')::int, 20));
end $$;

-- abre o quiz automático na hora sorteada do dia (igual para todos)
create or replace function public.quiz_auto_tick() returns void
language plpgsql security definer set search_path = public, extensions as $$
declare c jsonb := public.quiz_auto_cfg(); tz text := coalesce(public.cfg()->>'timezone', 'America/Sao_Paulo'); loc timestamp := now() at time zone tz;
  d date := (now() at time zone tz)::date; h int; mi int; st timestamptz; s jsonb; chk jsonb; pr jsonb;
begin
  if not coalesce((c->>'on')::boolean, true) or public.jogo_pausado() then return; end if;
  -- só no banco de verdade (nos bancos de teste, que não têm sql_aplicados, o quiz automático não abre sozinho)
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
  insert into quizzes(title, intro, prize, question, answer, seconds, closes_at, created_by, prize_coins, prize_hints, prize_retries, prize_bag, prize_items, auto)
  values ('Quiz surpresa!', 'Pergunta absurda do mundo Pokémon! A resposta oficial é segredo: quem chutar mais perto ganha.', s->>'prize_txt',
          s->>'question', (s->>'answer')::numeric, (s->>'seconds')::int, now() + make_interval(hours => coalesce((c->>'prazo_horas')::int, 24)),
          (select user_id from user_roles where role = 'admin' order by user_id limit 1),
          (chk->>'coins')::int, (chk->>'hints')::int, (chk->>'retries')::int, chk->'bag', array(select jsonb_array_elements_text(chk->'items')), true);
end $$;

-- botão "Sortear pergunta" do admin (preenche o formulário; não publica)
create or replace function public.admin_quiz_sortear() returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform public.assert_admin();
  return public.quiz_sorteio();
end $$;

-- banco de perguntas: o admin cadastra, muda, liga/desliga
create or replace function public.admin_quiz_banco_save(_id bigint, _pergunta text, _resposta numeric, _ativo boolean default true) returns public.quiz_banco
language plpgsql security definer set search_path = public, extensions as $$
declare b quiz_banco;
begin
  perform public.assert_admin();
  if char_length(btrim(coalesce(_pergunta, ''))) not between 5 and 300 then raise exception 'Pergunta: de 5 a 300 letras.'; end if;
  if _resposta is null then raise exception 'Informe a resposta oficial (um número).'; end if;
  if _id is null then
    insert into quiz_banco(pergunta, resposta, autor, ativo) values (btrim(_pergunta), _resposta, 'admin', coalesce(_ativo, true)) returning * into b;
  else
    update quiz_banco set pergunta = btrim(_pergunta), resposta = _resposta, ativo = coalesce(_ativo, true) where id = _id returning * into b;
    if b.id is null then raise exception 'Pergunta não encontrada.'; end if;
  end if;
  return b;
exception when unique_violation then raise exception 'Essa pergunta já está no banco.';
end $$;
create or replace function public.admin_quiz_banco_delete(_id bigint) returns void
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform public.assert_admin();
  delete from quiz_banco where id = _id;
end $$;

-- quiz da vez (versão do 38 + quiz automático)
create or replace function public.quiz_current() returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); q quizzes; e quiz_entries; total int; done int; res jsonb; left_s numeric;
begin
  perform public.quiz_auto_tick();   -- arquivo 86: abre o quiz automático na hora marcada
  select * into q from quizzes where status = 'aberto' order by id desc limit 1;
  if q.id is not null then perform public.quiz_tick(q.id); select * into q from quizzes where id = q.id; end if;
  if q.id is null or q.status <> 'aberto' then
    select * into q from quizzes where status = 'encerrado' and closed_at > now() - interval '3 days' order by closed_at desc limit 1;
  end if;
  if q.id is null then return null; end if;
  select * into e from quiz_entries where quiz_id = q.id and user_id = uid;
  select count(*) into total from public.day_active(public.game_today()) a where not public.has_role(a.user_id, 'admin');
  select count(*) into done from quiz_entries x where x.quiz_id = q.id and x.answered_at is not null and not public.has_role(x.user_id, 'admin');
  left_s := case when e.revealed_at is not null and e.answered_at is null
                 then greatest(0, extract(epoch from (e.revealed_at + make_interval(secs => q.seconds) - now()))) end;
  if q.status = 'encerrado' then
    select coalesce(jsonb_agg(jsonb_build_object('user_id', r.user_id, 'name', r.name, 'guess', r.guess, 'diff', r.diff) order by r.diff, r.answered_at), '[]'::jsonb)
      into res
      from (select x.user_id, ch.name, x.guess, abs(x.guess - q.answer) diff, x.answered_at
              from quiz_entries x join characters ch on ch.user_id = x.user_id
             where x.quiz_id = q.id and x.guess is not null) r;
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
    'winner', q.winner, 'results', res);
end $$;

-- Ajustes do jogo (versão do 83 + quiz automático)
create or replace function public.admin_cfg_efetiva() returns jsonb
language plpgsql stable security definer set search_path = public, extensions as $$
begin
  perform public.assert_admin();
  return jsonb_build_object('treino', public.treino_cfg(), 'pk', public.pk_cfg(), 'casas', public.casas_cfg(), 'itens', public.items_cfg(),
    'war', public.war_cfg(), 'rocket', public.rocket_cfg(), 'desafio', public.desafio_cfg(), 'creche', public.creche_cfg(), 'leilao', public.leilao_cfg(), 'herois', public.herois_cfg(), 'temporada', public.temporada_cfg(), 'liga', public.liga_cfg(), 'pausa', public.pausa_cfg(), 'teto', public.teto_cfg(), 'boas_vindas', public.boas_vindas_cfg(), 'vila_bonus', public.vila_bonus_cfg(), 'tm_nivel', public.tm_nivel_cfg(), 'quiz_auto', public.quiz_auto_cfg(), 'base', public.cfg());
end $$;

grant execute on function public.admin_quiz_sortear(), public.admin_quiz_banco_save(bigint, text, numeric, boolean), public.admin_quiz_banco_delete(bigint) to authenticated;
revoke execute on function public.quiz_auto_cfg(), public.quiz_premio_txt(jsonb), public.quiz_sorteio(), public.quiz_auto_tick() from public, anon, authenticated;

-- ---------- novidade no Jornal, publicada sozinha ----------
insert into public.posts(kind, title, body, created_by)
select 'novidade', x.title, x.body, coalesce((select user_id from public.user_roles where role = 'admin' order by user_id limit 1), '00000000-0000-0000-0000-000000000000'::uuid)
  from (values ('❓ Quiz surpresa automático!', 'Agora o Quiz surpresa aparece sozinho, 3 vezes por semana (segunda, quarta e sexta), num horário surpresa entre 18h e 22h.
• As perguntas são absurdas, do mundo Pokémon: "Quantos kg de sushi o Snorlax come em uma hora?", "Quanto o Mr. Mime ganha por dia como mímico no circo?"...
• Cada uma tem uma resposta oficial secreta: quem chutar mais perto ganha.
• O prêmio é sorteado (moedas, dicas, "tente outra vez" ou Great Balls) e cai na sua conta na hora.
Fique de olho no jogo à noite!')) x(title, body)
 where not exists (select 1 from public.posts p where p.title = x.title);
