# 用 DeepSeek + LangChain 搭建一个可用的问答 AI

本文手把手带你用 **DeepSeek** 和 **LangChain** 做一个常用的问答 AI，流程同样适用于其他兼容 OpenAI 接口的大模型。

---

## 一、获取 API Key

使用大模型前必须先配置 **API Key**。厂商通过它统计你消耗的 token 用量并计费。

- 打开：<https://platform.deepseek.com/api_keys>
- 登录后创建并复制你的 Key（格式一般为 `sk-xxxxxx`），后面会用到。

---

## 二、引入 LangChain 并配置模型

### 2.1 安装依赖

LangChain 官方文档：<https://docs.langchain.com/oss/javascript/langchain/install>

```bash
pnpm add langchain @langchain/core
```

> 要求 Node.js 20+

### 2.2 配置 DeepSeek 模型

DeepSeek 兼容 OpenAI 的接口，可以用 `@langchain/openai` 里的 `ChatOpenAI`，通过 `baseURL` 指向 DeepSeek：

```javascript
import { ChatOpenAI } from '@langchain/openai';

const model = new ChatOpenAI({
  modelName: 'deepseek-chat',
  apiKey: 'sk-xxxxxx',  // 替换为你在 DeepSeek 获取的 Key
  configuration: {
    baseURL: 'https://api.deepseek.com',
  },
  temperature: 0.7,  // 采样温度：越高输出越灵活，但也更容易跑题
});
```

- **apiKey**：填刚才在 DeepSeek 获取的 Key。  
- **temperature**：控制随机性，0～1 之间，一般 0.7 左右即可。

---

## 三、理解消息角色：SystemMessage 与 HumanMessage

现代聊天模型的输入不是「一段话」，而是一组**带角色（role）的消息**，例如：

```json
[
  { "role": "system", "content": "你是..." },
  { "role": "user", "content": "我想问..." }
]
```

在 LangChain 里对应为：

| 类型            | 含义                         |
|-----------------|------------------------------|
| **SystemMessage** | 系统设定：模型「该怎么回答、遵守什么规则」 |
| **HumanMessage**  | 用户输入：用户「问了什么」           |

源码里二者的核心区别就是 `type` 不同：`SystemMessage` 的 `type` 为 `"system"`，`HumanMessage` 的 `type` 为 `"human"`。了解这一点即可，日常用上面的语义区分就够了。

---

## 四、跑通第一个问答

```javascript
import { HumanMessage, SystemMessage } from '@langchain/core/messages';

async function main() {
  const response = await model.invoke([
    new SystemMessage('你是一个助手，请用中文回答用户的问题。'),
    new HumanMessage('你是谁？'),
  ]);
  console.log(response);
}
main();
```

- `model.invoke()` 返回的是 **Promise**，所以用 `await` 拿到结果。  
- 返回类型是 **AIMessage**，我们主要用其中的 **content**（模型回复的文本）。

示例返回结构（节选）：

```javascript
AIMessage {
  content: "你好！我是 DeepSeek，由深度求索公司创造的 AI 助手...",
  response_metadata: {
    tokenUsage: { promptTokens: 17, completionTokens: 124, totalTokens: 141 },
    // ...
  },
  // ...
}
```

**实际使用时**：用 `response.content` 或 `response.content.toString()` 即可得到模型回复的字符串。

---

## 五、保存对话记忆（多轮上下文）

默认每次只发「当前这一句」，模型没有上一轮的上下文。要实现**连续多轮对话**，需要把历史问答一起传给模型。

### 5.1 思路

- 用数组（如 `qaRecords`）保存 `{ question, answer }`。  
- 每次提问时，把「系统设定 + 历史问答 + 当前问题」拼成一条消息列表再调用 `invoke`。  
- 拿到回复后，把本轮 `question` 和 `answer` 写入记录并持久化（例如写入 JSON 文件）。

### 5.2 消息列表示例

```javascript
const messages = [
  new SystemMessage('你是一个助手，请用中文回答用户的问题。'),
  ...qaRecords.flatMap((r) => [
    new HumanMessage(r.question),
    new AIMessage(r.answer),
  ]),
  new HumanMessage(question),
];
const response = await model.invoke(messages);
const answer = response.content.toString();
qaRecords.push({ question, answer });
saveQARecords(qaRecords);
```

这样模型就能看到「之前问过什么、答过什么」，回答会具备上下文。

### 5.3 持久化到 JSON 文件

```javascript
const path = require('path');
const fs = require('fs');

const RECORDS_PATH = path.join(__dirname, 'qa-records.json');

function saveQARecords(records) {
  fs.writeFileSync(RECORDS_PATH, JSON.stringify(records, null, 2), 'utf-8');
}
```

`qa-records.json` 里会按轮次保存问答，例如：

```json
[
  { "question": "你叫什么名字", "answer": "我是 DeepSeek..." },
  { "question": "你现在叫老张", "answer": "哈哈，好的！如果你喜欢的话..." },
  { "question": "你叫什么名字", "answer": "哈哈，现在你可以叫我「老张」啦！..." }
]
```

这样再次问「你叫什么名字」时，模型会结合前面「改名叫老张」的设定来回答。

---

## 小结与下一步

- **API Key**：在 DeepSeek 控制台获取，并填入 `ChatOpenAI` 的 `apiKey`。  
- **消息角色**：用 `SystemMessage` 定规则，用 `HumanMessage` 传用户问题，用 `AIMessage` 表示历史回复。  
- **多轮对话**：把历史 `question/answer` 拼进 `invoke` 的消息列表，并持久化到文件或数据库。

当前是用 **JSON 文件** 记录上下文，后续可以改用 LangChain 的 **Memory** 组件（如 BufferMemory、SummaryMemory）来管理短期/长期记忆，使结构更清晰、更易扩展。

如果你已经跑通上面的流程，下一步可以尝试：加一个简单的前端界面、接入 RAG 做「基于文档的问答」，或为模型绑定 Tool 实现查天气、查数据库等能力。
