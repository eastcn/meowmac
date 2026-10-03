# 本机样式合同

样式保存在 `~/Library/Application Support/MeowMac/style.json`，所有猫共用。总览条的顺序、显示和额度窗口在猫的布局文件里，不在此文件中。

## 格式

```json
{
  "schemaVersion": 1,
  "quotaBasis": "remaining",
  "email": "full",
  "chartMinutes": 60,
  "colors": {
    "claude": "default",
    "codex": "default",
    "deepseek": "default",
    "opencodego": "default"
  }
}
```

`quotaBasis` 可为 `remaining` 或 `used`，只改数字显示，不改健康判定和原始额度。`email` 可为 `full`、`masked` 或 `hidden`，只改额度页。部分遮罩保留邮箱与域名的首字符，如 `name@example.com` 显示为 `n***@e***`。`chartMinutes` 只能为 `15` 或 `60`，面板临时切换不写回文件。

每个渠道的颜色可为 `default`、`orange`、`blue`、`teal`、`green`、`purple`、`pink` 或 `gray`。默认色沿用现有渠道色；Codex 跟随系统文字色，OpenCode Go 跟随系统灰。固定色的浅色值采用设计稿，深色值按对比度调整：

| 色板 | 浅色 | 深色 |
| --- | --- | --- |
| 橙 | `#D97757` | `#E68C6F` |
| 蓝 | `#4D6BFE` | `#8091FF` |
| 青 | `#1E9E8F` | `#48BAAB` |
| 绿 | `#3F9B4A` | `#65B86D` |
| 紫 | `#8B5CC6` | `#AB83DC` |
| 粉 | `#D6528A` | `#E37BA7` |
| 灰 | `#8E8E93` | `#AAAAAF` |

浅色值对白色、深色值对 `#1E1E1E` 的对比度均不低于 3:1。色板只用于额度进度条、趋势线和渠道标记；风险文案仍使用状态色。

## 读取与保存

缺少文件时用上面的默认值，不创建文件。未知字段、版本、枚举值、渠道，或错误类型会拒绝整个文件并回退默认值，同时记录恢复原因。保存前重读旧文件；旧文件损坏或不安全时拒绝覆盖。文件大小上限为 16 KiB。目录和文件必须是普通目录与普通文件，不跟随符号链接。发布前再次读取目标，拒绝预检后出现的坏文件或符号链接。写入使用同目录独占暂存文件、文件同步和原子替换。写入失败时保留当前生效样式和窗口草稿。
