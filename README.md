# Hermes SDR by CCB

Transforme o seu **Hermes Agent** num agente de **SDR / social media** para Instagram, controlado pelo **Telegram** — em poucos minutos, sem precisar entender de programação.

Este é um assistente (wizard) de instalação feito para a **Comunidade Claw Brasil (CCB)**. Você responde algumas perguntas simples e, no final, tem um agente que:

- 📸 **Cria e publica posts com imagem** no seu Instagram (você só aprova pelo Telegram).
- 💬 **Responde comentários e DMs automaticamente** e te avisa no Telegram quando aparece um cliente interessado.

---

## Pré-requisitos

1. Uma **VPS** (servidor) com o **Hermes Agent já instalado** — em Docker **ou** instalação nativa. (Se ainda não instalou, veja o material da CCB.)
2. O Hermes com um **modelo de IA configurado** (rode `hermes setup` e cole a chave de um provedor, ex.: OpenRouter). Sem isso o agente liga, mas não consegue responder.
3. **Telegram** no celular.
4. Uma conta no **Zernio** (zernio.com) com o seu **Instagram conectado**.

---

## Como instalar (1 comando)

Conecte na sua VPS por SSH e cole:

```bash
curl -fsSL https://raw.githubusercontent.com/SEU-USUARIO/hermes-sdr-ccb/main/install.sh | sudo bash
```

> Troque `SEU-USUARIO` pelo dono do repositório no GitHub.

O assistente abre sozinho e vai te guiando. Quando terminar, dá pra rodar de novo a qualquer momento com:

```bash
hermes-sdr            # roda/continua o assistente
hermes-sdr doctor     # confere se está tudo certo e corrige problemas comuns
hermes-sdr info       # mostra o endereço do webhook, a chave e o nome do bot
hermes-sdr contexto   # mostra o texto do seu negócio para colar no bot
```

### Alternativa (sem o one-liner)

```bash
git clone https://github.com/SEU-USUARIO/hermes-sdr-ccb.git /opt/hermes-sdr-ccb
sudo bash /opt/hermes-sdr-ccb/instalar.sh
```

---

## O que o assistente faz por você

1. Detecta se o seu Hermes é **Docker** ou **nativo**.
2. Cria um **agente dedicado** (perfil `sdr`) e configura o seu bot do Telegram.
3. Conecta o **Zernio** (Instagram) ao agente.
4. Liga as **respostas automáticas** (webhook) com segurança (HTTPS).
5. Gera as **instruções de trabalho** do agente a partir das respostas sobre o seu negócio.
6. Roda um **diagnóstico** no final e corrige o que conseguir.

---

## Perguntas frequentes

**Preciso saber programar?** Não. O assistente faz tudo e explica onde clicar.

**Mexe no meu Hermes que já uso?** Ele cria um agente **separado** (`sdr`), sem mexer no que você já tem.

**Onde ficam minhas senhas e chaves?** Só na **sua VPS**, na pasta `/root/.hermes-sdr-ccb/` (protegida). Nada é enviado para fora.

**Testei comentando no meu próprio Instagram e não respondeu.** Isso é normal: o Zernio só dispara para interações de **outra** pessoa. Teste de outra conta.

**As respostas pararam de funcionar.** Rode `hermes-sdr doctor` — ele costuma detectar e corrigir (inclusive quando o endereço do webhook muda).

Mais detalhes em [docs/COMO-FUNCIONA.md](docs/COMO-FUNCIONA.md) e [docs/PROBLEMAS-COMUNS.md](docs/PROBLEMAS-COMUNS.md).
