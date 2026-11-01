# 开发与构建

## 代码结构

| 位置 | 作用 |
| --- | --- |
| `app/CanonLUTTool.swift` | SwiftUI 界面、工作区导航、转换与安装任务 |
| `app/PhotoPreview.swift` | 系统照片解码、CUBE／PF3 渲染、文件夹浏览、多 LUT 选择与共享缩放状态 |
| `app/PhotoPreviewPanel.swift` | 多图／滑动比较，1 张原图 + 最多 8 个 CUBE 或 PF3 的画布与导出入口 |
| `app/PreviewPhotoView.swift` | 固定视口内绘制完整／填充及像素倍率照片，映射点击位置并约束鼠标响应边界 |
| `app/ComparisonLayout.swift` | 按实际图数计算满幅分区矩形，并计算完整显示的共同照片缩放尺寸 |
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

macOS 的文件夹扫描、筛选与多图选择回归检查：

```sh
python3 -B scripts/test_photo_preview.py
python3 -B scripts/test_comparison_layout.py
python3 -B scripts/test_preview_photo_view.py
```

构建 App 后可额外测试实际 sRGB 像素、八个 LUT 加原图的渲染、损坏文件隔离、缓存失效和快速换图取消，不需要相机、个人 LUT 或 Canon 软件：

```sh
python3 -B scripts/test_photo_preview.py --resources "dist/Canon LUT 工具.app/Contents/Resources"
```

这些测试覆盖 CUBE 轴序、插值、输入域、量化、颜色变换及校验逻辑。它们不能证明新机型、新固件或新 SDK 的设备兼容性。

macOS 上可以只检查 Swift 编译而不启动 App：

```sh
swiftc -typecheck -parse-as-library -swift-version 5 \
  -target arm64-apple-macosx13.0 \
  -framework SwiftUI -framework AppKit -framework CryptoKit \
  -framework IOKit -framework CoreImage -framework ImageIO \
  app/CanonLUTTool.swift app/CameraConnectionMonitor.swift app/PhotoPreview.swift app/PhotoPreviewPanel.swift app/ComparisonLayout.swift app/PreviewPhotoView.swift
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

原生 DPP 显影分为中间图像与定向输出两个阶段。中间图像尺寸可能不同于请求的预览尺寸；`DppProcessImageWithImageEx` 的矩形表示中间图像中的源区域，不能直接填入输出宽高。辅助程序通过 `DppGetImageInfo` 读取真实中间尺寸，按拍摄方向确定完整源区域，再单独指定输出尺寸。竖拍 RAW 的完整构图检查应同时对照前后两张图与系统显影参照，不能只核对 PNG 宽高比和成功返回码。

## 照片文件夹与多 LUT 对比

照片对比页可导入包含 CUBE、PF3 的文件夹，递归浏览子目录中的可选文件、查看格式标记、搜索名称并点击预览。CUBE、PF3 多图对比各自最多同时选择 8 个效果，另固定保留 1 张原图；文件名覆盖在照片角落，每格保留自己的生成状态与错误。多图模式去除底部重复缩略图，状态栏收为单行，渲染方法等说明通过详情查看。

画布按总图数使用稳定分区，各行铺满宽度、各行均分高度。行内图数依次为：1 张 `[1]`、2 张 `[2]`、3 张 `[2,1]`、4 张 `[2,2]`、5 张 `[3,2]`、6 张 `[3,3]`、7 张 `[3,2,2]`、8 张 `[3,3,2]`、9 张 `[3,3,3]`。原图始终位于第一格；取消一个效果会立即移除视图并重新分区，不绘制空占位。

默认“完整显示”按最受限分区计算全部照片的共同缩放尺寸，保留原始比例与完整内容；较宽的分区不会单独放大照片，周围仍可能有背景。“填充显示”改为各分区等比填满并裁切边缘，不拉伸照片；裁切只影响查看，PNG 导出仍使用完整渲染结果。

导入新照片时自动恢复“完整显示”，不沿用上一张照片的填充裁切。显示模式使用直接按钮切换，只更新固定原生视口的绘图方式，不改变分区尺寸，不重新解码照片或运行 LUT。`PreviewPhotoView.swift` 将图像绘制限制在视口内，防止放大后的图片尺寸参与 SwiftUI 父布局计算。旧版的 SwiftUI 图片虽然被 `.clipped()` 视觉裁切，鼠标响应区域仍可越过画布，导致顶部按钮无法点击；AX 触发按钮会绕过这个问题。验收必须用真实鼠标坐标执行填充→完整→滑动切换。布局算法检查和原生视口绘制／点击边界检查需分别运行。

联动缩放状态由照片模型统一保存：`previewZoomPercent` 为 `0`（适合窗口）、`100`、`150` 或 `200`，`previewZoomCenter` 为以照片左上角为原点的归一化坐标。每格将同一定位点放在本格中心，使用相同的像素倍率；不同分区宽高只影响可见范围，不改变定位点。100% 表示预览图的一个像素对应一个屏幕物理像素；原生视口按当前窗口的 backing scale 换算点尺寸。预览图长边上限为 1600 像素，百分比针对预览数据。

适合窗口时单击照片会记录该源图坐标，并进入上次选择的手动倍率（初始为 200%）；手动倍率下再次单击恢复适合窗口的完整画面。从倍率选项切换 100%／150%／200% 时保留定位点。切换 PF3、改变选择组内容、激活结果或切换多图／滑动方式均不重置此状态；每次导入新照片（包括相同路径）恢复适合窗口与居中。选择“适合窗口”会退出填充并显示完整画面，同时保留定位点供下次手动缩放使用；“重置视图”还会将定位点居中。选择“完整显示”或“填充显示”会退出手动倍率，填充状态下倍率菜单显示“填充窗口”；选择 100%／150%／200% 则进入明确的像素倍率。缩放只影响屏幕绘图，不重新运行 LUT，也不裁切导出的 PNG。

交互式原生视图只在自身边界内的可见照片区域接收点击，留白与画布外点击不触发缩放。点击坐标必须通过实际绘图矩形反算到源图归一化位置，不能直接按分区宽高归一化，否则完整显示留白、填充裁切或不同分区尺寸会使定位错位。回归检查应覆盖 Retina 像素倍率、不同宽高分区的同点定位、点击映射与边界、切换预设保留状态以及新照片重置。

PF3 与 CUBE 均可通过文件夹勾选加入多图，最多 8 个结果与 1 张原图。CUBE 和 PF3 保持独立的选择组：勾选另一种文件类型会开始新组。PF3 保留原生 Canon RAW／内嵌色表两条渲染路径；原生 PF3 的套用前参照是 Canon Neutral 显影，内嵌色表 PF3 使用 macOS 显影。PF3 批次以首个成功结果确定共同参照；后续结果若使用不同显影基准，保留该项错误并提示单独查看，其他结果继续生成，不将不同参照标作同一原图。

滑动模式只比较当前激活的效果，保留多图选择；返回多图模式会恢复全部已选项。单项状态点击文件名会替换当前效果，多项状态点击已选文件会激活该项，点击未选文件则追加（最多 8 个）。

PF3 逐项生成并显示状态。缓存保留来源绑定的套用前、套用后图像及渲染方法等元数据，便于切换激活项、滑动模式和添加预设时复用结果；照片或预设来源变化后需失效。取消与快速换图沿用当前任务令牌检查，过期任务不能覆盖新照片的结果。点击标题仅激活导出项并保持视图；点击照片同时激活该项并联动放大／缩回。PNG 导出始终使用当前激活项的完整结果。

文件夹内的 CUBE 默认按 sRGB LUT 直接套用，不应用 C-Log 照片适配，也不改动转换页已有的适配选择。PF3 始终读取文件保存的设置，不受这个开关影响。使用 Log LUT 文件夹时，关闭文件夹的 sRGB 直接套用开关，再选择所需输入曲线、色域和输出。源文件仅从用户选择的位置读取，不复制到源码树、App 或发布包。

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
