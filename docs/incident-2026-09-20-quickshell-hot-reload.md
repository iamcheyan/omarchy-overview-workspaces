# Quickshell 热重载卡死事故记录：2026-09-20

## 现象

修改 `hancore.overview-workspaces` 的 QML 文件后，Omarchy 顶栏和 Overview
同时失去响应。Hyprland 仍然可以管理窗口，内存、磁盘和 I/O 都正常，但
`omarchy-shell shell ping` 超时。

## 证据

- 修改插件文件后，日志开始密集出现：
  `Local plugin changed, reloading: hancore.overview-workspaces`。
- Quickshell CPU 持续升高，系统没有 OOM。
- 日志出现：
  `Quickshell's log filter has been installed twice`。
- 之后 Quickshell 因 `SIGABRT` 退出并留下 core dump。
- Hyprland 本身仍在运行；问题位于共享的 Quickshell 桌面壳。

## 根因链

插件 manifest 同时声明了 `panel`、`bar-widget` 和 `service`，并设置了
`keepLoaded: true`。插件文件保存后，Omarchy 会在同一轮热重载中卸载并重建
这些入口。旧实现存在多个生命周期竞态：

1. `Qt.callLater()` 保存的方法引用或闭包可能在组件销毁后仍执行，访问已经
   失效的 QML context。
2. 旧 `KeybindingService` 在 `Component.onDestruction` 中异步清理快捷键；
   新 service 可能已经安装了快捷键，旧清理随后又撤销新实例的绑定。
3. Overview 窗口销毁或重建期间，`grabToImage()` 可能在 QQuickItem 尚未挂载
   到 window 时执行，继续访问旧 scene graph。
4. 上述异常发生在同一个长期运行的 Quickshell 事件循环中，触发反复热加载、
   日志过滤器重复安装和忙循环，最终导致 Quickshell 崩溃；所以表现为整个
   桌面壳卡死，而不只是 Overview 卡住。

这不是内存不足、磁盘不足或 `hyprctl reload` 直接造成的；不过插件生命周期
中调用完整的 `hyprctl reload` 会重载整个 Hyprland，可能进一步造成 Wayland
断连，因此始终禁止这样做。

## 修复

- 用组件自有的零延迟 `Timer` 替换生命周期敏感的 `Qt.callLater()`。
- 为快捷键绑定增加实例所有权令牌。旧实例的延迟清理只有在仍拥有当前绑定
  时才会执行，不能撤销新实例的绑定。
- 销毁时停止所有 Timer，并阻止销毁中的 service 再排队新的绑定操作。
- 只有在预览 Item 已经拥有 window 时才执行 `grabToImage()`。
- 保留精确的 `hyprctl eval` 绑定安装/清理方式；插件代码中禁止出现完整的
  `hyprctl reload`。
- 增加测试，覆盖延迟回调生命周期、绑定所有权和销毁保护。

## 故障恢复

如果顶栏和 Overview 同时无响应：

```bash
OMARCHY_SHELL_IPC_TIMEOUT=2s omarchy-shell shell ping
timeout 35s omarchy restart shell
```

如果旧 Quickshell 忙循环导致重启命令无法完成，只终止当前 Quickshell 子进程，
让 `omarchy-launch-shell` 自动拉起新实例；不要终止 Hyprland，也不要用
`hyprctl reload` 代替 Shell 重启。

开发期间不要在 Overview 打开或拖拽时保存插件文件。涉及 `keepLoaded` 插件
的修改完成后，优先让 Shell 在干净实例中重启，再执行 Overview 的 summon/hide
验证。

## 验证结果

- `npm test`：58 个测试全部通过。
- `omarchy plugin validate .`：通过。
- `qmllint`：返回成功，无语法错误。
- QML 静态扫描：没有 `hyprctl reload`。
- 干净 Shell 实例中连续 5 次 Overview `summon → layer 检查 → hide`：全部通过。
- 最终 `omarchy-shell shell ping`：`ok`。

