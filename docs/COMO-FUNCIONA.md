# Como funciona (em linguagem simples)

O Hermes SDR liga três coisas: o seu **Instagram**, o **Zernio** e o seu **agente Hermes**, com o **Telegram** como seu "painel de controle".

## As duas demonstrações

### Demo 1 — Posts com imagem
Você pede um post pelo Telegram ("crie um post sobre X com imagem"). O agente escreve a legenda, gera a imagem e mostra para você aprovar. Aprovou, ele publica no Instagram pelo Zernio.

### Demo 2 — Respostas automáticas
Quando alguém comenta ou manda DM no seu Instagram, o Zernio avisa o seu agente na hora (isso se chama *webhook*). O agente lê a mensagem, responde seguindo as regras do seu negócio e te manda um resumo no Telegram.

```
Comentário/DM no Instagram
        │
        ▼
     Zernio  ──(internet, HTTPS)──►  seu agente Hermes
        ▲                                  │
        │                                  ├─ responde no Instagram
        └────────── publica posts ◄────────┤
                                           └─ te avisa no Telegram
```

## Por que precisa de "endereço HTTPS"
Para o Zernio conseguir falar com o seu agente pela internet, o agente precisa de um endereço seguro (https).

- **Docker:** seu Hermes já tem o Traefik, que cria esse endereço automaticamente (estável).
- **Nativo:** usamos o **Cloudflare Tunnel** (cloudflared) para criar um endereço seguro. Esse endereço pode mudar se a VPS reiniciar — por isso existe o `hermes-sdr doctor`, que detecta o endereço novo e te avisa para atualizar no painel do Zernio.

## O vigia automático do webhook (auto-recuperação)
O endereço do modo nativo usa um *túnel rápido* do Cloudflare. Com o tempo, a
conexão desse túnel com a internet pode cair sozinha — e, quando isso acontecia,
o serviço ficava parado até alguém reiniciar na mão.

Para resolver isso de vez, o assistente instala um **vigia** (`hermes-sdr-watchdog`)
que roda **a cada minuto**. Ele:

1. Faz um *health-check* de verdade do túnel (não só "o processo está vivo?", mas
   "a conexão com a internet está de pé?", via o endpoint `/ready` do cloudflared).
2. Se detecta a queda, **reconecta sozinho** — sem você precisar fazer nada.
3. Registra tudo em `/var/log/hermes-sdr-webhook.log` (quando caiu, quando voltou).
4. Se o endereço mudou na reconexão, ele **te avisa no Telegram** com o endereço
   novo para colar no Zernio (no modo Docker o endereço é estável, então nem isso
   é preciso).

Para ver o histórico de quedas/reconexões:

```bash
tail -f /var/log/hermes-sdr-webhook.log
journalctl -u hermes-sdr-watchdog -f      # o que o vigia fez a cada minuto
```

## Onde ficam suas informações
Tudo que você digita (tokens, chave do Zernio, dados do negócio) fica só na sua VPS, na pasta `/root/.hermes-sdr-ccb/`, com acesso restrito. As "instruções de trabalho" do agente (o contexto do negócio) você mesmo cola no bot do Telegram para o agente guardar na memória dele.
