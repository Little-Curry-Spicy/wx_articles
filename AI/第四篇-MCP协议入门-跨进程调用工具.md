# 让 AI 能调用「别处」的工具：MCP 协议入门

上一篇我们用 Node 在本地写了一个 Tool，让模型能查时间、读写文件。但现实里很多能力是用 **Java、Python、Rust** 等别的语言写的，跑在别的进程甚至别的机器上。如果每种都各搞一套接口，模型就很难统一调用。

**MCP（Model Context Protocol）** 就是一套**统一的协议**：不管工具是用什么语言写的、跑在本机还是远程，只要按 MCP 的规矩来，模型（或 Cursor 这类客户端）就能用同一套方式去调用。你可以把它理解成：**给模型扩展「上下文」和「能力」时，大家说好的同一种「语言」。**

---

## 一、MCP 最核心的一点：跨进程调用

Tool 可以不在「当前这个 Node 进程」里实现，而在**另一个进程**里——甚至另一台机器上。MCP 负责把「模型的请求」和「工具的响应」在进程之间传过去、传回来。

| 场景 | 怎么连 | 典型用法 |
|------|--------|----------|
| **本地、当前机器** | 用 **stdio**（标准输入/输出）和对方进程「管道」通信 | 本地开发、和 Cursor 等客户端同一台机对接 |
| **远程、另一台机器** | 用 **HTTP** 发请求、收响应 | 工具部署在服务器，客户端远程调用 |

也就是说：**同一条 MCP 协议，本地走 stdio，远程走 HTTP**，模型这边不用关心工具到底在哪儿。

---

## 二、动手写一个 MCP Server（含一个 Tool + 一个资源）

下面用 Node 写一个最简单的 **MCP Server**：提供一个「查用户」的**工具**，再提供一个「使用指南」的**静态资源**，最后用 **stdio** 接上，方便和 Cursor 等 MCP 客户端对接。

### 1. 先准备一点「假数据」

工具要查用户信息，咱们先用一个对象当简易数据库，后面工具从这里读：

```javascript
// 模拟一个小数据库
const database = {
  users: {
    '001': { id: '001', name: '张三', email: 'zhangsan@example.com', role: 'admin' },
    '002': { id: '002', name: '李四', email: 'lisi@example.com', role: 'user' },
    '003': { id: '003', name: '王五', email: 'wangwu@example.com', role: 'user' },
  },
};
```

### 2. 创建 MCP Server 并注册一个「查用户」工具

先 new 一个 `McpServer`，再给它**注册一个工具**：告诉客户端「我有个工具叫 query_user，输入用户 ID，返回用户信息」。

```javascript
const server = new McpServer({
  name: 'my-mcp-server',
  version: '1.0.0',
});

// 注册工具：按用户 ID 查用户信息
server.registerTool('query_user', {
  description: '查询数据库中的用户信息。输入用户 ID，返回该用户的详细信息（姓名、邮箱、角色）。',
  inputSchema: {
    userId: z.string().describe('用户 ID，例如: 001, 002, 003'),
  },
}, async ({ userId }) => {
  const user = database.users[userId];
  if (!user) {
    return {
      content: [{ type: 'text', text: `用户 ID ${userId} 不存在。可用的 ID: 001, 002, 003` }],
    };
  }
  return {
    content: [{
      type: 'text',
      text: `用户信息：\n- ID: ${user.id}\n- 姓名: ${user.name}\n- 邮箱: ${user.email}\n- 角色: ${user.role}`,
    }],
  };
});
```

- **description**：用自然语言描述「这个工具干啥、什么时候用」，客户端/模型靠它来决定要不要调用。
- **inputSchema**：参数长什么样（这里就是一个 userId 字符串）。
- 最后一个参数是**实际执行函数**：收到 userId 后去 `database.users` 里查，有就返回用户信息，没有就返回提示。

### 3. 注册一个「静态资源」：使用指南

除了「可调用的工具」，MCP 还可以提供**资源**（比如一篇文档、一段说明）。客户端可以按 URI 来读。下面注册一个「使用指南」资源：

```javascript
server.registerResource('使用指南', 'docs://guide', {
  description: 'MCP Server 使用文档',
  mimeType: 'text/plain',
}, async () => {
  return {
    contents: [{
      uri: 'docs://guide',
      mimeType: 'text/plain',
      text: `MCP Server 使用指南
功能：提供用户查询等工具。
使用：在 Cursor 等 MCP Client 中通过自然语言对话，客户端会自动调用相应工具。`,
    }],
  };
});
```

客户端（比如 Cursor）可以列出并读取这个资源，用户或模型就能看到这段使用说明。

### 4. 用 stdio 接上：和本地客户端通信

MCP Server 要真正「跑起来」，需要接一个**传输层**：负责收请求、发响应。

- **StdioServerTransport**：通过**标准输入（stdin）和标准输出（stdout）**和外界通信，适合**本机**和 Cursor 等客户端用管道对接（例如 Cursor 启动你这个进程，通过管道发 MCP 消息）。
- 若是远程部署，可以换成基于 HTTP 的 transport，协议不变，只是「怎么传」不同。

```javascript
const transport = new StdioServerTransport();
server.connect(transport);
```

这样，当前进程就变成一个「通过 stdio 对外提供 MCP 服务」的 Server 了；在 Cursor 里配置好这个 Server 后，用自然语言问「查一下 001 用户」，Cursor 会按 MCP 协议调用你的 `query_user`，把结果展示给你。

---

## 三、小结

- **MCP** 是一套「给模型扩展上下文与能力」的**统一协议**，不同语言、不同进程（甚至不同机器）写的工具，只要按 MCP 实现，就能被同一个客户端/模型用同一套方式调用。
- **跨进程**：本地一般用 **stdio** 和客户端管道通信，远程用 **HTTP**。
- 写一个 MCP Server 的典型步骤：**建 Server → 注册 Tool（和/或 Resource）→ 选 Transport（stdio 或 HTTP）→ connect**。  
  Tool 负责「模型能调用的能力」，Resource 负责「模型或用户能读的文档/数据」。

这样，您用 Node 写的 MCP Server 和用 Java、Python、Rust 写的 MCP Server 都能用同一套协议被 Cursor 或其它 MCP 客户端使用，这就是「协议统一」带来的好处。
