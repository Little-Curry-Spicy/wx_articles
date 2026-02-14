# 授权方式的更迭：从 ERC20 到 Permit2

链上换币、抵押借贷、领空投……很多操作都离不开「**授权**」：你允许某个合约（spender）在额度内从你钱包**划走** ERC20 代币。授权方式从最早的 **ERC20 approve + transferFrom**，到 **EIP-2612 permit**，再到 Uniswap 的 **Permit2**，一步步解决了「两笔交易」「无限授权」「每协议各授权一次」等问题。本文讲清楚三代方式的原理和差异。

**授权**特指：你允许别人从你账户转走代币。链上不认账号密码，只认**谁有权动你的币**——要么你自己 `transfer`，要么你事先 `approve` 过某地址，它才能用 `transferFrom` 划账。演进方向是：**在不降安全的前提下**，减少交易、降低风险、让授权更好复用。

---

## 一、为什么需要「授权」？

你的 USDT 在自己地址上，DEX 合约没有你的私钥，不能直接替你转币。所以必须有机制让你事先声明：「我允许 DEX 从我这转走最多 X 个 USDT。」这就是 **approve**。之后 DEX 调用代币的 **transferFrom(你, 池子, 数量)**，代币合约检查：你是否对 DEX 授权过 ≥ 该数量；若是，就扣余额、转走。

**授权 = 允许 spender 在额度内用 transferFrom 从你账户划币**。没授权会 revert；授权了，合约才能替你动币。

---

## 二、传统 ERC20：approve + transferFrom

- **approve(spender, amount)**：授权 spender 最多用你 `amount` 数量的代币，内部 `allowance[owner][spender] = amount`。
- **transferFrom(from, to, amount)**：调用方从 `from` 转 `amount` 到 `to`，需 `allowance[from][msg.sender] >= amount` 且余额足够，并会扣减 allowance。

**流程**：先对合约做一次 approve，再调用业务方法（如 swap），合约内部 transferFrom。所以**至少两笔交易**，且每个协议都是不同 spender，**每个都要单独 approve**。

**合约示例**：

```solidity
// 用户需先: token.approve(address(this), amount);
function deposit(address token, uint256 amount) external {
    IERC20(token).transferFrom(msg.sender, address(this), amount);
    _mint(msg.sender, amount);
}
```

**问题**：① 两笔交易，多付 gas；② 无限授权 `approve(spender, type(uint256).max)` 一旦 spender 被黑，币可被一次性转光；③ 悬挂授权无过期，只能自己再发交易改 allowance 为 0；④ 每协议一授权，分散难管理。

---

## 三、EIP-2612：permit（签名授权）

**EIP-2612** 在 ERC20 上增加 **permit**：用户**不用先发 approve 交易**，在链下用私钥对「授权谁、多少、截止时间」**签名**；链上任何人调用 `permit(owner, spender, value, deadline, v, r, s)`，代币合约用 EIP-712 恢复签名者，校验通过后执行 `_approve`。这样**授权和业务可在同一笔交易里完成**（中继先 permit 再 transferFrom，用户只签一次名）。

```solidity
function permit(
    address owner, address spender, uint256 value, uint256 deadline,
    uint8 v, bytes32 r, bytes32 s
) external;
```

**一次交易完成授权 + 划转**：

```solidity
function swapWithPermit(
    address token, address owner, uint256 amount, uint256 deadline,
    uint8 v, bytes32 r, bytes32 s
) external {
    IERC20Permit(token).permit(owner, address(this), amount, deadline, v, r, s);
    IERC20(token).transferFrom(owner, address(this), amount);
    // 后续 swap...
}
```

**局限**：只有实现 EIP-2612 的代币才有 permit（USDC、DAI 有，很多 USDT 没有）；授权仍是每 spender 各签一次，不能统一管理。

---

## 四、Permit2：授权集中到「一个合约」

**Permit2** 是 Uniswap 推出的独立授权合约，多链同址。思路：**用户只对 Permit2 做一次最大 approve**；之后所有「从用户转币」的权限**先经 Permit2**——用户对 Permit2 签授权/转账消息，协议调 Permit2 的 `permitTransferFrom`，由 Permit2 对原 ERC20 调 `transferFrom`。

两种用法：

- **SignatureTransfer**：一次性、仅当笔有效。用户签「允许本笔转 X 代币给某地址」的消息；协议调 `permitTransferFrom`，Permit2 校验后转出。不留下持久额度。
- **AllowanceTransfer**：有时效的额度。用户给 spender 设「在某过期时间前最多用多少」；spender 在期限内可多次 transferFrom。相当于 approve 搬到 Permit2，且带 **expiration**。

**协议侧示例**（SignatureTransfer）：

```solidity
struct PermitTransferFrom {
    TokenPermissions permitted;  // token + amount
    address spender;
    uint256 nonce;
    uint256 deadline;
}

function receiveTokenViaPermit2(
    address permit2, address token, uint256 amount,
    uint256 deadline, uint256 nonce, bytes calldata signature
) external {
    PermitTransferFrom memory permit = PermitTransferFrom({
        permitted: TokenPermissions({ token: token, amount: amount }),
        spender: address(this),
        nonce: nonce,
        deadline: deadline
    });
    ISignatureTransfer(permit2).permitTransferFrom(
        permit, msg.sender, address(this), amount, signature
    );
    // 代币已转入，后续业务...
}
```https://open.feishu.cn/open-apis/bot/v2/hook/5f73e75e-f0ab-4afb-ba8b-546f31bcfb03

用户侧：对 ERC20 只做一次 `approve(Permit2, type(uint256).max)`；之后每次转币只需签 Permit2 的 **PermitTransferFrom** 消息，把签名交给协议即可。

**Permit2 的好处**：① 一次 approve 多协议复用；② 签名即可授权，不必多发链上交易；③ 可带 deadline/expiration；④ 可统一在 Permit2 撤销；⑤ 兼容未实现 EIP-2612 的代币。

---

## 五、三代对比小结

| 维度 | ERC20 approve | EIP-2612 permit | Permit2 |
|------|---------------|-----------------|---------|
| **授权方式** | 链上 approve | 链下签名，链上 permit | 对 Permit2 approve 一次；后续签消息或设额度 |
| **最少交易数** | 2 | 1 | 1 |
| **依赖代币** | 否 | 是，需 permit | 否 |
| **授权范围** | 每 spender 单独 | 每 spender 单独 | 一次授权 Permit2，多协议复用 |
| **过期与撤销** | 无 | 有 deadline | 支持 deadline/expiration，可统一撤销 |
| **无限授权风险** | 常见 | 可签有限额 | 可每次限定 amount+deadline |

---

## 六、安全注意点

- **传统 approve**：避免 `type(uint256).max`；用完主动改 allowance 为 0。不信任的合约不授权。
- **EIP-2612**：签名前确认 domain、chainId、代币地址正确；deadline 不宜过长；防止 nonce 重放。
- **Permit2**：确认访问的是官方 Permit2 地址；签名时核对 token、amount、deadline、spender，防止被篡改。

---

授权方式的演进：从「两笔交易、每协议一授权、无过期」的 approve，到「签名即授权、一笔完成」的 permit，再到「授权集中到 Permit2、多协议复用、可过期可撤销」的 Permit2。理解这三代差异，有助于正确集成和审计；用户知道「授权给谁、多少、有没有过期」，能更好保护资产。

---

*第八篇 | 授权方式的更迭：从 ERC20 到 Permit2*
