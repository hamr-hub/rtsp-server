# rtsp-server

1. 官网 (mediamtx)[https://mediamtx.org],  (下载地址)[https://github.com/bluenviron/mediamtx/releases/tag/v1.15.5]
2. 更新ffmpeg 7.0+, (查看版本 ffmpeg --version)  (官方仓库) [https://git.ffmpeg.org/ffmpeg.git]
   ffmpeg 更新
   - (johnvansickle 静态更新)[https://www.johnvansickle.com/ffmpeg/]
   - (BtbN-build)[https://github.com/BtbN/FFmpeg-Builds]
   - (官网库)[https://ffmpeg.org/download.html]
  
3. 注册systemd， 参考(rtsp-server.service)
4. 启动推流脚本 ./start.sh

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
