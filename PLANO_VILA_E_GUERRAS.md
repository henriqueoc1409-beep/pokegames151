# Plano: Vila expandida e Guerras Pokémon entre vilas

Escrito em 21/10/2026. **Aprovado pelo dono e implementado** em `sql/25_vila_guerras.sql` e no `index.html` (guerra opcional, cura paga ou grátis em 24 h, XP dentro do limite diário). Ajustes feitos durante os testes: o escudo ficou em 24 horas (igual à cura grátis), e quando há poucos alvos de força parecida a lista só completa com vilas **mais fortes**, nunca com muito mais fracas.

## 1. O que existe hoje (inventário real)

Tudo fica na tabela `villages` (uma linha por jogador). A Mina tem uma coluna de nível que vai de 0 a 3. As outras construções têm só nível 0 ou 1: construir é tudo ou nada. Os preços e efeitos ficam em `game_config` (aba Regras), arquivos 09 e 11.

| # | Construção | Níveis | Custo | Efeito real | Nível do herói |
|---|---|---|---|---|---|
| 1 | Mina de Ouro | 3 | 300 / 600 / 1.200 | 20 / 40 / 70 moedas por dia (junta até 7 dias) | 1 |
| 2 | Torre de Pesquisa | 1 | 400 | 1 dica a cada 3 dias (até 3) | 1 |
| 3 | Pomar | 1 | 350 | 25 XP do herói por dia | 1 |
| 4 | Oficina do Ferreiro | 1 | 450 | 1 "tente outra vez" a cada 5 dias (até 2) | 1 |
| 5 | Estábulo | 1 | 600 | 1 casa de bônus a cada 4 dias (até 2) | 8 |
| 6 | Taverna | 1 | 700 | +15% no Dia de pagamento | 1 |
| 7 | Arena | 1 | 650 | +10% de chance nos duelos de encontro no mapa | 6 |
| 8 | Poço dos Desejos | 1 | 800 | 1 giro extra da roleta a cada 7 dias | 10 |
| 9 | Catapulta de Lama | 1 | 500 | A cada 7 dias: o alvo perde 2 casas e fica com a vila enlameada | 1 |
| 10 | Muralha | 1 | 500 | Segura 1 catapulta a cada 7 dias | 1 |

Outras coisas que já ficam na vila:
- **Lama** (nível 0 a 3): trava a coleta até limpar, a 50 moedas por nível. Vem da catapulta ou de ser o último da rodada.
- **Estátuas de ouro**: uma por rodada vencida.
- **Castelos**: um por temporada vencida.

Todas as funções validam no servidor: `village_build`, `village_collect`, `village_clean` e `catapult_fire`.

A vila inteira custa hoje **7.050 moedas**. Um jogador médio ganha entre 100 e 180 moedas por dia, então leva de 1 mês e meio a 2 meses para completar.

**Pokémon e batalhas, que a guerra vai aproveitar:**
- Os Pokémon ficam em `monsters`.
- A equipe de 6 fica em `team_slot`.
- O motor de batalha da 1ª geração está no servidor: `bt_use_move`, `bt_resolve` e as funções ligadas a eles.
- Hoje toda batalha é entre duas pessoas jogando turno a turno. Não existe batalha automática nem guerra entre vilas.

## 2. Construções propostas (18 no total)

### Ficam como estão (10)
Mina, Torre de Pesquisa, Pomar, Estábulo, Taverna, Poço, Arena e Catapulta continuam iguais. Não ganham níveis novos de produção, para **não inflacionar as moedas**.

Muralha e Ferreiro ganham níveis novos, ligados à guerra (veja abaixo).

### Novas (8)
| Construção | Função | Por que é nova |
|---|---|---|
| Centro da Vila | Define o nível da vila e o nível máximo das outras construções | Hoje não existe "nível da vila" |
| Cofre | Protege moedas do saque | Nada protege moedas hoje |
| Quartel Pokémon | Libera a guerra e define quantos ataques por dia | Não existem esquadrões |
| Torre de Defesa | Os 3 defensores lutam um pouco mais fortes | Defesa da guerra |
| Oficina de Armadilhas | O 1º Pokémon atacante entra com menos vida | Outra escolha de defesa, que soma com a Torre até um limite |
| Torre de Vigia | Mostra informações do alvo antes de atacar | Informação é uma decisão nova |
| Centro Pokémon de Guerra | Barateia a recuperação depois das guerras | Recuperação é um custo novo |
| Academia de Treinadores | Libera táticas para o combate automático | Estratégia sem ficar invencível |

### Ideias que não entram, por serem repetidas
- **Mercado da Vila e Posto Comercial**: já existe o Mercado entre jogadores.
- **Depósito e segunda moeda**: complica e não traz decisão nova.
- **Fazenda**: a Mina e o Pomar já produzem.
- **Alojamento**: seria igual ao Quartel.
- **Dojo e Laboratório**: juntei na Academia.
- **Enfermaria**: seria igual ao Centro Pokémon.
- **Monumento**: as estátuas e castelos já fazem esse papel.
- **Centro de Missões**: fica para depois, porque precisa de um sistema de missões que ainda não existe.

## 3. Níveis, custos e benefícios

Preços em moedas. "CV" quer dizer nível do Centro da Vila exigido.

| Construção | Nv1 | Nv2 | Nv3 | Nv4 | Nv5/6 |
|---|---|---|---|---|---|
| **Centro da Vila** (máx. 6) | grátis | 600 | 1.400 | 2.800 | 4.500 / 6.500 |
| **Cofre** (protege) | 400 (CV1): 300 moedas | 900 (CV2): 600 | 1.800 (CV3): 1.000 | 3.000 (CV5): 1.500 | |
| **Quartel** (ataques/dia) | 600 (CV1): 1 | 1.600 (CV3): 2 | 3.200 (CV5): 3 | | |
| **Torre de Defesa** (vida e defesa dos defensores) | 700 (CV2): +5% | 1.500 (CV3): +10% | 2.800 (CV5): +15% | | |
| **Oficina de Armadilhas** (vida a menos do 1º atacante) | 600 (CV2): −5% | 1.300 (CV4): −10% | | | |
| **Torre de Vigia** (o que você vê do alvo) | 400 (CV1): espécies | 1.000 (CV2): níveis e vida atual | 2.000 (CV4): ataques e chance estimada | | |
| **Centro Pokémon** (desconto na cura) | 500 (CV1): −10% | 1.200 (CV2): −20% | 2.500 (CV4): −30% | 4.000 (CV6): −40% (máximo) | |
| **Academia** (táticas) | 800 (CV2): tática do ataque | 1.800 (CV4): tática da defesa | 3.500 (CV6): troca inteligente por tipo | | |
| **Muralha** (já existe) | 500: segura catapulta | 900 (CV2): −15% de dano às construções | 1.600 (CV4): −30% | | |
| **Ferreiro** (já existe) | 450: tente outra vez | 1.000 (CV2): −15% no reparo | 2.200 (CV4): −30% | | |

**Limites de segurança**, para nenhuma vila ficar invencível:
- O bônus total de defesa (Torre de Defesa + Armadilhas) não passa de **20%**.
- O Cofre protege no máximo **1.500** moedas.

**Centro da Vila para quem já tem vila:**
- Ninguém perde nada.
- Cada vila começa no nível que corresponde ao que já construiu: até 3 construções = nível 1; 4 a 6 = 2; 7 a 9 = 3; as 10 = 4.

**Custo total do conteúdo novo:** cerca de 50 mil moedas. É progressão para vários meses, e as moedas passam a circular também por cura e reparo.

## 4. Guerras entre vilas

### Esquadrões (Quartel)
- 3 Pokémon fixos para atacar e 3 para defender, separados da equipe de 6 das batalhas normais.
- O mesmo Pokémon não pode ficar nos dois esquadrões.
- A defesa luta sozinha, mesmo com o dono fora do jogo.
- **A guerra é opcional:** só ataca e só é atacado quem construiu o Quartel e montou os dois esquadrões.

### Combate automático
- Usa o mesmo motor de batalha da 1ª geração, sem mudar dano, tipos ou regras.
- O servidor escolhe os ataques. Por padrão, usa o golpe que mais causa dano. A Academia libera outras táticas, como a "segura", que prefere golpes certeiros e de estado.
- A luta inteira é resolvida de uma vez no servidor. Não dá para processar duas vezes nem trapacear pelo navegador.
- Se passar de 60 turnos, vence quem tiver mais vida em porcentagem.
- O relatório completo (turnos, dano, vida, quem desmaiou, saque e danos) fica guardado para os dois lados verem.

### Pareamento justo e proteções
- **Poder** de cada jogador = soma da força dos 3 Pokémon do esquadrão (nível e atributos) + bônus da vila.
- Você só pode atacar quem tem entre **75% e 135% do seu poder**. Se houver menos de 3 opções, entram as vilas mais fortes mais próximas (nunca vilas muito mais fracas).
- Só pode ser atacado quem jogou nos últimos 7 dias. Isso protege quem viajou ou parou de jogar.
- Personagem criado há menos de 3 dias não ataca nem é atacado.
- Quem é atacado ganha um **escudo de 24 horas**.
- O mesmo atacante só ataca o mesmo alvo **1 vez a cada 3 dias**.
- Cada jogador é atacado no máximo 2 vezes por dia.

### Saque e danos (quando o atacante vence)
- **Saque**: 10% das moedas acima da parte protegida, com máximo de 150 por ataque.
- Parte protegida = 100 moedas (todos têm) + o que o Cofre protege.
- As moedas saem do perdedor e vão para o vencedor. Nenhuma moeda é criada do nada, e ninguém fica com saldo negativo.
- **Danos**: 1 construção do perdedor fica danificada; 2 se ele perder sem derrubar nenhum atacante. A Muralha reduz a chance.
- Construção danificada para de funcionar até ser consertada. O conserto custa 20% do preço dela (desconto do Ferreiro).
- Para ninguém ficar travado sem dinheiro, ela se conserta **de graça depois de 3 dias**.
- Nunca são danificados: Centro da Vila, Cofre e Quartel.
- Nada é apagado para sempre: nem construções, nem Pokémon, nem níveis.

### Recuperação (Centro Pokémon de Guerra)
- Depois de toda guerra, os Pokémon dos dois lados ficam com a "vida de guerra" que sobrou, ganhando ou perdendo.
- Pokémon desmaiado não entra na próxima guerra. Defensor ferido defende mais fraco.
- **Cura paga**: cerca de 1,5 moeda × nível × porcentagem de vida perdida. Um Pokémon nível 30 desmaiado custa cerca de 45 moedas. O Centro Pokémon dá até 40% de desconto.
- A guerra **não tira** nível nem XP do RPG normal.

## 5. Telas

- **Minha Vila**, com abas por categoria:
  - Economia: Mina, Pomar, Taverna, Poço, Estábulo, Torre de Pesquisa.
  - Defesa: Muralha, Cofre, Torre de Defesa, Armadilhas.
  - Pokémon e guerra: Quartel, Centro Pokémon, Torre de Vigia, Academia, Arena, Catapulta.
  - Desenvolvimento: Centro da Vila, Ferreiro.
- Cada cartão mostra: nível, função, custo e benefício do próximo nível, requisitos (se bloqueada) e custo do conserto (se danificada).
- **Guerras Pokémon** (janela nova):
  - montar os esquadrões;
  - lista de alvos com o poder de cada um e o que a Torre de Vigia mostra;
  - botão Atacar;
  - relatório animado da luta, histórico de ataques feitos e sofridos;
  - curar os Pokémon.
- Aviso ao entrar: "Sua vila foi atacada por Fulano: perdeu 80 moedas, Mina danificada", com botões para ver o relatório e consertar.
- As guerras aparecem também no Jornal e na Arena (encerradas).

## 6. Etapas e testes

Tudo num arquivo novo `sql/25_vila_guerras.sql`. Nenhum arquivo antigo é editado, e nenhum dado é apagado.

1. **Esquadrões e combate automático.** Teste: 200 guerras sorteadas sem erro, sem processar duas vezes, sem usar o mesmo Pokémon nos dois esquadrões.
2. **Saque, danos e conserto.** Teste: saque respeita o Cofre e o máximo, ninguém fica negativo, conserto grátis depois de 3 dias.
3. **Recuperação.** Teste: os dois lados ficam feridos, a cura cobra certo, o nível e o XP não mudam.
4. **Construções novas e níveis.** Teste: requisitos do Centro da Vila, custos e limites validados no servidor, vilas antigas preservadas.
5. **Balanceamento.** Simulação com 30 jogadores de níveis diferentes por 60 dias: ver quanto cada um ganha e perde, se alguém fica invencível e se dá para tirar vantagem com conta falsa.

Cada etapa é testada como jogador comum (não admin) antes de passar para a próxima. Nada é publicado no Netlify nem rodado no Supabase por mim.
