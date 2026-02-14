# LangChain 输出解析常用方法

把大模型返回的文本变成程序里好用的类型，常用两种思路：

1. **模型端约束**：`withStructuredOutput(schema)`，一步得到结构化对象。
2. **解析器**：模型先输出文本，再用各种 Parser 解析成目标类型。

---

## 一、`withStructuredOutput(schema)`（推荐：直接要对象）

调用时**直接得到结构化结果**，无需自己解析。

```ts
import { z } from 'zod';
import { model } from './utils';

const schema = z.object({
  name: z.string().describe('姓名'),
  birth_year: z.number().describe('出生年份'),
  fields: z.array(z.string()).describe('领域列表'),
});

const structuredModel = model.withStructuredOutput(schema);
const result = await structuredModel.invoke('介绍一下爱因斯坦');
// result 已是 { name, birth_year, fields }
```

适合：不关心中间文字，只要最终对象。

---

## 二、`StructuredOutputParser`（流式后再解析）

先让模型输出整段文字（可流式展示），再对**完整字符串**按 Zod 解析。

```ts
import { StructuredOutputParser } from '@langchain/core/output_parsers';

const parser = StructuredOutputParser.fromZodSchema(schema);
const formatInstructions = parser.getFormatInstructions();
const prompt = `请介绍一位科学家，严格按以下格式输出：\n${formatInstructions}`;

const response = await model.invoke(prompt);
const result = await parser.parse(response.content as string);
```

适合：需要先流式显示内容，再解析（如 `src/output.ts`）。

---

## 三、`JsonOutputParser`（只做「字符串 → JSON 对象」）

**它只做一件事**：把模型输出的**文本**当成 JSON 解析成**对象**。

- 会从回复里提取 JSON（例如去掉 \`\`\`json ... \`\`\` 包裹）、做 `JSON.parse`，流式时还支持对「逐步增加的 JSON 文本」做增量解析。
- **不会**把 schema 发给模型（模型不知道你要什么类型）、**不会**校验结果。所以「返回的字段/类型是否符合预期」完全取决于你在 **prompt 里怎么描述**，以及解析后是否用 Zod 再校验。

和其他方式的区别：

| 方式 | 谁负责「让模型按格式输出」 | 谁负责「校验类型」 |
|------|---------------------------|--------------------|
| `withStructuredOutput(schema)` | 框架（把 schema 交给模型） | 框架 |
| `StructuredOutputParser` | 你（把 `getFormatInstructions()` 放进 prompt） | 解析器（按 Zod 解析） |
| **`JsonOutputParser`** | **你**（只在 prompt 里用自然语言说「用 JSON 返回 xxx」） | **你**（解析后再 `schema.parse(obj)`） |

适合：你已经在 prompt 里约定了「用 JSON、有哪些字段」，只需要有人把**字符串变成对象**（并统一处理 markdown/流式），格式和校验都自己管。

```ts
import { z } from 'zod';
import { JsonOutputParser } from '@langchain/core/output_parsers';

const schema = z.object({
  name: z.string().describe('姓名'),
  birth_year: z.number().describe('出生年份'),
});
type Scientist = z.infer<typeof schema>;

// 只负责：model 输出的字符串 → JSON 对象（不教模型、不校验）
const parser = new JsonOutputParser<Scientist>();
const chain = model.pipe(parser);
const obj = await chain.invoke('介绍一位科学家，用 JSON 返回：name、birth_year');
// 类型/格式由 prompt 决定，若要严格类型需自己校验
const parsed = schema.parse(obj);
```

---

## 四、`StringOutputParser`（纯字符串）

不解析结构，只把输出统一成字符串，常用于链的最后一环。

```ts
import { StringOutputParser } from '@langchain/core/output_parsers';

const chain = model.pipe(new StringOutputParser());
const text = await chain.invoke('讲个笑话');
```

---

## 五、`CommaSeparatedListOutputParser`（逗号分隔列表）

把「逗号分隔」的文本解析成字符串数组。

```ts
import { CommaSeparatedListOutputParser } from '@langchain/core/output_parsers';

const parser = new CommaSeparatedListOutputParser();
const list = await parser.parse('物理, 数学, 哲学');
// list = ['物理', '数学', '哲学']
```

---

## 选择建议

| 需求           | 用法 |
|----------------|------|
| 直接要结构化对象 | `withStructuredOutput(schema)` |
| 流式后再按 Zod 解析 | `StructuredOutputParser.fromZodSchema(schema)` |
| 只把「模型输出的 JSON 字符串」解析成对象，格式/校验自己管 | `JsonOutputParser` |
| 只要字符串     | `StringOutputParser` |
| 逗号分隔列表   | `CommaSeparatedListOutputParser` |

示例代码见 `src/output.ts`。
