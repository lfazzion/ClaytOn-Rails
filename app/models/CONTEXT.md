# Contexto: app/models

Models ActiveRecord do projeto. Herdam de `ApplicationRecord`.

## Models Existentes

| Model | Descrição | Chave |
|-------|-----------|-------|
| `SocialProfile` | Perfil de influenciador (twitter, instagram, youtube, tiktok) | `platform` + `platform_user_id` |
| `SocialPost` | Post coletado de uma plataforma | `platform_post_id` |
| `ProfileSnapshot` | Snapshot de métricas em um momento | `social_profile_id` + `collected_at` |
| `DiscoveredProfile` | Perfil descoberto via grafo social (pendente de classificação) | `platform` + `username` |
| `NewsArticle` | Artigo RSS coletado | `url` |
| `ExternalCatalog` | Item de catálogo de fontes externas (TMDB, IGDB, Anilist) | `source` + `external_id` |
| `Event` | Evento nerd brasileiro (RSS, manual) | `source_url` |
| `Conversation` | Conversa do Discord; `scope` decide individual (`u:<user>:c:<channel>`) ou compartilhada (`c:<channel>`); a fronteira entre conversas é o `/new` | `scope` (índice parcial único com `active`) |
| `ChatMessage` | Fala persistida da conversa (`user`/`assistant`); `content` literal, nunca reescrito | `conversation_id` |

## Regras Críticas para IA

1. **Herança**: Todo model herda `ApplicationRecord`
2. **Constantes com freeze**: `PLATFORMS = %w[twitter instagram].freeze`
3. **Validações primeiro**, depois associations, depois scopes, depois métodos de instância
4. **Scopes com lambda**: `scope :verified, -> { where(verified: true) }`
5. **Uniqueness composta**: Sempre validar duplicatas por chaves compostas (ex: `platform` + `platform_user_id`)
 6. **Null vs Zero**: Ver regra cross-cutting #3 no AGENTS.md
 7. **Nenhum callback complexo**: Lógica de negócio vai em `app/services/`. Models ficam enxutos

## Cross-References

- Schema/migrations: `db/CONTEXT.md` — onde as tabelas são definidas
- Services: `app/services/CONTEXT.md` — lógica de negócio que usa estes models
- Jobs: `app/jobs/CONTEXT.md` — jobs que criam/atualizam estes models
