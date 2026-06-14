#!/usr/bin/env bash
# 11-negocio.sh — Perguntas sobre o negócio e geração do business-context.md.

# Blocos de texto pré-escritos selecionados por menu (garantem qualidade).
_tom_de_voz_texto() {
  case "$1" in
    1) echo "Fale como um amigo próximo: leve, divertido, linguagem do dia a dia, sem formalidade." ;;
    2) echo "Fale de forma profissional e direta: objetivo, confiante, sem enrolação." ;;
    3) echo "Fale de forma acolhedora e calma: gentil, paciente, passando segurança." ;;
    *) echo "$TOM_DE_VOZ_OUTRO" ;;
  esac
}

_regra_preco_texto() {
  case "$1" in
    1) echo "Responda o preço (dentro da faixa abaixo) e convide a pessoa a continuar no Direct ou WhatsApp." ;;
    2) echo "Não passe valores no comentário; convide a pessoa para o Direct ou WhatsApp para falar dos detalhes." ;;
    3) echo "Não responda o preço sozinho: avise o dono no Telegram e aguarde antes de dar qualquer valor." ;;
  esac
}

passo_negocio() {
  passo "PASSO 4 DE 4 — Sobre o seu negócio"
  cat <<'EOT'
  Agora me conta sobre o seu negócio. Não precisa caprichar na escrita —
  responde do seu jeito, como se explicasse pra um amigo. O assistente
  transforma isso nas "instruções de trabalho" do seu agente.
EOT

  perguntar NEG_NOME      "Qual o nome do seu negócio?" valida_nao_vazio
  perguntar NEG_VENDE     "Em uma ou duas frases: o que você vende ou que serviço presta?" valida_nao_vazio
  perguntar NEG_CLIENTE   "Quem é seu cliente ideal? (ex.: 'mães da minha cidade', 'donos de restaurante')" valida_nao_vazio
  perguntar NEG_PRECO     "Faixa de preço dos seus produtos/serviços? (ex.: 'bolos de R\$ 80 a R\$ 350') — pode pular com Enter" "" "" --opcional
  [[ -z "$NEG_PRECO" ]] && NEG_PRECO="(sob consulta)"
  perguntar NEG_INSTAGRAM "Qual o @ do Instagram do negócio? (ex.: @minhaloja)" \
    valida_instagram "Use só letras, números, ponto e _ (ex.: @minhaloja)."
  [[ "$NEG_INSTAGRAM" != @* ]] && NEG_INSTAGRAM="@$NEG_INSTAGRAM"

  titulo "Como você gosta de falar com o cliente?"
  info "1) Próximo e divertido"
  info "2) Profissional e direto"
  info "3) Acolhedor e calmo"
  info "4) Outro (eu descrevo)"
  MENU_MAX=4
  perguntar NEG_TOM "Escolha (1 a 4):" valida_opcao_menu "Digite um número de 1 a 4."
  if [[ "$NEG_TOM" == "4" ]]; then
    perguntar TOM_DE_VOZ_OUTRO "Descreva em uma frase como o agente deve falar:" valida_nao_vazio
  fi

  perguntar NEG_RESTRICOES "Tem algo que o agente NUNCA deve fazer ou prometer? (ex.: 'nunca dar desconto') — Enter pra pular" "" "" --opcional
  [[ -z "$NEG_RESTRICOES" ]] && NEG_RESTRICOES="Não prometer nada que não esteja combinado com o dono."

  titulo "Quando alguém pergunta preço ou quer comprar, o que o agente deve fazer?"
  info "1) Responder o preço e chamar pro Direct/WhatsApp"
  info "2) Só chamar pro Direct/WhatsApp (sem passar valor)"
  info "3) Avisar você antes de responder qualquer coisa"
  MENU_MAX=3
  perguntar NEG_REGRA_PRECO "Escolha (1 a 3):" valida_opcao_menu "Digite 1, 2 ou 3."

  # Salva respostas cruas (permite regenerar o contexto depois).
  for v in NEG_NOME NEG_VENDE NEG_CLIENTE NEG_PRECO NEG_INSTAGRAM NEG_TOM TOM_DE_VOZ_OUTRO NEG_RESTRICOES NEG_REGRA_PRECO; do
    salvar_var "$v" "${!v:-}"
  done
  salvar_var INSTAGRAM_HANDLE "$NEG_INSTAGRAM"

  _gerar_contexto
  _revisar_contexto
}

# Substitui placeholders do template com as respostas (via python p/ escape seguro).
_gerar_contexto() {
  local template="$BASE_DIR/modelos/business-context.template.md"
  TOM_TXT="$(_tom_de_voz_texto "$NEG_TOM")"
  REGRA_TXT="$(_regra_preco_texto "$NEG_REGRA_PRECO")"

  NOME_NEGOCIO="$NEG_NOME" O_QUE_VENDE="$NEG_VENDE" CLIENTE_IDEAL="$NEG_CLIENTE" \
  FAIXA_PRECO="$NEG_PRECO" INSTAGRAM_HANDLE="$NEG_INSTAGRAM" \
  TOM_DE_VOZ_DESCRICAO="$TOM_TXT" REGRA_PRECO="$REGRA_TXT" RESTRICOES="$NEG_RESTRICOES" \
  python3 - "$template" "$ESTADO_CONTEXTO" <<'PY'
import os, sys
template, destino = sys.argv[1], sys.argv[2]
campos = ["NOME_NEGOCIO","O_QUE_VENDE","CLIENTE_IDEAL","FAIXA_PRECO",
          "INSTAGRAM_HANDLE","TOM_DE_VOZ_DESCRICAO","REGRA_PRECO","RESTRICOES"]
texto = open(template, encoding="utf-8").read()
for c in campos:
    texto = texto.replace("{{%s}}" % c, os.environ.get(c, ""))
open(destino, "w", encoding="utf-8").write(texto)
PY
  chmod 600 "$ESTADO_CONTEXTO"
  ok "Criei as instruções de trabalho do seu agente."
}

_revisar_contexto() {
  titulo "Veja como ficou (resumo):"
  sed -n '1,18p' "$ESTADO_CONTEXTO"
  echo "  ..."
  if ! confirmar "Ficou bom?" s; then
    dica "Sem problema — vamos refazer as perguntas do negócio."
    NEG_NOME="" NEG_VENDE="" NEG_CLIENTE=""   # limpa para reperguntar
    passo_negocio
  fi
}
