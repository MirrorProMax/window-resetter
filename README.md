# 窗口复位器 · WindowResetter

一个 macOS 菜单栏小工具：**左键点一下**把当前焦点窗口按规则摆正，**再点一下**在「宽模式」与「窄模式」之间切换。每个 App 各自记住自己的模式。

纯 Swift + AppKit / SwiftUI，无第三方依赖，不联网、不收集数据。

## 宣传片

- 30 秒竖屏版（抖音 / B站 / 小红书 / 视频号通用）：[assets/窗口复位器-抖音30秒宣传片.mp4](assets/窗口复位器-抖音30秒宣传片.mp4)
  - 1080×1920 / 30fps / H.264 + AAC，**中文温柔女声配音**（Edge TTS 晓晓 / Warm，8 段合计 22.97 秒），人声段自动压低音效。
  - **v3 分镜（四组 / 8 镜，合规净版）**：① 0.8 秒视觉钩子「歪斜 → 自己居中」→ 平板式自动居中（产品名提前到约 4.7 秒）；② 产品出场 / 新窗口自动居中 / 菜单栏切宽窄 + 记忆角标；③ 侧拉分屏不打扰 → 往中间靠吸回中心；④ Slogan + 品牌净版定格。
  - **全平台合规净版**：画面与旁白均不含 URL、二维码、平台名（GitHub / Gitee / Releases）及「简介 / 评论区 / 扫码 / 下载」等导流话术；下载地址与仓库链接全部外置到发布文案（见分镜脚本 v3 第四节），下载方式见本文件「下载安装」。
  - 字幕按「一句旁白 = 一屏字幕」切换，切换点对齐镜头起点；时间轴按 8 段配音实测时长校准，节奏为「首镜 2.25 秒快切 → 中段静止 → 片尾定格」。
  - 全片常驻「macOS 专属」角标，片尾注明 macOS 13.0+、需「辅助功能」权限、未签名需右键打开；**不含多显示器 / 跨屏、iPad 商标类比**相关表述。
- B 站横版封面三版（1146×717，PNG + JPG，合规净版）：[assets/bilibili/](assets/bilibili/) — A 痛点反差 / B 功能演示 / C 极简品牌，附三版对照图；可用 [tools/render_bilibili_covers.py](tools/render_bilibili_covers.py) 重新渲染。
- 小红书 / 抖音竖版封面各三版（合规净版，PNG + JPG）：[assets/xiaohongshu/](assets/xiaohongshu/)（1080×1440，3:4，A 痛点共鸣 / B 清单种草 / C 极简品牌）、[assets/douyin/](assets/douyin/)（1080×1920，9:16，A 强钩子 / B 结果反差 / C 品牌定格），各附三版对照图；可用 [tools/render_social_covers.py](tools/render_social_covers.py) 一键重出六版。
- 分镜脚本 v3（成片校准时间轴、8 段旁白稿、改动对照、发布文案、口径禁区）：[docs/宣传短视频分镜脚本-v3.md](docs/宣传短视频分镜脚本-v3.md)
- 分镜脚本 v2（历史版本，含 9 镜时间轴与「待修订项」）：[docs/宣传短视频分镜脚本-v2.md](docs/宣传短视频分镜脚本-v2.md)
- 早期脚本（75 秒主版分镜 + 30 秒竖屏剪辑清单）：[docs/宣传短视频拍摄脚本.md](docs/宣传短视频拍摄脚本.md)
- 旁白音频缓存：[tools/voiceover_v3/](tools/voiceover_v3/)（8 段 mp3，离线重渲染无需联网）
- 成片为按本工具真实功能绘制的仿录屏动效，可用 [tools/render_douyin_video_v3.py](tools/render_douyin_video_v3.py) 重新渲染（需 ffmpeg、Pillow；缓存齐全时完全离线，缺缓存才需 edge-tts 联网，最差回退 macOS `say`）。`tools/render_douyin_video_v2.py` 与 `tools/render_douyin_video.py` 为旧渲染器，保留可回退。

## 功能

**复位 / 切换**

- 窗口已摆正在当前模式 → 切换到另一种模式；否则先按当前模式摆正（最后无条件居中收尾）。
- **宽模式**：接近全屏的宽矩形，上下铺满可见区，左右按「台前调度 / 左右预留」留边，并由「最小宽度」保底。
- **窄模式**：宽度为屏幕宽度的一半（可切换为屏幕高度），上下铺满可见区并水平居中。
- **竖屏自适应**：屏幕高 > 宽时一律使用统一全宽布局，不区分模式、左右不预留。
- **多显示器**：始终按窗口所在屏幕计算布局。
- **平滑变化**：窗口移动与拉伸在设定的毫秒数内平滑完成。

**自适应居中**（常驻服务，独立于点击复位）

- 首次激活窗口时居中；手动把窗口固定到某一侧后不再打扰，拖回中心或触发磁吸后恢复。
- 窗口跨屏拖动时，**等松开鼠标后**才居中到新屏幕。
- 已居中的窗口被拉伸时保持中心（类似按住 Option 拉伸）；垂直方向降频，且系统边缘动画期间完全不写窗口几何。
- 拖进 / 拖出中心磁吸范围（默认占可见区宽 / 高的 8%，可在设置里调）各触发一次触控板反馈，进入后松手吸附到中心。
- 双击窗口上 / 下边缘后，自动把另一端也补齐到对侧边缘。
- 控制中心、通知中心、菜单栏菜单、系统级搜索等临时浮层，以及面积过小的窗口不参与。

## 系统要求

- macOS 13.0 或更高
- 「辅助功能」权限（系统设置 › 隐私与安全性 › 辅助功能）
- 发布版为 Universal 二进制，Apple Silicon 与 Intel Mac 通用
- 仅源码构建需要 Swift 工具链（Xcode 或 Command Line Tools）

## 下载安装（推荐）

到 [GitHub Releases](https://github.com/MirrorProMax/window-resetter/releases) 下载最新版：

下载文件使用 ASCII 文件名，与 `SHA256SUMS.txt` 中的名称一致，可直接校验。

| 文件 | 说明 |
| --- | --- |
| `WindowResetter-<版本>.dmg` | 推荐：打开后把 App 拖进「应用程序」 |
| `WindowResetter-<版本>.zip` | 解压后把 App 拖进「应用程序」 |
| `SHA256SUMS.txt` | 校验下载完整性：`shasum -a 256 -c SHA256SUMS.txt` |

1. 把 `窗口复位器.app` 放进「应用程序」文件夹。
2. **首次打开**：本项目是个人开源工具，**默认发布版本**未使用 Apple Developer ID 签名与公证，macOS 会提示「无法验证开发者」。在访达中**右键点击 App → 打开 → 打开**；若仍被拦截，到「系统设置 › 隐私与安全性」点「仍要打开」，或执行 `xattr -dr com.apple.quarantine "/Applications/窗口复位器.app"` 移除隔离属性。这一步只需做一次，不是文件损坏；放行后 macOS 会把 App 记为安全性例外，之后双击即可正常启动。若 Release 由已启用公证的流程生成，首次只会弹一次「确定打开？」确认，点「打开」即可。
3. 首次启动后，在「系统设置 › 隐私与安全性 › 辅助功能」勾选「窗口复位器」，否则无法读取 / 调整窗口。
4. 之后它常驻菜单栏：左键复位 / 切换窗口，右键打开设置、关于、退出。

## 构建与运行

```bash
git clone https://github.com/MirrorProMax/window-resetter.git
cd window-resetter
./build.sh                  # 按本机架构编译，日常开发用
# ./build.sh --universal   # 发布用：编 arm64 + x86_64 双架构
open "build/窗口复位器.app"
```

也可以用 Xcode 打开 `WindowResizer.xcodeproj` 直接 Build & Run。

`build.sh` 会依次：`swiftc` 编译全部 `.swift`（加 `--universal` 时分别编 arm64 / x86_64 再用 `lipo` 合并）→ 组装 `.app` → 用本地证书 `WindowResetterSigning` 签名（证书不存在时回退 ad-hoc 签名）。产物在 `build/`，已加入 `.gitignore`。若希望签名身份稳定、避免每次替换应用后重新授权，可在「钥匙串访问」中自建代码签名证书并命名为 `WindowResetterSigning`。

首次运行请在「系统设置 › 隐私与安全性 › 辅助功能」中勾选本应用；重新签名或替换 `.app` 后，macOS 可能要求重新授权。

> 默认 Bundle ID 为 `com.example.WindowResizer`，是示例域名。正式分发前请改为自己的反向域名：`build.sh` 的 `BUNDLE_ID` 与工程文件的 `PRODUCT_BUNDLE_IDENTIFIER` 需同步修改。注意更换 Bundle ID 会启用一套新的 `UserDefaults` 偏好。

## 发布者：启用自动公证（可选）

默认发布的是本地自签 / ad-hoc 签名版本，下载者首次打开需手动放行一次。若要做到「下载后双击即可打开」，需加入 Apple Developer Program（中国大陆个人会员 ¥688/年），用 **Developer ID Application** 证书签名并提交 Apple 公证。

在仓库 Settings → Secrets and variables → Actions 中配置以下 6 项：

| Secret | 内容 |
| --- | --- |
| `APPLE_SIGN_IDENTITY` | 证书全名，形如 `Developer ID Application: 姓名 (TEAMID)` |
| `APPLE_CERTIFICATE_P12` | 该证书连私钥导出的 `.p12`，base64 编码后的单行文本 |
| `APPLE_CERTIFICATE_PASSWORD` | 导出 `.p12` 时设置的密码 |
| `APPLE_API_KEY` | App Store Connect API Key 的 `.p8` 文件全文（含 BEGIN / END 行） |
| `APPLE_API_KEY_ID` | Key ID |
| `APPLE_API_ISSUER` | Issuer ID |

六项齐全时，`.github/workflows/release.yml` 会自动：用 Developer ID 签名（`--options runtime --timestamp`）→ `notarytool` 分别公证 `.app` 与 DMG → `stapler` 装订票据 → `spctl` 校验 → 最后才生成 `SHA256SUMS.txt` 并发布。**缺任意一项会自动降级**为原来的自签流程，发版不会失败。

细节：ZIP 无法直接 staple，流程是先装订 `.app` 再打包 ZIP；签名身份变更后「辅助功能」授权需重新勾选一次；Bundle ID 无需修改，公证不要求自有反向域名。

## 使用

| 操作 | 效果 |
| --- | --- |
| 左键点击菜单栏图标 | 复位 / 切换当前焦点窗口 |
| 右键点击菜单栏图标 | 菜单：设置 / 关于 / 退出 |

设置界面按运行时逻辑优先级排列；把光标停在任意选项上约一秒即可看到说明。

| 设置项 | 默认值 | 说明 |
| --- | --- | --- |
| 开机自动启动 | 关 | 随登录启动 |
| 自适应居中 | 开 | 上方列出的常驻行为 |
| ├ 吸附率 | 8% | 中心磁吸范围占可见区宽 / 高的百分比，范围 `1~20`；越大越容易吸住 |
| ├ 震动强度 | 强 | 轻 / 中 / 强三档，需触控板 |
| └ 最小窗口面积 | 200000 | 小于该面积不参与自适应居中，`0` = 不启用 |
| 竖屏自适应 | 关 | 竖屏时使用统一全宽布局 |
| 窄窗口模式 | 屏幕宽度的一半 | 也可选「屏幕的高度」 |
| 最小宽度 | 1710 | 宽模式宽度下限，优先级高于「左右预留」；`0` = 不限制 |
| 台前调度检测 | 开 | 仅当系统台前调度开启时才左右留边 |
| ├ 左右预留 | 245 | 整数，左右各预留该值，范围 `0~10000` |
| 平滑变化 | 关 | 开启后窗口变化在设定时长内平滑完成 |
| └ 动画时长 | 1000 毫秒 | 有效范围 `16~60000` |

**关于单位**：界面上的长度 / 面积数字都按 macOS 的**逻辑分辨率（点 pt）**计算 —— `NSScreen.frame` / `visibleFrame` 与辅助功能 API 的 `AXPosition` / `AXSize` 都在点空间，**无需换算**。Retina 屏 `backingScaleFactor = 2` 时 1 点 = 2 物理像素。

## 实现要点

- 窗口读写走 Accessibility API（`AXUIElement` / `AXPosition` / `AXSize`），坐标按 Cocoa 左下原点与屏幕 `visibleFrame` 换算。
- 布局与「是否已摆正」共用同一个 `targetFrame`；是否翻转模式最终看**窗口中心**是否落在目标布局的中心范围（容差 2 点）。
- 「自适应居中」以 60ms 轮询配合全局鼠标事件实现，每窗口一份内存记录；系统浮层与系统垂直动画期间不写窗口几何。
- 偏好存 `UserDefaults`（域 `com.example.WindowResizer`），运行期无网络请求、无文件写入。详见 [PRIVACY.md](PRIVACY.md)。

## 已知限制

- 依赖「辅助功能」权限。macOS 不允许通过辅助功能 API 拦截系统拖动 / 拉伸，因此居中补偿是事后写回，会有一个轮询间隔内的极短位移。
- 「台前调度检测」通过读取系统偏好 `com.apple.WindowManager GloballyEnabled` 判断，属于非公开接口行为，未来 macOS 版本可能变化。
- 触控板反馈需要相应硬件；无 Force Touch 时可能完全无感。
- 部分 App 会夹断窗口尺寸或拒绝 AX 写入，此时以实际尺寸做居中兜底。

## 许可证

[MIT](LICENSE) © 2026 MirrorPro
