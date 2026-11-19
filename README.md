# 续桥 · macOS

<img src="assets/brand/AppIcon-Mac.png" width="96" alt="续桥图标" />

连接 Mac 与 HarmonyOS 手机的原生工具。通过已配对的加密局域网连接传输文件、同步剪贴板、浏览获授权的手机相册与文件，并接收手机屏幕共享。

当前版本 **0.11.8（40）**，作为预发布提供。手机端源码与手机安装包不在本公开仓库中分发。

## 下载

从 [GitHub Releases](https://github.com/ChenGuanyYao/xuqiao-macos/releases) 下载当前版本。

- 安装包面向 Apple Silicon（arm64），最低系统为 macOS 15。
- 将“续桥.app”放入“应用程序”后启动。
- 当前安装包采用 ad hoc 签名，尚未完成 Apple Developer ID 公证，macOS 可能阻止直接打开。请自行核实来源，并按系统安全设置提示处理。
- 本地网络、蓝牙、钥匙串及下载文件夹访问仍需按系统提示授权；重新构建后的签名变化可能再次触发钥匙串确认。

## 功能

- 局域网发现、二维码或核对码配对，保存多台设备的信任。
- 文字、图片、文件、文件夹和文件组的剪贴板历史；图片在应用内部缓存，明确保存后才导出。
- 文件、目录和文件组传输，取消、记录与批量保存。
- 在手机授权后通过局域网浏览相册和系统允许访问的文件范围。
- H.264 手机投屏。系统屏幕共享授权由手机确认。
- 蓝牙辅助发现与重连；剪贴板和文件内容仍走原加密局域网通道。

独立“控制手机”功能需要 HDC 与手机 USB/无线调试。相册和授权文件浏览使用局域网服务，不依赖开发者模式。

## 从源码构建

需要完整 Xcode 和 Swift 6 工具链。工程使用 SwiftUI、AppKit、Network、Security、CoreBluetooth、VideoToolbox 与系统 SQLite，无第三方 Swift 包依赖。

```sh
git clone https://github.com/ChenGuanyYao/xuqiao-macos.git
cd xuqiao-macos
./scripts/build-macos.sh
```

输出为 `apps/macos/build/release/续桥.app`。调试构建使用 `./scripts/build-macos.sh debug`。构建脚本在输出目录内执行本地 ad hoc 签名，不访问应用运行时的配对身份。

## 数据与安全边界

首次配对需核对设备安全指纹并在两端确认。连接使用 TLS 校验，设备身份不以 IP 或蓝牙 MAC 地址代替。运行时身份与信任凭据保存在系统钥匙串；源码和安装包不包含用户的钥匙串、配对数据库、剪贴板历史或下载内容。

0.11.8 补齐重连后的当前文字自动回写、系统变更计数保护，以及采集忙碌时保留后续复制的队列。已完成与手机新版的双向系统粘贴、手机锁屏后重启 Mac 服务的补写验证；断线期间的本机新复制不会被旧补写覆盖。

可运行使用独立目录和命名剪贴板的原生回归：

```sh
swift test --package-path apps/macos
```

后台连接及锁屏同步受两端系统状态、授权和电量管理影响。真实 Wi-Fi 切换、无 HDC 长期待机耗电仍未完成；预发布不承诺永久后台常驻。
