#!/bin/bash
set -eo pipefail

# ===================== 基础配置 =====================
OS_TYPE=$(uname -s)
# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# ===================== 工具函数 =====================
print_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
print_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
print_debug() { echo -e "${YELLOW}[DEBUG]${NC} $1"; }

# 检查命令存在性
check_command() {
    if ! command -v "$1" > /dev/null 2>&1; then
        print_error "未安装 $1，请先安装！"
        [ "$1" = "ffmpeg" ] && {
            [ "$OS_TYPE" = "Darwin" ] && print_info "macOS: brew install ffmpeg" || print_info "Linux: sudo apt install ffmpeg"
        }
        [ "$1" = "aplay" ] && [ "$OS_TYPE" != "Darwin" ] && print_info "Linux: sudo apt install alsa-utils"
        exit 1
    fi
}

# 数字校验
is_number() {
    echo "$1" | grep -Eq '^[0-9]+$'
}

# 目录检查 + 写入权限验证（核心修复）
check_dir() {
    # 创建目录
    if [ ! -d "$1" ]; then
        print_info "创建目录：$1"
        mkdir -p "$1" || { print_error "创建目录 $1 失败！"; exit 1; }
    fi
    # 验证写入权限
    TEST_FILE="$1/.test_write_$(date +%s)"
    if ! touch "$TEST_FILE" > /dev/null 2>&1; then
        print_error "目录 $1 无写入权限！请检查权限（如：sudo chmod 777 $1）"
        exit 1
    fi
    rm -f "$TEST_FILE"
    print_info "目录 $1 可正常写入"
}

# ===================== Linux 视频设备扫描 =====================
scan_video_linux() {
    print_info "Linux系统：扫描视频设备..."
    VIDEO_DEVICES=()
    for dev in /dev/video*; do
        [ -c "$dev" ] && echo "$dev" | grep -qv 'ctl$' && VIDEO_DEVICES+=("$dev")
    done
    [ ${#VIDEO_DEVICES[@]} -eq 0 ] && { print_error "无视频设备！"; exit 1; }

    echo -e "\n========== 可用视频设备 =========="
    idx=1
    for dev in "${VIDEO_DEVICES[@]}"; do echo "$idx. $dev"; idx=$((idx+1)); done

    while true; do
        read -p "选择视频设备（序号）：" CHOICE
        if is_number "$CHOICE" && [ "$CHOICE" -ge 1 ] && [ "$CHOICE" -le ${#VIDEO_DEVICES[@]} ]; then
            VID_DEV="${VIDEO_DEVICES[$((CHOICE-1))]}"
            print_success "选中：$VID_DEV"
            break
        else
            print_error "输入无效！范围 1-${#VIDEO_DEVICES[@]}"
        fi
    done
}

# ===================== Linux 视频能力解析 =====================
scan_video_caps_linux() {
    print_info "扫描 $VID_DEV 支持的格式/分辨率..."
    TMP=$(mktemp)
    
    # 执行FFmpeg并过滤含#的行，避免解析错误
    ffmpeg -f v4l2 -list_formats all -i "$VID_DEV" 2>&1 | grep -v '#' > "$TMP" || true

    VIDEO_CAPS=()
    CUR_FMT=""
    # 逐行解析（过滤空行和特殊字符）
    while IFS= read -r line; do
        # 跳过空行
        [ -z "$line" ] && continue
        
        # 解析格式（如 [mjpeg] : Motion-JPEG）
        if echo "$line" | grep -Eq '^\[([a-zA-Z0-9_]+)\][[:space:]]+:'; then
            CUR_FMT=$(echo "$line" | sed -e 's/^\[<span data-type="inline-math" data-value="Lio="></span>\].*/\1/' -e 's/[^a-zA-Z0-9_]//g')
            continue
        fi
        
        # 解析分辨率/帧率（如 1280x720  : 30 fps）
        if echo "$line" | grep -Eq '^[[:space:]]+[0-9]+x[0-9]+[[:space:]]+:[[:space:]]+[0-9]+ fps'; then
            RES=$(echo "$line" | awk '{print $1}' | sed -e 's/[^0-9x]//g')
            FPS=$(echo "$line" | awk '{print $3}' | sed -e 's/[^0-9]//g')
            [ -n "$CUR_FMT" ] && [ -n "$RES" ] && [ -n "$FPS" ] && VIDEO_CAPS+=("$CUR_FMT|$RES|$FPS")
        fi
    done < "$TMP"
    rm -f "$TMP"

    # 默认配置（解析失败时）
    if [ ${#VIDEO_CAPS[@]} -eq 0 ]; then
        print_warn "解析失败，使用默认：1280x720/30fps/mjpeg"
        VID_FMT="mjpeg"
        VID_RES="1280x720"
        VID_FPS="30"
        return
    fi

    # 去重并展示
    echo -e "\n========== 支持的视频配置 =========="
    CLEAN_CAPS=()
    for cap in "${VIDEO_CAPS[@]}"; do
        echo "${CLEAN_CAPS[@]}" | grep -qv "$cap" && CLEAN_CAPS+=("$cap")
    done

    idx=1
    for cap in "${CLEAN_CAPS[@]}"; do
        FMT=$(echo "$cap" | cut -d'|' -f1)
        RES=$(echo "$cap" | cut -d'|' -f2)
        FPS=$(echo "$cap" | cut -d'|' -f3)
        echo "$idx. 格式：$FMT | 分辨率：$RES | 帧率：$FPS fps"
        idx=$((idx+1))
    done

    # 选择配置
    while true; do
        read -p "选择视频配置（序号）：" CHOICE
        if is_number "$CHOICE" && [ "$CHOICE" -ge 1 ] && [ "$CHOICE" -le ${#CLEAN_CAPS[@]} ]; then
            CAP="${CLEAN_CAPS[$((CHOICE-1))]}"
            VID_FMT=$(echo "$CAP" | cut -d'|' -f1)
            VID_RES=$(echo "$CAP" | cut -d'|' -f2)
            VID_FPS=$(echo "$CAP" | cut -d'|' -f3)
            print_success "选中：格式=$VID_FMT，分辨率=$VID_RES，帧率=$VID_FPS fps"
            break
        else
            print_error "输入无效！范围 1-${#CLEAN_CAPS[@]}"
        fi
    done
}

# ===================== Linux 音频设备扫描 =====================
scan_audio_linux() {
    print_info "Linux系统：扫描音频设备..."
    TMP=$(mktemp)
    aplay -l 2>&1 > "$TMP" || true

    AUDIO_DEV=()
    while read -r line; do
        CARD=$(echo "$line" | awk -F 'card |:' '{print $2}' | awk '{print $1}')
        DEV=$(echo "$line" | awk -F 'device |:' '{print $2}' | awk '{print $1}')
        [ -n "$CARD" ] && [ -n "$DEV" ] && AUDIO_DEV+=("hw:$CARD,$DEV")
    done < <(grep 'card .* device' "$TMP")
    rm -f "$TMP"

    echo -e "\n========== 可用音频设备 =========="
    echo "0. 无音频"
    idx=1
    for dev in "${AUDIO_DEV[@]}"; do echo "$idx. $dev"; idx=$((idx+1)); done

    while true; do
        read -p "选择音频设备（序号，0=无）：" CHOICE
        if is_number "$CHOICE"; then
            if [ "$CHOICE" -eq 0 ]; then
                AUD_DEV=""
                print_success "选中：无音频"
                break
            elif [ "$CHOICE" -ge 1 ] && [ "$CHOICE" -le ${#AUDIO_DEV[@]} ]; then
                AUD_DEV="${AUDIO_DEV[$((CHOICE-1))]}"
                print_success "选中：$AUD_DEV"
                break
            else
                print_error "输入无效！范围 0-${#AUDIO_DEV[@]}"
            fi
        else
            print_error "输入无效！请输入数字"
        fi
    done
}

# ===================== macOS 设备扫描 =====================
scan_devices_macos() {
    print_info "macOS系统：扫描音视频设备..."
    TMP=$(mktemp)
    ffmpeg -f avfoundation -list_devices true -i "" 2>&1 | grep -v '#' > "$TMP" || true

    # 解析设备
    VID_DEV_LIST=()
    AUD_DEV_LIST=()
    IN_VID=0
    while read -r line; do
        [ "$line" = "" ] && continue
        echo "$line" | grep -q 'Video Devices:' && IN_VID=1 && continue
        echo "$line" | grep -q 'Audio Devices:' && IN_VID=0 && continue
        if echo "$line" | grep -Eq '^\s*\[[0-9]+\]'; then
            ID=$(echo "$line" | sed -e 's/^\s*\[<span data-type="inline-math" data-value="Lio="></span>\].*/\1/')
            [ $IN_VID -eq 1 ] && VID_DEV_LIST+=("$ID") || AUD_DEV_LIST+=("$ID")
        fi
    done < "$TMP"
    rm -f "$TMP"

    # 选择视频设备
    [ ${#VID_DEV_LIST[@]} -eq 0 ] && { print_error "无视频设备！"; exit 1; }
    echo -e "\n========== 可用视频设备 =========="
    idx=1
    for id in "${VID_DEV_LIST[@]}"; do echo "$idx. [$id] 摄像头"; idx=$((idx+1)); done
    while true; do
        read -p "选择视频设备（序号）：" CHOICE
        if is_number "$CHOICE" && [ "$CHOICE" -ge 1 ] && [ "$CHOICE" -le ${#VID_DEV_LIST[@]} ]; then
            VID_DEV="${VID_DEV_LIST[$((CHOICE-1))]}"
            print_success "选中视频设备：$VID_DEV"
            break
        else
            print_error "输入无效！范围 1-${#VID_DEV_LIST[@]}"
        fi
    done

    # 选择音频设备
    echo -e "\n========== 可用音频设备 =========="
    echo "0. 无音频"
    idx=1
    for id in "${AUD_DEV_LIST[@]}"; do echo "$idx. [$id] 麦克风"; idx=$((idx+1)); done
    while true; do
        read -p "选择音频设备（序号，0=无）：" CHOICE
        if is_number "$CHOICE"; then
            [ "$CHOICE" -eq 0 ] && { AUD_DEV=""; print_success "选中：无音频"; break; }
            if [ "$CHOICE" -ge 1 ] && [ "$CHOICE" -le ${#AUD_DEV_LIST[@]} ]; then
                AUD_DEV="${AUD_DEV_LIST[$((CHOICE-1))]}"
                print_success "选中音频设备：$AUD_DEV"
                break
            else
                print_error "输入无效！范围 0-${#AUD_DEV_LIST[@]}"
            fi
        else
            print_error "输入无效！请输入数字"
        fi
    done

    # macOS 默认参数
    VID_FMT="mjpeg"
    VID_RES="1280x720"
    VID_FPS="30"
}

# ===================== 主配置（核心修复：路径加引号）=====================
main_config() {
    print_info "\n========== 配置推流参数 =========="
    # 默认值
    PRESET="medium"
    VID_BITRATE="2000k"
    AUD_BITRATE="192k"
    RTSP_URL="rtsp://localhost:8554/live"
    SAVE_LOCAL="yes"
    [ "$OS_TYPE" = "Darwin" ] && SAVE_PATH="$HOME/Movies/stream/" || SAVE_PATH="/mnt/sd/"
    SAVE_FILE="camera_$(date +%Y%m%d_%H%M%S).mp4"

    # 读取配置
    read -p "视频编码预设（默认：$PRESET）：" INPUT
    [ -n "$INPUT" ] && PRESET="$INPUT"
    read -p "视频码率（默认：$VID_BITRATE）：" INPUT
    [ -n "$INPUT" ] && VID_BITRATE="$INPUT"
    [ -n "$AUD_DEV" ] && {
        read -p "音频码率（默认：$AUD_BITRATE）：" INPUT
        [ -n "$INPUT" ] && AUD_BITRATE="$INPUT"
    }
    read -p "RTSP推流地址（默认：$RTSP_URL）：" INPUT
    [ -n "$INPUT" ] && RTSP_URL="$INPUT"
    read -p "保存本地视频（默认：$SAVE_LOCAL，yes/no）：" INPUT
    [ -n "$INPUT" ] && SAVE_LOCAL=$(echo "$INPUT" | tr '[:upper:]' '[:lower:]')

    # 本地保存配置（核心修复：路径加引号）
    if [ "$SAVE_LOCAL" = "yes" ] || [ "$SAVE_LOCAL" = "y" ]; then
        SAVE_LOCAL="yes"
        read -p "保存路径（默认：$SAVE_PATH）：" INPUT
        [ -n "$INPUT" ] && SAVE_PATH="$INPUT"
        # 确保路径以/结尾
        [ "${SAVE_PATH: -1}" != "/" ] && SAVE_PATH="$SAVE_PATH/"
        # 检查目录+写入权限
        check_dir "$SAVE_PATH"
        # 读取文件名
        read -p "保存文件名（默认：$SAVE_FILE）：" INPUT
        [ -n "$INPUT" ] && SAVE_FILE="$INPUT"
        # 拼接完整路径并加引号（处理空格）
        FULL_SAVE="$SAVE_PATH$SAVE_FILE"
        print_info "本地保存路径：$FULL_SAVE"
    else
        SAVE_LOCAL="no"
        print_info "关闭本地保存"
    fi

    # 确认配置
    echo -e "\n========== 最终配置 =========="
    echo "系统：$OS_TYPE"
    echo "视频设备：$VID_DEV | 分辨率/帧率：$VID_RES/$VID_FPS fps"
    echo "音频设备：${AUD_DEV:-无}"
    echo "视频码率/预设：$VID_BITRATE/$PRESET"
    [ -n "$AUD_DEV" ] && echo "音频码率：$AUD_BITRATE"
    echo "RTSP地址：$RTSP_URL"
    echo "本地保存：$SAVE_LOCAL ${FULL_SAVE:-}"
    echo -n "确认开始推流？（回车=确认，n=取消）："
    read -r INPUT
    if [ "$INPUT" = "n" ] || [ "$INPUT" = "N" ]; then
        print_info "取消推流"
        exit 0
    fi
    print_info "开始构建FFmpeg命令..."
}

# ===================== 执行推流（核心修复：强制执行+调试）=====================
run_stream() {
    print_info "\n========== 开始执行FFmpeg =========="
    # 构建命令（所有路径加引号，处理空格/特殊字符）
    CMD="ffmpeg -re -hide_banner "
    # 输入格式
    if [ "$OS_TYPE" = "Linux" ]; then
        CMD+="-f v4l2 -input_format $VID_FMT -video_size $VID_RES -framerate $VID_FPS -i \"$VID_DEV\" "
        [ -n "$AUD_DEV" ] && CMD+="-f alsa -i \"$AUD_DEV\" "
    else
        CMD+="-f avfoundation -video_size $VID_RES -framerate $VID_FPS "
        [ -n "$AUD_DEV" ] && CMD+="-i \"$VID_DEV:$AUD_DEV\" " || CMD+="-i \"$VID_DEV\" "
    fi
    # 编码参数
    CMD+="-c:v libx264 -preset $PRESET -b:v $VID_BITRATE "
    CMD+="-flags +global_header -pix_fmt yuv420p -fflags +flush_packets -max_delay 500000 "
    # 音频编码
    [ -n "$AUD_DEV" ] && CMD+="-c:a aac -b:a $AUD_BITRATE -ac 2 " || CMD+="-an "
    # 输出配置
    if [ "$SAVE_LOCAL" = "yes" ]; then
        CMD+="-f rtsp -rtsp_transport tcp \"$RTSP_URL\" "
        CMD+="-f mp4 -movflags +faststart \"$FULL_SAVE\" "
    else
        CMD+="-f rtsp -rtsp_transport tcp \"$RTSP_URL\" "
    fi

    # 打印调试命令（关键：让你看到最终执行的命令）
    print_debug "构建的FFmpeg命令："
    echo "$CMD"
    echo -e "\n${YELLOW}注意：按 Ctrl+C 可终止推流${NC}"

    # 强制执行命令并捕获错误
    print_info "正在启动FFmpeg..."
    if ! eval "$CMD"; then
        print_error "FFmpeg执行失败！"
        print_debug "失败原因可能："
        print_debug "1. RTSP服务器未运行（如：rtsp-simple-server）"
        print_debug "2. 设备被占用（Linux：lsof $VID_DEV）"
        print_debug "3. 保存路径无权限（已提前检查，可忽略）"
        exit 1
    fi

    # 执行成功
    print_success "FFmpeg推流正常终止！"
    [ "$SAVE_LOCAL" = "yes" ] && print_success "本地文件已保存：$FULL_SAVE"
}

# ===================== 入口（强制执行流程）=====================
check_command "ffmpeg"
[ "$OS_TYPE" = "Linux" ] && check_command "aplay"

# 系统分支
if [ "$OS_TYPE" = "Linux" ]; then
    scan_video_linux
    scan_video_caps_linux
    scan_audio_linux
elif [ "$OS_TYPE" = "Darwin" ]; then
    scan_devices_macos
else
    print_error "不支持的系统：$OS_TYPE"
    exit 1
fi

# 强制执行主配置和推流
main_config
run_stream
