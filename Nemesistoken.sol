// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

abstract contract Context {
    function _msgSender() internal view virtual returns (address) {
        return msg.sender;
    }
    function _msgData() internal view virtual returns (bytes calldata) {
        return msg.data;
    }
}

interface IERC20 {
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address recipient, uint256 amount) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
}

interface IUniswapV2Router02 {
    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;

    function factory() external pure returns (address);
    function WETH() external pure returns (address);

    function addLiquidityETH(
        address token,
        uint amountTokenDesired,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline
    ) external payable returns (uint amountToken, uint amountETH, uint liquidity);
}

interface IUniswapV2Factory {
    function createPair(address tokenA, address tokenB) external returns (address pair);
}

abstract contract Ownable is Context {
    address private _owner;

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    constructor() {
        _transferOwnership(_msgSender());
    }

    function owner() public view virtual returns (address) {
        return _owner;
    }

    modifier onlyOwner() {
        require(owner() == _msgSender(), "Ownable: caller is not the owner");
        _;
    }

    function renounceOwnership() public virtual onlyOwner {
        _transferOwnership(address(0));
    }

    function transferOwnership(address newOwner) public virtual onlyOwner {
        require(newOwner != address(0), "Ownable: new owner is the zero address");
        _transferOwnership(newOwner);
    }

    function _transferOwnership(address newOwner) internal virtual {
        address oldOwner = _owner;
        _owner = newOwner;
        emit OwnershipTransferred(oldOwner, newOwner);
    }
}

contract Nemesis is Context, IERC20, Ownable {
    string private constant _name = "NEMESIS";
    string private constant _symbol = "NEMESIS";
    uint8 private constant _decimals = 18;

    uint256 private constant MAX = ~uint256(0);
    uint256 private _totalSupply = 300_000_000 * 10**_decimals;
    uint256 private _reflectionTotal = (MAX - (MAX % _totalSupply));

    mapping(address => uint256) private _reflectedBalances;
    mapping(address => uint256) private _actualBalances;
    mapping(address => mapping(address => uint256)) private _allowances;
    mapping(address => bool) private _isExcludedFromFee;
    mapping(address => bool) private _isExcludedFromReward;
    address[] private _excluded;

    uint256 public maxTxAmount;
    uint256 public tokensSellToAddToLiquidity;
    address public developmentWallet;

    uint256 private _taxFee = 5;
    uint256 private _liquidityFee = 5;
    uint256 private _developmentFee = 5;

    uint256 private _previousTaxFee;
    uint256 private _previousLiquidityFee;
    uint256 private _previousDevelopmentFee;

    IUniswapV2Router02 private _uniswapV2Router;
    address private _uniswapV2Pair;

    event ExcludedFromReward(address account);
    event IncludedInReward(address account);
    event FeeUpdated(uint256 taxFee, uint256 liquidityFee, uint256 developmentFee);

    constructor(address _router) {
        _reflectedBalances[_msgSender()] = _reflectionTotal;

        developmentWallet = 0xf976A4b348574991BE7ea8ef6DeEb3E311E23D57;
        maxTxAmount = _totalSupply / 100; // 1%
        tokensSellToAddToLiquidity = _totalSupply / 1000; // 0.1%

        IUniswapV2Router02 uniswapRouter = IUniswapV2Router02(_router);
        _uniswapV2Router = uniswapRouter;
        _uniswapV2Pair = IUniswapV2Factory(uniswapRouter.factory())
            .createPair(address(this), uniswapRouter.WETH());

        _isExcludedFromFee[owner()] = true;
        _isExcludedFromFee[address(this)] = true;

        emit Transfer(address(0), _msgSender(), _totalSupply);
    }

    function name() public pure returns (string memory) {
        return _name;
    }

    function symbol() public pure returns (string memory) {
        return _symbol;
    }

    function decimals() public pure returns (uint8) {
        return _decimals;
    }

    function totalSupply() public view override returns (uint256) {
        return _totalSupply;
    }

    function balanceOf(address account) public view override returns (uint256) {
        if (_isExcludedFromReward[account]) return _actualBalances[account];
        return tokenFromReflection(_reflectedBalances[account]);
    }

    function transfer(address recipient, uint256 amount) public override returns (bool) {
        _transfer(_msgSender(), recipient, amount);
        return true;
    }

    function allowance(address owner_, address spender) public view override returns (uint256) {
        return _allowances[owner_][spender];
    }

    function approve(address spender, uint256 amount) public override returns (bool) {
        _approve(_msgSender(), spender, amount);
        return true;
    }

    function transferFrom(address sender, address recipient, uint256 amount) public override returns (bool) {
        _transfer(sender, recipient, amount);
        _approve(sender, _msgSender(), _allowances[sender][_msgSender()] - amount);
        return true;
    }

    function _approve(address owner_, address spender, uint256 amount) private {
        require(owner_ != address(0), "ERC20: approve from the zero address");
        require(spender != address(0), "ERC20: approve to the zero address");

        _allowances[owner_][spender] = amount;
        emit Approval(owner_, spender, amount);
    }

    function tokenFromReflection(uint256 rAmount) public view returns (uint256) {
        require(rAmount <= _reflectionTotal, "Amount must be less than total reflections");
        uint256 currentRate = _getRate();
        return rAmount / currentRate;
    }

    function _getRate() private view returns (uint256) {
        (uint256 rSupply, uint256 tSupply) = _getCurrentSupply();
        return rSupply / tSupply;
    }

    function _getCurrentSupply() private view returns (uint256, uint256) {
        uint256 rSupply = _reflectionTotal;
        uint256 tSupply = _totalSupply;

        for (uint256 i = 0; i < _excluded.length; i++) {
            if (_reflectedBalances[_excluded[i]] > rSupply || _actualBalances[_excluded[i]] > tSupply)
                return (_reflectionTotal, _totalSupply);
            rSupply -= _reflectedBalances[_excluded[i]];
            tSupply -= _actualBalances[_excluded[i]];
        }
        if (rSupply < _reflectionTotal / _totalSupply) return (_reflectionTotal, _totalSupply);
        return (rSupply, tSupply);
    }

    function excludeFromReward(address account) public onlyOwner {
        require(!_isExcludedFromReward[account], "Account is already excluded");
        if (_reflectedBalances[account] > 0) {
            _actualBalances[account] = tokenFromReflection(_reflectedBalances[account]);
        }
        _isExcludedFromReward[account] = true;
        _excluded.push(account);
        emit ExcludedFromReward(account);
    }

    function includeInReward(address account) public onlyOwner {
        require(_isExcludedFromReward[account], "Account is not excluded");
        for (uint256 i = 0; i < _excluded.length; i++) {
            if (_excluded[i] == account) {
                _excluded[i] = _excluded[_excluded.length - 1];
                _actualBalances[account] = 0;
                _isExcludedFromReward[account] = false;
                _excluded.pop();
                break;
            }
        }
        emit IncludedInReward(account);
    }

    function removeAllFee() private {
        if (_taxFee == 0 && _liquidityFee == 0 && _developmentFee == 0) return;

        _previousTaxFee = _taxFee;
        _previousLiquidityFee = _liquidityFee;
        _previousDevelopmentFee = _developmentFee;

        _taxFee = 0;
        _liquidityFee = 0;
        _developmentFee = 0;
    }

    function restoreAllFee() private {
        _taxFee = _previousTaxFee;
        _liquidityFee = _previousLiquidityFee;
        _developmentFee = _previousDevelopmentFee;
    }

    function setFees(uint256 taxFee, uint256 liquidityFee, uint256 developmentFee) external onlyOwner {
        require(taxFee <= 10, "Tax fee too high");
        require(liquidityFee <= 10, "Liquidity fee too high");
        require(developmentFee <= 10, "Development fee too high");

        _taxFee = taxFee;
        _liquidityFee = liquidityFee;
        _developmentFee = developmentFee;

        emit FeeUpdated(taxFee, liquidityFee, developmentFee);
    }

    function _transfer(address from, address to, uint256 amount) private {
        require(from != address(0), "Transfer from zero address");
        require(to != address(0), "Transfer to zero address");
        require(amount > 0, "Transfer must be greater than zero");

        if (from != owner() && to != owner()) {
            require(amount <= maxTxAmount, "Exceeds max transaction amount");
        }

        _reflectedBalances[from] -= amount;
        _reflectedBalances[to] += amount;

        emit Transfer(from, to, amount);
    }
}
