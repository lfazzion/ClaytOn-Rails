# Contexto: db/

Schema, migrations e banco SQLite do projeto.

## Estrutura

```
db/
  migrate/              — Migrations da aplicação
  queue_migrate/        — Migrations do Solid Queue
  cache_migrate/        — Migrations do Solid Cache
  schema.rb             — Schema atual da aplicação
  queue_schema.rb       — Schema do Solid Queue
  cache_schema.rb       — Schema do Solid Cache
  development.sqlite3   — DB de desenvolvimento
  test.sqlite3          — DB de testes
```

## Regras Críticas para IA

1. **SQLite WAL**: Banco único com 3 conexões separadas (primary, queue, cache)
2. **Nomenclatura de migration**: `TIMESTAMP_snake_case_description.rb`
3. **Timestamps obrigatórios**: Toda tabela deve ter `t.timestamps` (created_at, updated_at)
4. **Índices**: Criar índice para toda foreign key e toda coluna usada em WHERE/ORDER BY
5. **3 tipos de migration**:
   - `db/migrate/` — tabelas da aplicação (SocialProfile, SocialPost, etc.)
   - `db/queue_migrate/` — tabelas do Solid Queue (NÃO mexer, gerenciado pelo gem)
   - `db/cache_migrate/` — tabelas do Solid Cache (NÃO mexer, gerenciado pelo gem)
6. **Docker**: Rodar migrations via `docker compose -f docker/docker-compose.yml exec app bin/rails db:migrate`
 7. **NUNCA apagar SQLite manualmente**: O arquivo fica em `storage/` (bind mount). Apagar = perder todos os dados

## Cross-References

- Models: `app/models/CONTEXT.md` — os models que usam estas tabelas
- Docker: `docker/CONTEXT.md` — bind mount de storage/ e entrypoint de migrations
