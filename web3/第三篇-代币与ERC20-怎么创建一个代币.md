# 代币是啥、ERC20 是啥、怎么「创建一个代币」？

上一篇捋了 Web3 里各种角色（LP、IB、Trader、Builder…），这篇就讲他们手里经常拿的那个东西——**代币**——是啥、按什么规则来、你怎么自己「发一个」。

**先说明一点**：代币就是链上的一种「凭证」，可转让、可编程。谁持有多、谁就能参与治理、领激励、或者去 DEX 换钱。**发代币**本质上就是部署一份合约、按规则铸造总量并分给不同地址；真正难的不是写合约，而是**代币经济学**——分给谁、锁多久、怎么释放。下面用一张真实项目的代币分配表 + 一份简化合约例子，把「代币」和「ERC20」串起来讲清楚。

---

## 代币是啥？

**干啥的**：链上的一种数字资产，有总量、有归属，可转、可编程。

你常听到的「项目发币」「上交易所」「空投」，说的都是这种链上代币。**谁持有多，谁就拥有多少「份额」**——可以投票治理、领挖矿/空投激励、或者在 CEX/DEX 上卖掉。代币本身是一串合约代码：总量多少、谁有多少、怎么转、能不能增发，都写在合约里。

**一句话**：代币 = 链上可转让、可编程的「份额凭证」，按合约规则发行和流转。

---

## ERC20 是啥？

**干啥的**：以太坊上最常用的一套「代币标准」，规定了名字、符号、总量、余额、转账、授权等接口。

大家都按同一套接口写，钱包和交易所才能识别、显示余额、帮你转账。**ERC20 就是这套「约定」**：你的合约里有 `name`、`symbol`、`totalSupply`、`balanceOf(地址)`、`transfer(地址, 数量)`、`approve`/`transferFrom` 等，就算一个 ERC20 代币。具体实现可以自己写，也可以直接用 OpenZeppelin 的 `ERC20.sol`，再在构造函数里铸币、按比例分给不同地址。

**一句话**：ERC20 = 以太坊上的代币「标准格式」，按这个格式写合约，发出来的就是大家能识别的代币。

---

## 怎么「创建一个代币」？

**三步**：定总量与分配 → 写 ERC20 合约（铸币 + 分给各用途地址）→ 部署上链。

写合约时，**建议继承自 ERC20 抽象类**（或直接用 OpenZeppelin 的 `ERC20.sol`），这样接口和事件都符合标准，钱包、交易所、区块浏览器才能正确识别。自己从零写也要实现同一套接口，否则别人集成就得单独适配。

**ERC20 里重要的参数和接口**：

| 类型 | 名称 | 说明 |
|------|------|------|
| 参数 | `name` | 代币全名，如 "Example Token" |
| 参数 | `symbol` | 代币符号，如 "EXT"，交易所/钱包显示用 |
| 参数 | `decimals` | 小数位数，通常为 18，和 ETH 一致 |
| 参数 | `totalSupply` | 总供应量（最小单位，= 显示数量 × 10^decimals） |
| 方法 | `balanceOf(address)` | 查询某地址余额 |
| 方法 | `transfer(to, amount)` | 转给某地址 |
| 方法 | `approve(spender, amount)` | 授权某地址可花自己多少额度 |
| 方法 | `allowance(owner, spender)` | 查询某地址被授权了多少 |
| 方法 | `transferFrom(from, to, amount)` | 被授权方从 from 转给 to（需先 approve） |
| 事件 | `Transfer(from, to, value)` | 发生转账时触发 |
| 事件 | `Approval(owner, spender, value)` | 发生授权时触发 |

**铸币**：ERC20 标准里没有规定「怎么发币」，只规定有了总量和余额之后怎么转。所以你要在构造函数里自己给 `totalSupply` 赋值，并给初始地址写入 `balanceOf`（即「铸造」），后面就可以用 `transfer` 正常流转了。

真正花功夫的是**代币分配**：多少给流动性挖矿、多少给生态与 IB、多少给团队、多少给融资、多少进国库、多少做初始 LP，以及**锁仓和释放**——例如团队锁 12 个月再 36 个月线性释放、融资锁 6 个月再 12 个月线性释放，等等。合约里可以先按比例一次性铸给不同地址，锁仓和线性释放再用单独的 **Vesting 合约** 控制，这样逻辑清晰、也方便审计。

下面这张表是某真实项目的代币分配与释放设计（4 年周期，总量 1000 个），你可以对照理解「比例」和「锁仓/释放」在业务上长什么样：

| 分配类别 | 比例 | 数量(枚) | 锁仓与释放机制 |
|----------|------|----------|----------------|
| 流动性激励 (XCLP 挖矿) | 45% | 450 | 4 年线性释放，第一年 30% 逐年递减 |
| 生态发展与 IB 奖励 | 15% | 150 | TGE 释放 10%，余下 24 个月用于代理激励与市场 |
| 核心团队与开发 | 15% | 150 | 锁仓 12 个月，随后 36 个月线性释放 |
| 战略/种子轮融资 | 10% | 100 | TGE 释放 10%，锁仓 6 个月后 12 个月线性释放 |
| 协议国库 | 10% | 100 | 由 DAO 治理，用于品牌建设与紧急风险对冲 |
| 初始流动性池 (LP) | 5% | 50 | 100% 锁定于 DEX 交易对，提供初始交易深度 |

*（TGE = Token Generation Event，代币生成/上线时点）*

---

## 合约例子：按上表比例「发币」到各地址

下面是一份**简化版 ERC20 合约**的核心代码，对着上表看，能直接理解「代币怎么创建、怎么按比例分」。

**合约做了啥**：总量 1000 × 10^18，用常量写死 6 类比例，在构造函数里接收 6 个地址，按比例 `_mint` 到对应地址；标准 ERC20 的 `transfer`、`approve`、`transferFrom` 等都有，钱包和区块浏览器能识别。真实项目里团队/融资/生态会再接 **Vesting 合约**做锁仓与线性释放，这里只做「按比例铸造到各地址」这一步。用 Remix / Hardhat / Foundry 部署时传入 6 个地址即可。

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

contract ExampleToken {
    string public name = "Example Token";
    string public symbol = "EXT";
    uint8 public decimals = 18;

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    // 按代币分配表的 6 类比例（总量 1000 * 10^18）
    uint256 public constant TOTAL = 1000 * 1e18;
    uint256 public constant PCT_LP_MINING   = 45;  // 45% 流动性激励
    uint256 public constant PCT_ECOSYSTEM   = 15;  // 15% 生态与 IB
    uint256 public constant PCT_TEAM        = 15;  // 15% 核心团队
    uint256 public constant PCT_STRATEGIC   = 10;  // 10% 战略/种子
    uint256 public constant PCT_TREASURY    = 10;  // 10% 协议国库
    uint256 public constant PCT_INITIAL_LP  = 5;   //  5% 初始 LP

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    constructor(
        address lpMining_,    // 流动性激励（挖矿池）
        address ecosystem_,  // 生态发展与 IB 奖励
        address team_,       // 核心团队与开发
        address strategic_,  // 战略/种子轮
        address treasury_,   // 协议国库
        address initialLp_   // 初始流动性池
    ) {
        totalSupply = TOTAL;
        _mint(lpMining_,   TOTAL * PCT_LP_MINING   / 100);
        _mint(ecosystem_,  TOTAL * PCT_ECOSYSTEM   / 100);
        _mint(team_,       TOTAL * PCT_TEAM       / 100);
        _mint(strategic_,  TOTAL * PCT_STRATEGIC  / 100);
        _mint(treasury_,   TOTAL * PCT_TREASURY   / 100);
        _mint(initialLp_, TOTAL * PCT_INITIAL_LP / 100);
    }

    function _mint(address to, uint256 amount) internal {
        require(to != address(0), "mint to zero");
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            require(allowed >= amount, "allowance exceeded");
            allowance[from][msg.sender] = allowed - amount;
        }
        _transfer(from, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        require(from != address(0) && to != address(0), "transfer to/from zero");
        require(balanceOf[from] >= amount, "insufficient balance");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
    }
}
```

完整版（含注释表格）仍在仓库 `examples/ExampleToken.sol`，可复制到 Remix 直接部署。

---

先把「代币 = 链上凭证」「ERC20 = 标准接口」「创建代币 = 定分配 + 写合约 + 部署」这三件事串起来，再看白皮书里的「代币分配与释放」就不会懵了。后面有机会再写锁仓、线性释放和挖矿合约，把「发币」这一条线补全。

---

*第三篇 | 代币与 ERC20：怎么创建一个代币*
