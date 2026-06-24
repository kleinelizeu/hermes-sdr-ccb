#!/usr/bin/env bash
# 60-painel-zernio.sh — Instruções (manuais) para criar o webhook no painel do Zernio.

passo_painel_zernio() {
  passo "ÚLTIMO AJUSTE NO PAINEL DO ZERNIO"

  # Tentativa SEM TOQUE: cria/atualiza o webhook no Zernio pela API (com a chave
  # que você já forneceu). Se der certo, você não precisa mexer no painel — e,
  # se a URL mudar no futuro, o vigia atualiza sozinho.
  if zernio_garantir_webhook 2>/dev/null; then
    ok "Configurei o webhook no Zernio automaticamente — você não precisa fazer nada."
    info "Endereço (Endpoint URL): ${WEBHOOK_URL}"
    nota "Se a URL mudar no futuro, o vigia atualiza o Zernio sozinho (sem toque)."
    caixa "Para TESTAR: comente ou mande DM de OUTRA conta do Instagram." \
          "Da sua própria conta o Zernio não dispara (não é bug)."
    return 0
  fi

  dica "Não consegui configurar o Zernio automaticamente — segue o jeito manual (rápido):"
  cat <<'EOT'
  Falta avisar o Zernio para onde mandar os comentários e DMs. É rápido:

   1. Entre em:  https://zernio.com/dashboard/webhooks
   2. Clique em "Create" (ou "Add Webhook")
   3. Preencha:
        Endpoint URL    -> o endereço abaixo
        Signing Secret  -> a chave abaixo
        Events          -> marque  message.received  e  comment.received
   4. Salve.
EOT
  echo
  info "Endereço (Endpoint URL):"
  copiavel "${WEBHOOK_URL:-(rode o doctor para descobrir o endereço)}"
  info "Chave de segurança (Signing Secret):"
  copiavel "${WEBHOOK_SECRET:-(nenhuma)}"

  caixa "Lembre-se: para TESTAR depois, comente ou mande DM de OUTRA" \
        "conta do Instagram. Da sua própria conta o Zernio não dispara."

  confirmar "Já criou o webhook no painel do Zernio?" s || \
    dica "Sem problema — você pode fazer isso depois. 'hermes-sdr info' mostra o endereço e a chave de novo."
}
