# Contexto: test/

Todos os testes do projeto. Framework: Minitest + FactoryBot + Mocha + WebMock.

## Espelha app/

A estrutura de `test/` espelha `app/`:
- `test/models/` → testa models
- `test/services/` → testa services
- `test/jobs/` → testa jobs
- `test/lib/` → testa classes de lib/
- `test/scraping/` → testa scraping
- `test/connectors/` → testa chrome_ws_connector
- `test/setup/` → testa infraestrutura (initializer, SQLite, etc.)
- `test/docker/` → testa configuração Docker (compose e Dockerfiles)
- `test/scripts/python/` → testa os scripts do sidecar rodando-os como processo,
  com um módulo falso (`camoufox`, etc.) no `PYTHONPATH`. Dublar só a ponte Ruby
  deixa o script livre para quebrar sem nenhum teste ficar vermelho

## Comandos (sempre dockerizado)

```bash
# Todos os testes
docker-compose -f docker/docker-compose.yml run --rm test

# Arquivo específico
docker-compose -f docker/docker-compose.yml run --rm test test test/models/social_profile_test.rb

# Pelo nome do teste
docker-compose -f docker/docker-compose.yml run --rm test test test/models/social_profile_test.rb -n "/test_name_pattern/"
```

## Regras Críticas para IA

1. **Nomenclatura**: `ClassNameTest` em `test/path/class_name_test.rb`
2. **Syntax de bloco**: Usar `test "description" do ... end` (não `def test_...`)
3. **Require**: Incluir `require 'test_helper'` no topo de todo arquivo de teste
4. **Setup**: Usar blocos `setup` para dados compartilhados
5. **Factories**: FactoryBot com `build`, `create`, `build_list`, `create_list`
6. **Mocks**: Mocha (`.expects`, `.stubs`)
7. **HTTP stubs**: WebMock (`stub_request`). Nunca chamada real a APIs externas
 8. **Novo model = factory + test**: Criar factory em `test/factories/` e test em `test/models/` sempre que criar um model novo

## Cross-References

- App: segue a mesma estrutura de `app/` — ver folder map no AGENTS.md
- Factories: `test/factories/` — FactoryBot, deve refletir os models em `app/models/`
