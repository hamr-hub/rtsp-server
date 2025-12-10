# rtsp-server

1. 官网 (mediamtx)[https://mediamtx.org],  (下载地址)[https://github.com/bluenviron/mediamtx/releases/tag/v1.15.5]
2. 更新ffmpeg 7.0+, (查看版本 ffmpeg --version)  (官方仓库) [https://git.ffmpeg.org/ffmpeg.git]
   ffmpeg 更新
   - (johnvansickle 静态更新)[https://www.johnvansickle.com/ffmpeg/]
   - (BtbN-build)[https://github.com/BtbN/FFmpeg-Builds]
   - (官网库)[https://ffmpeg.org/download.html]
  
3. 注册systemd， 参考(rtsp-server.service)
4. 启动推流脚本 ./start.sh



### macos 录制

```bash

ffmpeg -f avfoundation -framerate 30 -video_size 1280x720 -i 0:0 \
-vf "select='gt(scene,0.01)',setpts=N/FRAME_RATE/TB" \
-vcodec h264_videotoolbox -acodec aac -bf 0 \
-f segment -segment_time 600 -segment_format mp4 \
recording_%Y%m%d_%H%M%S.mp4 \
-reconnect 1 -reconnect_at_eof 1 -reconnect_streamed 1 -reconnect_delay_max 5 \
-nostdin -y

```
执行后预期效果
1. 终端会显示摄像头采集流的信息，开始持续录制；
2. 每 10 分钟（600 秒）生成一个文件，命名示例：recording_20251210_163000.mp4；
3. 无画面变化时（帧差异 < 0.01），该时间段内的帧会被跳过，最终文件仅保留有变化的画面；
4. 停止录制：按 Ctrl+C 即可。