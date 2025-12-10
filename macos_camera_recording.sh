#!/bin/bash

# macOS 摄像头录制脚本 - 每10分钟保存一次
# 使用方法: ./macos_camera_recording.sh

# 设置输出目录
OUTPUT_DIR="./recordings"
mkdir -p "$OUTPUT_DIR"

# 检查摄像头设备
echo "正在检查摄像头设备..."
ffmpeg -f avfoundation -list_devices true -i "" 2>&1 | grep -E "(Capture|0:0)"

echo "开始录制摄像头，每10分钟保存一个文件..."
echo "输出目录: $OUTPUT_DIR"
echo "按 Ctrl+C 停止录制"

# 优化后的 FFmpeg 命令
ffmpeg \
  -f avfoundation \
  -framerate 30 \
  -video_size 1280x720 \
  -i 0:0 \
  -vf "select='gt(scene,0.02)':e=0.02,setpts=N/FRAME_RATE/TB" \
  -vcodec h264_videotoolbox \
  -acodec aac \
  -bf 0 \
  -preset fast \
  -qp 23 \
  -f segment \
  -segment_time 600 \
  -segment_format mp4 \
  -segment_list "$OUTPUT_DIR/recordings_list.txt" \
  -segment_list_type flat \
  -segment_list_flags +live \
  -reset_timestamps 1 \
  -strftime 1 \
  "$OUTPUT_DIR/recording_%Y%m%d_%H%M%S.mp4" \
  -reconnect 1 \
  -reconnect_at_eof 1 \
  -reconnect_streamed 1 \
  -reconnect_delay_max 5 \
  -loglevel info \
  -stats \
  -y

echo "录制已停止"

# 简化版本（单行命令）
echo ""
echo "=== 简化版本（单行命令）==="
echo "ffmpeg -f avfoundation -framerate 30 -video_size 1280x720 -i 0:0 -vf \"select='gt(scene,0.02)':e=0.02,setpts=N/FRAME_RATE/TB\" -vcodec h264_videotoolbox -acodec aac -bf 0 -preset fast -qp 23 -f segment -segment_time 600 -strftime 1 -reset_timestamps 1 ./recording_%Y%m%d_%H%M%S.mp4"