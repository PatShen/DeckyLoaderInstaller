# Decky Loader 离线安装脚本（Steam Deck 桌面模式）

用你手动下载的 `PluginLoader` 二进制，在 Steam Deck 桌面模式一键安装 Decky Loader
（也就是带插件商店的那套插件框架）。**安装过程不需要联网、不需要 jq、不访问 GitHub API。**

- 安装：等价于官方 `install_release.sh` 做的事（`~/homebrew` + `plugin_loader.service` + CEF 标记）。
- 升级：再运行一次即可，会备份旧二进制，保留插件和配置。
- 卸载：`--uninstall`（`--wipe` 连 `~/homebrew` 一起删）。

> 说明：Decky Loader 自带插件商店（Decky 界面里的 **Store** 标签页），
> 不需要另外安装“插件商店”。浏览/下载插件时才需要联网。

---

## 1. 前置条件

1. Steam Deck 已切到 **桌面模式**（Steam → 电源 → 切换到桌面）。
2. 至少启动过一次 Steam，存在 `~/.steam/steam` 目录（游戏模式启动过也算）。
3. 能打开 **Konsole**（应用菜单里搜索 Konsole）。
4. 下载好 `PluginLoader` 二进制（见下一节）。
5. sudo 权限：Deck 默认没设密码，脚本会询问是否**临时**把密码设为 `Decky!`，
   安装结束后自动删除（与官方安装器做法相同）。也可以先自己运行 `passwd` 设好密码。

---

## 2. 下载哪个文件

1. 在 Deck 的浏览器打开：
   <https://github.com/SteamDeckHomebrew/decky-loader/releases/latest>
2. 展开 **Assets**，下载名为 **`PluginLoader`** 的文件（无扩展名）。
   - 不要下载 `PluginLoader-arm64`（那是 ARM 设备用的，Deck 是 x86_64）。
   - 不要下载 `Source code (zip/tar.gz)`。
   - 如果浏览器把文件存成了 `PluginLoader.zip`，请解压，只取里面的 `PluginLoader`。
3. 把脚本和二进制放在同一个目录，文件名保持 `PluginLoader`：

```
~/decky-install/
├── install-decky.sh
└── PluginLoader
```

> 文件名被浏览器改成 `PluginLoader (1)` 之类也没关系，用 `--binary` 指定即可。

---

## 3. 运行

```bash
cd ~/decky-install
chmod +x install-decky.sh

# 1) 先只做检查，不改任何东西
bash install-decky.sh --check

# 2) 正式安装 / 升级
bash install-decky.sh
```

安装过程中会：

1. 校验 `PluginLoader` 确实是 x86-64 的 Linux ELF 程序（防止下成网页、zip、arm64 版本）；
2. 停止旧的 `plugin_loader` 服务（如存在），把旧二进制备份为 `~/homebrew/PluginLoader.bak.<时间>`；
3. 创建 `~/homebrew/{plugins,services}` 并安装二进制；
4. 创建 `~/.steam/steam/.cef-enable-remote-debugging`（Flatpak 版 Steam 会同时处理）；
5. 写入 `/etc/systemd/system/plugin_loader.service`，`daemon-reload` 后 `enable --now`；
6. 校验服务状态 + `http://127.0.0.1:1337/auth/token` 是否响应；
7. 修正 `~/homebrew` 所有权（保证插件能写入），SELinux 环境下设置 `bin_t`。

> 必须在 Konsole 里运行；双击运行可能没有终端，会提示失败。

### 关于临时密码

如果 `deck` 用户没有设置过密码，脚本会问：

```
是否临时把密码设置为 Decky!（安装结束会自动删除）？[y/N]
```

回答 `y` 后，脚本用 `Decky!` 取得 sudo 权限，结束时自动 `passwd -d deck` 恢复无密码。
不想交互可以用 `--temp-password` 预先允许。若脚本异常中断导致密码残留，执行：

```bash
sudo passwd -d deck
```

---

## 4. 安装完成后

1. **完全退出并重新打开 Steam**（或重启机器），Decky 才会被注入；
   脚本检测到 Steam 在运行时会询问是否帮你关闭（`--restart-steam` 可直接关）。
2. 切回**游戏模式**（桌面上的 “Return to Gaming Mode”）。
3. 用 `...` 键打开快捷菜单（QAM），左侧会出现 **Decky** 图标；
   打开后切到 **Store** 标签页即可浏览插件商店（需要联网）。

### 用命令验收

```bash
systemctl status plugin_loader

curl -s http://127.0.0.1:1337/auth/token; echo

ls -l ~/homebrew/services/PluginLoader
ls -l ~/.steam/steam/.cef-enable-remote-debugging
```

正常情况下：服务是 `active (running)`，`curl` 返回一串 token，两个文件都存在。

---

## 5. 参数

| 参数 | 说明 |
|---|---|
| （无） | 安装或升级，自动在脚本目录找 `PluginLoader` |
| `--binary PATH` | 指定二进制路径（也可以直接把路径作为第一个参数） |
| `--version vX.Y.Z` | 可选，把版本号记录到 `~/homebrew/services/.loader.version` |
| `--check` | 只预检，不修改任何东西，退出码 0 表示可以安装 |
| `--yes` | 所有确认自动回答“是”（不会自动允许设置临时密码） |
| `--temp-password` | 允许自动设置临时密码 `Decky!`（结束自动删除） |
| `--restart-steam` | 安装完成后直接关闭 Steam（默认会先询问） |
| `--uninstall` | 卸载：停服务、删 unit、删二进制、删 CEF 标记（保留插件和配置） |
| `--uninstall --wipe` | 卸载并删除整个 `~/homebrew`（插件、配置、日志全删，会二次确认） |
| `-h, --help` | 显示帮助 |

退出码：`0` 成功，`1` 参数错误，`2` 预检失败，`3` 二进制非法，`4` 提权失败，
`5` 安装/卸载失败，`6` 服务校验失败。

---

## 6. 升级与卸载

**升级**：用新的 `PluginLoader` 覆盖目录里的文件，然后重新运行脚本即可；
插件、配置、已安装插件都不会动（旧二进制会备份到 `~/homebrew/PluginLoader.bak.*`）。

**卸载**：

```bash
bash install-decky.sh --uninstall          # 保留 ~/homebrew（插件和配置还在）
bash install-decky.sh --uninstall --wipe   # 全部删除
```

卸载后同样建议重启一次 Steam。

---

## 7. 排错

| 现象 | 处理 |
|---|---|
| `在脚本目录下找不到 PluginLoader` | 确认文件和脚本在同一目录，或 `--binary /路径/PluginLoader` |
| `这个文件是网页而不是程序` / `是 zip 压缩包` | 重新从 Releases 的 Assets 下载裸 `PluginLoader` |
| `这是 arm64 版本` | Deck 需要 x86-64 的 `PluginLoader`，不是 `PluginLoader-arm64` |
| `需要输入 sudo 密码，但没有可用终端` | 在 Konsole 里运行；不要双击 |
| `Text file busy` | 旧服务还在跑。先 `sudo systemctl stop plugin_loader` 再运行脚本 |
| 服务起不来 / 1337 无响应 | `journalctl -u plugin_loader -b --no-pager -n 100` 看详细日志；把日志发出来排查 |
| 端口 1337/8080 被占用 | Decky 需要这两个端口。Syncthing 请把端口改成 8384，其他程序同理 |
| 装完看不到 Decky | 1) 完全重启 Steam；2) 确认在**游戏模式**看 QAM；3) 重新运行脚本安装一次 |
| SteamOS 大版本更新后 Decky 消失 | 这是已知现象，重新运行本脚本即可 |
| 临时密码没被删掉 | `sudo passwd -d deck` |
| 脚本报 Windows 换行(CRLF) | `sed -i 's/\r$//' install-decky.sh` |
| 插件页打不开 / Store 空白 | 插件商店需要联网；并检查 1337/8080 端口冲突 |

---

## 8. 与官方安装器的关系 / 安全提示

- 官方做法是运行 `install_release.sh`：需要联网、`jq`、GitHub API，并且会**重新下载**
  一份 `PluginLoader`，覆盖你可能已经下好的文件。本脚本改为只使用本地文件。
- 本脚本会做和官方一致的、需要 root 的操作：写 `/etc/systemd/system/plugin_loader.service`、
  以 root 运行服务、创建 CEF 调试标记。除此之外不改动系统文件、不碰 Steam 启动参数。
- 请确认 `PluginLoader` 来自官方 Releases。脚本会打印 SHA256，
  可以和 Release 页面里该文件的 digest 对照。
- 官方安装器仍在维护；如果你更希望用官方方式，可以继续用
  `curl -L https://github.com/SteamDeckHomebrew/decky-installer/releases/latest/download/install_release.sh | sh`。
  本脚本与官方安装器安装结果兼容（同样的目录与服务名），两者可以互相覆盖升级。

---

## 9. 文件清单

```
decky-install/
├── install-decky.sh   # 安装/升级/卸载脚本（单文件，bash）
└── README.md          # 本说明
```

目标设备上最终会生成的文件：

| 路径 | 说明 |
|---|---|
| `~/homebrew/plugins/` | 插件安装目录（归 deck 用户所有） |
| `~/homebrew/services/PluginLoader` | 加载器二进制（root:root，0755） |
| `~/homebrew/services/.loader.version` | 仅在传 `--version` 时生成 |
| `~/homebrew/PluginLoader.bak.*` | 升级时自动备份的旧二进制 |
| `/etc/systemd/system/plugin_loader.service` | 开机自启的 systemd 服务 |
| `~/.steam/steam/.cef-enable-remote-debugging` | 让 Steam 开启 CEF 调试端口（Decky 注入用） |
