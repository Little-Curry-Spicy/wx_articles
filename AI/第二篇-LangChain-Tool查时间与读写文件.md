# 给 AI 装上「手脚」：LangChain Tool 从查时间到读写文件

上一篇我们讲了最基础的问答用法，但有一个局限：**大模型的知识有截止日期，不会自动更新**。比如问「现在几点了」「今天几号」，它答不出来。

要让 AI 能查时间、读文件、写文件，就需要给它配上 **Tool（工具）**。本文先做一个最简单的「获取当前时间」Tool，再做一个「读写文件」的完整示例，帮你把 Tool 的用法跑通。

---

## 一、最简单的 Tool：获取当前时间

### 1.1 定义一个 Tool

Tool 的本质是：**给模型一个「可调用的函数」+ 名称和描述**，模型在需要时会决定是否调用、传什么参数。

```javascript
import { tool } from "@langchain/core/tools";
import { z } from "zod";

const getCurrentTime = tool(
  async () => {
    const now = new Date();
    return now.toLocaleString("zh-CN", { timeZone: "Asia/Shanghai" });
  },
  {
    name: "get_current_time",
    description: "获取当前日期和时间，用于回答用户问「现在几点」「今天几号」等问题。",
    schema: z.object({}),
  }
);
```

三个字段都很重要：

| 字段 | 含义 |
|------|------|
| **name** | 工具名称，模型在决定调用时会用这个名称。 |
| **description** | 用自然语言描述「这个工具做什么、什么时候该用」，模型靠它来匹配用户意图。 |
| **schema** | 参数结构（用 Zod 定义）。这里无参数，所以是 `z.object({})`；有参数时在 object 里加字段即可。 |

### 1.2 绑定到模型并发起调用

```javascript
const model = new ChatOpenAI({
  modelName: "deepseek-chat",
  apiKey: "sk-xxxxx",
  configuration: { baseURL: "https://api.deepseek.com" },
  temperature: 0.7,
});

const modelWithTools = model.bindTools([getCurrentTime]);
```

之后用 `modelWithTools` 而不是 `model` 来 `invoke`，模型就可以在需要时返回「要调用哪个工具、传什么参数」。

```javascript
let messages = [
  new SystemMessage(
    "你是一个助手，请用中文回答。需要当前时间或日期时，请使用 get_current_time 工具。"
  ),
  new HumanMessage(question),
];

let response = await modelWithTools.invoke(messages);
console.log(response);
```

### 1.3 处理返回的 tool_calls

当用户问「现在几点了」时，模型不会直接答时间，而是返回 **tool_calls**，表示「请先调用这个工具，再把结果给我」：

```javascript
AIMessage {
  content: "我来帮您查看当前时间。",
  tool_calls: [
    { name: "get_current_time", args: {}, type: "tool_call", id: "call_00_xxx" }
  ],
}
```

我们需要：执行对应 Tool，把结果放进一条 **ToolMessage**，再连同之前的消息一起传回模型，让模型根据「工具返回的结果」生成最终回复。

```javascript
import { ToolMessage } from "@langchain/core/messages";

const id = response.tool_calls?.[0]?.id ?? "";
const content = await getCurrentTime.invoke({});
const toolMessages = new ToolMessage({ content, tool_call_id: id });

messages = [...messages, response, toolMessages];
response = await modelWithTools.invoke(messages);
```

此时 `response.content` 里就是模型根据「当前时间」生成的回答，例如「当前是 2025 年 2 月 4 日 下午 3:00」等。

---

## 二、多个 Tool 与循环调用：文件读写示例

当 Tool 不止一个、且一次推理中可能连续调用多次工具时，需要**循环**：只要模型还返回 `tool_calls`，就执行工具、把结果追加进消息、再调用一次模型，直到模型不再请求工具，只返回最终文本。

下面用四个与文件相关的 Tool 做示例：**创建目录、读文件、写文件、列出目录**。

### 2.1 定义四个文件类 Tool

路径都通过一个 `resolvePath` 转成相对当前工作目录的绝对路径（实现略），这里只给出 Tool 定义：

```javascript
// ============ 创建目录 ============
const createDirectory = tool(
  async ({ dirPath }) => {
    const full = resolvePath(String(dirPath));
    await fs.ensureDir(full);
    return "已创建目录: " + full;
  },
  {
    name: "create_directory",
    description: "创建目录；若父目录不存在会一并创建。路径相对于当前工作目录。",
    schema: z.object({
      dirPath: z.string().describe("相对路径，如 src/components 或 output"),
    }),
  }
);

// ============ 读文件 ============
const readFile = tool(
  async ({ filePath }) => {
    const full = resolvePath(String(filePath));
    const content = await fs.readFile(full, "utf-8");
    return content;
  },
  {
    name: "read_file",
    description: "读取文件内容（UTF-8 文本）。路径相对于当前工作目录。",
    schema: z.object({
      filePath: z.string().describe("文件相对路径，如 src/index.ts"),
    }),
  }
);

// ============ 写文件 ============
const writeFile = tool(
  async ({ filePath, content }) => {
    const full = resolvePath(String(filePath));
    await fs.outputFile(full, String(content), "utf-8");
    return "已写入: " + full;
  },
  {
    name: "write_file",
    description: "写入文件；若目录不存在会先创建。路径相对于当前工作目录。",
    schema: z.object({
      filePath: z.string().describe("文件相对路径"),
      content: z.string().describe("文件内容（纯文本）"),
    }),
  }
);

// ============ 列出目录 ============
const listDirectory = tool(
  async ({ dirPath }) => {
    const full = resolvePath(String(dirPath) || ".");
    const names = await fs.readdir(full);
    return names.join("\n");
  },
  {
    name: "list_directory",
    description: "列出目录下的文件名（一层）。传 . 或空表示当前目录。",
    schema: z.object({
      dirPath: z.string().describe("目录相对路径，. 表示当前目录"),
    }),
  }
);
```

### 2.2 绑定所有 Tool 并循环执行

```javascript
const allTools = [createDirectory, readFile, writeFile, listDirectory];
const modelWithTools = model.bindTools(allTools);

let messages = [
  new SystemMessage(`
    你是助手，可用工具：
    create_directory 创建目录；
    read_file 读文件；
    write_file 写文件（可生成新文件）；
    list_directory 列目录。路径都相对于当前工作目录。
    根据用户意图选工具，用中文总结。
  `),
  new HumanMessage(question),
];

let response = await modelWithTools.invoke(messages);
const maxToolRounds = 10; // 防止模型一直返回 tool_calls 导致死循环
let round = 0;

while (response.tool_calls?.length > 0 && round < maxToolRounds) {
  round++;
  const toolMessages = await runToolCalls(response.tool_calls);
  messages = [...messages, response, ...toolMessages];
  response = await modelWithTools.invoke(messages);
}
```

- **为什么用 while**：一次用户问题可能触发多次工具调用（例如先 `list_directory` 再 `read_file`），所以只要 `response.tool_calls` 非空，就继续执行工具并把结果塞回消息，再让模型「接着想」。
- **maxToolRounds**：避免模型反复只返回 tool_calls 而造成死循环，一般 10 轮足够。

### 2.3 统一执行 tool_calls：runToolCalls

```javascript
async function runToolCalls(
  toolCalls: { id?: string; name?: string; args?: Record<string, unknown> }[]
): Promise<ToolMessage[]> {
  const results: ToolMessage[] = [];
  for (const tc of toolCalls) {
    const id = tc.id ?? "";
    const name = tc.name ?? "";
    const fn = allTools.find((item) => item.name === name);
    let content: string;
    if (!fn) {
      content = "未知工具: " + name;
    } else {
      try {
        const out = await fn.invoke(tc.args ?? {});
        content = String(out);
      } catch (e) {
        content = "错误: " + (e instanceof Error ? e.message : String(e));
      }
    }
    results.push(new ToolMessage({ content, tool_call_id: id }));
  }
  return results;
}
```

逻辑：根据 `name` 在 `allTools` 里找到对应 Tool，用 `tc.args` 调用，把返回值或错误信息放进 `ToolMessage`，并带上 `tool_call_id`，这样模型才能把「哪次调用对应哪条结果」对上。

---

## 小结与下一步

- **为什么需要 Tool**：大模型不知道「当前时间」、不能直接读你磁盘上的文件，通过 Tool 把「查时间、读文件、写文件」等能力暴露给模型，它就能在回答时先调用再总结。
- **三步**：① 用 `tool()` 定义函数 + name/description/schema；② `model.bindTools([...])` 绑定；③ 调用后若存在 `tool_calls`，执行工具、追加 `ToolMessage`、再 `invoke`，直到模型只返回文本。
- **多 Tool 多轮**：用 `while` + `maxToolRounds` 循环处理 `tool_calls`，并用统一的 `runToolCalls` 生成 `ToolMessage` 列表。

下一篇可以在此基础上加上 **Memory**（对话记忆）或 **Agent**（让模型自动规划「先调用哪个工具、再调用哪个」），做一个真正能「记住上下文、会选工具」的助手。
