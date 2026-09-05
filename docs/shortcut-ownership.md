# 快捷键所有权与生命周期

## 插件拥有的范围

启用 `hancore.overview-workspaces` 后，插件只负责这些快捷键：

- 单独按 Win：打开或关闭工作区预览；
- Win+Tab、Win+Shift+Tab：预览中循环工作区；
- Win+数字：在 legacy 排序模式下选择预览中的工作区槽位。

插件可以在预览拖拽期间临时暂停 Win+鼠标移动和缩放，这是为了防止拖拽窗口同时触发 Hyprland 的移动或缩放。预览关闭后必须恢复这些绑定。

## 禁止触碰的范围

插件不得注册或删除以下绑定：

- `SUPER + <任意普通键>` 的通用观察器；
- `SUPER + CTRL + <任意普通键>` 的通用观察器；
- 用户未委托给插件的快捷键；
- 用户快捷键的命令、回调、参数、描述和选项。

因此 `Win+W`、`Win+Enter`、`Win+Space`、`Ctrl+Win+V` 以及用户自己定义的其它组合，都不能通过 interrupt 列表处理。

## 单独 Win 的判定

单独 Win 必须通过 `input.keyboard.key` 事件判断：

1. Win 按下时记录候选状态；
2. 任意其它键按下时取消候选状态，不论 Ctrl、Win 或普通键谁先按；
3. 只有候选状态仍然有效并且 Win 释放时，才切换工作区预览。

这样不会为了识别组合键而创建一批会和用户绑定竞争的 `SUPER + key` 绑定。

## 启用、禁用和重载

插件接管的 Win、Win+Tab、Win+数字绑定只存在于 Hyprland 运行时。插件禁用或销毁时，必须使用 `hyprctl eval` 精确撤销插件自己的绑定，并恢复插件接管前保存的用户绑定。**禁止调用 `hyprctl reload`**，也禁止用硬编码的 Omarchy 默认命令代替恢复，因为前者会重载整个 Hyprland，后者会丢失用户自定义的命令和选项。

Hyprland 的 `hl.unbind("...")` 不记录绑定来源，可能删除用户绑定。因此只能对插件明确拥有的表达式使用它；不得把它用于通用键列表，也不得在诊断时手动解绑用户快捷键。

## 每次修改后的检查

至少执行：

```sh
npm test
hyprctl reload
hyprctl configerrors
hyprctl binds -j
```

核对运行态中只有插件声明的快捷键带有 `Overview` 描述，并确认原生 `SUPER + W`、`SUPER + RETURN`、`SUPER + SPACE` 仍然存在。最后重启 shell，确认插件重载后这些结果不变。
