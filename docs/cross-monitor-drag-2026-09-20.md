# 跨显示器 Overview 拖拽：0.1.11

日期：2026-09-20  
范围：`hancore.overview-workspaces` 的双显示器工作区预览与窗口拖拽

## 用户可见行为

Overview 打开时，每个显示器仍显示自己的工作区预览。窗口可以直接从一个
显示器上的工作区卡片拖到另一个显示器上的工作区卡片，释放后窗口会被移动到
目标工作区，并路由到该工作区所属的显示器。

拖拽跨过屏幕边界时，目标显示器会：

- 高亮指针下的工作区卡片；
- 显示一个跟随指针的窗口代理；
- 在实时缩略图尚未完成抓取时显示应用图标和窗口标题作为后备。

同一显示器内的拖拽、窗口聚焦、中键关闭窗口、`New workspace` 卡片和取消拖拽
行为保持不变。

## 实现方式

每个显示器的 Overview 都是独立的 layer-shell surface。Qt 的
`Drag`/`DropArea` 不能可靠地跨越两个 QML window，因此新增
`CrossMonitorDrag.qml` 单例作为进程内桥接层：

1. 拖拽开始时记录窗口地址、源工作区、源显示器、窗口尺寸和拖拽 generation。
2. 所有显示器上的工作区卡片把自己的命中框发布到共享注册表。
3. 源显示器持续把指针转换为 Hyprland 的全局逻辑坐标。
4. 释放时先读取共享命中结果，再结束 Qt 拖拽，避免 `DropArea.onExited` 清掉
   目标状态。
5. 提交路径同时携带目标工作区所属的显示器名称，不能只依赖 workspace ID，
   因为每个显示器的临时工作区可能使用相同的 ID。

显示器原点也使用逻辑坐标。例如当前机器的 2 号显示器位于 `x=1280`，因此
目标命中框必须使用 `monitorOriginX + localX` 注册；遗漏这个偏移会导致从 1 号
显示器拖向 2 号显示器失效，而反方向看似正常。

异步的窗口预览抓取携带 generation 校验。拖拽结束或开始下一次拖拽后，旧回调
不能重新写入代理图片；结束拖拽时也会释放图片和目标注册表。

## 生命周期与安全边界

- `CrossMonitorDrag` 不安装、卸载或修改任何快捷键。
- 不修改 `KeybindingService.qml`、Super-key guard 或原生 Super+鼠标绑定。
- 插件关闭或 Overview 关闭时清理跨屏拖拽状态。
- 插件生命周期中没有 `hyprctl reload`；原生绑定仍通过精确的 `hyprctl eval`
  管理。

## 验证

- `npm test`：55 passed, 0 failed。
- `omarchy plugin validate .`：通过。
- `git diff --check`：通过。
- 两台显示器已确认在线，且 1 号屏逻辑起点为 `x=0`、2 号屏逻辑起点为
  `x=1280`。
- 修复重复 `onPositionChanged` 导致的 `OverviewWidget unavailable` 后，Shell
  重启、Overview summon/hide 和 IPC ping 均正常。
- 当前机器的双显示器运行态已加载跨屏实现；1→2 单向失效由目标命中框漏加
  `x=1280` 原点确认并修复。两个方向的物理鼠标回归按验证文档第 4 节执行。
