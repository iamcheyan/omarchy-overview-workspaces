# 商店审核注意事项（Marketplace Review Notes）

> 2026-08-22 整理。来源：本插件 issue
> [#1401](https://github.com/HANCORE-linux/omarchy-plugin-marketplace/issues/1401)
> 及兄弟插件 #1468、#1428 的审核往返。供上架前自查与复审对照。

## Published status

The plugin was approved and verified, and is now published at:
https://omarchyplugins.com/plugin.html?id=hancore.overview-workspaces

The marketplace verification applies to the published snapshot and is not a
security audit.

## 一、商店审核机制速览

1. **按精确 HEAD 审核**：维护者引用具体 commit SHA 复核。修复必须：上游提交 →
   issue 评论附 commit 链接 → 等按新 HEAD 复审。本地改完不推送 = 审核看不到。
2. **自动化基线**：扫描 `pkexec`/`sudo`/`systemctl`/`make` 模式，命中标
   `privilege`/`service-management` 能力。本仓基线 **passed、零能力标记**——这是优势，保持住。
3. **人工复审**只盯两类事：供应链完整性、资源与注入边界；语言精确到 `文件:行号`。

## 二、审核人在意的点（从三单反馈提炼）

| # | 关注点 | 出处 | 判例 |
|---|--------|------|------|
| 1 | 供应链固定：不 clone moving-HEAD、不以 root 构建下载物 | #1468 | unpinned remote-to-root path 被打回 |
| 2 | TOCTOU：校验后的用户可写路径不得再交特权步骤执行 | #1468 | make in user cache 被打回 |
| 3 | 资源无界：下载按声明大小截断 | #1428 | EOF 下载撑爆磁盘被打回 |
| 4 | **注入面：外部数据渲染必须显式 PlainText** | **#1401 本仓判例** | hyprctl clients 标题经 AutoText 可触发富文本资源加载 |
| 5 | 提权纪律：固定内联命令、用户显式触发 | #1428 ONNX | 固定串 pkexec 通过 |
| 6 | 卸载卫生：不在用户配置留悬挂钩子 | 提交清单 | explicit consent 条款 |
| 7 | 仓库卫生：无产物入库、README/license/preview 齐、版本递增 | 三单通用 | bot 校验 manifest 唯一性 |

## 三、本仓库反馈与修复状态

- 审核人 ryanrhughes（collaborator）：`HyprlandData.qml:557-573`、`OverviewWidget.qml`
  的窗口标题/类名经 `StyledText`（默认 `Text.AutoText`）渲染，本地应用可用 markup 形状
  的标题在常驻 shell 里触发富文本资源加载。
- 已修：`594826a` StyledText 改 `Text.PlainText`。2026-08-22 深查结论见下节。

## 四、本仓库对照自查要点（2026-08-22 深查）

- [x] **PlainText 覆盖面**：全文件核查完毕，所有渲染 hyprctl 标题/类名/标签的点都经
      StyledText（PlainText）；裸 `text:` 绑定均为内部常量。
- [x] **service 入口 bash -lc 拼装**：已在 `bindingScript` 前声明注入不变量
      （只允许常量表与整数插值），当前内容全部为常量。
- [x] **Sumika 移植残留清理**：会话菜单/重载 Shell（后端二进制不存在）整体删除；
      `>command` 模式改用系统自带 `xdg-terminal-exec` 直接派生（保留功能、去
      `sumika-detach`）；trailing 工作区回车启动器行为移除（无替代二进制），仅保留聚焦；
      `Directories.root` 死属性删除，`sumikaStateHome` 更名 `stateHome`。
- [x] **workspace-order.json 写入门控修复**：Omarchy shell 从不设置 `SUMIKA_APP_DIR`，
      原 isWriter 判定恒 false，排序持久化从未写入。现未设置该变量即视为本插件持有写权，
      保留上游 Sumika 环境下的原有选举语义。
- [x] Wallpaper 轮询改为仅概览可见时运行，打开瞬间额外刷新一次。
- [x] Persistent.qml 经核实**并非死代码**（OverviewWindow.qml:127 在消费），保留；
      Config.qml `arbitraryRaceConditionDelay=50` 为既有时序参数，不动。
- [x] 无 pkexec/sudo/keyd 类特权面；hyprctl 全部用户态 detached 运行。
- [x] 已有 `tests/menu-index.test.js` 与 `tests/workspace-bar-config.test.js`。绑定脚本、系统/优化排序、trailing id、pending 搬家仍是手工回归。
