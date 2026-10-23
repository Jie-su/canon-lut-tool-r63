# 开发与构建

## 代码结构

| 位置 | 作用 |
| --- | --- |
| `app/CanonLUTTool.swift` | SwiftUI 界面、工作区导航、转换与安装任务 |
| `app/PhotoPreview.swift` | 系统照片解码、CUBE／PF3 预览、并排与滑动比较 |
| `app/CameraConnectionMonitor.swift` | USB 通知与只读 SDK 枚举、诊断日志、任务排它 |
| `app/NativePF3Preview/native_pf3_preview.m` | 独立进程运行本机 Canon 离线 RAW 显影 |
| `app/make_app_icon.swift` | 原创图标生成源 |
| `src/r6lut/context.py` | 使用者自己的基底、快照和 hash 绑定 |
| `src/r6lut/cube.py`、`colors.py` | CUBE 解析、插值与可选颜色适配 |
| `src/r6lut/convert.py`、`native.py` | PF3 生成、真实 R6 III type10／full33 编译 |
| `src/r6lut/pf3_preview.py`、`pf3_embedded_preview.py` | 两类 PF3 的原生／内嵌色表预览路由 |
| `src/eds_r6_tool.m` | 只读探测、快照、验证及明确请求后的安装 |
| `scripts/audit_public_tree.py` | 公开源码与发行包的数据边界审计 |

## 构建 App

构建环境为 Apple Silicon Mac、Apple Command Line Tools／Swift／Clang，以及 Python.org 的 Python 3.13。公开构建从源码编译辅助程序，不要求取得开发者以前的私有二进制或快照。

```sh
python3 app/build_app.py --output "dist/Canon LUT 工具.app"
```

构建器会将所需 Python 标准库与动态库打包、瘦身为 arm64、改写本地依赖路径、拷入许可证，并执行本地签名检查。Canon 库始终从使用者本机的官方软件位置加载；源码和公开 App 不包含 Canon 专有库、基底 PF3 或机身快照。

当前发行版只做 ad-hoc 签名；Apple Developer ID 签名和公证应当作为独立的发行工作处理，不应靠修改用户系统保护来替代。

## 纯软件测试

在仓库根目录执行，无需相机或 Canon 安装：

```sh
PYTHONPATH=src python3 -m unittest discover -s src/r6lut -t src -p 'test_*.py'
python3 scripts/audit_public_tree.py
```

这些测试覆盖 CUBE 轴序、插值、输入域、量化、颜色变换及校验逻辑。它们不能证明新机型、新固件或新 SDK 的设备兼容性。

macOS 上可以只检查 Swift 编译而不启动 App：

```sh
swiftc -typecheck -parse-as-library -swift-version 5 \
  -target arm64-apple-macosx13.0 \
  -framework SwiftUI -framework AppKit -framework CryptoKit \
  -framework IOKit -framework CoreImage -framework ImageIO \
  app/CanonLUTTool.swift app/CameraConnectionMonitor.swift app/PhotoPreview.swift
```

GitHub Actions 运行纯 Python 测试、公开树审计和 macOS Swift typecheck。CI 不下载 Canon 软件，不开启相机会话，不发送硬件命令。

## 后端入口

```sh
PYTHONPATH=src python3 -m r6lut --help
```

本机初始化和转换：

```sh
PYTHONPATH=src python3 -m r6lut setup-context \
  --base ./my-standard.pf3 --camera-data ./my-camera-snapshot --output ./my-profile

PYTHONPATH=src python3 -m r6lut convert \
  --context ./my-profile --input ./my-look.cube --output ./my-output
```

CUBE 照片 Lookup 准备：

```sh
PYTHONPATH=src python3 -m r6lut preview-lut \
  --input ./my-look.cube --output ./my-preview-lookup --size 65
```

PF3 预览：

```sh
PYTHONPATH=src python3 -m r6lut preview-pf3 \
  --input ./my-style.pf3 --photo ./my-photo.CR3 --output ./my-pf3-preview \
  --helper "dist/Canon LUT 工具.app/Contents/MacOS/native_pf3_preview"
```

对于原生 PSE PF3，输出为来源绑定的 `before.png`、`after.png` 和 `metadata.json`；对于工具 dense PF3，输出内嵌 Lookup 与相应元数据，再由桌面解码和应用。不要把第二条路径标成 Canon 原生 RAW 显影。

## 设备与格式改动的验收

已验证的约束包括 R6 III 型号 `0x80000518`、固件 1.1.2、固定 SDK／Parser hash、描述符兼容性、type10、full33 几何、真实基础 PF3 和 settings 绑定。扩大范围前需要独立证据，不得为通过测试而删除守卫。

新的设备研究应依次记录：官方正常注册输入、编译输出、真实发送格式、独立设备读取，以及恒等／诊断 LUT 的实际成像。每次报告区分离线结构检查、缓存 getter、新设备请求和机内实拍，不能只给“setter 返回 0”。

源码更改应配套能检测实际错误的测试。例如轴序、比例换算、错文件绑定、损坏清单和取消后的遗留进程。图片 UI 的小幅可逆调整不必添加只重复实现细节的测试。

## 发行检查

1. 在干净的公开源码目录构建，确认许可证与源码版本匹配。
2. 运行纯软件测试与公开树审计。
3. 对 App 运行 `python3 scripts/audit_public_tree.py --bundle "dist/Canon LUT 工具.app"`。
4. 检查本地签名、空配置首次启动、CUBE 预览，以及依赖缺失时的明确错误。
5. 准备 ZIP、校验文件和准确的 Release notes，写明架构、依赖、公证状态与尚未实机验证的变化。

请勿把自己的 `context.json`、相机快照、原始 JPEG／RAW、第三方 LUT、生成 PF3、安装载荷或诊断日志加入 Git 历史。软件版本／错误码／脱敏的检查结果通常比原始二进制更适合公开 issue。
