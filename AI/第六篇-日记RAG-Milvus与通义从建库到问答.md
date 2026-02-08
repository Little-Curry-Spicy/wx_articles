# 动手做一个「日记 RAG」：Milvus + 通义，从建库到问答

上一篇讲了 RAG 和向量检索是咋回事——**先按语义查出相关文档，再塞进 prompt 让大模型答**。这篇就落地一把：用 **Milvus（Zilliz 云）** 当向量库、**通义** 做嵌入和生成，搭一个「日记问答」小应用。你问「我想看看关于吃饭的日记」，AI 先到向量库里搜出和「吃饭」最相关的几条日记，再结合这些内容给你写一段温暖的回复。

**先说明一点**：流程是通用的——换成你自己的文档、别的向量库或别的模型，思路一样。重点是**建库 → 检索 → 拼 prompt → 调模型**这条链跑通。

---

## 一、整体在干啥？

- **数据**：一条条日记，有内容、日期、心情、标签等。
- **建库**：把每条日记的「内容」用**嵌入模型**变成向量，和元数据一起写进 **Milvus**，并建好**向量索引**（例如 HNSW + 余弦相似度）。
- **问答**：用户提一个问题（如「关于吃饭的日记」）→ 问题也变成向量 → 在 Milvus 里做**向量检索**，取出最相关的几条日记 → 把这几条日记当「背景」拼进 prompt → 用**大模型**生成一句有同理心的回答。

**一句话**：日记 RAG = 日记内容向量化存进 Milvus，问的时候先按语义检索，再让大模型根据检索结果回答。

---

## 二、关键几步怎么实现？

### 1. 配置与客户端

用环境变量存 **Zilliz 地址、Token**，以及**通义 API Key**。Milvus 用 `@zilliz/milvus2-sdk-node` 连（支持云上 Zilliz）；嵌入用通义 **text-embedding-v3**（可指定维度，如 1024），生成用 **qwen-plus**，都走兼容 OpenAI 的接口，所以可以用 LangChain 的 `OpenAIEmbeddings` 和 `ChatOpenAI`，把 `baseURL` 指到通义即可。

```ts
import { env } from "node:process";
import { MilvusClient, MetricType, IndexType } from "@zilliz/milvus2-sdk-node";
import { ChatOpenAI, OpenAIEmbeddings } from "@langchain/openai";

const ZILLIZ_URI = env.ZILLIZ_URI ?? "";
const ZILLIZ_TOKEN = env.ZILLIZ_TOKEN;
const VECTOR_DIMENSIONS = 1024;

// 大模型：通义 qwen-plus
const model = new ChatOpenAI({
  modelName: "qwen-plus",
  apiKey: env.QIANWEN_API_KEY,
  configuration: {
    baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1",
  },
  temperature: 0.7,
});

// 嵌入模型：通义 text-embedding-v3，维度与建表一致
const embeddings = new OpenAIEmbeddings({
  modelName: "text-embedding-v3",
  apiKey: env.QIANWEN_API_KEY,
  configuration: {
    baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1",
  },
  dimensions: VECTOR_DIMENSIONS,
});

function createMilvusClient(): MilvusClient {
  return new MilvusClient({
    address: ZILLIZ_URI,
    token: ZILLIZ_TOKEN,
    ssl: true,
  });
}

async function getEmbeddingVector(text: string): Promise<number[]> {
  return await embeddings.embedQuery(text);
}
```

### 2. 建表与索引

先判断集合（collection）是否存在；不存在就按**维度**建表，字段里要有一个 **vector** 类型，维度和你嵌入模型输出一致。建完表再建**向量索引**：常见用 **HNSW**（近似最近邻、查询快），**度量用 COSINE**（余弦相似度），和「语义相似」很贴。建完索引后，插入数据、**flush** 落盘，再 **load** 进内存，检索才会生效。

```ts
async function ensureCollection(client: MilvusClient, dim: number): Promise<void> {
  const exists = await client.hasCollection({ collection_name: COLLECTION_NAME });
  if (exists.value) return;

  // 建表：fields 需包含 id、content、date、mood、tags、vector 等，vector 维度 = dim
  await client.createCollection({
    collection_name: COLLECTION_NAME,
    fields: getSchema(dim),  // 自己按 Milvus 规范定义字段，含 DataType.FloatVector, dim
  });

  // 建索引：HNSW + 余弦相似度
  await client.createIndex({
    collection_name: COLLECTION_NAME,
    field_name: "vector",
    index_type: IndexType.HNSW,
    metric_type: MetricType.COSINE,
    params: { M: 8, efConstruction: 128 },
  });
}
```

### 3. 写入：日记 → 向量 → 插入

把每条日记的「内容」用 `embedQuery` 转成向量，和 id、date、mood、tags 等一起组成一条记录（Milvus 里 JSON 字段一般传字符串）。一批条数别太大，按接口限制来；插完后记得 **flushSync**，再 **loadCollectionSync**，这样后面 search 才能查到。

```ts
// 每条日记内容转向量，和元数据一起组成一条记录
const vectors = await Promise.all(diaryContents.map(async (entry) => ({
  ...entry,
  tags: JSON.stringify(entry.tags),  // Milvus JSON 字段需传字符串
  vector: await getEmbeddingVector(entry.content),
})));

const res = await client.insert({
  collection_name: COLLECTION_NAME,
  data: vectors,
});

if (res.status.code === 0) {
  await client.flushSync({ collection_names: [COLLECTION_NAME] });
  await client.releaseCollection({ collection_name: COLLECTION_NAME });
  await client.loadCollectionSync({ collection_name: COLLECTION_NAME });
}
```

### 4. 查询：问题 → 向量 → 检索 → prompt → 生成

用户问题同样用 `embedQuery` 得到向量，在 Milvus 里 **search**，按余弦相似度取 top-k（如 2～5 条）。把这几条日记按「日期、心情、标签、内容」拼成一段可读的 context，再拼进 prompt，例如：「你是温暖的日记助手，根据以下日记内容回答问题：… 用户问题：… 要求结合日记、有同理心……」最后 `model.invoke(prompt)`，得到回答。

```ts
const query = "我想看看关于吃饭的日记";
const queryVector = await getEmbeddingVector(query);

const searchRes = await client.search({
  collection_name: COLLECTION_NAME,
  metric_type: MetricType.COSINE,
  data: [queryVector],
  limit: 2,
  output_fields: ["id", "content", "date", "mood", "tags"],
});

if (searchRes.results?.length > 0) {
  const context = searchRes.results
    .map((diary, i) => `[日记 ${i + 1}]\n日期: ${diary.date}\n心情: ${diary.mood}\n标签: ${Array.isArray(diary.tags) ? diary.tags.join(", ") : diary.tags}\n内容: ${diary.content}`)
    .join("\n\n━━━━━\n\n");

  const prompt = `你是一个温暖贴心的 AI 日记助手。基于用户的日记内容回答问题。
请根据以下日记内容回答问题：
${context}
用户问题: ${query}
回答要求：结合日记、有同理心……`;
  const response = await model.invoke(prompt);
  console.log(response.content);
}
```

---

## 三、容易踩的坑

- **维度一致**：建表时的 vector 维度必须和嵌入模型输出一致（如 1024），否则插不进去或查不对。
- **flush / load**：插入后没 flush 就 search，可能查不到；没 load 也可能查不到或很慢。云上 Zilliz 一般会帮你做一部分，但本地或自建要自己调。
- **索引与度量**：search 时的 `metric_type` 要和建索引时一致（如都用 COSINE）；否则结果不对。

**一句话**：维度对齐、插入后 flush+load、检索时度量类型一致，这三样对上，RAG 链就稳。

---

## 四、小结与延伸

用 **Milvus（Zilliz）+ 通义嵌入 + 通义大模型**，就能从零搭一个「日记 RAG」：建库时把日记内容向量化入库，问答时先语义检索再生成。你可以把「日记」换成工单、文档、代码片段，流程不变；也可以把通义换成 DeepSeek、OpenAI 等兼容接口的模型，只要嵌入维度和建表一致即可。后面有机会再写一写：怎么选 top-k、怎么切分长文档、以及 RAG 的评估和优化。

---

*第六篇 | 日记 RAG：Milvus + 通义，从建库到问答*
