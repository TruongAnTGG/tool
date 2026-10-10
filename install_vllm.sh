#!/usr/bin/env bash

# ==============================================================================
# Script Tự Động Cài Đặt, Cấu Hình & Quản Lý vLLM Server (Linux GPU / CPU)
# Mở port 8888 (Listen 0.0.0.0) tương thích chuẩn OpenAI API cho các hệ thống khác
# Hỗ trợ: Docker (Khuyên dùng) hoặc Python Virtualenv + Systemd
# Hỗ trợ: Ubuntu, Debian, CentOS, RHEL, AlmaLinux, RockyLinux
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

# Các giá trị mặc định cấu hình
DEFAULT_PORT="8888"
CONFIG_FILE="/etc/vllm/vllm.conf"
DOCKER_CONTAINER_NAME="vllm-server"
SYSTEMD_SERVICE_NAME="vllm"
VLLM_VENV_DIR="/opt/vllm-env"
DEFAULT_MODEL="Qwen/Qwen2.5-7B-Instruct-AWQ"

# Hiển thị banner
show_banner() {
    clear 2>/dev/null || true
    echo -e "${CYAN}${BOLD}=================================================================${NC}"
    echo -e "${CYAN}${BOLD}     HỆ THỐNG CÀI ĐẶT & QUẢN LÝ vLLM HIGH-PERFORMANCE SERVER     ${NC}"
    echo -e "${CYAN}${BOLD}          Tương thích OpenAI API - Mở kết nối Port 8888          ${NC}"
    echo -e "${CYAN}${BOLD}=================================================================${NC}\n"
}

# Kiểm tra quyền root
check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}✗ Lỗi: Script yêu cầu quyền root để cài đặt dịch vụ và mở Firewall.${NC}"
        echo -e "${YELLOW}ℹ Vui lòng chạy lại bằng lệnh:${NC} ${BOLD}sudo bash $0${NC}\n"
        exit 1
    fi
}

# Nhận diện OS và Linux Distro
detect_os() {
    OS="$(uname -s)"
    ARCH="$(uname -m)"
    DISTRO="unknown"
    PKG_MANAGER=""

    if [ "$OS" != "Linux" ]; then
        echo -e "${RED}✗ Lỗi: vLLM Server khuyến nghị chạy trên môi trường máy chủ Linux.${NC}"
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

# Lấy địa chỉ IP máy chủ (Public & Local)
get_server_ips() {
    LOCAL_IP=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "127.0.0.1")
    PUBLIC_IP=$(curl -s4 --max-time 3 https://ifconfig.me 2>/dev/null || \
                curl -s4 --max-time 3 https://api.ipify.org 2>/dev/null || \
                curl -s4 --max-time 3 https://icanhazip.com 2>/dev/null || \
                echo "$LOCAL_IP")
}

# Biến trạng thái GPU
HAS_NVIDIA_HARDWARE=false
HAS_NVIDIA_DRIVER=false
HAS_NVIDIA_DOCKER_READY=false

# 1. Phát hiện phần cứng card đồ họa NVIDIA qua PCIe (lspci)
detect_nvidia_hardware() {
    if ! command -v lspci >/dev/null 2>&1; then
        if [ "$PKG_MANAGER" = "apt-get" ]; then
            apt-get update -qq >/dev/null 2>&1 || true
            apt-get install -y -qq pciutils >/dev/null 2>&1 || true
        elif [ "$PKG_MANAGER" = "dnf" ] || [ "$PKG_MANAGER" = "yum" ]; then
            $PKG_MANAGER install -y -q pciutils >/dev/null 2>&1 || true
        fi
    fi

    if command -v lspci >/dev/null 2>&1; then
        PCI_NVIDIA=$(lspci 2>/dev/null | grep -iE 'nvidia|vga compatible controller: nvidia|3d controller: nvidia' || true)
        if [ -n "$PCI_NVIDIA" ]; then
            HAS_NVIDIA_HARDWARE=true
            echo -e "${GREEN}✓ Phát hiện phần cứng card đồ họa NVIDIA trên máy chủ:${NC}"
            while IFS= read -r line; do
                echo -e "   ${BOLD}⚡ $line${NC}"
            done <<< "$PCI_NVIDIA"
        else
            HAS_NVIDIA_HARDWARE=false
        fi
    fi
}

# 2. Cài đặt NVIDIA Driver chính thức trên máy chủ (Host)
install_host_nvidia_driver() {
    echo -e "\n${CYAN}${BOLD}=== TIẾN HÀNH CÀI ĐẶT NVIDIA DRIVER CHO MÁY CHỦ ===${NC}"
    echo -e "${BLUE}ℹ Đang cài đặt Kernel Headers và công cụ build DKMS...${NC}"

    local KERNEL_VER
    KERNEL_VER="$(uname -r)"

    if [ "$PKG_MANAGER" = "apt-get" ]; then
        apt-get update -qq
        apt-get install -y -qq linux-headers-"$KERNEL_VER" build-essential dkms ubuntu-drivers-common ca-certificates curl

        echo -e "${BLUE}ℹ Đang dò tìm và cài đặt bản driver NVIDIA phù hợp nhất...${NC}"
        if command -v ubuntu-drivers >/dev/null 2>&1; then
            ubuntu-drivers install || apt-get install -y -qq nvidia-driver-550 || apt-get install -y -qq nvidia-driver-535 || true
        else
            apt-get install -y -qq nvidia-driver-550 || apt-get install -y -qq nvidia-driver-535 || true
        fi
    elif [ "$PKG_MANAGER" = "dnf" ] || [ "$PKG_MANAGER" = "yum" ]; then
        $PKG_MANAGER install -y -q epel-release || true
        $PKG_MANAGER install -y -q kernel-devel-"$KERNEL_VER" kernel-headers-"$KERNEL_VER" gcc make dkms
        
        # Thêm repo NVIDIA CUDA RPM nếu chưa có
        if ! rpm -qa | grep -q "cuda-repo"; then
            echo -e "${BLUE}ℹ Đang thêm kho phần mềm NVIDIA chính thức...${NC}"
            curl -s -L https://developer.download.nvidia.com/compute/cuda/repos/rhel9/x86_64/cuda-rhel9.repo | tee /etc/yum.repos.d/cuda.repo >/dev/null 2>&1 || true
        fi
        $PKG_MANAGER module install -y -q nvidia-driver:latest-dkms || $PKG_MANAGER install -y -q kmod-nvidia nvidia-x11-drv || true
    fi

    echo -e "${BLUE}ℹ Đang thử nạp kernel module 'nvidia'...${NC}"
    modprobe nvidia 2>/dev/null || true

    if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi >/dev/null 2>&1; then
        echo -e "${GREEN}${BOLD}✓ Cài đặt NVIDIA Driver thành công! Hệ thống đã nhận diện GPU.${NC}"
        HAS_NVIDIA_DRIVER=true
    else
        echo -e "\n${YELLOW}${BOLD}⚠ LƯU Ý QUAN TRỌNG VỀ DRIVER:${NC}"
        echo -e "${YELLOW}Driver vừa được biên dịch vào nhân Linux. Thông thường, máy chủ cần khởi động lại (Reboot)${NC}"
        echo -e "${YELLOW}để nạp đầy đủ các module NVIDIA vào Kernel.${NC}"
        echo ""
        read -rp "Bạn có muốn khởi động lại máy chủ ngay bây giờ không? [y/N]: " DO_REBOOT
        if [[ "$DO_REBOOT" =~ ^[Yy]$ ]]; then
            echo -e "${GREEN}Đang khởi động lại máy chủ... Sau khi máy bật lại, hãy chạy lại script này.${NC}"
            sync
            reboot
            exit 0
        fi
    fi
}

# 3. Kiểm tra tổng quan card đồ họa NVIDIA & CUDA
check_gpu() {
    echo -e "${BLUE}ℹ Đang kiểm tra thông tin GPU NVIDIA trên máy chủ...${NC}"
    detect_nvidia_hardware

    GPU_VRAM_MB=0
    GPU_VRAM_GB=0

    if command -v nvidia-smi >/dev/null 2>&1; then
        GPU_INFO=$(nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv,noheader 2>/dev/null || echo "")
        if [ -n "$GPU_INFO" ]; then
            echo -e "${GREEN}✓ NVIDIA Driver đang hoạt động bình thường:${NC}"
            while IFS= read -r line; do
                echo -e "   ${BOLD}⚡ $line${NC}"
            done <<< "$GPU_INFO"
            HAS_NVIDIA_DRIVER=true
            HAS_NVIDIA_GPU=true

            # Lấy dung lượng VRAM thực tế (MiB)
            GPU_VRAM_MB=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | head -n 1 | tr -d ' ' || echo "0")
            if [ -n "$GPU_VRAM_MB" ] && [ "$GPU_VRAM_MB" -gt 0 ] 2>/dev/null; then
                GPU_VRAM_GB=$(( (GPU_VRAM_MB + 512) / 1024 ))
                echo -e "   ${CYAN}ℹ Dung lượng VRAM phát hiện:${NC} ${BOLD}~${GPU_VRAM_GB} GiB (${GPU_VRAM_MB} MiB)${NC}"
            fi
        else
            echo -e "${RED}✗ Lệnh nvidia-smi có tồn tại nhưng không giao tiếp được với Driver!${NC}"
            HAS_NVIDIA_DRIVER=false
            HAS_NVIDIA_GPU=false
        fi
    else
        echo -e "${YELLOW}⚠ Chưa tìm thấy lệnh 'nvidia-smi' trên máy chủ.${NC}"
        HAS_NVIDIA_DRIVER=false
        HAS_NVIDIA_GPU=false
    fi

    # Nếu có phần cứng nhưng chưa có Driver hoạt động
    if [ "$HAS_NVIDIA_HARDWARE" = true ] && [ "$HAS_NVIDIA_DRIVER" = false ]; then
        echo -e "\n${YELLOW}${BOLD}👉 PHÁT HIỆN: Máy chủ có card NVIDIA GPU nhưng chưa cài NVIDIA Driver!${NC}"
        echo -e "Để chạy vLLM tăng tốc bằng GPU trên Docker, máy chủ bắt buộc phải có NVIDIA Driver."
        read -rp "Bạn có muốn cài đặt NVIDIA Driver ngay bây giờ không? [Y/n]: " WANT_DRIVER
        WANT_DRIVER="${WANT_DRIVER:-Y}"
        if [[ "$WANT_DRIVER" =~ ^[Yy]$ ]]; then
            install_host_nvidia_driver
            check_gpu
        fi
    fi
}

# Mở Firewall Port (Hỗ trợ UFW, Firewalld, iptables)
open_firewall_port() {
    local port="${1:-8888}"
    echo -e "\n${BLUE}ℹ Đang kiểm tra và mở tường lửa (Firewall) cho Port ${BOLD}${port}/tcp${NC}...${NC}"

    local opened=false

    # 1. UFW (Ubuntu/Debian)
    if command -v ufw >/dev/null 2>&1; then
        UFW_STATUS=$(ufw status 2>/dev/null | grep -i "Status: active" || true)
        if [ -n "$UFW_STATUS" ]; then
            echo -e "   -> Cấu hình UFW rule cho port ${port}..."
            ufw allow "${port}/tcp" comment "vLLM Server API" >/dev/null 2>&1 || ufw allow "${port}" >/dev/null 2>&1
            ufw reload >/dev/null 2>&1 || true
            echo -e "   ${GREEN}✓ Đã mở port ${port} trên UFW!${NC}"
            opened=true
        fi
    fi

    # 2. Firewalld (CentOS, RHEL, Rocky, AlmaLinux)
    if command -v firewall-cmd >/dev/null 2>&1; then
        if systemctl is-active --quiet firewalld 2>/dev/null; then
            echo -e "   -> Cấu hình Firewalld rule cho port ${port}..."
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
        echo -e "${GREEN}✓ Hoàn tất mở cổng ${port}/tcp trên máy chủ.${NC}"
    else
        echo -e "${YELLOW}ℹ Không phát hiện firewall nội bộ đang chặn, cổng ${port} sẵn sàng.${NC}"
    fi

    echo -e "${MAGENTA}${BOLD}👉 LƯU Ý QUAN TRỌNG VỀ CLOUD VPS:${NC}"
    echo -e "   Nếu bạn dùng AWS EC2, Google Cloud, Azure, DigitalOcean, Oracle Cloud, Linode:"
    echo -e "   Hãy chắc chắn bạn đã vào ${BOLD}Security Group / Firewall Rules${NC} trên web console"
    echo -e "   và thêm rule: ${BOLD}Inbound Port ${port}/tcp -> Source: 0.0.0.0/0${NC} (hoặc IP cụ thể của bạn).\n"
}

# Đọc cấu hình đã lưu
load_config() {
    if [ -f "$CONFIG_FILE" ]; then
        # shellcheck disable=SC1090
        . "$CONFIG_FILE"
    fi
    PORT="${PORT:-$DEFAULT_PORT}"
    MODEL="${MODEL:-$DEFAULT_MODEL}"
    MODE="${MODE:-docker}"
    GPU_MEM_UTIL="${GPU_MEM_UTIL:-0.9}"
    MAX_MODEL_LEN="${MAX_MODEL_LEN:-}"
    ENFORCE_EAGER="${ENFORCE_EAGER:-false}"
    API_KEY="${API_KEY:-}"
    HF_TOKEN="${HF_TOKEN:-}"
    SERVE_EXTRA_ARGS="${SERVE_EXTRA_ARGS:-}"
}

# Lưu cấu hình ra file
save_config() {
    mkdir -p "$(dirname "$CONFIG_FILE")"
    cat > "$CONFIG_FILE" <<EOF
# Cấu hình vLLM Server tự động sinh bởi install_vllm.sh
MODE="${MODE}"
PORT="${PORT}"
MODEL="${MODEL}"
GPU_MEM_UTIL="${GPU_MEM_UTIL}"
MAX_MODEL_LEN="${MAX_MODEL_LEN}"
ENFORCE_EAGER="${ENFORCE_EAGER}"
API_KEY="${API_KEY}"
HF_TOKEN="${HF_TOKEN}"
SERVE_EXTRA_ARGS="${SERVE_EXTRA_ARGS}"
EOF
    chmod 600 "$CONFIG_FILE"
}

# Thu thập thông tin cấu hình từ người dùng
collect_user_config() {
    echo -e "${CYAN}${BOLD}--- BƯỚC 1: CẤU HÌNH THÔNG SỐ vLLM SERVER ---${NC}\n"

    # Lựa chọn cổng port
    read -rp "$(echo -e "${BOLD}1. Cổng lắng nghe (Port)${NC} [Mặc định: ${GREEN}${DEFAULT_PORT}${NC}]: ")" INPUT_PORT
    PORT="${INPUT_PORT:-$DEFAULT_PORT}"

    # Cảnh báo bộ nhớ VRAM tự động
    if [ "$GPU_VRAM_MB" -gt 0 ] 2>/dev/null && [ "$GPU_VRAM_MB" -lt 15500 ] 2>/dev/null; then
        echo -e "\n${YELLOW}${BOLD}⚠ PHÂN TÍCH VRAM GPU (${GPU_VRAM_MB} MiB ~ ${GPU_VRAM_GB} GiB):${NC}"
        echo -e "${YELLOW}   Model 7B gốc dạng ${BOLD}bfloat16${NC} chiếm ~15 GiB VRAM -> ${RED}${BOLD}Chắc chắn bị CUDA Out of Memory!${NC}"
        echo -e "   👉 ${GREEN}${BOLD}Giải pháp tối ưu tuyệt đối:${NC} Sử dụng bản nén ${BOLD}AWQ 4-bit${NC} (${CYAN}Qwen2.5-7B-Instruct-AWQ${NC})"
        echo -e "      chỉ tốn ${GREEN}~5 GiB VRAM${NC}, giữ nguyên 99% trí thông minh và chạy mượt mà trên GPU ${GPU_VRAM_GB}GB."
    fi

    # Lựa chọn Model
    echo -e "\n${BOLD}2. Chọn Mô hình AI (Model):${NC}"
    echo -e "   1) ${GREEN}${BOLD}Qwen/Qwen2.5-7B-Instruct-AWQ${NC}       (Khuyên dùng: Chuẩn AWQ 4-bit, chỉ tốn ~5GB VRAM, chống OOM 100%)"
    echo -e "   2) ${CYAN}Qwen/Qwen2.5-Coder-7B-Instruct-AWQ${NC} (Chuyên lập trình code, tối ưu cho GPU 8GB-12GB)"
    echo -e "   3) ${CYAN}Qwen/Qwen2.5-3B-Instruct${NC}           (Model 3B cân bằng, tốn ~6GB VRAM)"
    echo -e "   4) ${CYAN}Qwen/Qwen2.5-1.5B-Instruct${NC}         (Siêu nhẹ, tốn ~3GB VRAM, chạy được trên mọi GPU/CPU)"
    echo -e "   5) ${YELLOW}Qwen/Qwen2.5-7B-Instruct${NC}          (Bản gốc bfloat16 không nén - Yêu cầu GPU >= 16GB VRAM)"
    echo -e "   6) ${CYAN}meta-llama/Meta-Llama-3.1-8B-Instruct-AWQ${NC} (Llama 3.1 8B AWQ, cần HF_TOKEN)"
    echo -e "   7) ${CYAN}mistralai/Mistral-7B-Instruct-v0.3${NC}"
    echo -e "   8) ${CYAN}Nhập tên Model HuggingFace khác hoặc đường dẫn ổ đĩa cục bộ${NC}"
    read -rp "Lựa chọn model [1-8] (Mặc định: 1): " MODEL_CHOICE
    MODEL_CHOICE="${MODEL_CHOICE:-1}"

    case "$MODEL_CHOICE" in
        1) MODEL="Qwen/Qwen2.5-7B-Instruct-AWQ" ;;
        2) MODEL="Qwen/Qwen2.5-Coder-7B-Instruct-AWQ" ;;
        3) MODEL="Qwen/Qwen2.5-3B-Instruct" ;;
        4) MODEL="Qwen/Qwen2.5-1.5B-Instruct" ;;
        5) MODEL="Qwen/Qwen2.5-7B-Instruct" ;;
        6) MODEL="meta-llama/Meta-Llama-3.1-8B-Instruct-AWQ" ;;
        7) MODEL="mistralai/Mistral-7B-Instruct-v0.3" ;;
        8)
            read -rp "Nhập tên Model (VD: Qwen/Qwen2.5-7B-Instruct-AWQ hoặc /models/my-model): " CUSTOM_MODEL
            if [ -z "$CUSTOM_MODEL" ]; then
                MODEL="Qwen/Qwen2.5-7B-Instruct-AWQ"
            else
                MODEL="$CUSTOM_MODEL"
            fi
            ;;
        *) MODEL="Qwen/Qwen2.5-7B-Instruct-AWQ" ;;
    esac

    # Cấu hình API Key bảo mật
    echo -e "\n${BOLD}3. Cấu hình Khóa API (API Key bảo mật):${NC}"
    echo -e "   Để trống nếu muốn API mở tự do (dành cho mạng nội bộ/VPN)."
    echo -e "   Nhập chuỗi bí mật nếu muốn các hệ thống khác phải gửi kèm header: 'Authorization: Bearer <KEY>'."
    read -rp "Nhập API Key (Mặc định: không dùng key): " INPUT_API_KEY
    API_KEY="$INPUT_API_KEY"

    # Cấu hình HuggingFace Token
    echo -e "\n${BOLD}4. HuggingFace Token (HF_TOKEN):${NC}"
    echo -e "   Cần thiết nếu tải model có yêu cầu bản quyền (Llama 3, Gemma,...)."
    read -rp "Nhập Hugging Face Token (Để trống nếu tải model công khai như Qwen): " INPUT_HF_TOKEN
    HF_TOKEN="$INPUT_HF_TOKEN"

    # GPU Memory Utilization
    echo -e "\n${BOLD}5. Tỷ lệ cấp phát bộ nhớ GPU (GPU Memory Utilization):${NC}"
    echo -e "   Giá trị từ 0.5 đến 0.95 (Mặc định: 0.9 = 90% VRAM GPU)."
    read -rp "GPU Memory Utilization [0.5 - 0.95] (Mặc định: 0.9): " INPUT_UTIL
    GPU_MEM_UTIL="${INPUT_UTIL:-0.9}"

    # Giới hạn context length để chống OOM KV Cache
    local DEFAULT_MAX_LEN="4096"
    if [ "$GPU_VRAM_MB" -ge 16000 ] 2>/dev/null; then
        DEFAULT_MAX_LEN="8192"
    fi

    echo -e "\n${BOLD}6. Giới hạn độ dài ngữ cảnh (Max Model Length):${NC}"
    echo -e "   Mặc định gốc của model thường là 32,768 tokens (chiếm hàng GB VRAM cho KV Cache dễ gây crash OOM)."
    echo -e "   Khuyên dùng: 4096 hoặc 8192 là cực kỳ thoải mái cho Chat, Agent, Lập trình."
    read -rp "Max Model Len [Mặc định: ${DEFAULT_MAX_LEN}]: " INPUT_MAX_LEN
    MAX_MODEL_LEN="${INPUT_MAX_LEN:-$DEFAULT_MAX_LEN}"

    # Tùy chọn Enforce Eager mode cho GPU <= 16GB
    ENFORCE_EAGER=false
    if [ "$GPU_VRAM_MB" -gt 0 ] 2>/dev/null && [ "$GPU_VRAM_MB" -lt 15500 ] 2>/dev/null; then
        echo -e "\n${BOLD}7. Chế độ Enforce Eager (Tiết kiệm bộ nhớ CUDA Graph):${NC}"
        echo -e "   Bật chế độ này sẽ tắt pre-allocation của CUDA Graph, tiết kiệm thêm ~1.0 GiB VRAM."
        read -rp "Bật Enforce Eager? [Y/n] (Mặc định: Y): " INPUT_EAGER
        INPUT_EAGER="${INPUT_EAGER:-Y}"
        if [[ "$INPUT_EAGER" =~ ^[Yy]$ ]]; then
            ENFORCE_EAGER=true
        fi
    fi
}

# Cài đặt NVIDIA Container Toolkit (Cho Docker)
install_nvidia_container_toolkit() {
    echo -e "\n${BLUE}ℹ Kiểm tra NVIDIA Container Toolkit (nvidia-docker / nvidia-ctk)...${NC}"
    if command -v nvidia-ctk >/dev/null 2>&1; then
        echo -e "${GREEN}✓ NVIDIA Container Toolkit đã được cài đặt.${NC}"
    else
        echo -e "${YELLOW}ℹ Chưa tìm thấy nvidia-ctk, đang tiến hành cấu hình kho và cài đặt...${NC}"
        
        if [ "$PKG_MANAGER" = "apt-get" ]; then
            curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg --yes 2>/dev/null || true
            curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
                sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
                tee /etc/apt/sources.list.d/nvidia-container-toolkit.list >/dev/null
            apt-get update -qq
            apt-get install -y -qq nvidia-container-toolkit
        elif [ "$PKG_MANAGER" = "dnf" ] || [ "$PKG_MANAGER" = "yum" ]; then
            curl -s -L https://nvidia.github.io/libnvidia-container/stable/rpm/nvidia-container-toolkit.repo | \
                tee /etc/yum.repos.d/nvidia-container-toolkit.repo >/dev/null
            $PKG_MANAGER install -y -q nvidia-container-toolkit
        fi
    fi

    if command -v nvidia-ctk >/dev/null 2>&1; then
        echo -e "${BLUE}ℹ Đang đăng ký NVIDIA runtime vào Docker daemon (/etc/docker/daemon.json)...${NC}"
        nvidia-ctk runtime configure --runtime=docker >/dev/null 2>&1 || true
        systemctl restart docker >/dev/null 2>&1 || true
        echo -e "${GREEN}✓ Cài đặt và cấu hình NVIDIA Container Toolkit thành công!${NC}"
    else
        echo -e "${RED}⚠ Không thể tự động cấu hình nvidia-ctk. Vui lòng kiểm tra lại kết nối mạng hoặc kho gói.${NC}"
    fi
}

# Cài đặt Docker Engine tự động nếu chưa có
ensure_docker() {
    if ! command -v docker >/dev/null 2>&1; then
        echo -e "${YELLOW}ℹ Chưa tìm thấy Docker trên hệ thống. Đang tiến hành cài đặt Docker Engine chính thức...${NC}"
        curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
        sh /tmp/get-docker.sh
        rm -f /tmp/get-docker.sh
        systemctl enable --now docker
        echo -e "${GREEN}✓ Cài đặt Docker Engine thành công!${NC}"
    fi

    systemctl start docker 2>/dev/null || true
}

# Kiểm tra toàn diện điều kiện GPU trước khi chạy Docker
verify_docker_gpu_support() {
    echo -e "\n${CYAN}${BOLD}=== KIỂM TRA ĐIỀU KIỆN GPU CHO DOCKER TRƯỚC KHI CHẠY vLLM ===${NC}"
    
    # 1. Kiểm tra phần cứng
    detect_nvidia_hardware
    if [ "$HAS_NVIDIA_HARDWARE" = false ] && [ "$HAS_NVIDIA_GPU" = false ]; then
        echo -e "${YELLOW}ℹ Không phát hiện card đồ họa NVIDIA vật lý trên máy chủ. Server sẽ khởi chạy ở chế độ CPU.${NC}"
        HAS_NVIDIA_GPU=false
        return 0
    fi

    # 2. Kiểm tra Driver trên máy chủ
    if ! command -v nvidia-smi >/dev/null 2>&1 || ! nvidia-smi >/dev/null 2>&1; then
        echo -e "${RED}✗ Lỗi: Đã phát hiện card NVIDIA nhưng Driver trên máy chủ chưa hoạt động!${NC}"
        echo -e "   1) Tự động cài đặt NVIDIA Driver ngay bây giờ [Khuyên dùng]"
        echo -e "   2) Bỏ qua GPU và thử chạy bằng CPU"
        echo -e "   3) Hủy bỏ để kiểm tra lại hệ thống"
        read -rp "Lựa chọn [1/2/3] (Mặc định: 1): " GPU_DRV_CHOICE
        GPU_DRV_CHOICE="${GPU_DRV_CHOICE:-1}"

        if [ "$GPU_DRV_CHOICE" = "1" ]; then
            install_host_nvidia_driver
            check_gpu
            if [ "$HAS_NVIDIA_DRIVER" = false ]; then
                echo -e "${YELLOW}ℹ Driver cần máy chủ khởi động lại (sudo reboot). Hủy bỏ tiến trình triển khai Docker GPU.${NC}"
                exit 1
            fi
        elif [ "$GPU_DRV_CHOICE" = "2" ]; then
            HAS_NVIDIA_GPU=false
            return 0
        else
            echo -e "${YELLOW}Đã hủy tiến trình.${NC}"
            exit 1
        fi
    fi

    # 3. Cài đặt Docker & NVIDIA Container Toolkit
    ensure_docker
    install_nvidia_container_toolkit

    # 4. Kiểm tra Docker GPU Passthrough (--gpus all) trước khi tải model nặng
    echo -e "${BLUE}ℹ Đang kiểm tra kết nối GPU passthrough bên trong Docker...${NC}"
    if docker run --rm --gpus all ubuntu:22.04 nvidia-smi >/dev/null 2>&1 || \
       docker run --rm --gpus all nvidia/cuda:12.4.1-base-ubuntu22.04 nvidia-smi >/dev/null 2>&1; then
        echo -e "${GREEN}${BOLD}✓ Test thành công: Docker đã nhận diện đầy đủ GPU NVIDIA qua cờ --gpus all!${NC}"
        HAS_NVIDIA_DOCKER_READY=true
        HAS_NVIDIA_GPU=true
    else
        echo -e "${YELLOW}⚠ Thử nghiệm nhanh chưa nhận diện được. Đang cấu hình lại runtime và restart Docker...${NC}"
        nvidia-ctk runtime configure --runtime=docker >/dev/null 2>&1 || true
        systemctl restart docker >/dev/null 2>&1 || true
        sleep 2

        if docker run --rm --gpus all ubuntu:22.04 nvidia-smi >/dev/null 2>&1 || \
           docker run --rm --gpus all nvidia/cuda:12.4.1-base-ubuntu22.04 nvidia-smi >/dev/null 2>&1; then
            echo -e "${GREEN}${BOLD}✓ Khắc phục thành công! Docker GPU đã sẵn sàng.${NC}"
            HAS_NVIDIA_DOCKER_READY=true
            HAS_NVIDIA_GPU=true
        else
            echo -e "${RED}${BOLD}✗ CẢNH BÁO: Docker chưa thể truy cập GPU!${NC}"
            echo -e "${RED}Nguyên nhân thường gặp: Máy chủ vừa cài driver và cần 'sudo reboot' để Kernel nạp module nvidia.${NC}"
            read -rp "Bạn có muốn tiếp tục chạy vLLM (có thể container sẽ báo lỗi thiếu GPU) không? [y/N]: " FORCE_DOCKER
            if [[ ! "$FORCE_DOCKER" =~ ^[Yy]$ ]]; then
                echo -e "${YELLOW}Đã dừng cài đặt để bạn khởi động lại máy chủ (sudo reboot).${NC}"
                exit 1
            fi
        fi
    fi
}

# CÀI ĐẶT & CHẠY vLLM BẰNG DOCKER (KHUYÊN DÙNG)
deploy_with_docker() {
    verify_docker_gpu_support
    open_firewall_port "$PORT"

    echo -e "\n${BLUE}ℹ Đang chuẩn bị container vLLM (Docker)...${NC}"

    # Dừng và xóa container cũ nếu đang chạy
    if docker ps -a --format '{{.Names}}' | grep -Eq "^${DOCKER_CONTAINER_NAME}\$"; then
        echo -e "${YELLOW}ℹ Phát hiện container '${DOCKER_CONTAINER_NAME}' cũ, đang dừng và xóa...${NC}"
        docker stop "$DOCKER_CONTAINER_NAME" >/dev/null 2>&1 || true
        docker rm "$DOCKER_CONTAINER_NAME" >/dev/null 2>&1 || true
    fi

    # Thư mục cache model trên máy chủ
    CACHE_DIR="/root/.cache/huggingface"
    mkdir -p "$CACHE_DIR"

    # Tạo lệnh chạy Docker
    local DOCKER_RUN_CMD=(
        docker run -d
        --name "$DOCKER_CONTAINER_NAME"
        --restart unless-stopped
        --ipc=host
        -e "PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True"
        -p "0.0.0.0:${PORT}:8000"
        -v "${CACHE_DIR}:/root/.cache/huggingface"
    )

    if [ "$HAS_NVIDIA_GPU" = true ]; then
        DOCKER_RUN_CMD+=(--gpus all)
    fi

    if [ -n "$HF_TOKEN" ]; then
        DOCKER_RUN_CMD+=(-e "HF_TOKEN=${HF_TOKEN}")
    fi

    # vLLM image
    local VLLM_IMAGE="vllm/vllm-openai:latest"
    echo -e "${BLUE}ℹ Image sử dụng:${NC} ${BOLD}${VLLM_IMAGE}${NC}"
    echo -e "${BLUE}ℹ Đang kéo image Docker và khởi chạy server (quá trình có thể mất vài phút)...${NC}"

    # Tham số phục vụ vllm serve (truyền Model dạng positional argument theo chuẩn vLLM mới)
    local SERVE_ARGS=(
        "$MODEL"
        "--host" "0.0.0.0"
        "--port" "8000"
        "--gpu-memory-utilization" "$GPU_MEM_UTIL"
    )

    if [ -n "$MAX_MODEL_LEN" ]; then
        SERVE_ARGS+=("--max-model-len" "$MAX_MODEL_LEN")
    fi

    if [ "$ENFORCE_EAGER" = true ]; then
        SERVE_ARGS+=("--enforce-eager")
    fi

    if [ -n "$API_KEY" ]; then
        SERVE_ARGS+=("--api-key" "$API_KEY")
    fi

    if [ -n "$SERVE_EXTRA_ARGS" ]; then
        # shellcheck disable=SC2206
        SERVE_ARGS+=($SERVE_EXTRA_ARGS)
    fi

    # Thực thi lệnh docker
    "${DOCKER_RUN_CMD[@]}" "$VLLM_IMAGE" "${SERVE_ARGS[@]}"

    MODE="docker"
    save_config

    echo -e "\n${GREEN}${BOLD}✓ Khởi tạo container vLLM thành công!${NC}"
    post_install_guide
}

# CÀI ĐẶT QUA PYTHON VIRTUALENV VÀ TẠO DỊCH VỤ SYSTEMD
deploy_with_python_systemd() {
    open_firewall_port "$PORT"

    echo -e "\n${BLUE}ℹ Đang cài đặt các gói phụ thuộc Python cho hệ thống...${NC}"
    if [ "$PKG_MANAGER" = "apt-get" ]; then
        apt-get update -qq
        apt-get install -y -qq python3 python3-pip python3-venv python3-dev build-essential git curl
    elif [ "$PKG_MANAGER" = "dnf" ] || [ "$PKG_MANAGER" = "yum" ]; then
        $PKG_MANAGER install -y -q python3 python3-pip python3-devel gcc gcc-c++ make git curl
    fi

    echo -e "${BLUE}ℹ Đang tạo Python Virtual Environment tại ${BOLD}${VLLM_VENV_DIR}${NC}...${NC}"
    rm -rf "$VLLM_VENV_DIR"
    python3 -m venv "$VLLM_VENV_DIR"
    # shellcheck disable=SC1091
    source "$VLLM_VENV_DIR/bin/activate"

    echo -e "${BLUE}ℹ Đang nâng cấp pip và cài đặt gói vLLM...${NC}"
    pip install --upgrade pip setuptools wheel
    pip install vllm

    # Tạo file systemd service
    echo -e "${BLUE}ℹ Đang tạo systemd service cho vLLM...${NC}"

    local EXEC_CMD="$VLLM_VENV_DIR/bin/vllm serve $MODEL --host 0.0.0.0 --port $PORT --gpu-memory-utilization $GPU_MEM_UTIL"
    if [ -n "$MAX_MODEL_LEN" ]; then
        EXEC_CMD="$EXEC_CMD --max-model-len $MAX_MODEL_LEN"
    fi
    if [ "$ENFORCE_EAGER" = true ]; then
        EXEC_CMD="$EXEC_CMD --enforce-eager"
    fi
    if [ -n "$API_KEY" ]; then
        EXEC_CMD="$EXEC_CMD --api-key $API_KEY"
    fi
    if [ -n "$SERVE_EXTRA_ARGS" ]; then
        EXEC_CMD="$EXEC_CMD $SERVE_EXTRA_ARGS"
    fi

    cat > "/etc/systemd/system/${SYSTEMD_SERVICE_NAME}.service" <<EOF
[Unit]
Description=vLLM High-Performance OpenAI-Compatible Server
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/root
Environment=PYTHONUNBUFFERED=1
Environment="PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True"
Environment="HF_TOKEN=${HF_TOKEN}"
ExecStart=${EXEC_CMD}
Restart=always
RestartSec=10
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable "${SYSTEMD_SERVICE_NAME}"
    systemctl restart "${SYSTEMD_SERVICE_NAME}"

    MODE="systemd"
    save_config

    echo -e "\n${GREEN}${BOLD}✓ Khởi tạo Systemd service cho vLLM thành công!${NC}"
    post_install_guide
}

# Hướng dẫn chi tiết sau khi cài đặt thành công
post_install_guide() {
    get_server_ips

    echo -e "\n${CYAN}${BOLD}=================================================================${NC}"
    echo -e "${GREEN}${BOLD}         🎉 CÀI ĐẶT & KHỞI CHẠY vLLM SERVER THÀNH CÔNG!          ${NC}"
    echo -e "${CYAN}${BOLD}=================================================================${NC}\n"

    echo -e "${BOLD}📌 THÔNG TIN KẾT NỐI API:${NC}"
    echo -e "   • Base URL (Mạng ngoài):  ${GREEN}${BOLD}http://${PUBLIC_IP}:${PORT}/v1${NC}"
    echo -e "   • Base URL (Nội bộ/LAN):   ${GREEN}${BOLD}http://${LOCAL_IP}:${PORT}/v1${NC}"
    echo -e "   • Localhost:              ${GREEN}http://127.0.0.1:${PORT}/v1${NC}"
    echo -e "   • Model đang chạy:        ${CYAN}${BOLD}${MODEL}${NC}"
    if [ -n "$API_KEY" ]; then
        echo -e "   • API Key (Bearer):       ${YELLOW}${BOLD}${API_KEY}${NC}"
    else
        echo -e "   • API Key:                ${YELLOW}Không đặt (Không cần Bearer token)${NC}"
    fi

    echo -e "\n${BOLD}⏳ LƯU Ý KHI MỚI KHỞI ĐỘNG:${NC}"
    echo -e "   Server cần vài phút để tải Model từ HuggingFace và nạp vào VRAM GPU."
    echo -e "   Để xem tiến trình tải model, hãy chạy lệnh xem log bên dưới."

    echo -e "\n${BOLD}📋 LỆNH QUẢN LÝ DỊCH VỤ:${NC}"
    if [ "$MODE" = "docker" ]; then
        echo -e "   • Xem log trực tiếp:     ${BOLD}docker logs -f ${DOCKER_CONTAINER_NAME}${NC}"
        echo -e "   • Kiểm tra trạng thái:   ${BOLD}docker ps -f name=${DOCKER_CONTAINER_NAME}${NC}"
        echo -e "   • Khởi động lại:         ${BOLD}docker restart ${DOCKER_CONTAINER_NAME}${NC}"
        echo -e "   • Dừng server:           ${BOLD}docker stop ${DOCKER_CONTAINER_NAME}${NC}"
    else
        echo -e "   • Xem log trực tiếp:     ${BOLD}journalctl -u ${SYSTEMD_SERVICE_NAME} -f${NC}"
        echo -e "   • Kiểm tra trạng thái:   ${BOLD}systemctl status ${SYSTEMD_SERVICE_NAME}${NC}"
        echo -e "   • Khởi động lại:         ${BOLD}systemctl restart ${SYSTEMD_SERVICE_NAME}${NC}"
        echo -e "   • Dừng server:           ${BOLD}systemctl stop ${SYSTEMD_SERVICE_NAME}${NC}"
    fi

    echo -e "\n${BOLD}💻 VÍ DỤ GỌI API CHO CÁC HỆ THỐNG KHÁC:${NC}"

    local AUTH_HEADER=""
    local PY_KEY="None"
    if [ -n "$API_KEY" ]; then
        AUTH_HEADER="  -H \"Authorization: Bearer ${API_KEY}\" \\\\\n"
        PY_KEY="\"${API_KEY}\""
    fi

    echo -e "${YELLOW}1. Bằng cURL (Terminal / Bash):${NC}"
    echo -e "${CYAN}curl http://${PUBLIC_IP}:${PORT}/v1/chat/completions \\"
    echo -e "  -H \"Content-Type: application/json\" \\"
    [ -n "$AUTH_HEADER" ] && echo -ne "$AUTH_HEADER"
    echo -e "  -d '{"
    echo -e "    \"model\": \"${MODEL}\","
    echo -e "    \"messages\": [{\"role\": \"user\", \"content\": \"Xin chào! Bạn là ai?\"}],"
    echo -e "    \"temperature\": 0.7"
    echo -e "  }'${NC}"

    echo -e "\n${YELLOW}2. Bằng Python (OpenAI SDK):${NC}"
    echo -e "${CYAN}from openai import OpenAI"
    echo -e "client = OpenAI(base_url=\"http://${PUBLIC_IP}:${PORT}/v1\", api_key=${PY_KEY})"
    echo -e "response = client.chat.completions.create("
    echo -e "    model=\"${MODEL}\","
    echo -e "    messages=[{\"role\": \"user\", \"content\": \"Xin chào!\"}]"
    echo -e ")"
    echo -e "print(response.choices[0].message.content)${NC}"

    echo -e "\n${CYAN}=================================================================${NC}\n"
}

# Kiểm tra tình trạng server
check_status() {
    load_config
    get_server_ips

    echo -e "\n${CYAN}${BOLD}=== KIỂM TRA TRẠNG THÁI vLLM SERVER ===${NC}\n"
    check_gpu

    echo -e "\n${BLUE}ℹ Trạng thái dịch vụ:${NC}"
    if [ "$MODE" = "docker" ]; then
        if docker ps --format '{{.Names}} (Status: {{.Status}})' | grep -Eq "^${DOCKER_CONTAINER_NAME}"; then
            echo -e "${GREEN}✓ Container Docker '${DOCKER_CONTAINER_NAME}' đang CHẠY.${NC}"
        else
            echo -e "${RED}✗ Container Docker '${DOCKER_CONTAINER_NAME}' ĐANG DỪNG hoặc chưa được tạo.${NC}"
        fi
    else
        if systemctl is-active --quiet "$SYSTEMD_SERVICE_NAME" 2>/dev/null; then
            echo -e "${GREEN}✓ Systemd service '${SYSTEMD_SERVICE_NAME}' đang CHẠY.${NC}"
        else
            echo -e "${RED}✗ Systemd service '${SYSTEMD_SERVICE_NAME}' ĐANG DỪNG hoặc không tồn tại.${NC}"
        fi
    fi

    # Kiểm tra cổng lắng nghe
    echo -e "\n${BLUE}ℹ Kiểm tra Port ${PORT}:${NC}"
    if command -v ss >/dev/null 2>&1; then
        PORT_CHECK=$(ss -tlpn 2>/dev/null | grep ":${PORT} " || true)
    elif command -v netstat >/dev/null 2>&1; then
        PORT_CHECK=$(netstat -tlpn 2>/dev/null | grep ":${PORT} " || true)
    else
        PORT_CHECK=""
    fi

    if [ -n "$PORT_CHECK" ]; then
        echo -e "${GREEN}✓ Port ${PORT} đang được lắng nghe bởi:${NC} ${PORT_CHECK}"
    else
        echo -e "${YELLOW}⚠ Chưa thấy process lắng nghe port ${PORT} (Có thể model đang được load).${NC}"
    fi

    # Kiểm tra endpoint HTTP health
    echo -e "\n${BLUE}ℹ Thử truy vấn Endpoint Health (http://127.0.0.1:${PORT}/health)...${NC}"
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 3 "http://127.0.0.1:${PORT}/health" 2>/dev/null || echo "000")
    if [ "$HTTP_CODE" = "200" ]; then
        echo -e "${GREEN}✓ Endpoint /health phản hồi HTTP 200 OK! Server đã sẵn sàng nhận request.${NC}"
    else
        echo -e "${YELLOW}⚠ Endpoint chưa phản hồi 200 (HTTP: ${HTTP_CODE}). Nếu vừa bật, vLLM có thể vẫn đang download hoặc load model vào VRAM.${NC}"
    fi
}

# Xem logs thời gian thực
view_logs() {
    load_config
    echo -e "\n${BLUE}ℹ Đang mở live log (Nhấn Ctrl+C để thoát xem log)...${NC}\n"
    if [ "$MODE" = "docker" ]; then
        docker logs -f "$DOCKER_CONTAINER_NAME"
    else
        journalctl -u "$SYSTEMD_SERVICE_NAME" -f
    fi
}

# Khởi động lại dịch vụ
restart_service() {
    load_config
    echo -e "\n${BLUE}ℹ Đang khởi động lại dịch vụ vLLM...${NC}"
    if [ "$MODE" = "docker" ]; then
        docker restart "$DOCKER_CONTAINER_NAME"
    else
        systemctl restart "$SYSTEMD_SERVICE_NAME"
    fi
    echo -e "${GREEN}✓ Đã gửi lệnh khởi động lại.${NC}"
}

# Dừng dịch vụ
stop_service() {
    load_config
    echo -e "\n${YELLOW}ℹ Đang dừng dịch vụ vLLM...${NC}"
    if [ "$MODE" = "docker" ]; then
        docker stop "$DOCKER_CONTAINER_NAME" || true
    else
        systemctl stop "$SYSTEMD_SERVICE_NAME" || true
    fi
    echo -e "${GREEN}✓ Đã dừng dịch vụ vLLM.${NC}"
}

# Thử nghiệm gửi request Chat Completion mẫu
test_api() {
    load_config
    get_server_ips
    echo -e "\n${BLUE}ℹ Đang gửi request kiểm tra API tới http://127.0.0.1:${PORT}/v1/chat/completions...${NC}\n"

    local AUTH_HEADER=()
    if [ -n "$API_KEY" ]; then
        AUTH_HEADER=(-H "Authorization: Bearer $API_KEY")
    fi

    RESPONSE=$(curl -s --max-time 30 -X POST "http://127.0.0.1:${PORT}/v1/chat/completions" \
        -H "Content-Type: application/json" \
        "${AUTH_HEADER[@]}" \
        -d "{
            \"model\": \"${MODEL}\",
            \"messages\": [{\"role\": \"user\", \"content\": \"Hãy trả lời ngắn gọn: Bạn tên là gì và sẵn sàng phục vụ chưa?\"}],
            \"max_tokens\": 100,
            \"temperature\": 0.6
        }" || echo "")

    if [ -z "$RESPONSE" ]; then
        echo -e "${RED}✗ Không nhận được phản hồi từ server. Vui lòng kiểm tra lại log xem model đã load xong chưa.${NC}"
    else
        echo -e "${GREEN}✓ Phản hồi từ vLLM:${NC}"
        echo -e "${CYAN}${RESPONSE}${NC}\n"
    fi
}

# Gỡ bỏ dịch vụ vLLM
uninstall_vllm() {
    load_config
    echo -e "\n${RED}${BOLD}⚠ CẢNH BÁO: BẠN CÓ CHẮC CHẮN MUỐN GỠ BỎ vLLM SERVER?${NC}"
    read -rp "Xác nhận gỡ bỏ? (gõ 'yes' để xác nhận): " CONFIRM
    if [ "$CONFIRM" != "yes" ]; then
        echo -e "${YELLOW}Hủy bỏ thao tác gỡ bỏ.${NC}"
        return 0
    fi

    echo -e "\n${BLUE}ℹ Đang gỡ bỏ container và dịch vụ...${NC}"
    if docker ps -a --format '{{.Names}}' | grep -Eq "^${DOCKER_CONTAINER_NAME}\$"; then
        docker stop "$DOCKER_CONTAINER_NAME" >/dev/null 2>&1 || true
        docker rm "$DOCKER_CONTAINER_NAME" >/dev/null 2>&1 || true
    fi

    if [ -f "/etc/systemd/system/${SYSTEMD_SERVICE_NAME}.service" ]; then
        systemctl stop "$SYSTEMD_SERVICE_NAME" >/dev/null 2>&1 || true
        systemctl disable "$SYSTEMD_SERVICE_NAME" >/dev/null 2>&1 || true
        rm -f "/etc/systemd/system/${SYSTEMD_SERVICE_NAME}.service"
        systemctl daemon-reload
    fi

    rm -rf "$CONFIG_FILE"
    echo -e "${GREEN}✓ Đã gỡ bỏ thành công dịch vụ vLLM Server.${NC}"
}

# Menu điều khiển chính
main_menu() {
    show_banner
    detect_os
    check_gpu
    load_config

    echo -e "\n${BOLD}Chọn tác vụ bạn muốn thực hiện:${NC}"
    echo -e "   1) ${GREEN}${BOLD}Cài đặt vLLM bằng Docker (Khuyên dùng - Ổn định nhất)${NC}"
    echo -e "   2) ${CYAN}Cài đặt vLLM bằng Python venv + Systemd service${NC}"
    echo -e "   3) ${YELLOW}Kiểm tra trạng thái Server, GPU & Cổng ${PORT}${NC}"
    echo -e "   4) ${CYAN}Xem Live Logs của vLLM Server${NC}"
    echo -e "   5) ${BLUE}Mở / Kiểm tra lại tường lửa (Firewall) cho Port ${PORT}${NC}"
    echo -e "   6) ${GREEN}Thử gọi Test API (curl chat completion)${NC}"
    echo -e "   7) ${MAGENTA}Cài đặt & Sửa lỗi NVIDIA Driver + Container Toolkit (Docker GPU)${NC}"
    echo -e "   8) Khởi động lại vLLM Server"
    echo -e "   9) Dừng vLLM Server"
    echo -e "  10) ${RED}Gỡ bỏ vLLM Server${NC}"
    echo -e "   0) Thoát"

    echo ""
    read -rp "Nhập lựa chọn của bạn [0-10] (Mặc định: 1): " MENU_CHOICE
    MENU_CHOICE="${MENU_CHOICE:-1}"

    case "$MENU_CHOICE" in
        1)
            collect_user_config
            deploy_with_docker
            ;;
        2)
            collect_user_config
            deploy_with_python_systemd
            ;;
        3)
            check_status
            ;;
        4)
            view_logs
            ;;
        5)
            open_firewall_port "$PORT"
            ;;
        6)
            test_api
            ;;
        7)
            verify_docker_gpu_support
            ;;
        8)
            restart_service
            ;;
        9)
            stop_service
            ;;
        10)
            uninstall_vllm
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

# Điểm khởi chạy chính
check_root
main_menu
