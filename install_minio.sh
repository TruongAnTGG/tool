#!/usr/bin/env bash

# ==============================================================================
# Script Tự Động Cài Đặt, Cấu Hình & Quản Lý MinIO (S3-Compatible Object Storage)
# Triển khai bằng Docker & Docker Compose kèm MinIO Client (mc) CLI
# Tối ưu hóa cho AI Agents, LLM RAG, Nextcloud, Dify, LangChain & Media Backup
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
INSTALL_DIR="/opt/minio"
DATA_DIR="/opt/minio/data"
CONFIG_DIR="/opt/minio/config"
COMPOSE_FILE="$INSTALL_DIR/docker-compose.yml"
ENV_FILE="$INSTALL_DIR/.env"

# Cổng mặc định
DEFAULT_API_PORT="9000"
DEFAULT_CONSOLE_PORT="9001"
DEFAULT_ROOT_USER="minioadmin"
DEFAULT_MINIO_IMAGE="pgsty/minio:latest"

# Hiển thị banner
show_banner() {
    clear 2>/dev/null || true
    echo -e "${CYAN}${BOLD}==================================================================${NC}"
    echo -e "${CYAN}${BOLD}       HỆ THỐNG CÀI ĐẶT & QUẢN LÝ MINIO OBJECT STORAGE (S3)       ${NC}"
    echo -e "${CYAN}${BOLD}    Docker Compose • MinIO Console Web UI • MinIO Client (mc)     ${NC}"
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
        echo -e "${RED}✗ Lỗi: MinIO Server nên được triển khai trên máy chủ Linux.${NC}"
        echo -e "${YELLOW}Hệ điều hành hiện tại: $OS ($ARCH)${NC}\n"
        exit 1
    fi

    case "$ARCH" in
        x86_64|amd64)
            MC_ARCH="amd64"
            ;;
        aarch64|arm64)
            MC_ARCH="arm64"
            ;;
        armv7l|armhf)
            MC_ARCH="arm"
            ;;
        *)
            MC_ARCH="amd64"
            ;;
    esac

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
    for tool in curl openssl jq wget; do
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
    local api_port="${1:-$DEFAULT_API_PORT}"
    local console_port="${2:-$DEFAULT_CONSOLE_PORT}"

    echo -e "\n${BLUE}ℹ Đang kiểm tra và mở tường lửa cho Port ${BOLD}${api_port}/tcp (API)${NC} và ${BOLD}${console_port}/tcp (Console)${NC}...${NC}"

    local opened=false

    # 1. UFW (Ubuntu/Debian)
    if command -v ufw >/dev/null 2>&1; then
        UFW_STATUS=$(ufw status 2>/dev/null | grep -i "Status: active" || true)
        if [ -n "$UFW_STATUS" ]; then
            ufw allow "${api_port}/tcp" comment "MinIO S3 API" >/dev/null 2>&1 || ufw allow "${api_port}" >/dev/null 2>&1
            ufw allow "${console_port}/tcp" comment "MinIO Console UI" >/dev/null 2>&1 || ufw allow "${console_port}" >/dev/null 2>&1
            ufw reload >/dev/null 2>&1 || true
            echo -e "   ${GREEN}✓ Đã mở port ${api_port} & ${console_port} trên UFW!${NC}"
            opened=true
        fi
    fi

    # 2. Firewalld (CentOS, RHEL, Rocky, AlmaLinux)
    if command -v firewall-cmd >/dev/null 2>&1; then
        if systemctl is-active --quiet firewalld 2>/dev/null; then
            firewall-cmd --permanent --add-port="${api_port}/tcp" >/dev/null 2>&1 || true
            firewall-cmd --permanent --add-port="${console_port}/tcp" >/dev/null 2>&1 || true
            firewall-cmd --reload >/dev/null 2>&1 || true
            echo -e "   ${GREEN}✓ Đã mở port ${api_port} & ${console_port} trên Firewalld!${NC}"
            opened=true
        fi
    fi

    # 3. Iptables fallback
    if command -v iptables >/dev/null 2>&1; then
        for p in "$api_port" "$console_port"; do
            if ! iptables -C INPUT -p tcp --dport "${p}" -j ACCEPT >/dev/null 2>&1; then
                iptables -I INPUT -p tcp --dport "${p}" -j ACCEPT >/dev/null 2>&1 || true
            fi
        done
        opened=true
    fi

    if [ "$opened" = true ]; then
        echo -e "${GREEN}✓ Hoàn tất cấu hình tường lửa cục bộ.${NC}"
    else
        echo -e "${YELLOW}ℹ Không phát hiện firewall nội bộ đang kích hoạt.${NC}"
    fi

    echo -e "${MAGENTA}${BOLD}👉 LƯU Ý CHO CLOUD VPS:${NC}"
    echo -e "   Nếu dùng AWS EC2, GCP, Azure, Oracle, DigitalOcean, Linode, Hetzner, v.v:"
    echo -e "   Vui lòng mở ${BOLD}Inbound Port ${api_port} & ${console_port} (TCP)${NC} trên bảng điều khiển Security Group / Firewall Rules của nhà cung cấp.\n"
}

# Đọc cấu hình hiện tại từ .env
load_config() {
    if [ -f "$ENV_FILE" ]; then
        # shellcheck disable=SC1090
        . "$ENV_FILE" 2>/dev/null || true
    fi
    API_PORT="${MINIO_API_PORT:-$DEFAULT_API_PORT}"
    CONSOLE_PORT="${MINIO_CONSOLE_PORT:-$DEFAULT_CONSOLE_PORT}"
    ROOT_USER="${MINIO_ROOT_USER:-$DEFAULT_ROOT_USER}"
    ROOT_PASSWORD="${MINIO_ROOT_PASSWORD:-}"
    DATA_PATH="${MINIO_DATA_DIR:-$DATA_DIR}"
    MINIO_IMAGE="${MINIO_IMAGE:-$DEFAULT_MINIO_IMAGE}"
}

# Lưu cấu hình vào file .env
save_config() {
    mkdir -p "$INSTALL_DIR"
    cat > "$ENV_FILE" <<EOF
# MinIO Server Configuration
MINIO_API_PORT=${API_PORT}
MINIO_CONSOLE_PORT=${CONSOLE_PORT}
MINIO_ROOT_USER=${ROOT_USER}
MINIO_ROOT_PASSWORD=${ROOT_PASSWORD}
MINIO_DATA_DIR=${DATA_PATH}
MINIO_IMAGE=${MINIO_IMAGE}
EOF
    chmod 600 "$ENV_FILE"
}

# Tự động xác định và tải Docker Image tương thích cho MinIO
resolve_minio_image() {
    echo -e "${BLUE}ℹ Đang kiểm tra và chuẩn bị Docker Image cho MinIO...${NC}"
    local candidate_images=(
        "${MINIO_IMAGE}"
        "pgsty/minio:latest"
        "pgsty/silo:latest"
        "cgr.dev/chainguard/minio:latest"
    )

    local target_img=""
    for img in "${candidate_images[@]}"; do
        [ -z "$img" ] && continue
        # Bỏ qua image quay.io hoặc minio/minio đã bị đóng public (lỗi 401 / pull access denied)
        if [[ "$img" == *"quay.io/minio"* ]]; then
            continue
        fi

        echo -e "${YELLOW}⏳ Đang kiểm tra và tải Docker Image: ${BOLD}${img}${NC}...${NC}"
        if docker pull "$img"; then
            target_img="$img"
            echo -e "   ${GREEN}✓ Đã sẵn sàng image: ${BOLD}${target_img}${NC}\n"
            break
        else
            echo -e "   ${YELLOW}⚠ Không thể tải ${img}, đang thử image dự phòng tiếp theo...${NC}"
        fi
    done

    if [ -z "$target_img" ]; then
        echo -e "${RED}✗ Lỗi: Không thể tải image MinIO từ các kho Docker công khai!${NC}"
        echo -e "${YELLOW}ℹ Vui lòng kiểm tra lại kết nối internet trên máy chủ.${NC}"
        exit 1
    fi

    MINIO_IMAGE="$target_img"
}

# Tạo docker-compose.yml cho MinIO
generate_docker_compose() {
    mkdir -p "$INSTALL_DIR" "$DATA_PATH" "$CONFIG_DIR"
    chmod 750 "$DATA_PATH" "$CONFIG_DIR"

    local current_image="${MINIO_IMAGE:-$DEFAULT_MINIO_IMAGE}"

    cat > "$COMPOSE_FILE" <<EOF
services:
  minio:
    image: ${current_image}
    container_name: minio-server
    restart: unless-stopped
    command: server /data --console-address ":9001" --address ":9000"
    environment:
      MINIO_ROOT_USER: "${ROOT_USER}"
      MINIO_ROOT_PASSWORD: "${ROOT_PASSWORD}"
    ports:
      - "${API_PORT}:9000"
      - "${CONSOLE_PORT}:9001"
    volumes:
      - ${DATA_PATH}:/data
      - ${CONFIG_DIR}:/root/.minio
    healthcheck:
      test: ["CMD-SHELL", "curl -f http://127.0.0.1:9000/minio/health/live || timeout 2 bash -c '</dev/tcp/127.0.0.1/9000' || exit 1"]
      interval: 15s
      timeout: 5s
      retries: 3
    logging:
      driver: "json-file"
      options:
        max-size: "20m"
        max-file: "3"
EOF
    chmod 644 "$COMPOSE_FILE"
}

# Cài đặt hoặc cập nhật MinIO Client (mc) trên host
install_or_update_mc() {
    echo -e "\n${BLUE}ℹ Đang kiểm tra MinIO Client (mc)...${NC}"
    local mc_path="/usr/local/bin/mc"

    if ! command -v mc >/dev/null 2>&1; then
        echo -e "${YELLOW}ℹ Đang tải MinIO Client (mc) cho kiến trúc Linux ${MC_ARCH}...${NC}"
        local mc_url="https://dl.min.io/client/mc/release/linux-${MC_ARCH}/mc"
        
        if curl -fsSL "$mc_url" -o "$mc_path" 2>/dev/null || wget -q "$mc_url" -O "$mc_path" 2>/dev/null; then
            chmod +x "$mc_path"
            echo -e "${GREEN}✓ Đã cài đặt MinIO Client tại: ${mc_path}${NC}"
        else
            echo -e "${RED}⚠ Không thể tải binary mc từ dl.min.io (có thể do kết nối mạng). Bạn vẫn có thể dùng mc qua Docker.${NC}"
        fi
    else
        echo -e "${GREEN}✓ MinIO Client (mc) đã có sẵn trên hệ thống: $(command -v mc)${NC}"
    fi

    # Cấu hình alias local cho mc nếu mc đã sẵn sàng
    if command -v mc >/dev/null 2>&1 && [ -n "$ROOT_PASSWORD" ]; then
        echo -e "${BLUE}ℹ Đang cấu hình alias 'local' cho mc CLI...${NC}"
        mc alias set local "http://127.0.0.1:${API_PORT}" "$ROOT_USER" "$ROOT_PASSWORD" --api s3v4 >/dev/null 2>&1 || true
        echo -e "${GREEN}✓ Đã liên kết mc alias 'local' -> http://127.0.0.1:${API_PORT}${NC}"
    fi
}

# Tạo mật khẩu ngẫu nhiên an toàn (chữ hoa, thường, số)
generate_secure_password() {
    if command -v openssl >/dev/null 2>&1; then
        openssl rand -base64 16 | tr -dc 'a-zA-Z0-9' | head -c 16
    else
        tr -dc 'A-Za-z0-9' </dev/urandom | head -c 16
    fi
}

# Quy trình Cài đặt & Khởi chạy MinIO
deploy_minio() {
    show_banner
    detect_os
    ensure_utilities
    ensure_docker_and_compose
    get_server_ips
    load_config

    echo -e "${CYAN}${BOLD}===[ BƯỚC 1: CẤU HÌNH THÔNG SỐ MINIO SERVER ]===${NC}\n"

    # 1. API Port
    read -rp "Nhập Port S3 API [Mặc định: ${DEFAULT_API_PORT}]: " USER_API_PORT
    API_PORT="${USER_API_PORT:-$DEFAULT_API_PORT}"

    # 2. Console Port
    read -rp "Nhập Port Web Console Dashboard [Mặc định: ${DEFAULT_CONSOLE_PORT}]: " USER_CONSOLE_PORT
    CONSOLE_PORT="${USER_CONSOLE_PORT:-$DEFAULT_CONSOLE_PORT}"

    # Đảm bảo 2 port không trùng nhau
    if [ "$API_PORT" = "$CONSOLE_PORT" ]; then
        echo -e "${RED}✗ Lỗi: Port S3 API và Port Web Console không thể trùng nhau! Tự động đặt lại Console Port: 9001${NC}"
        CONSOLE_PORT="9001"
    fi

    # 3. Thư mục lưu trữ dữ liệu
    echo -e "\n${BLUE}ℹ Thư mục lưu dữ liệu MinIO Object Storage (Bucket Data):${NC}"
    read -rp "Nhập đường dẫn lưu dữ liệu [Mặc định: ${DEFAULT_DATA_DIR:-$DATA_DIR}]: " USER_DATA_PATH
    DATA_PATH="${USER_DATA_PATH:-$DATA_DIR}"

    # 4. Root User
    echo -e "\n${BLUE}ℹ Tài khoản Quản trị viên (Root User / Access Key):${NC}"
    read -rp "Nhập Root User [Mặc định: ${DEFAULT_ROOT_USER}]: " USER_ROOT_USER
    ROOT_USER="${USER_ROOT_USER:-$DEFAULT_ROOT_USER}"
    if [ ${#ROOT_USER} -lt 3 ]; then
        echo -e "${YELLOW}Root user phải có ít nhất 3 ký tự. Sử dụng mặc định: minioadmin${NC}"
        ROOT_USER="minioadmin"
    fi

    # 5. Root Password
    local auto_pass
    auto_pass=$(generate_secure_password)
    echo -e "\n${BLUE}ℹ Mật khẩu Quản trị viên (Root Password / Secret Key):${NC}"
    echo -e "   Gợi ý mật khẩu ngẫu nhiên an toàn: ${GREEN}${BOLD}${auto_pass}${NC}"
    read -rp "Nhập Root Password (tối thiểu 8 ký tự, nhấn Enter để dùng mật khẩu gợi ý): " USER_ROOT_PASS
    ROOT_PASSWORD="${USER_ROOT_PASS:-$auto_pass}"

    if [ ${#ROOT_PASSWORD} -lt 8 ]; then
        echo -e "${RED}✗ Mật khẩu quá ngắn (MinIO yêu cầu >= 8 ký tự). Sử dụng mật khẩu ngẫu nhiên: ${auto_pass}${NC}"
        ROOT_PASSWORD="$auto_pass"
    fi

    echo -e "\n${CYAN}${BOLD}===[ BƯỚC 2: TẠO CẤU HÌNH VÀ KHỞI TẠO CONTAINER ]===${NC}\n"
    resolve_minio_image
    save_config
    generate_docker_compose

    # Mở firewall
    open_firewall_ports "$API_PORT" "$CONSOLE_PORT"

    # Dừng container cũ nếu đang chạy
    cd "$INSTALL_DIR"
    echo -e "${BLUE}ℹ Đang khởi động MinIO Object Storage bằng Docker Compose...${NC}"
    run_compose down 2>/dev/null || true
    run_compose up -d --remove-orphans

    # Chờ dịch vụ sẵn sàng
    echo -e "${YELLOW}⏳ Đang chờ MinIO khởi động...${NC}"
    local count=0
    local ready=false
    while [ $count -lt 20 ]; do
        if curl -s -f "http://127.0.0.1:${API_PORT}/minio/health/live" >/dev/null 2>&1 || \
           curl -s "http://127.0.0.1:${API_PORT}" 2>/dev/null | grep -qi "MinIO"; then
            ready=true
            break
        fi
        sleep 1
        count=$((count + 1))
    done

    # Cài đặt mc client
    install_or_update_mc

    # Tự động tạo một bucket mẫu nếu mc sẵn sàng
    if command -v mc >/dev/null 2>&1; then
        mc mb local/default-bucket >/dev/null 2>&1 || true
    fi

    echo -e "\n${GREEN}${BOLD}==================================================================${NC}"
    echo -e "${GREEN}${BOLD}          🎉 CÀI ĐẶT MINIO OBJECT STORAGE THÀNH CÔNG!             ${NC}"
    echo -e "${GREEN}${BOLD}==================================================================${NC}\n"

    show_credentials
}

# Hiển thị thông tin kết nối và mẫu code
show_credentials() {
    load_config
    get_server_ips

    echo -e "${CYAN}${BOLD}📌 THÔNG TIN TRUY CẬP VÀ ĐĂNG NHẬP:${NC}"
    echo -e "   • ${BOLD}Web Console Dashboard:${NC} ${GREEN}http://${PUBLIC_IP}:${CONSOLE_PORT}${NC}"
    echo -e "     (Mạng nội bộ / LAN):       ${GREEN}http://${LOCAL_IP}:${CONSOLE_PORT}${NC}"
    echo -e "   • ${BOLD}S3 API Endpoint:${NC}       ${CYAN}http://${PUBLIC_IP}:${API_PORT}${NC}"
    echo -e "     (Mạng nội bộ / LAN):       ${CYAN}http://${LOCAL_IP}:${API_PORT}${NC}"
    echo -e "   • ${BOLD}Root User / Access Key:${NC} ${YELLOW}${BOLD}${ROOT_USER}${NC}"
    echo -e "   • ${BOLD}Root Password / Secret:${NC}  ${YELLOW}${BOLD}${ROOT_PASSWORD}${NC}"
    echo -e "   • ${BOLD}Thư mục lưu trữ dữ liệu:${NC} ${BOLD}${DATA_PATH}${NC}"
    echo -e "   • ${BOLD}File cấu hình:${NC}           ${BOLD}${ENV_FILE}${NC}\n"

    echo -e "${MAGENTA}${BOLD}🚀 LỆNH MINIO CLIENT (mc) TRÊN MÁY CHỦ:${NC}"
    echo -e "   mc ls local                     # Liệt kê các Bucket"
    echo -e "   mc mb local/<ten-bucket>        # Tạo Bucket mới"
    echo -e "   mc cp file.txt local/<bucket>/  # Tải file lên Bucket"
    echo -e "   mc admin info local             # Xem thông số hệ thống và dung lượng\n"

    echo -e "${BLUE}${BOLD}💻 MẪU CẤU HÌNH KẾT NỐI (PYTHON / BOTO3 / DIFY / LLM):${NC}"
    cat <<EOF
   AWS_ACCESS_KEY_ID = "${ROOT_USER}"
   AWS_SECRET_ACCESS_KEY = "${ROOT_PASSWORD}"
   AWS_ENDPOINT_URL = "http://${PUBLIC_IP}:${API_PORT}"
   AWS_REGION = "us-east-1"
EOF
    echo ""
}

# Kiểm tra trạng thái dịch vụ
check_status() {
    show_banner
    load_config
    get_server_ips

    echo -e "${BOLD}KIỂM TRA TRẠNG THÁI MINIO SERVER:${NC}\n"

    if [ ! -d "$INSTALL_DIR" ] || [ ! -f "$COMPOSE_FILE" ]; then
        echo -e "${RED}✗ Chưa tìm thấy cài đặt MinIO tại ${INSTALL_DIR}.${NC}\n"
        return 1
    fi

    cd "$INSTALL_DIR"
    echo -e "${BLUE}1. Trạng thái Docker Container:${NC}"
    run_compose ps

    echo -e "\n${BLUE}2. Kiểm tra Port lắng nghe trên máy chủ:${NC}"
    if command -v ss >/dev/null 2>&1; then
        ss -tulpn | grep -E "(:${API_PORT}|:${CONSOLE_PORT})" || echo -e "   ${YELLOW}Chưa thấy cổng ${API_PORT} hoặc ${CONSOLE_PORT} trong danh sách ss.${NC}"
    elif command -v netstat >/dev/null 2>&1; then
        netstat -tulpn | grep -E "(:${API_PORT}|:${CONSOLE_PORT})" || echo -e "   ${YELLOW}Chưa thấy cổng ${API_PORT} hoặc ${CONSOLE_PORT} trong danh sách netstat.${NC}"
    fi

    echo -e "\n${BLUE}3. Kiểm tra S3 API Health Endpoint:${NC}"
    local HTTP_CODE
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:${API_PORT}/minio/health/live" 2>/dev/null || echo "000")
    if [ "$HTTP_CODE" = "200" ]; then
        echo -e "   ${GREEN}✓ API S3 phản hồi HTTP 200 OK (Sẵn sàng hoạt động)!${NC}"
    else
        echo -e "   ${YELLOW}⚠ API S3 phản hồi mã HTTP: ${HTTP_CODE} (Đang khởi động hoặc cần kiểm tra logs).${NC}"
    fi

    # Kiểm tra mc nếu có
    if command -v mc >/dev/null 2>&1; then
        echo -e "\n${BLUE}4. Kiểm tra qua MinIO Client (mc admin info):${NC}"
        mc admin info local 2>/dev/null | head -n 12 || echo -e "   ${YELLOW}Chưa thể kết nối qua alias 'local'. Thử chạy lại cấu hình mc.${NC}"
    fi

    echo ""
    show_credentials
}

# Xem logs trực tiếp
view_logs() {
    if [ -d "$INSTALL_DIR" ]; then
        cd "$INSTALL_DIR"
        echo -e "\n${BLUE}ℹ Đang mở live log MinIO (Nhấn ${BOLD}Ctrl+C${NC} để thoát)...${NC}\n"
        run_compose logs -f minio
    else
        echo -e "${RED}✗ Chưa tìm thấy thư mục cài đặt ${INSTALL_DIR}.${NC}"
    fi
}

# Quản lý Buckets bằng MinIO Client (mc)
manage_buckets() {
    load_config

    if ! command -v mc >/dev/null 2>&1; then
        echo -e "${YELLOW}ℹ MinIO Client (mc) chưa được cài đặt. Đang tải và cấu hình...${NC}"
        detect_os
        install_or_update_mc
    fi

    if ! command -v mc >/dev/null 2>&1; then
        echo -e "${RED}✗ Không thể sử dụng mc client. Vui lòng kiểm tra kết nối internet.${NC}"
        return 1
    fi

    # Đảm bảo alias 'local' luôn trúng config hiện tại
    mc alias set local "http://127.0.0.1:${API_PORT}" "$ROOT_USER" "$ROOT_PASSWORD" >/dev/null 2>&1 || true

    while true; do
        echo -e "\n${CYAN}${BOLD}--- QUẢN LÝ BUCKET MINIO (mc CLI) ---${NC}"
        echo -e "   1) ${GREEN}Liệt kê các Bucket hiện có${NC}"
        echo -e "   2) ${BLUE}Tạo Bucket mới${NC}"
        echo -e "   3) ${YELLOW}Đặt chính sách chia sẻ Bucket (Public / Download / Private)${NC}"
        echo -e "   4) ${MAGENTA}Tải file thử nghiệm lên Bucket${NC}"
        echo -e "   5) ${RED}Xóa Bucket${NC}"
        echo -e "   0) Quay lại Menu chính"

        read -rp "Chọn thao tác [0-5]: " BUCKET_CHOICE

        case "$BUCKET_CHOICE" in
            1)
                echo -e "\n${BLUE}Danh sách Bucket:${NC}"
                mc ls local || true
                ;;
            2)
                read -rp "Nhập tên Bucket cần tạo (chữ thường, số, dấu gạch ngang): " NEW_BUCKET
                if [ -n "$NEW_BUCKET" ]; then
                    mc mb "local/${NEW_BUCKET}" && echo -e "${GREEN}✓ Đã tạo thành công bucket: ${NEW_BUCKET}${NC}" || true
                fi
                ;;
            3)
                read -rp "Nhập tên Bucket cần phân quyền: " POLICY_BUCKET
                if [ -n "$POLICY_BUCKET" ]; then
                    echo -e "Chọn quyền: 1) public (Đọc & Ghi mở) | 2) download (Chỉ cho phép đọc/tải công khai) | 3) none (Riêng tư - Private)"
                    read -rp "Lựa chọn [1/2/3]: " POL_OPT
                    case "$POL_OPT" in
                        1) mc anonymous set public "local/${POLICY_BUCKET}" ;;
                        2) mc anonymous set download "local/${POLICY_BUCKET}" ;;
                        3) mc anonymous set none "local/${POLICY_BUCKET}" ;;
                        *) echo -e "${YELLOW}Lựa chọn không hợp lệ.${NC}" ;;
                    esac
                fi
                ;;
            4)
                read -rp "Nhập tên Bucket muốn tải file thử nghiệm: " TEST_BUCKET
                if [ -n "$TEST_BUCKET" ]; then
                    local TEST_FILE="/tmp/minio_test_$(date +%s).txt"
                    echo "MinIO Object Storage Test Upload at $(date)" > "$TEST_FILE"
                    mc cp "$TEST_FILE" "local/${TEST_BUCKET}/" && echo -e "${GREEN}✓ Đã upload file thử nghiệm thành công lên ${TEST_BUCKET}!${NC}" || true
                    rm -f "$TEST_FILE"
                fi
                ;;
            5)
                read -rp "Nhập tên Bucket muốn xóa: " DEL_BUCKET
                if [ -n "$DEL_BUCKET" ]; then
                    read -rp "Bạn có chắc chắn muốn xóa bucket '${DEL_BUCKET}'? (yes/no): " DEL_CONFIRM
                    if [ "$DEL_CONFIRM" = "yes" ]; then
                        mc rb --force "local/${DEL_BUCKET}" && echo -e "${GREEN}✓ Đã xóa bucket ${DEL_BUCKET}.${NC}" || true
                    else
                        echo -e "${YELLOW}Hủy thao tác xóa.${NC}"
                    fi
                fi
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

# Thay đổi thông tin đăng nhập hoặc cổng truy cập
change_credentials() {
    show_banner
    load_config

    echo -e "${CYAN}${BOLD}CẬP NHẬT CẤU HÌNH MINIO:${NC}\n"
    echo -e "Hiện tại: S3 Port=${API_PORT}, Console Port=${CONSOLE_PORT}, User=${ROOT_USER}\n"

    read -rp "Nhập S3 API Port mới (Enter để giữ ${API_PORT}): " NEW_API_PORT
    API_PORT="${NEW_API_PORT:-$API_PORT}"

    read -rp "Nhập Console Web Port mới (Enter để giữ ${CONSOLE_PORT}): " NEW_CONSOLE_PORT
    CONSOLE_PORT="${NEW_CONSOLE_PORT:-$CONSOLE_PORT}"

    read -rp "Nhập Root User mới (Enter để giữ ${ROOT_USER}): " NEW_ROOT_USER
    ROOT_USER="${NEW_ROOT_USER:-$ROOT_USER}"

    read -rp "Nhập Root Password mới (Enter để giữ mật khẩu cũ): " NEW_ROOT_PASS
    if [ -n "$NEW_ROOT_PASS" ]; then
        if [ ${#NEW_ROOT_PASS} -lt 8 ]; then
            echo -e "${RED}✗ Mật khẩu phải có tối thiểu 8 ký tự! Giữ lại mật khẩu cũ.${NC}"
        else
            ROOT_PASSWORD="$NEW_ROOT_PASS"
        fi
    fi

    save_config
    generate_docker_compose
    open_firewall_ports "$API_PORT" "$CONSOLE_PORT"

    echo -e "\n${BLUE}ℹ Đang áp dụng cấu hình mới và khởi động lại MinIO...${NC}"
    cd "$INSTALL_DIR"
    run_compose up -d --remove-orphans

    if command -v mc >/dev/null 2>&1; then
        mc alias set local "http://127.0.0.1:${API_PORT}" "$ROOT_USER" "$ROOT_PASSWORD" >/dev/null 2>&1 || true
    fi

    echo -e "${GREEN}✓ Cập nhật thành công!${NC}\n"
    show_credentials
}

# Khởi động lại dịch vụ
restart_service() {
    if [ -d "$INSTALL_DIR" ]; then
        cd "$INSTALL_DIR"
        echo -e "\n${BLUE}ℹ Đang khởi động lại container MinIO...${NC}"
        run_compose restart
        echo -e "${GREEN}✓ Đã khởi động lại thành công!${NC}"
    else
        echo -e "${RED}✗ Không tìm thấy thư mục cài đặt ${INSTALL_DIR}.${NC}"
    fi
}

# Dừng dịch vụ
stop_service() {
    if [ -d "$INSTALL_DIR" ]; then
        cd "$INSTALL_DIR"
        echo -e "\n${YELLOW}ℹ Đang dừng container MinIO...${NC}"
        run_compose stop
        echo -e "${GREEN}✓ Đã dừng dịch vụ MinIO.${NC}"
    else
        echo -e "${RED}✗ Không tìm thấy thư mục cài đặt ${INSTALL_DIR}.${NC}"
    fi
}

# Khởi động dịch vụ
start_service() {
    if [ -d "$INSTALL_DIR" ]; then
        cd "$INSTALL_DIR"
        echo -e "\n${BLUE}ℹ Đang khởi động container MinIO...${NC}"
        run_compose up -d
        echo -e "${GREEN}✓ Đã khởi chạy dịch vụ MinIO.${NC}"
    else
        echo -e "${RED}✗ Không tìm thấy thư mục cài đặt ${INSTALL_DIR}.${NC}"
    fi
}

# Sao lưu cấu hình
backup_minio_config() {
    local backup_tar="/opt/minio_backup_$(date +%Y%m%d_%H%M%S).tar.gz"
    echo -e "\n${BLUE}ℹ Đang tiến hành sao lưu cấu hình MinIO...${NC}"
    if [ -d "$INSTALL_DIR" ]; then
        tar -czf "$backup_tar" -C "$INSTALL_DIR" docker-compose.yml .env 2>/dev/null || true
        echo -e "${GREEN}✓ Đã tạo file sao lưu tại: ${backup_tar}${NC}"
        echo -e "${YELLOW}ℹ Lưu ý: File này chứa file compose và .env (không bao gồm toàn bộ dữ liệu storage trong ${DATA_PATH}).${NC}\n"
    else
        echo -e "${RED}✗ Không tìm thấy thư mục ${INSTALL_DIR}.${NC}"
    fi
}

# Gỡ bỏ MinIO hoàn toàn
uninstall_minio() {
    echo -e "\n${RED}${BOLD}⚠ CẢNH BÁO: BẠN CÓ CHẮC CHẮN MUỐN GỠ BỎ MINIO?${NC}"
    read -rp "Xác nhận gỡ bỏ dịch vụ MinIO? (gõ 'yes' để tiếp tục): " CONFIRM
    if [ "$CONFIRM" != "yes" ]; then
        echo -e "${YELLOW}Hủy bỏ thao tác gỡ bỏ.${NC}"
        return 0
    fi

    load_config

    if [ -d "$INSTALL_DIR" ]; then
        cd "$INSTALL_DIR"
        echo -e "${YELLOW}ℹ Đang gỡ bỏ container MinIO...${NC}"
        run_compose down -v --remove-orphans 2>/dev/null || true
    fi

    read -rp "Bạn có muốn XÓA TOÀN BỘ DỮ LIỆU ĐÃ LƯU TRONG ${DATA_PATH}? (gõ 'DELETE' để xóa sạch, nhấn Enter để giữ lại): " DEL_DATA
    if [ "$DEL_DATA" = "DELETE" ]; then
        rm -rf "$DATA_PATH"
        echo -e "${RED}✓ Đã xóa toàn bộ thư mục dữ liệu ${DATA_PATH}.${NC}"
    else
        echo -e "${GREEN}✓ Đã giữ lại thư mục dữ liệu ${DATA_PATH}.${NC}"
    fi

    rm -rf "$INSTALL_DIR"
    echo -e "${GREEN}✓ Đã gỡ bỏ hoàn toàn MinIO Server khỏi hệ thống.${NC}\n"
}

# Menu điều khiển chính
main_menu() {
    show_banner
    detect_os
    load_config

    echo -e "${BOLD}Chọn tác vụ bạn muốn thực hiện:${NC}"
    echo -e "   1) ${GREEN}${BOLD}Cài đặt & Khởi chạy MinIO Server (Docker Compose + mc CLI)${NC}"
    echo -e "   2) ${YELLOW}Kiểm tra trạng thái dịch vụ & Xem thông tin truy cập (Credentials)${NC}"
    echo -e "   3) ${CYAN}Xem Live Logs của MinIO Server${NC}"
    echo -e "   4) ${MAGENTA}Quản lý Bucket & Thử nghiệm tải file (MinIO mc CLI)${NC}"
    echo -e "   5) ${BLUE}Cập nhật cấu hình / Đổi mật khẩu Admin / Đổi Port${NC}"
    echo -e "   6) Mở / Kiểm tra lại Firewall (Port ${API_PORT} & ${CONSOLE_PORT})"
    echo -e "   7) Khởi động lại dịch vụ (Restart)"
    echo -e "   8) Dừng dịch vụ (Stop)"
    echo -e "   9) Khởi động dịch vụ (Start)"
    echo -e "   10) Sao lưu cấu hình MinIO"
    echo -e "   11) ${RED}Gỡ bỏ MinIO hoàn toàn (Uninstall)${NC}"
    echo -e "   0) Thoát"

    echo ""
    read -rp "Nhập lựa chọn của bạn [0-11] (Mặc định: 1): " MENU_CHOICE
    MENU_CHOICE="${MENU_CHOICE:-1}"

    case "$MENU_CHOICE" in
        1) deploy_minio ;;
        2) check_status ;;
        3) view_logs ;;
        4) manage_buckets ;;
        5) change_credentials ;;
        6) open_firewall_ports "$API_PORT" "$CONSOLE_PORT" ;;
        7) restart_service ;;
        8) stop_service ;;
        9) start_service ;;
        10) backup_minio_config ;;
        11) uninstall_minio ;;
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

# Hỗ trợ chạy trực tiếp qua tham số dòng lệnh
if [ $# -gt 0 ]; then
    detect_os
    load_config
    case "$1" in
        install|setup) deploy_minio ;;
        status) check_status ;;
        logs) view_logs ;;
        restart) restart_service ;;
        stop) stop_service ;;
        start) start_service ;;
        mc) manage_buckets ;;
        firewall) open_firewall_ports "$API_PORT" "$CONSOLE_PORT" ;;
        backup) backup_minio_config ;;
        uninstall) uninstall_minio ;;
        *)
            echo -e "${RED}Tham số không hợp lệ:${NC} $1"
            echo -e "Sử dụng: $0 [install|status|logs|restart|stop|start|mc|firewall|backup|uninstall]"
            exit 1
            ;;
    esac
else
    main_menu
fi
