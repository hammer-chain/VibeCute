# Cutout 动作配置

本契约只用于 Cutout。像素帧角色的图集、口型资源和动作播放器不读取这些字段。

角色注册位于 `Sources/CodexCaptions/Resources/CutoutCharacters/deepseek-cutout.json`，动作库位于 `Sources/CodexCaptions/Resources/DeepSeekCutout/classic-thinking-motions.json`。

## 首尾姿态

动作库的 `poses` 声明命名骨骼姿态。值是相对绑定姿态的位移与旋转；未列出的骨骼取零位移、零旋转。动作的 `startPose` 和 `endPose` 分别锁定首尾关键姿态。

```json
{
  "poses": { "seated-neutral": {} },
  "clips": [{
    "id": "idle",
    "title": "休息",
    "duration": 4,
    "loop": true,
    "tracks": [],
    "frameDurations": [4],
    "startPose": "seated-neutral",
    "endPose": "seated-neutral"
  }]
}
```

加载时检查姿态名称和每根骨骼的端点值。配置不匹配时拒载，不自动覆盖作者的关键帧。循环动作仍须保持骨骼与眼睑端点一致。视线和口型继续作为独立通道输入。

## 帧时长与结束去向

Cutout 连续插值骨骼关键帧，不生成整身图片帧。`frameDurations` 配置的是关键姿态区间时长，单位为秒。

区间顺序取所有骨骼关键帧时间、眼睑关键帧时间与 `0`、`duration` 的排序去重结果。例如时间点为 `[0, 1, 2, 3, 4]`，则对应四个时长。增删任一通道的时间点后，须同步调整时长数组。

`duration` 保留原始关键帧时间轴的长度。实际播放时长是 `frameDurations` 的和；不提供该字段时，沿用原时间轴。时长数组须覆盖全部区间，每项至少 0.001 秒，总和不超过 120 秒。插值和眼睑共用重映射后的时间。

现有 `tail-wag-once` 使用 `[0.3, 0.5, 0.7, 0.5]`，实际播放 2 秒。`loop: false` 与 `fallback: "idle"` 使它播放完后进入休息。未配置 `fallback` 的非循环动作停在末姿态。

`fallback` 必须指向已有动作。前一动作末姿态须与后一动作首姿态一致，约束集合、接地模式和眼睑端点也须兼容。禁止循环动作配置 `fallback`，也禁止结束去向形成环。需要不同姿态之间的过渡时，先制作衔接动作。

播放器按绝对时钟处理结束去向。回调晚到时，已过去的时间会计入目标动作。工作台暂停后可查看非循环动作的精确末姿态，恢复播放后再进入目标动作。

## 共用裁切框

`cutout.motionBounds` 为 `[minX, minY, maxX, maxY]`，使用源坐标，Y 轴向上。当前值为 `[-8, 16, 1048, 1016]`，覆盖现有动作、发型和视线范围，并保留边缘余量。

所有动作、原生窗口、重绘区域和导出画面共用该框。切换动作或发型不会重新居中、按包围盒缩放或移动脚线。实际显示位置仍由 `anchor` 和 `pointsPerPixel` 决定。

新增动作或发型后，运行边界检查；如超出共同框，扩大同一个框。不要为单个动作增加独立裁切框。测试使用每秒 60 次采样检查已有动作，不能替代新增动作的人工画面检查。

## 解码缓存

`cutout.decodedByteLimit` 为当前选中外观的常驻解码预算，当前为 `25165824` 字节，即 24 MiB。旧配置未声明时沿用 24 MiB。

缓存按 `CGImage.bytesPerRow × height` 计费。同一图片对象只计一次；同路径图片在组件、表情和口型间共享。预算包括源组件、表情、口型、局部合成图集、布料图集和眼部遮罩。分配前检查预计字节，生成后核对实际字节。

只保留当前外观和共用表情。换装复用仍在使用的图片，成功后释放旧外观资源。超预算或加载失败时，保留此前选中外观和画面。动画推进只读取已准备好的图片，不解码、不重建图集。

换装为原子操作，准备期间旧、新外观会同时存在。`peakResidentDecodedBytes` 记录去重后的并存峰值，最多受两个选中外观预算约束。该统计不含解码临时缓冲、绘图上下文、系统缓存和其他 App 内存，不能当作进程 RSS 上限。

诊断字段还包括 `decodedBytes`、`decodedByteLimit`、`releasedDecodedBytes` 和 `cacheHits`。

## Claude Code 工服与双袖拆层

工作台「服装」可选择 `clothes-claude-code`（Claude Code 工服 · 米白卫衣）。它包含米白卫衣、橙色裙装、配套鞋袜。八道橙色星芒是独立头饰 `headwear-claude-code`，换衣服不会自动覆盖当前头饰或发型。

当前工服是阶段快照，外观尚未验收通过。2026-10-23 用户仍反馈脖子不可见，并要求先提交现状。后续须在完整角色中检查颈部、领口和抬手的关系；隐藏手部后的颈部像素检查通过，不能证明实际画面的脖子可见面积和比例正确。

工服的两侧都分别使用上袖、下袖、袖口和手。上袖跟随肩关节，下袖与袖口跟随肘关节，手跟随腕关节。右手复用原有裸手图片；左肘和左腕补为 `arm-left` 的后代。旧女仆装左臂仍保留原整片素材，中性画面与原有思考动作保持不变。

`sleeve-joints-probe`（双袖屈肘 · 工服接缝）是新增检查动作，循环为 4 秒。它检查两侧肘、腕的分段接缝，不是另一份工服专用思考动作。思考、贴颊、肩部动作与原衣服共用原动作配置。

服装可在自己的 variant 内提供 `clothDeformations`，字段结构与角色级同名配置一致。未提供时继承角色配置，提供空数组时关闭布料变形。服装的变形区域必须属于自身附件；缓存同时比较变形参数，避免同图不同配置错误复用旧图集。工服使用自己的肩腰区域，不套用女仆装区域。

服装可用 `slotOrders` 调整自身附件和身份图层的绘制顺序。未提供时沿用角色插槽顺序；只在换装准备阶段排序。工服依次绘制后裙摆 `skirt-back`、腿、前裙片 `skirt-front`、上衣 `topwear`。前裙片独立覆盖上部大腿，保留膝盖与袜筒；不能把整条裙子移到腿后当作拆分完成。`neck` 在上衣之后、脸之前绘制。两侧上袖在衣身之前绘制，隐藏肩端的圆形接头；下袖、袖口与手仍在衣身前。旧女仆装不使用此覆盖。未知插槽、其他服装附件、头发和越界顺序会被拒绝；覆盖不能拆散局部合成组。

素材源图与提示词位于 `artwork/cutout/claude-code/`，内置 imagegen 依据当前 Cutout 与工服帧图生成分层源图。前后裙片使用 `compact-outfit-source.png`，后片收在同一裙子轮廓内，避免在完整长裙上再叠一条前裙边。衣身改用 `low-neckline-source.png`，中央 V 口透明，后领藏在头部后方，避免高领围巾和头身空隙。领口与腹部分段注册，开口末端落在原颈部皮肤范围内。袖片使用 `puffy-sleeves-source.png`，鞋袜使用 `soft-socks-shoes-source.png`，去掉首版多出的鞋带扣和蕾丝袜边，保留可见的袜筒贴花。头饰使用独立八道星芒源图。`scripts/artwork/prepare_claude_cutout.swift` 按组件实际边界提取，分别将袖片端点注册到绑定关节，并同步 `registration.json` 与角色注册中的矩形。袖长和袖宽分别校准，保留原右手位置。准备阶段生成已注册图片，动画期间不做纹理重采样准备。

```sh
swift -module-cache-path .build/clang-cache scripts/artwork/prepare_claude_cutout.swift
bash scripts/cutout_wardrobe_check.sh
open -n "dist/development/VibeCute Dev.app" --args --cutout-studio \
  --cutout-clothes clothes-claude-code --cutout-headwear headwear-claude-code
```

检查覆盖两套衣服、三种发型、五个动作，并单独移除躯干遮挡检查袖片关节覆盖；另将完整角色的露颈、膝盖和袜筒像素与实际对应图层比较，同时检查前裙片必须盖住上部大腿。只确认腿可见会漏掉整条腿都在裙前的问题。思考和歪头还检查下巴与后领的真实重叠像素：下巴必须覆盖衣料，而且必须有接触，不能以没有重叠的空隙通过检查。导出的 `output/claude-cutout/workwear-motion.gif` 依次播放一轮思考与一轮双袖诊断，仅用于查看动作，不包含音轨。

`--cutout-studio` 启动隔离工作台；日常开发版可用 `--cutout-workbench` 同时打开工作台，避免两个同路径 App 实例读取不同版本的素材。两种入口都支持 `--cutout-clothes` 与 `--cutout-headwear` 指定工作台初始选择，不改日常绑定或默认女仆装。

## 验收

```sh
bash scripts/cutout_runtime_check.sh
bash scripts/cutout_playback_check.sh
bash scripts/build.sh development
```

独立工作台使用签名开发版，避免启动会话读取和日常设置：

```sh
open -n "dist/development/VibeCute Dev.app" --args \
  --cutout-studio --cutout-playback-smoke \
  --cutout-smoke-out "$PWD/output/cutout-playback/native"
```

该验收实例记录一次性动作结束、换发型、暂停、最小化和恢复的实窗状态。验收结束后关闭独立工作台。

## 思考循环的像素节拍试验

`thinking-classic` 使用 `interpolation: "step"`。每个头部与身体关键姿态保持到下个时间点，眼睑也按拍切换。单根轨道可用 `interpolation: "smooth"` 覆盖；其他动作未声明该字段时继续使用平滑插值。

Cutout 工作台打开后默认播放 `thinking-classic`，与两版对比预览一致。选择 step 动作时不加入场混合，原 30 Hz 预览时钟会在姿态边界提前唤醒。工作台与角色预览共用头发变形、接缝合成和双马尾后发遮挡。没有 `thinking-classic` 的候选角色继续按已有动作回退选择。

`referenceFrames` 记录每个区间对应的像素帧编号，便于核查节拍。它不加载像素素材，也不改变 Cutout 的图层渲染。当前为 `[0, 0, 0, 0, 0, 1, 1, 2, 2, 3, 4, 5, 6, 6, 7, 7, 7, 7]`，18 拍各 0.16 秒，共 2.88 秒。

| 像素姿态 | Cutout 保持区间 |
|---|---|
| 0 | 0.00–0.80 秒 |
| 1 | 0.80–1.12 秒 |
| 2 | 1.12–1.44 秒 |
| 3，半闭眼 | 1.44–1.60 秒 |
| 4，闭眼 | 1.60–1.76 秒 |
| 5，重新睁眼 | 1.76–1.92 秒 |
| 6 | 1.92–2.24 秒 |
| 7 | 2.24–2.88 秒 |

回正前的头部角度参考原像素帧视线注册中的双眼连线。此映射对齐姿态方向，不能复现原画的全部局部形变。1.60 秒回正后，头部与躯干保持中性；原像素帧后半段的细微头摆不再照搬。

原生角色进入这个思考循环时不加 0.25 秒入场混合。原有 30 Hz 时钟会在关键姿态边界提前唤醒，不增加第二套动画时钟。真实显示仍受系统调度和窗口提交延迟影响，配置同拍不代表两扇窗口能保证零毫秒误差。

「DeepSeek 两版对比」先准备两边资源，等待窗口显示稳定，再同时开始。点击「重播」可重新起跑；此操作只控制预览。隔离实窗验收与原生并排 GIF 使用以下命令：

```sh
bash scripts/cutout_thinking_sync_check.sh
open -n "dist/development/VibeCute Dev.app" --args \
  --cutout-compare --cutout-rhythm-smoke-out "$PWD/output/cutout-thinking-sync/native"
```

此模式不启动会话读取，不写日常角色绑定。真实两版的切换事件分别记录，验收器不会用同一合成时钟代替实际播放器。

### 回正后的头发回摆

`hair-return` 是无挂件的叶子控制关节，只提供头发变形量，不是头部父关节。该轨道单独用连续插值，1.60 秒从零开始，1.76 秒到达峰值，之后反向衰减，2.56 秒恢复零值。头、颈、肩和手臂在整个回摆期间保持原位。

`cutout.hairDeformations` 按头发 slot 配置 `driver`、`rootY`、`tipY`、`maxOffset` 与 `rows`。坐标为源画布 Y 向上；发根位移为零，发梢位移随 smoothstep 权重增大。当前后发和双马尾最大 12 源像素，前发 4 像素，呆毛 6 像素，均以 4 段连续剪切网格为基础，并加入发根与发梢边界。

每段共享相邻边界顶点，使用同一张已解码头发图。无变形时直接绘制原图，保留中性画面；有变形时暂时绕过该头发的静态合成组。变形不生成位图图集、不解码新图，也不改变头部骨骼。共同裁切框的边界检查包含变形后的顶点。

`bash scripts/cutout_thinking_sync_check.sh` 同时检查头部回正后的骨骼恒定、发根固定、非线性弯曲，以及去掉头发后的整张头身画面逐像素一致。

### 分段接缝与双马尾后发

头发在独立透明合成层内变形。分段边界重叠两个设备像素，用 copy 替换层内交界处的 RGBA。结束透明层前恢复 normal，再整体按 source-over 合成到角色上；否则 copy 会清空下方图层，留下矩形缺口。这样避免分段抗锯齿边缘露出背景，也避免透明发丝在重叠处叠深。中性姿态仍直接绘制原图。

四段网格加发根、发梢精确边界即可覆盖当前小幅弯曲。没有新增解码图片；透明合成层使用的临时绘图表面不计入常驻解码缓存。绘制预算仍为 p95 低于 4 ms。

高双马尾的 back hair 与低双马尾的 rear scalp 使用附件级 `maskOut`，在素材准备时清除下巴两侧的短截后发。遮挡多边形使用源画布坐标，仅对两种双马尾生效；马尾主体和原长发不改。处理后的图片随当前外观缓存，保留原 PNG。

`bash scripts/cutout_hair_seam_check.sh` 检查三个发型的 11 个实际头发层和 3 张完整角色、每项 25 帧的不透明覆盖与两处后发排除区域。软件位图检查不能单独证明窗口合成器没有细线，仍须在实际工作台放大检查。

### 对比窗口拖动

对比窗口独立持有 `ProjectOverlays`，不会经过日常 `AppModel.updateMouth` 的交互刷新。角色拖动开始后，对比控制器临时以 60 Hz 推进拖动与回落；回落完成即关闭交互计时器。像素帧原有的 160 ms 动画计时器不变。

回落会让原版回到首帧，因此对比控制器在回落结束后统一重播两版，避免拖动后相位不同。只在对比窗口内处理，不改变日常角色的拖动或像素帧资源。

以下隔离验收调用真实面板的 begin/move/release 回调，记录回落退出、交互计时器回收和思考帧恢复。它不是鼠标实拖证据。

```sh
open -n "dist/development/VibeCute Dev.app" --args \
  --cutout-compare --cutout-drag-smoke-out "$PWD/output/cutout-thinking-sync/native-drag"
```
