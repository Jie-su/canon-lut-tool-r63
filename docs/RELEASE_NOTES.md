# Canon LUT 工具 R63 · v1.3.0-beta.1

首个公开 Beta，面向 Apple Silicon Mac。源码使用 MIT 许可证，保留上游署名。

## 下载

- `Canon-LUT-Tool-R63-v1.3.0-beta.1-macOS-arm64.zip`：解压后的完整 App，包含私有 Python 运行环境，无需为运行另装 Python。
- `SHA256SUMS.txt`：下载校验值。
- GitHub 自动提供源码归档；构建与继续开发见仓库文档。

## 已包含

- 深色照片工作台，左右并排与滑动对比，PNG 导出。
- CUBE 与 PF3 预览，C-Log 2/3 照片近似适配。
- 批量 CUBE → PF3／full33；R6 Mark III 1.1.2 实验性 USB 写入。
- 相机自动识别、独立备份及强制设备回读。
- 原创 App 图标、中文指南、开发说明、脱敏 R7→R6 III 技术总结和 CI。

## 首次使用

CUBE 照片预览可以直接使用。转换与写入前，需自己安装官方 EOS Utility／PSE，导出自己的 Standard 基底，并通过 App 建立本机配置。

公开包不包含 Canon 专有库、使用者基础 PF3、相机快照、照片或第三方 LUT。

## 当前范围

- 仅 arm64 macOS；应用目标为 macOS 13 及以上，新机型 RAW 仍取决于系统支持。
- 原生 PSE PF3 预览需要本机 Canon 软件和对应 Canon RAW；工具 dense PF3 使用照片近似预览。
- 此包为 ad-hoc 签名，尚未进行 Developer ID 签名与公证。
- 历史硬件证据限一台 R6 III 1.1.2 的恒等、红蓝交换、机内 JPEG、一次重启与后续多槽回读。公开版配置改造只做了离线/打包验证，没有追加硬件写入试验。
- 新版本不包含用户的机内预设；请使用自己的合法 LUT 或原生 PSE 文件。

## 发布验证

26 项纯 Python 测试、Swift 类型检查、公开源码与发行包审计、ad-hoc 签名验证通过。实际发行包在无捆绑配置的首次启动状态完成原创示例 CUBE 对比，并用仅保存在本机的配置完成离线转换。

English: First public macOS Apple Silicon beta with CUBE/PF3 photo comparison, local user-owned setup, batch conversion and experimental R6 Mark III installation. No Canon libraries or private camera/photo/LUT data are distributed. See SETUP and DEVELOPMENT for prerequisites and verified scope.
