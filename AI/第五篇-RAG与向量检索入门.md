# 让大模型「先查资料再回答」：RAG 与向量检索入门

大模型虽然很强，但有两个问题：**知识有截止日期**，**不知道你公司或你私人的文档**。  
**RAG（检索增强生成）** 的做法就是：在用户提问时，**先去知识库里把和问题相关的文档片段查出来**，把这些片段当作「背景知识」塞进发给大模型的 prompt 里，再让大模型**根据这些内容**来生成回答。这样，回答就更贴近你的资料，而不是「凭空想」。

但有一个关键问题：**用户问了一个问题，你怎么把「相关的」文档片段找出来？**  
比如用户问「水果的信息」，你希望把讲苹果、香蕉、草莓的文档都找出来。用**关键词搜索**行不行？  
不太行——用户可能用「苹果」查，文档里写的是「红富士」「青苹果」，关键词对不上就搜不到。所以要靠**语义**：意思相近的就能被找出来。这就需要用**向量（Vector）**来做**语义检索**。

---

## 一、用「向量」理解「语义相似」

可以把**向量**想成：把一段文字或一个概念，用一串数字表示，并且**意思越接近，这串数字在空间里离得越近**。

举一个极简例子：只用**两个维度**——  
- 维度 1：**可食用性**（0 = 不能吃，1 = 很能吃）  
- 维度 2：**硬度**（0 = 很软，1 = 很硬）

那可以粗略得到：

| 概念 | 向量 | 含义 |
|------|------|------|
| 水果 | [0.9, 0.3] | 很能吃，偏软 |
| 苹果 | [0.9, 0.5] | 很能吃，硬度适中 |
| 香蕉 | [0.9, 0.1] | 很能吃，很软 |
| 石头 | [0.1, 0.9] | 几乎不能吃，很硬 |

一眼能看出：**苹果、香蕉、水果**在「食用性高、偏软」这一块很接近，所以向量挨得近；**水果**和**石头**差得远，向量就离得远。  
在数学上，一般用**余弦相似度**（两个向量夹角的余弦值）来衡量「有多像」：夹角越小，相似度越高。  
也就是说：**把文字变成向量，再比向量的相似度，就能实现「按意思找相关文档」——这就是语义检索。**

---

## 二、谁把文字变成向量？嵌入模型

把「用户问题」和「文档」都变成向量的，是一种专门的模型，叫**嵌入模型（Embedding Model）**。

流程可以概括为：

1. **建知识库时**：把每段文档用嵌入模型转成向量，存进**向量数据库**，并在元信息里记下「这段向量来自哪篇文档、哪一页」。
2. **用户提问时**：把用户的问题也用嵌入模型转成向量，用**检索器（Retriever）**在向量库里找「和这个问题向量最像」的几段文档。
3. **拼 prompt**：把这几段文档当作「背景知识」拼进 prompt，再交给大模型，让大模型**基于这些片段**生成回答。

这就是 RAG 的完整链路：**问题 → 向量化 → 检索相关文档 → 文档 + 问题 一起给大模型 → 生成回答。**

---

## 三、用代码跑通一遍：以「喜羊羊与灰太狼」为例

下面用 **LangChain + 通义千问** 做一个小 Demo：把几段「喜羊羊与灰太狼」的故事当成知识库，用户问一个问题，先检索相关片段，再让大模型根据片段回答。

### 1. 准备大模型和嵌入模型

大模型负责「根据背景知识生成回答」，嵌入模型负责「把问题和文档变成向量」。

```javascript
const model = new ChatOpenAI({
  modelName: "qwen-plus",
  apiKey: env.QIANWEN_API_KEY,
  configuration: { baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1" },
  temperature: 0.7,
});

const embeddings = new OpenAIEmbeddings({
  modelName: "text-embedding-v3",
  apiKey: env.QIANWEN_API_KEY,
  configuration: { baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1" },
});
```

### 2. 准备「知识库」：几段故事文档

每段文档有**正文**（pageContent）和**元数据**（章节、角色、类型、心情等），方便后续筛选或展示来源。

```javascript
const documents = [
  new Document({
    pageContent: `在青青草原上有一个羊村，村里住着喜羊羊、懒羊羊、美羊羊、沸羊羊等小羊...`,
    metadata: { chapter: 1, character: "喜羊羊与羊村", type: "角色介绍", mood: "欢乐" },
  }),
  new Document({
    pageContent: `灰太狼住在狼堡里，和老婆红太狼一起生活。灰太狼整天想着抓羊...`,
    metadata: { chapter: 2, character: "灰太狼与红太狼", type: "角色介绍", mood: "搞笑" },
  }),
  // ... 更多片段（吸羊机、智斗、懒羊羊、结局等），结构相同
];
```

（文中示例里还有吸羊机、扮羊混进羊村、懒羊羊睡觉、羊村与狼堡日复一日等片段，此处省略重复结构。）

### 3. 向量化并存入向量库，再建检索器

用**内存向量库**（MemoryVectorStore）即可跑通流程；生产环境可换成 Redis、Pinecone 等。

```javascript
const vectorStore = new MemoryVectorStore(embeddings);
await vectorStore.addDocuments(documents);  // 把每段文档转成向量并存入

// 检索器：每次查「和问题最像」的 k 段文档，这里 k=3
const retriever = vectorStore.asRetriever({ k: 3 });
```

### 4. 用户提问 → 检索相关文档

用户问一个问题，检索器会拿问题的向量去库里找最相似的 3 段文档。

```javascript
const question = "喜羊羊是怎么对付灰太狼的吸羊机的？灰太狼最爱说哪句话？";
const retrievedDocs = await retriever.invoke(question);
```

想看「相似度」具体多少，可以用 `similaritySearchWithScore`（分数越低表示越相似，很多实现里会用 1−score 当「相似度」来展示）：

```javascript
const scoredResults = await vectorStore.similaritySearchWithScore(question, 3);
scoredResults.forEach(([doc, score], idx) => {
  console.log(`【片段${idx + 1}】相似度(1-score): ${(1 - score).toFixed(4)}`);
  console.log("内容:", doc.pageContent);
});
```

### 5. 把检索结果拼进 prompt，交给大模型

把 3 段文档拼成「背景知识」，和用户问题一起塞进 prompt，再调用大模型。

```javascript
const context = retrievedDocs
  .map((doc, i) => `[片段${i + 1}]\n${doc.pageContent}`)
  .join("\n\n━━━━━\n\n");

const prompt = `你是一个讲故事的老师。请根据下面给出的故事片段回答问题，用温暖、简洁的语言。如果片段里没有提到，就老实说"故事里还没有提到这一点"。

故事片段:
${context}

问题: ${question}

老师的回答:`;

const response = await model.invoke(prompt);
console.log(response.content);
```

这里 `model.invoke` 若接收的是字符串，会按默认方式构造消息；若你的 ChatOpenAI 需要消息数组，可改成 `model.invoke([new HumanMessage(prompt)])` 等，与你在 2.md 里的用法一致。

---

## 四、小结

- **RAG**：用户提问时，先从知识库里**检索相关文档片段**，把这些片段当背景知识放进 prompt，再让大模型根据它们生成回答，从而「有据可依」。
- **为什么用向量**：关键词搜不到「意思相关」的内容；把文字用**嵌入模型**变成**向量**，用**余弦相似度**比较「像不像」，就能做**语义检索**。
- **流程**：文档向量化存进向量库 → 用户问题向量化 → 用检索器取最相似的 k 段 → 拼成 context 和问题一起给大模型 → 得到回答。

用「喜羊羊与灰太狼」小故事做知识库，就是为了方便理解：**问「吸羊机」「灰太狼爱说啥」时，检索到的会是相关段落，大模型的回答就基于这些段落，而不是瞎编。** 实际项目中，把 `documents` 换成你的产品文档、帮助中心、内部知识库即可，流程一样。
