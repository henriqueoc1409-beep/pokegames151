# Como colaborar com o Pokegames

Obrigado por ajudar! O jogo é do Karneiro (o dono). Você propõe mudanças e ele aprova. Depois que ele aprova, o jogo se atualiza sozinho: o banco (Supabase) e o site (Cloudflare Pages).

## Do que você precisa

- Uma conta no GitHub e acesso a este repositório (peça ao Karneiro).
- O Claude Code no seu computador.
- Você **não** precisa de acesso ao Supabase nem ao Cloudflare. Os segredos ficam guardados no GitHub, e só o robô de publicação usa.

## O caminho de uma mudança

1. **Faça a sua cópia do projeto (fork):** no GitHub, clique em **Fork** neste repositório. Depois baixe a sua cópia para o computador (`git clone`).
2. **Abra o Claude Code na pasta do projeto** e peça o que você quer. Por exemplo: "crie um evento de Halloween com casas abóbora". O Claude lê o `CLAUDE.md`, que tem todas as regras do jogo, e segue o mesmo jeito de trabalhar.
3. **O Claude faz tudo dentro das regras:**
   - um arquivo SQL novo em `sql/` (com o próximo número; nunca mexe nos antigos);
   - as mudanças no site, em `deploy/index.html`;
   - os testes (em `ferramentas/`), rodados como jogador comum;
   - o aviso pronto para o Jornal (lista `NOVIDADES`) e a explicação na Biblioteca.
4. **Peça ao Claude para abrir um pull request** (uma proposta de mudança) para o repositório do Karneiro, explicando o que muda para os jogadores.
5. **Os testes rodam sozinhos no GitHub.** Se algum ficar vermelho, peça ao seu Claude para corrigir.
6. **O Karneiro revisa e aprova.** Só então o robô roda o SQL novo no banco, com cópia de segurança antes, e publica o site.

## Regras que valem para todo mundo

- Nada de editar SQL que já rodou: sempre um arquivo novo, com o próximo número.
- Nunca coloque senha, chave secreta (service_role) ou endereço do banco no código. A única chave no site é a pública ("anon"), e o robô barra a publicação se aparecer outra.
- Um SQL que só o dono deve rodar à mão (por exemplo, zerar o jogo) começa com a linha `-- MANUAL`. O robô nunca roda esse arquivo.
- Não mude pontos, XP, moedas ou recompensas sem o Karneiro pedir.
- Nada de pessoas reais, Pokémon desenhados à mão ou escudos de clubes nas artes.
- Explique tudo em português simples: o Karneiro não é programador.
