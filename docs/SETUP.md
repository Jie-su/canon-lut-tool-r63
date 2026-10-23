# 首次使用与本机配置

公开版把程序和个人相机数据分开。下载 App 后可以立即使用 CUBE 照片预览；转换与写入使用你自己建立的本地配置，不随发行包提供另一台相机的 PF3 或快照。

## 1. 安装与预览

从仓库 [Releases](https://github.com/Jie-su/canon-lut-tool-r63/releases) 下载 arm64 App ZIP 和校验文件，解压后保留 App 完整目录。当前发行版仅面向 Apple Silicon Mac，应用最低目标为 macOS 13。新机型 RAW 的显影支持取决于实际 macOS 版本，Canon 组件另有其官方系统要求。

发行版暂未使用 Apple Developer ID 签名及公证，系统可能拒绝直接运行。请参考 [Apple 官方安全说明](https://support.apple.com/en-us/102445)，核对来源后自行决定如何处理系统提示。项目不要求关闭 Gatekeeper 或更改系统安全设置。

在“照片对比”中：

1. 导入 JPEG、PNG、HEIC、TIFF，或 macOS 支持显影的 RAW／CR3。
2. 选择自己的 CUBE；使用左右并排或拖动分割线比较。
3. 如 LUT 原本针对 C-Log，按其说明选择 C-Log 2／3、色域和输出编码。
4. 可以导出预览 PNG，源文件保持不变。

直接选择 PF3 时，界面会标明实际预览方式：原生 PSE 参数型 PF3 使用 Canon RAW 离线显影；本工具生成的 PF3 使用文件内嵌色表做照片近似预览。原生 PSE PF3 不支持在这里直接应用于 JPEG，请使用对应 Canon RAW。

## 2. 安装自己的 Canon 软件

请从 Canon 官方支持页面为你的机型安装合法取得的 EOS Utility 3 和 Picture Style Editor。此项目不会提供 Canon 安装包或专有二进制。

本次已验证软件环境为 EOS Utility 3.20.21 系列、PSE 1.32.20。程序实际按固定 EDSDK／EdsCFParse hash、R6 III 型号、固件和描述符守卫检查，不能仅凭相同界面版本号判断兼容。出现版本不匹配时停止，将脱敏后的错误码和版本报告给项目，不要自行移除守卫。

## 3. 准备自己的 Standard PF3

1. 用自己的 Canon RAW 在官方 PSE 中导出可编辑的 **Standard／标准** 基础 PF3。
2. 使用官方 EOS Utility 将同一份基底注册到 **用户定义 1**。它用于建立本次已验证转换路线所需的基线与参数。
3. 如果之后准备写入用户槽 2、3，也先使用官方流程初始化对应槽位。
4. 退出 EOS Utility，保持相机开机、唤醒，USB 模式选择照片导入／遥控。

请保留这份原始 PF3。不要使用未知来源的占位 PF3、零填充模板或其他人的机身快照。

## 4. 在 App 中建立本地配置

使用公开版的本机配置入口，选择自己的 Standard PF3，并读取或导入自己的只读相机快照。初始化会核对模型、固件、descriptor、设置和基底，绑定文件 hash，保存到使用者自己的 Application Support 目录。

读取快照不会替换槽位。初始化失败不会意味着需要强行写入；请先核对官方基底是否与用户定义 1 中注册的文件一致、相机是否可连接，以及 EOS Utility 是否已退出。

配置是个人运行数据，不应提交到 GitHub、随 issue 上传或拷给其他使用者作为通用模板。应用无法将未经初始化的其他机型自动变成支持机型。

### 开发者的 CLI 等价流程

以下示例在仓库根目录使用源代码后端。目录名是示例，需换为自己的文件；输出目录必须是新目录。

```sh
CANON_SDK="/Applications/Canon Utilities/EOS Utility/EU3/EOS Utility 3.app/Contents/Frameworks/EDSDK.framework/Versions/A/EDSDK"
"dist/Canon LUT 工具.app/Contents/MacOS/eds_r6_tool" snapshot "$CANON_SDK" ./my-camera-snapshot

PYTHONPATH=src python3 -m r6lut setup-context \
  --base ./my-standard.pf3 \
  --camera-data ./my-camera-snapshot \
  --output ./my-profile
```

`snapshot` 是只读设备获取；`setup-context` 校验已保存文件并生成本机配置。它们都不是写入命令。

## 5. 转换与相机写入

完成配置后，在“转换与写入”导入一个 CUBE 或文件夹，选择输出位置。每个 LUT 会输出 PF3、full33 和 manifest，必须放在一起。

CLI 转换示例：

```sh
PYTHONPATH=src python3 -m r6lut convert \
  --context ./my-profile \
  --input ./my-look.cube \
  --output ./my-output
```

输入适配可显式增加：

```text
--adaptation clog3 --log-gamut cinema-gamut --lut-output gamma24
```

上述值只是模式选择，不是自动识别 LUT。具体曲线、色域和输出必须匹配原 LUT 说明。

在 App 的生成列表为文件分配用户槽位，核对确认窗口后才开始写入。工具先保存独立备份，再发送载荷和设置，显式重新请求设备数据验证，并检查未选槽及当前活动状态。请保持相机开机和数据连接，操作期间不要同时运行 EOS Utility 或其他相机控制软件。

原生 PSE 参数型 PF3 可以走普通官方注册流程；本工具的 CUBE dense PF3 需要使用配套 full33 安装路线。不要用“普通 EOS Utility 能打开文件”代替效果验证。

## 6. 验证与恢复边界

首次在自己的环境尝试时，先使用自己生成的恒等与红蓝交换诊断 LUT，检查实时取景、机内 JPEG 及重新连接后的状态，再评估创意 LUT。结构读回通过不等于所有颜色都精确。

R6 III 此路线的写入 full33 为 431,616 字节，而读回可为 83,076 字节；两者不能直接要求字节相等。SDK 同会话普通 getter 可能返回缓存，工具会显式请求新数据。

读回备份不是可直接重发的 full33 恢复载荷。需要恢复时，应有自己的原始 PF3，或经过验证的原 full33 输入，再采用对应注册流程；项目不承诺任意 getter 备份可以自动原样恢复。

详细格式与历史验证范围见 [R7 → R6 III 技术记录](R7_TO_R6III.md)。
