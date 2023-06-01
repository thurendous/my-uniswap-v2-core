pragma solidity =0.5.16;

import "./interfaces/IUniswapV2Pair.sol";
import "./UniswapV2ERC20.sol"; // UniswapV2ERC20コントラクトをインポート
import "./libraries/Math.sol";
import "./libraries/UQ112x112.sol"; // mathライブラリ
// interfaces
import "./interfaces/IERC20.sol";
import "./interfaces/IUniswapV2Factory.sol";
import "./interfaces/IUniswapV2Callee.sol";

//UniswapV2Pairコントラクト
contract UniswapV2Pair is IUniswapV2Pair, UniswapV2ERC20 { // permitメソッドを実装しているERC20を継承
    using SafeMath for uint256; // typeにlibraryを使用
    using UQ112x112 for uint224; // typeにlibraryを使用
    //最小の流動性 = 1000
    uint256 public constant MINIMUM_LIQUIDITY = 10**3; // 除数が零になることを避けるためにaddress(0)が保有しているこれくらいの流動性をロックする
    //SELECTOR常量值为'transfer(address,uint256)'字符串哈希值的前4位16进制数字
    bytes4 private constant SELECTOR = bytes4(
        keccak256(bytes("transfer(address,uint256)"))
    );

    address public factory; // ファクトリーアドレス
    address public token0; // token0
    address public token1; // token1

    uint112 private reserve0; // reserve0
    uint112 private reserve1; // reserve1
    uint32 private blockTimestampLast; // reserve更新の最後のtimestamp
    //　price0の累計値
    uint256 public price0CumulativeLast;
    //　price1の累計値
    uint256 public price1CumulativeLast;

    // 直近の流動性変動以降のk値
    //reserve0*reserve1
    uint256 public kLast;
    // re-entrancy攻撃を防ぐ用のロックフラグ
    uint256 private unlocked = 1;

    //イベント:ミント
    event Mint(address indexed sender, uint256 amount0, uint256 amount1);
    //イベント:バーン
    event Burn(
        address indexed sender,
        uint256 amount0,
        uint256 amount1,
        address indexed to
    );
    /**
     * @dev イベント:スワップ
     * @param sender 送信者
     * @param amount0In 入ってくる金額0
     * @param amount1In 入ってくる金額1
     * @param amount0Out 出ていく金額0
     * @param amount1Out 出ていく金額1
     * @param to toアドレス
     */
    event Swap(
        address indexed sender,
        uint256 amount0In,
        uint256 amount1In,
        uint256 amount0Out,
        uint256 amount1Out,
        address indexed to
    );
    /**
     * @dev イベント:同期
     * @param reserve0 reserve0
     * @param reserve1 reserce1
     */
    event Sync(uint112 reserve0, uint112 reserve1);

    /**
     * @dev コンストラクタ、factory変数に実際のfactoryのアドレスを代入
     */
    constructor() public {
        // factoryがデプロイするので、無論これはfactoryのアドレス
        factory = msg.sender;
    }

    /**
     * @param _token0 token0
     * @param _token1 token1
     * @dev 初期化関数、最初に一度のみファクトリーからcallされる
     */
    function initialize(address _token0, address _token1) external {
        //确认调用者为工厂地址
        require(msg.sender == factory, "UniswapV2: FORBIDDEN");
        token0 = _token0;
        token1 = _token1;
    }

    /**
     * @dev modifier:re-entrancy対策
     */
    modifier lock() {
        require(unlocked == 1, "UniswapV2: LOCKED");
        unlocked = 0;
        _;
        unlocked = 1;
    }

    /**
     * @return _reserve0 reserve0
     * @return _reserve1 reserve1
     * @return _blockTimestampLast タイムスタンプ
     * @dev リザーブをゲット
     */
    function getReserves()
        public
        view
        returns (
            uint112 _reserve0,
            uint112 _reserve1,
            uint32 _blockTimestampLast
        )
    {
        _reserve0 = reserve0;
        _reserve1 = reserve1;
        _blockTimestampLast = blockTimestampLast;
    }

    /**
     * @param token tokenアドレス
     * @param to    toアドレス
     * @param value 数量
     * @dev プライベート関数：安全なトランスファー
     */
    function _safeTransfer(
        address token,
        address to,
        uint256 value
    ) private {
        //ローレベルでコールを使ってトークンをトランスファー
        //solium-disable-next-line
        (bool success, bytes memory data) = token.call(
            abi.encodeWithSelector(SELECTOR, to, value)
        );
        // 返り値がtrueで、返り値のdataの長さが0またはデコード後がtrueであることを確認
        require(
            success && (data.length == 0 || abi.decode(data, (bool))),
            "UniswapV2: TRANSFER_FAILED"
        );
    }

    /**
     * @param balance0 balance0
     * @param balance1  balance1
     * @param _reserve0 reserve0
     * @param _reserve1 reserve1
     * @dev reserveをアップデート、private関数。累計価格、タイムスタンプを更新。
     */
    function _update(
        uint256 balance0,
        uint256 balance1,
        uint112 _reserve0,
        uint112 _reserve1
    ) private {
        //uint112をオーバーフローしていないかチェック
        require(
            balance0 <= uint112(-1) && balance1 <= uint112(-1), // overflowチェック
            "UniswapV2: OVERFLOW"
        );
        // uint256タイムスタンプをuint32に変換
        //solium-disable-next-line
        uint32 blockTimestamp = uint32(block.timestamp % 2**32); // uint32が表示できる最大の日付は2106年2月7日6時28分15秒、セーフ変換
        // 時間の経過を計算
        uint32 timeElapsed = blockTimestamp - blockTimestampLast; // overflow is desired
        // 時間的な経過 > 0 and reserve0,reserve1 != 0
        if (timeElapsed > 0 && _reserve0 != 0 && _reserve1 != 0) {
            // * never overflows, and + overflow is desired
            // 累計価格0 += reserve1 * 2**112 / reserve0 * 時間経過
            //solium-disable-next-line
            price0CumulativeLast +=
                uint256(UQ112x112.encode(_reserve1).uqdiv(_reserve0)) *
                timeElapsed;
            // 累計価格1 += reserve0 * 2**112 / reserve1 * 時間経過
            //solium-disable-next-line
            price1CumulativeLast +=
                uint256(UQ112x112.encode(_reserve0).uqdiv(_reserve1)) *
                timeElapsed;
        }
        // reserve0,1にbalance0,1を代入
        reserve0 = uint112(balance0);
        reserve1 = uint112(balance1);
        //blockTimestampLastを更新
        blockTimestampLast = blockTimestamp; // blockTimestampLastは更新のタイミングを記録
        //emit Syncイベント
        emit Sync(reserve0, reserve1);
    }

    /**
     * @param _reserve0 reserve0
     * @param _reserve1 reserve1
     * @return feeOn
     * @dev feeを徴収する場合、feeはsqrt(k)値の1/6の増加(0.05%)に相当する
     */
    function _mintFee(uint112 _reserve0, uint112 _reserve1)
        private
        returns (bool feeOn)
    {
        // feeToアドレスをファクトリーコントラクトからゲット
        address feeTo = IUniswapV2Factory(factory).feeTo();
        // memory変数を定義し、feeToアドレスが0の場合はfalse、そうでない場合true
        feeOn = feeTo != address(0);
        // k値を代入
        uint256 _kLast = kLast; // gas savings
        // feeOnがtrueの場合に実行
        if (feeOn) {
            //kの値が0でない場合に実行。初回流動性提供時にkの値は0
            if (_kLast != 0) {
                //(_reserve0*_reserve1)の平方根
                uint256 rootK = Math.sqrt(uint256(_reserve0).mul(_reserve1));
                //k値の平方根
                uint256 rootKLast = Math.sqrt(_kLast);
                //rootK>rootKLastをチェック
                if (rootK > rootKLast) {
                    //分子 = erc20数量 * (rootK - rootKLast)
                    uint256 numerator = totalSupply.mul(rootK.sub(rootKLast));
                    //分母 = rootK * 5 + rootKLast
                    uint256 denominator = rootK.mul(5).add(rootKLast);
                    //流動性 = 分子 / 分母
                    uint256 liquidity = numerator / denominator;
                    // 流動性 > 0 の場合、LPトークンをfeeToアドレスにmint
                    if (liquidity > 0) _mint(feeTo, liquidity);
                }
            }
            // feeOnがfalseで、_klastがゼロでない場合
        } else if (_kLast != 0) {
            //k=0にした
            kLast = 0;
        }
    }

    /**
     * @param to toアドレス
     * @return liquidity 流動性トークン量
     * @dev ミント関数：2種類のトークンをプールに投入し、流動性トークンをtoに対して発行する
     * @notice この関数はチェックを実施したコントラクトから呼ばれるべき
     */
    // this low-level function should be called from a contract which performs important safety checks
    function mint(address to) external lock returns (uint256 liquidity) {
        //`reserve0`,`reserve1`だけをゲット
        (uint112 _reserve0, uint112 _reserve1, ) = getReserves(); // gas savings
        // 現在のコントラクトの`token0`の残高をゲット
        uint256 balance0 = IERC20(token0).balanceOf(address(this));
        // 現在のコントラクトの`token1`の残高をゲット
        uint256 balance1 = IERC20(token1).balanceOf(address(this));
        //amount0 = balance0 - reserve0 -> このトランザクションにおいて、`token0`の残高の増加量
        uint256 amount0 = balance0.sub(_reserve0);
        //amount1 = balance1 - reserve1
        uint256 amount1 = balance1.sub(_reserve1);

        // feeを徴収するかどうかのスイッチをゲット
        bool feeOn = _mintFee(_reserve0, _reserve1);
        // totalSupplyをゲット。mintFeeに置いて変化する可能性があるので、ここで定義
        uint256 _totalSupply = totalSupply; // gas savings, must be defined here since totalSupply can update in _mintFee
        // _totalSupply == 0
        if (_totalSupply == 0) { // 初回のときに、ミニマム流動性をアドレスゼロへmint
            //流動性 = (数量0 * 数量1)の平方根 - ミニマム流動性の1000
            liquidity = Math.sqrt(amount0.mul(amount1)).sub(MINIMUM_LIQUIDITY);
            // 初回流動性提供時に、永続にミニマム流動性をロックする
            _mint(address(0), MINIMUM_LIQUIDITY); // permanently lock the first MINIMUM_LIQUIDITY tokens
        } else { // 初回でない場合
            // 流動性 = (amount0 * _totalSupply / _reserve0) と (amount1 * _totalSupply / _reserve1)の最小値
            // 流動性はプールの量に比例しない場合を想定した上で、最小値を取ってる
            liquidity = Math.min(
                amount0.mul(_totalSupply) / _reserve0,
                amount1.mul(_totalSupply) / _reserve1
            );
        }
        // 流動性 > 0
        require(liquidity > 0, "UniswapV2: INSUFFICIENT_LIQUIDITY_MINTED");
        // toアドレスに流動性トークンをミント
        _mint(to, liquidity);

        // reserve量を更新
        _update(balance0, balance1, _reserve0, _reserve1);
        // もしfeeOnがtrueの場合、kLastを更新→reserveの更新があったから
        if (feeOn) kLast = uint256(reserve0).mul(reserve1); // reserve0 and reserve1 are up-to-date
        // イベントをemit
        emit Mint(msg.sender, amount0, amount1);
    }

    /**
     * @param to toアドレス
     * @return amount0
     * @return amount1
     * @dev バーン関数
     * @notice この関数はチェックを実施したコントラクトから呼ばれるべき
     */
    // this low-level function should be called from a contract which performs important safety checks
    function burn(address to)
        external
        lock
        returns (uint256 amount0, uint256 amount1)
    {
        //`reserve0`,`reserve1`をゲット
        (uint112 _reserve0, uint112 _reserve1, ) = getReserves(); // gas savings
        // 状態変数をキャッシュ
        address _token0 = token0; // gas savings
        address _token1 = token1; // gas savings
        // 今のtoken1, token0バランスをゲットする
        uint256 balance0 = IERC20(_token0).balanceOf(address(this));
        uint256 balance1 = IERC20(_token1).balanceOf(address(this));
        // ユーザーから送ってきた流動性トークンの量をゲット。これはrouterコントラクトから送付される。
        uint256 liquidity = balanceOf[address(this)];

        // feeがオンになっているかどうかのbool値をゲット
        bool feeOn = _mintFee(_reserve0, _reserve1);
        // toalSupplyを取得。mintFeeにおいて変化する可能性があるので、ここで定義
        uint256 _totalSupply = totalSupply; // gas savings, must be defined here since totalSupply can update in _mintFee
        //amount0 = 流動性 * balance0 / totalSupply 現在の流動性に占める割合に従い、amount0の残高を計算
        amount0 = liquidity.mul(balance0) / _totalSupply; // using balances ensures pro-rata distribution
        //amount1 = 流动性数量 * 余额1 / totalSupply  現在の流動性に占める割合に従い、amount1の残高を計算 
        // -> .3%の手数料が徴収され、スワップも発生するので、amount0, amount1は変化するはず
        amount1 = liquidity.mul(balance1) / _totalSupply; // using balances ensures pro-rata distribution
        //amount0, amount1 > 0をチェック
        require(
            amount0 > 0 && amount1 > 0, // どんな状況でもゼロになることはないはず
            "UniswapV2: INSUFFICIENT_LIQUIDITY_BURNED"
        );
        // 送付した流動性トークンをバーン
        _burn(address(this), liquidity);
        // amount0のtoken0をtoアドレスに送付
        _safeTransfer(_token0, to, amount0);
        // amount1のtoken1をtoアドレスに送付
        _safeTransfer(_token1, to, amount1);
        //balance0更新：トークン送付したので
        balance0 = IERC20(_token0).balanceOf(address(this));
        //balance1更新
        balance1 = IERC20(_token1).balanceOf(address(this));

        //reserve0, reserve1を更新
        _update(balance0, balance1, _reserve0, _reserve1);
        // feeOnがtrueの場合, k = reserve0 * reserve1
        if (feeOn) kLast = uint256(reserve0).mul(reserve1); // reserve0 and reserve1 are up-to-date
        // イベントをemit
        emit Burn(msg.sender, amount0, amount1, to); // msg.senderはrouterコントラクトのはず
    }

    /**
     * @param amount0Out amount0のアウトプット
     * @param amount1Out amount1のアウトプット
     * @param to    toアドレス
     * @param data  dataでdynamicな長さのbyteデータ
     * @dev スワップ関数、手数料の計算が含まれていないが、チェックはされている
     * @notice この関数はチェックを実施したコントラクトから呼ばれるべき。Routerから呼ばれる
     */
     // 初めてスワップ関数だけを読むとちんぷんかんぷんになるので、Routerコントラクトを通して理解したほうが良い
    // this low-level function should be called from a contract which performs important safety checks
    function swap(
        uint256 amount0Out,
        uint256 amount1Out,
        address to,
        bytes calldata data
    ) external lock {
        //まずamount0Out、amount1Outは0より大きいこと
        require(
            amount0Out > 0 || amount1Out > 0,
            "UniswapV2: INSUFFICIENT_OUTPUT_AMOUNT"
        );
        //`reserve0`,`reserve1`を取得
        (uint112 _reserve0, uint112 _reserve1, ) = getReserves(); // gas savings
        //`amount0Out,amount1Out` < `reserve0,1`の条件を満たす
        require(
            amount0Out < _reserve0 && amount1Out < _reserve1,
            "UniswapV2: INSUFFICIENT_LIQUIDITY"
        );

        // 初期化する
        uint256 balance0;
        uint256 balance1;
        {
            // _token{0,1}についてローカルスコープを確保、stack too deepエラーを避ける
            // scope for _token{0,1}, avoids stack too deep errors
            address _token0 = token0;
            address _token1 = token1;

            //toアドレスが_token0、_token1とイコールでないことをチェック、誤送信防止
            require(to != _token0 && to != _token1, "UniswapV2: INVALID_TO");
            // `amountOut0` > 0 なら、toへ送信する
            if (amount0Out > 0) _safeTransfer(_token0, to, amount0Out); // optimistically transfer tokens
            // `amountOut1` > 0 なら、toへ送信する
            if (amount1Out > 0) _safeTransfer(_token1, to, amount1Out); // optimistically transfer tokens
            // dataの長さが0より大きいなら、`to`に対して`data`を実行する　→　フラッシュローン関連の処理
            if (data.length > 0)
                IUniswapV2Callee(to).uniswapV2Call(
                    msg.sender,
                    amount0Out,
                    amount1Out,
                    data
                );
            //`balance0,1` = 現時点コントラクトにある`token0,1`のバランス
            balance0 = IERC20(_token0).balanceOf(address(this));
            balance1 = IERC20(_token1).balanceOf(address(this));
        }
        // もし balance0 > reserve0 - amount0Out だと amount0In = balance0 - (reserve0 - amount0Out)、それ以外の場合、 amount0In = 0
        uint256 amount0In = (balance0 > _reserve0 - amount0Out)
            ? balance0 - (_reserve0 - amount0Out)
            : 0;
        // もし balance1 > reserve1 - amount1Out だと amount1In = balance1 - (reserve1 - amount1Out)、それ以外の場合、 amount1In = 0
        uint256 amount1In = (balance1 > _reserve1 - amount1Out)
            ? balance1 - (_reserve1 - amount1Out)
            : 0;
        // 上記の計算ではどちらかが0より大きい場合
        require(
            amount0In > 0 || amount1In > 0,
            "UniswapV2: INSUFFICIENT_INPUT_AMOUNT"
        );
        {
            // scope for reserve{0,1}Adjusted, avoids stack too deep errors
            // 調整残高0 = balance0 * 1000 - (amount0In * 3)
            uint256 balance0Adjusted = balance0.mul(1000).sub(amount0In.mul(3));
            // 調整残高1 = balance1 * 1000 - (amount1In * 3)
            uint256 balance1Adjusted = balance1.mul(1000).sub(amount1In.mul(3));
            // balance0Adjusted * balance1Adjusted >= reserve0 * reserve1 * 1000^2 を満たすことを確認
            // 1000^2は上記の1000を乗じていることを考慮したもの
            // このチェックできちんと手数料0.3%をもらったことを確認している
            require(
                balance0Adjusted.mul(balance1Adjusted) >=
                    uint256(_reserve0).mul(_reserve1).mul(1000**2),
                "UniswapV2: K"
            );
        }

        // リザーブを更新する
        _update(balance0, balance1, _reserve0, _reserve1);
        // Swapイベントを発火する
        emit Swap(msg.sender, amount0In, amount1In, amount0Out, amount1Out, to);
    }

    /**
     * @param to toアドレス
     * @dev 強制的にバランスを一致させる関数
     */
    // force balances to match reserves
    function skim(address to) external lock {
        address _token0 = token0; // gas savings
        address _token1 = token1; // gas savings
        //将当前合约在`token0,1`的余额-`储备量0,1`安全发送到to地址
        _safeTransfer(
            _token0,
            to,
            IERC20(_token0).balanceOf(address(this)).sub(reserve0)
        );
        _safeTransfer(
            _token1,
            to,
            IERC20(_token1).balanceOf(address(this)).sub(reserve1)
        );
    }

    /**
     * @dev 強制的にリザーブをバランスと一致させる関数（update関数はリザーブにバランスを代入する）
     */
    // force reserves to match balances
    function sync() external lock {
        _update(
            IERC20(token0).balanceOf(address(this)),
            IERC20(token1).balanceOf(address(this)),
            reserve0,
            reserve1
        );
    }
}
