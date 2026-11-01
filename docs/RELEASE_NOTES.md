# Canon LUT 工具 R63 · v1.3.7-beta.1

这次更新集中在照片对比：导入整个 CUBE／PF3 文件夹，最多同时查看 8 个效果与原图，并在同一位置联动缩放检查细节。本次汇总上个公开版 v1.3.0-beta.1 之后的更新；1.3.1–1.3.6 未单独公开发行。

## 下载

| 文件 | 用途 |
| --- | --- |
| `Canon-LUT-Tool-R63-v1.3.7-beta.1-macOS-arm64.zip` | 完整 App，包含独立 Python 运行环境，运行无需另装 Python 或 pip。 |
| `Canon-LUT-Tool-R63-v1.3.7-beta.1-developer.zip` | 对应版本的公开源码、开发说明、来源提交与文件校验清单，便于继续开发。 |
| `SHA256SUMS.txt` | 两个 ZIP 的 SHA-256 校验值。 |

[下载本版](https://github.com/Jie-su/canon-lut-tool-r63/releases/tag/v1.3.7-beta.1) · [完整更新记录](https://github.com/Jie-su/canon-lut-tool-r63/blob/v1.3.7-beta.1/CHANGELOG.md) · [与上一公开版比较](https://github.com/Jie-su/canon-lut-tool-r63/compare/v1.3.0-beta.1...v1.3.7-beta.1)

## 新增与改进

- **文件夹浏览**：同时识别 CUBE、PF3，递归浏览子目录，支持搜索与格式标记，点击名称即可预览。CUBE 文件夹默认使用 sRGB 直接套用；Log LUT 可关闭此选项后选择已有适配，PF3 沿用文件内保存的设置。
- **最多九图比较**：原图固定保留，最多勾选 8 个 CUBE 或 8 个 PF3；增删后按实际数量重新分区，没有空占位。两种类型分别建立比较组。
- **多 PF3 预览**：逐项显示生成状态，复用已经完成的结果。原生 PF3 使用 Canon Neutral 参照，内嵌色表 PF3 使用 macOS 显影参照；基准不同的单项提示单独查看，其他项继续生成。
- **同位置联动缩放**：单击照片中的部位，让所有预览同步定位放大；再次单击缩回。可选适合窗口、100%、150%、200% 和重置视图；切换 PF3、增删效果或切换多图／滑动模式保留倍率与定位点。
- **滑动与导出**：滑动对比显示当前激活项，返回多图保留选择；放大时仍可拖动分割线。点击标题选择导出项，PNG 始终保存完整预览结果。

## 修复

- 修复点击填充显示后，图片响应区域挡住工具栏，导致完整显示、滑动对比等按钮点不动的问题。
- 修正原生 PF3 显影把输出尺寸误用为源图区域的问题，避免竖拍 RAW 构图被放大裁切。
- 导入新照片自动恢复完整显示和居中位置，避免沿用上一张照片的填充裁切或缩放状态。
- 将照片限制在固定视口内绘制；显示与缩放切换只更新绘图，不重新运行 LUT 或 RAW 显影。

## 使用与范围

- 仅 **Apple Silicon／arm64、macOS 13 或更新版本**。此包采用 ad-hoc 签名，尚未进行 Apple Developer ID 签名与公证。
- 照片预览无需连接相机。原生 PSE PF3 预览需要本机受支持的 Canon 官方软件及对应 Canon RAW；本工具生成的内嵌色表 PF3 使用照片近似预览，两者均不等于机内实拍。
- **100% 指当前预览图像素对应屏幕物理像素**。预览长边最多 1600 像素，不是原始 RAW 的全分辨率显示。完整显示可能留白；填充显示保持比例并裁切边缘，PNG 导出不受查看裁切影响。
- 转换与写入继续要求自己的 Standard PF3 基底、只读相机快照和本地初始化配置。相机守卫仍限定 R6 Mark III／1.1.2 与固定 Canon 软件环境；本次没有改动写入流程或追加硬件写入测试。
- 两个 ZIP 均不包含私人 LUT、PF3、照片、相机数据、凭据或 Canon 专有组件；MIT 许可与上游署名保留。

[首次使用](https://github.com/Jie-su/canon-lut-tool-r63/blob/v1.3.7-beta.1/docs/SETUP.md) · [开发与构建](https://github.com/Jie-su/canon-lut-tool-r63/blob/v1.3.7-beta.1/docs/DEVELOPMENT.md)

## 验证

纯 Python 测试、Swift 类型检查、照片模型／布局／原生视口回归检查、公开源码与 App 内容审计、严格本地签名检查通过。实际 App 已验证多个原生 PF3 与 RAW 的离线预览、倍率选择、切换预设保留视图、拖动分割线及单击缩回。

English: This beta adds recursive CUBE/PF3 folder browsing, up to eight same-type looks plus the original, linked point zoom at 100%/150%/200%, cached multi-PF3 previews, and fixes for fill-mode input blocking and cropped native RAW previews. Percentages refer to preview pixels. App and developer ZIPs exclude private content and Canon binaries. macOS arm64 only; ad-hoc signed, not notarized. Camera compatibility and installation paths remain unchanged.
