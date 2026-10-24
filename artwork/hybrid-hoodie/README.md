# 思考动画遮挡补图

源图由内置 imagegen 生成，保留透明背景。它们仅作为原画像素后方的垫图，不替换原版图集。

- `body-underpainting-source.png`：以原版 frame-0-body 和完整工服角色为输入，补齐头发后面的双肩、上袖和短脖子，移除残留头发；要求保留坐姿、衣服、手、裙子、鞋袜与尾巴。生成结果的比例和位置没有完全遵循提示，因此按原画坐标重新注册，只使用上身遮挡补片。
- `chin-underpainting-source.png`：以原版 frame-0-head 和完整角色为输入，补齐刘海后面的额头、抬手后面的下巴；要求保留眼睛和表情、不含头发、耳朵、颈部、手与身体。运行时原版脸部覆盖其上。

打包命令：`swift -module-cache-path .build/clang-cache scripts/artwork/prepare_hybrid_hoodie.swift`。注册参数对应当前两张源图，不能直接用于重新生成的图片。源图修改后需重新核对原生工作台，不能仅依赖覆盖测试。
