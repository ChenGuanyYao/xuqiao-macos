#!/bin/zsh
set -euo pipefail
script_dir="${0:A:h}"
project_dir="${script_dir:h}"
package_dir="$project_dir/apps/macos"
configuration="${1:-release}"
if [[ "$configuration" != release && "$configuration" != debug ]]; then
  print -u2 '用法: scripts/build-macos.sh [release|debug]'
  exit 2
fi
export SDKROOT="$(xcode-select -p)/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"
if [[ ! -d "$SDKROOT" ]]; then export SDKROOT="$(xcrun --show-sdk-path)"; fi
swift build --package-path "$package_dir" -c "$configuration" --sdk "$SDKROOT"
binary_dir="$(swift build --package-path "$package_dir" -c "$configuration" --sdk "$SDKROOT" --show-bin-path)"
output_dir="$package_dir/build/$configuration"
app_dir="$output_dir/续桥.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
# 替换新inode，避免截断正在运行的旧release映像；旧进程继续使用原映像。
binary_temporary="$(mktemp "$app_dir/Contents/MacOS/.XuQiaoMac.XXXXXXXX")"
trap 'rm -f "$binary_temporary"' EXIT
cp "$binary_dir/XuQiaoMac" "$binary_temporary"
chmod 755 "$binary_temporary"
mv -f "$binary_temporary" "$app_dir/Contents/MacOS/XuQiaoMac"
cp "$project_dir/assets/brand/AppIcon.icns" "$app_dir/Contents/Resources/AppIcon.icns"
cat > "$app_dir/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.chenguangyao.xuqiao.mac</string>
<key>CFBundleName</key><string>续桥</string>
<key>CFBundleDisplayName</key><string>续桥</string>
<key>CFBundleExecutable</key><string>XuQiaoMac</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.11.14</string>
<key>CFBundleVersion</key><string>46</string>
<key>LSMinimumSystemVersion</key><string>15.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSBluetoothAlwaysUsageDescription</key><string>续桥使用蓝牙发现已配对的手机并在后台唤醒重连，剪贴板和文件内容仍通过加密局域网传输。</string>
<key>NSLocalNetworkUsageDescription</key><string>续桥需要在局域网发现手机并建立经过配对确认的加密连接。</string>
<key>NSBonjourServices</key><array><string>_xuqiao._tcp</string></array>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
/usr/bin/codesign --force --sign - "$app_dir"
/usr/bin/codesign --verify --strict "$app_dir"
print "已生成: $app_dir"
