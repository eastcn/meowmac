# 提醒规则与通知：系统设计

- 状态：草稿，待用户确认决策点（见同目录 `plan.md`）。
- 日期：2026-10-07
- 范围：把写死在代码里的提醒检测改成“规则”，让内置规则可以查看、调阈值、停用，并允许用户用已采集的指标新建规则。通知开关并入同一处。

## 1. 出发点

用户的三个痛点，以及代码里的对应原因：

| 痛点 | 原因 |
| --- | --- |
| 内存压力阈值没处可调 | 内存提醒不看百分比，看内核离散档位 `kern.memorystatus_vm_pressure_level` 是否为 warn 或 critical，持续 `memoryPressureSeconds`（600 秒）才触发（`EnergyDiagnosis.swift`）。配置里的 `memoryWarnLoad`、`memoryCriticalLoad` 只控制猫的速度，和提醒无关。设置窗口里没有任何阈值（D38）。 |
| 不知道有哪些告警 | 提醒类型 10 种（`ReminderKind`），通知类别 9 种（`NotificationCategory`），阈值 13 个散在 `config.json`。没有一处能看全。 |
| 无法新增告警 | 检测逻辑写死在 `ReminderCollector.collect` 的分支里，没有“规则”这个概念。 |

## 2. 目标与不做

做：

- 设置窗口“通知”栏改名“提醒”，一处列出全部规则：名称、条件、档位、是否启用、是否发通知、当前状态。
- 内置规则可以调阈值和持续时长（规则本身允许时），可以停用。
- 内存规则改为“压力% ≥ 阈值，持续 N 分钟”，与面板显示的压力% 同一口径。
- 用户可以从指标目录里选一个指标，设比较方式、阈值、持续时长和档位，新建规则。
- 自定义规则和内置规则同等对待：进“全部提醒”、影响猫的形态、可发通知，提醒档可限时暂缓。

不做：

- 不引入新数据源，不起子进程，不执行用户脚本。指标只来自已有采集。
- 不做多条件组合（与、或）。一条规则一个指标、一个条件。
- 不改猫的速度映射（D11），`memoryWarnLoad` 等字段保留原用途。
- 不改 TunCanary。网络规则的判定仍来自 TunCanary 的 faults，只能开关，不能调阈值。
- 不保存已恢复的历史（沿用 D40）。

## 3. 概念

```
指标（Metric）──被引用──▶ 规则（AlertRule）──评估──▶ 提醒（Reminder）──▶ 健康档位 / 全部提醒 / 系统通知
                              ▲
                     内置规则表 + 用户覆盖 + 自定义规则
```

- **指标**：一个可读数值，带编号、名称、单位、取值来源和“对象维度”。对象维度决定一条规则会产生几条提醒：系统级指标只有一个对象；额度窗口指标按“渠道 × 窗口”各产生一个对象。
- **规则**：`指标 + 比较（≥ 或 ≤）+ 阈值 + 持续时长 + 档位`，外加启用、通知两个开关。
- **提醒**：沿用现有 `Reminder`。规则命中后生成，id 为 `<规则 id>.<对象>`。

## 4. 指标目录（自定义规则可选）

全部来自现有采集，读不到时为“不可用”，不当作恢复（D40）。

| 指标 id | 名称 | 单位 | 来源 | 对象 | 采样间隔 |
| --- | --- | --- | --- | --- | --- |
| `cpu.usage` | CPU 使用率 | % | `SystemSnapshot.cpuUsage` | 系统 | 2 秒 |
| `memory.pressure` | 内存压力 | % | `memoryPressurePercent` | 系统 | 2 秒 |
| `memory.used` | 内存已用 | % | `memoryUsedFraction` | 系统 | 2 秒 |
| `swap.used` | Swap 已用 | GB | `swapUsedBytes` | 系统 | 2 秒 |
| `disk.free` | 磁盘剩余 | % | `diskRemainingFraction` | 系统 | 2 秒 |
| `disk.freeBytes` | 磁盘剩余 | GB | `diskAvailableBytes` | 系统 | 2 秒 |
| `net.down` | 网络下行 | MB/s | `networkReceivedBytesPerSecond` | 系统 | 2 秒 |
| `net.up` | 网络上行 | MB/s | `networkSentBytesPerSecond` | 系统 | 2 秒 |
| `power.system` | 整机功耗 | W | `battery.systemPowerWatts` | 系统 | 2 秒 |
| `battery.temp` | 电池温度 | °C | `battery.temperatureCelsius` | 系统 | 2 秒 |
| `cpu.temp` | CPU 温度 | °C | `sensors.cpuMaxCelsius` | 系统 | 随传感器 |
| `gpu.temp` | GPU 温度 | °C | `sensors.gpuAverageCelsius` | 系统 | 随传感器 |
| `fan.speed` | 风扇转速 | % 最大值 | `sensors.leadingFan.fraction` | 系统 | 随传感器 |
| `quota.remaining` | 额度窗口剩余 | % | `QuotaWindow.remainingPercent` | 渠道 × 窗口；可限定渠道和窗口 | 随额度刷新 |

不进目录：余额（已在“额度源”里按渠道设阈值，D13）、单进程 CPU（内置“进程 CPU 持续偏高”覆盖）、网络探测结果（来自 TunCanary，只有离散结论）。

## 5. 内置规则表

内置规则 id 固定，用户只能覆盖表中“可调”列的字段。默认值沿用现有行为，内存规则除外。

| 规则 id | 名称 | 条件（默认） | 档位 | 可调 | 可暂缓 | 现有对应 |
| --- | --- | --- | --- | --- | --- | --- |
| `system.memory` | 内存压力持续偏高 | 压力% ≥ **待校准**，持续 10 分钟 | 提醒 | 阈值、时长 | 否 | `memory`，原为内核 warn 档 |
| `system.disk` | 磁盘剩余不足 | 剩余 < 10% | 提醒 | 阈值 | 是 | `disk` |
| `system.process` | 进程 CPU 持续偏高 | 单进程 ≥ 90%，持续 10 分钟 | 提醒 | 阈值、时长 | 否 | `process` |
| `system.thermal` | 系统已降频 | `thermalState` ≥ serious | 提醒 | 无 | 否 | `thermal` |
| `system.cooling` | 建议降温 | fair 持续 5 分钟，或风扇 ≥ 80% 持续 5 分钟 | 标记 | 风扇阈值、两个时长 | 否 | `cooling`，不发通知 |
| `quota.low` | 额度剩余不足 | 任一窗口剩余 < 20% | 提醒 | 阈值 | 是 | `quotaLow`（窗口部分） |
| `quota.balance` | 余额不足 | 每渠道单独阈值 | 提醒 | 在“额度源”栏改 | 是 | `quotaLow`（余额部分） |
| `quota.pace` | 额度偏快 | 预计重置前用完 | 提醒 | 无 | 是 | `quotaPace` |
| `network.fault` | 网络故障 | TunCanary 判定 | 严重或提醒 | 无 | 否 | `network` |
| `network.egress` | 出口 IP 变化 | TunCanary 事件 | 只通知 | 无 | — | 通知类别 `egress` |
| `source.failure` | 数据源失效 | 连续 2 次失败 | 提醒 | 次数 | 是 | `source` |

“可调”之外的字段在界面上只读显示，保证用户能看全每条规则的真实条件。

## 6. 规则评估

### 6.1 新增的纯逻辑（`MeowMacCore`）

- `AlertMetric`：指标目录，静态表。提供 `read(_ inputs: HealthInputs) -> [MetricReading]`，每个读数带对象、数值和采样时间；读不到返回空。
- `AlertRule`：规则定义，`Codable`。
- `AlertRuleSet`：内置规则表 + 用户覆盖 + 自定义规则，合并出生效规则列表，并负责校验（阈值范围、时长 0～24 小时、名称非空、自定义规则最多 32 条）。
- `RuleClock`：有状态，记录每个“规则 × 对象”的条件成立起点 `since`。每次系统采样（2 秒）更新一次。规则同 `EnergyTracker` 的现有做法：
  - 条件成立且 `since` 为空，记为当前时刻；条件不成立（有效读数）清空。
  - 读不到数值时保留 `since`，既不确认也不推翻。
  - 两次有效采样相隔超过该指标采样间隔的 2.5 倍（休眠、唤醒）时清空，避免把休眠算进“持续”。
- `ReminderCollector.collect` 拆分：内置规则逐条迁移为规则评估，再加上自定义规则。输出仍是 `ReminderBatch`，`ReminderTracker`、暂缓和 `NotificationDecider` 不改接口。

### 6.2 自定义规则生成的提醒

- `ReminderKind` 新增 `custom`。提醒 id 为 `custom.<规则 id>.<对象>`，规则 id 形如 `u-<8 位小写十六进制>`，满足现有暂缓键的字符集和长度限制。
- 档位由规则决定。提醒档允许暂缓，严重档不允许（D40）。
- 标签页：系统级指标归系统页，额度指标归额度页。
- 有效读数且条件不成立，算该对象“确认恢复”。
- 标题用规则名称，详情写“当前值、阈值、已持续”，例如“Swap 已用 6.2 GB，超过 4 GB · 已持续 12 分钟”。通知正文同样具体（D41）。
- 规则被停用或删除：对应提醒直接移除，暂缓记录和通知记录一并清掉，不当作“恢复后重现”。

### 6.3 内存规则的口径变化

- 原口径：内核档位 warn 或 critical 持续 10 分钟。
- 新口径：压力% ≥ 阈值，持续 10 分钟。压力% 是 100 减 `kern.memorystatus_level`，与总览和系统页显示的数字相同。
- 默认阈值需要实机校准：执行时在本机同时采样两个值，记录内核从 normal 进入 warn 时压力% 的取值范围，取其下沿附近的整数。原值写到 `build/acceptance/`，result 只写结论。校准前的占位值为 70%。
- 猫的速度（D11）仍用内核档位换算，不受影响。

## 7. 存储

| 内容 | 位置 | 依据 |
| --- | --- | --- |
| 内置规则覆盖、自定义规则 | `config.json` 的 `alertRules` 字段 | D15：判定规则写在统一的本机配置里 |
| 每条规则的“发通知”开关、总开关 | `notifications.json` | D41：通知开关是本机设置，不提供配置文件编辑入口 |
| 暂缓记录 | `reminder-snoozes.json`，不变 | D40 |

`config.json` 新增字段的形状：

```json
{
  "alertRules": {
    "builtin": {
      "system.memory": { "enabled": true, "threshold": 70, "durationSeconds": 600 },
      "system.disk": { "threshold": 10 }
    },
    "custom": [
      {
        "id": "u-3fa91c02",
        "name": "Swap 偏高",
        "metric": "swap.used",
        "comparison": "gte",
        "threshold": 4,
        "durationSeconds": 300,
        "level": "warn",
        "enabled": true,
        "scope": null
      }
    ]
  }
}
```

- 只写和默认值不同的字段。缺字段用默认值。
- 旧的标量字段（`memoryPressureSeconds`、`diskRemainingWarn`、`quotaRemainingWarn`、`runawayCPU`、`runawaySeconds`、`fairThermalSeconds`、`fanHighFraction`、`fanHighSeconds`、`sourceFailureCount`）继续可读：`alertRules.builtin` 里没有对应字段时，用旧字段的值；界面保存只写新字段。百分比统一按 0～100 存。
- `notifications.json` 由“类别集合”迁移为“规则 id → 是否通知”。旧类别按下表映射，读到旧格式时自动转换并在下次保存时写新格式：`network`→`network.fault`，`egress`→`network.egress`，`quotaLow`→`quota.low` 和 `quota.balance`，`quotaPace`→`quota.pace`，`disk`→`system.disk`，`process`→`system.process`，`memory`→`system.memory`，`thermal`→`system.thermal`，`source`→`source.failure`。
- 自定义规则的“发通知”默认开。
- 保存沿用 `ConfigStore.saveField` 的合并写法，保留其他字段和未知字段。坏文件不覆盖，回退到默认规则，并在“提醒”栏顶部显示恢复说明。

## 8. 界面：设置 → 提醒

“通知”栏改名“提醒”，图标不变。更改立即生效（与原通知栏一致）；阈值和时长的输入框在失焦或回车时校验并保存，越界时留在原值并就地提示。

结构自上而下：

1. **系统通知**：授权状态横幅（未授权时）、“发送系统通知”总开关。总开关只管通知，不影响检测。
2. **规则列表**，按系统、额度、网络、数据源分组。每行：
   - 左：启用开关、规则名、条件摘要（例如“压力 ≥ 70%，持续 10 分钟”）、档位标签。
   - 右：当前状态（正常 / 触发中 / 已暂缓 / 读不到 / 已停用）、通知铃铛开关。
   - 点开一行展开编辑：可调字段用数字框加单位；不可调字段只读显示。
3. **自定义规则**：分组末尾“＋ 新建规则”。表单：名称、指标（下拉，按分组）、对象（仅额度指标：渠道、窗口，默认“任一”）、比较、阈值（带单位）、持续时长、档位、发通知。表单下方实时显示“当前值”，帮助选阈值。自定义规则行可编辑和删除，删除需确认。
4. **恢复默认**：栏底按钮，只恢复内置规则的阈值、时长和启用状态，不删自定义规则。

视觉沿用统一设置窗口的现有样式。具体版式以设计稿 `docs/design/mockups/alert-rules.html` 为准（2026-10-07 草稿，待用户定稿）。

## 9. 和受保护决策的关系

需要用户修订 `docs/DECISIONS.md`，草案见同目录 `decision-update.md`：

- D13、D14：内存规则改用压力% 阈值；规则可调、可停用；新增自定义规则。
- D38：提醒阈值可以在设置界面修改。
- D41：通知范围由固定类别改为“每条规则一个开关”，包含自定义规则；开关迁移规则。

决策修订落地前，执行者不实现第 9 节涉及的行为。

## 10. 风险

| 风险 | 应对 |
| --- | --- |
| 内存新口径误报或漏报 | 实机校准默认值；result 记录校准结论；用户可调 |
| 2 秒一次评估所有规则带来 CPU 开销 | 规则数上限 32；评估只做比较，不分配大对象；性能排查（ROADMAP 优先级 1）一并测 |
| 用户停用了严重的网络规则后看不到故障 | 停用的规则在列表中明确显示“已停用”；网络页的风险色和原始数据照常显示（D40） |
| 旧配置迁移出错 | 迁移用纯函数，夹具覆盖：只有旧字段、只有新字段、两者都有、坏值、未知指标 id |
| 自定义规则引用的指标以后被删除 | 规则保留但标为“指标不可用”，不触发、不报错 |
