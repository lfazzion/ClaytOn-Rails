# RELATORIO — card t_324ad4fd: a regra 4 no caminho que navega
#
# Data: 2026-09-26. Escopo: CONSERTO (o card t_f63b3613 mediu a causa; este
# fecha). Causa e medicoes originais em RELATORIO-reddit-403-backoff.md.
#
# Todas as provas rodam DENTRO do container de producao (docker-app-1), com o
# SolidCache, o jar e o IP reais. Como rodar, esta no fim.

## RESPOSTA CURTA

Os dois lados do conserto funcionam, e a prova que o card pedia esta no
`reddit_403_fix_proof.rb`: a segunda tentativa no mesmo alvo e barrada ANTES do
`go_to`, com **zero paginas criadas**.

1. **Cooldown por alvo (a)**: `BrowserSession.with_page` consulta
   `BotDetection.cooldown_for(host)` antes de gastar browser, e levanta
   `TargetInCooldown`.
2. **403 como 403 (b)**: o status do DOCUMENTO sai do mesmo evento CDP que o
   `RebindingGuard` ja usava, e 403/429 viram `TargetBlocked` + cooldown de
   6-12h, no go_to — sem esperar o teto de 35s.

## A MEDICAO QUE NAO ESTAVA NO CARD: O 403 E DO CAMINHO ANONIMO

O card mediu 403 contra `old.reddit.com` com o Chrome do container. Medindo de
novo, com o MESMO container e o MESMO IP, o alvo responde **duas coisas
diferentes** conforme a sessao:

| Cenario | Status | Duracao | Leitura |
|---------|--------|---------|---------|
| SEM sessao (`SessionCookies.for` -> `[]`) | **403** | 0,053s | `TargetBlocked`, cooldown gravado |
| COM a sessao do jar (8 cookies) | **200** | 1,42s | thread lida: 51 comentarios, 15.029 chars |

Ou seja: o bloqueio do card nao e do IP da VM. E do caminho **anonimo**. Isso
corrige o FATO 1 do card ("o bloqueio e do IP") para o caso anonimo — e explica
por que o `with_page` legado levantava `CookieJar::Expired` antes de navegar
quando nao havia sessao: a casa ja recusava o caminho anonimo, mas nao no
`Reddit.search`, que passa pelo mesmo `with_page`.

O conserto e ortogonal a isso: o bloqueio por alvo vale para os dois cenarios, e
o caminho com sessao continua lendo (medido, cenario B).

## ONDE A FONTE DO STATUS MUDOU (e por que a antiga nao servia)

`browser_session.rb` lia `page.network.response&.status` SO PARA LOG. Esse e o
ULTIMO exchange da sessao CDP, nao o do documento: saiu vazio em 53 de 65
navegacoes (M11) e segue vazio no log vivo (`status=` vazio em todas as de
15,0s, reconferido em `docker logs docker-app-1`).

A fonte nova e `DocumentStatus.capture` (`lib/fetcher/document_status.rb`):
assina `Network.responseReceived`, filtra `type == "Document"` e le
`response.status` — mesma assinatura do `RebindingGuard`.

**Medido antes de depender dela** (o evento nao chegar tornaria o conserto
(b) inerte de novo):

| Prova | Onde | Resultado |
|-------|------|-----------|
| p1 | Chrome de PRODUCAO (24h) | 0 eventos `responseReceived`; `network.response` = nil |
| p2 | Chrome de PRODUCAO, com `Network.enable` explicito | 0 eventos, ate em example.com |
| p3 | Chrome de PRODUCAO, cru vs isolado | ambos sem evento; body do isolado VAZIO em 20s |
| p4 | Chrome NOVO (mesmo container, mesmo IP) | **evento chega: `status=403` em 0,117s**; isolado funciona |

A p3 isolou a diferenca: o Chrome de producao estava com a **sessao
envenenada** (o episodio ja documentado no compose: "CDP respondia e NENHUMA
requisicao completava"). Nao era o codigo. Em Chrome novo o caminho isolado — o
mesmo do `BrowserSession` — le o status sem difficulty.

Por isso `DocumentStatus` devolve `nil` quando o evento nao chega, em vez de
inventar status: a classificacao e fail-open, e quem decide o que fazer com o
timeout e o `goto_estourou` de sempre.

## A PROVA QUE O CARD PEDE

`scripts/proofs/reddit_403_fix_proof.rb`, cenario C — a segunda tentativa no
mesmo alvo, por OUTRO chamador:

    A) 1a chamada (sem sessao): TargetBlocked, cooldown TTL 10,66h
    C) Reddit.search no MESMO alvo: TargetInCooldown
       duracao=0,007s   paginas criadas=0
       "volte em 10h39m; nao repita a leitura antes disso"
    C2) ExtractService: error="alvo old.reddit.com esta em cooldown
        de bloqueio (HTTP 403) — volte em 11h54m", content=0 chars

`paginas criadas=0` e a prova: a barreira e ANTES do `go_to`, nao depois dele.
E o C2 mostra o que o MCP recebe — erro nomeado, nao "tempo de render excedeu
35s", que era o convite para repetir.

## DECISOES QUE MUDARAM O COMPORTAMENTO

- **As duas excecoes herdam de `Channels::Error`**, nao de `FetchError` nem de
  `StandardError`. Quem entra por `with_page` e um CANAL, e o
  `ExtractService`/`PlatformSearchTool` ja convertem `Channels::Error` em campo
  de erro limpo. Um erro novo fora dessa raiz subiria como "falha inesperada" —
  de novo um convite a repetir.
- **O bloqueio e levantado ANTES do `RenderTimeout`** quando os dois ocorrem. O
  403 e um FATO do servidor; o timeout e a falha de quem esperou. Com as duas
  coisas presentes, o bloqueio e a informacao — e e o que o modelo precisa ler.
- **O cooldown e gravado E levantado juntos.** Gravar sem levantar devolve um
  `PageFailed` que o modelo le como "pagina ruim" e tenta com outro termo;
  levantar sem gravar e o defeito medido (65 navegacoes).
- **A chave e o host que o Chrome ABRE** (`old.reddit.com`), nao o canonico
  (`www.reddit.com`). Gravar e ler pela mesma chave e o que faz a segunda
  tentativa respeitar o backoff.
- **Ordem deliberada**: `SsrfGuard` -> `check_cooldown!` -> `SessionCookies.for`
  -> browser. O cooldown vem antes da leitura de sessao porque essa leitura
  gasta CDP.

## TESTES (TDD, no nivel do chamador)

`test/lib/fetcher/reddit_target_backoff_test.rb`, 10 casos, no nivel de quem
CHAMA (o canal `Reddit.call`/`Reddit.search` e o `ExtractService`) — nao na
camada de mapeamento, pela licao do #205.

- RED: 10 runs, **8 vermelhos** (6 `NameError` das classes novas, 2 falhas de
  asercao). Saida crua no log do card.
- GREEN: 10 runs, 56 assertions, 0 failures, 0 errors.
- Dois CONTROLES no arquivo, e eles valem tanto quanto os positivos: `200` nao
  arma cooldown e a thread e lida; `status` ausente nao vira bloqueio (fail-open).

## RISCOS E LIMITES (honestos)

- **O conserto nao conserta o Chrome envenenado.** A p3 mediu que o container de
  producao estava com a sessao envenenada de 24h — nenhuma requisicao completava.
  Isso e ORTODO, e e de um card proprio. A prova rodou num Chrome novo pelo
  mesmo motivo.
- **Um alvo anonimo que responde 403 passa a ficar 6-12h sem leitura.** E o que
  a regra 4 manda, mas e uma mudanca de comportamento: enquanto o cooldown
  estiver valendo, a busca do Reddit devolve o erro nomeado em vez de lista
  vazia. O que e preferivel a lista vazia (o modelo leria "nao existe nada
  sobre isso").
- **O `goto_estourou` continua levantando `RenderTimeout`** quando o status nao
  veio. O desfecho nao melhorou nesse caminho: e a medicao de que o evento nao
  chegou, e a p3 mostra que isso acontece quando a sessao esta envenenada.
- **A faixa de 6-12h vem do `rand` do `BotDetection`**, que ja existia. Nao ha
  teste que prove a distribuicao; ha teste que prova que o TTL fica dentro da
  faixa (6h-12h), que e o contrato.
- **Prova em container de producao, nao em CI.** As 4 provas de codigo sobem com
  o PR mas nao rodam no CI: precisam de Chrome com CDP e de rede externa.

## COMO RODAR

    # suites
    docker compose -f docker/docker-compose.yml run --rm test test test/lib/fetcher/reddit_target_backoff_test.rb

    # medicao do status (Chrome de producao — mostra a sessao envenenada)
    docker cp scripts/proofs/reddit_403_status_source.rb docker-app-1:/tmp/st.rb
    docker exec -w /rails docker-app-1 bin/rails runner /tmp/st.rb

    # par de controle: Chrome NOVO mostra o evento chegando
    docker run -d --name chrome-p4 --network docker_browser \
      chromedp/headless-shell:147.0.7727.102 --user-data-dir=/data \
      --disable-dev-shm-usage --disable-features=NetworkService
    docker cp scripts/proofs/reddit_403_status_source_p4.rb docker-app-1:/tmp/st4.rb
    docker exec -w /rails -e CHROME_P4_HOST=chrome-p4 docker-app-1 bin/rails runner /tmp/st4.rb

    # a prova do conserto (a que o card pede)
    docker cp scripts/proofs/reddit_403_fix_proof.rb docker-app-1:/tmp/fix.rb
    docker exec -w /rails -e CHROME_P4_HOST=chrome-p4 docker-app-1 bin/rails runner /tmp/fix.rb

Custo: fix_proof ~12s, status_source ~5s, p4 ~5s, p2 ~60s, p3 ~45s.
