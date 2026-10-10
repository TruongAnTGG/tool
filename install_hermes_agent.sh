#!/usr/bin/env bash

# ==============================================================================
# Script Tự Động Cài Đặt, Cấu Hình & Quản Lý Hermes Agent (Nous Research)
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
VLLM_CONF="/etc/vllm/vllm.conf"
DEFAULT_VLLM_PORT="8888"

# Hiển thị banner
show_banner() {
    clear 2>/dev/null || true
    echo -e "${CYAN}${BOLD}=================================================================${NC}"
    echo -e "${CYAN}${BOLD}     HỆ THỐNG CÀI ĐẶT & CẤU HÌNH HERMES AGENT (NOUS RESEARCH)   ${NC}"
    echo -e "${CYAN}${BOLD}       Autonomous AI Agent - Kết nối vLLM (Port 8888) & Gateway  ${NC}"
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

# Thêm đường dẫn PATH vào bashrc/zshrc
ensure_path() {
    local PATHS_TO_CHECK=(
        "$HOME/.local/bin"
        "$HOME/.hermes/bin"
        "/usr/local/bin"
    )

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

# Kiểm tra xem vLLM nội bộ có đang hoạt động không
check_local_vllm() {
    LOCAL_VLLM_ACTIVE=false
    DETECTED_VLLM_MODEL=""
    DETECTED_VLLM_PORT="$DEFAULT_VLLM_PORT"
    DETECTED_API_KEY=""

    # 1. Kiểm tra qua config file nếu tồn tại
    if [ -f "$VLLM_CONF" ]; then
        # shellcheck disable=SC1090
        . "$VLLM_CONF" 2>/dev/null || true
        DETECTED_VLLM_MODEL="${MODEL:-}"
        DETECTED_VLLM_PORT="${PORT:-$DEFAULT_VLLM_PORT}"
        DETECTED_API_KEY="${API_KEY:-}"
    fi

    # 2. Thử truy vấn endpoint /v1/models trên port đã cấu hình hoặc 8888
    local TEST_PORTS=("$DETECTED_VLLM_PORT" "8888" "8000")
    for port in "${TEST_PORTS[@]}"; do
        MODELS_RES=$(curl -s --max-time 2 "http://127.0.0.1:${port}/v1/models" 2>/dev/null || echo "")
        if [[ "$MODELS_RES" =~ "\"id\"" ]] || [[ "$MODELS_RES" =~ "\"data\"" ]]; then
            LOCAL_VLLM_ACTIVE=true
            DETECTED_VLLM_PORT="$port"
            # Lấy tên model đầu tiên từ json nếu chưa có
            if [ -z "$DETECTED_VLLM_MODEL" ]; then
                DETECTED_VLLM_MODEL=$(echo "$MODELS_RES" | grep -o '"id": *"[^"]*"' | head -n 1 | cut -d '"' -f 4 || echo "custom-vllm-model")
            fi
            break
        fi
    done
}

# Cài đặt Hermes Agent
install_hermes() {
    install_dependencies

    echo -e "\n${BLUE}ℹ Đang cài đặt Hermes Agent thông qua script chính thức của Nous Research...${NC}"
    
    # Chạy official installer
    if curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash; then
        echo -e "${GREEN}✓ Đã tải và cài đặt bộ core của Hermes Agent thành công!${NC}"
    else
        echo -e "${YELLOW}⚠ Cài đặt bằng script trực tuyến gặp trục trặc, chuyển sang cài đặt qua Git + Python Virtualenv...${NC}"
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
        echo -e "\n${YELLOW}ℹ Lệnh 'hermes' đã được cài vào profile. Vui lòng chạy:${NC} ${BOLD}source ~/.bashrc${NC} (hoặc ~/.zshrc)"
    fi

    # Cấu hình tự động
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
            echo -e "${BLUE}ℹ Đang mở xác thực Nous Portal qua trình duyệt hoặc mã code...${NC}"
            if command -v hermes >/dev/null 2>&1; then
                hermes setup --portal || true
            else
                echo -e "${YELLOW}Vui lòng chạy 'hermes setup --portal' sau khi reload shell.${NC}"
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
                echo -e "${YELLOW}Vui lòng chạy 'hermes setup' trong terminal.${NC}"
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

    mkdir -p "$HERMES_CONFIG_DIR"
    cat > "$HERMES_CONFIG_FILE" <<EOF
# Cấu hình Hermes Agent kết nối vLLM Server nội bộ
model:
  provider: "custom"
  default: "${model}"
  base_url: "http://127.0.0.1:${port}/v1"
  api_key: "${api_key}"

agent:
  auto_create_skills: true
  persist_memory: true
  workspace: "$HOME/.hermes/workspace"
EOF

    echo -e "\n${GREEN}${BOLD}✓ Đã liên kết Hermes Agent thành công với vLLM Server:${NC}"
    echo -e "   • Base URL: ${CYAN}http://127.0.0.1:${port}/v1${NC}"
    echo -e "   • Model:    ${CYAN}${model}${NC}"
    echo -e "   • Config:   ${CYAN}${HERMES_CONFIG_FILE}${NC}\n"
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
        echo -e "${RED}✗ Không tìm thấy lệnh 'hermes' trong PATH hiện tại.${NC}"
        echo -e "${YELLOW}ℹ Gợi ý: Hãy chạy lệnh:${NC} ${BOLD}source ~/.bashrc${NC} ${YELLOW}hoặc chạy lại mục 1 để cài đặt.${NC}"
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

# Chạy Hermes Agent tương tác
run_hermes_interactive() {
    ensure_path
    if ! command -v hermes >/dev/null 2>&1; then
        echo -e "${RED}✗ Lỗi: Chưa tìm thấy lệnh 'hermes'. Hãy chạy cài đặt trước (Mục 1).${NC}"
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

# Gỡ bỏ Hermes Agent
uninstall_hermes() {
    echo -e "\n${RED}${BOLD}⚠ CẢNH BÁO: BẠN CÓ CHẮC CHẮN MUỐN GỠ BỎ HERMES AGENT?${NC}"
    read -rp "Xác nhận gỡ bỏ? (gõ 'yes' để xác nhận): " CONFIRM
    if [ "$CONFIRM" != "yes" ]; then
        echo -e "${YELLOW}Hủy bỏ thao tác gỡ bỏ.${NC}"
        return 0
    fi

    echo -e "\n${BLUE}ℹ Đang dọn dẹp các thư mục Hermes Agent...${NC}"
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
    echo -e "   1) ${GREEN}${BOLD}Cài đặt Hermes Agent (Official Nous Research Installer)${NC}"
    echo -e "   2) ${CYAN}Liên kết nhanh Hermes Agent với vLLM nội bộ (Port 8888)${NC}"
    echo -e "   3) ${GREEN}Chạy Hermes Agent tương tác trực tiếp ('hermes')${NC}"
    echo -e "   4) ${YELLOW}Kiểm tra trạng thái cài đặt & kết nối vLLM${NC}"
    echo -e "   5) ${MAGENTA}Thiết lập Gateway tin nhắn (Telegram / Discord / Slack)${NC}"
    echo -e "   6) Đổi Model / Nhà cung cấp AI ('hermes model')${NC}"
    echo -e "   7) Quản lý Công cụ & Skills ('hermes tools')${NC}"
    echo -e "   8) ${RED}Gỡ bỏ Hermes Agent${NC}"
    echo -e "   0) Thoát"

    echo ""
    read -rp "Nhập lựa chọn của bạn [0-8] (Mặc định: 1): " MENU_CHOICE
    MENU_CHOICE="${MENU_CHOICE:-1}"

    case "$MENU_CHOICE" in
        1)
            install_hermes
            ;;
        2)
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
        3)
            run_hermes_interactive
            ;;
        4)
            check_status
            ;;
        5)
            setup_gateway
            ;;
        6)
            if command -v hermes >/dev/null 2>&1; then
                hermes model || true
            else
                auto_configure_provider
            fi
            ;;
        7)
            if command -v hermes >/dev/null 2>&1; then
                hermes tools || true
            else
                echo -e "${YELLOW}Vui lòng cài đặt Hermes Agent trước.${NC}"
            fi
            ;;
        8)
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
