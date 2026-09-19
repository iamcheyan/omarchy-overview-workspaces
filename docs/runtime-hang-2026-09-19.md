# Overview 卡死运行日志：2026-09-19

## 现象

Overview 打开后不能使用，随后顶栏和 Overview 一起无响应。Hyprland 本身仍然正常，窗口仍可由 Hyprland 管理。

## 现场证据

时间均为 JST（Asia/Tokyo）：

- 10:22:34，Quickshell 输出：
  - `QQmlVMEMetaObject: Internal error - attempted to evaluate a function in an invalid context`
  - `OverviewWidget.qml[485]: TypeError: Property 'keyboardSelectedEntry' ... is not a function`
- 10:23:22，桌面服务报告 `Disabling unresponsive app with pid 2185`。
- 10:24 左右，`omarchy-shell shell ping` 返回 `omarchy-shell is not responding`。
- Quickshell PID 2185 仍存在，`omarchy-bar` layer 还在，但 `quickshell:overview` 无法正常通过 IPC summon。
- `omarchy restart shell` 无法接管旧进程，并报告已有实例在运行。

## 排除项

- Overview 插件仍在 `~/.config/omarchy/shell.json` 中启用。
- Hyprland 中 Overview 的 Super、Tab、数字 workspace bindings 仍存在。
- 插件仓库工作树没有未提交的 Overview 源码修改；最近提交 `d2456e7` 的相关变更没有修改 `keyboardSelectedEntry()` 的实现。
- icon 缺失和 xdg-desktop-portal 的 ScreenSaver warning 与本次卡死无直接关系。
- shell 重启后单独 summon/hide Overview 可以成功，且 shell ping 保持正常。

## 根因判断

`OverviewWidget.qml:536` 原先使用：

```qml
onOverviewEntriesChanged: Qt.callLater(root.reconcileFocusedWorkspace)
```

OverviewWidget 会随着 overlay 的打开/关闭、模型刷新和插件热加载反复创建和销毁。`Qt.callLater()` 接收的是一个绑定到 `root` 的方法引用；如果 Item 在回调执行前被销毁，Quickshell 仍可能尝试在已经失效的 QML context 中解析该方法。现场的 `invalid context` 与随后 `keyboardSelectedEntry is not a function` 正好符合这一生命周期竞态。

因为 Omarchy bar、Overview、通知等都运行在同一个长期存活的 Quickshell 进程中，这个未处理的 QML 延迟回调错误会拖住共享事件循环，表现为整个 shell 卡死，而不只是 Overview 关闭。

## 修复

将 `Qt.callLater(root.reconcileFocusedWorkspace)` 替换为组件内部的零延迟、非重复 `Timer`：

- rapid model revisions 仍会被合并；
- Timer 属于当前 OverviewWidget；
- Widget 销毁时 Timer 一并销毁，不会留下对旧 QML context 的方法引用；
- 不改变工作区选择逻辑，只改变延迟调度的生命周期管理。

## 验证记录

修复后执行：

1. `node --test`：通过（51 tests）。
2. 插件静态校验和 `qmllint`：待本次验证补录。
3. 重启 shell 后 `omarchy-shell shell ping`：`ok`。
4. `omarchy-shell shell summon hancore.overview-workspaces '{}'`：`ok`。
5. `hyprctl layers`：出现 `quickshell:overview` layer。
6. hide Overview 后 shell ping：`ok`。
7. 修复后的日志窗口内未再次出现 `invalid context`、`keyboardSelectedEntry` 或 `TypeError`。

## 第二次卡死：修复文件触发热加载

本次修复保存后又出现一次卡死。第二次现场与第一次不同：

- Quickshell PID 241912 存在但 CPU 约 34%，`omarchy-shell shell ping` 超时。
- journal 只记录了 `Local plugin changed, reloading: hancore.overview-workspaces`，没有再次出现 `keyboardSelectedEntry` 或 `TypeError`。
- shell 随后记录 `Disabling unresponsive app with pid 241912`。
- `/nix/store/.../shell/shell.qml` 显示本机 shell 的插件重载流程会先卸载 panel/service/widget，再通过 `Qt.callLater(shell.finishPluginReload)` 扫描并重建插件。

因此第二次卡死是插件热加载路径本身的竞态，不能证明 Timer 修复失败。它发生在“保存插件文件 → shell 自动卸载/重建整个插件”期间，且插件包含一个 `keepLoaded` service、bar widget 和全屏 panel；这三个对象会在同一轮 reload 中同时拆装。开发文档原本也规定：不要在 Overview 打开或拖拽期间热扫描，更新启用的 `keepLoaded` 插件后应完整重启 shell。

本次修复后的运行验证必须先结束这个热加载实例，再由 launcher 自动启动干净的 Quickshell；不能把热加载失败误归因到新的 Overview 逻辑。

## 干净实例验证结果

终止卡住的旧 PID 241912 后，launcher 启动了新的 Quickshell PID 261230。新实例加载
Timer 修复后：

- `omarchy-shell shell ping`：`ok`。
- 连续 5 次 `summon → 等待 → 检查 quickshell:overview layer → hide → ping`：全部通过。
- 新 PID 的日志没有出现 `invalid context`、`keyboardSelectedEntry`、`TypeError`、`fatal` 或 `segfault`。
- 旧 PID 241912 的延迟错误仍会在 journal 中出现，但它属于终止前已排队的旧 QML 回调，不能作为新实例回归失败的证据。
- `npm test`：52 tests 全部通过（新增 1 个生命周期静态回归测试）。
- `omarchy plugin validate .`：通过。
- `qmllint`：运行成功，但当前命令行缺少 Quickshell/Omarchy 的完整 QML import path，因此产生大量既有的 unresolved import/type warnings；没有将这些环境警告误判为本次修改错误。

## 后续回归重点

重复测试 Overview 的打开/关闭、工作区刷新、Win+Tab 切换和插件热加载；重点观察是否再次出现：

- `attempted to evaluate a function in an invalid context`
- `Property ... is not a function`
- `omarchy-shell is not responding`
- `Disabling unresponsive app`
