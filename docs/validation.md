# Overview Workspaces 验证流程

这份文档是每次修改插件后的固定验收清单。它覆盖静态检查、自动测试、Shell
运行时检查和 Overview 交互检查。所有命令都应在插件目录
`hancore.overview-workspaces/` 中执行。

## 1. 修改前确认

```sh
git status --short --branch
git diff --check
```

确认没有把其他插件或用户配置的改动混入本次提交。插件开发期间不要在
Overview 正打开或正在拖拽窗口时执行热扫描。

## 2. 自动检查

```sh
node --test
omarchy plugin validate .
qmllint -I "${OMARCHY_PATH:-/usr/share/omarchy}/shell" \
  Overview.qml OverviewWidget.qml OverviewWindow.qml \
  SettingsPanel.qml KeybindingService.qml bar/widget.qml
```

验收标准：

- `node --test` 全部通过；测试数量以当前仓库为准（目前为 56 个）。
- `omarchy plugin validate .` 返回成功且没有 manifest 错误。
- `qmllint` 不出现新的 QML 错误。某些环境下由于 Quickshell 的运行时导入路径，
  可能出现 `Failed to import QtQuick` 或未解析 composite type 警告；这类警告
  不能替代运行时测试。
- 插件生命周期代码中禁止出现完整 Hyprland reload：

```sh
if rg -n 'hyprctl.*reload|reload.*hyprctl' . -g '*.qml'; then
  echo 'forbidden hyprctl reload found' >&2
  exit 1
fi
```

## 3. Shell 运行时检查

```sh
OMARCHY_SHELL_IPC_TIMEOUT=1s omarchy-shell shell ping
OMARCHY_SHELL_IPC_TIMEOUT=1s omarchy plugin list --json \
  | jq '.[] | select(.id == "hancore.overview-workspaces")'

pid=$(pgrep -f '^quickshell -n -p ' | head -n1)
ps -p "$pid" -o pid,ppid,stat,etime,pcpu,pmem,cmd
hyprctl layers
```

验收标准：

- Shell ping 返回 `ok`。
- overview 插件为 `enabled: true`。
- `hyprctl layers` 中存在 `namespace: omarchy-bar`。
- Quickshell 进程存在并保持运行；启动后短暂高 CPU 可以接受，但等待约 30 秒
  后不应持续攀升或变成 IPC 无响应。

## 4. Overview 显示和鼠标检查

命令行可以检查 layer 和 IPC；实际鼠标右键还必须手动确认：

```sh
OMARCHY_SHELL_IPC_TIMEOUT=1s \
  omarchy-shell shell summon hancore.overview-workspaces '{}'
hyprctl layers | rg 'omarchy-bar|quickshell:overview'
OMARCHY_SHELL_IPC_TIMEOUT=1s \
  omarchy-shell shell hide hancore.overview-workspaces
```

在顶栏 overview 工作区区域分别确认：

1. 右键点击工作区数字：打开 Overview。
2. 右键点击齿轮：打开 Overview。
3. 右键点击数字之间的空隙：打开 Overview。
4. 左键点击工作区数字：仍然切换工作区。
5. 左键点击齿轮：仍然打开设置面板。

如果连接了多个显示器，还要确认跨屏拖拽：

6. 打开 Overview，从 1 号显示器的窗口卡片拖到 2 号显示器的工作区卡片，
   目标卡片应高亮并显示窗口代理，释放后窗口应移动到目标工作区所属的显示器。
7. 再从 2 号显示器拖回 1 号显示器，确认两个方向都能工作；也要测试目标为
   `New workspace` 卡片的情况。
8. 按 `Escape` 或在卡片外释放取消拖拽，确认不会留下代理、卡片高亮或悬挂的
   工作区移动状态。

Overview 打开后应看到 `quickshell:overview` layer，关闭后该 layer 应消失，
`omarchy-bar` 应保持存在。

## 5. 稳定性回归

对于涉及 Shell、快捷键、插件生命周期或 bar widget 的改动，至少执行 3 次；
涉及热重载、IPC 或卡死问题时执行 5 次：

```sh
for n in 1 2 3 4 5; do
  echo "cycle-$n"
  timeout 35s omarchy restart shell
  OMARCHY_SHELL_IPC_TIMEOUT=1s omarchy-shell shell ping
  OMARCHY_SHELL_IPC_TIMEOUT=1s \
    omarchy-shell shell summon hancore.overview-workspaces '{}'
  sleep 1
  hyprctl layers | rg -q 'namespace: quickshell:overview'
  OMARCHY_SHELL_IPC_TIMEOUT=1s \
    omarchy-shell shell hide hancore.overview-workspaces
  sleep 1
done
```

每次循环都应成功。循环之间保留 1 秒以上间隔，避免把 Shell 启动竞争误判为
插件故障。完成后再等待约 30 秒，确认 ping 仍返回 `ok`，并检查最近日志：

```sh
journalctl --user -b --since '3 min ago' --no-pager \
  | rg -i 'omarchy-shell|quickshell|overview|qml|fatal|segfault' \
  | tail -n 160
```

重点关注 `fatal`、`segfault`、`is not responding`、重复的 Shell 启动/退出，
以及持续刷屏的同一条 QML 错误。普通图标缺失和 portal 注册 warning 通常不是
插件故障，但应记录而不能冒充“全部无 warning”。

## 6. 卡死时的隔离流程

如果 top bar 和 Overview 同时无响应，先保留现场并执行：

```sh
pgrep -af 'quickshell|omarchy-launch-shell'
OMARCHY_SHELL_IPC_TIMEOUT=1s omarchy-shell shell ping
hyprctl layers
free -h
df -h
```

如果 Hyprland 正常但 Shell IPC 无响应，说明故障在 Quickshell/Shell 层，不是
整机资源耗尽。可用 Omarchy 的正常流程尝试恢复：

```sh
timeout 35s omarchy restart shell
```

如果 Shell 已经忙循环而该命令无法完成，最后手段是只终止当前 Quickshell 子进程，
让 `omarchy-launch-shell` 重新拉起它；不要终止 Hyprland，也不要使用
`hyprctl reload` 代替 Shell 重启。恢复后必须重新执行第 3、4、5 节。

为确认是否是 overview 导致，可暂时执行：

```sh
omarchy plugin disable hancore.overview-workspaces
timeout 35s omarchy restart shell
```

隔离测试结束后务必恢复：

```sh
omarchy plugin enable hancore.overview-workspaces left
timeout 35s omarchy restart shell
```

## 7. 提交前清单

- 自动测试、插件校验和 `git diff --check` 通过。
- 没有新增 `hyprctl reload`。
- 手动右键/左键行为符合第 4 节。
- Shell ping 返回 `ok`，bar 和 overview layer 正常出现/消失。
- 稳定性循环完成，日志没有新的 fatal/QML 错误。
- 只提交 overview 仓库自己的文件；确认 `git status` 后再 commit。
