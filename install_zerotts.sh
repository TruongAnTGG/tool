#!/usr/bin/env bash

# ==============================================================================
# Script Tự Động Cài Đặt, Cấu Hình & Quản Lý ZeroTTS Server (zeroweight-ai/ZeroTTS)
# Mô hình chuyển văn bản thành giọng nói (TTS) Tiếng Việt siêu nhanh & tự nhiên
# Hỗ trợ 2 phương thức:
#   1. DOCKER CONTAINER (Khuyên dùng: Cách ly môi trường, CUDA GPU, không lỗi thư viện)
#   2. PYTHON VENV + SYSTEMD SERVICE
# Tích hợp OpenAI-Compatible API (/v1/audio/speech) & Giao diện WebUI test giọng
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

# Thư mục cài đặt & cấu hình
INSTALL_DIR="/opt/zerotts"
VENV_DIR="$INSTALL_DIR/venv"
CONFIG_FILE="/etc/zerotts/zerotts.conf"
SYSTEMD_SERVICE="zerotts"
DOCKER_CONTAINER_NAME="zerotts-server"
DOCKER_IMAGE_NAME="zerotts-server:latest"
DEFAULT_PORT="8002"
MODEL_REPO="zeroweight-ai/ZeroTTS"

# Hiển thị banner
show_banner() {
    clear 2>/dev/null || true
    echo -e "${CYAN}${BOLD}=================================================================${NC}"
    echo -e "${CYAN}${BOLD}     HỆ THỐNG CÀI ĐẶT & QUẢN LÝ ZEROTTS (VIETNAMESE TTS)        ${NC}"
    echo -e "${CYAN}${BOLD}   Tăng tốc NVIDIA GPU CUDA & Tương thích chuẩn OpenAI Speech API ${NC}"
    echo -e "${CYAN}${BOLD}=================================================================${NC}\n"
}

# Kiểm tra quyền root
check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}✗ Lỗi: Script yêu cầu quyền root để cài đặt Docker/gói và mở Firewall.${NC}"
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
        echo -e "${RED}✗ Lỗi: ZeroTTS Server yêu cầu chạy trên hệ điều hành Linux.${NC}"
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

# Kiểm tra card đồ họa NVIDIA & CUDA
check_gpu() {
    HAS_NVIDIA_GPU=false
    echo -e "${BLUE}ℹ Đang kiểm tra thông tin GPU NVIDIA trên máy chủ...${NC}"
    if command -v nvidia-smi >/dev/null 2>&1; then
        GPU_INFO=$(nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv,noheader 2>/dev/null || echo "")
        if [ -n "$GPU_INFO" ]; then
            echo -e "${GREEN}✓ Đã tìm thấy GPU NVIDIA:${NC}"
            while IFS= read -r line; do
                echo -e "   ${BOLD}⚡ $line${NC}"
            done <<< "$GPU_INFO"
            HAS_NVIDIA_GPU=true
        else
            echo -e "${YELLOW}⚠ Lệnh nvidia-smi có tồn tại nhưng chưa giao tiếp được với Driver.${NC}"
        fi
    else
        echo -e "${YELLOW}⚠ Không tìm thấy lệnh 'nvidia-smi'. ZeroTTS sẽ chạy ở chế độ CPU (vẫn rất nhanh ~70ms).${NC}"
    fi
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
            ufw allow "${port}/tcp" comment "ZeroTTS Server" >/dev/null 2>&1 || ufw allow "${port}" >/dev/null 2>&1
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
        echo -e "${GREEN}✓ Hoàn tất mở cổng ${port}/tcp trên máy chủ.${NC}"
    else
        echo -e "${YELLOW}ℹ Cổng ${port} sẵn sàng đón kết nối.${NC}"
    fi

    echo -e "${MAGENTA}${BOLD}👉 LƯU Ý QUAN TRỌNG VỀ CLOUD VPS:${NC}"
    echo -e "   Nếu bạn dùng AWS EC2, GCP, Azure, Oracle, DigitalOcean: Hãy mở ${BOLD}Inbound Port ${port}/tcp${NC}"
    echo -e "   trên Security Group hoặc Firewall console của nhà cung cấp.\n"
}

# Đọc cấu hình đã lưu
load_config() {
    if [ -f "$CONFIG_FILE" ]; then
        # shellcheck disable=SC1090
        . "$CONFIG_FILE" 2>/dev/null || true
    fi
    PORT="${PORT:-$DEFAULT_PORT}"
    DEVICE="${DEVICE:-cuda}"
    MODE="${MODE:-docker}"
}

# Lưu cấu hình ra file
save_config() {
    mkdir -p "$(dirname "$CONFIG_FILE")"
    cat > "$CONFIG_FILE" <<EOF
MODE="${MODE}"
PORT="${PORT}"
DEVICE="${DEVICE}"
MODEL_REPO="${MODEL_REPO}"
EOF
    chmod 600 "$CONFIG_FILE"
}

# Cài đặt NVIDIA Container Toolkit (nếu dùng Docker + GPU)
install_nvidia_container_toolkit() {
    echo -e "\n${BLUE}ℹ Kiểm tra NVIDIA Container Toolkit (nvidia-docker / nvidia-ctk)...${NC}"
    if command -v nvidia-ctk >/dev/null 2>&1; then
        echo -e "${GREEN}✓ NVIDIA Container Toolkit đã được cài đặt.${NC}"
    else
        echo -e "${YELLOW}ℹ Đang cài đặt nvidia-container-toolkit để Docker truy cập GPU...${NC}"
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
        nvidia-ctk runtime configure --runtime=docker >/dev/null 2>&1 || true
        systemctl restart docker >/dev/null 2>&1 || true
        echo -e "${GREEN}✓ Cấu hình NVIDIA runtime cho Docker thành công!${NC}"
    fi
}

# Cài đặt Docker tự động nếu chưa có
ensure_docker() {
    if ! command -v docker >/dev/null 2>&1; then
        echo -e "${YELLOW}ℹ Chưa tìm thấy Docker, đang cài đặt Docker Engine chính thức...${NC}"
        curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
        sh /tmp/get-docker.sh
        rm -f /tmp/get-docker.sh
        systemctl enable --now docker
        echo -e "${GREEN}✓ Cài đặt Docker Engine thành công!${NC}"
    fi
    systemctl start docker 2>/dev/null || true

    if [ "$HAS_NVIDIA_GPU" = true ]; then
        install_nvidia_container_toolkit
    fi
}

# Tạo mã nguồn máy chủ FastAPI & Web UI (server.py)
create_server_script() {
    mkdir -p "$INSTALL_DIR"
    cat > "$INSTALL_DIR/server.py" <<'EOF'
import os
import io
import time
import soundfile as sf
import numpy as np
from fastapi import FastAPI, HTTPException, Response
from fastapi.responses import HTMLResponse
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel
from typing import Optional
from zerotts import ZeroTTS

app = FastAPI(title="ZeroTTS Vietnamese API Server", version="1.0.0")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

MODEL_ID = os.getenv("MODEL_REPO", "zeroweight-ai/ZeroTTS")
DEVICE = os.getenv("DEVICE", "cuda")

print(f"[*] Đang tải ZeroTTS model '{MODEL_ID}' (Target Device: {DEVICE})...")
try:
    tts = ZeroTTS.from_pretrained(MODEL_ID)
    print(f"[+] Tải ZeroTTS model thành công! Sample rate: {tts.sample_rate}Hz")
except Exception as e:
    print(f"[!] Lỗi khi nạp model: {e}")
    raise e

class SpeechRequest(BaseModel):
    model: Optional[str] = "zerotts"
    input: str
    voice: Optional[str] = "maichi"
    response_format: Optional[str] = "wav"
    speed: Optional[float] = 1.0

@app.get("/health")
def health():
    return {
        "status": "healthy",
        "model": MODEL_ID,
        "sample_rate": tts.sample_rate,
        "device": DEVICE
    }

@app.get("/v1/audio/voices")
def get_voices():
    return {"voices": ["maichi"], "default": "maichi"}

@app.post("/v1/audio/speech")
def text_to_speech(req: SpeechRequest):
    if not req.input or not req.input.strip():
        raise HTTPException(status_code=400, detail="Nội dung 'input' không được để trống.")
    
    voice_name = req.voice or "maichi"
    start_time = time.time()
    
    try:
        audio = tts.synthesize(req.input, voice=voice_name)
        wav_io = io.BytesIO()
        sf.write(wav_io, audio, tts.sample_rate, format='WAV')
        wav_io.seek(0)
        
        proc_time = round((time.time() - start_time) * 1000, 2)
        print(f"[+] Tạo âm thanh thành công cho {len(req.input)} ký tự trong {proc_time}ms (Voice: {voice_name})")
        
        return Response(
            content=wav_io.read(),
            media_type="audio/wav",
            headers={
                "Content-Disposition": "attachment; filename=speech.wav",
                "X-Process-Time-Ms": str(proc_time)
            }
        )
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Lỗi tạo âm thanh: {str(e)}")

@app.get("/", response_class=HTMLResponse)
def index():
    return """
    <!DOCTYPE html>
    <html lang="vi">
    <head>
        <meta charset="UTF-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
        <title>ZeroTTS Studio - Vietnamese Speech AI</title>
        <link href="https://fonts.googleapis.com/css2?family=Plus+Jakarta+Sans:wght@400;600;700&display=swap" rel="stylesheet">
        <style>
            :root {
                --bg: #090d16;
                --card: #131b2e;
                --border: #232f48;
                --primary: #3b82f6;
                --primary-hover: #2563eb;
                --text: #f8fafc;
                --muted: #94a3b8;
            }
            body {
                font-family: 'Plus Jakarta Sans', sans-serif;
                background-color: var(--bg);
                color: var(--text);
                margin: 0;
                padding: 40px 20px;
                display: flex;
                justify-content: center;
            }
            .container {
                max-width: 680px;
                width: 100%;
                background: var(--card);
                border: 1px solid var(--border);
                border-radius: 16px;
                padding: 32px;
                box-shadow: 0 20px 40px rgba(0,0,0,0.4);
            }
            h1 {
                margin-top: 0;
                font-size: 26px;
                color: #fff;
                display: flex;
                align-items: center;
                gap: 12px;
            }
            p.desc {
                color: var(--muted);
                margin-top: -6px;
                margin-bottom: 24px;
                font-size: 14px;
                line-height: 1.5;
            }
            label {
                display: block;
                font-size: 13px;
                font-weight: 600;
                margin-bottom: 8px;
                color: #cbd5e1;
            }
            textarea {
                width: 100%;
                box-sizing: border-box;
                background: #0b1120;
                border: 1px solid var(--border);
                border-radius: 10px;
                color: #fff;
                padding: 14px;
                font-size: 15px;
                min-height: 120px;
                resize: vertical;
                outline: none;
                transition: border-color 0.2s;
            }
            textarea:focus { border-color: var(--primary); }
            .grid {
                display: grid;
                grid-template-columns: 1fr 1fr;
                gap: 16px;
                margin-top: 18px;
            }
            select {
                width: 100%;
                background: #0b1120;
                border: 1px solid var(--border);
                color: #fff;
                border-radius: 8px;
                padding: 10px;
                outline: none;
            }
            button {
                width: 100%;
                background: var(--primary);
                color: white;
                border: none;
                border-radius: 10px;
                padding: 14px;
                font-size: 16px;
                font-weight: 600;
                cursor: pointer;
                margin-top: 24px;
                transition: background 0.2s, transform 0.1s;
            }
            button:hover { background: var(--primary-hover); }
            button:active { transform: scale(0.99); }
            button:disabled { opacity: 0.6; cursor: not-allowed; }
            .player-box {
                margin-top: 28px;
                padding: 20px;
                background: #090e1a;
                border-radius: 12px;
                border: 1px solid var(--border);
                display: none;
            }
            audio { width: 100%; margin-top: 8px; }
            .stats {
                font-size: 12px;
                color: var(--muted);
                margin-top: 8px;
            }
            .badge {
                background: rgba(59, 130, 246, 0.2);
                color: #60a5fa;
                padding: 4px 8px;
                border-radius: 6px;
                font-size: 12px;
                font-weight: 600;
            }
        </style>
    </head>
    <body>
        <div class="container">
            <h1>🎙️ ZeroTTS Studio <span class="badge">Vietnamese AI</span></h1>
            <p class="desc">Chuyển văn bản thành giọng nói Tiếng Việt siêu nhanh (~70ms) và tự nhiên với ZeroTTS.</p>
            
            <label for="text">Nhập văn bản Tiếng Việt:</label>
            <textarea id="text" placeholder="Nhập câu tiếng Việt bất kỳ...">Xin chào các bạn! Mình là mô hình giọng nói nhân tạo ZeroTTS, hỗ trợ Tiếng Việt tự nhiên và siêu nhanh.</textarea>
            
            <div class="grid">
                <div>
                    <label for="voice">Giọng đọc (Voice):</label>
                    <select id="voice">
                        <option value="maichi">Mai Chi (Giọng nữ tự nhiên)</option>
                    </select>
                </div>
                <div>
                    <label>Chuẩn kết nối:</label>
                    <select disabled>
                        <option>OpenAI Audio Speech API</option>
                    </select>
                </div>
            </div>

            <button id="btn" onclick="generateSpeech()">⚡ Phát sinh giọng nói</button>

            <div class="player-box" id="playerBox">
                <label>Kết quả phát âm thanh:</label>
                <audio id="audioPlayer" controls></audio>
                <div class="stats" id="stats"></div>
            </div>
        </div>

        <script>
            async function generateSpeech() {
                const text = document.getElementById('text').value;
                const voice = document.getElementById('voice').value;
                const btn = document.getElementById('btn');
                const playerBox = document.getElementById('playerBox');
                const player = document.getElementById('audioPlayer');
                const stats = document.getElementById('stats');

                if (!text.trim()) {
                    alert('Vui lòng nhập văn bản!');
                    return;
                }

                btn.disabled = true;
                btn.innerText = '⏳ Đang tạo âm thanh...';

                const t0 = performance.now();
                try {
                    const response = await fetch('/v1/audio/speech', {
                        method: 'POST',
                        headers: { 'Content-Type': 'application/json' },
                        body: JSON.stringify({ input: text, voice: voice })
                    });

                    if (!response.ok) {
                        const err = await response.json();
                        throw new Error(err.detail || 'Lỗi server');
                    }

                    const blob = await response.blob();
                    const audioUrl = URL.createObjectURL(blob);
                    const elapsed = Math.round(performance.now() - t0);

                    player.src = audioUrl;
                    playerBox.style.display = 'block';
                    stats.innerText = `Hoàn thành trong ${elapsed} ms. Định dạng: WAV (Sample rate: 48kHz)`;
                    player.play();
                } catch (e) {
                    alert('Lỗi: ' + e.message);
                } finally {
                    btn.disabled = false;
                    btn.innerText = '⚡ Phát sinh giọng nói';
                }
            }
        </script>
    </body>
    </html>
    """
EOF
    chmod 644 "$INSTALL_DIR/server.py"
}

# Tạo Dockerfile chuyên biệt cho ZeroTTS
create_dockerfile() {
    mkdir -p "$INSTALL_DIR"
    cat > "$INSTALL_DIR/Dockerfile" <<'EOF'
FROM nvidia/cuda:12.4.1-runtime-ubuntu22.04

ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONUNBUFFERED=1

RUN apt-get update && apt-get install -y --no-install-recommends \
    python3 \
    python3-pip \
    python3-dev \
    libsndfile1 \
    ffmpeg \
    curl \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

RUN pip3 install --no-cache-dir --upgrade pip setuptools wheel && \
    pip3 install --no-cache-dir \
    zerotts \
    onnxruntime-gpu \
    fastapi \
    uvicorn \
    soundfile \
    scipy \
    numpy \
    huggingface-hub \
    pydantic

COPY server.py /app/server.py

EXPOSE 8002

CMD ["uvicorn", "server:app", "--host", "0.0.0.0", "--port", "8002"]
EOF
    chmod 644 "$INSTALL_DIR/Dockerfile"
}

# ==============================================================================
# PHƯƠNG THỨC 1: CÀI ĐẶT & CHẠY BẰNG DOCKER (KHUYÊN DÙNG)
# ==============================================================================
deploy_with_docker() {
    ensure_docker
    check_gpu
    load_config

    echo -e "\n${CYAN}${BOLD}--- CẤU HÌNH ZEROTTS DOCKER CONTAINER ---${NC}\n"
    read -rp "$(echo -e "${BOLD}Cổng lắng nghe (Port)${NC} [Mặc định: ${GREEN}${DEFAULT_PORT}${NC}]: ")" INPUT_PORT
    PORT="${INPUT_PORT:-$DEFAULT_PORT}"

    MODE="docker"
    save_config
    open_firewall_port "$PORT"

    create_server_script
    create_dockerfile

    echo -e "\n${BLUE}ℹ Đang build Docker Image '${DOCKER_IMAGE_NAME}' (quá trình mất 2-3 phút)...${NC}"
    cd "$INSTALL_DIR"
    docker build -t "$DOCKER_IMAGE_NAME" .

    # Dừng container cũ nếu đang chạy
    if docker ps -a --format '{{.Names}}' | grep -Eq "^${DOCKER_CONTAINER_NAME}\$"; then
        echo -e "${YELLOW}ℹ Dừng và xóa container '${DOCKER_CONTAINER_NAME}' cũ...${NC}"
        docker stop "$DOCKER_CONTAINER_NAME" >/dev/null 2>&1 || true
        docker rm "$DOCKER_CONTAINER_NAME" >/dev/null 2>&1 || true
    fi

    # Thư mục cache model trên host để không phải tải lại model khi restart
    CACHE_DIR="/root/.cache/huggingface"
    mkdir -p "$CACHE_DIR"

    # Lệnh chạy docker
    local DOCKER_RUN_CMD=(
        docker run -d
        --name "$DOCKER_CONTAINER_NAME"
        --restart unless-stopped
        --ipc=host
        -p "0.0.0.0:${PORT}:8002"
        -v "${CACHE_DIR}:/root/.cache/huggingface"
        -e "MODEL_REPO=${MODEL_REPO}"
    )

    if [ "$HAS_NVIDIA_GPU" = true ]; then
        DOCKER_RUN_CMD+=(--gpus all -e "DEVICE=cuda")
        echo -e "${GREEN}✓ Kích hoạt tăng tốc NVIDIA GPU (--gpus all).${NC}"
    else
        DOCKER_RUN_CMD+=(-e "DEVICE=cpu")
        echo -e "${YELLOW}ℹ Khởi chạy chế độ CPU.${NC}"
    fi

    echo -e "\n${BLUE}ℹ Đang khởi chạy Docker container...${NC}"
    "${DOCKER_RUN_CMD[@]}" "$DOCKER_IMAGE_NAME"

    echo -e "\n${GREEN}${BOLD}✓ Khởi tạo ZeroTTS Container thành công!${NC}"
    post_install_guide
}

# ==============================================================================
# PHƯƠNG THỨC 2: CÀI ĐẶT BẰNG PYTHON VENV + SYSTEMD
# ==============================================================================
deploy_with_python_systemd() {
    detect_os
    check_gpu
    load_config

    echo -e "\n${CYAN}${BOLD}--- CẤU HÌNH ZEROTTS SYSTEMD SERVICE ---${NC}\n"
    read -rp "$(echo -e "${BOLD}Cổng lắng nghe (Port)${NC} [Mặc định: ${GREEN}${DEFAULT_PORT}${NC}]: ")" INPUT_PORT
    PORT="${INPUT_PORT:-$DEFAULT_PORT}"

    MODE="systemd"
    save_config
    open_firewall_port "$PORT"

    # Cài đặt gói hệ thống
    echo -e "${BLUE}ℹ Đang cài đặt các phụ thuộc hệ thống...${NC}"
    if [ "$PKG_MANAGER" = "apt-get" ]; then
        apt-get update -qq
        apt-get install -y -qq python3 python3-pip python3-venv python3-dev build-essential libsndfile1 ffmpeg git curl
    elif [ "$PKG_MANAGER" = "dnf" ] || [ "$PKG_MANAGER" = "yum" ]; then
        $PKG_MANAGER install -y -q python3 python3-pip python3-devel gcc gcc-c++ make libsndfile ffmpeg git curl
    fi

    create_server_script

    echo -e "\n${BLUE}ℹ Đang tạo Python Virtual Environment tại ${BOLD}${VENV_DIR}${NC}...${NC}"
    rm -rf "$VENV_DIR"
    python3 -m venv "$VENV_DIR"
    # shellcheck disable=SC1091
    source "$VENV_DIR/bin/activate"

    echo -e "${BLUE}ℹ Đang nâng cấp pip và cài đặt gói ZeroTTS...${NC}"
    pip install --upgrade pip setuptools wheel
    pip install "zerotts" "fastapi" "uvicorn" "pydantic" "soundfile" "scipy" "numpy" "huggingface-hub"

    if [ "$HAS_NVIDIA_GPU" = true ]; then
        pip install "onnxruntime-gpu" || pip install "onnxruntime"
        DEVICE="cuda"
    else
        pip install "onnxruntime"
        DEVICE="cpu"
    fi

    # Tạo file systemd service
    cat > "/etc/systemd/system/${SYSTEMD_SERVICE}.service" <<EOF
[Unit]
Description=ZeroTTS Vietnamese Speech API Server
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=${INSTALL_DIR}
Environment=PYTHONUNBUFFERED=1
Environment="MODEL_REPO=${MODEL_REPO}"
Environment="DEVICE=${DEVICE}"
ExecStart=${VENV_DIR}/bin/uvicorn server:app --host 0.0.0.0 --port ${PORT}
Restart=always
RestartSec=5
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable "${SYSTEMD_SERVICE}"
    systemctl restart "${SYSTEMD_SERVICE}"

    echo -e "\n${GREEN}${BOLD}✓ Khởi tạo Systemd service cho ZeroTTS thành công!${NC}"
    post_install_guide
}

# Hướng dẫn chi tiết sau khi cài đặt
post_install_guide() {
    load_config
    get_server_ips

    echo -e "\n${CYAN}${BOLD}=================================================================${NC}"
    echo -e "${GREEN}${BOLD}         🎉 CÀI ĐẶT & KHỞI CHẠY ZEROTTS THÀNH CÔNG!              ${NC}"
    echo -e "${CYAN}${BOLD}=================================================================${NC}\n"

    echo -e "${BOLD}📌 THÔNG TIN TRUY CẬP:${NC}"
    echo -e "   • Giao diện WebUI thử giọng:   ${GREEN}${BOLD}http://${PUBLIC_IP}:${PORT}${NC}"
    echo -e "   • Base URL (Mạng ngoài):       ${GREEN}${BOLD}http://${PUBLIC_IP}:${PORT}/v1${NC}"
    echo -e "   • Localhost:                  ${GREEN}http://127.0.0.1:${PORT}${NC}"
    echo -e "   • Chế độ chạy:                ${CYAN}${BOLD}${MODE^^}${NC} (Tăng tốc: ${DEVICE^^})"

    echo -e "\n${BOLD}📋 LỆNH QUẢN LÝ DỊCH VỤ:${NC}"
    if [ "$MODE" = "docker" ]; then
        echo -e "   • Xem live logs:     ${BOLD}docker logs -f ${DOCKER_CONTAINER_NAME}${NC}"
        echo -e "   • Kiểm tra trạng thái: ${BOLD}docker ps -f name=${DOCKER_CONTAINER_NAME}${NC}"
        echo -e "   • Khởi động lại:     ${BOLD}docker restart ${DOCKER_CONTAINER_NAME}${NC}"
        echo -e "   • Dừng dịch vụ:      ${BOLD}docker stop ${DOCKER_CONTAINER_NAME}${NC}"
    else
        echo -e "   • Xem live logs:     ${BOLD}journalctl -u ${SYSTEMD_SERVICE} -f${NC}"
        echo -e "   • Kiểm tra status:   ${BOLD}systemctl status ${SYSTEMD_SERVICE}${NC}"
        echo -e "   • Khởi động lại:     ${BOLD}systemctl restart ${SYSTEMD_SERVICE}${NC}"
        echo -e "   • Dừng dịch vụ:      ${BOLD}systemctl stop ${SYSTEMD_SERVICE}${NC}"
    fi

    echo -e "\n${BOLD}💻 VÍ DỤ GỌI API CHUẨN OPENAI (TÍCH HỢP CHO HỆ THỐNG KHÁC):${NC}"
    echo -e "${YELLOW}1. Bằng cURL (Tải file âm thanh speech.wav):${NC}"
    echo -e "${CYAN}curl -X POST http://${PUBLIC_IP}:${PORT}/v1/audio/speech \\"
    echo -e "  -H \"Content-Type: application/json\" \\"
    echo -e "  -d '{"
    echo -e "    \"model\": \"zerotts\","
    echo -e "    \"input\": \"Xin chào bạn, ZeroTTS đọc tiếng Việt rất tự nhiên.\","
    echo -e "    \"voice\": \"maichi\""
    echo -e "  }' --output speech.wav${NC}"

    echo -e "\n${YELLOW}2. Bằng Python (OpenAI SDK):${NC}"
    echo -e "${CYAN}from openai import OpenAI"
    echo -e "client = OpenAI(base_url=\"http://${PUBLIC_IP}:${PORT}/v1\", api_key=\"none\")"
    echo -e "response = client.audio.speech.create("
    echo -e "    model=\"zerotts\","
    echo -e "    voice=\"maichi\","
    echo -e "    input=\"Hôm nay trời rất đẹp, chúc bạn một ngày làm việc hiệu quả!\""
    echo -e ")"
    echo -e "response.stream_to_file(\"output.wav\")${NC}"

    echo -e "\n${CYAN}=================================================================${NC}\n"
}

# Kiểm tra trạng thái dịch vụ
check_status() {
    load_config
    get_server_ips

    echo -e "\n${CYAN}${BOLD}=== KIỂM TRA TRẠNG THÁI ZEROTTS SERVER ===${NC}\n"
    check_gpu

    if [ "$MODE" = "docker" ]; then
        if docker ps --format '{{.Names}} (Status: {{.Status}})' | grep -Eq "^${DOCKER_CONTAINER_NAME}"; then
            echo -e "\n${GREEN}✓ Docker Container '${DOCKER_CONTAINER_NAME}' đang CHẠY.${NC}"
        else
            echo -e "\n${RED}✗ Docker Container '${DOCKER_CONTAINER_NAME}' ĐANG DỪNG hoặc chưa tạo.${NC}"
        fi
    else
        if systemctl is-active --quiet "$SYSTEMD_SERVICE" 2>/dev/null; then
            echo -e "\n${GREEN}✓ Dịch vụ ${SYSTEMD_SERVICE} đang CHẠY bình thường.${NC}"
        else
            echo -e "\n${RED}✗ Dịch vụ ${SYSTEMD_SERVICE} ĐANG DỪNG hoặc gặp lỗi.${NC}"
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
        echo -e "${GREEN}✓ Port ${PORT} đang lắng nghe!${NC}"
    else
        echo -e "${YELLOW}⚠ Chưa thấy Port ${PORT} mở.${NC}"
    fi

    # Thử gọi endpoint /health
    echo -e "\n${BLUE}ℹ Thử truy vấn Endpoint Health (http://127.0.0.1:${PORT}/health)...${NC}"
    RES=$(curl -s --max-time 3 "http://127.0.0.1:${PORT}/health" 2>/dev/null || echo "")
    if [ -n "$RES" ]; then
        echo -e "${GREEN}✓ Phản hồi từ server:${NC} ${CYAN}${RES}${NC}"
    else
        echo -e "${YELLOW}⚠ Server chưa phản hồi HTTP (có thể đang download model).${NC}"
    fi
}

# Xem logs thời gian thực
view_logs() {
    load_config
    echo -e "\n${BLUE}ℹ Đang mở live log (Nhấn Ctrl+C để thoát)...${NC}\n"
    if [ "$MODE" = "docker" ]; then
        docker logs -f "$DOCKER_CONTAINER_NAME"
    else
        journalctl -u "$SYSTEMD_SERVICE" -f
    fi
}

# Test tạo âm thanh thử nghiệm qua CLI
test_synthesis() {
    load_config
    echo -e "\n${BLUE}ℹ Đang gửi request test tạo âm thanh tới http://127.0.0.1:${PORT}/v1/audio/speech...${NC}"
    
    local OUT_FILE="/tmp/zerotts_test.wav"
    rm -f "$OUT_FILE"

    HTTP_CODE=$(curl -s -w "%{http_code}" -X POST "http://127.0.0.1:${PORT}/v1/audio/speech" \
        -H "Content-Type: application/json" \
        -d '{
            "model": "zerotts",
            "input": "Xin chào! Đây là bản tin thử nghiệm âm thanh tiếng Việt từ mô hình ZeroTTS.",
            "voice": "maichi"
        }' -o "$OUT_FILE" || echo "000")

    if [ "$HTTP_CODE" = "200" ] && [ -f "$OUT_FILE" ] && [ -s "$OUT_FILE" ]; then
        local SIZE
        SIZE=$(du -h "$OUT_FILE" | awk '{print $1}')
        echo -e "${GREEN}${BOLD}✓ Tạo âm thanh thành công! File lưu tại: ${OUT_FILE} (Dung lượng: ${SIZE})${NC}\n"
    else
        echo -e "${RED}✗ Lỗi tạo âm thanh (HTTP Code: ${HTTP_CODE}). Vui lòng kiểm tra lại log.${NC}\n"
    fi
}

# Khởi động lại
restart_service() {
    load_config
    echo -e "\n${BLUE}ℹ Đang khởi động lại dịch vụ ZeroTTS...${NC}"
    if [ "$MODE" = "docker" ]; then
        docker restart "$DOCKER_CONTAINER_NAME"
    else
        systemctl restart "$SYSTEMD_SERVICE"
    fi
    echo -e "${GREEN}✓ Đã gửi lệnh khởi động lại.${NC}"
}

# Dừng dịch vụ
stop_service() {
    load_config
    echo -e "\n${YELLOW}ℹ Đang dừng dịch vụ ZeroTTS...${NC}"
    if [ "$MODE" = "docker" ]; then
        docker stop "$DOCKER_CONTAINER_NAME" || true
    else
        systemctl stop "$SYSTEMD_SERVICE" || true
    fi
    echo -e "${GREEN}✓ Đã dừng dịch vụ.${NC}"
}

# Gỡ bỏ dịch vụ
uninstall_zerotts() {
    load_config
    echo -e "\n${RED}${BOLD}⚠ CẢNH BÁO: BẠN CÓ CHẮC CHẮN MUỐN GỠ BỎ ZEROTTS?${NC}"
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

    if [ -f "/etc/systemd/system/${SYSTEMD_SERVICE}.service" ]; then
        systemctl stop "$SYSTEMD_SERVICE" 2>/dev/null || true
        systemctl disable "$SYSTEMD_SERVICE" 2>/dev/null || true
        rm -f "/etc/systemd/system/${SYSTEMD_SERVICE}.service"
        systemctl daemon-reload
    fi

    rm -rf "$INSTALL_DIR"
    rm -rf "$CONFIG_FILE"

    echo -e "${GREEN}✓ Đã gỡ bỏ sạch sẽ ZeroTTS khỏi máy chủ!${NC}\n"
}

# Menu chính
main_menu() {
    show_banner
    detect_os
    load_config

    echo -e "${BOLD}Chọn tác vụ bạn muốn thực hiện:${NC}"
    echo -e "   1) ${GREEN}${BOLD}Cài đặt & Khởi chạy bằng DOCKER (Khuyên dùng - Ổn định, hỗ trợ CUDA GPU)${NC}"
    echo -e "   2) ${CYAN}Cài đặt bằng Python Virtualenv + Systemd service${NC}"
    echo -e "   3) ${YELLOW}Kiểm tra trạng thái & Cổng lắng nghe (${PORT})${NC}"
    echo -e "   4) ${CYAN}Xem Live Logs của dịch vụ${NC}"
    echo -e "   5) ${GREEN}Test tạo file âm thanh mẫu (WAV Test)${NC}"
    echo -e "   6) ${BLUE}Mở / Kiểm tra lại tường lửa cho Port ${PORT}${NC}"
    echo -e "   7) Khởi động lại dịch vụ"
    echo -e "   8) Dừng dịch vụ"
    echo -e "   9) ${RED}Gỡ bỏ ZeroTTS hoàn toàn${NC}"
    echo -e "   0) Thoát"

    echo ""
    read -rp "Nhập lựa chọn của bạn [0-9] (Mặc định: 1): " MENU_CHOICE
    MENU_CHOICE="${MENU_CHOICE:-1}"

    case "$MENU_CHOICE" in
        1)
            deploy_with_docker
            ;;
        2)
            deploy_with_python_systemd
            ;;
        3)
            check_status
            ;;
        4)
            view_logs
            ;;
        5)
            test_synthesis
            ;;
        6)
            open_firewall_port "$PORT"
            ;;
        7)
            restart_service
            ;;
        8)
            stop_service
            ;;
        9)
            uninstall_zerotts
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
