# Contexto: lib/llm

Integração pura com LLMs via RubyLLM (gem 1.14.0): OpenRouter, Gemini, Poolside, Nous.

## Arquivos

| Arquivo | Descrição |
|---------|-----------|
| `base_client.rb` | Classe base com error handling e retry |
| `gemini_background_client.rb` | Cliente Gemini para tarefas assincronas (tier: background) |
| `gemini_interactive_client.rb` | Cliente Gemini para conversa (tier: interactive short) |
| `model_chain.rb` | A cadeia de rotas: Poolside → Nous → OpenRouter, com ajustes de raciocínio por rota |
| `openrouter_client.rb` | Cliente OpenRouter do pipeline `AiRouter` (fallback das rotas Gemini). **Não** é o elo 3 da `ModelChain` — aquele é montado direto pelo `ChatSessionManager`, sem cota própria. |
| `prompt_loader.rb` | Carrega templates YAML de `config/prompts/` |
| `model_registry.rb` | Consulta de modelos gratuitos vivos na OpenRouter |

### `providers/` — rotas OpenAI-compatíveis registradas na gem

`poolside.rb` e `nous.rb` são subclasses de `RubyLLM::Providers::OpenAI`. São
registradas em `config/initializers/ruby_llm.rb`, que é o único ponto de
carregamento correto: `RubyLLM::Provider.register` cria os acessores de
configuração (`poolside_api_key`, `nous_api_key`) e tem de rodar antes do
`RubyLLM.configure`.

O `slug` de cada provedor é derivado do **nome da classe**, e é ele que precisa
casar, como String, com o campo `provider` dos `Model::Info` registrados. Mudar o
nome da classe quebra a resolução do modelo em tempo de execução, não no boot.

### `model_chain.rb` — a cadeia de rotas do chat

Descreve os elos na ordem, filtrados pelas chaves presentes. Cada elo carrega
como desligar o raciocínio **daquela** rota, porque os mecanismos são
incompatíveis: a Poolside direta usa
`chat_template_kwargs.enable_thinking = false` (via `Chat#with_params`) e o Nous
usa `reasoning_effort` (via `Chat#with_thinking`). Trocar um pelo outro não
degrada — dá HTTP 400 ou é ignorado em silêncio.

`ModelChain.aggregator` expõe o modelo `tencent/hy3:free` no provedor `:nous`,
reservado para a spec 3 (MoA — multiplicação de agentes). **Não** entra na cadeia
do chat — é fiel na agregação mas 3× mais lento que o `laguna-xs` no chat.

### `model_registry.rb` — consulta de modelos gratuitos vivos

Lê a resposta crua da OpenRouter (`provider.connection.get("models")`) porque o
`Model::Info` da gem descarta a informação de preço zero. Não registra modelo
nenhum: quem registra é o initializer.

## Regras Críticas para IA

 1. **Time Injection**: Ver regra cross-cutting #8 no AGENTS.md
 2. **Usar PromptLoader**: `PromptLoader.load('system/analysis')` — nunca ler YAML diretamente
 3. **Roteamento**: `AiRouter.complete(prompt, context: :interactive|:background)` — ver `app/services/CONTEXT.md`
 4. **Error handling**: `QuotaExceededError`, `RateLimitError` — classes aninhadas no módulo

## Cross-References

- Services: `app/services/CONTEXT.md` — AiRouter orquestra chamadas
- Prompts: `config/prompts/CONTEXT.md` — templates carregados pelo PromptLoader
