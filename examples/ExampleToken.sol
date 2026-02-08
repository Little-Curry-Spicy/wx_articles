// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * 示例：基于真实项目代币分配的 ERC20 合约（简化版，便于理解）
 *
 * 代币分配与释放（参考某项目 4 年释放周期，总量 1000）：
 * ┌─────────────────────────────┬───────┬──────────────┬─────────────────────────────────────┐
 * │ 分配类别                     │ 比例  │ 数量(枚)     │ 锁仓与释放机制                        │
 * ├─────────────────────────────┼───────┼──────────────┼─────────────────────────────────────┤
 * │ 流动性激励 (XCLP 挖矿)       │ 45%   │         450  │ 4年线性释放，第一年30%逐年递减        │
 * │ 生态发展与 IB 奖励           │ 15%   │         150  │ TGE 释放10%，余下24个月代理激励与市场 │
 * │ 核心团队与开发               │ 15%   │         150  │ 锁仓12个月，随后36个月线性释放        │
 * │ 战略/种子轮融资              │ 10%   │         100  │ TGE 释放10%，锁仓6个月后12个月线性   │
 * │ 协议国库                     │ 10%   │         100  │ 由 DAO 治理，品牌建设与风险对冲      │
 * │ 初始流动性池 (LP)            │  5%   │          50  │ 100% 锁定于 DEX 交易对，初始交易深度  │
 * └─────────────────────────────┴───────┴──────────────┴─────────────────────────────────────┘
 *
 * 本合约仅做「按比例铸造到不同地址」的演示，真实项目会配合 Vesting 合约做锁仓与线性释放。
 */

contract ExampleToken {
    string public name = "Example Token";
    string public symbol = "EXT";
    uint8 public decimals = 18;

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    // 按上表的比例分配（总量 1000 * 10^18）
    uint256 public constant TOTAL = 1000 * 1e18;
    uint256 public constant PCT_LP_MINING   = 45; // 45% 流动性激励
    uint256 public constant PCT_ECOSYSTEM   = 15; // 15% 生态与 IB
    uint256 public constant PCT_TEAM        = 15; // 15% 核心团队
    uint256 public constant PCT_STRATEGIC   = 10; // 10% 战略/种子
    uint256 public constant PCT_TREASURY    = 10; // 10% 协议国库
    uint256 public constant PCT_INITIAL_LP  = 5;  //  5% 初始 LP

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    /**
     * 部署时按分配比例铸造到对应地址（真实项目里这些地址会再对接 Vesting/锁仓合约）
     */
    constructor(
        address lpMining_,      // 流动性激励（挖矿池）
        address ecosystem_,    // 生态发展与 IB 奖励
        address team_,        // 核心团队与开发
        address strategic_,   // 战略/种子轮
        address treasury_,    // 协议国库
        address initialLp_    // 初始流动性池
    ) {
        totalSupply = TOTAL;

        _mint(lpMining_,   TOTAL * PCT_LP_MINING   / 100); // 450
        _mint(ecosystem_,  TOTAL * PCT_ECOSYSTEM   / 100); // 150
        _mint(team_,       TOTAL * PCT_TEAM       / 100); // 150
        _mint(strategic_,  TOTAL * PCT_STRATEGIC  / 100); // 100
        _mint(treasury_,   TOTAL * PCT_TREASURY  / 100); // 100
        _mint(initialLp_,  TOTAL * PCT_INITIAL_LP / 100); // 50
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
