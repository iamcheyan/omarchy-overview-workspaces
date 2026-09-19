# Overview Workspaces 变更详情：MRU、工作区指示器与卡死修复

日期：2026-09-19  
范围：`hancore.overview-workspaces` 0.1.10 相关实现

## 1. 用户可见问题

这次变更处理的是一组相互关联、但必须分开建模的问题：

1. Overview 曾经出现卡死，卡死后顶栏和 Overview 一起无响应。
2. 开启 MRU（Most Recently Used）排序后，工作区会根据最近使用顺序移动，顶部数字却仍然被用户理解为固定工作区编号。
3. Win+数字切换后，窗口已经切换成功，但顶部高亮可能仍停留在 1，或者短暂正确后又回到 1。
4. Overview 卡片此前只显示一个数字，缺少背景和说明文字，在窗口缩略图上可读性很差。

## 2. 卡死问题与生命周期修复

### 原因

`OverviewWidget.qml` 原先在 `overviewEntries` 变化时使用：

```qml
onOverviewEntriesChanged: Qt.callLater(root.reconcileFocusedWorkspace)
```

OverviewWidget 会随着 Overview 打开、关闭、模型刷新和插件热加载而创建、销毁。`Qt.callLater()` 持有的是绑定到当前 QML 对象的方法引用；如果对象在回调执行前已经销毁，Quickshell 可能在失效的 QML context 中继续解析方法。现场出现的 `invalid context`、`keyboardSelectedEntry is not a function` 和最终 shell 无响应，与这个生命周期竞态一致。

### 修复

改为由 OverviewWidget 自己拥有的零延迟、非重复 `Timer`：

- 快速连续的模型变化仍然会合并处理；
- Timer 随 OverviewWidget 一起销毁；
- 不会留下指向旧 QML context 的延迟方法引用；
- 不改变工作区选择算法，只改变调度对象的生命周期。

### 验证

- 重新启动干净的 Quickshell 实例后，`omarchy-shell shell ping` 返回 `ok`；
- Overview 的 summon/hide 生命周期验证通过；
- 未再出现 `invalid context`、`keyboardSelectedEntry`、`TypeError`、`fatal` 或 `segfault`；
- 插件热加载期间若出现旧实例错误，需与干净重启实例分开判断，不能把旧实例的排队回调当作新代码回归。

## 3. MRU 与固定编号的产品语义

### 问题本质

MRU 列表位置和 Hyprland 工作区 ID 是两种不同的编号：

- Hyprland 工作区 ID 是真实工作区，例如 1、2、3；
- MRU 视觉槽位是当前排序后的第 1、2、3 项。

开启 MRU 后，工作区 2 可能出现在第 1 个视觉位置，之后又移动到第 2 个位置。因此不能同时把顶部数字解释成“固定工作区 ID”和“动态 MRU 槽位”。

### 最终方案

设置中增加并统一使用 `MRU workspace ordering` 开关：

- **关闭 MRU**：Overview 和顶部 bar 使用固定真实工作区编号；顶部显示 `1 2 3 4 5`，Win+数字保持原生稳定含义。
- **开启 MRU**：Overview 和 Win+数字按最近使用顺序工作；顶部隐藏容易误解的数字，改为显示 `Workspaces`。

切换开关时，Overview 顺序、顶部显示和快捷键行为一起切换，避免出现混合状态。

## 4. 顶部指示器修复

顶部 bar 的高亮判断现在直接使用：

```qml
Hyprland.focusedWorkspace?.id
```

并通过已有的数据刷新序号触发重新计算。这样 MRU 列表即使重新排序，也会用每个按钮携带的真实工作区 ID 与 Hyprland 当前焦点 ID 比较，不会因为数组位置变化而固定高亮 1。

同时保留工作区路由和 Win+数字的既有切换逻辑，没有引入额外 dispatch，也没有让顶部视觉槽位反过来驱动真实工作区焦点。

## 5. Overview 卡片标签视觉改进

每个工作区卡片右上角现在显示圆角标签：

- MRU 模式显示 `Workspace 1`、`Workspace 2` 等当前视觉顺序；
- 固定模式显示真实工作区编号，例如 `Workspace 3`；
- 新工作区显示 `New workspace`；
- 标签位于窗口缩略图之上，保证不会被缩略图覆盖。

标签颜色不再固定写死：

- 当前工作区使用主题 accent 与主题背景混合色；
- 非当前工作区使用主题背景与主题 accent 混合色；
- 边框使用主题 accent 或主题前景/背景混合色；
- 文字直接使用主题前景色；
- 两种状态都使用足够不透明的实色背景，确保文字与缩略图之间有稳定对比度。

## 6. 代码与文档变更

- `OverviewWidget.qml`
  - 用组件内 Timer 替换不安全的 `Qt.callLater`；
  - 统一 MRU 视觉槽位编号计算；
  - 把工作区标签提升到缩略图层之上；
  - 增加主题色圆角 badge 和可读性背景。
- `HyprlandData.qml`
  - 区分 MRU 排序和固定原生编号排序；
  - 缓存 Overview 模型时同步排序模式。
- `SettingsPanel.qml`
  - 提供 MRU 开关，并明确说明两种模式的行为。
- `bar/widget.qml`
  - MRU 模式显示 `Workspaces`；
  - 固定模式显示真实数字；
  - 高亮使用实时 Hyprland 焦点工作区。
- `README.md`
  - 补充 MRU 开关、快捷键语义、更新后重启 shell 的说明。
- `tests/workspace-bar-config.test.js`
  - 增加生命周期 Timer、实时焦点、MRU 标签、主题 badge 的静态回归检查。
- `docs/runtime-hang-2026-09-19.md`
  - 保存卡死现场证据、根因判断和验证记录。
- `docs/workspace-indicator-mru-2026-09-19.md`
  - 保存顶部指示器与 MRU 编号语义的详细分析。

## 7. 验证结果

在插件仓库执行：

```text
npm test                         54 passed, 0 failed
node --test tests/workspace-bar-config.test.js
                                passed
omarchy plugin validate .       passed
git diff --check                passed
```

并重启了当前 Omarchy shell，确认新的插件代码可以被加载。QML 完整 lint 仍会受到命令行缺少 Quickshell/Omarchy import path 的环境警告影响；该警告属于本机 lint 环境，不是本次修改引入的 QML 语法错误。

## 8. 提交边界

本次提交包含 Overview Workspaces 插件仓库中的全部相关实现、测试和文档变更，并由父插件工作区更新对应的 gitlink。其他插件的既有本地修改不纳入本次提交，也不覆盖或重置。
