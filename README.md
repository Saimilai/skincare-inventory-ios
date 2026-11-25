# 库存手记 · 在线 IPA

把现有[库存手记网站](https://skincare-k-test-20261115.pages.dev/)装进独立的 iOS App，供已安装且可正常使用 TrollStore（巨魔）的设备安装。当前 App 版本为 `1.0.1`；网页显示的版本由网站发布独立管理。

1.0.1 修复表单录入时的键盘安全区域布局，避免键盘遮挡操作区域。已发布的 1.0.0 保留为历史版本；更新时使用同一 Bundle ID 覆盖安装。

App 使用持久化 WKWebView 加载原固定网址。库存保存在这个 App 的本地容器里，关掉再打开仍可读取；网站更新后，重新打开或刷新会加载网站的新内容。打开、重新加载页面需要网络，本工程不承诺离线打开网页。

App 和 Safari 的库存、快照与备份状态相互独立，不会自动同步。首次使用请在 Safari 原网页导出 JSON，再导入 App。JSON 用于恢复库存，Excel 用于查看和整理；修改 Excel 不会回写库存。

## 安装与使用

从本仓库的 **Releases** 下载 `SkincareInventory-1.0.1-TrollStore.ipa`，在 TrollStore 中安装。完整步骤见 [巨魔安装说明](docs/INSTALL.zh-CN.md)。

- 支持 arm64、iOS 14.0 及以上的设备构建；能否用巨魔安装仍取决于设备系统是否受 TrollStore 支持。
- JSON 备份、Excel 导出与分享接入 iOS 的文件/分享界面，JSON 导入沿用网页的内容校验和覆盖确认。
- 网页中的备份时间沿用现有网站语义：生成文件或交给系统分享时就可能更新，不能证明文件已存入网盘。请以“文件”或网盘里实际存在、能打开的 JSON 为准。
- 固定 Bundle ID：`io.github.saimilai.skincareinventory`。覆盖更新时沿用它，避免意外创建第二个独立库存。

## 免费构建

本工作流仅允许**公开仓库**手动触发，使用 GitHub 的标准 `macos-15-intel` runner。该运行器在公开仓库的计算免费，不使用付费 larger runners、开发者证书或签名服务。模拟器验收和设备打包各用一个最长 20 分钟的任务，中间以一个保留 1 天的小型 Actions artifact 传递测试证据。打包任务核对同次运行、源码提交、版本和证据校验值后才生成 IPA；Release 发布成功后立即删除这个临时 artifact，长期产物保存在 Release 附件中。

测试失败时保留截图与日志供定位，诊断 artifact 同样只保留 1 天，失败的结果不会交给打包任务。

1. 在公开的 GitHub 仓库中打开 **Actions → Build TrollStore IPA → Run workflow**。
2. 等待网页测试、Python 单元测试、iOS 18.5 模拟器 UI 测试及设备构建完成。
3. 在 **Releases → v1.0.1** 下载 IPA、`SHA256SUMS.txt`、`validation.json`、`test-report.md` 和包含模拟器截图的 `simulator-evidence.zip`。同页提供与该提交对应的源码 ZIP。

工作流固定 Xcode 16.4；如果 GitHub 镜像将来移除此版本，构建会失败并要求维护工程，不会自动切换到未知工具链。每次手动运行的构建号递增。同一提交重跑可覆盖附件；源码变化后必须递增工作流中的 App 版本，避免旧 tag 的源码 ZIP 与新 IPA 不一致。

私有仓库的 Actions 使用账号免费额度，额度耗尽后可能收费，因此本工作流不会在私有仓库中运行。这里的免费说明不代表该账号其他仓库或服务的费用状态。

费用与平台依据：[GitHub 标准运行器](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)、[Actions 计费](https://docs.github.com/en/billing/concepts/product-billing/github-actions)、[Release 附件](https://docs.github.com/en/repositories/releasing-projects-on-github/about-releases)。

## 本地检查与 macOS 构建

网页兼容逻辑可在有 Node.js 的电脑上检查：

```sh
node --test Tests/web-compatibility.test.js
python3 -m unittest discover -s Tests -p 'test_*.py' -v
```

完整构建需要 macOS、Xcode 16.4、Node.js、Python 3，以及已安装的 iOS 18.5 iPhone 模拟器：

```sh
APP_VERSION=1.0.1 BUILD_NUMBER=1 bash scripts/build_ipa.sh
```

构建脚本运行测试后，为 arm64/iOS 14.0 编译，添加 ad hoc 签名，再生成 `Payload/SkincareInventory.app` 结构的 IPA。它不使用 App Store 导出流程或 provisioning profile；TrollStore 安装时会重签。产物和报告位于 `build/artifacts/`，详细日志位于 `build/logs/`。

验证脚本使用 Python 标准库核对 ZIP 路径、Info.plist、Mach-O 架构与最低系统，并在 macOS 调用 codesign 验证实际签名。静态测试可显式跳过执行 codesign；这种结果会标为 `static_checks_passed`，不能当作正式产物验收。

## 验证边界

通过工作流只代表该提交通过自动检查、模拟器测试和产物校验。**尚未在用户真实 iPhone / TrollStore 上验证安装、启动、文件分享以及覆盖更新后的数据保留。**请参照 Release 中本次实际生成的测试报告，不要把工程里的说明当成已经完成的实机测试。

库存与导出内容由用户保存在设备上，工程、测试和安装包不包含用户真实库存。公开仓库仅用于这个在线封装工程。

本工程采用 [MIT License](LICENSE)；TrollStore 及原网站各自遵循其适用许可。
