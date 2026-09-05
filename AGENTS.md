# hancore.overview-workspaces 维护规则

## 绝对禁止：插件生命周期中调用 `hyprctl reload`

本插件运行在 Omarchy 的 Quickshell 进程中。插件卸载、热重载以及
`Component.onDestruction` 执行时，**绝对不能调用 `hyprctl reload`**。

`hyprctl reload` 会重载整个 Hyprland，而不是恢复本插件的局部状态，可能造成：

- Wayland connection broken；
- Quickshell 退出并反复拉起；
- 插件热重载时桌面卡死或输入无响应；
- 用户误以为 `omarchy restart shell` 杀掉了所有应用进程。

如果插件临时修改了快捷键，销毁时只能撤销本插件自己的绑定，使用精确的
`hyprctl eval`：

```qml
Quickshell.execDetached(["hyprctl", "eval", commands.join("; ")]);
```

不要用整套 Hyprland 配置重载来代替 `unbind`/`bind`。修改
`KeybindingService.qml` 或相关生命周期逻辑后，必须检查：

```bash
rg -n "hyprctl.*reload|reload.*hyprctl" .
```

除非是明确的人工维护命令，否则结果必须为空；特别是不能出现在
`Component.onDestruction`、销毁回调或插件热重载路径中。

这条规则来自实际故障：将快捷键恢复改成 `hyprctl reload` 后，Shell 重启和插件
热重载会触发 Wayland 连接断开。恢复为 `hyprctl eval` 后才恢复正常。
