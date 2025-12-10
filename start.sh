#!/bin/bash
set -eo pipefail

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# 工具函数
print_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
print_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }

check_command() {
    if ! command -v "$1" &> /dev/null; then
        print_error "未安装 $1，请先安装！"
        case "$1" in
            ffmpeg) print_info "下载地址：https://johnvansickle.com/ffmpeg/"; ;;
            aplay) print_info "Ubuntu/Debian: sudo apt install alsa-utils"; ;;
        esac
        exit 1
    fi
}

check_and_create_dir() {
    if [ ! -d "$1" ]; then
        print_info "创建目录：$1"
        mkdir -p "$1" || { print_error "创建目录失败！"; exit 1; }
    fi
}

# 扫描视频设备
scan_video_devices() {
    print_info "扫描视频设备..."
    VIDEO_DEVICES=()
    for dev in /dev/video*; do
        [[ ! $dev =~ ctl$ ]] && [ -c "$dev" ] && VIDEO_DEVICES+=("$dev")
    done
    [ ${#VIDEO_DEVICES[@]} -eq 0 ] && { print_error "无视频设备！"; exit 1; }

    echo -e "\n========== 可用视频设备 =========="
    for i in "${!VIDEO_DEVICES[@]}"; do echo "$((i+1)). ${VIDEO_DEVICES[$i]}"; done
    while true; do
        read -p "选择视频设备（序号）：" VIDEO_CHOICE
        if [[ "$VIDEO_CHOICE" =~ ^[0-9]+$ && $VIDEO_CHOICE -ge 1 && $VIDEO_CHOICE -le ${#VIDEO_DEVICES[@]} ]]; then
            SELECTED_VIDEO_DEV="${VIDEO_DEVICES[$((VIDEO_CHOICE-1))]}"
            print_success "选中：$SELECTED_VIDEO_DEV"
            break
        else
            print_error "输入无效！范围：1-${#VIDEO_DEVICES[@]}"
        fi
    done
}

# 扫描视频能力
scan_video_capabilities() {
    print_info "扫描 $SELECTED_VIDEO_DEV 能力..."
    TMP_CAP=$(mktemp)
    ffmpeg -f v4l2 -list_formats all -i "$SELECTED_VIDEO_DEV" 2> "$TMP_CAP" || true

    VIDEO_CAPS=()
    CURRENT_FORMAT=""
    FORMAT_REGEX='^\[([a-zA-Z0-9_]+)\][[:space:]]+: (.+)$'
    RES_FPS_REGEX='^[[:space:]]+([0-9]+x[0-9]+)[[:space:]]+: ([0-9]+) fps$'

    while IFS= read -r line; do
        [[ "$line" =~ $FORMAT_REGEX ]] && CURRENT_FORMAT="${BASH_REMATCH[1]}"
        if [[ "$line" =~ $RES_FPS_REGEX && -n "$CURRENT_FORMAT" ]]; then
            VIDEO_CAPS+=("$CURRENT_FORMAT|${BASH_REMATCH[1]}|${BASH_REMATCH[2]}")
        fi
    done < "$TMP_CAP"
    rm -f "$TMP_CAP"

    if [ ${#VIDEO_CAPS[@]} -eq 0 ]; then
        print_warn "解析失败，使用默认配置：1920x1080/30fps/mjpeg"
        SELECTED_RES="1920x1080"
        SELECTED_FPS="30"
        SELECTED_FORMAT="mjpeg"
        return
    fi

    echo -e "\n========== 支持的配置 =========="
    declare -A CAP_SEEN
    CLEAN_CAPS=()
    for cap in "${VIDEO_CAPS[@]}"; do
        [ -z "${CAP_SEEN[$cap]}" ] && CAP_SEEN["$cap"]=1 && CLEAN_CAPS+=("$cap")
    done
    for i in "${!CLEAN_CAPS[@]}"; do
        IFS='|' read -r fmt res fps <<< "${CLEAN_CAPS[$i]}"
        echo "$((i+1)). 格式：$fmt | 分辨率：$res | 帧率：$fps fps"
    done

    while true; do
        read -p "选择视频配置（序号）：" CAP_CHOICE
        if [[ "$CAP_CHOICE" =~ ^[0-9]+$ && $CAP_CHOICE -ge 1 && $CAP_CHOICE -le ${#CLEAN_CAPS[@]} ]]; then
            IFS='|' read -r SELECTED_FORMAT SELECTED_RES SELECTED_FPS <<< "${CLEAN_CAPS[$((CAP_CHOICE-1))]}"
            print_success "选中：格式=$SELECTED_FORMAT，分辨率=$SELECTED_RES，帧率=$SELECTED_FPS fps"
            break
        else
            print_error "输入无效！范围：1-${#CLEAN_CAPS[@]}"
        fi
    done
}

# 扫描音频设备
scan_audio_devices() {
    print_info "扫描音频设备..."
    TMP_AUDIO=$(mktemp)
    aplay -l 2> "$TMP_AUDIO" > "$TMP_AUDIO"

    AUDIO_DEVICES=()
    AUDIO_REGEX='card[[:space:]]+([0-9]+):[[:space:]]+([^,]+),[[:space:]]+device[[:space:]]+([0-9]+):[[:space:]]+(.+)$'
    while IFS= read -r line; do
        if [[ "$line" =~ $AUDIO_REGEX ]]; then
            AUDIO_DEVICES+=("hw:${BASH_REMATCH[1]},${BASH_REMATCH[3]}|${BASH_REMATCH[2]} - ${BASH_REMATCH[4]}")
        fi
    done < "$TMP_AUDIO"
    rm -f "$TMP_AUDIO"

    echo -e "\n========== 可用音频设备 =========="
    echo "0. 无音频"
    for i in "${!AUDIO_DEVICES[@]}"; do
        IFS='|' read -r dev name <<< "${AUDIO_DEVICES[$i]}"
        echo "$((i+1)). $dev | $name"
    done

    while true; do
        read -p "选择音频设备（序号，0=无）：" AUDIO_CHOICE
        if [[ "$AUDIO_CHOICE" =~ ^[0-9]+$ ]]; then
            if [ "$AUDIO_CHOICE" -eq 0 ]; then
                SELECTED_AUDIO_DEV=""
                print_success "选中：无音频"
                break
            elif [ "$AUDIO_CHOICE" -ge 1 ] && [ "$AUDIO_CHOICE" -le ${#AUDIO_DEVICES[@]} ]; then
                IFS='|' read -r SELECTED_AUDIO_DEV _ <<< "${AUDIO_DEVICES[$((AUDIO_CHOICE-1))]}"
                print_success "选中：$SELECTED_AUDIO_DEV"
                break
            else
                print_error "输入无效！范围：0-${#AUDIO_DEVICES[@]}"
            fi
        else
            print_error "输入无效！请输入数字"
        fi
    done
}

# 主流程
check_command "ffmpeg"
check_command "aplay"

scan_video_devices
scan_video_capabilities
scan_audio_devices

# 配置参数
print_info "\n========== 配置推流参数 =========="
DEFAULT_VIDEO_PRESET="medium"
DEFAULT_VIDEO_BITRATE="5000k"
DEFAULT_AUDIO_BITRATE="192k"
DEFAULT_RTSP_URL="rtsp://localhost:8554/live"
DEFAULT_SAVE_LOCAL="yes"
DEFAULT_SAVE_PATH="/mnt/sd/"
DEFAULT_SAVE_FILENAME="camera_$(date +%Y%m%d_%H%M%S).mp4"

read -p "视频编码预设（默认：$DEFAULT_VIDEO_PRESET）：" VIDEO_PRESET
VIDEO_PRESET=${VIDEO_PRESET:-$DEFAULT_VIDEO_PRESET}

read -p "视频码率（默认：$DEFAULT_VIDEO_BITRATE）：" VIDEO_BITRATE
VIDEO_BITRATE=${VIDEO_BITRATE:-$DEFAULT_VIDEO_BITRATE}

[ -n "$SELECTED_AUDIO_DEV" ] && {
    read -p "音频码率（默认：$DEFAULT_AUDIO_BITRATE）：" AUDIO_BITRATE
    AUDIO_BITRATE=${AUDIO_BITRATE:-$DEFAULT_AUDIO_BITRATE}
}

read -p "RTSP推流地址（默认：$DEFAULT_RTSP_URL）：" RTSP_URL
RTSP_URL=${RTSP_URL:-$DEFAULT_RTSP_URL}

read -p "保存本地视频（默认：$DEFAULT_SAVE_LOCAL，yes/no）：" SAVE_LOCAL
SAVE_LOCAL=$(echo "${SAVE_LOCAL:-$DEFAULT_SAVE_LOCAL}" | tr '[:upper:]' '[:lower:]')

if [[ "$SAVE_LOCAL" == "yes" || "$SAVE_LOCAL" == "y" ]]; then
    SAVE_LOCAL="yes"
    read -p "保存路径（默认：$DEFAULT_SAVE_PATH）：" SAVE_PATH
    SAVE_PATH=${SAVE_PATH:-$DEFAULT_SAVE_PATH}
    [[ "${SAVE_PATH: -1}" != "/" ]] && SAVE_PATH="$SAVE_PATH/"
    check_and_create_dir "$SAVE_PATH"

    read -p "保存文件名（默认：$DEFAULT_SAVE_FILENAME）：" SAVE_FILENAME
    SAVE_FILENAME=${SAVE_FILENAME:-$DEFAULT_SAVE_FILENAME}
    FULL_SAVE_PATH="$SAVE_PATH$SAVE_FILENAME"
    print_info "本地保存路径：$FULL_SAVE_PATH"
else
    SAVE_LOCAL="no"
    print_info "关闭本地保存"
fi

# 确认配置
echo -e "\n========== 最终配置 =========="
echo "视频设备：$SELECTED_VIDEO_DEV"
echo "分辨率/帧率：$SELECTED_RES/$SELECTED_FPS fps"
echo "音频设备：${SELECTED_AUDIO_DEV:-无}"
echo "视频码率/预设：$VIDEO_BITRATE/$VIDEO_PRESET"
[ -n "$SELECTED_AUDIO_DEV" ] && echo "音频码率：$AUDIO_BITRATE"
echo "RTSP地址：$RTSP_URL"
echo "本地保存：$SAVE_LOCAL（${FULL_SAVE_PATH:-无}）"
echo "=================================="

read -p "确认开始推流？（回车=确认，n=取消）：" CONFIRM
[[ "$CONFIRM" =~ ^[Nn]$ ]] && { print_info "取消推流"; exit 0; }

# 构建FFmpeg命令（核心修复：多路输出，放弃tee）
print_info "\n开始推流...（Ctrl+C终止）"
FFMPEG_CMD=(
    ffmpeg -re -hide_banner
    # 输入参数
    -f v4l2 -video_size "$SELECTED_RES" -framerate "$SELECTED_FPS"
    -input_format "$SELECTED_FORMAT" -i "$SELECTED_VIDEO_DEV"
)

# 音频输入
[ -n "$SELECTED_AUDIO_DEV" ] && FFMPEG_CMD+=(
    -f alsa -i "$SELECTED_AUDIO_DEV"
)

# 编码参数（统一配置）
FFMPEG_CMD+=(
    -c:v libx264 -preset "$VIDEO_PRESET" -b:v "$VIDEO_BITRATE"
    -flags +global_header -pix_fmt yuv420p
    -fflags +flush_packets -max_delay 500000
)

# 音频编码
[ -n "$SELECTED_AUDIO_DEV" ] && FFMPEG_CMD+=(
    -c:a aac -b:a "$AUDIO_BITRATE" -ac 2
) || FFMPEG_CMD+=(-an)

# 多路输出：先RTSP，再本地文件（核心修复）
if [[ "$SAVE_LOCAL" == "yes" ]]; then
    FFMPEG_CMD+=(
        # 输出1：RTSP
        -f rtsp -rtsp_transport tcp "$RTSP_URL"
        # 输出2：本地MP4
        -f mp4 -movflags +faststart "$FULL_SAVE_PATH"
    )
else
    FFMPEG_CMD+=(
        # 仅输出RTSP
        -f rtsp -rtsp_transport tcp "$RTSP_URL"
    )
fi

# 执行命令（直接执行数组，避免eval转义错误）
"${FFMPEG_CMD[@]}"

# 结果检查
if [ $? -eq 0 ]; then
    print_success "推流正常终止！"
    [[ "$SAVE_LOCAL" == "yes" ]] && print_success "本地文件：$FULL_SAVE_PATH"
else
    print_error "推流失败！排查方向："
    print_info "1. 检查RTSP服务器：ps aux | grep rtsp-simple-server"
    print_info "2. 检查设备权限：sudo chmod 666 $SELECTED_VIDEO_DEV"
    print_info "3. 检查存储权限：touch $SAVE_PATH/test.txt"
    print_info "4. 测试基础推流：ffmpeg -f v4l2 -i $SELECTED_VIDEO_DEV -c:v libx264 -f rtsp $RTSP_URL"
    exit 1
fi