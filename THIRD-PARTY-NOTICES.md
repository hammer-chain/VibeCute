# VibeCute 第三方组件与原项目

项目代码：GNU GPL v3（GPL-3.0-only）。角色形象：CC BY-NC-SA 4.0；原作者：上善无形 ZipZipPipe。各第三方组件保留独立的版权及许可声明。

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
