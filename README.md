# rtsp-server

## 快速开始

1. **官网**: [MediaMTX](https://mediamtx.org)
2. **下载地址**: [MediaMTX v1.15.5](https://github.com/bluenviron/mediamtx/releases/tag/v1.15.5)
3. **FFmpeg版本**: 需要 7.0+ 版本
   - 查看版本: `ffmpeg --version`
   - 官方仓库: [https://git.ffmpeg.org/ffmpeg.git](https://git.ffmpeg.org/ffmpeg.git)
   - 静态编译包:
     - [johnvansickle](https://www.johnvansickle.com/ffmpeg/)
     - [BtbN-build](https://github.com/BtbN/FFmpeg-Builds)
     - [官网下载](https://ffmpeg.org/download.html)
4. **注册systemd服务**: 参考 `rtsp-server.service`
5. **启动推流脚本**: `./start.sh`

## 🚀 新增功能：参数化启动脚本

`start-webcam.sh` 脚本现已支持命令行参数，可以在两种编码模式之间灵活切换：

### 使用方法

```bash
# 1. 使用默认的 h264_rkmpp 硬件编码模式
./start-webcam.sh

# 2. 使用标准H264输入 + Copy编码模式
./start-webcam.sh -m copy

# 3. 使用copy模式，60fps
./start-webcam.sh -m copy -f 60

# 4. 使用rkmpp模式，1080p分辨率
./start-webcam.sh --mode rkmpp --size 1920x1080

# 5. 自定义所有参数
./start-webcam.sh -m copy -d /dev/video0 -s 1920x1080 -f 30 -t 1800

# 6. 查看帮助信息
./start-webcam.sh -h
```

### 支持的参数

| 参数 | 短参数 | 说明 | 默认值 |
|------|--------|------|--------|
| `--mode` | `-m` | 编码模式：`rkmpp` 或 `copy` | `rkmpp` |
| `--device` | `-d` | 摄像头设备节点 | `/dev/video10` |
| `--size` | `-s` | 视频分辨率 | `1280x720` |
| `--framerate` | `-f` | 帧率 | `30` |
| `--segment-time` | `-t` | 分段时长（秒） | `3600` |
| `--help` | `-h` | 显示帮助信息 | - |

### 两种编码模式对比

#### 1. h264_rkmpp 模式（默认）
- **特点**: 使用Rockchip硬件编码器，性能优异，CPU占用低
- **适用场景**: RK3399等支持硬件编码的平台
- **FFmpeg核心参数**:
  ```bash
  -c:v h264_rkmpp -b:v 2000k -g 60 -r 30 -pix_fmt yuv420p
  -color_range tv -colorspace bt709 -color_primaries bt709 -color_trc bt709
  ```

#### 2. 标准H264 + Copy编码模式
- **特点**: 直接复制标准H264流，不做重新编码，保持原始质量
- **适用场景**: 输入已经是标准H264格式的摄像头
- **FFmpeg核心参数**:
  ```bash
  -input_format h264 -c:v copy
  -bsf:v h264_mp4toannexb
  -avoid_negative_ts make_zero
  ```

### 后台运行

```bash
# 使用nohup后台运行（推荐）
nohup ./start-webcam.sh > "/mnt/sd/log/ffmpeg.log" 2>&1 &

# 使用systemd服务（需要配置rtsp-server.service）
sudo systemctl start rtsp-server
```

### linux 录制

命令中的[/dev/video10] 改成设备
```bash 
ffmpeg \
  -f v4l2 -framerate 30 -video_size 640x480 -i /dev/video10 \
  -vf "select='gt(scene,0.5)',setpts=N/30/TB" \
  -r 30 \
  -vcodec libx264 -preset veryfast -crf 23 -bf 0 \
  -nostdin -y "recording_$(date +%Y%m%d_%H%M%S).mp4"
```




### macos 录制

```bash

ffmpeg \
  -f avfoundation \
  -framerate 30 \
  -video_size 640x480 \
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
  -segment_list "recordings_list.txt" \
  -segment_list_type flat \
  -segment_list_flags +live \
  -reset_timestamps 1 \
  -strftime 1 \
  "recording_%Y%m%d_%H%M%S.mp4" \
  -reconnect 1 \
  -reconnect_at_eof 1 \
  -reconnect_streamed 1 \
  -reconnect_delay_max 5 \
  -loglevel info \
  -stats \
  -y

```
执行后预期效果
1. 终端会显示摄像头采集流的信息，开始持续录制；
2. 每 10 分钟（600 秒）生成一个文件，命名示例：recording_20251210_163000.mp4；
3. 无画面变化时（帧差异 < 0.01），该时间段内的帧会被跳过，最终文件仅保留有变化的画面；
4. 停止录制：按 Ctrl+C 即可。



# RK3399 源码编译 ffmpeg

## 下载代码
```base
# 1. 克隆 FFmpeg 源码
git clone https://git.ffmpeg.org/ffmpeg.git
## 报错尝试：git clone --depth 1 https://gitee.com/mirrors/ffmpeg.git

cd ffmpeg

# 2. 配置编译参数（核心：开启 --enable-librockchipmpp）
./configure \
  --prefix=/usr/local \
  --enable-gpl \
  --enable-nonfree \
  --enable-v4l2_m2m \
  --enable-hardcoded-tables \
  --enable-shared \
  --disable-static \
  --disable-doc \
  --disable-ffplay \
  --disable-ffprobe \
  --arch=arm64 \
  --target-os=linux

# 3. 编译安装（-j6 适配 6 核）
make -j6
sudo make install

# 4. 刷新库缓存
sudo ldconfig



```


ffmpeg 编译最新命令：
缺依赖可以问AI用api装上：
```bash 

 ./configure --prefix=/usr --extra-version=1ubuntu1.0firefly3 --toolchain=hardened --libdir=/usr/lib/aarch64-linux-gnu --incdir=/usr/include/aarch64-linux-gnu --arch=arm64 --enable-gpl --disable-stripping --disable-filter=resample --disable-avisynth --disable-gnutls --disable-ladspa --disable-libaom --enable-libass --enable-libbluray --enable-libbs2b --enable-libcaca --disable-libcdio --enable-libcodec2 --disable-libflite --enable-libfontconfig --enable-libfreetype --enable-libfribidi --enable-libgme --enable-libgsm --enable-libjack --enable-libmp3lame --enable-libmysofa --disable-libopenjpeg --enable-libopenmpt --enable-libopus --enable-libpulse --enable-librsvg --enable-librubberband --enable-libshine --enable-libsnappy --enable-libsoxr --enable-libspeex --enable-libssh --enable-libtheora --enable-libtwolame --enable-libvidstab --enable-libvorbis --enable-libvpx --enable-libwebp --enable-libx265 --enable-libxml2 --enable-libxvid --enable-libzmq --enable-libzvbi --disable-lv2 --enable-omx --enable-openal --enable-opencl --enable-opengl --enable-sdl2 --enable-libdc1394 --enable-libdrm --disable-libiec61883 --disable-chromaprint --disable-frei0r --enable-libx264 --enable-libdrm --enable-rkmpp --enable-version3 --disable-libopenh264 --disable-vaapi --disable-vdpau --disable-decoder=h264_v4l2m2m --disable-decoder=vp8_v4l2m2m --disable-decoder=mpeg2_v4l2m2m --disable-decoder=mpeg4_v4l2m2m --enable-shared --disable-doc


之后再make


```


## 验证

ffmpeg -encoders | grep rkmpp

### RK3399 硬件编码命令

#### 传统命令行方式

```
ffmpeg -re -hide_banner -loglevel error \
  -f v4l2 -input_format mjpeg -video_size 1280x720 -framerate 30 -i "/dev/video10" \
  -c:v h264_rkmpp -b:v 2000k -flags +global_header -pix_fmt nv12 \
  -color_range 1 -colorspace bt601 \
  -fflags +flush_packets -max_delay 500000 -an \
  -f rtsp -rtsp_transport tcp "rtsp://localhost:8554/live" \


ffmpeg -re -hide_banner -loglevel warning \
  -f v4l2 -input_format mjpeg -video_size 1280x720 -framerate 30 -i /dev/video10 \
  -c:v h264_rkmpp -b:v 2000k -g 60 -r 30 -pix_fmt yuv420p \
  -color_range tv -colorspace bt709 -flags +global_header \
  -fflags +flush_packets+nobuffer -max_delay 500000 -bufsize 2M -an \
  -map 0:v -f rtsp -rtsp_transport tcp rtsp://localhost:8554/live \
  -map 0:v -f mp4 -movflags +faststart -y /mnt/sd/camera_$(date +%Y%m%d_%H%M%S).mp4
```

#### 推荐：使用参数化脚本

```bash
# 使用默认的h264_rkmpp模式
./start-webcam.sh

# 或者指定参数
./start-webcam.sh -m rkmpp -s 1920x1080 -f 30
```

### 标准H264 + Copy编码命令

#### 传统命令行方式

```bash
ffmpeg -re -hide_banner -loglevel warning \
  -f v4l2 -thread_queue_size 4096 -input_format h264 \
  -video_size 1280x720 -framerate 30 \
  -i /dev/video10 \
  -c:v copy \
  -bsf:v h264_mp4toannexb \
  -flags +global_header -fflags +flush_packets+nobuffer+genpts \
  -max_delay 500000 -bufsize 2M -an \
  -avoid_negative_ts make_zero \
  -map 0:v -f rtsp -rtsp_transport tcp rtsp://localhost:8554/live \
  -map 0:v -f segment -segment_time 3600 -segment_format mp4 \
  -strftime 1 -reset_timestamps 1 -movflags +faststart -y /mnt/sd/camera_%Y%m%d_%H%M%S.mp4
```

#### 推荐：使用参数化脚本

```bash
# 使用标准H264 + Copy编码模式
./start-webcam.sh -m copy

# 或者指定参数
./start-webcam.sh -m copy -s 1920x1080 -f 60 -t 1800
```
## opencv安装

发布版本下载：[https://opencv.org/releases/]

```bash

git clone --depth 1 https://github.com/opencv/opencv.git
# git clone --depth 1 https://gitee.com/mirror/opencv.git

apt-get install libopencv-dev

cd opencv

mkdir build && cd build
cmake -D CMAKE_BUILD_TYPE=RELEASE -D CMAKE_INSTALL_PREFIX=/usr/local/opencv_install ..

make -j$(nproc) && sudo make install

```


## 脚本特性

### 自动化功能
- ✅ **环境检查**: 自动检查FFmpeg、摄像头设备、磁盘空间
- ✅ **编码器验证**: 编码器不可用时自动切换
- ✅ **自动清理**: 定时清理旧文件，防止磁盘满
- ✅ **日志记录**: 完整的操作和错误日志
- ✅ **优雅退出**: 支持Ctrl+C等信号处理

### 后台运行

```bash
# 使用nohup后台运行（推荐）
nohup ./start-webcam.sh > "/mnt/sd/log/ffmpeg.log" 2>&1 &

# 使用systemd服务（需要配置rtsp-server.service）
sudo systemctl start rtsp-server

# 查看运行状态
sudo systemctl status rtsp-server

# 查看日志
tail -f /mnt/sd/log/ffmpeg.log
```

### 日志文件说明

- `/mnt/sd/log/ffmpeg.log`: FFmpeg详细日志
- `/mnt/sd/log/info.log`: 脚本运行信息
- `/mnt/sd/log/error.log`: 错误日志
- `/mnt/sd/log/clean.log`: 文件清理日志

### 文件清理策略

- **保留时间**: 默认保留7天内的录制文件
- **磁盘阈值**: 磁盘使用率超过85%时自动清理最旧文件
- **分段时长**: 默认每1小时生成一个文件
- **自动触发**: 每30分钟执行一次清理检查