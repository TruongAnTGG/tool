#!/usr/bin/env bash

# ==============================================================================
# Script Tự Động Cài Đặt, Cấu Hình & Quản Lý SearXNG (Privacy Metasearch Engine)
# Triển khai bằng Docker & Docker Compose kèm Redis Cache
# Mở cổng truy cập (Mặc định: 8080) & Kích hoạt JSON API cho AI Agents (Hermes, Dify,...)
# Hỗ trợ: Ubuntu, Debian, CentOS, RHEL, AlmaLinux, RockyLinux
# ==============================================================================

set -e

# Màu sắc hiển thị
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
RED='\033[0;31m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# Thư mục cài đặt mặc định
INSTALL_DIR="/opt/searxng"
CONFIG_FILE="$INSTALL_DIR/settings.yml"
COMPOSE_FILE="$INSTALL_DIR/docker-compose.yml"
ENV_FILE="$INSTALL_DIR/.env"
DEFAULT_PORT="8080"

# Hiển thị banner
show_banner() {
    clear 2>/dev/null || true
    echo -e "${CYAN}${BOLD}=================================================================${NC}"
    echo -e "${CYAN}${BOLD}     HỆ THỐNG CÀI ĐẶT & QUẢN LÝ SEARXNG METASEARCH ENGINE        ${NC}"
    echo -e "${CYAN}${BOLD}   Tích hợp Docker, Redis Cache & JSON API cho AI Agents (Hermes) ${NC}"
    echo -e "${CYAN}${BOLD}=================================================================${NC}\n"
}

# Kiểm tra quyền root
check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}✗ Lỗi: Script yêu cầu quyền root để cài đặt Docker và mở Firewall.${NC}"
        echo -e "${YELLOW}ℹ Vui lòng chạy lại bằng lệnh:${NC} ${BOLD}sudo bash $0${NC}\n"
        exit 1
    fi
}

# Phát hiện hệ điều hành
detect_os() {
    OS="$(uname -s)"
    ARCH="$(uname -m)"
    DISTRO="unknown"
    PKG_MANAGER=""

    if [ "$OS" != "Linux" ]; then
        echo -e "${RED}✗ Lỗi: SearXNG Server nên được triển khai trên máy chủ Linux.${NC}"
        echo -e "${YELLOW}Hệ điều hành hiện tại: $OS ($ARCH)${NC}\n"
        exit 1
    fi

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
}

# Lấy địa chỉ IP máy chủ
get_server_ips() {
    LOCAL_IP=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "127.0.0.1")
    PUBLIC_IP=$(curl -s4 --max-time 3 https://ifconfig.me 2>/dev/null || \
                curl -s4 --max-time 3 https://api.ipify.org 2>/dev/null || \
                curl -s4 --max-time 3 https://icanhazip.com 2>/dev/null || \
                echo "$LOCAL_IP")
}

# Mở Firewall Port (UFW, Firewalld, iptables)
open_firewall_port() {
    local port="${1:-$DEFAULT_PORT}"
    echo -e "\n${BLUE}ℹ Đang kiểm tra và mở tường lửa cho Port ${BOLD}${port}/tcp${NC}...${NC}"

    local opened=false

    # 1. UFW (Ubuntu/Debian)
    if command -v ufw >/dev/null 2>&1; then
        UFW_STATUS=$(ufw status 2>/dev/null | grep -i "Status: active" || true)
        if [ -n "$UFW_STATUS" ]; then
            ufw allow "${port}/tcp" comment "SearXNG Metasearch" >/dev/null 2>&1 || ufw allow "${port}" >/dev/null 2>&1
            ufw reload >/dev/null 2>&1 || true
            echo -e "   ${GREEN}✓ Đã mở port ${port} trên UFW!${NC}"
            opened=true
        fi
    fi

    # 2. Firewalld (CentOS, RHEL, Rocky, AlmaLinux)
    if command -v firewall-cmd >/dev/null 2>&1; then
        if systemctl is-active --quiet firewalld 2>/dev/null; then
            firewall-cmd --permanent --add-port="${port}/tcp" >/dev/null 2>&1 || true
            firewall-cmd --reload >/dev/null 2>&1 || true
            echo -e "   ${GREEN}✓ Đã mở port ${port} trên Firewalld!${NC}"
            opened=true
        fi
    fi

    # 3. Iptables fallback
    if command -v iptables >/dev/null 2>&1; then
        if ! iptables -C INPUT -p tcp --dport "${port}" -j ACCEPT >/dev/null 2>&1; then
            iptables -I INPUT -p tcp --dport "${port}" -j ACCEPT >/dev/null 2>&1 || true
        fi
        opened=true
    fi

    if [ "$opened" = true ]; then
        echo -e "${GREEN}✓ Hoàn tất cấu hình tường lửa cho cổng ${port}/tcp.${NC}"
    else
        echo -e "${YELLOW}ℹ Không phát hiện firewall nội bộ chặn port ${port}.${NC}"
    fi

    echo -e "${MAGENTA}${BOLD}👉 LƯU Ý VỀ CLOUD VPS:${NC}"
    echo -e "   Nếu bạn dùng AWS EC2, GCP, Azure, Oracle, DigitalOcean: Hãy mở ${BOLD}Inbound Port ${port}/tcp${NC}"
    echo -e "   trên trang quản trị Security Group / Firewall Rules của nhà cung cấp.\n"
}

# Cài đặt Docker & Docker Compose nếu chưa có
ensure_docker_and_compose() {
    echo -e "${BLUE}ℹ Đang kiểm tra Docker & Docker Compose...${NC}"
    if ! command -v docker >/dev/null 2>&1; then
        echo -e "${YELLOW}ℹ Chưa tìm thấy Docker, đang tiến hành cài đặt Docker Engine chính thức...${NC}"
        curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
        sh /tmp/get-docker.sh
        rm -f /tmp/get-docker.sh
        systemctl enable --now docker
        echo -e "${GREEN}✓ Cài đặt Docker thành công!${NC}"
    fi

    systemctl start docker 2>/dev/null || true

    # Kiểm tra Docker Compose plugin hoặc standalone
    if ! docker compose version >/dev/null 2>&1 && ! command -v docker-compose >/dev/null 2>&1; then
        echo -e "${YELLOW}ℹ Đang cài đặt Docker Compose plugin...${NC}"
        if [ "$PKG_MANAGER" = "apt-get" ]; then
            apt-get update -qq
            apt-get install -y -qq docker-compose-plugin || true
        elif [ "$PKG_MANAGER" = "dnf" ] || [ "$PKG_MANAGER" = "yum" ]; then
            $PKG_MANAGER install -y -q docker-compose-plugin || true
        fi
    fi
    echo -e "${GREEN}✓ Docker & Docker Compose đã sẵn sàng.${NC}"
}

# Lệnh chạy docker compose tương thích
run_compose() {
    if docker compose version >/dev/null 2>&1; then
        docker compose "$@"
    else
        docker-compose "$@"
    fi
}

# Đọc cấu hình hiện tại
load_config() {
    if [ -f "$ENV_FILE" ]; then
        # shellcheck disable=SC1090
        . "$ENV_FILE" 2>/dev/null || true
    fi
    PORT="${SEARXNG_PORT:-$DEFAULT_PORT}"
}

# Tạo cấu hình settings.yml chuẩn cho SearXNG
generate_settings_yaml() {
    local secret_key="$1"
    
    mkdir -p "$INSTALL_DIR"
    cat > "$CONFIG_FILE" <<EOF
# SearXNG configuration generated by install_searxng.sh
use_default_settings: true

general:
  debug: false
  instance_name: "SearXNG Private Search"

server:
  port: 8080
  bind_address: "0.0.0.0"
  secret_key: "${secret_key}"
  limiter: false           # Tắt giới hạn rate-limit để phục vụ AI Agents (Hermes, Dify, LangChain)
  image_proxy: true
  method: "GET"

search:
  safe_search: 0
  autocomplete: ""
  formats:
    - html
    - json                 # Cho phép xuất định dạng JSON cho API và AI Agents

redis:
  url: redis://redis:6379/0

ui:
  static_use_hash: true
  default_locale: "en"
  query_in_title: true
  infinite_scroll: false
  center_alignment: true
  default_theme: simple
  theme_args:
    simple_style: auto
EOF
    chmod 644 "$CONFIG_FILE"
}

# Tạo docker-compose.yml
generate_docker_compose() {
    local port="$1"

    cat > "$COMPOSE_FILE" <<EOF
services:
  redis:
    image: redis:alpine
    container_name: searxng-redis
    restart: unless-stopped
    command: redis-server --save "" --appendonly no
    tmpfs:
      - /var/lib/redis
    cap_drop:
      - ALL
    cap_add:
      - SETGID
      - SETUID
      - DAC_OVERRIDE
    logging:
      driver: "json-file"
      options:
        max-size: "1m"
        max-file: "1"

  searxng:
    image: searxng/searxng:latest
    container_name: searxng
    restart: unless-stopped
    ports:
      - "0.0.0.0:${port}:8080"
    volumes:
      - ./settings.yml:/etc/searxng/settings.yml:ro
    environment:
      - SEARXNG_BASE_URL=http://localhost:${port}/
    depends_on:
      - redis
    cap_drop:
      - ALL
    cap_add:
      - CHOWN
      - SETGID
      - SETUID
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"
EOF
    chmod 644 "$COMPOSE_FILE"
}

# Cài đặt và triển khai SearXNG
deploy_searxng() {
    ensure_docker_and_compose
    detect_os
    mkdir -p "$INSTALL_DIR"
    cd "$INSTALL_DIR"

    echo -e "\n${CYAN}${BOLD}--- CẤU HÌNH THÔNG SỐ SEARXNG ---${NC}\n"

    # Nhập cổng
    read -rp "$(echo -e "${BOLD}1. Cổng lắng nghe (Port)${NC} [Mặc định: ${GREEN}${DEFAULT_PORT}${NC}]: ")" INPUT_PORT
    PORT="${INPUT_PORT:-$DEFAULT_PORT}"

    # Tạo Secret Key ngẫu nhiên an toàn
    echo -e "\n${BLUE}ℹ Đang sinh chuỗi Secret Key ngẫu nhiên 32-byte...${NC}"
    if command -v openssl >/dev/null 2>&1; then
        SECRET_KEY=$(openssl rand -hex 32)
    else
        SECRET_KEY=$(python3 -c "import secrets; print(secrets.token_bytes(32).hex())" 2>/dev/null || date +%s | sha256sum | head -c 64)
    fi

    # Ghi file .env
    cat > "$ENV_FILE" <<EOF
SEARXNG_PORT=${PORT}
SEARXNG_SECRET=${SECRET_KEY}
EOF
    chmod 600 "$ENV_FILE"

    # Tạo settings.yml và docker-compose.yml
    generate_settings_yaml "$SECRET_KEY"
    generate_docker_compose "$PORT"

    # Mở tường lửa
    open_firewall_port "$PORT"

    # Dừng các container cũ nếu có
    if [ -f "$COMPOSE_FILE" ]; then
        run_compose down 2>/dev/null || true
    fi

    echo -e "\n${BLUE}ℹ Đang tải Image SearXNG & Redis và khởi chạy container...${NC}"
    run_compose pull
    run_compose up -d

    echo -e "\n${GREEN}${BOLD}✓ Khởi tạo SearXNG thành công!${NC}"
    post_install_guide
}

# Hướng dẫn chi tiết sau khi cài đặt
post_install_guide() {
    load_config
    get_server_ips

    echo -e "\n${CYAN}${BOLD}=================================================================${NC}"
    echo -e "${GREEN}${BOLD}         🎉 CÀI ĐẶT & KHỞI CHẠY SEARXNG THÀNH CÔNG!              ${NC}"
    echo -e "${CYAN}${BOLD}=================================================================${NC}\n"

    echo -e "${BOLD}📌 THÔNG TIN TRUY CẬP:${NC}"
    echo -e "   • Giao diện Web (Browser):    ${GREEN}${BOLD}http://${PUBLIC_IP}:${PORT}${NC}"
    echo -e "   • Giao diện Web (Nội bộ/LAN): ${GREEN}${BOLD}http://${LOCAL_IP}:${PORT}${NC}"
    echo -e "   • Localhost:                 ${GREEN}http://127.0.0.1:${PORT}${NC}"
    echo -e "   • Định dạng JSON API:         ${CYAN}ĐÃ KÍCH HOẠT (Hỗ trợ AI Agents)${NC}"

    echo -e "\n${BOLD}📋 LỆNH QUẢN LÝ DỊCH VỤ:${NC}"
    echo -e "   • Thư mục cài đặt:   ${BOLD}cd ${INSTALL_DIR}${NC}"
    echo -e "   • Xem live logs:     ${BOLD}cd ${INSTALL_DIR} && docker compose logs -f${NC}"
    echo -e "   • Kiểm tra trạng thái: ${BOLD}cd ${INSTALL_DIR} && docker compose ps${NC}"
    echo -e "   • Khởi động lại:     ${BOLD}cd ${INSTALL_DIR} && docker compose restart${NC}"
    echo -e "   • Dừng dịch vụ:      ${BOLD}cd ${INSTALL_DIR} && docker compose stop${NC}"

    echo -e "\n${BOLD}🤖 CẤU HÌNH TÍCH HỢP CHO AI AGENT (HERMES AGENT / DIFY / OPEN WEBUI):${NC}"
    echo -e "   • SearXNG URL: ${CYAN}${BOLD}http://${PUBLIC_IP}:${PORT}${NC} hoặc ${CYAN}http://127.0.0.1:${PORT}${NC}"
    echo -e "   • Ví dụ gọi tìm kiếm JSON bằng cURL:"
    echo -e "     ${YELLOW}curl \"http://${PUBLIC_IP}:${PORT}/search?q=AI+news&format=json\"${NC}"
    echo -e "\n${CYAN}=================================================================${NC}\n"
}

# Kiểm tra trạng thái SearXNG
check_status() {
    load_config
    get_server_ips

    echo -e "\n${CYAN}${BOLD}=== KIỂM TRA TRẠNG THÁI SEARXNG ===${NC}\n"

    if [ -d "$INSTALL_DIR" ]; then
        cd "$INSTALL_DIR"
        run_compose ps
    else
        echo -e "${RED}✗ Chưa tìm thấy thư mục cài đặt tại ${INSTALL_DIR}.${NC}"
        return 1
    fi

    echo -e "\n${BLUE}ℹ Kiểm tra Port ${PORT}:${NC}"
    if command -v ss >/dev/null 2>&1; then
        PORT_CHECK=$(ss -tlpn 2>/dev/null | grep ":${PORT} " || true)
    elif command -v netstat >/dev/null 2>&1; then
        PORT_CHECK=$(netstat -tlpn 2>/dev/null | grep ":${PORT} " || true)
    else
        PORT_CHECK=""
    fi

    if [ -n "$PORT_CHECK" ]; then
        echo -e "${GREEN}✓ Port ${PORT} đang lắng nghe bình thường!${NC}"
    else
        echo -e "${YELLOW}⚠ Chưa thấy Port ${PORT} mở. Kiểm tra lại log container.${NC}"
    fi

    # Thử gọi kiểm tra HTTP
    echo -e "\n${BLUE}ℹ Kiểm tra phản hồi HTTP từ SearXNG...${NC}"
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 3 "http://127.0.0.1:${PORT}" 2>/dev/null || echo "000")
    if [ "$HTTP_CODE" = "200" ]; then
        echo -e "${GREEN}✓ SearXNG phản hồi HTTP 200 OK! Sẵn sàng phục vụ.${NC}"
    else
        echo -e "${YELLOW}⚠ Phản hồi HTTP: ${HTTP_CODE}. Vui lòng kiểm tra lại logs.${NC}"
    fi
}

# Xem live logs
view_logs() {
    if [ -d "$INSTALL_DIR" ]; then
        cd "$INSTALL_DIR"
        echo -e "\n${BLUE}ℹ Đang mở live log (Nhấn Ctrl+C để thoát)...${NC}\n"
        run_compose logs -f
    else
        echo -e "${RED}✗ Chưa tìm thấy thư mục cài đặt ${INSTALL_DIR}.${NC}"
    fi
}

# Thử nghiệm tìm kiếm qua API JSON
test_search() {
    load_config
    echo -e "\n${BLUE}ℹ Đang gửi truy vấn tìm kiếm thử nghiệm qua JSON API...${NC}"
    local QUERY="Vietnam"
    local URL="http://127.0.0.1:${PORT}/search?q=${QUERY}&format=json"

    echo -e "   Endpoint: ${CYAN}${URL}${NC}\n"

    RES=$(curl -s --max-time 10 "$URL" 2>/dev/null || echo "")

    if [[ "$RES" =~ "\"results\"" ]]; then
        echo -e "${GREEN}${BOLD}✓ Tìm kiếm thành công! JSON API hoạt động hoàn hảo.${NC}"
        # Trích xuất 2 kết quả đầu tiên
        echo -e "${YELLOW}Kết quả mẫu:${NC}"
        echo "$RES" | grep -o '"title": *"[^"]*"' | head -n 3 || true
    else
        echo -e "${RED}✗ Chưa nhận được kết quả JSON hợp lệ.${NC}"
        echo -e "${YELLOW}Phản hồi nhận được:${NC} $RES"
    fi
    echo ""
}

# Khởi động lại
restart_service() {
    if [ -d "$INSTALL_DIR" ]; then
        cd "$INSTALL_DIR"
        echo -e "\n${BLUE}ℹ Đang khởi động lại SearXNG...${NC}"
        run_compose restart
        echo -e "${GREEN}✓ Đã khởi động lại thành công!${NC}"
    fi
}

# Dừng dịch vụ
stop_service() {
    if [ -d "$INSTALL_DIR" ]; then
        cd "$INSTALL_DIR"
        echo -e "\n${YELLOW}ℹ Đang dừng các container SearXNG...${NC}"
        run_compose stop
        echo -e "${GREEN}✓ Đã dừng dịch vụ.${NC}"
    fi
}

# Gỡ bỏ dịch vụ
uninstall_searxng() {
    echo -e "\n${RED}${BOLD}⚠ CẢNH BÁO: BẠN CÓ CHẮC CHẮN MUỐN GỠ BỎ SEARXNG?${NC}"
    read -rp "Xác nhận gỡ bỏ? (gõ 'yes' để xác nhận): " CONFIRM
    if [ "$CONFIRM" != "yes" ]; then
        echo -e "${YELLOW}Hủy bỏ thao tác gỡ bỏ.${NC}"
        return 0
    fi

    if [ -d "$INSTALL_DIR" ]; then
        cd "$INSTALL_DIR"
        run_compose down -v --remove-orphans 2>/dev/null || true
    fi

    rm -rf "$INSTALL_DIR"
    echo -e "${GREEN}✓ Đã gỡ bỏ sạch sẽ SearXNG và Redis khỏi máy chủ.${NC}\n"
}

# Menu chính
main_menu() {
    show_banner
    detect_os
    load_config

    echo -e "${BOLD}Chọn tác vụ bạn muốn thực hiện:${NC}"
    echo -e "   1) ${GREEN}${BOLD}Cài đặt & Khởi chạy SearXNG (Docker + Redis)${NC}"
    echo -e "   2) ${YELLOW}Kiểm tra trạng thái & Cổng lắng nghe (${PORT})${NC}"
    echo -e "   3) ${CYAN}Xem Live Logs của SearXNG${NC}"
    echo -e "   4) ${GREEN}Thử nghiệm tìm kiếm qua JSON API (curl test)${NC}"
    echo -e "   5) ${BLUE}Mở / Kiểm tra lại tường lửa (Firewall) cho Port ${PORT}${NC}"
    echo -e "   6) Khởi động lại SearXNG (Restart)"
    echo -e "   7) Dừng SearXNG (Stop)"
    echo -e "   8) ${RED}Gỡ bỏ SearXNG hoàn toàn${NC}"
    echo -e "   0) Thoát"

    echo ""
    read -rp "Nhập lựa chọn của bạn [0-8] (Mặc định: 1): " MENU_CHOICE
    MENU_CHOICE="${MENU_CHOICE:-1}"

    case "$MENU_CHOICE" in
        1)
            deploy_searxng
            ;;
        2)
            check_status
            ;;
        3)
            view_logs
            ;;
        4)
            test_search
            ;;
        5)
            open_firewall_port "$PORT"
            ;;
        6)
            restart_service
            ;;
        7)
            stop_service
            ;;
        8)
            uninstall_searxng
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
check_root
main_menu
