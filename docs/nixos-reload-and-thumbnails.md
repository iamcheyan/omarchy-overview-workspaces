# NixOS 插件重载与缩略图故障记录

## 会话卡死的根因

旧版 `KeybindingService.qml` 在插件加载、配置变化和组件销毁时执行 `hyprctl reload`，并通过大量独立的 `hyprctl eval` 子进程安装按键。插件热扫描会销毁并重建 service，因此一次 `rescanPlugins` 可能同时触发：

- Hyprland 配置重载；
- 上百次 Hyprland IPC 调用；
- Overview 全屏 layer 和 screencopy 对象重建；
- 全局 Super+鼠标绑定被重写。

故障现场日志随后出现 `Bad file descriptor` 和 `error in client communication`，应用进程可能仍在运行，但 Hyprland 无法正常分发输入，因此所有窗口表现为卡死。

修复后：

- 插件生命周期不再调用 `hyprctl reload`；
- 加载时把所有绑定合并到一次 `hyprctl eval`；
- 禁用或销毁时只清理插件自己拥有的运行时绑定，并恢复 Super+鼠标移动/缩放绑定，不 reload；
- Overview 打开时暂时拆掉 Super+鼠标移动/缩放，避免拖预览时被底层 Hyprland 抢走。

## NixOS 缩略图兼容

- 移除 NixOS 环境缺失的 `Qt5Compat.GraphicalEffects` 硬依赖。
- 对窗口地址兼容带 `0x` 和不带 `0x` 两种格式（`HyprlandData.normalizeAddress` / `clientByAddress`）。
- 总览关闭时 `captureSource: null`，不保留后台 recording context。
- 总览打开后 `live: true`。

## 工作区变化后的缩略图策略

### 2026-09-05 响应速度优化

- 插件注册只匹配 `quickshell:overview` 的 `no_anim` layer rule，配置重载后随快捷键一起恢复。
- 网格同步创建，取消 Loader 跨帧孵化和信息栏淡入。关闭时仍销毁网格与截图对象，避免恢复隐藏截图树造成的休眠问题。
- Win+Tab 只在实际显示的屏幕创建网格。
- 移除每个窗口 400ms 的定时 `grabToImage`，只在首帧、拖拽和工作区变化时备份，并阻止同一窗口并发备份。
- 保留 `ItemGrabResult` 引用以维持内存图片 URL 的有效性；不能用 `file:` 前缀过滤 Qt 的图片 key。
- 数据刷新按 16ms 合并事件，已有刷新不再被后续事件推迟。首帧仍取决于 compositor 截图，不保证零耗时。

窗口预览是每个 toplevel 一份 `ScreencopyView`，不是整张工作区截图。拖拽或外部移动窗口之后，画面必须立刻出现在目标工作区上，中间不能露出工作区壁纸。

### Quickshell 约束（不要再踩）

`ScreencopyView` 在 `src/wayland/screencopy/view.cpp` 里的行为：

- `setCaptureSource(null)` 会 `destroyContext()`，并把 `hasContent` 清成 `false`。
- `setCaptureSource(同一个 toplevel)` 是空操作，不会重建 context。
- compositor 结束 stream 时发 `stopped`，同样销毁 context、清掉画面。
- `live: true` 只在 `updatePaintNode` 里继续截图；若 `!hasContent` 或 `!context`，paint 直接返回，**不会重试**。
- `captureFrame()` 没有 context 时什么都不做。
- `ShaderEffectSource` 拷不到 Wayland screencopy 纹理。不能靠它做冻帧。

因此：流断了必须换一条 recording context；但清掉当前 `captureSource` 之前，屏幕上必须已经有另一张可见画面。

### 失败过的做法

| 做法 | 结果 |
|---|---|
| 模型 key 做成 `地址\|工作区ID\|截图代数`，搬家后拆掉整个 delegate | 预览销毁，先露出工作区，再重新截 |
| 受影响工作区的所有窗口一起重建 | 没搬家的窗口也被拆掉，全部变图标 |
| 重建后再等 220ms 才 `arm` | 空白时间被故意拉长 |
| 关掉总览或 `visible === false` 时把 `captureSource` 置空 | 最后一帧丢掉，再打开只剩图标 |
| `live` 只开 500ms | 第一帧失败就再也出不来图 |
| 只绑同一个 `ScreencopyView`、流断了不重建 | 画面停在图标上 |

### 现在的做法

1. **模型身份是窗口地址。** `OverviewWidget` 的 ScriptModel 只返回地址。搬家不销毁 `OverviewWindow`，只改位置。
2. **拖拽松手立刻记下目标工作区。** `GlobalStates.setPendingWindowWorkspace(address, targetId)`。在 `hyprctl clients` 还返回旧工作区时，定位已经按目标工作区算。源工作区被 suppress 也不会把窗口从模型里拿掉。
3. **位置用 sticky index。** 新工作区还没进网格时，继续停在上一个有效格子，`visible` 不因此变 `false`。
4. **双路截图。** `preview0` / `preview1`。旧槽还在显示时先 `arm` 新槽；新槽 `hasContent` 后再 `promoteSlot`，关掉旧槽。不要先拆旧的再截新的。
5. **按下拖拽时 `grabToImage`。** 这是实像素备份。旧流断了、新槽还没出帧时，显示这张图，而不是工作区壁纸。`ShaderEffectSource` 不要用来冻 `ScreencopyView`。
6. **`stopped` 只启动另一路，不把当前画面清掉再等。** 看门狗只在两路都没有内容时才补 `arm`。

关键文件：`OverviewWindow.qml`（双槽 + 冻帧）、`OverviewWidget.qml`（地址模型 + pending 定位）、`WorkspaceNavigation.qml`（松手写 pending）、`GlobalStates.qml` / `HyprlandData.qml`（pending 的写入和确认后清除）。

### 以后不要改回去的点

- 不要把工作区 ID 或截图代数编进窗口模型 key。
- 不要在搬家时拆掉还在显示的 `ScreencopyView`。
- 不要用 `ShaderEffectSource` 去冻 Wayland 预览。
- 不要在 `hasContent === false` 时把窗口 `visible` 设成 `false`（会露出工作区卡片）。

## 开发安全规则

开发目录未连接到 `~/.config/omarchy/plugins` 时，只进行离线修改。重新连接前必须确认：

```bash
rg -n 'hyprctl reload' . -g '*.qml'
```

正常结果应为空。不要在 Overview 打开或窗口拖动期间执行插件热扫描。
