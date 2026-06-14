# Problemas comuns (e como resolver)

A maioria se resolve rodando:

```bash
hermes-sdr doctor
```

Abaixo, o que cada situação significa.

---

### "Comentei/mandei DM e o agente não respondeu"
**Quase sempre não é bug.** O Zernio só dispara o webhook para interações de **outra** pessoa. Teste comentando ou mandando DM de **outra conta** do Instagram.

### "As respostas pararam de funcionar do nada" (instalação nativa)
O endereço do túnel (Cloudflare) provavelmente **mudou** (a VPS reiniciou). Rode `hermes-sdr doctor`: ele mostra o **endereço novo**. Copie e atualize no painel do Zernio em *Webhooks → seu webhook → Endpoint URL*.

### "O bot do Telegram não responde"
O token pode ter sido revogado no @BotFather. Rode `hermes-sdr` de novo e cole o token atual.

### "O agente responde 'qual contato? qual interação?'"
A rota do webhook está sem os dados do evento. O assistente cria a rota com o marcador `{__raw__}`, que injeta os dados. Rode `hermes-sdr doctor` para recriar a rota corretamente.

### "O Zernio mostra 200/sucesso, mas o agente não age"
A rota não pode ter **filtro de eventos**. O assistente cria a rota **sem filtro** (o Zernio já filtra no painel). Rode `hermes-sdr doctor`.

### "O Zernio mostra 401 (não autorizado)"
A **chave de segurança** (Signing Secret) que está no painel do Zernio é diferente da que está na sua VPS. Rode `hermes-sdr info` para ver a chave certa e cole no painel do Zernio.

### "Depois de atualizar o Hermes, parou" (instalação nativa)
Atualizar o Hermes apaga o ajuste que reconhece a assinatura do Zernio (`X-Zernio-Signature`). Rode `hermes-sdr doctor` — ele reaplica o ajuste automaticamente.

### "Depois de um `docker compose down/up`, parou" (Docker)
O assistente já deixa um ajuste que reaplica sozinho a cada reinício do container. Se ainda assim falhar, rode `hermes-sdr doctor`.

### "A resposta demora vários minutos"
Depende do modelo de IA configurado no seu Hermes. Modelos gratuitos costumam ser mais lentos. Para acelerar, configure um modelo mais rápido no seu perfil do Hermes.

---

Se nada disso resolver, leve a saída do `hermes-sdr doctor` para a comunidade.
