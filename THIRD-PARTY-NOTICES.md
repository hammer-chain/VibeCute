# VibeCute 第三方组件与原项目

项目代码：GNU GPL v3（GPL-3.0-only）。角色形象：CC BY-NC-SA 4.0；原作者：[上善无形](https://space.bilibili.com/4456176)、[ZipZipPipe](https://space.bilibili.com/4168597)。各第三方组件保留独立的版权及许可声明。

| 组件 | 原项目 | 许可或限制 | 说明 |
| --- | --- | --- | --- |
| BeatNet+ C++ 代码 | [key2/beatnetplus.cpp](https://github.com/key2/beatnetplus.cpp) | MIT | 接入版本及修改见源码仓库 |
| BeatNet+ 模型权重 | [上游模型与授权说明](https://github.com/key2/beatnetplus.cpp#dependencies-and-licenses) | 仅限非商业使用 | 不适用本项目的 GPL v3 或角色素材许可 |
| ggml | [ggml-org/ggml](https://github.com/ggml-org/ggml) | MIT | 随 BeatNet+ 运行时保留许可 |
| PocketFFT | [mreineck/pocketfft](https://github.com/mreineck/pocketfft) | BSD-3-Clause | 保留上游头文件声明 |
| Zstandard | [facebook/zstd](https://github.com/facebook/zstd) | 保留上游许可 | 许可文件随包附带 |
| aubio | [aubio/aubio](https://github.com/aubio/aubio) | GPL-3.0-or-later | 接入版本及修改见源码仓库，仅开发/实验构建 |
| BTrack | [adamstark/BTrack](https://github.com/adamstark/BTrack) | GPL-3.0-or-later | 接入版本及修改见源码仓库，仅开发/实验构建 |
| Kiss FFT | [mborgerding/kissfft](https://github.com/mborgerding/kissfft) | 随附 BSD 许可 | 随 BTrack 保留原始声明 |
| libsamplerate | [libsndfile/libsamplerate](https://github.com/libsndfile/libsamplerate) | BSD-2-Clause | 随 BTrack 保留原始声明 |

## 安装包中的许可文件

正式版的 Licenses 目录包含 LICENSE、LICENSE-ASSETS.md、CC-BY-NC-SA-4.0.txt、本声明，以及 BeatNetPlus-LICENSE.txt、ggml-LICENSE.txt、PocketFFT-NOTICE.txt、Weights-NOTICE.txt 和 Zstandard-LICENSE.txt。

本表中的“接入说明”和“随附许可”指源码仓库内的说明；原项目列为可直接访问的上游网址。正式版不包含 aubio、BTrack、Kiss FFT 或 libsamplerate；开发版若包含相应组件，也会附带相应原始许可。BeatNet+ 权重仅限非商业使用。

## Desktop weather

The desktop rain renderer and procedural rain audio were adapted from the user-supplied DesktopRain prototype. The 24-second rain loop contains no downloaded recordings or samples.

When the user enables automatic city weather, weather data is provided by [Open-Meteo](https://open-meteo.com/) under [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/). City search uses Open-Meteo's geocoding service with data from [GeoNames](https://www.geonames.org/). The free API is for non-commercial use; commercial integrations require an appropriate subscription or self-hosted service. See [service terms](https://open-meteo.com/en/terms).

## 天气雨声录音

以下两份录音作为桌面天气动画的独立音轨使用。原始下载文件保留原始字节；播放版本分别裁掉首尾弱音段，使用各自录音的首尾做2秒交叉衔接，并转为PCM无缝循环文件。远处雨声与近处雨滴没有合并。不适用项目代码的 GPL-3.0-only 或角色形象许可。

- `rain-bed.mp3`：**Gentle Rain from Window**，YostPeter（通过 freesound_community 发布）。来源：https://pixabay.com/sound-effects/nature-gentle-rain-from-window-24548/
- `rain-drops.mp3`：**Dripping rain drops**，RobMosCreative。来源：https://pixabay.com/sound-effects/nature-dripping-rain-drops-376028/
- 播放文件为 `rain-bed-loop.wav`（127.376秒）与 `rain-drops-loop.wav`（125.424秒）；离线处理脚本为 `scripts/prepare_rain_loops.py`。
- 下载及许可核对日期：2026-10-20。上述页面均标注 Pixabay Content License。许可摘要：https://pixabay.com/service/license-summary/ ；完整条款：https://pixabay.com/service/terms/
- 录音仅作为 VibeCute 天气动画的一部分使用，不作为独立素材包提供或重新许可；如单独复用，须自行遵守原始许可，尤其是禁止独立分发的限制。
