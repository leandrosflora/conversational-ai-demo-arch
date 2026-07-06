# Arquitetura de segurança

Este documento traduz os requisitos não funcionais de segurança e LGPD já declarados em [`docs/context/business-context.md`](../context/business-context.md) para o que está de fato implementado no código hoje — e, com igual destaque, o que ainda não está.

## Autenticidade do webhook (implementado)

`whatsapp-bff` valida toda entrega do WhatsApp Cloud API com HMAC-SHA256 sobre o corpo bruto da requisição, comparando com o header `X-Hub-Signature-256`, usando `WhatsApp:AppSecret` como chave. Uma assinatura ausente ou inválida é rejeitada com `401 Unauthorized` antes de qualquer processamento (`WebhookSignatureValidator`, invocado em `WhatsAppWebhookEndpoints.HandleWebhookAsync`). O handshake de verificação do webhook (`GET /webhooks/whatsapp`) também exige `hub.verify_token` batendo com `WhatsApp:VerifyToken`.

## Proteção de dados sensíveis em trânsito para o Kafka (implementado)

O `tool-service-renegotiation` nunca inclui argumentos de tool (CPF, IDs de contrato/simulação/acordo) no evento `tool.executed` publicado no Kafka — o payload contém apenas `tool_name`, `outcome` e `correlation_id`. Isso não é mascaramento parcial: é exclusão total do dado potencialmente sensível do evento de auditoria, por desenho. Pelo mesmo motivo, o client HTTP desse serviço loga apenas o *tipo* da exceção em falhas de rede, nunca a mensagem completa (que poderia conter a URL com CPF/IDs).

## Segredos e configuração (recomendação, não controle imposto)

Nenhum serviço commita segredos reais em `appsettings.json`/`.env` — os arquivos versionados trazem apenas placeholders vazios (`WhatsApp:AppSecret`, `WhatsApp:AccessToken`, `WhatsApp:VerifyToken`). A orientação (documentada no README do `whatsapp-bff`) é usar `dotnet user-secrets` ou variáveis de ambiente em desenvolvimento, e um cofre de segredos real (não incluído neste workspace) em produção. **Isso é uma convenção seguida pelo código existente, não um controle tecnicamente imposto** — nada impede alguém de commitar um segredo real por engano; não há scanning de segredos configurado neste workspace.

## O que não está implementado

- **Nenhuma autenticação/autorização entre serviços internos.** `conversation-orchestrator` chama `agent-runtime-renegotiation`, que chama `tool-service-renegotiation`, que chama `renegotiation-service`, que chama `core-bancario-mock` — nenhuma dessas chamadas HTTP carrega token, mTLS ou qualquer credencial. Qualquer processo com acesso de rede a essas portas pode chamá-las diretamente. Isso é aceitável para um ambiente de demonstração local, mas precisaria de uma camada de autenticação de serviço (mTLS, tokens assinados, ou um service mesh) antes de qualquer coisa próxima de produção.
- **`POST /internal/messages` do `whatsapp-bff` não tem autenticação própria** — depende inteiramente de estar atrás de um gateway/rede privada, o que não existe neste workspace.
- **Sem criptografia em repouso** para nenhum dos datastores provisionados (Postgres/Mongo/Redis) — aliás, nenhum deles é usado hoje por código de aplicação (ver [`docs/contracts/data-stores.md`](../contracts/data-stores.md)), então a questão de criptografia em repouso ainda nem se aplica na prática.
- **Sem rate limiting** em nenhum endpoint público (`POST /webhooks/whatsapp` inclusive) além da deduplicação por `message.id`.
- **Sem scanning automatizado de segredos** no repositório ou pipeline (não há `.github/workflows` neste workspace).

## Relação com os requisitos de negócio

`business-context.md` declara como requisitos não funcionais: autenticação/autorização, criptografia em trânsito/repouso, integrações seguras entre sistemas, proteção de dados pessoais, minimização de dados, e auditoria de acessos. Deste conjunto, o que está genuinamente implementado hoje é: validação de autenticidade do webhook (HMAC), minimização de dados no evento de auditoria de tools (exclusão de CPF/IDs), e auditoria de execuções de tools (`tool.executed`). Autenticação entre serviços internos, criptografia em repouso e controles automatizados de segredo permanecem como lacunas — não implicitamente resolvidas por este documento, e sim explicitamente sinalizadas como pendentes.
