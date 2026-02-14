# 用 n8n 做一个「RSS → AI 总结 → 飞书推送」的小工具

效果如图所示：RSS 有新文章自动拉取，AI 总结成中文要点，直接推到飞书群。如果你也想做一个，跟着下面步骤即可。

---

## 一、先有一个 n8n

**有服务器**：装 Docker，配置镜像加速后拉 n8n 镜像，按 [官方文档](https://docs.n8n.cn/hosting/installation/docker/#n8n) 启动即可。国内拉镜像可配加速，例如：

```json
{
  "registry-mirrors": [
    "https://docker.m.daocloud.io",
    "https://docker.hlmirror.com",
    "https://docker.1ms.run"
  ]
}
```

**没服务器**：用 [n8n 云服务](https://n8n.io/)，注册登录即有，免费 30 天。

---

## 二、搭工作流：3 个节点搞定

### 节点 1：RSS Feed Trigger

**RSS**：Really Simple Syndication，一次订阅，有新内容自动推送。

- **Schedule**：`every day`，`hour:14`（每天下午 2 点拉取）
- **URL**：`https://cointelegraph.com/rss`（可换成任意 RSS）
- 点「Test step」可看右侧输出

### 节点 2：HTTP Request — 调 DeepSeek 总结

用 DeepSeek 做内容的总结和改写。API Key 在 [DeepSeek 控制台](https://platform.deepseek.com/api_keys) 创建。

- **URL**：DeepSeek 的 chat 接口
- **Send Body**：勾选，Body 内容为：

```json
{
  "model": "deepseek-chat",
  "messages": [
    {
      "role": "system",
      "content": "你是一名资讯分析助手。请把输入新闻总结为中文，输出结构固定：【一句话结论】+【3-5条要点】+【影响/机会】+【原文链接】。"
    },
    {
      "role": "user",
      "content": "标题：{{ $json.title }}\n时间：{{ $json.pubDate }}\n内容：{{ $json.contentSnippet || $json.content }}\n链接：{{ $json.link }}"
    }
  ],
  "temperature": 0.3
}
```

其中 `{{ $json.title }}` 是 n8n 的变量替换，会自动插入上一步 RSS 的字段。

输入是左侧 RSS 原文，输出是右侧 AI 总结结果。

### 节点 3：HTTP Request — 发到飞书

按 [飞书自定义机器人文档](https://open.feishu.cn/document/client-docs/bot-v3/add-custom-bot?lang=zh-CN) 创建机器人，拿到 **Webhook 地址**（接收推送的 URL）。

- **URL**：填机器人的 Webhook 地址
- **Method**：POST
- **Body**：

```
{{ JSON.stringify({ msg_type: "text", content: { text: $json.choices[0].message.content } }) }}
```

若 Body 需单独配置 `msg_type` 和 `content` 字段，则：
- `msg_type`：`text`
- `content`：`{{ JSON.stringify({ text: $json.choices[0].message.content }) }}`

---

## 三、串联起来

RSS 拉取 → HTTP Request（DeepSeek）总结 → HTTP Request（飞书）推送。三条连线接好，就能收到类似下图的飞书消息。

下一篇文章：教你如何用国内服务器免费访问国外 RSS。

---

*AI 系列 | 用 n8n 做 RSS + AI 总结 + 飞书推送*
