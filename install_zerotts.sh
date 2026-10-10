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
import shutil
import base64
import tempfile
from typing import Optional, List, Dict, Any
import numpy as np
from scipy.io import wavfile
from fastapi import FastAPI, HTTPException, Response, UploadFile, File, Form, Query
from fastapi.responses import HTMLResponse, JSONResponse, StreamingResponse
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel, Field

from zerotts import ZeroTTS, normalize_vi_text
from zerotts.chunking import chunk_text, clean_segment_punctuation, normalize_punctuation
from zerotts.audio import concat_with_silence

app = FastAPI(
    title="ZeroTTS Vietnamese AI Speech API",
    description="Hệ thống API chuyển văn bản thành giọng nói tiếng Việt thời gian thực (Tương thích 100% chuẩn OpenAI Audio Speech và REST API cho hệ thống ngoài tích hợp).",
    version="1.2.0",
    docs_url="/docs",
    redoc_url="/redoc"
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

MODEL_ID = os.getenv("MODEL_REPO", "zeroweight-ai/ZeroTTS")
DEVICE = os.getenv("DEVICE", "cuda").lower()

print(f"[*] Khởi tạo ZeroTTS model '{MODEL_ID}' (Cấu hình thiết bị: {DEVICE})...")

# Khởi tạo Execution Providers cho ONNX Runtime
providers = ["CPUExecutionProvider"]
if DEVICE == "cuda":
    try:
        import onnxruntime as ort
        avail_providers = ort.get_available_providers()
        print(f"[*] ONNX Runtime Available Providers: {avail_providers}")
        if "CUDAExecutionProvider" in avail_providers:
            providers = ["CUDAExecutionProvider", "CPUExecutionProvider"]
            print("[+] KÍCH HOẠT TĂNG TỐC GPU: ['CUDAExecutionProvider', 'CPUExecutionProvider']")
        else:
            print("[!] Không tìm thấy CUDAExecutionProvider trong ONNX Runtime, sẽ chạy trên CPU.")
    except Exception as e:
        print(f"[!] Lỗi khi kiểm tra providers: {e}")

try:
    tts = ZeroTTS.from_pretrained(MODEL_ID, providers=providers)
    active_providers = tts.prefix_step_sess.get_providers()
    print(f"[+] Tải ZeroTTS model thành công! Providers đang dùng: {active_providers}, Sample rate: {tts.sample_rate}Hz")
except Exception as e:
    print(f"[!] Lỗi khi nạp model với providers {providers}: {e}")
    if providers != ["CPUExecutionProvider"]:
        print("[*] Đang fallback sang CPUExecutionProvider...")
        tts = ZeroTTS.from_pretrained(MODEL_ID, providers=["CPUExecutionProvider"])
        active_providers = tts.prefix_step_sess.get_providers()
        print(f"[+] Fallback CPU thành công! Providers: {active_providers}")
    else:
        raise e

# Bảng metadata chi tiết cho 8 giọng mặc định của ZeroTTS
BUILTIN_VOICES_INFO = {
    "maichi": {
        "id": "maichi",
        "name": "Mai Chi",
        "gender": "nữ",
        "tags": ["trẻ", "kể chuyện", "nhẹ nhàng", "thân thiện"],
        "description": "Giọng nữ miền Bắc nhẹ nhàng, truyền cảm, thích hợp đọc truyện và trợ lý ảo"
    },
    "baotrang": {
        "id": "baotrang",
        "name": "Bảo Trang",
        "gender": "nữ",
        "tags": ["trưởng thành", "tin tức", "rõ ràng", "trung tính"],
        "description": "Giọng nữ chuẩn biên tập viên tin tức, rõ ràng, dứt khoát"
    },
    "kimoanh": {
        "id": "kimoanh",
        "name": "Kim Oanh",
        "gender": "nữ",
        "tags": ["trung niên", "kể chuyện", "ấm áp", "truyền cảm"],
        "description": "Giọng nữ ấm áp, đầm ấm, thích hợp đọc sách nói và tâm sự"
    },
    "hamy": {
        "id": "hamy",
        "name": "Hà My",
        "gender": "nữ",
        "tags": ["trẻ", "hoạt hình", "cao", "biểu cảm"],
        "description": "Giọng nữ trẻ trung, trong trẻo, hoạt bát, thích hợp hoạt hình và video ngắn"
    },
    "giahuy": {
        "id": "giahuy",
        "name": "Gia Huy",
        "gender": "nam",
        "tags": ["trẻ", "kể chuyện", "trầm ấm", "tâm tình"],
        "description": "Giọng nam trẻ trầm ấm, mộc mạc, truyền cảm, phù hợp podcast và kể chuyện"
    },
    "huuduc": {
        "id": "huuduc",
        "name": "Hữu Đức",
        "gender": "nam",
        "tags": ["lớn tuổi", "kể chuyện", "trầm", "điềm đạm"],
        "description": "Giọng nam lớn tuổi điềm đạm, uy nghiêm, giọng đọc phóng sự, tài liệu lịch sử"
    },
    "quangminh": {
        "id": "quangminh",
        "name": "Quang Minh",
        "gender": "nam",
        "tags": ["trẻ", "tin tức", "rõ ràng", "dứt khoát"],
        "description": "Giọng nam thời sự, dứt khoát, thanh thoát, thích hợp phát thanh và tin nhanh"
    },
    "tiendat": {
        "id": "tiendat",
        "name": "Tiến Đạt",
        "gender": "nam",
        "tags": ["trẻ", "bình luận", "sôi nổi", "năng lượng cao"],
        "description": "Giọng nam sôi nổi, hào hứng, phù hợp bình luận thể thao, video review"
    }
}

def get_all_voices_list() -> List[Dict[str, Any]]:
    try:
        current_names = tts.list_voices()
    except Exception:
        current_names = list(BUILTIN_VOICES_INFO.keys())

    voices_list = []
    for vname in current_names:
        if vname in BUILTIN_VOICES_INFO:
            voices_list.append(BUILTIN_VOICES_INFO[vname])
        else:
            # Giọng tùy biến nạp thêm từ ngoài
            voices_list.append({
                "id": vname,
                "name": vname.capitalize(),
                "gender": "tùy biến",
                "tags": ["custom"],
                "description": f"Giọng tùy biến '{vname}'"
            })
    return voices_list

def synthesize_audio(
    text: str,
    voice: str = "maichi",
    normalize: bool = True,
    chunk_long_form: bool = True,
    cfg_scale: float = 1.0
) -> np.ndarray:
    if not text or not text.strip():
        raise HTTPException(status_code=400, detail="Nội dung 'input' hoặc 'text' không được để trống.")
    
    # 1. Chuẩn hóa tiếng Việt (ngày tháng, giờ, tiền tệ, từ viết tắt...)
    processed_text = normalize_vi_text(text) if normalize else text.strip()

    # 2. Kiểm tra giọng đọc
    available_voices = tts.list_voices()
    if voice not in available_voices and available_voices:
        voice = available_voices[0]

    # 3. Phân đoạn thông minh cho văn bản dài theo kiến trúc ZeroTTS
    # Giúp âm thanh mượt mà, không bị hiện tượng lặp âm ở văn bản nhiều câu
    need_chunk = chunk_long_form and (
        len(processed_text) > 120 or "\n" in processed_text or sum(processed_text.count(p) for p in [".", "?", "!", ";"]) > 1
    )

    if need_chunk:
        segments = [
            clean_segment_punctuation(s)
            for s in chunk_text(normalize_punctuation(processed_text), max_chunk_sec=12.0)
        ]
        segments = [s for s in segments if s.strip()]
        if len(segments) > 1:
            chunks = [tts.synthesize(seg, voice=voice, cfg_scale=cfg_scale) for seg in segments]
            audio = concat_with_silence(chunks, silence_sec=0.15, sample_rate=tts.sample_rate)
            return np.asarray(audio).squeeze()

    audio = tts.synthesize(processed_text, voice=voice, cfg_scale=cfg_scale)
    return np.asarray(audio).squeeze()

def encode_to_wav(audio_arr: np.ndarray, sample_rate: int) -> bytes:
    audio_int16 = (np.clip(audio_arr, -1.0, 1.0) * 32767).astype(np.int16)
    buf = io.BytesIO()
    wavfile.write(buf, sample_rate, audio_int16)
    return buf.getvalue()

# ==============================================================================
# PYDANTIC SCHEMAS
# ==============================================================================
class OpenAISpeechRequest(BaseModel):
    model: Optional[str] = Field("zerotts", description="Tên mô hình (ví dụ: 'zerotts', 'tts-1', 'tts-1-hd')")
    input: str = Field(..., description="Văn bản cần đọc")
    voice: Optional[str] = Field("maichi", description="Giọng đọc: maichi, baotrang, kimoanh, hamy, giahuy, huuduc, quangminh, tiendat")
    response_format: Optional[str] = Field("wav", description="Định dạng âm thanh trả về ('wav')")
    speed: Optional[float] = Field(1.0, description="Tốc độ đọc (1.0 mặc định)")
    normalize: Optional[bool] = Field(True, description="Tự động chuẩn hóa số, ngày giờ, viết tắt tiếng Việt")
    chunk_long_form: Optional[bool] = Field(True, description="Tự động phân đoạn thông minh văn bản dài")
    cfg_scale: Optional[float] = Field(1.0, description="Trọng số bám sát đặc trưng giọng đọc (1.0 - 2.0)")

class SynthesizeRequest(BaseModel):
    text: str = Field(..., description="Văn bản tiếng Việt cần đọc")
    voice: Optional[str] = Field("maichi", description="Tên giọng đọc")
    normalize: Optional[bool] = Field(True, description="Chuẩn hóa ngày giờ, số, tiền tệ")
    chunk_long_form: Optional[bool] = Field(True, description="Phân đoạn thông minh cho văn bản dài")
    cfg_scale: Optional[float] = Field(1.0, description="Trọng số giọng")
    return_base64: Optional[bool] = Field(False, description="Nếu True sẽ trả về chuỗi Base64 thay vì file nhị phân WAV")

class NormalizeRequest(BaseModel):
    input: str = Field(..., description="Văn bản gốc cần kiểm tra chuẩn hóa")

# ==============================================================================
# CÁC ENDPOINT CHÍNH
# ==============================================================================

@app.get("/health", summary="Kiểm tra tình trạng máy chủ & GPU")
def health():
    providers_in_use = []
    try:
        providers_in_use = tts.prefix_step_sess.get_providers()
    except Exception:
        pass
    using_gpu = "CUDAExecutionProvider" in providers_in_use
    return {
        "status": "healthy",
        "model": MODEL_ID,
        "sample_rate": tts.sample_rate,
        "device": DEVICE,
        "providers": providers_in_use,
        "using_gpu": using_gpu,
        "total_voices": len(get_all_voices_list())
    }

@app.get("/v1/models", summary="Danh sách models (Chuẩn OpenAI)")
@app.get("/models", summary="Danh sách models")
def list_models():
    """Trả về danh sách models chuẩn OpenAI để Dify, NextChat, Open-WebUI dễ dàng kết nối."""
    return {
        "object": "list",
        "data": [
            {"id": "zerotts", "object": "model", "created": 1700000000, "owned_by": "zeroweight-ai"},
            {"id": "tts-1", "object": "model", "created": 1700000000, "owned_by": "zeroweight-ai"},
            {"id": "tts-1-hd", "object": "model", "created": 1700000000, "owned_by": "zeroweight-ai"}
        ]
    }

@app.get("/v1/audio/voices", summary="Danh sách giọng đọc chi tiết")
@app.get("/api/voices", summary="Danh sách giọng đọc chi tiết (REST)")
def get_voices():
    """Trả về danh sách đầy đủ 8 giọng đọc tiếng Việt kèm thông tin giới tính, phong cách."""
    voices_list = get_all_voices_list()
    default_voice = voices_list[0]["id"] if voices_list else "maichi"
    return {
        "default": default_voice,
        "voices": [v["id"] for v in voices_list],
        "details": voices_list
    }

@app.post("/v1/audio/speech", summary="Tạo âm thanh chuẩn OpenAI Speech API")
def openai_speech(req: OpenAISpeechRequest):
    """
    Endpoint tương thích 100% chuẩn OpenAI `/v1/audio/speech`.
    Các ứng dụng như NextChat, Dify, LibreChat, Open-WebUI có thể trỏ trực tiếp Base URL vào đây.
    """
    start_time = time.time()
    try:
        audio_arr = synthesize_audio(
            text=req.input,
            voice=req.voice or "maichi",
            normalize=req.normalize,
            chunk_long_form=req.chunk_long_form,
            cfg_scale=req.cfg_scale or 1.0
        )
        wav_bytes = encode_to_wav(audio_arr, tts.sample_rate)
        proc_time = round((time.time() - start_time) * 1000, 2)
        duration_sec = round(len(audio_arr) / tts.sample_rate, 2)

        return Response(
            content=wav_bytes,
            media_type="audio/wav",
            headers={
                "Content-Disposition": "attachment; filename=speech.wav",
                "X-Process-Time-Ms": str(proc_time),
                "X-Audio-Duration-Sec": str(duration_sec)
            }
        )
    except HTTPException:
        raise
    except Exception as e:
        import traceback
        traceback.print_exc()
        raise HTTPException(status_code=500, detail=f"Lỗi tạo âm thanh: {str(e)}")

@app.post("/api/synthesize", summary="Tạo âm thanh qua REST API (Hỗ trợ Base64)")
def api_synthesize(req: SynthesizeRequest):
    """
    Endpoint REST API đa năng cho Backend/Microservices.
    Hỗ trợ xuất trực tiếp file WAV hoặc mã hóa chuỗi JSON Base64.
    """
    start_time = time.time()
    try:
        audio_arr = synthesize_audio(
            text=req.text,
            voice=req.voice or "maichi",
            normalize=req.normalize,
            chunk_long_form=req.chunk_long_form,
            cfg_scale=req.cfg_scale or 1.0
        )
        wav_bytes = encode_to_wav(audio_arr, tts.sample_rate)
        proc_time = round((time.time() - start_time) * 1000, 2)
        duration_sec = round(len(audio_arr) / tts.sample_rate, 2)

        if req.return_base64:
            b64_str = base64.b64encode(wav_bytes).decode("utf-8")
            return {
                "success": True,
                "audio_base64": b64_str,
                "format": "audio/wav",
                "duration_sec": duration_sec,
                "process_time_ms": proc_time,
                "sample_rate": tts.sample_rate,
                "voice": req.voice
            }

        return Response(
            content=wav_bytes,
            media_type="audio/wav",
            headers={
                "Content-Disposition": "attachment; filename=synthesized.wav",
                "X-Process-Time-Ms": str(proc_time),
                "X-Audio-Duration-Sec": str(duration_sec)
            }
        )
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

@app.post("/api/normalize", summary="Kiểm tra cách đọc số & viết tắt tiếng Việt")
def api_normalize(req: NormalizeRequest):
    """
    Xem trước cách ZeroTTS diễn giải ngày tháng (23/8/2026), giờ (15h30),
    số tiền (1.250.000đ), số thập phân (12,5) và từ viết tắt sang chữ tiếng Việt.
    """
    orig = req.input
    expanded = normalize_vi_text(orig)
    return {
        "original": orig,
        "normalized": expanded
    }

@app.post("/api/voices/upload", summary="Nạp thêm Voice Pack tùy biến (.zip)")
async def upload_voice(file: UploadFile = File(...)):
    """
    Nạp thêm giọng đọc mới từ file `.zip` (xuất từ platform zeroweight.ai).
    Giọng mới sẽ có hiệu lực ngay lập tức mà không cần khởi động lại server.
    """
    if not file.filename.endswith(".zip"):
        raise HTTPException(status_code=400, detail="Chỉ hỗ trợ file .zip voice pack.")
    
    with tempfile.NamedTemporaryFile(suffix=".zip", delete=False) as tmp:
        shutil.copyfileobj(file.file, tmp)
        tmp_path = tmp.name

    try:
        if hasattr(tts, "add_voices"):
            names = tts.add_voices(tmp_path)
            return {"success": True, "message": f"Đã nạp thành công {len(names)} giọng mới", "voices": names}
        else:
            from zerotts.voices import install_voice_zip
            names = install_voice_zip(tmp_path)
            return {"success": True, "message": f"Đã nạp thành công {len(names)} giọng mới", "voices": names}
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Lỗi khi nạp giọng: {str(e)}")
    finally:
        if os.path.exists(tmp_path):
            os.remove(tmp_path)

@app.get("/", response_class=HTMLResponse, summary="Giao diện WebUI & Tài liệu API")
def index():
    return """
    <!DOCTYPE html>
    <html lang="vi">
    <head>
        <meta charset="UTF-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
        <title>ZeroTTS Vietnamese Studio & API Hub</title>
        <link href="https://fonts.googleapis.com/css2?family=Plus+Jakarta+Sans:wght@400;500;600;700&family=JetBrains+Mono:wght@400;600&display=swap" rel="stylesheet">
        <style>
            :root {
                --bg: #0b0f19;
                --card: #131b2e;
                --card-alt: #1a243c;
                --border: #23314e;
                --primary: #3b82f6;
                --primary-hover: #2563eb;
                --success: #10b981;
                --warning: #f59e0b;
                --text: #f8fafc;
                --muted: #94a3b8;
            }
            body {
                font-family: 'Plus Jakarta Sans', sans-serif;
                background-color: var(--bg);
                color: var(--text);
                margin: 0;
                padding: 30px 20px;
                display: flex;
                justify-content: center;
            }
            .wrapper {
                max-width: 900px;
                width: 100%;
            }
            .header-bar {
                display: flex;
                align-items: center;
                justify-content: space-between;
                flex-wrap: wrap;
                margin-bottom: 24px;
                gap: 12px;
            }
            h1 {
                margin: 0;
                font-size: 26px;
                display: flex;
                align-items: center;
                gap: 12px;
            }
            .badges {
                display: flex;
                gap: 8px;
            }
            .badge {
                padding: 5px 12px;
                border-radius: 8px;
                font-size: 13px;
                font-weight: 600;
            }
            .badge-primary { background: rgba(59, 130, 246, 0.2); color: #60a5fa; border: 1px solid rgba(59, 130, 246, 0.3); }
            .badge-gpu { background: rgba(16, 185, 129, 0.2); color: #34d399; border: 1px solid rgba(16, 185, 129, 0.3); }
            .badge-cpu { background: rgba(245, 158, 11, 0.2); color: #fbbf24; border: 1px solid rgba(245, 158, 11, 0.3); }
            
            .nav-tabs {
                display: flex;
                gap: 8px;
                border-bottom: 1px solid var(--border);
                margin-bottom: 24px;
            }
            .nav-tab {
                padding: 12px 20px;
                cursor: pointer;
                font-weight: 600;
                color: var(--muted);
                border-bottom: 2px solid transparent;
                transition: all 0.2s;
            }
            .nav-tab.active {
                color: #60a5fa;
                border-bottom: 2px solid #3b82f6;
            }
            .tab-pane { display: none; }
            .tab-pane.active { display: block; }

            .card {
                background: var(--card);
                border: 1px solid var(--border);
                border-radius: 16px;
                padding: 28px;
                box-shadow: 0 16px 36px rgba(0,0,0,0.4);
                margin-bottom: 24px;
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
                background: #090e1a;
                border: 1px solid var(--border);
                border-radius: 12px;
                color: #fff;
                padding: 16px;
                font-size: 15px;
                min-height: 110px;
                resize: vertical;
                outline: none;
                line-height: 1.6;
            }
            textarea:focus { border-color: var(--primary); }

            .quick-samples {
                display: flex;
                gap: 8px;
                flex-wrap: wrap;
                margin-top: 10px;
            }
            .chip {
                background: var(--card-alt);
                border: 1px solid var(--border);
                color: #94a3b8;
                padding: 4px 10px;
                border-radius: 6px;
                font-size: 12px;
                cursor: pointer;
                transition: all 0.2s;
            }
            .chip:hover {
                color: #fff;
                border-color: #3b82f6;
            }

            .grid-2 {
                display: grid;
                grid-template-columns: 1fr 1fr;
                gap: 16px;
                margin-top: 18px;
            }
            select, input[type="text"] {
                width: 100%;
                background: #090e1a;
                border: 1px solid var(--border);
                color: #fff;
                border-radius: 8px;
                padding: 11px 14px;
                outline: none;
                box-sizing: border-box;
            }
            .btn {
                width: 100%;
                background: var(--primary);
                color: white;
                border: none;
                border-radius: 10px;
                padding: 14px;
                font-size: 16px;
                font-weight: 600;
                cursor: pointer;
                margin-top: 20px;
                transition: background 0.2s;
            }
            .btn:hover { background: var(--primary-hover); }
            .btn:disabled { opacity: 0.6; cursor: not-allowed; }

            .preview-norm {
                background: #090e1a;
                border: 1px dashed var(--border);
                border-radius: 10px;
                padding: 12px 16px;
                font-size: 13px;
                margin-top: 12px;
                color: #38bdf8;
                display: none;
            }

            .player-box {
                margin-top: 24px;
                padding: 20px;
                background: #090e1a;
                border-radius: 12px;
                border: 1px solid var(--border);
                display: none;
            }
            audio { width: 100%; margin-top: 8px; }
            .stats {
                font-size: 13px;
                color: var(--muted);
                margin-top: 10px;
                display: flex;
                justify-content: space-between;
                flex-wrap: wrap;
            }

            /* Code block style */
            pre, code {
                font-family: 'JetBrains Mono', monospace;
            }
            .code-block {
                background: #090e1a;
                border: 1px solid var(--border);
                border-radius: 10px;
                padding: 16px;
                overflow-x: auto;
                font-size: 13px;
                color: #e2e8f0;
                line-height: 1.5;
                margin-top: 10px;
            }
            .doc-link-btn {
                display: inline-flex;
                align-items: center;
                gap: 6px;
                background: rgba(59, 130, 246, 0.15);
                color: #60a5fa;
                border: 1px solid rgba(59, 130, 246, 0.3);
                padding: 8px 16px;
                border-radius: 8px;
                font-size: 14px;
                font-weight: 600;
                text-decoration: none;
                margin-bottom: 20px;
            }
            .doc-link-btn:hover { background: rgba(59, 130, 246, 0.25); }
        </style>
    </head>
    <body>
        <div class="wrapper">
            <div class="header-bar">
                <h1>🎙️ ZeroTTS Studio <span class="badge badge-primary">Vietnamese AI</span></h1>
                <div class="badges">
                    <span id="gpuBadge" class="badge badge-cpu">Đang kiểm tra...</span>
                    <span id="voiceCountBadge" class="badge badge-primary">8 Giọng đọc</span>
                </div>
            </div>

            <div class="nav-tabs">
                <div class="nav-tab active" onclick="switchTab('studio')">🎧 Trải nghiệm giọng nói</div>
                <div class="nav-tab" onclick="switchTab('api-docs')">⚡ Hướng dẫn tích hợp API</div>
                <div class="nav-tab" onclick="switchTab('voices-tab')">🗣️ Danh sách giọng đọc</div>
            </div>

            <!-- TAB 1: STUDIO -->
            <div id="tab-studio" class="tab-pane active">
                <div class="card">
                    <label for="textInput">Nhập văn bản tiếng Việt:</label>
                    <textarea id="textInput">Hôm nay ngày 30/4 lúc 15h30, hệ thống ZeroTTS chạy thử nghiệm tốc độ cao với 8 giọng đọc tiếng Việt cực kỳ tự nhiên.</textarea>
                    
                    <div class="quick-samples">
                        <span class="chip" onclick="setSample('greeting')">👋 Câu chào mừng</span>
                        <span class="chip" onclick="setSample('news')">📰 Bản tin công nghệ</span>
                        <span class="chip" onclick="setSample('numbers')">🔢 Số tiền & Ngày giờ</span>
                        <span class="chip" onclick="checkNormalize()">🔍 Xem cách đọc số</span>
                    </div>

                    <div id="normPreview" class="preview-norm"></div>

                    <div class="grid-2">
                        <div>
                            <label for="voiceSelect">Giọng đọc (Voice):</label>
                            <select id="voiceSelect"></select>
                        </div>
                        <div>
                            <label for="speedSelect">Tốc độ & Tính năng:</label>
                            <select id="featureSelect">
                                <option value="norm">Tự động chuẩn hóa số & từ viết tắt (Khuyên dùng)</option>
                                <option value="raw">Giữ nguyên văn bản gốc</option>
                            </select>
                        </div>
                    </div>

                    <button id="genBtn" class="btn" onclick="generateSpeech()">⚡ Phát sinh giọng nói</button>

                    <div id="playerBox" class="player-box">
                        <label>🔊 Bản phát âm thanh kết quả:</label>
                        <audio id="audioPlayer" controls></audio>
                        <div class="stats" id="statsBox"></div>
                    </div>
                </div>
            </div>

            <!-- TAB 2: API DOCS -->
            <div id="tab-api-docs" class="tab-pane">
                <div class="card">
                    <a href="/docs" target="_blank" class="doc-link-btn">📖 Mở Swagger Interactive API Docs ↗</a>
                    <a href="/redoc" target="_blank" class="doc-link-btn" style="margin-left:8px;">📄 Mở ReDoc ↗</a>
                    
                    <h3>1. Tích hợp chuẩn OpenAI Audio Speech API (`/v1/audio/speech`)</h3>
                    <p style="color:var(--muted); font-size:14px;">Trỏ Base URL của các ứng dụng (Dify, NextChat, Open-WebUI, LibreChat) vào <code>http://&lt;IP-MÁY-CHỦ&gt;:8002/v1</code></p>
                    <div class="code-block">curl -X POST http://localhost:8002/v1/audio/speech \
  -H "Content-Type: application/json" \
  -d '{
    "model": "zerotts",
    "input": "Hôm nay thời tiết rất đẹp, chúc bạn một ngày làm việc hiệu quả!",
    "voice": "maichi"
  }' --output speech.wav</div>

                    <h3 style="margin-top:24px;">2. Tích hợp bằng Python (OpenAI SDK chính thức)</h3>
                    <div class="code-block">from openai import OpenAI

client = OpenAI(base_url="http://localhost:8002/v1", api_key="none")

response = client.audio.speech.create(
    model="zerotts",
    voice="maichi",
    input="Xin chào bạn! ZeroTTS hỗ trợ tiếng Việt cực kỳ tự nhiên và siêu tốc."
)
response.stream_to_file("output.wav")</div>

                    <h3 style="margin-top:24px;">3. Tích hợp bằng Node.js / TypeScript</h3>
                    <div class="code-block">import fs from "fs";
import OpenAI from "openai";

const openai = new OpenAI({
  baseURL: "http://localhost:8002/v1",
  apiKey: "none"
});

async function main() {
  const mp3 = await openai.audio.speech.create({
    model: "zerotts",
    voice: "maichi",
    input: "Xin chào thế giới! Đây là âm thanh từ ZeroTTS."
  });
  const buffer = Buffer.from(await mp3.arrayBuffer());
  await fs.promises.writeFile("output.wav", buffer);
}
main();</div>

                    <h3 style="margin-top:24px;">4. Gọi trực tiếp bằng JSON API (Nhận Base64 cho Web/App)</h3>
                    <div class="code-block">curl -X POST http://localhost:8002/api/synthesize \
  -H "Content-Type: application/json" \
  -d '{
    "text": "Chào bạn, đây là dữ liệu âm thanh trả về dạng Base64.",
    "voice": "maichi",
    "return_base64": true
  }'</div>
                </div>
            </div>

            <!-- TAB 3: VOICES LIST -->
            <div id="tab-voices-tab" class="tab-pane">
                <div class="card" id="voicesContainer">
                    <p style="color:var(--muted)">Đang tải danh sách giọng đọc...</p>
                </div>
            </div>
        </div>

        <script>
            let isUsingGpu = false;
            let currentVoices = [];

            const SAMPLES = {
                greeting: "Xin chào quý vị và các bạn! Cảm ơn mọi người đã theo dõi buổi phát thanh ngày hôm nay.",
                news: "Thị trường công nghệ tuần qua ghi nhận nhiều bước đột phá của các mô hình trí tuệ nhân tạo nguồn mở, giúp rút ngắn thời gian xử lý và tối ưu hóa chi phí vận hành cho doanh nghiệp.",
                numbers: "Vào ngày 30/4/2026 lúc 14h30, phiên bản v2.5 sẽ được phân phối với mức chi phí 1.500.000 đồng, giảm 20% so với dự kiến."
            };

            function switchTab(tab) {
                document.querySelectorAll('.nav-tab').forEach(t => t.classList.remove('active'));
                document.querySelectorAll('.tab-pane').forEach(p => p.classList.remove('active'));
                if (tab === 'studio') {
                    document.querySelectorAll('.nav-tab')[0].classList.add('active');
                    document.getElementById('tab-studio').classList.add('active');
                } else if (tab === 'api-docs') {
                    document.querySelectorAll('.nav-tab')[1].classList.add('active');
                    document.getElementById('tab-api-docs').classList.add('active');
                } else if (tab === 'voices-tab') {
                    document.querySelectorAll('.nav-tab')[2].classList.add('active');
                    document.getElementById('tab-voices-tab').classList.add('active');
                }
            }

            function setSample(key) {
                document.getElementById('textInput').value = SAMPLES[key];
                document.getElementById('normPreview').style.display = 'none';
            }

            async function checkNormalize() {
                const text = document.getElementById('textInput').value;
                if (!text.trim()) return;
                try {
                    const res = await fetch('/api/normalize', {
                        method: 'POST',
                        headers: {'Content-Type': 'application/json'},
                        body: JSON.stringify({input: text})
                    });
                    const d = await res.json();
                    const box = document.getElementById('normPreview');
                    box.style.display = 'block';
                    box.innerHTML = '<strong>Đọc thực tế:</strong> "' + d.normalized + '"';
                } catch(e) {
                    console.warn(e);
                }
            }

            window.addEventListener('DOMContentLoaded', async () => {
                try {
                    const hRes = await fetch('/health');
                    const hData = await hRes.json();
                    isUsingGpu = hData.using_gpu;
                    const badge = document.getElementById('gpuBadge');
                    if (hData.using_gpu) {
                        badge.className = 'badge badge-gpu';
                        badge.innerText = '⚡ GPU NVIDIA (CUDA)';
                    } else {
                        badge.className = 'badge badge-cpu';
                        badge.innerText = '💻 CPU Mode';
                    }
                } catch(e) { console.warn(e); }

                try {
                    const vRes = await fetch('/v1/audio/voices');
                    const vData = await vRes.json();
                    currentVoices = vData.details || [];
                    document.getElementById('voiceCountBadge').innerText = currentVoices.length + ' Giọng đọc';

                    const sel = document.getElementById('voiceSelect');
                    sel.innerHTML = '';
                    currentVoices.forEach(v => {
                        const opt = document.createElement('option');
                        opt.value = v.id;
                        opt.textContent = `${v.name} (${v.gender.toUpperCase()} - ${v.tags.slice(0, 2).join(', ')})`;
                        sel.appendChild(opt);
                    });

                    // Render voices tab
                    const vc = document.getElementById('voicesContainer');
                    let html = '<h3 style="margin-top:0">Danh sách 8 Giọng đọc chuẩn tích hợp:</h3>';
                    html += '<div style="display:grid; grid-template-columns:1fr 1fr; gap:16px;">';
                    currentVoices.forEach(v => {
                        html += `
                        <div style="background:var(--card-alt); border:1px solid var(--border); border-radius:10px; padding:16px;">
                            <div style="display:flex; justify-content:space-between; align-items:center; margin-bottom:6px;">
                                <strong style="font-size:16px; color:#fff;">${v.name} (<code>${v.id}</code>)</strong>
                                <span class="badge badge-primary">${v.gender}</span>
                            </div>
                            <p style="font-size:13px; color:var(--muted); margin:6px 0;">${v.description}</p>
                            <div style="display:flex; gap:6px; flex-wrap:wrap; margin-top:8px;">
                                ${(v.tags || []).map(t => `<span class="chip" style="font-size:11px;">#${t}</span>`).join('')}
                            </div>
                        </div>`;
                    });
                    html += '</div>';
                    vc.innerHTML = html;
                } catch(e) { console.warn(e); }
            });

            async function generateSpeech() {
                const text = document.getElementById('textInput').value;
                const voice = document.getElementById('voiceSelect').value;
                const feature = document.getElementById('featureSelect').value;
                const btn = document.getElementById('genBtn');
                const playerBox = document.getElementById('playerBox');
                const player = document.getElementById('audioPlayer');
                const stats = document.getElementById('statsBox');

                if (!text.trim()) {
                    alert('Vui lòng nhập văn bản!');
                    return;
                }

                btn.disabled = true;
                btn.innerText = '⏳ Đang tổng hợp giọng nói...';

                const t0 = performance.now();
                try {
                    const response = await fetch('/v1/audio/speech', {
                        method: 'POST',
                        headers: { 'Content-Type': 'application/json' },
                        body: JSON.stringify({
                            input: text,
                            voice: voice,
                            normalize: feature === 'norm'
                        })
                    });

                    if (!response.ok) {
                        const err = await response.json();
                        throw new Error(err.detail || 'Lỗi server (HTTP ' + response.status + ')');
                    }

                    const blob = await response.blob();
                    const audioUrl = URL.createObjectURL(blob);
                    const elapsed = Math.round(performance.now() - t0);
                    const modeTxt = isUsingGpu ? '⚡ GPU CUDA' : '💻 CPU';
                    const procHdr = response.headers.get('X-Process-Time-Ms') || elapsed;
                    const durHdr = response.headers.get('X-Audio-Duration-Sec') || '';

                    player.src = audioUrl;
                    playerBox.style.display = 'block';
                    stats.innerHTML = `<span>⏱️ Xử lý: <strong>${procHdr} ms</strong> (${modeTxt})</span> <span>🎧 Độ dài audio: <strong>${durHdr}s</strong> (48kHz WAV PCM)</span>`;
                    player.play();
                } catch(e) {
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
FROM nvidia/cuda:12.4.1-cudnn-runtime-ubuntu22.04

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
    "uvicorn[standard]" \
    soundfile \
    scipy \
    numpy \
    huggingface-hub \
    pydantic \
    python-multipart

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
    pip install "zerotts" "fastapi" "uvicorn[standard]" "pydantic" "soundfile" "scipy" "numpy" "huggingface-hub" "python-multipart"

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
    echo -e "${GREEN}${BOLD}         🎉 CÀI ĐẶT & KHỞI CHẠY ZEROTTS API THÀNH CÔNG!         ${NC}"
    echo -e "${CYAN}${BOLD}=================================================================${NC}\n"

    echo -e "${BOLD}📌 THÔNG TIN TRUY CẬP HỆ THỐNG:${NC}"
    echo -e "   • Giao diện WebUI & Studio:    ${GREEN}${BOLD}http://${PUBLIC_IP}:${PORT}${NC}"
    echo -e "   • Tài liệu Swagger API Docs:   ${GREEN}${BOLD}http://${PUBLIC_IP}:${PORT}/docs${NC}"
    echo -e "   • Tài liệu kỹ thuật ReDoc:     ${GREEN}${BOLD}http://${PUBLIC_IP}:${PORT}/redoc${NC}"
    echo -e "   • Base URL (Chuẩn OpenAI):     ${GREEN}${BOLD}http://${PUBLIC_IP}:${PORT}/v1${NC}"
    echo -e "   • Chế độ tăng tốc:            ${CYAN}${BOLD}${DEVICE^^}${NC} (Nền tảng: ${MODE^^})"

    echo -e "\n${BOLD}📋 LỆNH QUẢN LÝ DỊCH VỤ:${NC}"
    if [ "$MODE" = "docker" ]; then
        echo -e "   • Xem live logs:       ${BOLD}docker logs -f ${DOCKER_CONTAINER_NAME}${NC}"
        echo -e "   • Kiểm tra container:  ${BOLD}docker ps -f name=${DOCKER_CONTAINER_NAME}${NC}"
        echo -e "   • Khởi động lại:       ${BOLD}docker restart ${DOCKER_CONTAINER_NAME}${NC}"
        echo -e "   • Dừng dịch vụ:        ${BOLD}docker stop ${DOCKER_CONTAINER_NAME}${NC}"
    else
        echo -e "   • Xem live logs:       ${BOLD}journalctl -u ${SYSTEMD_SERVICE} -f${NC}"
        echo -e "   • Kiểm tra status:     ${BOLD}systemctl status ${SYSTEMD_SERVICE}${NC}"
        echo -e "   • Khởi động lại:       ${BOLD}systemctl restart ${SYSTEMD_SERVICE}${NC}"
        echo -e "   • Dừng dịch vụ:        ${BOLD}systemctl stop ${SYSTEMD_SERVICE}${NC}"
    fi

    echo -e "\n${BOLD}🌐 CẤU HÌNH KẾT NỐI VÀO CÁC NỀN TẢNG AI (Dify, NextChat, Open-WebUI, Hermes Agent):${NC}"
    echo -e "   • ${YELLOW}Base URL / Endpoint:${NC}  ${BOLD}http://${PUBLIC_IP}:${PORT}/v1${NC}"
    echo -e "   • ${YELLOW}API Key:${NC}              ${BOLD}none${NC} (hoặc chuỗi bất kỳ)"
    echo -e "   • ${YELLOW}TTS Model Name:${NC}       ${BOLD}zerotts${NC} (hoặc ${BOLD}tts-1${NC})"
    echo -e "   • ${YELLOW}Voice Name (8 Giọng):${NC} ${BOLD}maichi${NC} (Nữ - Mặc định), ${BOLD}baotrang${NC} (Nữ tin tức), ${BOLD}giahuy${NC} (Nam ấm), ${BOLD}quangminh${NC} (Nam thời sự), ${BOLD}kimoanh${NC}, ${BOLD}huuduc${NC}, ${BOLD}hamy${NC}, ${BOLD}tiendat${NC}"

    echo -e "\n${BOLD}💻 CODE MẪU GỌI API CHO CÁC HỆ THỐNG KHÁC:${NC}"
    echo -e "${YELLOW}1. cURL (Gọi OpenAI Speech & tải file WAV):${NC}"
    echo -e "${CYAN}curl -X POST http://${PUBLIC_IP}:${PORT}/v1/audio/speech \\"
    echo -e "  -H \"Content-Type: application/json\" \\"
    echo -e "  -d '{"
    echo -e "    \"model\": \"zerotts\","
    echo -e "    \"input\": \"Hôm nay ngày 30/4 lúc 15h30, hệ thống ZeroTTS đọc tiếng Việt rất tự nhiên.\","
    echo -e "    \"voice\": \"maichi\""
    echo -e "  }' --output speech.wav${NC}"

    echo -e "\n${YELLOW}2. Python (Dùng thư viện chính thức OpenAI SDK):${NC}"
    echo -e "${CYAN}from openai import OpenAI"
    echo -e "client = OpenAI(base_url=\"http://${PUBLIC_IP}:${PORT}/v1\", api_key=\"none\")"
    echo -e "response = client.audio.speech.create("
    echo -e "    model=\"zerotts\","
    echo -e "    voice=\"maichi\","
    echo -e "    input=\"Xin chào bạn! ZeroTTS hỗ trợ tiếng Việt cực kỳ mượt mà trên GPU NVIDIA.\""
    echo -e ")"
    echo -e "response.stream_to_file(\"output.wav\")${NC}"

    echo -e "\n${YELLOW}3. Node.js / TypeScript (Fetch hoặc OpenAI SDK):${NC}"
    echo -e "${CYAN}const fs = require('fs');"
    echo -e "fetch('http://${PUBLIC_IP}:${PORT}/v1/audio/speech', {"
    echo -e "  method: 'POST',"
    echo -e "  headers: { 'Content-Type': 'application/json' },"
    echo -e "  body: JSON.stringify({ model: 'zerotts', input: 'Xin chào thế giới!', voice: 'maichi' })"
    echo -e "}).then(res => res.arrayBuffer())"
    echo -e "  .then(buf => fs.writeFileSync('output.wav', Buffer.from(buf)));${NC}"

    echo -e "\n${YELLOW}4. REST API nhận dữ liệu Base64 (Microservice Backend):${NC}"
    echo -e "${CYAN}curl -X POST http://${PUBLIC_IP}:${PORT}/api/synthesize \\"
    echo -e "  -H \"Content-Type: application/json\" \\"
    echo -e "  -d '{\"text\": \"Chào bạn!\", \"voice\": \"maichi\", \"return_base64\": true}'${NC}"

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
    echo -e "\n${BLUE}ℹ Kiểm tra phản hồi API tại http://127.0.0.1:${PORT}/health...${NC}"
    HEALTH_RES=$(curl -s --max-time 3 "http://127.0.0.1:${PORT}/health" 2>/dev/null || echo "")
    if [ -n "$HEALTH_RES" ]; then
        echo -e "${GREEN}✓ Trạng thái hệ thống:${NC} ${CYAN}${HEALTH_RES}${NC}"
    fi

    echo -e "\n${BLUE}ℹ Đang gửi request test tạo âm thanh tới http://127.0.0.1:${PORT}/v1/audio/speech...${NC}"
    
    local OUT_FILE="/tmp/zerotts_test.wav"
    rm -f "$OUT_FILE"

    local T0
    T0=$(date +%s%N 2>/dev/null || date +%s)
    HTTP_CODE=$(curl -s -w "%{http_code}" -X POST "http://127.0.0.1:${PORT}/v1/audio/speech" \
        -H "Content-Type: application/json" \
        -d '{
            "model": "zerotts",
            "input": "Xin chào! Đây là bản tin thử nghiệm âm thanh tiếng Việt từ hệ thống ZeroTTS API.",
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
