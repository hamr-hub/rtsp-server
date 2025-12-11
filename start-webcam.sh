#!/bin/bash
set -euo pipefail  # 严格模式：错误立即退出，未定义变量报错，管道错误传递

# ===================== 参数解析 =====================
# 默认配置
MODE="rkmpp"  # 可选: rkmpp 或 copy
CAMERA_DEV="/dev/video10"          # 摄像头设备节点
VIDEO_SIZE="1280x720"              # 分辨率
FRAMERATE=30                       # 帧率
SEGMENT_TIME=3600                  # 分段时长（秒），1小时=3600秒

# 解析命令行参数
while [[ $# -gt 0 ]]; do
    case $1 in
        -m|--mode)
            MODE="$2"
            shift 2
            ;;
        -d|--device)
            CAMERA_DEV="$2"
            shift 2
            ;;
        -s|--size)
            VIDEO_SIZE="$2"
            shift 2
            ;;
        -f|--framerate)
            FRAMERATE="$2"
            shift 2
            ;;
        -t|--segment-time)
            SEGMENT_TIME="$2"
            shift 2
            ;;
        -h|--help)
            echo "使用方法: $0 [选项]"
            echo "选项:"
            echo "  -m, --mode MODE          编码模式: rkmpp (默认) 或 copy"
            echo "  -d, --device DEVICE      摄像头设备节点 (默认: /dev/video10)"
            echo "  -s, --size SIZE          视频分辨率 (默认: 1280x720)"
            echo "  -f, --framerate FPS      帧率 (默认: 30)"
            echo "  -t, --segment-time SEC   分段时长（秒）(默认: 3600)"
            echo "  -h, --help               显示此帮助信息"
            echo ""
            echo "示例:"
            echo "  $0                                    # 使用默认的 rkmpp 模式"
            echo "  $0 -m copy                           # 使用标准H264 + Copy编码"
            echo "  $0 --mode rkmpp --size 1920x1080    # 使用rkmpp模式，1080p分辨率"
            echo "  $0 -m copy -f 60                     # 使用copy模式，60fps"
            exit 0
            ;;
        *)
            echo "未知选项: $1"
            echo "使用 -h 或 --help 查看帮助信息"
            exit 1
            ;;
    esac
done

# 验证模式参数
if [[ "$MODE" != "rkmpp" && "$MODE" != "copy" ]]; then
    echo "错误: 编码模式必须是 'rkmpp' 或 'copy'"
    echo "使用 -h 或 --help 查看帮助信息"
    exit 1
fi

echo "[$(date +%Y-%m-%d\ %H:%M:%S)] 启动模式: $MODE" >> "/mnt/sd/log/info.log"
echo "[$(date +%Y-%m-%d\ %H:%M:%S)] 摄像头设备: $CAMERA_DEV" >> "/mnt/sd/log/info.log"
echo "[$(date +%Y-%m-%d\ %H:%M:%S)] 分辨率: $VIDEO_SIZE, 帧率: $FRAMERATE" >> "/mnt/sd/log/info.log"

# ===================== 核心配置（根据模式动态配置）=====================
# 摄像头基础参数
INPUT_FORMAT="mjpeg"                 # 默认输入格式
THREAD_QUEUE_SIZE=2048              # 线程队列大小
SKIP_FRAME="nokey"                  # 跳帧策略

# 根据模式设置编码器和相关参数
if [[ "$MODE" == "rkmpp" ]]; then
    ENCODER="h264_rkmpp"            # 使用硬件编码器
    BITRATE="2000k"                 # 视频码率
    GOP_SIZE=60                     # GOP大小
    MAX_DELAY=500000                # 最大延迟
    BUFSIZE="10M"                   # 编码缓冲区大小
    INPUT_FORMAT="mjpeg"            # 输入格式
    SKIP_FRAME="nokey"              # 跳帧策略
    COLOR_PARAMS="-color_range tv -colorspace bt709 -color_primaries bt709 -color_trc bt709"
    SWSCALE_FILTER="-sws_flags fast_bilinear"
    echo "[$(date +%Y-%m-%d\ %H:%M:%S)] 使用 h264_rkmpp 硬件编码模式" >> "/mnt/sd/log/info.log"
else
    # copy 模式：直接复制标准H264流
    ENCODER="copy"                  # 直接复制，不重新编码
    BITRATE=""                      # copy模式不需要码率
    GOP_SIZE=""                     # copy模式不需要GOP
    MAX_DELAY=500000                # 最大延迟
    BUFSIZE=""                      # copy模式不需要缓冲区大小
    INPUT_FORMAT="h264"             # 标准H264输入格式
    SKIP_FRAME=""                   # copy模式不需要跳帧
    COLOR_PARAMS=""                 # copy模式保持原始色彩
    SWSCALE_FILTER=""               # copy模式不需要缩放
    echo "[$(date +%Y-%m-%d\ %H:%M:%S)] 使用 标准H264 + Copy 编码模式" >> "/mnt/sd/log/info.log"
fi

# 输出配置
RTSP_URL="rtsp://localhost:8554/live"  # RTSP推流地址
SAVE_DIR="/mnt/sd"                     # 视频保存目录
FILE_NAME_TEMPLATE="camera_%Y%m%d_%H%M%S.mp4"  # 分段文件名模板

# 清理策略
CLEAN_DAYS=7                       # 保留7天内的录制文件
DISK_THRESHOLD=85                  # 磁盘使用率阈值（%），超过则强制清理
LOG_DIR="/mnt/sd/log/"          # 日志目录

# 输出配置
RTSP_URL="rtsp://localhost:8554/live"  # RTSP推流地址
SAVE_DIR="/mnt/sd"                     # 视频保存目录
FILE_NAME_TEMPLATE="camera_%Y%m%d_%H%M%S.mp4"  # 分段文件名模板

# 清理策略
CLEAN_DAYS=7                       # 保留7天内的录制文件
DISK_THRESHOLD=85                  # 磁盘使用率阈值（%），超过则强制清理
LOG_DIR="/mnt/sd/log/"          # 日志目录

# ===================== 工具函数：前置环境检查 =====================
check_environment() {
    # 1. 创建日志/保存目录
    mkdir -p "${LOG_DIR}" "${SAVE_DIR}"

    # 2. 检查FFmpeg是否安装
    if ! command -v ffmpeg &> /dev/null; then
        echo "[$(date +%Y-%m-%d\ %H:%M:%S)] 错误：未安装ffmpeg！" >> "${LOG_DIR}/error.log"
        echo "错误：未安装ffmpeg，请先安装后重试！"
        exit 1
    fi

    # 3. 检查编码器可用性，不存在则自动切换为h264_v4l2m2m
#    if ! ffmpeg -encoders 2>/dev/null | grep -q "${ENCODER}"; then
#        echo "[$(date +%Y-%m-%d\ %H:%M:%S)] 警告：编码器${ENCODER}不存在，自动切换为h264_v4l2m2m" >> "${LOG_DIR}/info.log"
#        echo "警告：编码器${ENCODER}不存在，自动切换为h264_v4l2m2m"
#        
#    fi

    # 4. 检查摄像头设备是否存在
    if [ ! -c "${CAMERA_DEV}" ]; then
        echo "[$(date +%Y-%m-%d\ %H:%M:%S)] 错误：摄像头设备${CAMERA_DEV}不存在！" >> "${LOG_DIR}/error.log"
        echo "错误：摄像头设备${CAMERA_DEV}不存在，请检查设备节点！"
        exit 1
    fi

    # 5. 检查磁盘空间（剩余<1GB则退出）
    FREE_SPACE=$(df -P "${SAVE_DIR}" | awk 'NR==2 {print $4}')
    if [ "${FREE_SPACE}" -lt 1048576 ]; then
        echo "[$(date +%Y-%m-%d\ %H:%M:%S)] 错误：${SAVE_DIR}剩余空间不足1GB！" >> "${LOG_DIR}/error.log"
        echo "错误：${SAVE_DIR}剩余空间不足1GB，请清理磁盘后重试！"
        exit 1
    fi

  
}

# ===================== 工具函数：自动清理旧文件 =====================
clean_old_files() {
    echo "[$(date +%Y-%m-%d\ %H:%M:%S)] 开始执行文件清理策略..." >> "${LOG_DIR}/clean.log"

    # 1. 计算磁盘使用率
    local mount_point=$(df -P "${SAVE_DIR}" | awk 'NR==2 {print $6}')
    local disk_usage=$(df -P "${mount_point}" | awk 'NR==2 {print $5}' | sed 's/%//g')

    # 2. 删除指定天数前的文件
    find "${SAVE_DIR}" -maxdepth 1 -name "camera_*.mp4" -type f -mtime +${CLEAN_DAYS} -delete
    echo "[$(date +%Y-%m-%d\ %H:%M:%S)] 已删除${CLEAN_DAYS}天前的录制文件" >> "${LOG_DIR}/clean.log"

    # 3. 磁盘使用率超过阈值则循环删除最旧文件
    if [ "${disk_usage}" -ge "${DISK_THRESHOLD}" ]; then
        echo "[$(date +%Y-%m-%d\ %H:%M:%S)] 磁盘使用率${disk_usage}%≥阈值${DISK_THRESHOLD}%，开始清理最旧文件" >> "${LOG_DIR}/clean.log"
        while [ "${disk_usage}" -ge "${DISK_THRESHOLD}" ]; do
            # 找到最旧的mp4文件（按修改时间排序）
            oldest_file=$(find "${SAVE_DIR}" -maxdepth 1 -name "camera_*.mp4" -type f -printf "%T@ %p\n" | sort -n | head -n1 | awk '{print $2}')
            if [ -z "${oldest_file}" ]; then
                echo "[$(date +%Y-%m-%d\ %H:%M:%S)] 无可清理的文件，磁盘使用率仍为${disk_usage}%" >> "${LOG_DIR}/clean.log"
                break
            fi
            # 删除最旧文件
            rm -f "${oldest_file}"
            echo "[$(date +%Y-%m-%d\ %H:%M:%S)] 删除最旧文件：${oldest_file}" >> "${LOG_DIR}/clean.log"
            # 重新计算磁盘使用率
            disk_usage=$(df -P "${mount_point}" | awk 'NR==2 {print $5}' | sed 's/%//g')
        done
        echo "[$(date +%Y-%m-%d\ %H:%M:%S)] 清理完成，当前磁盘使用率：${disk_usage}%" >> "${LOG_DIR}/clean.log"
    fi
}

# ===================== 工具函数：优雅退出 =====================
cleanup() {
    echo "[$(date +%Y-%m-%d\ %H:%M:%S)] 收到退出信号，正在停止FFmpeg进程..." >> "${LOG_DIR}/info.log"
    # 停止FFmpeg进程
    if [ -n "${FFMPEG_PID:-}" ] && ps -p "${FFMPEG_PID}" &> /dev/null; then
        kill "${FFMPEG_PID}"
        wait "${FFMPEG_PID}" 2>/dev/null
    fi
    # 停止后台清理进程（若存在）
    if [ -n "${CLEAN_PID:-}" ] && ps -p "${CLEAN_PID}" &> /dev/null; then
        kill "${CLEAN_PID}" 2>/dev/null
    fi
    echo "[$(date +%Y-%m-%d\ %H:%M:%S)] FFmpeg进程已停止，脚本正常退出" >> "${LOG_DIR}/info.log"
    echo "脚本已正常退出！"
    exit 0
}

# ===================== 工具函数：后台定时清理 =====================
background_clean() {
    while true; do
        sleep 1800  # 每30分钟执行一次清理
        clean_old_files
    done
}

# ===================== 主执行逻辑 =====================
main() {
    # 前置环境检查
    check_environment

    # 首次执行清理（启动时清理旧文件）
    clean_old_files

    # 启动后台定时清理（不阻塞主进程）
    background_clean &
    CLEAN_PID=$!
    echo "[$(date +%Y-%m-%d\ %H:%M:%S)] 后台定时清理进程启动，PID：${CLEAN_PID}" >> "${LOG_DIR}/info.log"

    # 构建完整的保存路径
    local save_path="${SAVE_DIR}/${FILE_NAME_TEMPLATE}"

    echo "[$(date +%Y-%m-%d\ %H:%M:%S)] 启动FFmpeg推流+分段录制（编码器：${ENCODER}）" >> "${LOG_DIR}/info.log"
    echo "启动成功！FFmpeg核心参数与你的命令完全一致，日志文件：${LOG_DIR}/ffmpeg.log"

    # 根据模式构建FFmpeg命令
    if [[ "$MODE" == "rkmpp" ]]; then
        # h264_rkmpp 模式
        ffmpeg -re -hide_banner -loglevel warning \
          -f v4l2 -thread_queue_size "${THREAD_QUEUE_SIZE}" -input_format "${INPUT_FORMAT}" -skip_frame "${SKIP_FRAME}" \
          -video_size "${VIDEO_SIZE}" -framerate "${FRAMERATE}" -i "${CAMERA_DEV}" \
          -c:v "${ENCODER}" -b:v "${BITRATE}" -g "${GOP_SIZE}" -r "${FRAMERATE}" -pix_fmt yuv420p \
          ${COLOR_PARAMS} -flags +global_header \
          -fflags +flush_packets+nobuffer -max_delay "${MAX_DELAY}" ${BUFSIZE:+-bufsize "${BUFSIZE}"} -an \
          ${SWSCALE_FILTER} \
          -map 0:v -f rtsp -rtsp_transport tcp "${RTSP_URL}" \
          -map 0:v -f segment -segment_time "${SEGMENT_TIME}" -segment_format mp4 \
          -strftime 1 -reset_timestamps 1 -movflags +faststart -y "${save_path}" \
          > "${LOG_DIR}/ffmpeg.log" 2>&1 &
    else
        # copy 模式：标准H264输入 + Copy编码
        ffmpeg -re -hide_banner -loglevel warning \
          -f v4l2 -thread_queue_size "${THREAD_QUEUE_SIZE}" -input_format "${INPUT_FORMAT}" \
          -video_size "${VIDEO_SIZE}" -framerate "${FRAMERATE}" -i "${CAMERA_DEV}" \
          -c:v "${ENCODER}" \
          -bsf:v h264_mp4toannexb \
          -flags +global_header -fflags +flush_packets+nobuffer+genpts \
          -max_delay "${MAX_DELAY}" -an \
          -avoid_negative_ts make_zero \
          -map 0:v -f rtsp -rtsp_transport tcp "${RTSP_URL}" \
          -map 0:v -f segment -segment_time "${SEGMENT_TIME}" -segment_format mp4 \
          -strftime 1 -reset_timestamps 1 -movflags +faststart -y "${save_path}" \
          > "${LOG_DIR}/ffmpeg.log" 2>&1 &
    fi

    # 记录FFmpeg进程ID
    FFMPEG_PID=$!
    echo "[$(date +%Y-%m-%d\ %H:%M:%S)] FFmpeg进程启动，PID：${FFMPEG_PID}" >> "${LOG_DIR}/info.log"

    # 等待FFmpeg进程（防止脚本退出）
    wait "${FFMPEG_PID}"

    # 检查FFmpeg退出状态
    local exit_code=$?
    if [ "${exit_code}" -ne 0 ]; then
        echo "[$(date +%Y-%m-%d\ %H:%M:%S)] FFmpeg异常退出（退出码：${exit_code}），日志详情：${LOG_DIR}/ffmpeg.log" >> "${LOG_DIR}/error.log"
        echo "错误：FFmpeg异常退出！退出码：${exit_code}，请查看日志：${LOG_DIR}/ffmpeg.log"
        # 停止后台清理进程
        kill "${CLEAN_PID}" 2>/dev/null
        exit "${exit_code}"
    fi
}

# 捕获退出信号（Ctrl+C、kill、关机等）
trap cleanup SIGINT SIGTERM SIGQUIT

# 启动主逻辑
main