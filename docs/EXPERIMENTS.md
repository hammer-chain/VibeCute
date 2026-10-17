# 开发版音频实验记录

以下为历史实验记录；当前正式版配置见 [RELEASE.md](RELEASE.md)。旧 minimal 构建命令仅作历史记录，当前开发版使用 `bash scripts/build.sh development`。

## BTrack 实验分支

开发者设置 → 节拍方案 → `BTrack（实验）`，也可使用 `--tempo-engine btrack`。
默认仍为 aubio；切换引擎会清空节奏状态。BTrack 原始 BPM 显示在节拍证据中，
未加入半速/倍速校正。置信度是本地稳定性门槛，不是 BTrack 输出的概率。

BTrack 固定使用 44.1 kHz、512 hop、1024 窗口；适配器将现有 16 kHz 单声道流
线性插值到该时钟（仅用于节奏），约每秒处理 86 个 hop。窗口与历史缓冲固定大小，
初始化只在启用音乐跟踪时发生。512 点起音历史无需 1:1 sinc 重采样，直接复制。
上游版本、修改与 GPL/BSD 许可见 `Sources/BTrackBridge/UPSTREAM.md`；打包脚本包含依赖许可。

可重复检查：

```sh
swift build --product CaptionCoreChecks
BTRACK_ONLY=1 .build/debug/CaptionCoreChecks
```

本机 Command Line Tools 缺少默认 C++ 头文件搜索路径时，构建命令附加
`-Xcxx -isystem -Xcxx "$(xcrun --show-sdk-path)/usr/include/c++/v1"`。
受限执行环境可附加 `--disable-sandbox`。

2026-10-14，arm64 macOS 调试构建，24 秒相同 120 BPM 合成鼓点（最后 4 秒静音）：
16 kHz 输入 aubio 0.90 秒、BTrack 1.14–1.27 秒；48 kHz 输入 aubio 1.12–1.46 秒、
BTrack 1.34–1.46 秒。总计四个输入/引擎组合，不带分析器，耗时包含整个口型分析链路。
前两轮运行存在并行构建干扰。无并行构建的扩展检查：BTrack 处理 24 秒音频耗时
1.13–1.46 秒，aubio 0.89–1.14 秒；仍不能作为稳定性能或真实歌曲准确率结论。
扩展检查的 90/120/160 BPM、两种采样率均锁定（误差 <10%），并通过静音失效、语音抑制和切换重置检查。
暂定实验预算为离线耗时低于音频时长的 10%；真实系统音频的 CPU、能耗、内存、
拍点延迟、歌曲切换与动作同步尚未验收，性能未完成实际运行验收。

## BeatNet+ 实验

先运行 `bash scripts/setup_beatnet.sh`，再 `bash scripts/build.sh minimal`。
开发者设置 → 节拍方案 → `BeatNet+（实验）`，或启动参数 `--tempo-engine beatnet`。
C++ 动态库与 3.4 MB 模型会随本地 app 打包；无 Python 推理进程和实时网络调用。
**权重仅限非商业使用**，此接入用于本地试验；上游与依赖说明见 `Sources/BeatNetBridge/UPSTREAM.md`。

22050 Hz 流式模型在单独工作队列按 100 ms 批处理，最多排队三批；积压时丢弃并重置阶段，
不沿用失效拍点。特征需要约 40 ms 后视窗口，另有批处理和拍点确认延迟。
只保留最近八个拍点；粒子滤波历史只保留上一拍锚点，并与上游逐事件校验。
默认模型范围为 55–215 BPM。界面置信度是拍点间隔一致性，不是网络概率。

检查：

```sh
BEATNET_ONLY=1 bash scripts/test.sh
.build/beatnet/build/beatnet-parity .build/beatnet/runtime/generic-f32.gguf
PCM_TEMPO_ENGINE=beatnet PCM_TEMPOS=120,132,144,156,168,180 \
 BTRACK_PCM_DIRECTORY=output/beatnet/moderate-speeds .build/debug/CaptionCoreChecks
```

最后一条回放依赖本次生成的测试 WAV；`output` 属于本地测试产物。
已验证 120 BPM 锁定、静音失效、语音抑制、引擎切换重置和缺少运行时的无输出行为。
加速输入没有在本机触发积压，不能宣称已实测最坏过载。60 秒测试的 118 个事件与上游完全一致。
模型 SHA-256：`f1c1143ae016c7d525156591f6a99d864d1ddcc19129ae33982d08a6a4c41c5c`。

2026-10-14 小幅变速实测：相同 120–180 BPM 底鼓，BeatNet+ 稳态中位数误差小于 2%；
真实《星間飛行》1.1–1.5× 稳态相对中位数误差小于 3%，1.5× 有效输出约 93%。
实际发生一次丢批后重锁，仍需长期稳定性和动作同步验收。详见本地 `output/beatnet/report.html`。
