# `.cat` 帧图合同 v1

## 状态与范围

2026-10-02 的第一轮实现合同，用户已采纳全部推荐。四版动作和睡姿设计已确认。此版本只包含菜单栏帧图；面板布局和样式另开轮次。

一只猫是以 `.cat` 结尾的普通目录。目录中只有 `manifest.json`、跑步 PNG 和严重状态 PNG。本轮导入目录，不导入压缩包，不提供删除、覆盖或导出入口。

## 清单

```json
{
  "schemaVersion": 1,
  "id": "example-cat",
  "name": "示例猫",
  "run": {
    "image": "run.png",
    "rendering": "template",
    "sheetSize": [2172, 724],
    "canvas": [451, 191],
    "noseAnchor": 411,
    "topPadding": 4,
    "frames": [
      {"source": [22, 275, 443, 187], "noseX": 429},
      {"source": [489, 275, 398, 187], "noseX": 885},
      {"source": [924, 275, 330, 187], "noseX": 1249},
      {"source": [1301, 275, 368, 187], "noseX": 1667},
      {"source": [1728, 275, 417, 187], "noseX": 2125}
    ]
  },
  "severe": {
    "image": "severe.png",
    "sheetSize": [1816, 866],
    "bounds": [464, 266, 1000, 383],
    "zzAnchorFraction": 0.83
  }
}
```

上例的坐标来自已确认的瘦身素材。`source`、`bounds` 均为 `[x, y, width, height]`，原点在 PNG 左上角。`noseX` 是原图中头部前缘的横坐标。画布、锚点和留白统一用于所有跑步帧，不能逐帧拉伸。

`rendering` 只有 `template` 和 `original` 两个值。单色猫正常时用模板，随菜单栏外观变化；彩色猫正常时保留原色。提醒和严重都由应用使用透明轮廓统一着色。

## 校验

- `schemaVersion` 只接受 `1`。所有对象严格检查允许字段；未知字段、健康规则、刷新策略、数据源、脚本和凭据字段均拒绝，不静默忽略。
- `id` 匹配 `[a-z0-9][a-z0-9._-]{0,63}`；`builtin.` 前缀只给内置猫。名称去掉首尾空白后为 1～40 个字符，不包含控制字符。
- 清单不超过 64 KiB。每张 PNG 不超过 8 MiB，单包不超过 20 MiB。目录最多这 3 个普通文件，不接受额外文件或子目录。
- 文件名是根目录中的单个 `.png` 文件名。拒绝绝对路径、斜杠、反斜杠、空名、`.` 和 `..`。两张图允许使用同一文件时，目录可以只有 2 个文件；总量按实际文件计。
- 包根和包内文件不得是符号链接。用 `O_DIRECTORY | O_NOFOLLOW` 打开根目录，用 `openat` 与 `O_NOFOLLOW` 打开文件。用 `fstat` 确认普通文件和大小后读取字节；校验和复制复用这些字节，不重新跟随源路径。导入只写受管理目录中的本次暂存目录。
- 图片类型必须是 PNG。解码前读取 ImageIO 属性；每边不超过 4096 px，总像素不超过 8,388,608。属性尺寸必须与 `sheetSize` 一致，并含 alpha。拒绝损坏、尺寸不符、无透明像素的图片。
- 必须恰好有 5 个跑步帧。所有数值有限；像素坐标、尺寸、画布、`noseX`、`noseAnchor` 和 `topPadding` 为整数。尺寸为正，坐标和间距非负；取帧矩形不得越界，取出的帧不得全透明。`noseX` 位于对应取帧横向范围内。
- 跑步帧采用相同的垂直取帧范围。横向取帧范围不得重叠。共同画布、锚点和偏移必须使所有帧完整落入 50×18 pt 输出区域；超出时拒绝，不能自动裁掉爪或尾巴。
- 严重图的 `bounds` 不越界且不全透明；`zzAnchorFraction` 在 0～1 之间。严重姿态由图决定，颜色、停止规则和 zz 由应用决定。

限额是本轮规划推荐，用户已采纳。它们覆盖四版现有源图，给导入和图片解码设上限。失败时返回具体的中文错误，不导入部分内容。

## 显示

输出透明画布固定为 50×18 pt。绘制公式与已确认浏览器样稿一致：

- 跑步：`padding = height / 18`，`scale = (height - padding) / canvasHeight`；共同画布水平居中。每帧按 `noseAnchor - (noseX - sourceX)` 平移，纵向位置为 `topPadding × scale`。
- 严重：按宽度减去 `4 × padding` 和高度的 `0.62` 倍共同约束缩放。底部在输出高度的 `0.93` 倍处；zz 在顶部 `0.02` 倍处，水平位置按 `zzAnchorFraction` 计算。只做等比缩放。
- 正常单色为模板；正常彩色为原色。提醒整只猫为 `systemOrange`；严重整只猫与 zz 为 `systemRed`。
- 真实负载不低于 70% 时，正常和提醒显示三道速度线。模板猫的线随外观变化；彩色猫的线使用 `labelColor`，保持深浅色可读。
- 速度由本机配置和真实负载决定，不放进猫包。严重完全静止，减少动态效果时正常和提醒定格第 1 帧。

## 内置映射

| id | 名称 | 正常渲染 | 跑步源与定位 | 严重源与定位 |
| --- | --- | --- | --- | --- |
| `builtin.slim` | 标准瘦身 | `template` | `slim-run-sheet-v2.png`、`slim-run-v2-layout.json` | `slim-severe-v6.png`、`slim-severe-v6-layout.json` |
| `builtin.round` | 圆润 | `template` | `round-run-sheet-v1.png`、`round-run-v1-layout.json` | `round-severe-v1.png`、`round-severe-v1-layout.json` |
| `builtin.american` | 圆润美短 | `original` | `american-run-sheet-v2.png`、`american-run-v2-layout.json` | 复用圆润严重源 |
| `builtin.orange-white` | 瘦身橘白 | `original` | `orange-white-run-sheet-v2.png`、`orange-white-run-v2-layout.json` | 复用瘦身严重源 |

源与定位位于 `docs/design/cat/animation/`。运行包由执行者复制已确认 PNG 并生成清单，放在 `Sources/MeowMacUI/Resources/Cats/`。不把过程稿或真实照片放进应用。应用使用 `Bundle.module` 定位资源。

## 保存与恢复

导入副本位于 `~/Library/Application Support/MeowMac/Cats/<id>.cat/`。不引用外部源目录，因此移动或删除导入源不会影响显示。

受管理目标同样拒绝符号链接。打开应用根、Cats 和暂存目录时，逐级使用无符号链接的目录句柄。文件创建、选择写入和发布通过相应目录句柄完成，不用拼出的绝对路径重新打开目标。选择文件读取也使用 `O_NOFOLLOW`；已有同名符号链接不得作为覆盖目标。测试须覆盖应用根、Cats、选择文件和暂存节点的符号链接，确认包外文件未改变。

包发布使用 `renameatx_np(..., RENAME_EXCL)`，在固定父目录中原子移动且不覆盖同名目标。文件系统不支持时拒绝导入，不退回普通 `renameat`。预检后出现的同名目录、文件或符号链接也须保持原样。选择文件按独立的原子替换规则保存，允许替换此前的普通选择文件。

当前选择单独保存到同目录上一级的 `cat-selection.json`，只写 `schemaVersion: 1` 和 `selectedID`。本轮不改写 `config.json`，不保存外部源路径。

导入先读取并校验全部字节，在受管理目录暂存，再验证副本并原子发布。相同 id 或保留 id 拒绝，不覆盖现有猫。选择文件原子写入成功后，才发布内存中的当前猫并更新菜单栏。选择保存失败时，保留此前选择和画面；导入失败不留下半包。

包已发布、选择保存失败时，保留这个完整的导入包，提示“已导入，切换未保存”。菜单可再次选择它。暂存失败时只清理本次暂存目录，不删除现有猫。

首次启动无选择文件时使用标准瘦身。选择文件损坏、所选猫丢失或无效时回到标准瘦身，并记录原因；不自动覆写坏文件。切换时只加载一次图片，逐帧播放不做文件 I/O。

导入与切换串行执行。重启、慢解码和连续点击不得让旧请求覆盖新选择。失败只报告猫配置问题，不改变系统、额度或网络健康判定。
