# 窗口复位器

macOS 菜单栏小工具：左键点一下把当前焦点窗口按规则摆正，再点一下在「宽模式」与「窄模式」之间切换；另有常驻的「自适应居中」服务。纯 Swift + AppKit / SwiftUI，无第三方依赖，不联网、不收集数据。

> 维护者：发新版时请更新下方「本次更新」，并同步 `build.sh` 里的 `VERSION`。

## 本次更新 · v1.1.0

- 新增「吸附率」设置（默认 8%，可调 `1~20`），位于「自适应居中」开关下方；控制中心磁吸范围，改完即时生效。旧版固定 5%，填 `5` 可保留原手感。
- 全项目术语统一为「宽模式 / 窄模式」。
- 发布版改为 Universal 二进制，Apple Silicon 与 Intel Mac 通用。

## 下载

| 文件 | 说明 |
| --- | --- |
| `窗口复位器-<版本>.dmg` | 推荐：打开后把 App 拖进「应用程序」 |
| `窗口复位器-<版本>.zip` | 解压后把 App 拖进「应用程序」 |
| `SHA256SUMS.txt` | 校验：`shasum -a 256 -c SHA256SUMS.txt` |

## 安装与首次运行

1. 要求 macOS 13.0 或更高，把 `窗口复位器.app` 放进「应用程序」。
2. 本项目为个人开源工具，**未使用 Apple Developer ID 签名与公证**，macOS 会提示「无法验证开发者」。在访达中 **右键点击 App → 打开 → 打开**；若仍被拦截，到「系统设置 › 隐私与安全性」点「仍要打开」，或执行 `xattr -dr com.apple.quarantine "/Applications/窗口复位器.app"` 移除隔离属性。只需做一次，不是文件损坏。
3. 首次启动后到「系统设置 › 隐私与安全性 › 辅助功能」勾选「窗口复位器」，否则无法读取 / 调整窗口；替换 App 后可能需要重新授权。
4. 菜单栏：左键复位 / 切换窗口，右键打开设置、关于、退出。「吸附率」等子项只在「自适应居中」开关打开时显示。

详见仓库 [README](https://github.com/MirrorProMax/window-resetter#readme) 与 [PRIVACY.md](https://github.com/MirrorProMax/window-resetter/blob/main/PRIVACY.md)。
