# 参与开发

欢迎提交可复现的错误、文档修正和有明确范围的代码改动。先阅读 [开发说明](docs/DEVELOPMENT.md) 与 [R7 → R6 III 技术记录](docs/R7_TO_R6III.md)。

## 报告问题

请提供应用版本、macOS／CPU 架构、操作步骤、预期与实际结果，以及相关错误码。相机问题还应注明型号、固件、Canon 软件版本，说明记录来自离线检查、普通 getter、显式新设备读取，还是实际机内 JPEG。

请勿公开上传完整相机快照、descriptor、序列号、RAW／私人照片、个人 context、安装载荷、第三方 LUT 或授权受限的 Canon 软件。日志与截图先删去个人路径和私人内容。若需要某份素材才能复现，优先生成可公开的合成测试输入。

## 提交改动

1. 为一个具体问题开分支，保留相关版权与许可。
2. 对数学、格式或绑定校验的修改，增加能检测实际错误的测试。
3. 运行纯 Python 测试和公开树审计；Swift 改动在 macOS 做 typecheck 或构建。
4. 在 PR 中说明触发条件、修改后的行为、验证方式和已知限制。

```sh
PYTHONPATH=src python3 -m unittest discover -s src/r6lut -t src -p 'test_*.py'
python3 scripts/audit_public_tree.py
```

不得仅为“让新机型能运行”而移除模型、固件、SDK／Parser hash、描述符或载荷几何守卫。支持新环境需要官方输入／输出和实际设备证据，CI 通过不能代替这些验证。

## 提交与发行边界

只提交代码、文档和拥有再分发权的素材。不要提交 `context.json`、相机备份、生成 PF3／full33、Canon 专有二进制或第三方 LUT。新依赖需写明来源与许可，发行包中的依赖通知也应同步更新。

项目使用 MIT 许可证；贡献应当是你有权按该许可提交的内容。Canon、其他研究项目及运行时依赖的许可各自独立，见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
