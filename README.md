# Clash for Linux Fusion

基于 [clash-for-linux-install](https://github.com/nelvko/clash-for-linux-install) 的增强融合版，整合了节点管理、快速切换、端口管理等实用功能。

## 相比原版的增强

- **节点管理** — 查看当前节点信息（分组/节点/延迟/模式）
- **快速切换** — 一条命令切换节点、分组、模式、订阅
- **策略分组** — 查看所有策略分组，支持并行测速
- **自动测速** — 进入节点列表时自动并行测试所有节点延迟，颜色区分（绿/黄/红）
- **端口管理** — 一键自动分配可用端口，或手动指定端口
- **订阅名称** — 订阅列表显示友好名称，支持 `ch -s` 快速切换订阅
- **zsh 兼容** — 完全兼容 zsh（NOCLOBBER 等），无多余输出
- **多用户环境** — 支持 root 和普通用户，适配 AutoDL 等容器化环境

## 快速安装

```bash
git clone --depth 1 https://github.com/unreading/clash-for-linux-fusion.git \
  && cd clash-for-linux-fusion \
  && bash install.sh
```

安装后在 shell 配置文件中添加别名（可选）：

```bash
alias clash="clashctl"
alias mihomo="clashctl"
alias mi="clashctl"
```

## 命令一览

```
Usage: 
  clashctl COMMAND [OPTIONS]

Aliases: clash, mihomo, mi

Commands:
  on                    开启代理
  off                   关闭代理
  proxy                 系统代理
  status                内核状态
  now                   当前节点信息（分组/节点/延迟/模式）
  group                 策略分组（-n 查看节点，-t 测速）
  ch                    快速切换（-n 节点，-g 分组，-m 模式，-s 订阅）
  ui                    面板地址（update 更新 UI）
  port                  端口管理（auto 自动，set <port> 固定）
  sub                   订阅管理（add/ls/del/use/update）
  log                   内核日志
  tun                   Tun 模式
  mixin                 Mixin 配置
  secret                Web 密钥
  upgrade               升级内核

Global Options:
  -h, --help            显示帮助信息
```

## 使用示例

### 代理启停

```bash
$ clashctl on              # 启动代理并设置系统代理
$ clashctl off             # 停止代理并清除系统代理
$ clashctl status          # 查看内核状态
```

### 节点切换

```bash
$ mi now                   # 查看当前节点（分组/节点/延迟/代理模式）
$ mi ch -n                 # 交互式选择节点（自动测速，颜色标记延迟）
$ mi ch -n 12              # 直接切换到第 12 个节点
$ mi ch -g                 # 交互式选择策略分组
$ mi ch -s                 # 交互式切换订阅
$ mi group -n              # 查看策略分组详情
$ mi group -t              # 并行测速所有节点
```

节点列表自动测速并颜色标记：
- 🟢 绿色 — 优秀（< 200ms）
- 🟡 黄色 — 一般（200–500ms）
- 🔴 红色 — 较慢（> 500ms）/ 超时 / 不可用

### 订阅管理

```bash
$ mi sub add <url>         # 添加订阅
$ mi sub ls                # 查看订阅列表（显示名称和 URL）
$ mi sub use 2             # 切换到第 2 个订阅
$ mi sub update            # 更新当前订阅
```

### 端口管理

```bash
$ mi port                  # 查看当前端口
$ mi port auto             # 自动分配可用端口
$ mi port set 7891         # 固定端口为 7891
```

### 其他

```bash
$ mi ui                    # 显示 Web 面板地址
$ mi ui update             # 更新 Web 面板
$ mi mixin                 # 查看 Mixin 配置
$ mi mixin -e              # 编辑 Mixin 配置
$ mi tun on                # 开启 Tun 模式
$ mi upgrade               # 升级内核
```

## 致谢

- [nelvko/clash-for-linux-install](https://github.com/nelvko/clash-for-linux-install) — 原版项目
- [MetaCubeX/mihomo](https://github.com/MetaCubeX/mihomo) — 代理内核
- [subconverter](https://github.com/tindy2013/subconverter) — 订阅转换
- [zashboard](https://github.com/Zephyruso/zashboard) — Web 控制台

## 声明

本项目仅供学习和研究使用，不得用于任何违反法律法规的用途。
