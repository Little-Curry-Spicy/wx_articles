# LangChain 模板化 Prompt：PromptTemplate、ChatPromptTemplate 与多轮对话

上一篇讲了怎么把大模型输出解析成结构化数据。这篇换个前提：**你有一堆「带占位符」的提示词**，想固定格式、只换变量，或者做多轮对话时把「历史消息」塞进模板里。LangChain 的 **Prompt 模板**就是干这个的——用 `{变量名}` 占位，`format` 或 `formatMessages` 填进去，再交给模型。

**先说明一点**：模板解决的是「**同一套话术、不同参数**」和「**多轮对话时历史往哪放**」的问题。不用模板也可以自己拼字符串，但模板化之后更好维护、复用，也方便和 `partial`、`pipe(model)` 链式用。下面按「单段模板 → 多角色对话模板 → 历史消息占位 → 固定部分变量 → 链式调用」顺序讲。

---

## 一、PromptTemplate：单段字符串，占位符 `{变量名}`

**干啥的**：把一段文字里需要动态替换的地方写成 `{变量名}`，调用时传入变量对象，得到**一整段填充好的字符串**。适合一次性拼出一整段给模型（若模型接字符串）。

```ts
import { PromptTemplate } from "@langchain/core/prompts";

const greetTemplate = new PromptTemplate({
  inputVariables: ["name", "role"],
  template: "你好，{name}！你正在以{role}的身份与 AI 对话。请简要介绍一下你自己。",
});

const str = await greetTemplate.format({ name: "小明", role: "产品经理" });
// 得到："你好，小明！你正在以产品经理的身份与 AI 对话。请简要介绍一下你自己。"
// 可直接把 str 交给 model.invoke(str)
```

**一句话**：PromptTemplate = 单段字符串 + `{变量}`，`format(变量对象)` 得到填充后的字符串，适合一次性整段发给模型。

---

## 二、ChatPromptTemplate：多角色消息模板（system / human / ai）

**干啥的**：Chat 模型要的是**多条消息**（system、human、ai），不是一根字符串。ChatPromptTemplate 由多条「消息模板」组成，每条里可以有 `{变量名}`，最后用 `formatMessages(变量对象)` 得到 **BaseMessage[]**，直接传给 `model.invoke(messages)`。

```ts
import {
  ChatPromptTemplate,
  SystemMessagePromptTemplate,
  HumanMessagePromptTemplate,
} from "@langchain/core/prompts";

const chatTemplate = ChatPromptTemplate.fromMessages([
  SystemMessagePromptTemplate.fromTemplate(
    "你是一个{style}的助手。回答时要{constraint}。"
  ),
  HumanMessagePromptTemplate.fromTemplate("{question}"),
]);

const messages = await chatTemplate.formatMessages({
  style: "简洁专业",
  constraint: "控制在三句话以内",
  question: "什么是 RAG？",
});
const response = await model.invoke(messages);
```

这样 **system 设定**（风格、约束）和**用户问题**都从变量来，改一处就能换风格或换题。

**一句话**：ChatPromptTemplate = 多条消息模板（system/human 等），`formatMessages()` 得到消息数组，直接给 Chat 模型用。

---

## 三、MessagesPlaceholder：在模板里预留「历史消息」位置

**干啥的**：做**多轮对话**时，除了「当前用户输入」，还要把**之前的几轮 human/ai 消息**一起发给模型。MessagesPlaceholder 在 ChatPromptTemplate 里占一个「坑」，`formatMessages` 时用**变量名**传入一条或多条 BaseMessage，它们会按顺序插在这个位置，**不参与** `{xxx}` 的字符串替换。

用法：`new MessagesPlaceholder("变量名")`，变量名对应 `formatMessages({ 变量名: BaseMessage[] })`。适合：system 固定，中间是历史，最后是当前 input。

```ts
import { MessagesPlaceholder } from "@langchain/core/prompts";
import { HumanMessage, AIMessage } from "@langchain/core/messages";

const chatWithHistoryTemplate = ChatPromptTemplate.fromMessages([
  SystemMessagePromptTemplate.fromTemplate(
    "你是客服助手。根据对话历史回答用户，保持礼貌简洁。"
  ),
  new MessagesPlaceholder("history"),
  HumanMessagePromptTemplate.fromTemplate("{input}"),
]);

// 有历史时：传入 history 数组
const messages = await chatWithHistoryTemplate.formatMessages({
  history: [
    new HumanMessage("我想查订单 12345 的物流"),
    new AIMessage("好的，正在为您查询订单 12345 的物流信息，大概需要 3 天左右到货。"),
  ],
  input: "大概什么时候能到？",
});
const response = await model.invoke(messages);
```

**首轮没有历史**：传空数组即可。若希望「没有历史也不报错」，可以用 `optional: true`：

```ts
new MessagesPlaceholder({ variableName: "history", optional: true })
// 首轮：formatMessages({ history: [], input: "你好，请问 RAG 是什么？" })
```

**一句话**：MessagesPlaceholder = 在模板里占一个坑，formatMessages 时把「历史消息数组」塞进去，多轮对话必备。

---

## 四、partial：固定部分变量，得到「部分填充」的模板

**干啥的**：有些变量是**固定设定**（如 system 的风格、约束），每轮只换用户问题。用 `partial(固定变量对象)` 得到一个新模板，之后只需传**剩余变量**，不用每次都传 style、constraint。

```ts
const partialChat = await chatTemplate.partial({
  style: "温暖贴心",
  constraint: "用一两句话说明白",
});
const messages = await partialChat.formatMessages({
  question: "你好，请问 RAG 是什么？",
});
const response = await model.invoke(messages);
```

注意：`partial()` 返回的是 **Promise**，要 `await`。适合：系统设定固定，只传每轮不同的 question / input。

**一句话**：partial = 先固定一部分变量，得到「半成品」模板，后面只填剩下的变量。

---

## 五、链式使用：prompt.pipe(model)，invoke 时只传变量

**干啥的**：把「模板 + 模型」串成一条**链**，调用时只传变量，一步得到模型回复。不用自己先 `formatMessages` 再 `model.invoke`。

```ts
const partialChat = await chatTemplate.partial({
  style: "简洁",
  constraint: "一句话",
});
const chain = partialChat.pipe(model);
const result = await chain.invoke({ question: "用一句话解释 API 是什么。" });
// result 是 AIMessage，result.content 即回复文本
```

这样**模板 + 模型**变成一个 Runnable，方便和别的步骤再 `pipe`（如加输出解析、加 Tool）。

**一句话**：prompt.pipe(model) = 模板和模型串成链，invoke 只传变量，一步拿回复。

---

## 小结

| 能力 | 用法 |
|------|------|
| 单段字符串模板 | PromptTemplate，`{变量}`，`format()` |
| 多角色对话模板 | ChatPromptTemplate.fromMessages，`formatMessages()` |
| 多轮对话历史 | MessagesPlaceholder("history")，传 BaseMessage[]；可选 optional: true |
| 固定部分变量 | template.partial({ ... }) |
| 链式调用 | template.pipe(model)，invoke({ 变量 }) |

先把「单段用 PromptTemplate、对话用 ChatPromptTemplate」「多轮用 MessagesPlaceholder」「复用设定用 partial、串联用 pipe」对上号，写对话和 RAG 时的 prompt 就能少写重复代码、结构更清晰。后面有机会可以再写 Few-shot 模板、或和输出解析一起链成「模板 → 模型 → 解析」一整条。

---

*第九篇 | LangChain 模板化 Prompt：PromptTemplate、ChatPromptTemplate 与多轮对话*
