# Cleitin Bot — Sistema de Data Mining para Influencers

Este projeto é um sistema completo de coleta de dados, análise de influencers e chatbot com integração ao Discord, construído utilizando Ruby 4.0 e Ruby on Rails 8.1 em modo headless.

A motivação inicial é simples: Acompanhar métricas de vários perfis (próprios e de concorrentes) sem perder horas fazendo isso manualmente. O que começou como um script simples evoluiu para um sistema robusto (implementado rigorosamente em 6 Fases) com dezenas de jobs agendados, scraping automatizado com Chrome headless/Python e um bot de Discord autônomo atuando como Cérebro e Interface.

## Arquitetura do Sistema

O projeto segue uma arquitetura modular onde cada responsabilidade está bem isolada. O backend utiliza Rails 8.1 em modo headless (sem ActionView/Sprockets), servindo puramente como API e maestro de enfileiramento. 

Para o banco de dados, utilizo SQLite3 em modo WAL (Write-Ahead Logging). O modo WAL permite leituras e escritas concorrentes massivas. Tudo é hospedado localmente no host dentro de containers com persistência mapeada.

A fila de processamento utiliza **Solid Queue**, e o cache utiliza **Solid Cache** (ambos armazenados no SQLite). Esta combinação unificada elimina o overhead e a manutenção de infraestruturas externas como Redis ou Sidekiq.

### Stack Tecnológico

| Componente | Tecnologia |
|------------|------------|
| Framework | Ruby 4.0 + Rails 8.1 (headless API-only) |
| Banco de Dados | SQLite3 (modo WAL) com backups live nativos |
| Fila e Cache | Solid Queue + Solid Cache |
| Interface (Bot)| discordrb (processo docker stanalone isolado) |
| Scraping | Ferrum + Chrome headless + Python (Nodriver/Camoufox) |
| IA e Agentes | RubyLLM + Gemini 3.1 Flash / Imagen 3 / OpenRouter |
| Infraestrutura | docker-compose multi-container (`app`, `jobs`, `bot`, etc) |
| Bateria de Testes| Minitest (~400 testes unitários/integrados selados) |

## Técnicas de Web Scraping

Um dos maiores desafios do projeto é coletar dados de redes fechadas com muros de login ou de sites altamente dinâmicos. Lidamos de forma proativa com os 4 obstáculos centrais em 2026:

1. **Client-Side Rendering (SPAs):** Resolvidos com sessões manipuladas em Chromium Headless.
2. **Defesas Bot:** Delays randômicos, injeções via CDP page scripts e spoofs.
3. **Escudo WAF/CDP:** Bypass de Headers clássico (alterando Host de WebSocket connections) e stealth requests.
4. **Dom quebra-galho:** Seletores estáticos tendem a morrer; a coleta ocorre baseada na estrutura dom ou via Fallback Gracioso, aceitando `og:tags` primários e limitando qualidade, sem crash.

### Stack de Scraping Multi-linguagem

O Ferrum (`Ruby`) conversando com o Chrome headless é nossa linha de frente. No entanto, para portais endurecidos, alocamos os workers que engatilham o `python-scraper` sidecar que explora ferramentas avançadas criadas em Python como Nodriver e Camoufox, gerando fingerprints quase indistinguíveis de Safari em iOS.

## Design de Dados e Regras de Negócio

### Nulo versus Zero
Decisão de vida e morte analítica: Se uma API falha em retornar o número de visualizações, inserimos `nil` no banco. Zero (`0`) significa que a foto flopou completamente (zero interações reais). Ignorar Nulos usando o `.compact` previne um viés de esmagamento contra médias reais se a coleta cair momentaneamente.

### Extrema Idempotência e Tratamento de Rate Limit
Todos os *colectors* são resilientes, sem side-fx caso instanciados 20 vezes juntas. Existe um Snapshot Dedup Window de 2 a horas blindando replicação estúpida. Não fazemos loops retry em HTTP 429 ou 403. Falhas críticas disparam silenciosamente throttling de Alerta ao Dev por discord, e os proxy-pools descansam pelo menos durantes as próximas 6-12 horas. 

## Tool Calling e A IA Soberana (Tooling)

Este projeto possui algo superior a dashboards chatos e planilhas BI: O usuário envia comandos ao Discord em linguagem humana natural. A LLM assume e usa tool calling integrado para extrair as respostas da base. 

Atualmente temos **mais de 16 subclasses de ferramentas** mapeadas ao `RubyLLM`, herdando defesas arquiteturais:
- O Bot nunca formata string via terminal para a IA; tudo são hashes puras injetáveis de alta performance.
- Tools base do App contêm **silent clamps** (`[ [X, 1].max, 50].min`) impedindo requisições perigosamente pesadas pelo AI.

Nossas capabilities extrapolam texto com suporte ao **Gemini Imagen 3**. O sistema consegue gerar referências criativas customizadas baseadas na própria IA lendo cenários dos concorrentes da creator.

### Prompting como Código (Prompts YAML)

Sem Strings hardcoded em serviços. Todos os prompts, pedaços de oráculo e restrições estão organizados em `config/prompts/*.yml`. Tudo flui usando interpolação de varávies dinâmicas injectando sempre `<current_datetime>` corrigindo a desorientação crônica de modelos fundamentais.

## Jobs Agendados, Alertas e Auto-Healing

O servidor cron nativo opera relógios orgânicos de mineração de mercado:
- O **Pipeline de Descoberta** vasculha URLs e menções encontrando concorrentes automaticamente.
- O Discord Notifica imediatamente se health-checks ou a rotina crasher, usando limitadores de SPAM em Solid Cache (`AlertThrottler`).
- Entregas programadas pelo Sistema de Digests passivos: O `FridayIdeationJob` manda ideias incríveis pro fim de semana e os resumos de performance na segunda, tudo gerado autonomamente.

## Executando o Projeto

O setup inteiro se compõe perfeitamente pelo Compose em Linux/Mac.

### Pré-requisitos
- Docker e Docker Compose instalados e configurados.
- Variáveis no seu novo `.env` (Use o `.env.example` como guia).

### Subindo os Serviços

```bash
docker compose -f docker/docker-compose.yml up -d
```
Verifique via `docker ps` os **5 micro-serviços** criados:
- **app**: Puma (Backend / Headless REST).
- **jobs**: O Enfileirador pesado (Solid Queue daemon).
- **chrome**: Sandbox de renderização DevTools Protocol.
- **discord-bot**: Célula chat-bot de altíssima resiliência, auto-run.
- **python-scraper**: Container Python pronto pro trabalho imundo contra proteções modernas.

### Comandos de Utilidade (Sempre dockerizados)

Verificando funcionamento (retorna status HTTP blindados):
```bash
curl http://localhost:3000/health
curl http://localhost:3000/up
```

Para atualizar o Banco de dados recém-nascido e observar os logs:
```bash
docker compose -f docker/docker-compose.yml exec app bin/rails db:migrate
docker compose -f docker/docker-compose.yml logs -f discord-bot
```

Rodando a suíte incansável de testes (Apenas inicie e espere 0 failures com o run selado):
```bash
docker compose -f docker/docker-compose.yml run --rm test
```

## Arquitetura de Banco Simplificada (E Backups Livres)

Tudo jaz e prospera silenciosamente em `/storage`. O Rails faz pooling para `primary`, `queue` e `cache` apontando pro mesmíssimo SQLite em host mount. Por fim, o projeto inclui backup automatizado contornando lock de DB: O Job de sistema (`SqliteBackupJob`) e script `.sh` copia via integridade pura WAL assegurando blindagem máxima.

## Lições Aprendidas Consolidadas (Base de Conhecimento MEMORY)

Esses paradigmas são absolutos durante o life-cycle de updates deste software em 2026:
- **A Ditadura Ruby 4.0:** OpenStruct foi morto. Usamos apenas e obrigatoriamente class mocks em testes nativos para aguentares as novas métricas da Engine base.
- **Mocha x SQLite Connection Pool:** Mocks de instâncias do DB exigem extrema destreza no clear pós-teste, caso contrário o Connection Pool transfere os objetos de stub sujos para a próxima asserção comendo a memória e soltando erros bizarros.
- **Bots são melhores que frontends:** Trocar meses de React por puro botting textual agilizou o feedback passivo do usuário infinitamente mais.

---

## Licença

[GNU Affero General Public License v3.0 (AGPL-3.0)](https://www.gnu.org/licenses/agpl-3.0.html)
