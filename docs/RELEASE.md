# 固定发布配置

正式版唯一入口：

```sh
bash scripts/package-release.sh           # 本机架构
bash scripts/package-release.sh x86_64    # Intel
```

配置为 `config/build-profiles/release.json`，纳入 Git。生产编译边界通过
`CAPTIONS_BUILD_PROFILE=release` 进入 SwiftPM 的 `VIBECUTE_RELEASE` 条件。
配置中的资源白名单、排除项、版本要求和模型哈希参与打包及验证；不支持的功能组合使构建失败。

正式版保留 BeatNet+、MFCC 辅助口型、声音分类、唱歌、普通角色、闲置互动、字幕及六个 Harness。
人声增强是声音门控，继续保留；MFCC 仍使用基础声学判断，BeatNet+ 仍使用频谱起音参考。
排除 Kira 素材/触发/菜单、Apple Speech 与 Whisper 后端、NowPlaying 轮询、人声分离 worker/模型、
aubio/BTrack 实现与专用依赖、全部 CutOut 实现和工作台、开发者工具页、粉色小熊素材。
旧偏好和启动参数无法恢复被排除功能。BeatNet+ 仅加载包内运行时；缺少/损坏模型不改用其他引擎。
包内 `BuildManifest.json` 记录配置、配置哈希、源码哈希、HEAD 和工作区是否有未提交改动。
不把 dirty 工作区产物称为已经提交的发行版本。

产物：`dist/release/VibeCute.app` 和带版本/构建号/架构的 `.dmg`、`.dmg.sha256`。
DMG 提供 App 与 Applications 快捷入口。脚本自动运行最终 Release core 回归。打包后只读挂载，再对内部 App 执行严格签名和资源/依赖检查。
证据写入 `output/release/`。`CAPTIONS_BUILD_NUMBER` 可显式指定构建号，默认使用构建时间。
基础版本取自 `Resources/Info.plist`。最低 macOS 15.0。Intel 交叉构建使用独立目录 `dist/release/x86_64/`、`output/release/x86_64/` 和架构缓存，不覆盖 ARM 产物。
Intel 依赖由 `scripts/setup_intel_runtime.sh` 编译：Zstandard 1.5.7、固定 ggml 提交及同一 BeatNet+ 模型。关闭 AVX/AVX2/FMA/F16C 强制要求。
Apple Silicon 上的 Intel 核心回归需要 Rosetta；通过不等于已完成 Intel 真机性能验收。
架构和最低系统要求必须以最终验证报告为准。

## 开发版

```sh
bash scripts/build.sh development
# full 是 development 的兼容别名
bash scripts/build.sh full
```

配置为 `config/build-profiles/development.json`。保留实验选择和源码，只有本机已准备的 Whisper/Vocal
运行时才会打包。粉色小熊已按用户要求全局退役，其素材保存在 Git 忽略的 `backups/`。
开发版产物为 `dist/development/VibeCute Dev.app`，标识 `app.vibecute.desktop.dev`。
正式版继续使用 `app.vibecute.desktop` 及原有签名身份；两者偏好和缓存独立，不自动覆盖或迁移配置。
已有 `dist/VibeCute.app` 是旧构建路径，不会被这两个入口覆盖。
旧 minimal 入口仅作为兼容构建保留，不是正式发行入口。

## 验收

```sh
CAPTIONS_BUILD_PROFILE=release bash scripts/settings_ui_checks.sh
python3 scripts/onboarding_checks.py --profile release
bash scripts/release_core_checks.sh
python3 scripts/release_smoke.py --seconds 20
python3 scripts/rain_shelter_smoke.py --profile release
python3 scripts/verify_release.py dist/release/VibeCute.app --report output/release/bundle-check.json
```

原生设置检查使用独立偏好域，验证被排除功能无法由旧设置、setter 或演示方法启用。
Release core 检查直接链接最终 Release 的 core 对象，检查 BeatNet 锁定、静音失效、语音抑制、
加速积压后的恢复、缺少运行时无替代路径、环境覆盖无效及 MFCC 特征。
该回放是合成输入，不代表真实歌曲、长时间 CPU/能耗或系统音频授权验收。
原生设置检查与性能采样不要并发运行，资源测量也不要与编译并发。

天气烟测先编译 `Tests/RainShelterWindowFixture.swift` 到 `.build/rain-shelter-window-fixture`，使用自建空白前台窗口与隔离偏好，比较雨关、局部往返和底边内侧到达三个场景；记录进程CPU、RSS、物理footprint与真实位置，不读取用户窗口内容。Intel包可加 `--arch x86_64`，在Apple Silicon上执行时只代表Rosetta检查。天气和字幕等其他原生窗口验收结束后再单独采样；不把模拟计时、Rosetta结果或局部进程指标当成GPU、多屏、长期或Intel真机验收。

## 分发边界

包内保留 BeatNet+、GGML、PocketFFT、zstd 的许可及权重说明。
仓库所用 BeatNet+ 权重说明为仅限非商业使用；商业分发需另行确认授权或替换模型。
项目/角色素材授权状态见 README。本地持久证书签名不等于 Developer ID 签名或 Apple 公证。
脚本不上传、不公证、不发布至外部服务。交付报告必须单独注明公证状态。

## 随包授权文件

两个配置的 `legal_documents` 固定项目 GPL v3、角色授权说明、CC BY-NC-SA 4.0 完整法律文本和带上游链接的第三方声明。构建时汇入 App 的 `Contents/Resources/Licenses/`，并收集随包依赖许可。DMG 根目录另放一份 `Licenses/`，无需安装即可阅读。验收逐字节比较项目原文、依赖原文和挂载后两份副本，缺文件或内容过期会使打包失败。该修改只增加静态文件和构建时校验，无新增 App 轮询或运行时网络请求。

## 无 Git 的源码包与签名恢复

从 GitHub Download ZIP 解压的目录也可构建。组装器只认源码根目录自身的 Git 仓库，不借用外层仓库。自带 `SOURCE-INFO.json` 的源码导出保留原始提交、版本和源码摘要；若修改过源码，manifest 标记与归档不一致。GitHub ZIP 没有这份元信息时，应用版本仍来自 Info.plist，提交与 dirty 状态记录为未知，不伪造 HEAD。

签名首次准备会先验证 OpenSSL 的导出能力并生成临时证书；持久钥匙串创建/导入失败会回滚本次新建状态。原有身份不自动替换。若此前中断留下已导入的私钥和公开证书，可运行 `python3 scripts/setup_signing.py --recover` 校验并恢复该身份；若缺少可验证身份，脚本保留原文件并停止，应先完整备份 Signing 目录，再人工恢复或清理半成品。已有 identity.json 的情况继续复用原签名身份。

## 审查问题回归

```sh
bash scripts/test.sh
bash scripts/review_checks.sh
python3 -m unittest discover -s Tests -p test_review_build_tools.py -v
python3 scripts/onboarding_checks.py --profile release
```

音频回归使用注入的假设备测试实际重连定时器与退避，不操作真实设备或申请系统权限。真实蓝牙/耳机切换仍需单独验收。压缩夹具通过 PATH 查找 zstd，也可设置 `CAPTIONS_ZSTD_EXECUTABLE` 为指定可执行文件路径，避免依赖 Homebrew 的芯片专用前缀。
