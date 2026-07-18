# knowledge-service

Repo: [`leandrosflora/knowledge-service`](https://github.com/leandrosflora/knowledge-service) · Stack: Python, FastAPI, OpenSearch, OpenAI Embeddings · Porta local: `8500`

## Responsabilidade principal

Serviço de RAG (retrieval-augmented generation) para FAQ de renegociação: ingere PDFs, os quebra em chunks, embeda cada chunk via OpenAI e indexa no OpenSearch com busca vetorial k-NN. Expõe `GET /search` — já consumido de verdade pelo `agent-runtime-renegotiation` (tool `search_knowledge_base`) — e `POST /admin/reindex` para reprocessar sem reiniciar o serviço.

## Dados que o serviço possui

Nenhum modelo de domínio próprio em memória — todo o estado vive no índice OpenSearch `faq_chunks` (um documento por chunk: `text`, `title`, `sourceFile`, `chunkIndex`, `contentHash`, `createdAt`, `embedding` — vetor k-NN de 1536 dimensões, `hnsw`/`cosinesimil`/engine `lucene`).

## APIs publicadas

| Método | Rota | Descrição |
|---|---|---|
| `GET` | `/search?query=...` | Embeda a query, faz k-NN search no índice, filtra por `min_relevance_score` (default `0.70`) e devolve os resultados ordenados por score |
| `POST` | `/admin/reindex` | Reprocessa todo `.pdf` em `data/faq_pdfs/` sob demanda, sem reiniciar o processo |

`GET /search` responde `200 OK` com `results: []` quando nada relevante é encontrado — isso é um resultado normal, não um erro. Ambos os endpoints respondem `503 Service Unavailable` (nunca `500`/hang) quando o OpenSearch ou a OpenAI Embeddings API estão inacessíveis (`KnowledgeBackendUnavailableError`, mapeada por um exception handler central em `app/main.py`).

## Eventos publicados

Nenhum.

## Eventos consumidos

Nenhum.

## Dependências síncronas

| Destino | Comportamento se indisponível |
|---|---|
| OpenSearch (`:9200`) | Client configurado com `timeout=3s`, `max_retries=0` — sem isso, o retry padrão do `opensearch-py` (3 tentativas) multiplicaria o tempo até falhar para ~9s antes do `503` ter chance de disparar. Qualquer `OpenSearchException` vira `KnowledgeBackendUnavailableError` → `503` |
| OpenAI Embeddings API (externo, real) | Sem `OPENAI_API_KEY` configurada, `embed_texts` recusa a chamar a API e levanta `KnowledgeBackendUnavailableError` direto — nem tenta a rede. Com chave configurada mas API fora do ar, o erro do SDK vira o mesmo `KnowledgeBackendUnavailableError` |

## Persistência & infraestrutura

- **OpenSearch** (`faq_chunks`): único armazenamento real do serviço — chunks de texto + embeddings, busca k-NN.
- Ingestão de PDFs lê de `data/faq_pdfs/` (bind mount no `docker-compose.yml`, para que um PDF solto ali sem rebuild de imagem já seja visível a `POST /admin/reindex`).
- Sem banco relacional/documento.

## Regras de negócio

1. **Idempotência por hash de conteúdo**: cada arquivo tem um `contentHash` (calculado na extração). Se o hash já indexado bate com o atual **e** a contagem de chunks indexados bate com `len(chunks)` do arquivo, o arquivo é pulado (`files_skipped`) — só reprocessa o que for novo ou tiver mudado.
2. **Detecção de ingestão parcial**: um hash "bater" sozinho não é prova de que a indexação anterior terminou — uma escrita de chunk pode ter dado timeout no client mas ter sido concluída no servidor. Por isso a contagem de chunks indexados também é conferida; se não bater com o esperado, o arquivo é reingerido mesmo com hash igual.
3. **Rollback em falha parcial**: se o backend cair no meio da escrita dos chunks de um arquivo, os chunks já escritos daquele arquivo são apagados — deixar um estado parcial faria `get_indexed_hash` enxergar um "match" (o hash não muda) e pular esse arquivo para sempre, sem nunca completar a ingestão que de fato falhou.
4. Uma falha de backend (OpenSearch/OpenAI) durante a ingestão em lote de `data/faq_pdfs/` **aborta o restante do lote** — se o backend caiu, todo arquivo remanescente falharia do mesmo jeito; é preferido um erro claro a N entradas idênticas de "falhou".
5. Sem nenhum PDF em `data/faq_pdfs/`, o serviço sobe normalmente e `GET /search` responde `200` com `results: []` para qualquer busca — ausência de conteúdo não é uma condição de erro.
6. `refresh_index` só é chamado uma vez, ao final da indexação de todos os chunks de um arquivo — não a cada chunk individual, para não serializar/lentificar a escrita de um arquivo com muitos chunks a ponto de estourar o timeout de 3s do client contra um cluster saudável.

## Referências de arquitetura

- [Diagramas de sequência da jornada](../architecture/sequence-diagrams.md)
- [Contratos — Datastores](../contracts/data-stores.md)
