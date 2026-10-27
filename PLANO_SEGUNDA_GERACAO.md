# Plano simples: Segunda geração (Pokémon 152 a 251)

Escrito em 21/10/2026 a pedido do dono. **Etapas 1 a 4 prontas e testadas** (`sql/27_dados_gen2.sql`, `sql/28_liberar_gen2.sql` e o site).

**Regra principal:** tudo continua com as **regras da 1ª geração**. A 2ª geração só acrescenta Pokémon, ataques e dois tipos. Os Pokémon que os jogadores já têm não mudam.

## 1. O botão "Liberar 2ª geração" (liga e desliga)

- Na aba **Administração** aparece um interruptor: **"2ª geração: ligada / desligada"**.
- Ele grava `gen2: true/false` no `game_config`. Não baixa nada: os dados entram antes, por SQL, e ficam escondidos.
- O efeito começa no **dia seguinte**. O desafio do dia que já foi sorteado não muda no meio do dia, para não bagunçar o ranking.

| | Ligada | Desligada |
|---|---|---|
| Desafios do dia | sorteia entre os 251 | só os 151 |
| Encontros depois de andar | aparecem os 251 | só os 151 |
| Pokémon da 2ª geração já capturados | normais | **continuam na coleção, com nível e XP, e podem batalhar** (ninguém perde nada) |
| Evoluções da 2ª geração (Golbat → Crobat, Onix → Steelix…) | liberadas | bloqueadas (o Pokémon espera, nada se perde) |
| Pokédex | mostra 251 | mostra 151 (+ os da 2ª que a pessoa já tem) |
| Palpites no desafio | aceita os 251 | aceita só os 151 |

## 2. Dados (sem inventar nada)

- **Números** (atributos, taxa de captura, experiência, ataques por nível, evoluções): tirados do projeto pret/pokecrystal, o mesmo tipo de fonte do 16. Só números e nomes.
- **Imagens**: PokeAPI, como hoje.
- **Desafios**: tipo, habitat, cor, fase, altura e peso dos 100 novos, no mesmo formato dos 151.
- **Descrições**: 100 descrições **originais em português**, escritas do zero como as do arquivo 05.

## 3. Como a 2ª geração cabe nas regras da 1ª

- **Atributo Especial:** na 2ª geração ele se divide em dois (ataque e defesa especial). Aqui vira **um só, a média dos dois**, como na 1ª geração.
- **Tipos novos:**
  - Sombrio e Metálico entram na tabela de tipos com as vantagens da 2ª geração.
  - Os confrontos antigos entre os 15 tipos ficam exatamente como hoje.
  - Sombrio conta como golpe especial e Metálico como físico, como na 2ª geração.
- **Ataques novos (cerca de 86):**
  - os que têm efeito parecido com um da 1ª geração usam esse efeito (dano, veneno, sono, abaixar atributo, drenar vida…);
  - os que dependem de coisas que não existem aqui (clima, itens equipados, Protect, Spikes) entram avisando "ainda não funciona", como já acontece com Transform e Counter;
  - depois dá para ligar alguns aos poucos.
- **Evoluções que não existem na 1ª geração** viram regras simples. A lista abaixo é uma sugestão, ajustável:

| Na 2ª geração | Aqui |
|---|---|
| Por amizade (Pichu, Cleffa, Igglybuff, Togepi, Golbat → Crobat, Chansey → Blissey) | por nível (por exemplo, Pichu no 15, Crobat no 38, Blissey no 40) |
| Por hora do dia (Eevee → Espeon / Umbreon) | 2 pedras novas na loja: Pedra do Sol e Pedra da Lua Nova |
| Por troca com item (Onix → Steelix, Scyther → Scizor, Seadra → Kingdra, Slowpoke → Slowking, Poliwhirl → Politoed, Porygon → Porygon2) | por nível (por exemplo, 40) ou pela Pedra Metálica / Pedra do Rei (novas na loja, 250 moedas como as outras) |
| Tyrogue (depende de atributos) | escolha do jogador na hora de evoluir |

- **Bebês e formas iniciais:** os encontros continuam dando sempre a forma inicial da linha. Com a 2ª ligada, a linha do Pikachu passa a aparecer como Pichu.
- **Lendários** (Raikou, Entei, Suicune, Lugia, Ho-Oh e Celebi): **não aparecem** nos encontros, como os da 1ª geração. Podem virar o **Lendário do mapa**, se você quiser.

## 4. Etapas (cada uma testada antes da próxima)

1. **`sql/27_dados_gen2.sql`:** os 100 Pokémon, imagens, descrições, ataques, ataques por nível, evoluções e os dois tipos novos. Tudo marcado como 2ª geração e escondido. Rodar não muda nada no jogo.
2. **`sql/28_liberar_gen2.sql`:** o interruptor (`admin_set_gen2`) e as funções que passam a respeitar o liga/desliga:
   - sorteio do desafio;
   - palpites;
   - encontros;
   - evoluções;
   - loja de pedras.
3. **Site:**
   - o interruptor no admin;
   - lista de palpites com os 251;
   - Pokédex com 251;
   - cores dos tipos Sombrio e Metálico;
   - pedras novas na loja.
4. **Testes:**
   - liga e desliga várias vezes sem quebrar nada;
   - desafios e capturas respeitando o interruptor;
   - 300 batalhas sorteadas com Pokémon das duas gerações;
   - a regra contra spoiler continua valendo.

## 5. Decisões que ficam com o dono

- As evoluções da tabela acima: por nível, por pedra ou por outro jeito.
- Se os lendários da 2ª geração podem virar o Lendário do mapa.
- Quando ligar: avise no Jornal (agora dá para pôr imagem 😉).
