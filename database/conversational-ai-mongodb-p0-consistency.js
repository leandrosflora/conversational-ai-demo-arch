// P0 tenant-scoped idempotency migration for fresh MongoDB volumes.
// Existing volumes are migrated by conversation-memory-service on startup.

const targetDb = db.getSiblingDB('conversational_ai');
const messages = targetDb.conversation_messages;

const indexes = messages.getIndexes();
const legacy = indexes.find(index =>
  index.name === 'externalMessageId_1' &&
  JSON.stringify(index.key) === JSON.stringify({ externalMessageId: 1 })
);

if (legacy) {
  messages.dropIndex('externalMessageId_1');
}

messages.createIndex(
  { tenantId: 1, externalMessageId: 1 },
  {
    name: 'ux_conversation_messages_tenant_external_message',
    unique: true,
    partialFilterExpression: { externalMessageId: { $type: 'string' } }
  }
);

print('MongoDB P0 tenant-scoped idempotency migration completed.');
