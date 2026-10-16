#!/usr/bin/env bash

# ==============================================================================
# Script Tự Động Cài Đặt, Cấu Hình & Quản Lý n8n Workflow Automation
# Triển khai bằng Docker & Docker Compose
# Domain mặc định: n8n.openv.io.vn
# Tích hợp: SSL Let's Encrypt (Caddy / Nginx) hoặc Chế độ Proxy ngoài (Cloudflare/aaPanel)
# Tùy chọn Database: SQLite (mặc định siêu nhẹ) hoặc PostgreSQL 16 (High Performance)
# Hỗ trợ: Ubuntu, Debian, CentOS, RHEL, AlmaLinux, RockyLinux, Fedora
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
INSTALL_DIR="/opt/n8n"
DATA_DIR="/opt/n8n/data"
BACKUP_DIR="/opt/n8n/backups"
COMPOSE_FILE="$INSTALL_DIR/docker-compose.yml"
ENV_FILE="$INSTALL_DIR/.env"

# Cấu hình mặc định
DEFAULT_DOMAIN="n8n.openv.io.vn"
DEFAULT_PORT="5678"
DEFAULT_TIMEZONE="Asia/Ho_Chi_Minh"
DEFAULT_N8N_IMAGE="docker.n8n.io/n8nio/n8n:latest"

# Hiển thị banner
show_banner() {
    clear 2>/dev/null || true
    echo -e "${CYAN}${BOLD}==================================================================${NC}"
    echo -e "${CYAN}${BOLD}        HỆ THỐNG CÀI ĐẶT & QUẢN LÝ N8N WORKFLOW AUTOMATION        ${NC}"
    echo -e "${CYAN}${BOLD}    Docker Compose • Domain: ${DEFAULT_DOMAIN} • SSL & Webhook     ${NC}"
    echo -e "${CYAN}${BOLD}==================================================================${NC}\n"
}

# Kiểm tra quyền root
check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}✗ Lỗi: Script yêu cầu quyền root để cấu hình Docker, dịch vụ và Firewall.${NC}"
        echo -e "${YELLOW}ℹ Vui lòng chạy lại bằng lệnh:${NC} ${BOLD}sudo bash $0${NC}\n"
        exit 1
    fi
}

# Phát hiện hệ điều hành và kiến trúc phần cứng
detect_os() {
    OS="$(uname -s)"
    ARCH="$(uname -m)"
    DISTRO="unknown"
    PKG_MANAGER=""

    if [ "$OS" != "Linux" ]; then
        echo -e "${RED}✗ Lỗi: Script này được tối ưu để triển khai máy chủ trên Linux.${NC}"
        echo -e "${YELLOW}Hệ điều hành hiện tại: $OS ($ARCH)${NC}\n"
        exit 1
    fi

    if [ -f /etc/os-release ]; then
        # shellcheck disable=SC1091
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

# Cài đặt các gói tiện ích cơ bản (curl, openssl, jq, wget, tar)
ensure_utilities() {
    local missing=()
    for tool in curl openssl jq wget tar; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            missing+=("$tool")
        fi
    done

    if [ ${#missing[@]} -gt 0 ]; then
        echo -e "${BLUE}ℹ Đang cài đặt các tiện ích bổ trợ: ${missing[*]}...${NC}"
        if [ "$PKG_MANAGER" = "apt-get" ]; then
            apt-get update -qq
            apt-get install -y -qq "${missing[@]}" || true
        elif [ "$PKG_MANAGER" = "dnf" ] || [ "$PKG_MANAGER" = "yum" ]; then
            $PKG_MANAGER install -y -q "${missing[@]}" || true
        fi
    fi
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

    # Đảm bảo plugin compose hoạt động
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

# Mở Firewall Port (UFW, Firewalld, iptables)
open_firewall_ports() {
    local ports=("$@")
    if [ ${#ports[@]} -eq 0 ]; then
        ports=("$DEFAULT_PORT" "80" "443")
    fi

    echo -e "\n${BLUE}ℹ Đang kiểm tra và mở tường lửa cho các cổng: ${BOLD}${ports[*]}${NC}...${NC}"
    local opened=false

    # 1. UFW (Ubuntu/Debian)
    if command -v ufw >/dev/null 2>&1; then
        UFW_STATUS=$(ufw status 2>/dev/null | grep -i "Status: active" || true)
        if [ -n "$UFW_STATUS" ]; then
            for p in "${ports[@]}"; do
                ufw allow "${p}/tcp" comment "n8n automation" >/dev/null 2>&1 || ufw allow "${p}" >/dev/null 2>&1
            done
            ufw reload >/dev/null 2>&1 || true
            echo -e "   ${GREEN}✓ Đã mở các port ${ports[*]} trên UFW!${NC}"
            opened=true
        fi
    fi

    # 2. Firewalld (CentOS, RHEL, Rocky, AlmaLinux)
    if command -v firewall-cmd >/dev/null 2>&1; then
        if systemctl is-active --quiet firewalld 2>/dev/null; then
            for p in "${ports[@]}"; do
                firewall-cmd --permanent --add-port="${p}/tcp" >/dev/null 2>&1 || true
            done
            firewall-cmd --reload >/dev/null 2>&1 || true
            echo -e "   ${GREEN}✓ Đã mở các port ${ports[*]} trên Firewalld!${NC}"
            opened=true
        fi
    fi

    # 3. Iptables fallback
    if command -v iptables >/dev/null 2>&1; then
        for p in "${ports[@]}"; do
            if ! iptables -C INPUT -p tcp --dport "${p}" -j ACCEPT >/dev/null 2>&1; then
                iptables -I INPUT -p tcp --dport "${p}" -j ACCEPT >/dev/null 2>&1 || true
            fi
        done
        opened=true
    fi

    if [ "$opened" = true ]; then
        echo -e "${GREEN}✓ Hoàn tất cấu hình tường lửa nội bộ.${NC}"
    else
        echo -e "${YELLOW}ℹ Không phát hiện firewall nội bộ đang kích hoạt.${NC}"
    fi

    echo -e "${MAGENTA}${BOLD}👉 LƯU Ý CHO CLOUD VPS:${NC}"
    echo -e "   Nếu bạn dùng AWS EC2, GCP, Azure, Oracle Cloud, Linode, Hetzner, DigitalOcean:"
    echo -e "   Hãy đảm bảo đã mở ${BOLD}Inbound Rules (Port ${ports[*]})${NC} trên Web Dashboard của nhà cung cấp.\n"
}

# Đọc cấu hình hiện tại từ .env
load_config() {
    if [ -f "$ENV_FILE" ]; then
        # shellcheck disable=SC1090
        . "$ENV_FILE" 2>/dev/null || true
    fi

    DOMAIN="${DOMAIN_NAME:-$DEFAULT_DOMAIN}"
    N8N_PORT="${PORT:-$DEFAULT_PORT}"
    TIMEZONE="${GENERIC_TIMEZONE:-$DEFAULT_TIMEZONE}"
    DB_TYPE="${DB_TYPE:-sqlite}"
    SSL_MODE="${SSL_MODE:-caddy}" # caddy, standalone, nginx
    SSL_EMAIL="${SSL_EMAIL:-admin@${DOMAIN}}"
    ENCRYPTION_KEY="${N8N_ENCRYPTION_KEY:-}"
    DATA_PATH="${N8N_DATA_PATH:-$DATA_DIR}"
    N8N_IMAGE="${N8N_IMAGE:-$DEFAULT_N8N_IMAGE}"

    if [ -z "$ENCRYPTION_KEY" ]; then
        ENCRYPTION_KEY=$(openssl rand -hex 32 2>/dev/null || head -c 32 /dev/urandom | xxd -p -c 32)
    fi
}

# Lưu cấu hình vào .env
save_config() {
    mkdir -p "$INSTALL_DIR"
    cat > "$ENV_FILE" <<EOF
# n8n Automation Configuration
DOMAIN_NAME=${DOMAIN}
PORT=${N8N_PORT}
GENERIC_TIMEZONE=${TIMEZONE}
DB_TYPE=${DB_TYPE}
SSL_MODE=${SSL_MODE}
SSL_EMAIL=${SSL_EMAIL}
N8N_ENCRYPTION_KEY=${ENCRYPTION_KEY}
N8N_DATA_PATH=${DATA_PATH}
N8N_IMAGE=${N8N_IMAGE}
POSTGRES_USER=${POSTGRES_USER:-n8n}
POSTGRES_PASSWORD=${POSTGRES_PASSWORD:-$(openssl rand -hex 16)}
POSTGRES_DB=${POSTGRES_DB:-n8n}
EOF
    chmod 600 "$ENV_FILE"
}

# Tạo docker-compose.yml theo chế độ đã chọn
generate_docker_compose() {
    mkdir -p "$INSTALL_DIR" "$DATA_PATH" "$BACKUP_DIR"

    # Phân quyền 1000:1000 cho user 'node' của n8n container
    chown -R 1000:1000 "$DATA_PATH" "$BACKUP_DIR" 2>/dev/null || chmod -R 777 "$DATA_PATH" "$BACKUP_DIR"

    if [ "$SSL_MODE" = "caddy" ]; then
        # Chế độ 1: Caddy Reverse Proxy (Tự động xin SSL Let's Encrypt / ZeroSSL cho n8n.openv.io.vn)
        mkdir -p "$INSTALL_DIR/caddy_data" "$INSTALL_DIR/caddy_config"
        cat > "$INSTALL_DIR/Caddyfile" <<EOF
${DOMAIN} {
    reverse_proxy n8n:5678 {
        flush_interval -1
    }

    header {
        Strict-Transport-Security "max-age=31536000; includeSubDomains; preload"
        X-Content-Type-Options "nosniff"
        X-XSS-Protection "1; mode=block"
        X-Robots-Tag "noindex, nofollow"
    }
}
EOF

        if [ "$DB_TYPE" = "postgres" ]; then
            # n8n + PostgreSQL + Caddy
            mkdir -p "$INSTALL_DIR/postgres_data"
            cat > "$COMPOSE_FILE" <<EOF
services:
  postgres:
    image: postgres:16-alpine
    container_name: n8n_postgres
    restart: unless-stopped
    environment:
      POSTGRES_USER: \${POSTGRES_USER}
      POSTGRES_PASSWORD: \${POSTGRES_PASSWORD}
      POSTGRES_DB: \${POSTGRES_DB}
    volumes:
      - ./postgres_data:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U \${POSTGRES_USER} -d \${POSTGRES_DB}"]
      interval: 5s
      timeout: 5s
      retries: 10
    networks:
      - n8n_net

  n8n:
    image: \${N8N_IMAGE}
    container_name: n8n
    restart: unless-stopped
    environment:
      - N8N_HOST=\${DOMAIN_NAME}
      - N8N_PORT=5678
      - N8N_PROTOCOL=https
      - WEBHOOK_URL=https://\${DOMAIN_NAME}/
      - N8N_EDITOR_BASE_URL=https://\${DOMAIN_NAME}/
      - GENERIC_TIMEZONE=\${GENERIC_TIMEZONE}
      - TZ=\${GENERIC_TIMEZONE}
      - N8N_ENCRYPTION_KEY=\${N8N_ENCRYPTION_KEY}
      - N8N_ENFORCE_SETTINGS_FILE_PERMISSIONS=true
      - N8N_RUNNERS_ENABLED=true
      - EXECUTIONS_DATA_PRUNE=true
      - EXECUTIONS_DATA_MAX_AGE=168
      - EXECUTIONS_DATA_PRUNE_MAX_COUNT=50000
      - DB_TYPE=postgresdb
      - DB_POSTGRESDB_HOST=postgres
      - DB_POSTGRESDB_PORT=5432
      - DB_POSTGRESDB_DATABASE=\${POSTGRES_DB}
      - DB_POSTGRESDB_USER=\${POSTGRES_USER}
      - DB_POSTGRESDB_PASSWORD=\${POSTGRES_PASSWORD}
    volumes:
      - \${N8N_DATA_PATH}:/home/node/.n8n
      - ./backups:/home/node/backups
    depends_on:
      postgres:
        condition: service_healthy
    networks:
      - n8n_net

  caddy:
    image: caddy:2-alpine
    container_name: n8n_caddy
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - ./caddy_data:/data
      - ./caddy_config:/config
    depends_on:
      - n8n
    networks:
      - n8n_net

networks:
  n8n_net:
    driver: bridge
EOF
        else
            # n8n (SQLite) + Caddy
            cat > "$COMPOSE_FILE" <<EOF
services:
  n8n:
    image: \${N8N_IMAGE}
    container_name: n8n
    restart: unless-stopped
    environment:
      - N8N_HOST=\${DOMAIN_NAME}
      - N8N_PORT=5678
      - N8N_PROTOCOL=https
      - WEBHOOK_URL=https://\${DOMAIN_NAME}/
      - N8N_EDITOR_BASE_URL=https://\${DOMAIN_NAME}/
      - GENERIC_TIMEZONE=\${GENERIC_TIMEZONE}
      - TZ=\${GENERIC_TIMEZONE}
      - N8N_ENCRYPTION_KEY=\${N8N_ENCRYPTION_KEY}
      - N8N_ENFORCE_SETTINGS_FILE_PERMISSIONS=true
      - N8N_RUNNERS_ENABLED=true
      - EXECUTIONS_DATA_PRUNE=true
      - EXECUTIONS_DATA_MAX_AGE=168
      - EXECUTIONS_DATA_PRUNE_MAX_COUNT=50000
    volumes:
      - \${N8N_DATA_PATH}:/home/node/.n8n
      - ./backups:/home/node/backups
    networks:
      - n8n_net

  caddy:
    image: caddy:2-alpine
    container_name: n8n_caddy
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - ./caddy_data:/data
      - ./caddy_config:/config
    depends_on:
      - n8n
    networks:
      - n8n_net

networks:
  n8n_net:
    driver: bridge
EOF
        fi

    else
        # Chế độ 2: Standalone n8n (Mở Port 5678, dùng cho Cloudflare Tunnel / aaPanel / Nginx bên ngoài)
        if [ "$DB_TYPE" = "postgres" ]; then
            mkdir -p "$INSTALL_DIR/postgres_data"
            cat > "$COMPOSE_FILE" <<EOF
services:
  postgres:
    image: postgres:16-alpine
    container_name: n8n_postgres
    restart: unless-stopped
    environment:
      POSTGRES_USER: \${POSTGRES_USER}
      POSTGRES_PASSWORD: \${POSTGRES_PASSWORD}
      POSTGRES_DB: \${POSTGRES_DB}
    volumes:
      - ./postgres_data:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U \${POSTGRES_USER} -d \${POSTGRES_DB}"]
      interval: 5s
      timeout: 5s
      retries: 10
    networks:
      - n8n_net

  n8n:
    image: \${N8N_IMAGE}
    container_name: n8n
    restart: unless-stopped
    ports:
      - "\${PORT}:5678"
    environment:
      - N8N_HOST=\${DOMAIN_NAME}
      - N8N_PORT=5678
      - N8N_PROTOCOL=https
      - WEBHOOK_URL=https://\${DOMAIN_NAME}/
      - N8N_EDITOR_BASE_URL=https://\${DOMAIN_NAME}/
      - GENERIC_TIMEZONE=\${GENERIC_TIMEZONE}
      - TZ=\${GENERIC_TIMEZONE}
      - N8N_ENCRYPTION_KEY=\${N8N_ENCRYPTION_KEY}
      - N8N_ENFORCE_SETTINGS_FILE_PERMISSIONS=true
      - N8N_RUNNERS_ENABLED=true
      - EXECUTIONS_DATA_PRUNE=true
      - EXECUTIONS_DATA_MAX_AGE=168
      - EXECUTIONS_DATA_PRUNE_MAX_COUNT=50000
      - DB_TYPE=postgresdb
      - DB_POSTGRESDB_HOST=postgres
      - DB_POSTGRESDB_PORT=5432
      - DB_POSTGRESDB_DATABASE=\${POSTGRES_DB}
      - DB_POSTGRESDB_USER=\${POSTGRES_USER}
      - DB_POSTGRESDB_PASSWORD=\${POSTGRES_PASSWORD}
    volumes:
      - \${N8N_DATA_PATH}:/home/node/.n8n
      - ./backups:/home/node/backups
    depends_on:
      postgres:
        condition: service_healthy
    networks:
      - n8n_net

networks:
  n8n_net:
    driver: bridge
EOF
        else
            cat > "$COMPOSE_FILE" <<EOF
services:
  n8n:
    image: \${N8N_IMAGE}
    container_name: n8n
    restart: unless-stopped
    ports:
      - "\${PORT}:5678"
    environment:
      - N8N_HOST=\${DOMAIN_NAME}
      - N8N_PORT=5678
      - N8N_PROTOCOL=https
      - WEBHOOK_URL=https://\${DOMAIN_NAME}/
      - N8N_EDITOR_BASE_URL=https://\${DOMAIN_NAME}/
      - GENERIC_TIMEZONE=\${GENERIC_TIMEZONE}
      - TZ=\${GENERIC_TIMEZONE}
      - N8N_ENCRYPTION_KEY=\${N8N_ENCRYPTION_KEY}
      - N8N_ENFORCE_SETTINGS_FILE_PERMISSIONS=true
      - N8N_RUNNERS_ENABLED=true
      - EXECUTIONS_DATA_PRUNE=true
      - EXECUTIONS_DATA_MAX_AGE=168
      - EXECUTIONS_DATA_PRUNE_MAX_COUNT=50000
    volumes:
      - \${N8N_DATA_PATH}:/home/node/.n8n
      - ./backups:/home/node/backups
    networks:
      - n8n_net

networks:
  n8n_net:
    driver: bridge
EOF
        fi
    fi
}

# Kiểm tra phân giải DNS của Domain
check_dns_record() {
    local domain="$1"
    get_server_ips
    echo -e "${BLUE}ℹ Đang kiểm tra bản ghi DNS cho domain: ${BOLD}${domain}${NC}...${NC}"

    local resolved_ip=""
    if command -v getent >/dev/null 2>&1; then
        resolved_ip=$(getent ahosts "$domain" 2>/dev/null | awk '{print $1}' | head -n 1 || true)
    fi

    if [ -z "$resolved_ip" ] && command -v nslookup >/dev/null 2>&1; then
        resolved_ip=$(nslookup "$domain" 2>/dev/null | awk '/^Address: / { print $2 }' | tail -n 1 || true)
    fi

    if [ -n "$resolved_ip" ]; then
        echo -e "   → Domain ${BOLD}${domain}${NC} đang trỏ về IP: ${BOLD}${resolved_ip}${NC}"
        echo -e "   → IP Công khai của máy chủ này: ${BOLD}${PUBLIC_IP}${NC}"
        if [ "$resolved_ip" = "$PUBLIC_IP" ]; then
            echo -e "   ${GREEN}✓ DNS đã được cấu hình chính xác trỏ thẳng về máy chủ này!${NC}"
        else
            echo -e "   ${YELLOW}⚠ Lưu ý: IP DNS (${resolved_ip}) khác với IP máy chủ (${PUBLIC_IP}).${NC}"
            echo -e "   Nếu bạn đang dùng Cloudflare Proxy (đám mây cam) hoặc CDN, đây là điều bình thường."
            echo -e "   Nếu bạn dùng Caddy SSL tự động, hãy đảm bảo tắt Cloudflare Proxy (đổi sang DNS Only - xám) hoặc trỏ trực tiếp.${NC}"
        fi
    else
        echo -e "   ${YELLOW}⚠ Chưa phân giải được DNS cho ${domain}. Vui lòng đảm bảo đã tạo bản ghi A/CNAME trỏ về IP: ${PUBLIC_IP}${NC}"
    fi
    echo ""
}

# Triển khai và Cài đặt n8n
deploy_n8n() {
    show_banner
    detect_os
    ensure_utilities
    ensure_docker_and_compose
    load_config

    echo -e "${CYAN}${BOLD}--- BẮT ĐẦU CẤU HÌNH VÀ CÀI ĐẶT N8N WORKFLOW AUTOMATION ---${NC}\n"

    # 1. Nhập Domain Public
    read -rp "1. Nhập Domain truy cập công khai (Public Domain) [Mặc định: ${DEFAULT_DOMAIN}]: " INPUT_DOMAIN
    DOMAIN="${INPUT_DOMAIN:-$DEFAULT_DOMAIN}"

    # 2. Chọn chế độ SSL & Reverse Proxy
    echo -e "\n${BOLD}2. Chọn phương thức Reverse Proxy & Chứng chỉ SSL HTTPS:${NC}"
    echo -e "   1) ${GREEN}${BOLD}Caddy Reverse Proxy (Khuyên dùng)${NC} - Tự động cấp phát & gia hạn SSL Let's Encrypt miễn phí (Mở port 80 & 443)"
    echo -e "   2) ${YELLOW}Standalone Port 5678 (Dùng Cloudflare Tunnel / aaPanel / Nginx riêng)${NC} - Bạn tự quản lý SSL/Reverse Proxy bên ngoài"
    read -rp "Chọn phương thức [1-2] (Mặc định: 1): " PROXY_CHOICE
    PROXY_CHOICE="${PROXY_CHOICE:-1}"

    if [ "$PROXY_CHOICE" = "1" ]; then
        SSL_MODE="caddy"
        # Kiểm tra xem cổng 80 hoặc 443 có đang bị chiếm không
        for check_port in 80 443; do
            if ss -tuln 2>/dev/null | grep -q ":${check_port} " || netstat -tuln 2>/dev/null | grep -q ":${check_port} "; then
                echo -e "${YELLOW}⚠ Cảnh báo: Cổng ${check_port} dường như đang được sử dụng bởi một dịch vụ khác (ví dụ: Nginx/Apache/aaPanel).${NC}"
                echo -e "   Nếu bạn đã có Web Server (Nginx, aaPanel), hãy chọn Chế độ 2 (Standalone Port 5678) để tránh xung đột cổng!${NC}"
                read -rp "Bạn vẫn muốn tiếp tục dùng Caddy trên cổng 80/443? (y/N): " FORCE_CADDY
                if [[ ! "$FORCE_CADDY" =~ ^[yY]$ ]]; then
                    SSL_MODE="standalone"
                    echo -e "${GREEN}✓ Đã chuyển sang chế độ Standalone (Port 5678).${NC}"
                fi
            fi
        done
    else
        SSL_MODE="standalone"
    fi

    # 3. Chọn Database
    echo -e "\n${BOLD}3. Chọn loại Cơ sở dữ liệu (Database Backend):${NC}"
    echo -e "   1) ${GREEN}${BOLD}SQLite (Khuyên dùng cho nhu cầu vừa và nhỏ)${NC} - Rất nhẹ, không tốn thêm RAM, sao lưu dễ dàng"
    echo -e "   2) ${BLUE}PostgreSQL 16 (Dành cho Production / Tải cao)${NC} - Xử lý nhiều workflow song song mượt mà"
    read -rp "Chọn Database [1-2] (Mặc định: 1): " DB_CHOICE
    DB_CHOICE="${DB_CHOICE:-1}"

    if [ "$DB_CHOICE" = "2" ]; then
        DB_TYPE="postgres"
    else
        DB_TYPE="sqlite"
    fi

    # 4. Múi giờ
    read -rp $'\n4. Nhập Múi giờ (Timezone) [Mặc định: Asia/Ho_Chi_Minh]: ' INPUT_TZ
    TIMEZONE="${INPUT_TZ:-$DEFAULT_TIMEZONE}"

    # 5. Lưu và tạo file compose
    save_config
    generate_docker_compose

    # 6. Kiểm tra DNS
    check_dns_record "$DOMAIN"

    # 7. Mở Firewall
    if [ "$SSL_MODE" = "caddy" ]; then
        open_firewall_ports 80 443
    else
        open_firewall_ports "$N8N_PORT"
    fi

    # 8. Khởi chạy Docker Compose
    echo -e "${BLUE}⏳ Đang tải Docker Images và khởi chạy n8n...${NC}"
    cd "$INSTALL_DIR"
    run_compose down 2>/dev/null || true
    run_compose pull
    run_compose up -d

    echo -e "\n${YELLOW}⏳ Đang chờ n8n khởi động hoàn tất (khoảng 10-15 giây)...${NC}"
    sleep 10

    # Hiển thị kết quả thành công
    check_status
}

# Kiểm tra trạng thái dịch vụ
check_status() {
    load_config
    get_server_ips

    echo -e "\n${CYAN}${BOLD}==================================================================${NC}"
    echo -e "${CYAN}${BOLD}                 TRẠNG THÁI DỊCH VỤ N8N WORKFLOW                  ${NC}"
    echo -e "${CYAN}${BOLD}==================================================================${NC}"

    if [ -d "$INSTALL_DIR" ] && [ -f "$COMPOSE_FILE" ]; then
        cd "$INSTALL_DIR"
        echo -e "\n${BOLD}Container Status:${NC}"
        run_compose ps
        echo ""
    else
        echo -e "${RED}✗ Chưa tìm thấy thư mục cài đặt tại: $INSTALL_DIR${NC}\n"
        return 1
    fi

    local is_running=false
    if docker ps 2>/dev/null | grep -q " n8n"; then
        is_running=true
    fi

    if [ "$is_running" = true ]; then
        echo -e "${GREEN}${BOLD}✓ n8n Automation đang HOẠT ĐỘNG!${NC}\n"
        echo -e "   🌐 ${BOLD}Domain truy cập:${NC}    ${GREEN}${BOLD}https://${DOMAIN}${NC}"
        echo -e "   🔗 ${BOLD}Webhook URL Base:${NC} ${GREEN}${BOLD}https://${DOMAIN}/webhook/...${NC}"
        echo -e "   📂 ${BOLD}Thư mục dữ liệu:${NC}  ${BOLD}${DATA_PATH}${NC}"
        echo -e "   🗄️  ${BOLD}Cơ sở dữ liệu:${NC}    ${BOLD}${DB_TYPE}${NC}"
        echo -e "   🔐 ${BOLD}Chế độ SSL:${NC}       ${BOLD}${SSL_MODE}${NC}"

        if [ "$SSL_MODE" = "standalone" ]; then
            echo -e "   🔌 ${BOLD}Cổng nội bộ/VPS:${NC}   ${BOLD}http://${LOCAL_IP}:${N8N_PORT}${NC} hoặc ${BOLD}http://${PUBLIC_IP}:${N8N_PORT}${NC}"
            echo -e "\n   ${YELLOW}${BOLD}👉 HƯỚNG DẪN PROXY NGOÀI (CLOUDFLARE TUNNEL / AAPANEL / NGINX):${NC}"
            echo -e "   • Nếu dùng ${BOLD}Cloudflare Tunnel${NC}: Trỏ hostname ${BOLD}${DOMAIN}${NC} về ${BOLD}http://localhost:${N8N_PORT}${NC}"
            echo -e "   • Nếu dùng ${BOLD}aaPanel / Nginx / Nginx Proxy Manager${NC}: Tạo website với domain ${BOLD}${DOMAIN}${NC},"
            echo -e "     cấu hình Reverse Proxy trỏ đến ${BOLD}http://127.0.0.1:${N8N_PORT}${NC} kèm bật WebSocket (Upgrade/Connection)."
        else
            echo -e "\n   ${GREEN}${BOLD}✓ Caddy đã tự động kích hoạt HTTPS (Port 443 & 80).${NC}"
            echo -e "   Hãy truy cập ngay: ${CYAN}${BOLD}https://${DOMAIN}${NC} để tạo tài khoản Quản trị viên (Owner Account) đầu tiên."
        fi
    else
        echo -e "${RED}${BOLD}✗ n8n hiện KHÔNG chạy hoặc gặp lỗi khởi động!${NC}"
        echo -e "${YELLOW}ℹ Bạn có thể xem log lỗi bằng lệnh:${NC} ${BOLD}docker logs n8n --tail 50${NC}\n"
    fi
}

# Xem Live Logs
view_logs() {
    load_config
    if [ ! -d "$INSTALL_DIR" ]; then
        echo -e "${RED}Chưa cài đặt n8n.${NC}"
        return 1
    fi
    cd "$INSTALL_DIR"
    echo -e "${CYAN}${BOLD}Đang hiển thị Logs của n8n (Nhấn Ctrl+C để thoát)...${NC}\n"
    run_compose logs -f --tail=100
}

# Cập nhật n8n lên bản mới nhất
update_n8n() {
    load_config
    if [ ! -d "$INSTALL_DIR" ]; then
        echo -e "${RED}Chưa cài đặt n8n.${NC}"
        return 1
    fi
    cd "$INSTALL_DIR"
    echo -e "${BLUE}⏳ Đang kéo image n8n mới nhất từ Docker Registry...${NC}"
    run_compose pull
    echo -e "${BLUE}⏳ Đang khởi động lại dịch vụ với phiên bản mới...${NC}"
    run_compose up -d --remove-orphans
    echo -e "${GREEN}✓ Cập nhật n8n thành công!${NC}\n"
}

# Sao lưu dữ liệu (Workflows, Credentials & Database)
backup_n8n() {
    load_config
    mkdir -p "$BACKUP_DIR"
    local timestamp
    timestamp=$(date +"%Y%m%d_%H%M%S")
    local backup_target="$BACKUP_DIR/n8n_backup_${timestamp}"
    mkdir -p "$backup_target"

    echo -e "${BLUE}ℹ Đang thực hiện sao lưu dữ liệu n8n (${timestamp})...${NC}"

    # 1. Sao lưu .env và Caddyfile
    cp -f "$ENV_FILE" "$backup_target/.env" 2>/dev/null || true
    cp -f "$INSTALL_DIR/Caddyfile" "$backup_target/Caddyfile" 2>/dev/null || true
    cp -f "$COMPOSE_FILE" "$backup_target/docker-compose.yml" 2>/dev/null || true

    # 2. Xuất Workflows và Credentials qua n8n CLI container
    if docker ps 2>/dev/null | grep -q " n8n"; then
        echo -e "   → Đang xuất Workflows qua n8n CLI..."
        docker exec -u node n8n n8n export:workflow --all --output=/home/node/backups/workflows_${timestamp}.json 2>/dev/null || true
        echo -e "   → Đang xuất Credentials qua n8n CLI..."
        docker exec -u node n8n n8n export:credentials --all --output=/home/node/backups/credentials_${timestamp}.json 2>/dev/null || true
    fi

    # 3. Sao lưu SQLite hoặc PostgreSQL
    if [ "$DB_TYPE" = "postgres" ]; then
        if docker ps 2>/dev/null | grep -q "n8n_postgres"; then
            echo -e "   → Đang dump PostgreSQL database..."
            docker exec n8n_postgres pg_dump -U "${POSTGRES_USER:-n8n}" "${POSTGRES_DB:-n8n}" > "$backup_target/postgres_dump.sql" 2>/dev/null || true
        fi
    else
        echo -e "   → Đang sao lưu file SQLite database..."
        cp -f "$DATA_PATH/database.sqlite" "$backup_target/" 2>/dev/null || true
    fi

    # Nén toàn bộ bản backup thành tar.gz
    local archive_file="$BACKUP_DIR/n8n_full_backup_${timestamp}.tar.gz"
    tar -czf "$archive_file" -C "$BACKUP_DIR" "n8n_backup_${timestamp}"
    rm -rf "$backup_target"

    echo -e "${GREEN}✓ Đã tạo file sao lưu an toàn tại:${NC} ${BOLD}${archive_file}${NC}"
    echo -e "   Dung lượng: ${BOLD}$(du -sh "$archive_file" | awk '{print $1}')${NC}\n"
}

# Khôi phục dữ liệu từ bản sao lưu
restore_n8n() {
    load_config
    echo -e "\n${YELLOW}${BOLD}Danh sách các bản sao lưu hiện có trong ${BACKUP_DIR}:${NC}"
    local backups=("$BACKUP_DIR"/*.tar.gz)
    if [ ! -f "${backups[0]}" ]; then
        echo -e "${RED}✗ Chưa tìm thấy file sao lưu (*.tar.gz) nào trong ${BACKUP_DIR}.${NC}\n"
        return 1
    fi

    local index=1
    for b in "${backups[@]}"; do
        echo -e "   $index) $(basename "$b") ($(du -sh "$b" | awk '{print $1}'))"
        ((index++))
    done

    read -rp "Nhập số thứ tự file bạn muốn khôi phục [1-$((index-1))]: " PICK
    if [[ ! "$PICK" =~ ^[0-9]+$ ]] || [ "$PICK" -lt 1 ] || [ "$PICK" -ge "$index" ]; then
        echo -e "${RED}Lựa chọn không hợp lệ.${NC}"
        return 1
    fi

    local selected_archive="${backups[$((PICK-1))]}"
    echo -e "${YELLOW}Đang chuẩn bị khôi phục từ: ${selected_archive}...${NC}"

    cd "$INSTALL_DIR"
    run_compose down 2>/dev/null || true

    local temp_restore="/tmp/n8n_restore_$$"
    mkdir -p "$temp_restore"
    tar -xzf "$selected_archive" -C "$temp_restore"

    local extracted_folder
    extracted_folder=$(find "$temp_restore" -mindepth 1 -maxdepth 1 -type d | head -n 1)

    if [ -d "$extracted_folder" ]; then
        if [ -f "$extracted_folder/.env" ]; then
            cp -f "$extracted_folder/.env" "$INSTALL_DIR/.env"
        fi
        if [ -f "$extracted_folder/database.sqlite" ]; then
            cp -f "$extracted_folder/database.sqlite" "$DATA_PATH/database.sqlite"
            chown 1000:1000 "$DATA_PATH/database.sqlite" 2>/dev/null || true
        fi
    fi

    rm -rf "$temp_restore"
    run_compose up -d
    echo -e "${GREEN}✓ Khôi phục hoàn tất và dịch vụ đã khởi động lại.${NC}\n"
}

# Khởi động lại dịch vụ
restart_service() {
    load_config
    if [ -d "$INSTALL_DIR" ]; then
        cd "$INSTALL_DIR"
        echo -e "${BLUE}⏳ Đang khởi động lại các container n8n...${NC}"
        run_compose restart
        echo -e "${GREEN}✓ Đã khởi động lại thành công!${NC}\n"
        check_status
    fi
}

# Dừng dịch vụ
stop_service() {
    load_config
    if [ -d "$INSTALL_DIR" ]; then
        cd "$INSTALL_DIR"
        echo -e "${YELLOW}⏳ Đang dừng n8n...${NC}"
        run_compose stop
        echo -e "${GREEN}✓ Đã dừng dịch vụ.${NC}\n"
    fi
}

# Khởi động dịch vụ
start_service() {
    load_config
    if [ -d "$INSTALL_DIR" ]; then
        cd "$INSTALL_DIR"
        echo -e "${BLUE}⏳ Đang khởi động n8n...${NC}"
        run_compose up -d
        echo -e "${GREEN}✓ Đã kích hoạt n8n thành công!${NC}\n"
        check_status
    fi
}

# Thay đổi Domain hoặc Cấu hình
change_domain_or_config() {
    load_config
    echo -e "\n${CYAN}${BOLD}--- CẬP NHẬT CẤU HÌNH DOMAIN & WEBSOCKET/WEBHOOK ---${NC}"
    echo -e "Domain hiện tại: ${BOLD}${DOMAIN}${NC}"
    read -rp "Nhập Domain mới (hoặc Enter để giữ nguyên): " NEW_DOMAIN
    if [ -n "$NEW_DOMAIN" ]; then
        DOMAIN="$NEW_DOMAIN"
    fi

    read -rp "Nhập Múi giờ mới (hoặc Enter để giữ ${TIMEZONE}): " NEW_TZ
    if [ -n "$NEW_TZ" ]; then
        TIMEZONE="$NEW_TZ"
    fi

    save_config
    generate_docker_compose
    cd "$INSTALL_DIR"
    run_compose up -d --force-recreate
    echo -e "${GREEN}✓ Đã cập nhật cấu hình và tái khởi động container!${NC}\n"
    check_status
}

# Gỡ bỏ n8n hoàn toàn
uninstall_n8n() {
    echo -e "\n${RED}${BOLD}⚠ CẢNH BÁO NGUY HIỂM: BẠN CÓ CHẮC CHẮN MUỐN GỠ BỎ N8N?${NC}"
    echo -e "${RED}Thao tác này sẽ dừng toàn bộ quy trình tự động hóa workflow đang chạy!${NC}"
    read -rp "Xác nhận gỡ bỏ dịch vụ n8n? (gõ chính xác 'yes' để tiếp tục): " CONFIRM
    if [ "$CONFIRM" != "yes" ]; then
        echo -e "${YELLOW}Hủy bỏ thao tác gỡ bỏ.${NC}"
        return 0
    fi

    load_config

    if [ -d "$INSTALL_DIR" ]; then
        cd "$INSTALL_DIR"
        echo -e "${YELLOW}ℹ Đang dừng và xóa toàn bộ container n8n...${NC}"
        run_compose down -v --remove-orphans 2>/dev/null || true
    fi

    read -rp "Bạn có muốn XÓA TOÀN BỘ WORKFLOW & DỮ LIỆU ĐÃ LƯU TRONG ${DATA_PATH}? (gõ 'DELETE' để xóa sạch, nhấn Enter để giữ lại): " DEL_DATA
    if [ "$DEL_DATA" = "DELETE" ]; then
        rm -rf "$DATA_PATH" "$INSTALL_DIR"
        echo -e "${RED}✓ Đã xóa toàn bộ thư mục dữ liệu và cấu hình n8n.${NC}"
    else
        rm -f "$COMPOSE_FILE" "$INSTALL_DIR/Caddyfile"
        echo -e "${GREEN}✓ Đã giữ lại thư mục dữ liệu ${DATA_PATH}.${NC}"
    fi

    echo -e "${GREEN}✓ Đã gỡ bỏ hoàn toàn n8n khỏi hệ thống.${NC}\n"
}

# Menu điều khiển chính
main_menu() {
    show_banner
    detect_os
    load_config

    echo -e "${BOLD}Chọn tác vụ bạn muốn thực hiện:${NC}"
    echo -e "   1) ${GREEN}${BOLD}Cài đặt & Triển khai n8n (Domain: ${DOMAIN})${NC}"
    echo -e "   2) ${YELLOW}Kiểm tra trạng thái dịch vụ & Thông tin Webhook URL${NC}"
    echo -e "   3) ${CYAN}Xem Live Logs thời gian thực (docker logs)${NC}"
    echo -e "   4) ${BLUE}Cập nhật n8n lên phiên bản mới nhất${NC}"
    echo -e "   5) Thay đổi Domain / Cấu hình .env"
    echo -e "   6) Sao lưu dữ liệu (Workflows, Credentials, Database)"
    echo -e "   7) Khôi phục dữ liệu từ bản sao lưu"
    echo -e "   8) Khởi động lại dịch vụ (Restart)"
    echo -e "   9) Dừng dịch vụ (Stop)"
    echo -e "   10) Khởi động dịch vụ (Start)"
    echo -e "   11) Mở / Kiểm tra lại Firewall (Port 80, 443, 5678)"
    echo -e "   12) ${RED}Gỡ bỏ n8n hoàn toàn (Uninstall)${NC}"
    echo -e "   0) Thoát"

    echo ""
    read -rp "Nhập lựa chọn của bạn [0-12] (Mặc định: 1): " MENU_CHOICE
    MENU_CHOICE="${MENU_CHOICE:-1}"

    case "$MENU_CHOICE" in
        1) deploy_n8n ;;
        2) check_status ;;
        3) view_logs ;;
        4) update_n8n ;;
        5) change_domain_or_config ;;
        6) backup_n8n ;;
        7) restore_n8n ;;
        8) restart_service ;;
        9) stop_service ;;
        10) start_service ;;
        11) open_firewall_ports ;;
        12) uninstall_n8n ;;
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

# Hỗ trợ chạy trực tiếp qua tham số dòng lệnh (CLI flags)
if [ $# -gt 0 ]; then
    detect_os
    load_config
    case "$1" in
        install|setup) deploy_n8n ;;
        status) check_status ;;
        logs) view_logs ;;
        update) update_n8n ;;
        restart) restart_service ;;
        stop) stop_service ;;
        start) start_service ;;
        backup) backup_n8n ;;
        restore) restore_n8n ;;
        firewall) open_firewall_ports ;;
        uninstall) uninstall_n8n ;;
        *)
            echo -e "${RED}Tham số không hợp lệ:${NC} $1"
            echo -e "Sử dụng: $0 [install|status|logs|update|restart|stop|start|backup|restore|firewall|uninstall]"
            exit 1
            ;;
    esac
else
    main_menu
fi
