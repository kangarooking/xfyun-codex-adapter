# 讯飞 Coding Plan 接入 Codex 一键适配器

这个工具用于临时解决 CC Switch v3.15.0 对 Codex 的一个兼容问题：Codex 使用 OpenAI Responses API，而讯飞 Coding Plan 当前稳定可用的是 OpenAI Chat Completions API。

安装后会在本机启动一个只监听 `127.0.0.1` 的轻量适配器：

```text
Codex -> http://127.0.0.1:18666/v1/responses -> 讯飞 /v2/chat/completions
```

## 前置条件

1. macOS
2. 已安装并打开过 CC Switch
3. 已开通讯飞 Coding Plan，并拿到专属 API Key

## 一键安装

国内用户优先使用 Gitee：

```bash
curl -fsSL https://gitee.com/kangarooking/xfyun-codex-adapter/raw/main/install.sh | bash
```

如果你能稳定访问 GitHub，也可以使用 GitHub 备用链接：

```bash
curl -fsSL https://raw.githubusercontent.com/kangarooking/xfyun-codex-adapter/main/install.sh | bash
```

如果你是下载压缩包后安装，在终端运行：

```bash
cd xfyun-codex-adapter
bash install.sh
```

根据提示粘贴你的讯飞 Coding Plan API Key。脚本会自动：

1. 安装本地适配器
2. 注册 macOS 后台启动项
3. 启动 `http://127.0.0.1:18666`
4. 在 CC Switch 里新增或更新独立的 `Xunfei Astron Adapter`
5. 自动把 CC Switch 的 Codex provider 切到 `Xunfei Astron Adapter`
6. 切换前会先把当前 Codex 配置回填到原 Provider，方便之后切回

安装完成后，只需要重启 Codex。之后想切回官方或其他模型，直接在 CC Switch 里切换原来的 Provider，然后重启 Codex 即可。

脚本不会把讯飞配置写进原 Provider；讯飞配置会保存在单独的 `Xunfei Astron Adapter` Provider 里。

## 卸载

```bash
bash uninstall.sh
```

如果卸载时 Codex 仍然指向这个适配器，脚本会尝试切回 CC Switch 里的其他 Codex Provider。

## 注意

- 不要把自己的 API Key 发给别人。
- 这个方案是临时兼容方案。等 CC Switch 正式版原生支持 Codex `Responses -> Chat Completions` 转换后，可以切回官方直连方案。
