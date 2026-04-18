#!/usr/bin/env bash

# Cores para output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Configuração
API_URL="${WHISPER_API_URL:-http://localhost:8080}"
TEMP_DIR="/tmp/whisper_cli_$$"
mkdir -p "$TEMP_DIR"

# Verifica dependências
check_deps() {
    if ! command -v curl &> /dev/null; then
        echo -e "${RED}Erro: curl não instalado.${NC}"
        exit 1
    fi
    if ! command -v python3 &> /dev/null; then
        echo -e "${RED}Erro: python3 não instalado.${NC}"
        exit 1
    fi
}
check_deps

# Função para imprimir seção
print_section() {
    echo -e "\n${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}$1${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

# Verifica se a API está online
check_api() {
    local response=$(curl -s -o /dev/null -w "%{http_code}" "$API_URL/health")
    if [ "$response" != "200" ]; then
        echo -e "${RED}✗ API não respondendo em $API_URL (HTTP $response)${NC}"
        echo -e "${YELLOW}Certifique-se que o servidor está rodando: python whisper_api.py${NC}"
        return 1
    fi
    echo -e "${GREEN}✓ API conectada em $API_URL${NC}"
    return 0
}

# Aguarda conclusão de um job
wait_for_job() {
    local job_id="$1"
    local max_attempts=60
    local attempt=0
    echo -e "${YELLOW}Aguardando job $job_id...${NC}"
    while [ $attempt -lt $max_attempts ]; do
        response=$(curl -s "$API_URL/job/$job_id")
        status=$(echo "$response" | python3 -c "import sys, json; print(json.load(sys.stdin).get('status', ''))" 2>/dev/null)
        case "$status" in
            completed)
                echo -e "\n${GREEN}✓ Job concluído!${NC}"
                echo "$response" | python3 -m json.tool 2>/dev/null
                return 0
                ;;
            failed)
                error=$(echo "$response" | python3 -c "import sys, json; print(json.load(sys.stdin).get('error', 'unknown'))" 2>/dev/null)
                echo -e "\n${RED}✗ Job falhou: $error${NC}"
                return 1
                ;;
            processing)
                echo -n "."
                ;;
            pending)
                echo -n "."
                ;;
        esac
        sleep 1
        attempt=$((attempt + 1))
    done
    echo -e "\n${RED}✗ Timeout após ${max_attempts}s${NC}"
    return 1
}

# Listar todas as sessões disponíveis
list_sessions() {
    local sessions=$(curl -s "$API_URL/sessions")
    local count=$(echo "$sessions" | python3 -c "import sys, json; print(len(json.load(sys.stdin)))" 2>/dev/null)
    if [ "$count" -eq 0 ]; then
        echo -e "${YELLOW}Nenhuma sessão encontrada.${NC}"
        return 1
    fi
    echo -e "${BLUE}Sessões disponíveis:${NC}"
    echo "$sessions" | python3 -c "import sys, json; data=json.load(sys.stdin); [print(f'  {i+1}. {s}') for i, s in enumerate(data)]" 2>/dev/null
    return 0
}

# Listar mensagens de uma sessão
list_messages() {
    local session_id="$1"
    local response=$(curl -s "$API_URL/messages?session=$session_id")
    local count=$(echo "$response" | python3 -c "import sys, json; print(len(json.load(sys.stdin)))" 2>/dev/null)
    if [ "$count" -eq 0 ]; then
        echo -e "${YELLOW}Nenhuma mensagem na sessão '$session_id'.${NC}"
        return 1
    fi
    echo -e "${GREEN}Mensagens da sessão '$session_id' (total: $count):${NC}"
    echo "$response" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for i, m in enumerate(data):
    print(f\"{i+1}. Job: {m['job_id'][:8]}... | Hash: {m['audio_hash'][:16]}... | Status: {m['status']} | Data: {m['created_at']}\")
    if m.get('transcript'):
        print(f\"   Texto: {m['transcript'][:100]}{'...' if len(m['transcript'])>100 else ''}\")
    print()
" 2>/dev/null
    return 0
}

# Exibir detalhes de um job
show_job() {
    local job_id="$1"
    local response=$(curl -s "$API_URL/job/$job_id")
    local status=$(echo "$response" | python3 -c "import sys, json; print(json.load(sys.stdin).get('status', ''))" 2>/dev/null)
    if [ -z "$status" ]; then
        echo -e "${RED}Job não encontrado.${NC}"
        return 1
    fi
    echo "$response" | python3 -m json.tool 2>/dev/null
    return 0
}

# Consultar por hash
query_hash() {
    local hash="$1"
    local response=$(curl -s "$API_URL/message?hash=$hash")
    local status=$(echo "$response" | python3 -c "import sys, json; print(json.load(sys.stdin).get('status', ''))" 2>/dev/null)
    if [ -z "$status" ]; then
        echo -e "${RED}Hash não encontrado.${NC}"
        return 1
    fi
    echo "$response" | python3 -m json.tool 2>/dev/null
    return 0
}

# Gravar áudio (com session_id opcional)
record_audio() {
    local duration="$1"
    local session_id="$2"
    local data="{\"duration\": $duration}"
    if [ -n "$session_id" ]; then
        data="{\"duration\": $duration, \"session_id\": \"$session_id\"}"
    fi
    echo -e "${BLUE}Gravando ${duration}s...${NC}"
    local response=$(curl -s -X POST "$API_URL/record" -H "Content-Type: application/json" -d "$data")
    local job_id=$(echo "$response" | python3 -c "import sys, json; print(json.load(sys.stdin).get('job_id', ''))" 2>/dev/null)
    local sess=$(echo "$response" | python3 -c "import sys, json; print(json.load(sys.stdin).get('session_id', ''))" 2>/dev/null)
    if [ -z "$job_id" ]; then
        echo -e "${RED}Falha na gravação: $response${NC}"
        return 1
    fi
    echo -e "${GREEN}Job criado: $job_id | Sessão: $sess${NC}"
    wait_for_job "$job_id"
}

# Upload de arquivo
upload_file() {
    local filepath="$1"
    local session_id="$2"
    if [ ! -f "$filepath" ]; then
        echo -e "${RED}Arquivo não encontrado: $filepath${NC}"
        return 1
    fi
    echo -e "${BLUE}Enviando $filepath...${NC}"
    local response=$(curl -s -X POST "$API_URL/upload" -F "file=@$filepath" -F "session_id=$session_id")
    local job_id=$(echo "$response" | python3 -c "import sys, json; print(json.load(sys.stdin).get('job_id', ''))" 2>/dev/null)
    if [ -z "$job_id" ]; then
        echo -e "${RED}Falha no upload: $response${NC}"
        return 1
    fi
    echo -e "${GREEN}Job criado: $job_id${NC}"
    wait_for_job "$job_id"
}

# Criar arquivo WAV de teste (1s silêncio)
create_test_wav() {
    local output="$1"
    if command -v sox &> /dev/null; then
        sox -n -r 16000 -c 1 "$output" trim 0 1.0 &> /dev/null
    elif command -v ffmpeg &> /dev/null; then
        ffmpeg -f lavfi -i anullsrc=r=16000:cl=mono -t 1 -q:a 9 -acodec pcm_s16le "$output" -y &> /dev/null
    else
        # Base64 de um WAV mínimo
        echo "UklGRCwAAABXQVZFZm10IBAAAAABAAEAQB8AAEAfAAABAAgAAABmYWN0BAAAAAAAAABkYXRhAAAAAA==" | base64 -d > "$output" 2>/dev/null
    fi
}

# Submenu de gravação
menu_record() {
    echo -e "\n${CYAN}--- Gravação de Áudio ---${NC}"
    read -p "Duração em segundos: " dur
    if [[ ! "$dur" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        echo -e "${RED}Duração inválida.${NC}"
        return
    fi
    read -p "Session ID (opcional, deixe vazio para gerar automático): " sess
    record_audio "$dur" "$sess"
}

# Submenu de upload
menu_upload() {
    echo -e "\n${CYAN}--- Upload de Áudio ---${NC}"
    read -p "Caminho do arquivo de áudio: " filepath
    if [ ! -f "$filepath" ]; then
        echo -e "${RED}Arquivo não encontrado.${NC}"
        return
    fi
    read -p "Session ID (opcional, deixe vazio para anônimo): " sess
    [ -z "$sess" ] && sess="anonymous_$(date +%Y%m%d_%H%M%S)"
    upload_file "$filepath" "$sess"
}

# Submenu para listar sessões e escolher uma
menu_list_sessions() {
    print_section "📋 Listar Sessões"
    if ! list_sessions; then
        return
    fi
    read -p "Digite o número da sessão para ver mensagens (ou ENTER para voltar): " choice
    if [[ "$choice" =~ ^[0-9]+$ ]]; then
        local sessions=$(curl -s "$API_URL/sessions")
        local sess_id=$(echo "$sessions" | python3 -c "import sys, json; data=json.load(sys.stdin); print(data[int($choice)-1] if $choice-1 < len(data) else '')" 2>/dev/null)
        if [ -n "$sess_id" ]; then
            list_messages "$sess_id"
        else
            echo -e "${RED}Seleção inválida.${NC}"
        fi
    fi
}

# Submenu para consultar por hash
menu_query_hash() {
    print_section "🔍 Consultar por Hash"
    read -p "Digite o hash da mensagem: " hash
    if [ -z "$hash" ]; then
        echo -e "${RED}Hash não pode ser vazio.${NC}"
        return
    fi
    query_hash "$hash"
}

# Submenu para ver detalhes de um job
menu_job_details() {
    print_section "📄 Detalhes do Job"
    read -p "Digite o Job ID: " job_id
    if [ -z "$job_id" ]; then
        echo -e "${RED}Job ID não pode ser vazio.${NC}"
        return
    fi
    show_job "$job_id"
}

# Submenu para ver fila e health
menu_status() {
    print_section "📊 Status do Sistema"
    echo -e "${BLUE}Health:${NC}"
    curl -s "$API_URL/health" | python3 -m json.tool 2>/dev/null
    echo -e "\n${BLUE}Fila de processamento:${NC}"
    curl -s "$API_URL/queue" | python3 -m json.tool 2>/dev/null
}

# Menu principal (REPL)
main_menu() {
    clear
    echo -e "${GREEN}"
    echo "╔════════════════════════════════════════════════════════════════╗"
    echo "║           Whisper API - Interface CLI Interativa               ║"
    echo "╚════════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    if ! check_api; then
        exit 1
    fi
    while true; do
        echo -e "\n${CYAN}┌─────────────────────────────────────────────────────────┐${NC}"
        echo -e "${CYAN}│${NC}  ${GREEN}1${NC}) Gravar áudio (microfone)                              ${CYAN}│${NC}"
        echo -e "${CYAN}│${NC}  ${GREEN}2${NC}) Fazer upload de arquivo de áudio                       ${CYAN}│${NC}"
        echo -e "${CYAN}│${NC}  ${GREEN}3${NC}) Listar sessões e mensagens                             ${CYAN}│${NC}"
        echo -e "${CYAN}│${NC}  ${GREEN}4${NC}) Consultar mensagem por hash                            ${CYAN}│${NC}"
        echo -e "${CYAN}│${NC}  ${GREEN}5${NC}) Ver detalhes de um job (Job ID)                        ${CYAN}│${NC}"
        echo -e "${CYAN}│${NC}  ${GREEN}6${NC}) Ver status da fila e health check                      ${CYAN}│${NC}"
        echo -e "${CYAN}│${NC}  ${GREEN}0${NC}) Sair                                                   ${CYAN}│${NC}"
        echo -e "${CYAN}└─────────────────────────────────────────────────────────┘${NC}"
        read -p "Escolha uma opção: " opt
        case "$opt" in
            1) menu_record ;;
            2) menu_upload ;;
            3) menu_list_sessions ;;
            4) menu_query_hash ;;
            5) menu_job_details ;;
            6) menu_status ;;
            0) echo -e "${GREEN}Encerrando...${NC}"; exit 0 ;;
            *) echo -e "${RED}Opção inválida.${NC}" ;;
        esac
        echo -e "\n${YELLOW}Pressione ENTER para continuar...${NC}"
        read
        clear
    done
}

# Execução principal
main_menu
