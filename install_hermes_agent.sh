#!/usr/bin/env bash

# ==============================================================================
# Script Tự Động Cài Đặt, Cấu Hình & Quản Lý Hermes Agent (Nous Research)
# Hỗ trợ: Cài đặt Trực tiếp (Native Host) & Triển khai Docker Container
# Hỗ trợ tự động tích hợp với vLLM Server nội bộ (Port 8888) hoặc Cloud AI Providers
# Hỗ trợ: Linux (Ubuntu, Debian, CentOS, RHEL, AlmaLinux, RockyLinux) & macOS
# ==============================================================================

set -e

# Màu sắc hiển thị giao diện CLI
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
RED='\033[0;31m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
NC='\033[0m' # No Color

HERMES_CONFIG_DIR="$HOME/.hermes"
HERMES_CONFIG_FILE="$HERMES_CONFIG_DIR/config.yaml"
HERMES_DOCKER_IMAGE="nousresearch/hermes-agent:latest"
HERMES_CONTAINER_NAME="hermes-gateway"
HERMES_COMPOSE_FILE="$HERMES_CONFIG_DIR/docker-compose.yml"
VLLM_CONF="/etc/vllm/vllm.conf"
DEFAULT_VLLM_PORT="8888"

# Hiển thị banner
show_banner() {
    clear 2>/dev/null || true
    echo -e "${CYAN}${BOLD}=================================================================${NC}"
    echo -e "${CYAN}${BOLD}     HỆ THỐNG CÀI ĐẶT & CẤU HÌNH HERMES AGENT (NOUS RESEARCH)   ${NC}"
    echo -e "${CYAN}${BOLD}     Hỗ trợ Chạy Trực tiếp (Native) & Docker Container Gateway   ${NC}"
    echo -e "${CYAN}${BOLD}       Tự động kết nối vLLM (Port 8888) & Quản lý Đa nền tảng    ${NC}"
    echo -e "${CYAN}${BOLD}=================================================================${NC}\n"
}

# Phát hiện hệ điều hành
detect_os() {
    OS="$(uname -s)"
    ARCH="$(uname -m)"
    DISTRO="unknown"
    PKG_MANAGER=""

    if [ "$OS" = "Linux" ]; then
        if [ -f /etc/os-release ]; then
            . /etc/os-release
            DISTRO="${ID:-unknown}"
        elif [ -f /etc/redhat-release ]; then
            DISTRO="centos"
        elif [ -f /etc/debian_version ]; then
            DISTRO="debian"
        fi

        case "$DISTRO" in
            ubuntu|debian)
                PKG_MANAGER="apt-get"
                ;;
            centos|rhel|almalinux|rocky|fedora)
                if command -v dnf >/dev/null 2>&1; then
                    PKG_MANAGER="dnf"
                else
                    PKG_MANAGER="yum"
                fi
                ;;
            *)
                PKG_MANAGER="apt-get"
                ;;
        esac
    elif [ "$OS" = "Darwin" ]; then
        DISTRO="macos"
    fi
}

# Thêm đường dẫn PATH vào bashrc/zshrc
ensure_path() {
    local PATHS_TO_CHECK=(
        "$HOME/.local/bin"
        "$HOME/.hermes/bin"
        "/usr/local/bin"
    )

    mkdir -p "$HOME/.local/bin"

    for p in "${PATHS_TO_CHECK[@]}"; do
        if [ -d "$p" ]; then
            case ":$PATH:" in
                *":$p:"*) ;;
                *)
                    export PATH="$p:$PATH"
                    if [ -f "$HOME/.bashrc" ] && ! grep -q "$p" "$HOME/.bashrc"; then
                        echo "export PATH=\"$p:\$PATH\"" >> "$HOME/.bashrc"
                    fi
                    if [ -f "$HOME/.zshrc" ] && ! grep -q "$p" "$HOME/.zshrc"; then
                        echo "export PATH=\"$p:\$PATH\"" >> "$HOME/.zshrc"
                    fi
                    ;;
            esac
        fi
    done
}

# Cài đặt các gói phụ thuộc cơ bản
install_dependencies() {
    echo -e "${BLUE}ℹ Đang kiểm tra và cài đặt các phụ thuộc cần thiết (curl, git, python3)...${NC}"
    if [ "$OS" = "Linux" ]; then
        local SUDO_CMD=""
        if [ "$EUID" -ne 0 ]; then
            if command -v sudo >/dev/null 2>&1; then
                SUDO_CMD="sudo"
            else
                echo -e "${RED}✗ Lỗi: Cần quyền root hoặc sudo để cài đặt gói hệ thống.${NC}"
                exit 1
            fi
        fi

        if [ "$PKG_MANAGER" = "apt-get" ]; then
            $SUDO_CMD apt-get update -qq
            $SUDO_CMD apt-get install -y -qq curl git python3 python3-pip python3-venv build-essential ca-certificates
        elif [ "$PKG_MANAGER" = "dnf" ] || [ "$PKG_MANAGER" = "yum" ]; then
            $SUDO_CMD $PKG_MANAGER install -y -q curl git python3 python3-pip gcc gcc-c++ make ca-certificates
        fi
    elif [ "$OS" = "Darwin" ]; then
        if ! command -v brew >/dev/null 2>&1; then
            echo -e "${YELLOW}ℹ Khuyến nghị cài Homebrew trên macOS để quản lý môi trường tốt nhất.${NC}"
        fi
    fi
    echo -e "${GREEN}✓ Hoàn tất kiểm tra gói phụ thuộc.${NC}"
}

# Kiểm tra và đảm bảo Docker đã sẵn sàng
ensure_docker() {
    echo -e "\n${BLUE}ℹ Đang kiểm tra môi trường Docker...${NC}"
    if ! command -v docker >/dev/null 2>&1; then
        echo -e "${YELLOW}⚠ Chưa tìm thấy Docker trên hệ thống!${NC}"
        local SCRIPT_DIR
        SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

        if [ -f "$SCRIPT_DIR/install_docker.sh" ]; then
            echo -e "${CYAN}ℹ Phát hiện script cài đặt Docker trong thư mục: $SCRIPT_DIR/install_docker.sh${NC}"
            read -rp "Bạn có muốn chạy script cài đặt Docker ngay bây giờ không? [Y/n]: " RUN_DOCKER_INSTALL
            RUN_DOCKER_INSTALL="${RUN_DOCKER_INSTALL:-Y}"
            if [[ "$RUN_DOCKER_INSTALL" =~ ^[Yy]$ ]]; then
                bash "$SCRIPT_DIR/install_docker.sh"
            else
                echo -e "${RED}✗ Cần có Docker để tiếp tục tùy chọn Container.${NC}"
                return 1
            fi
        else
            read -rp "Tự động cài đặt Docker qua script chính thức (get.docker.com)? [Y/n]: " AUTO_INSTALL_DK
            AUTO_INSTALL_DK="${AUTO_INSTALL_DK:-Y}"
            if [[ "$AUTO_INSTALL_DK" =~ ^[Yy]$ ]]; then
                curl -fsSL https://get.docker.com | sh
                if [ "$EUID" -ne 0 ] && command -v sudo >/dev/null 2>&1; then
                    sudo usermod -aG docker "$USER" 2>/dev/null || true
                    sudo systemctl enable docker 2>/dev/null || true
                    sudo systemctl start docker 2>/dev/null || true
                fi
            else
                echo -e "${RED}✗ Vui lòng cài đặt Docker trước khi tiếp tục.${NC}"
                return 1
            fi
        fi
    fi

    # Kiểm tra quyền truy cập Docker daemon
    if ! docker info >/dev/null 2>&1; then
        echo -e "${YELLOW}⚠ Không thể kết nối tới Docker daemon (có thể do quyền socket). Đang thử khắc phục...${NC}"
        if [ "$EUID" -ne 0 ] && command -v sudo >/dev/null 2>&1; then
            sudo chmod 666 /var/run/docker.sock 2>/dev/null || true
            sudo systemctl start docker 2>/dev/null || true
        fi
        if ! docker info >/dev/null 2>&1; then
            echo -e "${RED}✗ Lỗi: Không thể truy cập Docker daemon. Vui lòng kiểm tra dịch vụ Docker (sudo systemctl start docker).${NC}"
            return 1
        fi
    fi

    echo -e "${GREEN}✓ Docker đã sẵn sàng hoạt động!${NC}"
    return 0
}

# Kiểm tra xem vLLM nội bộ có đang hoạt động không
check_local_vllm() {
    LOCAL_VLLM_ACTIVE=false
    DETECTED_VLLM_MODEL=""
    DETECTED_VLLM_PORT="$DEFAULT_VLLM_PORT"
    DETECTED_API_KEY=""

    if [ -f "$VLLM_CONF" ]; then
        # shellcheck disable=SC1090
        . "$VLLM_CONF" 2>/dev/null || true
        DETECTED_VLLM_MODEL="${MODEL:-}"
        DETECTED_VLLM_PORT="${PORT:-$DEFAULT_VLLM_PORT}"
        DETECTED_API_KEY="${API_KEY:-}"
    fi

    local TEST_PORTS=("$DETECTED_VLLM_PORT" "8888" "8000")
    for port in "${TEST_PORTS[@]}"; do
        MODELS_RES=$(curl -s --max-time 2 "http://127.0.0.1:${port}/v1/models" 2>/dev/null || echo "")
        if [[ "$MODELS_RES" =~ "\"id\"" ]] || [[ "$MODELS_RES" =~ "\"data\"" ]]; then
            LOCAL_VLLM_ACTIVE=true
            DETECTED_VLLM_PORT="$port"
            if [ -z "$DETECTED_VLLM_MODEL" ]; then
                DETECTED_VLLM_MODEL=$(echo "$MODELS_RES" | grep -o '"id": *"[^"]*"' | head -n 1 | cut -d '"' -f 4 || echo "custom-vllm-model")
            fi
            break
        fi
    done
}

# Tạo Docker CLI Wrapper cho lệnh `hermes` trên Host
create_docker_wrapper() {
    ensure_path
    local WRAPPER_PATH="$HOME/.local/bin/hermes"
    echo -e "${BLUE}ℹ Đang tạo CLI wrapper cho Hermes Container tại ${BOLD}${WRAPPER_PATH}${NC}...${NC}"

    cat > "$WRAPPER_PATH" << 'EOF'
#!/usr/bin/env bash
# ==============================================================================
# Hermes Agent Docker Wrapper
# Tự động chuyển tiếp các lệnh CLI vào Hermes Docker Container
# ==============================================================================

HERMES_IMAGE="nousresearch/hermes-agent:latest"
DATA_DIR="$HOME/.hermes"
mkdir -p "$DATA_DIR"

# Thiết lập network
NET_ARGS="--network host"
if [ "$(uname -s)" = "Darwin" ]; then
    NET_ARGS="-p 8642:8642 -p 9119:9119 --add-host host.docker.internal:host-gateway"
fi

exec docker run -it --rm \
    $NET_ARGS \
    -v "$DATA_DIR:/opt/data" \
    -e HERMES_UID="$(id -u)" \
    -e HERMES_GID="$(id -g)" \
    "$HERMES_IMAGE" hermes "$@"
EOF

    chmod +x "$WRAPPER_PATH"
    echo -e "${GREEN}✓ Đã tạo lệnh wrapper 'hermes' thành công! Giờ bạn có thể gõ trực tiếp 'hermes' trong terminal.${NC}"
}

# Tạo file docker-compose.yml cho Hermes Gateway
generate_docker_compose() {
    mkdir -p "$HERMES_CONFIG_DIR"
    echo -e "${BLUE}ℹ Đang tạo file cấu hình Docker Compose tại ${HERMES_COMPOSE_FILE}...${NC}"

    local NET_MODE="network_mode: host"
    local PORT_MAPPING=""
    if [ "$OS" = "macos" ]; then
        NET_MODE=""
        PORT_MAPPING="ports:
      - \"8642:8642\"
      - \"9119:9119\"
    extra_hosts:
      - \"host.docker.internal:host-gateway\""
    fi

    cat > "$HERMES_COMPOSE_FILE" <<EOF
version: '3.8'

services:
  hermes:
    image: ${HERMES_DOCKER_IMAGE}
    container_name: ${HERMES_CONTAINER_NAME}
    restart: unless-stopped
    ${NET_MODE}
    ${PORT_MAPPING}
    volumes:
      - ~/.hermes:/opt/data
    environment:
      - HERMES_UID=\${HERMES_UID:-$(id -u)}
      - HERMES_GID=\${HERMES_GID:-$(id -g)}
    command: ["gateway", "run"]
EOF

    echo -e "${GREEN}✓ Đã tạo file ${HERMES_COMPOSE_FILE}!${NC}"
}

# Triển khai Hermes Agent bằng Docker Container
install_hermes_docker() {
    echo -e "\n${CYAN}${BOLD}=== TRIỂN KHAI HERMES AGENT BẰNG DOCKER CONTAINER ===${NC}"
    
    if ! ensure_docker; then
        return 1
    fi

    echo -e "\n${BLUE}ℹ Đang tải Docker Image chính thức: ${BOLD}${HERMES_DOCKER_IMAGE}${NC}...${NC}"
    docker pull "$HERMES_DOCKER_IMAGE"
    echo -e "${GREEN}✓ Đã tải Docker Image thành công!${NC}"

    # Tạo các thư mục dữ liệu và phân quyền tránh lỗi attachment / permissions
    mkdir -p "$HERMES_CONFIG_DIR/cache/exports"
    mkdir -p "$HERMES_CONFIG_DIR/workspace"
    chmod -R 775 "$HERMES_CONFIG_DIR" 2>/dev/null || true

    # Tạo Wrapper CLI và Docker Compose
    create_docker_wrapper
    generate_docker_compose

    # Tự động cấu hình AI Provider
    auto_configure_provider

    echo -e "\n${GREEN}${BOLD}🎉 Cài đặt Hermes Agent Container thành công!${NC}"
    echo -e "   • Dữ liệu lưu trữ tại: ${CYAN}${HERMES_CONFIG_DIR}${NC}"
    echo -e "   • Docker Compose:      ${CYAN}${HERMES_COMPOSE_FILE}${NC}"
    echo -e "   • Lệnh tương tác CLI:  ${BOLD}hermes${NC}"
    echo ""

    read -rp "Bạn có muốn khởi chạy Hermes Gateway Container (chạy nền Telegram/Discord) ngay không? [y/N]: " START_GW
    if [[ "$START_GW" =~ ^[Yy]$ ]]; then
        start_gateway_container
    fi
}

# Cài đặt Hermes Agent trực tiếp trên Host (Native)
install_hermes_native() {
    install_dependencies

    echo -e "\n${BLUE}ℹ Đang cài đặt Hermes Agent thông qua script chính thức của Nous Research...${NC}"
    
    if curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash; then
        echo -e "${GREEN}✓ Đã tải và cài đặt bộ core của Hermes Agent thành công!${NC}"
    else
        echo -e "${YELLOW}⚠ Cài đặt trực tuyến gặp trục trặc, chuyển sang cài đặt qua Git + Python Virtualenv...${NC}"
        local HERMES_INSTALL_DIR="$HOME/.hermes-src"
        rm -rf "$HERMES_INSTALL_DIR"
        git clone https://github.com/NousResearch/hermes-agent.git "$HERMES_INSTALL_DIR"
        python3 -m venv "$HOME/.hermes/venv"
        # shellcheck disable=SC1091
        source "$HOME/.hermes/venv/bin/activate"
        pip install --upgrade pip
        pip install -e "$HERMES_INSTALL_DIR"
        
        mkdir -p "$HOME/.local/bin"
        ln -sf "$HOME/.hermes/venv/bin/hermes" "$HOME/.local/bin/hermes" 2>/dev/null || true
    fi

    ensure_path

    if command -v hermes >/dev/null 2>&1; then
        HERMES_VERSION=$(hermes --version 2>/dev/null || echo "Hoạt động")
        echo -e "\n${GREEN}${BOLD}🎉 Cài đặt Hermes Agent thành công! (${HERMES_VERSION})${NC}"
    else
        echo -e "\n${YELLOW}ℹ Lệnh 'hermes' đã được thêm vào PATH. Vui lòng reload shell: source ~/.bashrc${NC}"
    fi

    auto_configure_provider
}

# Tự động cấu hình kết nối tới vLLM hoặc nhà cung cấp khác
auto_configure_provider() {
    mkdir -p "$HERMES_CONFIG_DIR"
    check_local_vllm

    echo -e "\n${CYAN}${BOLD}--- CẤU HÌNH NHÀ CUNG CẤP AI (PROVIDER) CHO HERMES AGENT ---${NC}"

    if [ "$LOCAL_VLLM_ACTIVE" = true ]; then
        echo -e "\n${GREEN}${BOLD}⚡ PHÁT HIỆN MÁY CHỦ vLLM ĐANG CHẠY NỘI BỘ TẠI PORT ${DETECTED_VLLM_PORT}!${NC}"
        echo -e "   • Model nhận diện: ${CYAN}${BOLD}${DETECTED_VLLM_MODEL:-Qwen/Qwen2.5-7B-Instruct}${NC}"
        echo -e "   • Endpoint:        ${CYAN}http://127.0.0.1:${DETECTED_VLLM_PORT}/v1${NC}"
        echo ""
        read -rp "Bạn có muốn cấu hình Hermes Agent kết nối trực tiếp vào vLLM này không? [Y/n]: " USE_LOCAL_VLLM
        USE_LOCAL_VLLM="${USE_LOCAL_VLLM:-Y}"

        if [[ "$USE_LOCAL_VLLM" =~ ^[Yy]$ ]]; then
            configure_vllm_connection "$DETECTED_VLLM_PORT" "$DETECTED_VLLM_MODEL" "$DETECTED_API_KEY"
            return 0
        fi
    fi

    echo -e "\n${BOLD}Chọn nhà cung cấp AI cho Hermes Agent:${NC}"
    echo -e "   1) ${CYAN}vLLM Server nội bộ / Custom OpenAI-compatible (Port 8888)${NC} [Khuyên dùng]"
    echo -e "   2) ${CYAN}OpenRouter API${NC} (Đa dạng model Claude 3.5, GPT-4o, DeepSeek, Hermes 3)"
    echo -e "   3) ${CYAN}Nous Portal${NC} (Cổng chính thức của Nous Research)"
    echo -e "   4) ${CYAN}OpenAI Trực tiếp (GPT-4o, o1, etc.)${NC}"
    echo -e "   5) ${CYAN}Chạy Setup Wizard tương tác chính thức ('hermes setup')${NC}"
    read -rp "Lựa chọn [1-5] (Mặc định: 1): " PROVIDER_CHOICE
    PROVIDER_CHOICE="${PROVIDER_CHOICE:-1}"

    case "$PROVIDER_CHOICE" in
        1)
            read -rp "Nhập Port của vLLM [Mặc định: 8888]: " CUSTOM_PORT
            CUSTOM_PORT="${CUSTOM_PORT:-8888}"
            read -rp "Nhập tên Model [Mặc định: Qwen/Qwen2.5-7B-Instruct]: " CUSTOM_MODEL
            CUSTOM_MODEL="${CUSTOM_MODEL:-Qwen/Qwen2.5-7B-Instruct}"
            read -rp "Nhập API Key nếu có (Để trống nếu không đặt): " CUSTOM_KEY
            configure_vllm_connection "$CUSTOM_PORT" "$CUSTOM_MODEL" "$CUSTOM_KEY"
            ;;
        2)
            read -rp "Nhập OpenRouter API Key: " OR_KEY
            read -rp "Nhập Model ID [Mặc định: nousresearch/hermes-3-llama-3.1-405b]: " OR_MODEL
            OR_MODEL="${OR_MODEL:-nousresearch/hermes-3-llama-3.1-405b}"
            cat > "$HERMES_CONFIG_FILE" <<EOF
model:
  provider: "openrouter"
  default: "${OR_MODEL}"
  api_key: "${OR_KEY}"
EOF
            echo -e "${GREEN}✓ Đã lưu cấu hình OpenRouter vào ${HERMES_CONFIG_FILE}!${NC}"
            ;;
        3)
            echo -e "${BLUE}ℹ Đang mở xác thực Nous Portal...${NC}"
            if command -v hermes >/dev/null 2>&1; then
                hermes setup --portal || true
            else
                echo -e "${YELLOW}Vui lòng chạy 'hermes setup --portal' sau khi hoàn tất cài đặt.${NC}"
            fi
            ;;
        4)
            read -rp "Nhập OpenAI API Key: " OAI_KEY
            read -rp "Nhập Model [Mặc định: gpt-4o]: " OAI_MODEL
            OAI_MODEL="${OAI_MODEL:-gpt-4o}"
            cat > "$HERMES_CONFIG_FILE" <<EOF
model:
  provider: "openai"
  default: "${OAI_MODEL}"
  api_key: "${OAI_KEY}"
EOF
            echo -e "${GREEN}✓ Đã lưu cấu hình OpenAI vào ${HERMES_CONFIG_FILE}!${NC}"
            ;;
        5)
            if command -v hermes >/dev/null 2>&1; then
                hermes setup || true
            else
                echo -e "${YELLOW}Vui lòng chạy 'hermes setup' trong terminal sau khi hoàn tất.${NC}"
            fi
            ;;
    esac
}

# Ghi file cấu hình kết nối vLLM vào config.yaml
configure_vllm_connection() {
    local port="${1:-8888}"
    local model="${2:-Qwen/Qwen2.5-7B-Instruct}"
    local api_key="${3:-none}"
    if [ -z "$api_key" ]; then
        api_key="none"
    fi

    # Nếu chạy Docker trên macOS/Windows thì dùng host.docker.internal, trên Linux dùng 127.0.0.1
    local vllm_host="127.0.0.1"
    if [ "$OS" = "macos" ]; then
        vllm_host="host.docker.internal"
    fi

    mkdir -p "$HERMES_CONFIG_DIR"
    cat > "$HERMES_CONFIG_FILE" <<EOF
# Cấu hình Hermes Agent kết nối vLLM Server nội bộ
model:
  provider: "custom"
  default: "${model}"
  base_url: "http://${vllm_host}:${port}/v1"
  api_key: "${api_key}"

agent:
  auto_create_skills: true
  persist_memory: true
  workspace: "$HOME/.hermes/workspace"
EOF

    echo -e "\n${GREEN}${BOLD}✓ Đã liên kết Hermes Agent thành công với vLLM Server:${NC}"
    echo -e "   • Base URL: ${CYAN}http://${vllm_host}:${port}/v1${NC}"
    echo -e "   • Model:    ${CYAN}${model}${NC}"
    echo -e "   • Config:   ${CYAN}${HERMES_CONFIG_FILE}${NC}\n"
}

# Khởi chạy Hermes Gateway Container
start_gateway_container() {
    ensure_docker || return 1
    echo -e "\n${BLUE}ℹ Đang khởi chạy Hermes Gateway Container (${HERMES_CONTAINER_NAME})...${NC}"

    # Dừng container cũ nếu đang chạy
    if docker ps -a --format '{{.Names}}' | grep -q "^${HERMES_CONTAINER_NAME}$"; then
        echo -e "${YELLOW}ℹ Dừng và xóa container cũ...${NC}"
        docker rm -f "$HERMES_CONTAINER_NAME" >/dev/null 2>&1 || true
    fi

    local NET_OPT="--network host"
    if [ "$OS" = "macos" ]; then
        NET_OPT="-p 8642:8642 -p 9119:9119 --add-host host.docker.internal:host-gateway"
    fi

    mkdir -p "$HOME/.hermes"
    chmod -R 775 "$HOME/.hermes" 2>/dev/null || true

    # Khởi chạy container với UID/GID chuẩn của user hiện tại
    docker run -d \
        --name "$HERMES_CONTAINER_NAME" \
        --restart unless-stopped \
        $NET_OPT \
        -v "$HOME/.hermes:/opt/data" \
        -e HERMES_UID="$(id -u)" \
        -e HERMES_GID="$(id -g)" \
        "$HERMES_DOCKER_IMAGE" gateway run

    sleep 2
    if docker ps --format '{{.Names}}' | grep -q "^${HERMES_CONTAINER_NAME}$"; then
        echo -e "${GREEN}${BOLD}✓ Container ${HERMES_CONTAINER_NAME} đang chạy nền thành công!${NC}"
        echo -e "   • Xem logs: ${BOLD}docker logs -f ${HERMES_CONTAINER_NAME}${NC}"
    else
        echo -e "${RED}✗ Không thể khởi chạy container. Xem log lỗi:${NC}"
        docker logs --tail 20 "$HERMES_CONTAINER_NAME"
    fi
}

# Dừng Gateway Container
stop_gateway_container() {
    if command -v docker >/dev/null 2>&1 && docker ps -a --format '{{.Names}}' | grep -q "^${HERMES_CONTAINER_NAME}$"; then
        echo -e "${BLUE}ℹ Đang dừng container ${HERMES_CONTAINER_NAME}...${NC}"
        docker stop "$HERMES_CONTAINER_NAME" >/dev/null 2>&1 || true
        echo -e "${GREEN}✓ Đã dừng container.${NC}"
    else
        echo -e "${YELLOW}ℹ Không tìm thấy container ${HERMES_CONTAINER_NAME} đang chạy.${NC}"
    fi
}

# Quản lý Gateway Container (Menu tương tác)
manage_gateway_container() {
    while true; do
        echo -e "\n${CYAN}${BOLD}=== QUẢN LÝ HERMES GATEWAY CONTAINER ===${NC}"
        local STATUS="${RED}Đã dừng / Chưa tạo${NC}"
        if command -v docker >/dev/null 2>&1 && docker ps --format '{{.Names}}' | grep -q "^${HERMES_CONTAINER_NAME}$"; then
            STATUS="${GREEN}Đang hoạt động (Running)${NC}"
        fi
        echo -e "Trạng thái Container [${HERMES_CONTAINER_NAME}]: ${STATUS}\n"
        echo -e "   1) ${GREEN}Khởi chạy / Restart Gateway Container${NC}"
        echo -e "   2) ${RED}Dừng Gateway Container${NC}"
        echo -e "   3) ${YELLOW}Xem Logs Container thời gian thực (docker logs -f)${NC}"
        echo -e "   4) Mở Terminal bên trong Container (Bash shell)"
        echo -e "   5) Cập nhật Docker Image mới nhất (docker pull)"
        echo -e "   0) Quay lại Menu chính"
        echo ""
        read -rp "Lựa chọn [0-5]: " GW_CHOICE

        case "$GW_CHOICE" in
            1)
                start_gateway_container
                ;;
            2)
                stop_gateway_container
                ;;
            3)
                echo -e "${YELLOW}(Nhấn Ctrl+C để thoát chế độ xem log)${NC}"
                docker logs -f --tail 100 "$HERMES_CONTAINER_NAME" 2>/dev/null || echo -e "${RED}Container chưa chạy.${NC}"
                ;;
            4)
                if docker ps --format '{{.Names}}' | grep -q "^${HERMES_CONTAINER_NAME}$"; then
                    docker exec -it "$HERMES_CONTAINER_NAME" bash || docker exec -it "$HERMES_CONTAINER_NAME" sh
                else
                    echo -e "${RED}Container không chạy.${NC}"
                fi
                ;;
            5)
                ensure_docker && docker pull "$HERMES_DOCKER_IMAGE"
                ;;
            0)
                break
                ;;
            *)
                echo -e "${RED}Lựa chọn không hợp lệ.${NC}"
                ;;
        esac
    done
}

# Kiểm tra trạng thái và kết nối
check_status() {
    ensure_path
    echo -e "\n${CYAN}${BOLD}=== KIỂM TRA TRẠNG THÁI HERMES AGENT & LIÊN KẾT vLLM ===${NC}\n"

    # Kiểm tra lệnh hermes
    if command -v hermes >/dev/null 2>&1; then
        echo -e "${GREEN}✓ Lệnh 'hermes' đã được cài đặt:${NC} $(which hermes)"
        hermes --version 2>/dev/null || true
    else
        echo -e "${YELLOW}⚠ Chưa tìm thấy lệnh 'hermes' trong PATH hiện tại.${NC}"
    fi

    # Kiểm tra Docker Container
    if command -v docker >/dev/null 2>&1; then
        echo -e "\n${BLUE}ℹ Trạng thái Docker:${NC}"
        if docker ps -a --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' | grep -q "$HERMES_CONTAINER_NAME"; then
            echo -e "${GREEN}✓ Tìm thấy Hermes Container:${NC}"
            docker ps -a --filter "name=$HERMES_CONTAINER_NAME" --format '   • Tên: {{.Names}} | Trạng thái: {{.Status}} | Image: {{.Image}}'
        else
            echo -e "   • Chưa có container ${HERMES_CONTAINER_NAME} nào được tạo."
        fi
    fi

    # Kiểm tra file config
    echo -e "\n${BLUE}ℹ Kiểm tra cấu hình (${HERMES_CONFIG_FILE}):${NC}"
    if [ -f "$HERMES_CONFIG_FILE" ]; then
        echo -e "${GREEN}✓ Đã tìm thấy file cấu hình:${NC}"
        cat "$HERMES_CONFIG_FILE"
    else
        echo -e "${YELLOW}⚠ Chưa có file cấu hình ~/.hermes/config.yaml${NC}"
    fi

    # Kiểm tra vLLM
    echo -e "\n${BLUE}ℹ Kiểm tra khả năng kết nối tới vLLM Server nội bộ:${NC}"
    check_local_vllm
    if [ "$LOCAL_VLLM_ACTIVE" = true ]; then
        echo -e "${GREEN}✓ vLLM Server đang hoạt động tốt trên Port ${DETECTED_VLLM_PORT}!${NC}"
        echo -e "   Model: ${BOLD}${DETECTED_VLLM_MODEL}${NC}"
    else
        echo -e "${YELLOW}⚠ Không phát hiện vLLM Server phản hồi trên port 8888 hoặc 8000.${NC}"
        echo -e "   (Bạn có thể chạy script ${BOLD}./install_vllm.sh${NC} để khởi động vLLM).${NC}"
    fi
    echo ""
}

# Chạy Hermes Agent tương tác CLI
run_hermes_interactive() {
    ensure_path
    if ! command -v hermes >/dev/null 2>&1; then
        echo -e "${RED}✗ Lỗi: Chưa tìm thấy lệnh 'hermes'. Hãy cài đặt bằng Mục 1 hoặc Mục 2 trước.${NC}"
        return 1
    fi

    echo -e "\n${GREEN}${BOLD}🚀 ĐANG KHỞI ĐỘNG HERMES AGENT CLI...${NC}"
    echo -e "${YELLOW}(Gõ /exit hoặc Ctrl+C để thoát khỏi phiên chat với agent)${NC}\n"
    hermes
}

# Cấu hình Gateway (Telegram, Discord, Slack)
setup_gateway() {
    ensure_path
    echo -e "\n${CYAN}${BOLD}=== THIẾT LẬP GATEWAY KẾT NỐI TIN NHẮN (TELEGRAM / DISCORD / SLACK) ===${NC}"
    echo -e "Hermes Agent hỗ trợ kết nối trực tiếp với Bot Telegram, Discord hoặc Slack để bạn chat điều khiển từ xa."
    echo ""
    if command -v hermes >/dev/null 2>&1; then
        hermes gateway setup || true
    else
        echo -e "${RED}✗ Chưa tìm thấy lệnh hermes. Vui lòng cài đặt trước.${NC}"
    fi
}

# Xem logs (Host hoặc Container)
view_logs() {
    echo -e "\n${CYAN}${BOLD}=== XEM LOGS HERMES GATEWAY ===${NC}"
    echo -e "   1) Xem Docker logs (${HERMES_CONTAINER_NAME})"
    echo -e "   2) Xem File logs Host (~/.hermes/logs/gateway.log)"
    echo -e "   0) Quay lại"
    read -rp "Lựa chọn [0-2]: " LOG_C

    case "$LOG_C" in
        1)
            if command -v docker >/dev/null 2>&1; then
                echo -e "${YELLOW}(Nhấn Ctrl+C để thoát)${NC}"
                docker logs -f --tail 100 "$HERMES_CONTAINER_NAME" 2>/dev/null || echo -e "${RED}Container chưa được tạo.${NC}"
            fi
            ;;
        2)
            if [ -f "$HOME/.hermes/logs/gateway.log" ]; then
                echo -e "${YELLOW}(Nhấn Ctrl+C để thoát)${NC}"
                tail -n 100 -f "$HOME/.hermes/logs/gateway.log"
            else
                echo -e "${YELLOW}Chưa có file log tại ~/.hermes/logs/gateway.log${NC}"
            fi
            ;;
        *)
            ;;
    esac
}

# Gỡ bỏ Hermes Agent
uninstall_hermes() {
    echo -e "\n${RED}${BOLD}⚠ CẢNH BÁO: BẠN CÓ CHẮC CHẮN MUỐN GỠ BỎ HERMES AGENT?${NC}"
    read -rp "Xác nhận gỡ bỏ? (gõ 'yes' để xác nhận): " CONFIRM
    if [ "$CONFIRM" != "yes" ]; then
        echo -e "${YELLOW}Hủy bỏ thao tác gỡ bỏ.${NC}"
        return 0
    fi

    echo -e "\n${BLUE}ℹ Đang dọn dẹp các tiến trình và Container...${NC}"
    if command -v docker >/dev/null 2>&1; then
        docker rm -f "$HERMES_CONTAINER_NAME" >/dev/null 2>&1 || true
    fi

    pkill -f "hermes gateway" 2>/dev/null || true

    echo -e "${BLUE}ℹ Đang dọn dẹp các thư mục Hermes Agent...${NC}"
    rm -rf "$HOME/.hermes"
    rm -rf "$HOME/.hermes-src"
    rm -f "$HOME/.local/bin/hermes"
    rm -f "/usr/local/bin/hermes" 2>/dev/null || true

    echo -e "${GREEN}✓ Đã gỡ bỏ thành công Hermes Agent khỏi máy chủ!${NC}\n"
}

# Menu chính
main_menu() {
    show_banner
    detect_os
    ensure_path

    echo -e "${BOLD}Chọn tác vụ bạn muốn thực hiện:${NC}"
    echo -e "   1) ${MAGENTA}${BOLD}Triển khai Hermes Agent bằng DOCKER CONTAINER [Khuyên dùng cho Server]${NC}"
    echo -e "   2) ${GREEN}Cài đặt Hermes Agent trực tiếp trên máy chủ (Native Python/Host)${NC}"
    echo -e "   3) ${CYAN}Liên kết nhanh Hermes Agent với vLLM nội bộ (Port 8888)${NC}"
    echo -e "   4) ${GREEN}${BOLD}Chạy Hermes Agent tương tác trực tiếp CLI ('hermes')${NC}"
    echo -e "   5) ${BLUE}Quản lý Gateway Container chạy nền (Telegram / Discord)${NC}"
    echo -e "   6) ${YELLOW}Kiểm tra trạng thái cài đặt, Docker & kết nối vLLM${NC}"
    echo -e "   7) Thiết lập Gateway tin nhắn ('hermes gateway setup')"
    echo -e "   8) Đổi Model / Nhà cung cấp AI ('hermes model')"
    echo -e "   9) Quản lý Công cụ & Skills ('hermes tools')"
    echo -e "   10) Xem Logs Gateway (Container / Host)"
    echo -e "   11) ${RED}Gỡ bỏ Hermes Agent${NC}"
    echo -e "   0) Thoát"

    echo ""
    read -rp "Nhập lựa chọn của bạn [0-11] (Mặc định: 1): " MENU_CHOICE
    MENU_CHOICE="${MENU_CHOICE:-1}"

    case "$MENU_CHOICE" in
        1)
            install_hermes_docker
            ;;
        2)
            install_hermes_native
            ;;
        3)
            check_local_vllm
            if [ "$LOCAL_VLLM_ACTIVE" = true ]; then
                configure_vllm_connection "$DETECTED_VLLM_PORT" "$DETECTED_VLLM_MODEL" "$DETECTED_API_KEY"
            else
                read -rp "Nhập Port của vLLM [Mặc định: 8888]: " P
                P="${P:-8888}"
                read -rp "Nhập tên Model [Mặc định: Qwen/Qwen2.5-7B-Instruct]: " M
                M="${M:-Qwen/Qwen2.5-7B-Instruct}"
                read -rp "Nhập API Key nếu có (Để trống nếu không dùng): " K
                configure_vllm_connection "$P" "$M" "$K"
            fi
            ;;
        4)
            run_hermes_interactive
            ;;
        5)
            manage_gateway_container
            ;;
        6)
            check_status
            ;;
        7)
            setup_gateway
            ;;
        8)
            if command -v hermes >/dev/null 2>&1; then
                hermes model || true
            else
                auto_configure_provider
            fi
            ;;
        9)
            if command -v hermes >/dev/null 2>&1; then
                hermes tools || true
            else
                echo -e "${YELLOW}Vui lòng cài đặt Hermes Agent trước.${NC}"
            fi
            ;;
        10)
            view_logs
            ;;
        11)
            uninstall_hermes
            ;;
        0)
            echo -e "${GREEN}Tạm biệt!${NC}\n"
            exit 0
            ;;
        *)
            echo -e "${RED}Lựa chọn không hợp lệ.${NC}"
            ;;
    esac
}

# Điểm khởi chạy
main_menu
