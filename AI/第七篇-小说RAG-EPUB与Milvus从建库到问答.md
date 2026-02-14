# 给小说建一个「先查书再回答」的 AI：EPUB + Milvus 实战

上一篇我们聊了 RAG 和向量检索：让大模型**先查资料、再回答**，既省 token 又更准。那如果资料是一整本小说，比如《天龙八部》，该怎么从零搭起来？这篇文章就顺着「建库 → 问答」这条线，把 EPUB 加载、切块、向量化、存 Milvus、检索、拼 prompt 一整条链路讲顺，代码和概念都嵌在流程里，你读下来会像跟着做一遍。

---

## 一、先搞清楚我们在干什么

目标很简单：用户问「书里最厉害的武功是什么」，系统**不要**让大模型瞎猜，而是先在已经存好的小说内容里找出和这个问题最相关的几段原文，把这几段当「参考资料」塞进 prompt，再让大模型**只基于这些原文**来回答。这就是 RAG：Retrieval（检索）→ Augmented（用检索结果增强）→ Generation（生成回答）。

整条链路可以分成两段：**建库**（把书变成「一块块原文 + 对应向量」存进向量库）和**问答**（用户提问 → 用问题向量在库里找最像的几块 → 把这几块原文拼进 prompt → 调大模型）。下面就从建库开始，一步一步说下去。

---

## 二、建库：从 EPUB 到向量库里的一条条记录

### 2.1 先统一一个能力：文本 → 向量

后面无论是「书里的一小块内容」还是「用户的问题」，都要变成同一套数字（向量），才能在数学上比「谁和谁更像」。所以代码里会先把「任意一段文本转成向量」封装成一个函数，全书和问题都走这个函数，保证用的是**同一套 embedding 模型**、维数一致，否则向量不在同一空间，检索就没意义。建表时向量字段的 `dim` 也要和这个模型的输出维数一致（例如你在 utils 里配置的 `VECTOR_DIMENSIONS`）。

```ts
const CHUNK_SIZE = 500;
const EPUB_FILE = './天龙八部.epub';
const BOOK_NAME = parse(EPUB_FILE).name;
const COLLECTION_NAME = "book";

// 全书和用户问题都走这一套 embedding，维数由 utils 配置决定
async function getEmbeddingVector(text: string): Promise<number[]> {
    const vec = await embeddings.embedQuery(text);
    return vec;
}
```

### 2.2 在 Milvus 里建好「表」和「索引」

建库前要先在 Milvus 里有一张表（collection），用来存每块内容的元数据（书名、章节号、章节名、原文）和对应的向量。如果表已存在就跳过，避免重复建表。

表里需要这些字段：主键 `id`、`book_id` / `book_name`、`chapter_num` / `chapter_name`、`chapter_content`（存原文，后面检索出来要原样拼进 prompt）、以及 `vector`（FloatVector，维数必须和 embedding 一致）。建完表还要给 `vector` 建索引：用 HNSW 做近似最近邻，用 COSINE 做相似度度量，这样后面按向量检索才会又快又准。**这里有个容易踩的坑**：建完索引后必须调用 `loadCollection`，否则 search 会查不到或报错。另外，建索引时的 `metric_type` 和后面 search 时的要一致，都选 COSINE。

```ts
async function ensureCollection(client: MilvusClient): Promise<void> {
    const exists = await client.hasCollection({ collection_name: COLLECTION_NAME });
    if (exists.value) return;

    await client.createCollection({
        collection_name: COLLECTION_NAME,
        fields: [
            { name: "id", data_type: DataType.VarChar, is_primary_key: true, max_length: 64 },
            { name: "book_id", data_type: DataType.VarChar, max_length: 64 },
            { name: "book_name", data_type: DataType.VarChar, max_length: 256 },
            { name: "index", data_type: DataType.Int32 },
            { name: "chapter_num", data_type: DataType.Int32 },
            { name: "chapter_name", data_type: DataType.VarChar, max_length: 256 },
            { name: "chapter_content", data_type: DataType.VarChar, max_length: 10000 },
            { name: "vector", data_type: DataType.FloatVector, dim: VECTOR_DIMENSIONS },
        ]
    });

    await client.createIndex({
        collection_name: COLLECTION_NAME,
        field_name: "vector",
        index_type: IndexType.HNSW,
        metric_type: MetricType.COSINE,
        params: { M: 8, efConstruction: 128 },
    });

    await client.loadCollection({ collection_name: COLLECTION_NAME });
}
```

### 2.3 把 EPUB 按章加载，再按块切分

书是一整本，不能整本转成一个向量，也不能整本塞给模型，所以要**按块**处理。代码里先用 LangChain 的 `EPubLoader` 加载 epub，并设 `splitChapters: true`，得到的是「一章一个 document」，每个 document 的 `pageContent` 就是该章正文。这样既保留了章节结构，也方便后面存 `chapter_num`、`chapter_name`。

一章可能很长，所以再对每章的正文做二次切块：用 `RecursiveCharacterTextSplitter`，每块约 500 字（`chunkSize`），块与块之间重叠 50 字（`chunkOverlap`）。重叠的作用是避免一句话被拦腰截断在两块之间，检索到任一块时都能带上一点上下文，模型读起来更连贯。

```ts
const loader = new EPubLoader(EPUB_FILE, { splitChapters: true });
const documents = await loader.load();

const textSplitter = new RecursiveCharacterTextSplitter({
    chunkSize: CHUNK_SIZE,
    chunkOverlap: 50,
});

for (let chapterIndex = 0; chapterIndex < documents.length; chapterIndex++) {
    const chapterContent = documents[chapterIndex].pageContent;
    const chunks = await textSplitter.splitText(chapterContent);
    // 下面把 chunks 逐块算向量并插入
}
```

### 2.4 每块算向量并插入，顺带做「同一本书不重复导入」

对每一章切出来的 `chunks`，逐个调用 `getEmbeddingVector(chunk)` 得到向量，再和元数据拼成一条记录插入 Milvus。主键 `id` 用 `bookId-chapterNum-index` 这种形式，保证全局唯一；这样同一本书重复跑脚本时，可以先查一下库里是否已经有这条 `book_id` 的数据，有就跳过整本书的导入，避免重复切块、重复算向量（即幂等）。插入时一定要把 `chapter_content` 存进去，因为检索时是按向量相似度拿回几条记录，你要把这几条里的**原文**拼进 prompt，模型才能「根据书本内容」回答。

```ts
async function isBookLoaded(client: MilvusClient, bookId: number): Promise<boolean> {
    try {
        const res = await client.query({
            collection_name: COLLECTION_NAME,
            filter: `book_id == "${bookId}"`,
            output_fields: ["id"],
            limit: 1,
        });
        const data = (res as { data?: unknown[] }).data;
        return Array.isArray(data) && data.length > 0;
    } catch {
        return false;
    }
}

const insertChunksBatch = async (chunks: string[], bookId: number, chapterNum: number) => {
    const vectors = await Promise.all(chunks.map(async (chunk, index) => {
        const vector = await getEmbeddingVector(chunk);
        return {
            id: `${bookId}-${chapterNum}-${index}`,
            book_id: bookId,
            book_name: BOOK_NAME,
            index: chapterNum,
            chapter_num: chapterNum,
            chapter_name: `${BOOK_NAME} - 第${chapterNum}章 - ${index + 1}`,
            chapter_content: chunk,
            vector
        };
    }));
    const res = await client.insert({ collection_name: COLLECTION_NAME, data: vectors });
    return Number(res.insert_cnt) || 0;
};
```

这里用 `query` 而不是 `search`，是因为我们只是按条件（有没有这条 book_id）过滤，不需要按向量相似度查。Milvus 的 filter 是字符串表达式，若你 schema 里 `book_id` 是数字类型，可能要写成 `book_id == 1`，按官方文档来即可。

---

## 三、问答：从用户问题到模型回答

建库完成后，用户提问时流程是：先把问题用同一套 `getEmbeddingVector` 转成向量，在 Milvus 里用 COSINE 做相似度检索，取最相似的 top K 条（例如 2 条），把这几条记录的 `chapter_content`、`chapter_name` 等格式化成一段「参考资料」，和用户问题一起塞进 prompt，再调大模型生成回答。这样模型看到的永远是「问题 + 几段和问题最相关的原文」，回答就有据可查。

检索时要注意：`metric_type` 必须和建索引时一致（COSINE）；`limit` 决定给模型几块原文，太少可能信息不够，太多占 token 且可能带噪音，一般 2～5 条起步再按效果调；`output_fields` 里一定要包含 `chapter_content`，否则没法拼进 prompt。不同版本的 Milvus Node SDK 对查询向量的传参可能不同，有的用 `vector`，有的用 `data: [queryVector]`，报错时对照官方示例即可，核心是传入一条和表里 `dim` 一致的查询向量。

```ts
const query = "最厉害的武功是什么";
const queryVector = await getEmbeddingVector(query);

const searchRes = await client.search({
    collection_name: COLLECTION_NAME,
    vector: queryVector,
    data: [queryVector],
    metric_type: MetricType.COSINE,
    limit: 2,
    output_fields: ["id", "book_name", "chapter_num", "chapter_name", "chapter_content"],
});

if (searchRes.results?.length > 0) {
    const context = searchRes.results
        .map((book, i) => `[书本 ${i + 1}]\n书本名称: ${book.book_name}\n章节名称: ${book.chapter_name}\n章节内容: ${book.chapter_content}`)
        .join('\n\n━━━━━\n\n');

    const prompt = `你是一个温暖贴心的 AI 书本助手。基于用户的书本内容回答问题。

请根据以下书本内容回答问题：
${context}

用户问题: ${query}

回答要求：
1. 若片段中有相关信息，请结合小说内容详细、准确回答
2. 可综合多个片段给出完整答案
3. 若没有相关信息，请如实告知
4. 可引用原文支持你的回答

AI 助手的回答:`;
    const response = await model.invoke(prompt);
    console.log(response.content);
}
```

---

## 四、容易踩的坑：写在一起方便你查

- **向量同一空间**：全书块和用户问题都用同一套 embedding，维数一致，建表 `vector.dim` 也要等于这个维数。
- **建索引后要 load**：`createIndex` 之后必须 `loadCollection`，否则 search 不生效或报错。
- **COSINE 一致**：建索引和 search 的 `metric_type` 都用 COSINE，避免静默错。
- **chunkOverlap**：适当重叠（如 50 字）可以减少句被截断，检索到的块更完整。
- **id 与幂等**：id 设计成唯一（如 bookId-chapterNum-index），用 `isBookLoaded` 避免同一本书重复导入。
- **search 入参**：按 SDK 版本确认传 `vector` 还是 `data: [queryVector]`，维数一致。
- **limit**：根据回答质量和 token 占用调 top K（如 2～5），不必写死。

---

## 五、小结

整条链路就是：**EPUB 按章加载 → 每章按 500 字 + 50 字重叠切块 → 每块向量化并写入 Milvus（含原文）→ 用户问题向量化后在 Milvus 用 COSINE 检索 top K → 把检索到的原文拼进 prompt → 大模型基于原文回答**。换别的书或格式（如 PDF、Markdown），只要改「加载 + 切块」那两步，后面的向量化、建表、检索、拼 prompt 都可以复用。核心记住：同一套 embedding、维数一致、索引与检索的 metric 一致、记得 load、合理切块与 limit。

---

*第 7 篇 | 小说 RAG：EPUB + Milvus 从建库到问答*
