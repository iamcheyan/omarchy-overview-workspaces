# 全仓审查与修改计划

日期：2026-09-05
审查对象：`hancore.overview-workspaces` 整仓（HEAD 当时为 `34966c9` / manifest `0.1.5`）
平台：Omarchy on Arch（`/usr/share/omarchy`）与 NixOS Omarchy（`$OMARCHY_PATH` 为 nix store）必须共用同一套代码。

本文是审查结论和后续改动的对照文档，方便回溯。修改按文末「实施顺序」进行；缩略图双槽 / `ScreencopyView` 策略不在本次范围内。

## 总体判断

这是一个能用的 Overview 插件：全屏工作区网格、`ScreencopyView` 实时预览、拖拽搬家、单独 Win 开 Overview、Win+Tab MRU、Overview 内搜应用/窗口/菜单。商店那次 `AutoText` 注入已经堵住（`StyledText` 固定 `Text.PlainText`）。NixOS 上卡死会话的路径也不在 QML 里：没有 `hyprctl reload`，绑定是一次 `hyprctl eval`，数据刷新 16ms 合并。

上一轮移植留下的问题是「症状修了、生命周期没做完」：NixOS 卡死修好了，Hyprland 绑定所有权和系统原生排序模型是半截的。文档仍在描述已经不存在或从未实现的行为。

## 问题

### Bug 1 — 系统原生模式下 Win+1…0 被拆掉且永不恢复

文件：`KeybindingService.qml`

Omarchy 原生绑定在 `$OMARCHY_PATH/default/hypr/bindings/tiling.lua`：

```lua
for workspace = 1, 10 do
  local key = "code:" .. tostring(workspace + 9)
  o.bind("SUPER + " .. key, "Switch to workspace " .. workspace, hl.dsp.focus({ workspace = tostring(workspace) }))
end
o.bind("SUPER + TAB", "Next workspace", hl.dsp.focus({ workspace = "e+1" }))
o.bind("SUPER + SHIFT + TAB", "Previous workspace", hl.dsp.focus({ workspace = "e-1" }))
```

插件的 `bindingScript()` 无论哪种模式都会 `hl.unbind("SUPER + code:10")`…`code:19`，却只在优化排序（`legacy`）里重新 bind 到 `workspaceSlotN`。切到系统原生排序后，Win+数字没有 dispatcher。README 写「Native Win+number behavior is restored」，代码没有做到。

禁用/卸载更差：

- `restoreBindings()` 只拆插件自己的键，再把 Super+鼠标加回去，不恢复 Win+数字，也不恢复原生 `SUPER + TAB`
- 没有 `Component.onDestruction`
- README 仍写禁用时会 `hyprctl reload` 以恢复用户持久绑定；QML 里已经刻意去掉 reload

加载和 rescan **仍然不要** `hyprctl reload`（这是 NixOS 卡死的根因）。恢复必须用一次 `hyprctl eval` 把原生绑定写回去。

**改法：**

- 优化模式：unbind 后 bind `quickshell:workspaceSlotN`
- 系统模式：unbind 后立刻按 `tiling.lua` 原样 bind `hl.dsp.focus({ workspace = N })`
- `restoreBindings()` / `Component.onDestruction`：拆插件的 Super 单独键、interrupt、slot；恢复原生 Win+数字、Win+Tab、Super+鼠标
- 不把绑定写进 `~/.config/hypr/bindings.lua`

### Bug 2 — 系统原生排序没有按显示器过滤

文件：`HyprlandData.qml` `overviewWorkspaceEntriesForMonitor`

优化排序会按 `workspaceMonitorName === targetMonitor` 过滤。系统模式把 `systemWorkspaceIds()`（永远 1–10，外加真实存在的 11+）原样塞进网格，没有显示器过滤。

默认 `overviewPerMonitor: true` 时，别的屏幕上的工作区会漏进当前屏。关掉 per-monitor 后，`overviewWorkspaceEntriesGroupedByMonitor()` 会给每块屏各拼一份 1–10，同一 id 出现多次，键盘导航按 id 查找永远命中第一个。

**改法：**

- 活着的工作区：`targetMonitor` 有值时，只保留 `workspaceMonitorName` 匹配的
- 不存在的 1–10 空槽：只在「单屏条」里显示（per-monitor overlay / 全局一次），不要在多屏分组里每块屏复制一份
- 多屏分组：每组只放真正在该屏上的工作区 + 该屏的 New workspace

给 `overviewWorkspaceEntriesForMonitor` 增加 `includeEmptySystemSlots`（第 5 个参数）：

| 调用点 | includeEmptySystemSlots | 含义 |
|---|---|---|
| 单屏 overlay / 顶栏同源网格 | true | 像原生条一样显示 1–10，但排除住在别的屏上的 id |
| 多屏分组总览 | false | 只显示该屏真实工作区 |
| Win+Tab MRU | false | 只走有窗口的 + trailing |
| 全局（无显示器名） | true | 1–10 只出现一次 |

### Bug 3 — 「新工作区」跨屏共用同一个 id

文件：`HyprlandData.qml`

`overviewWorkspaceEntriesForMonitor(monitorName, appendTrailing, reservedWorkspaceIds, …)` 收了 `reservedWorkspaceIds` 和 `appendTrailing`，函数体完全不用。每个显示器各自 `allocateId`，多屏总览里每张 New workspace 卡会拿到同一个 id。

**改法：**

- 真正使用 `appendTrailing`：为 false 时不追加 trailing
- 分配 trailing id 之后写入共享的 `reservedWorkspaceIds`，下一屏跳过
- `allocateSystemTrailingWorkspaceId` 同样尊重 reserved
- 系统模式下 used set 已经包含 1–10 时，trailing 落在 11+ 是正确行为（空的 6–10 已经作为格子显示，不能再当 New workspace）。只改过期注释，不改成复用 6–10

键盘焦点继续按 workspace id。trailing id 跨屏唯一之后，id 不再碰撞。

### Suggestion 4 — hyprctl JSON 无 try/catch

文件：`HyprlandData.qml`

`getClients` / `getMonitors` / `getWorkspaces` 只挡了空文本。`getActiveWindow` 有 try/catch。hyprctl 输出截断时会抛，pending 窗口结算和 `markDataChanged` 会停。

**改法：** 与 `getActiveWindow` 一样包起来，失败时保留上一份列表并 `console.warn` 一次。

### Suggestion 5 — 版本号不一致

- `SettingsPanel.qml` 写死 `pluginVersion: "0.1.3"`
- `manifest.json` 为 `0.1.5`
- README changelog 停在 0.1.3

本次会改真实 bug，manifest 升到 `0.1.7`，齿轮面板和 README 锁到同一数字。

### Suggestion 6 — README 的 qmllint 路径只适用于 Arch

`qmllint -I /usr/share/omarchy/shell` 在 NixOS 上不存在。应使用 `-I "$OMARCHY_PATH/shell"`，Arch 默认只作为 fallback 说明。

### Suggestion 7 — 运行时注释在讲迁移史

`KeybindingService.qml`、`AppSearch.qml`、`Overview.qml`、`WorkspaceOrder.qml` 里有「旧实现 spawn 了一百个子进程」「这曾经是返回 [] 的 stub」「Sumika 的 IPC」这类注释。保留仍成立的不变量（例如「一次 hyprctl eval，创建/销毁时不要 reload」），迁移说明只留在 `docs/`。

### Nit 8 — 缺字段会打崩 occupancy

`hyprlandClientsForWorkspace` 使用 `win.workspace.id` 没有 `?.`。改为 `win?.workspace?.id === workspace`。

### 文档与 README 对不上的行为

- README：应用没有图标时，不会在缩略图上覆盖通用图标。`OverviewWindow.qml` 在 `iconPath` 为空时仍会叠 Nerd `apps`。无预览、无冻帧时才显示通用图标。
- `docs/nixos-reload-and-thumbnails.md` 写「Overview 不再修改全局 Super+鼠标绑定」。`applyMouseGuard()` 仍会改。打开 Overview 时挡住 Super+鼠标是对的（否则拖预览会拖到底下的真窗口）；文档改成与代码一致，不删这个行为。
- `docs/marketplace-review-notes.md` 仍写「无测试目录」；`tests/` 已存在。

## NixOS 与 Omarchy（Arch）

两边已经对齐、本机 NixOS 核对过的：

| 能力 | 做法 | NixOS | Arch |
|---|---|---|---|
| 菜单 / `launcher.hides` | `$OMARCHY_PATH`，fallback `/usr/share/omarchy` | nix store | `/usr/share/omarchy` |
| 菜单 JS | 自带 `MenuIndex.js`，不静态 import Omarchy 的 `MenuModel.js` | 否则整个插件加载失败 | 也能用 |
| 启动应用 | `uwsm-app -- gtk-launch <id>.desktop` | PATH 上有 | 与 AppLibrary 相同 |
| `>command` | `xdg-terminal-exec` | PATH 上有 | `omarchy-base` 提供 |
| 缩略图 | 无 `Qt5Compat.GraphicalEffects`；地址兼容 `0x` | 已修 | 已修 |
| 壁纸 | `~/.local/state/omarchy/current/background` | 布局相同 | 布局相同 |
| 绑定安装 | 一次 `hyprctl eval`，QML 里无 `hyprctl reload` | 不再卡死 | 同样 |

还没对齐、本次要处理的：

- README qmllint 写死 Arch 路径
- 系统模式 Win+数字在两边都坏（Bug 1），NixOS 没有 `/usr/share/omarchy` 当退路
- Super+鼠标在 Overview 打开时仍改写，两边一样，只改文档
- `SUMIKA_APP_DIR` / `SUMIKA_OVERVIEW_WARM` 两边都不会设，删掉选举和 env 门闩

商店注入面：hyprctl 标题/类名都走 `StyledText`（PlainText）。设置面板里的裸 `Text` 只有插件自己的文案。此项保持，不回退。

## 上一轮留下的残骸（本次清理）

运行路径上的壳层：

- `GlobalStates.qml`：剪贴板 / OSD / 锁屏 / 会话确认 / `barPopup` / `requestSessionConfirm()`，插件不用
- `WorkspaceOrder.qml`：`SUMIKA_APP_DIR` 写者选举。改为本插件始终写自己的 state
- `GlobalStates.qml`：`SUMIKA_OVERVIEW_WARM`。`overviewWarmStart` 默认 false，去掉 env 和 3 秒 timer
- `Appearance.qml`：animation `createObject()` 返回 null 的空壳

死代码：

- `ModuleLoader.overviewProviders` 永远 `[]`，`OverviewWidget` 仍为它建 Repeater → 删 Repeater 和 `ModuleLoader.qml`
- `Persistent.qml` 只被未使用的 `OverviewWindow.perfMode` 读取 → 删属性、singleton、文件
- `MaterialSymbol.qml` 从未实例化 → 从 `qmldir` 去掉并删文件
- `Config.arbitraryRaceConditionDelay`、`workspaceGroupBase`、`biggestWindowForWorkspace`、`restrictToWorkspace`、`indicateXWayland`
- `Overview.qml` 传给网格的 `searchQuery` 永远是 `""` → 去掉网格内搜索过滤（搜索只走 overlay）
- `OverviewSearch.menuOpen` 从未为 true
- Slot badge `visible: false`；注释掉的 `console.log`；注释掉的 focused-monitor 排序
- `qmldir` 把 `OverviewSwitchingController` 和 `WorkspaceNavigation` 同时注册成 singleton 和非 singleton → 只保留 singleton
- `NerdIcon` 里已删会话菜单的 `logout` / `refresh` / `power_settings_new`

不改：

- 双槽 screencopy、`grabToImage` 冻帧、地址模型 key、pending 搬家
- 菜单 `when:` 的单次 `bash -lc` 批跑
- `uwsm-app` / `gtk-launch` / `xdg-terminal-exec` / `$OMARCHY_PATH` 这一套启动路径

## 实施顺序

1. **快捷键所有权**（Bug 1）— `KeybindingService.qml`，并改 README 里「禁用会 reload Hyprland」的过时说法
2. **系统排序 + trailing id**（Bug 2、3）— `HyprlandData.qml` 及调用点
3. **安全与版本**（Suggestion 4–6、Nit 8）— JSON.parse、可选链、manifest `0.1.6`、齿轮面板、README changelog 与 qmllint
4. **残骸清理**（Suggestion 7 + 清单）— 死状态、空 stub、未用文件、文档与代码对齐（含通用图标、Super+鼠标文档、测试目录）

## 验证

```sh
node --test
omarchy plugin validate .
qmllint -I "$OMARCHY_PATH/shell" \
  Overview.qml OverviewWidget.qml OverviewWindow.qml \
  SettingsPanel.qml KeybindingService.qml bar/widget.qml
```

手工：优化模式 Win+1 走视觉槽；系统模式 Win+1 走原生工作区 1；禁用插件后 Win+1 和 Win+Tab 回到 `tiling.lua`；多屏系统模式下别的屏的窗口不出现在当前屏 overlay。

## 实施状态（2026-09-05）

已按上面的顺序改完，版本 `0.1.7`。

| 项 | 结果 |
|---|---|
| Bug 1 快捷键所有权 | `KeybindingService.qml`：系统模式恢复原生 Win+数字；禁用/销毁时 eval 恢复 Win+数字、Win+Tab、Super+鼠标；无 `hyprctl reload` |
| Bug 2 系统排序按屏过滤 | `HyprlandData.qml` + 调用点：`includeEmptySystemSlots`；活工作区按显示器过滤 |
| Bug 3 trailing id | 共享 `reservedWorkspaceIds`；`appendTrailing` 生效 |
| Suggestion 4 JSON.parse | clients/monitors/workspaces 与 activewindow 一样 try/catch |
| Suggestion 5 版本 | manifest / SettingsPanel / README 均为 0.1.7 |
| Suggestion 6 qmllint | README 使用 `$OMARCHY_PATH/shell` |
| Suggestion 7 迁移注释 | 运行时只留不变量 |
| Nit 8 可选链 | `win?.workspace?.id` |
| 残骸 | 删除 `ModuleLoader.qml`、`Persistent.qml`、`MaterialSymbol.qml`；空 animation / 死搜索过滤 / 隐藏 Slot badge。**`GlobalStates.qml` 的 Sumika 字段清理已撤回**：去掉 `import Quickshell` 后 `Singleton is not a type`，整个插件无法加载；热重载会缓存失败模块，必须 `omarchy restart shell` |
| 文档 | `docs/nixos-reload-and-thumbnails.md`、`docs/marketplace-review-notes.md`、README 三语与代码对齐 |

未改：双槽 screencopy、地址模型 key、pending 搬家、`uwsm-app` / `xdg-terminal-exec` / `$OMARCHY_PATH` 启动路径。
