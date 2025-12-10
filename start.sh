#!/bin/bash
set -eo pipefail

# ===================== 全局配置 & 常量 =====================
OS_TYPE=$(uname -s)
# 颜色输出（兼容无终端环境）
if [ -t 1 ]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    NC='\033[0m'
else
    RED=''
    GREEN=''
    YELLOW=''
    BLUE=''
    NC=''
fi

# 默认参数
DEFAULT_PRESET="medium"
DEFAULT_VID_BITRATE="5000k"
DEFAULT_AUD_BITRATE="192k"
DEFAULT_RTSP_URL="rtsp://localhost:8554/live"
DEFAULT_SAVE_LOCAL="yes"
[ "$OS_TYPE" = "Darwin" ] && DEFAULT_SAVE_PATH="$HOME/Movies/stream/" || DEFAULT_SAVE_PATH="/mnt/sd/"

# ===================== 核心工具函数 =====================
# 打印日志（带颜色+时间）
log_info() { echo -e "[$(date +%H:%M:%S)] ${BLUE}[INFO]${NC} $1"; }
log_warn() { echo -e "[$(date +%H:%M:%S)] ${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "[$(date +%H:%M:%S)] ${RED}[ERROR]${NC} $1"; }
log_success() { echo -e "[$(date +%H:%M:%S)] ${GREEN}[SUCCESS]${NC} $1"; }
log_debug() { echo -e "[$(date +%H:%M:%S)] ${YELLOW}[DEBUG]${NC} $1"; }

# 检查命令是否存在
check_command() {
    local cmd="$1"
    local desc="$2"
    if ! command -v "$cmd" >/dev/null 2>&1; then
        log_error "缺少必要依赖：$cmd（$desc）"
        case "$cmd" in
            ffmpeg)
                if [ "$OS_TYPE" = "Darwin" ]; then
                    log_info "安装命令：brew install ffmpeg"
                else
                    log_info "安装命令：sudo apt install ffmpeg -y"
                fi
                ;;
            aplay) log_info "安装命令：sudo apt install alsa-utils -y" ;;
            rtsp-simple-server)
                if [ "$OS_TYPE" = "Darwin" ]; then
                    log_info "安装命令：brew install rtsp-simple-server"
                else
                    log_info "安装教程：https://github.com/aler9/rtsp-simple-server"
                fi
                ;;
        esac
        exit 1
    fi
}

# 检查目录可写性
check_dir_writable() {
    local dir="$1"
    # 创建目录
    if [ ! -d "$dir" ]; then
        log_info "创建目录：$dir"
        mkdir -p "$dir" || { log_error "创建目录失败！"; exit 1; }
    fi
    # 测试写入
    local test_file="$dir/.test_write_$(date +%s)"
    if ! touch "$test_file" >/dev/null 2>&1; then
        log_error "目录 $dir 无写入权限！"
        log_info "建议执行：sudo chmod 777 $dir"
        exit 1
    fi
    rm -f "$test_file"
    log_success "目录 $dir 可正常写入"
}

# 自动启动RTSP服务器
start_rtsp_server() {
    log_info "检查RTSP服务器状态..."
    if ! pgrep -x "rtsp-simple-server" >/dev/null 2>&1; then
        log_warn "RTSP服务器未运行，正在后台启动..."
        # 启动并记录日志
        if [ "$OS_TYPE" = "Darwin" ]; then
            nohup rtsp-simple-server >/tmp/rtsp_server.log 2>&1 &
        else
            nohup ./rtsp-simple-server >/tmp/rtsp_server.log 2>&1 &
        fi
        # 等待启动
        sleep 2
        # 验证启动
        if ! pgrep -x "rtsp-simple-server" >/dev/null 2>&1; then
            log_error "RTSP服务器启动失败！"
            log_info "手动启动命令：rtsp-simple-server"
            log_info "日志文件：/tmp/rtsp_server.log"
            exit 1
        fi
        log_success "RTSP服务器已启动（日志：/tmp/rtsp_server.log）"
    else
        log_success "RTSP服务器已在运行"
    fi
}

# 数字合法性校验
is_number() {
    echo "$1" | grep -Eq '^[0-9]+$'
}

# ===================== Linux 设备扫描模块 =====================
scan_linux_video_dev() {
    log_info "=== Linux 视频设备扫描 ==="
    local video_devices=()
    # 扫描视频设备（排除ctl设备）
    for dev in /dev/video*; do
        if [ -c "$dev" ] && echo "$dev" | grep -qv 'ctl$'; then
            video_devices+=("$dev")
        fi
    done
    # 无设备处理
    if [ ${#video_devices[@]} -eq 0 ]; then
        log_error "未检测到任何视频设备！"
        log_info "排查：1. 检查摄像头连接 2. ls /dev/video* 确认设备存在"
        exit 1
    fi
    # 列出设备
    log_info "可用视频设备："
    local idx=1
    for dev in "${video_devices[@]}"; do
        echo "  $idx. $dev"
        idx=$((idx+1))
    done
    # 选择设备
    while true; do
        read -p "请选择视频设备序号（1-${#video_devices[@]}）：" choice
        if is_number "$choice" && [ "$choice" -ge 1 ] && [ "$choice" -le ${#video_devices[@]} ]; then
            VID_DEV="${video_devices[$((choice-1))]}"
            log_success "选中视频设备：$VID_DEV"
            break
        else
            log_error "输入无效！请输入 1-${#video_devices[@]} 之间的数字"
        fi
    done
}

scan_linux_video_caps() {
    log_info "=== 扫描视频设备能力 ==="
    local tmp=$(mktemp)
    # 执行ffmpeg并过滤特殊字符
    ffmpeg -f v4l2 -list_formats all -i "$VID_DEV" 2>&1 | grep -v '#' > "$tmp" || true
    # 解析格式/分辨率/帧率
    local video_caps=()
    local cur_fmt=""
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        # 解析格式行
        if echo "$line" | grep -Eq '^\[([a-zA-Z0-9_]+)\][[:space:]]+:'; then
            cur_fmt=$(echo "$line" | sed -e 's/^\[<span data-type="inline-math" data-value="Lio="></span>\].*/\1/' -e 's/[^a-zA-Z0-9_]//g')
            continue
        fi
        # 解析分辨率/帧率行
        if echo "$line" | grep -Eq '^[[:space:]]+[0-9]+x[0-9]+[[:space:]]+:[[:space:]]+[0-9]+ fps'; then
            local res=$(echo "$line" | awk '{print $1}' | sed -e 's/[^0-9x]//g')
            local fps=$(echo "$line" | awk '{print $3}' | sed -e 's/[^0-9]//g')
            if [ -n "$cur_fmt" ] && [ -n "$res" ] && [ -n "$fps" ]; then
                video_caps+=("$cur_fmt|$res|$fps")
            fi
        fi
    done < "$tmp"
    rm -f "$tmp"
    # 解析失败用默认值
    if [ ${#video_caps[@]} -eq 0 ]; then
        log_warn "解析设备能力失败，使用默认配置：mjpeg/1920x1080/30fps"
        VID_FMT="mjpeg"
        VID_RES="1920x1080"
        VID_FPS="30"
        return
    fi
    # 去重
    local clean_caps=()
    for cap in "${video_caps[@]}"; do
        if ! echo "${clean_caps[@]}" | grep -q "$cap"; then
            clean_caps+=("$cap")
        fi
    done
    # 列出可选配置
    log_info "可用视频配置："
    local idx=1
    for cap in "${clean_caps[@]}"; do
        local fmt=$(echo "$cap" | cut -d'|' -f1)
        local res=$(echo "$cap" | cut -d'|' -f2)
        local fps=$(echo "$cap" | cut -d'|' -f3)
        echo "  $idx. 格式：$fmt | 分辨率：$res | 帧率：$fps fps"
        idx=$((idx+1))
    done
    # 选择配置
    while true; do
        read -p "请选择视频配置序号（1-${#clean_caps[@]}）：" choice
        if is_number "$choice" && [ "$choice" -ge 1 ] && [ "$choice" -le ${#clean_caps[@]} ]; then
            local cap="${clean_caps[$((choice-1))]}"
            VID_FMT=$(echo "$cap" | cut -d'|' -f1)
            VID_RES=$(echo "$cap" | cut -d'|' -f2)
            VID_FPS=$(echo "$cap" | cut -d'|' -f3)
            log_success "选中配置：格式=$VID_FMT，分辨率=$VID_RES，帧率=$VID_FPS fps"
            break
        else
            log_error "输入无效！请输入 1-${#clean_caps[@]} 之间的数字"
        fi
    done
}

scan_linux_audio_dev() {
    log_info "=== Linux 音频设备扫描 ==="
    local tmp=$(mktemp)
    aplay -l 2>&1 > "$tmp" || true
    # 解析音频设备
    local audio_devices=()
    while read -r line; do
        local card=$(echo "$line" | awk -F 'card |:' '{print $2}' | awk '{print $1}')
        local dev=$(echo "$line" | awk -F 'device |:' '{print $2}' | awk '{print $1}')
        if [ -n "$card" ] && [ -n "$dev" ]; then
            audio_devices+=("hw:$card,$dev")
        fi
    done < <(grep 'card .* device' "$tmp")
    rm -f "$tmp"
    # 列出设备
    log_info "可用音频设备："
    echo "  0. 无音频"
    local idx=1
    for dev in "${audio_devices[@]}"; do
        echo "  $idx. $dev"
        idx=$((idx+1))
    done
    # 选择设备
    while true; do
        read -p "请选择音频设备序号（0-${#audio_devices[@]}）：" choice
        if is_number "$choice"; then
            if [ "$choice" -eq 0 ]; then
                AUD_DEV=""
                log_success "选中：无音频"
                break
            elif [ "$choice" -ge 1 ] && [ "$choice" -le ${#audio_devices[@]} ]; then
                AUD_DEV="${audio_devices[$((choice-1))]}"
                log_success "选中音频设备：$AUD_DEV"
                break
            else
                log_error "输入无效！请输入 0-${#audio_devices[@]} 之间的数字"
            fi
        else
            log_error "输入无效！请输入数字"
        fi
    done
}

# ===================== macOS 设备扫描模块（核心修复）=====================
scan_macos_dev() {
    log_info "=== macOS 设备扫描（avfoundation）==="
    # 权限提示
    log_warn "⚠️  请确保终端已获得摄像头权限：系统设置 → 隐私与安全性 → 摄像头"
    read -p "已授权请按回车继续... "

    # 获取原始设备列表（修复：用dummy占位符避免空输入错误，过滤无关日志）
    local tmp=$(mktemp)
    # 关键修复：-i dummy 替代 -i ""，只保留设备列表相关输出
    ffmpeg -f avfoundation -list_devices true -i dummy 2>&1 | \
        grep -E 'AVFoundation (video|audio) devices:|\[AVFoundation indev @ .*\] \[[0-9]+\]' | \
        sed -e 's/^\[AVFoundation indev @ .*\] //' > "$tmp"
    
    log_debug "FFmpeg设备列表（过滤后）："
    cat "$tmp"
    echo ""

    # 解析视频/音频设备（兼容中文设备名）
    local vid_dev_list=()
    local vid_name_list=()
    local aud_dev_list=()
    local aud_name_list=()
    local in_vid=0

    while IFS= read -r line; do
        [ -z "$line" ] && continue
        # 切换解析模式
        if echo "$line" | grep -qi 'avfoundation video devices'; then
            in_vid=1
            continue
        elif echo "$line" | grep -qi 'avfoundation audio devices'; then
            in_vid=0
            continue
        fi
        # 解析设备行（兼容中文：\[0\] MacBook Pro相机）
        if echo "$line" | grep -Eq '^\[[0-9]+\] .+'; then
            # 提取索引（[0] → 0）
            local id=$(echo "$line" | sed -e 's/^\[<span data-type="inline-math" data-value="WzAtOV1cKw=="></span>\].*/\1/' -e 's/[^0-9]//g')
            # 提取名称（[0] MacBook Pro相机 → MacBook Pro相机）
            local name=$(echo "$line" | sed -e 's/^\[[0-9]\+\] //' -e 's/^[ \t]*//')
            if [ $in_vid -eq 1 ]; then
                vid_dev_list+=("$id")
                vid_name_list+=("$name")
            else
                aud_dev_list+=("$id")
                aud_name_list+=("$name")
            fi
        fi
    done < "$tmp"
    rm -f "$tmp"

    # 视频设备处理（已识别到设备：0=MacBook Pro相机，1=MacBook Pro桌上视角相机）
    if [ ${#vid_dev_list[@]} -eq 0 ]; then
        log_warn "未扫描到视频设备，启用手动输入模式"
        read -p "请输入视频设备索引（默认0）：" vid_idx
        [ -z "$vid_idx" ] && vid_idx=0
        if ! is_number "$vid_idx"; then
            log_error "设备索引必须是数字！"
            exit 1
        fi
        VID_DEV="$vid_idx"
        log_warn "手动指定视频设备索引：$VID_DEV"
    else
        # 列出视频设备（兼容中文）
        log_info "可用视频设备："
        local idx=1
        for i in "${!vid_dev_list[@]}"; do
            echo "  $idx. [${vid_dev_list[$i]}] ${vid_name_list[$i]}"
            idx=$((idx+1))
        done
        # 选择视频设备
        while true; do
            read -p "请选择视频设备序号（1-${#vid_dev_list[@]}）：" choice
            if is_number "$choice" && [ "$choice" -ge 1 ] && [ "$choice" -le ${#vid_dev_list[@]} ]; then
                VID_DEV="${vid_dev_list[$((choice-1))]}"
                log_success "选中视频设备：[$VID_DEV] ${vid_name_list[$((choice-1))]}"
                break
            else
                log_error "输入无效！请输入 1-${#vid_dev_list[@]} 之间的数字"
            fi
        done
    fi

    # 音频设备处理（已识别到：0=MacBook Pro麦克风，1=USB Audio Device）
    log_info "可用音频设备："
    echo "  0. 无音频"
    local idx=1
    for i in "${!aud_dev_list[@]}"; do
        echo "  $idx. [${aud_dev_list[$i]}] ${aud_name_list[$i]}"
        idx=$((idx+1))
    done
    # 选择音频设备
    while true; do
        read -p "请选择音频设备序号（0-${#aud_dev_list[@]}）：" choice
        if is_number "$choice"; then
            if [ "$choice" -eq 0 ]; then
                AUD_DEV=""
                log_success "选中：无音频"
                break
            elif [ "$choice" -ge 1 ] && [ "$choice" -le ${#aud_dev_list[@]} ]; then
                AUD_DEV="${aud_dev_list[$((choice-1))]}"
                log_success "选中音频设备：[$AUD_DEV] ${aud_name_list[$((choice-1))]}"
                break
            else
                log_error "输入无效！请输入 0-${#aud_dev_list[@]} 之间的数字"
            fi
        else
            log_error "输入无效！请输入数字"
        fi
    done

    # macOS默认视频参数
    VID_FMT="mjpeg"
    VID_RES="1920x1080"
    VID_FPS="30"
}

# ===================== 通用配置模块 =====================
common_config() {
    log_info "=== 推流参数配置 ==="
    # 视频编码预设
    read -p "视频编码预设（默认：$DEFAULT_PRESET）：" preset
    PRESET=${preset:-$DEFAULT_PRESET}
    # 视频码率
    read -p "视频码率（默认：$DEFAULT_VID_BITRATE）：" vid_bitrate
    VID_BITRATE=${vid_bitrate:-$DEFAULT_VID_BITRATE}
    # 音频码率（仅选音频时）
    if [ -n "$AUD_DEV" ]; then
        read -p "音频码率（默认：$DEFAULT_AUD_BITRATE）：" aud_bitrate
        AUD_BITRATE=${aud_bitrate:-$DEFAULT_AUD_BITRATE}
    fi
    # RTSP地址
    read -p "RTSP推流地址（默认：$DEFAULT_RTSP_URL）：" rtsp_url
    RTSP_URL=${rtsp_url:-$DEFAULT_RTSP_URL}
    # 本地保存配置
    read -p "是否保存本地视频（默认：$DEFAULT_SAVE_LOCAL，yes/no）：" save_local
    SAVE_LOCAL=$(echo "${save_local:-$DEFAULT_SAVE_LOCAL}" | tr '[:upper:]' '[:lower:]')
    if [ "$SAVE_LOCAL" = "yes" ] || [ "$SAVE_LOCAL" = "y" ]; then
        SAVE_LOCAL="yes"
        # 保存路径
        read -p "保存路径（默认：$DEFAULT_SAVE_PATH）：" save_path
        SAVE_PATH=${save_path:-$DEFAULT_SAVE_PATH}
        # 确保路径以/结尾
        [ "${SAVE_PATH: -1}" != "/" ] && SAVE_PATH="$SAVE_PATH/"
        # 检查路径可写
        check_dir_writable "$SAVE_PATH"
        # 保存文件名
        local default_filename="camera_$(date +%Y%m%d_%H%M%S).mp4"
        read -p "保存文件名（默认：$default_filename）：" save_file
        SAVE_FILE=${save_file:-$default_filename}
        FULL_SAVE_PATH="$SAVE_PATH$SAVE_FILE"
        log_success "本地保存路径：$FULL_SAVE_PATH"
    else
        SAVE_LOCAL="no"
        log_info "禁用本地视频保存"
    fi

    # 确认配置
    log_info "=== 最终配置确认 ==="
    echo "  系统类型：$OS_TYPE"
    echo "  视频设备：$VID_DEV"
    echo "  视频参数：$VID_RES @ $VID_FPS fps | 格式：$VID_FMT | 码率：$VID_BITRATE | 预设：$PRESET"
    echo "  音频设备：${AUD_DEV:-无}"
    [ -n "$AUD_DEV" ] && echo "  音频码率：$AUD_BITRATE"
    echo "  RTSP地址：$RTSP_URL"
    echo "  本地保存：$SAVE_LOCAL ${FULL_SAVE_PATH:-}"
    read -p "确认执行FFmpeg推流？（回车确认，n取消）：" confirm
    if [ "$confirm" = "n" ] || [ "$confirm" = "N" ]; then
        log_info "用户取消执行，退出脚本"
        exit 0
    fi
}

# ===================== FFmpeg执行模块 =====================
run_ffmpeg() {
    log_info "=== 构建FFmpeg命令 ==="
    # 基础命令
    local ffmpeg_cmd="ffmpeg -re -hide_banner "
    # 输入格式配置
    if [ "$OS_TYPE" = "Linux" ]; then
        ffmpeg_cmd+="-f v4l2 -input_format $VID_FMT -video_size $VID_RES -framerate $VID_FPS -i \"$VID_DEV\" "
        [ -n "$AUD_DEV" ] && ffmpeg_cmd+="-f alsa -i \"$AUD_DEV\" "
    else
        ffmpeg_cmd+="-f avfoundation -video_size $VID_RES -framerate $VID_FPS "
        [ -n "$AUD_DEV" ] && ffmpeg_cmd+="-i \"$VID_DEV:$AUD_DEV\" " || ffmpeg_cmd+="-i \"$VID_DEV\" "
    fi
    # 编码参数
    ffmpeg_cmd+="-c:v libx264 -preset $PRESET -b:v $VID_BITRATE "
    ffmpeg_cmd+="-flags +global_header -pix_fmt yuv420p -fflags +flush_packets -max_delay 500000 "
    # 音频编码
    [ -n "$AUD_DEV" ] && ffmpeg_cmd+="-c:a aac -b:a $AUD_BITRATE -ac 2 " || ffmpeg_cmd+="-an "
    # 输出配置
    ffmpeg_cmd+="-f rtsp -rtsp_transport tcp \"$RTSP_URL\" "
    # 本地保存
    if [ "$SAVE_LOCAL" = "yes" ]; then
        ffmpeg_cmd+="-f mp4 -movflags +faststart \"$FULL_SAVE_PATH\" "
    fi

    # 打印命令（调试）
    log_debug "最终FFmpeg命令："
    echo "$ffmpeg_cmd"
    echo -e "\n${RED}⚠️  按 Ctrl+C 可终止推流${NC}\n"

    # 强制执行
    log_info "=== 启动FFmpeg推流 ==="
    if ! eval "$ffmpeg_cmd"; then
        log_error "FFmpeg执行失败！错误码：$?"
        log_info "建议排查方向："
        log_info "  1. 手动执行上述FFmpeg命令，查看详细错误"
        log_info "  2. 检查RTSP服务器是否正常运行（pgrep rtsp-simple-server）"
        log_info "  3. 检查设备是否被占用（Linux：lsof $VID_DEV；macOS：Activity Monitor）"
        exit 1
    fi

    log_success "FFmpeg推流正常终止！"
    [ "$SAVE_LOCAL" = "yes" ] && log_success "本地视频已保存：$FULL_SAVE_PATH"
}

# ===================== 主流程入口 =====================
main() {
    log_success "=== 跨平台FFmpeg推流脚本启动 ==="
    # 1. 检查基础依赖
    check_command "ffmpeg" "音视频处理核心工具"
    #check_command "rtsp-simple-server" "RTSP推流服务器"
    [ "$OS_TYPE" = "Linux" ] && check_command "aplay" "音频设备检测工具"

    # 2. 启动RTSP服务器
    #start_rtsp_server

    # 3. 设备扫描（分系统）
    if [ "$OS_TYPE" = "Linux" ]; then
        scan_linux_video_dev
        scan_linux_video_caps
        scan_linux_audio_dev
    elif [ "$OS_TYPE" = "Darwin" ]; then
        scan_macos_dev
    else
        log_error "不支持的系统类型：$OS_TYPE（仅支持Linux/macOS）"
        exit 1
    fi

    # 4. 通用参数配置
    common_config

    # 5. 执行FFmpeg
    run_ffmpeg

    exit 0
}

# 启动主流程
main "$@"