# RELATORIO — t_f63b3613: por que o bot navega 28x no old.reddit se a regra 4
# manda nao repetir scraping em 403
#
# Data: 2026-09-26. Escopo: CAUSA (o card proibe corrigir).
# Todas as provas rodam DENTRO do container de producao (docker-app-1), com o
# SolidCache, o Chrome e a config reais. Como rodar, esta no fim.

## RESPOSTA CURTA

A regra 4 NAO esta em nenhum ponto do caminho que navega old.reddit.com. Sao
três furos independentes, e qualquer um deles sozinho bastaria:

1. O backoff por sintoma (RateLimitHandler, 6-12h) tem ZERO call sites em
   lib/fetcher — que é onde o canal do Reddit vive.
2. O cooldown por alvo (BotDetection, 6-12h) existe e funciona, mas só é
   lido por PageFetcher#call — que o caminho de canal não usa.
3. O 403 real nunca chega ao código como 403: chega como RenderTimeout, que
   não casa com nenhum padrão de backoff. E o caminho de canal não testa
   status nenhum; olha só o HTML, que nunca chega a ser lido.

## AS TRÊS HIPÓTESES DO CARD, JULGADAS

(a) "o backoff da regra 4 não cobre este caminho" — CONFIRMADA.
(b) "as navegações vêm de jobs diferentes e o backoff é por job" — REFUTADA.
    O balde é por HOST (host_rate_limiter.rb:31-33), não por job.
(c) "o 403 não está sendo classificado como 403" — CONFIRMADA.

## CADEIA CAUSAL, COM ARQUIVO: LINHA

    MCP page_fetch (thread do Reddit)
      -> ExtractService#extract          lib/fetcher/extract_service.rb:146
         (cobra HostRateLimiter por www.reddit.com, teto 2/min)
      -> via_channel -> Reddit.call      lib/fetcher/channels/reddit.rb:185
      -> BrowserSession.with_page        lib/fetcher/browser_session.rb:74
         NAO consulta BotDetection (p1: false)
         NAO chama RateLimitHandler (p1: 0 call sites em lib/fetcher)
         le status so para LOG: browser_session.rb:138
      -> page.go_to                      lib/fetcher/browser_session.rb:131
         Reddit devolve 403 em 0,025s (medido, p2)
         o goto_limit de 15s (browser_session.rb:117) estoura antes
      -> RenderTimeout 35s               lib/fetcher/browser_session.rb:174
         NAO casa com nenhum padrao de backoff
      -> o modelo repete com outro termo -> nova navegacao

## ONDE O BACKOFF DEVERIA AGIR

Em UM unico ponto: BrowserSession.with_page, ANTES do go_to. E ele precisa
de duas coisas que hoje nao existem la:

  - checar o cooldown por alvo (BotDetection.cooldown? host) — o mecanismo ja
    existe (bot_detection.rb:40-59, TTL de 6-12h medido em 9h na p1) e e'
    inerte nesse caminho;
  - classificar o 403 como 403, nao como timeout. O caminho de canal hoje nao
    tem nenhum teste de status (p3).

## MEDIÇÕES (todas em execução, no container de produção)

| # | Medido | Resultado |
|---|--------|-----------|
| M1 | Chamadas reais de Reddit.search + Reddit.call | 6/6 → RenderTimeout(35s). 0 PageFailed. 0 SearchFailed. |
| M2 | Cooldown de old.reddit.com depois das 6 chamadas | nil (regra 4 nunca disparou) |
| M3 | Chamadas de RateLimitHandler em lib/fetcher | 0 |
| M4 | BrowserSession cita BotDetection/check_cooldown! | false (PageFetcher#call sim) |
| M5 | old.reddit.com do IP do container app | HTTP 403 em 0,025s, server=snooserv, x-reddit-ct=v=1,dn=FT,p=GRU,cs=MISS |
| M6 | Corpo do 403 casa com BLOCKED_PAGE_MARKERS do canal | SIM ("whoa there, pardner" e "blocked due to a network policy") |
| M7 | goto_limit de 15s com o Chrome real | body_check = "" (0 chars) → RenderTimeout em browser_session.rb:134 |
| M8 | Balde 2/min do canal, 6 incrementos | estourou na 3a (funciona) |
| M9 | Balde 2/min sob 12 threads | 10/12 estouraram (funciona) |
| M10 | Janela do balde: desliza? | SIM (increment renova TTL) |
| M11 | Log real: status CDP na navegação | vazio em 53 de 65; =200 nas outras 12 (~1,2-2,3s) |
| M12 | Log real: "fetches/min" (RateLimited) em 12h | 0 ocorrências |
| M13 | Log real: 65 navegações old.reddit em ~55 min | média 1,2/min; 10 minutos com 3+ |
| M14 | --proxy-server no Chrome do container | AUSENTE (flags: --user-data-dir, --disable-dev-shm-usage, --disable-features=NetworkService) |
| M15 | IP de saída do container app | 137.131.132.152, AS31898 Oracle, São Paulo |

## TRÊS ACHADOS QUE O CARD NÃO PREVISTE

A1. O FATO 2 do card atribui o 403 ao SCRAPING_PROXY. Não se sustenta: o
    Chrome do container não tem --proxy-server (M14), e ferrum.rb:89 só aplica
    a flag no Chromium que o FERRUM cria — em produção o processo já existe e
    o Ferrum só conecta por CDP. O proxy é lido no ferrum e em 3 jobs
    (twitter/instagram/youtube), nenhum deles no caminho do Reddit. O
    bloqueio é do IP DA VM (datacenter da OCI, M15) — mesma conclusão prática
    do FATO 3 (residencial → 302), mas a causa nomeada está errada.

A2. O balde de 2/min funciona (M8, M9) e mesmo assim nunca disparou em
    produção (M12). Motivo medido: o ritmo real é 1,2/min (M13). E as 16
    page_fetch do minuto T18:45 eram de 13 hosts diferentes — só 2 eram
    reddit. O balde nunca foi pressionado. Ele NÃO é o gargalo.

A3. thread_comments não cobra NENHUM balde (p1: o método tem 4 linhas e
    nenhuma chama HostRateLimiter). O alvo real é UM SÓ (old.reddit.com) e
    o código o conta em três baldes distintos — www.reddit.com (Extract),
    old.reddit.com (busca) e nenhum (thread).

## POR QUE 28 E NÃO MAIS

O ritmo é o do MODELO, não o de um job. Medido no log: 75 chamadas de
platform_search e 154 de page_fetch em 6h, e os 10 minutos com 3+ navegações
de Reddit coincidem com rajadas de tool_call do MCP. Cada tentativa custa 35s
de Chrome, então o modelo só consegue disparar ~1,2/min por thread — e é
exatamente o que o log mostra. O número 28 é consequência da rajada do agente,
não de um retry interno do bot.

## O QUE NÃO FOI FEITO (o card proíbe corrigir)

Nenhuma linha de app/, lib/ ou config/ foi tocada. As 11 provas são novas,
em scripts/proofs/, e não têm efeito em produção. O commit traz só elas.

## COMO RODAR

    cd /home/ubuntu/projects/ClaytOn-Rails
    for p in 1 2 3 4 5 6 7 8 9 10 11; do
      docker cp scripts/proofs/reddit_403_gap_p$p.rb docker-app-1:/tmp/p$p.rb
      docker exec -w /rails docker-app-1 bin/rails runner /tmp/p$p.rb
    done
    docker cp scripts/proofs/reddit_403_backoff_gap_proof.rb docker-app-1:/tmp/proof.rb
    docker exec -w /rails docker-app-1 bin/rails runner /tmp/proof.rb

Custo: p1 ~5s, p2 ~10s, p3 ~40s, p4 ~20s, p5 ~40s, p6 ~215s, p7 ~145s,
p8 ~150s, p9 ~5s, p10 ~5s, p11 ~10s.

## LIMITE DESTA MEDIÇÃO (honesto)

- As 6 chamadas reais (M1) são o que a PRODUÇÃO faz, com o MESMO Chrome, o
  MESMO proxy e o MESMO teto. Elas produziram RenderTimeout 6/6. Uma
  execução anterior da p5 chegou ao yield (comportamento instável perto do
  limite de 15s) — por isso a M1 é a medição que vale, com repetição.
- O cooldown foi testado com uma escrita manual (p1 passo 5) e depois apagado
  com clear!. Nenhum cooldown de produção foi tocado.
- Nenhuma correção foi aplicada, por instrução do card. As-names das três
  linhas de conserto possíveis estão no Relatório, para o card de correção.
