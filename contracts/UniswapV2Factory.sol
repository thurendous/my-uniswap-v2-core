pragma solidity =0.5.16;

import './interfaces/IUniswapV2Factory.sol';
import './UniswapV2Pair.sol';

//uniswap factoryコントラクト
contract UniswapV2Factory is IUniswapV2Factory {
    address public feeTo; //手数料送信先
    address public feeToSetter; //手数料送信先を設定できるアドレス
    //ペアのマッピング,アドレス=>(アドレス=>アドレス)
    mapping(address => mapping(address => address)) public getPair;
    //全てのペアを保存する配列
    address[] public allPairs;
    //配对合约的Bytecode的hash
    bytes32 public constant INIT_CODE_PAIR_HASH = keccak256(abi.encodePacked(type(UniswapV2Pair).creationCode));
    //イベント:ペア作成のタイミングで放出
    event PairCreated(address indexed token0, address indexed token1, address pair, uint);

    /**
     * @dev コンストラクタ
     * @param _feeToSetter 手数料の管理を担当するアドレス
     */
    constructor(address _feeToSetter) public {
        feeToSetter = _feeToSetter; // feeToSetterに_feeToSetterを代入、本番では0アドレスになっている
    }

    /**
     * @dev 全てのペア配列の長さを返す、
     */
    function allPairsLength() external view returns (uint) {
        return allPairs.length;
    }

    /**
     *
     * @param tokenA TokenA
     * @param tokenB TokenB
     * @return pairアドレス
     * @dev ペアを作成
     */
    function createPair(address tokenA, address tokenB) external returns (address pair) {
        // tokenAとtokenBが異なることを確認
        require(tokenA != tokenB, 'UniswapV2: IDENTICAL_ADDRESSES');
        // tokenAとtokenBをソートする。順番を一定にするため
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        // token0が0アドレスでないことを確認
        require(token0 != address(0), 'UniswapV2: ZERO_ADDRESS');
        // 配对マッピングのtoken0=>token1が0アドレスで、存在しないことをチェック
        require(getPair[token0][token1] == address(0), 'UniswapV2: PAIR_EXISTS'); // single check is sufficient
        // bytecodeに入れるのは、UniswapV2Pairのコントラクトの作成コード。作成コードがrun timeコードと違うことに注意
        bytes memory bytecode = type(UniswapV2Pair).creationCode;
        // saltを作成。keccak256でハッシュ化
        bytes32 salt = keccak256(abi.encodePacked(token0, token1)); // byte32のsaltを作成
        // アセンブリ言語で、create2を呼び出す。create2は、saltを使って、bytecodeをデプロイする
        // solium-disable-next-line
        assembly {
            // assemblyはsolidityだけでは書けないコードを書くために使う
            // create2を使って、bytecodeをデプロイする。返り値は、デプロイしたコントラクトのアドレスで、pairに代入
            pair := create2(0, add(bytecode, 32), mload(bytecode), salt)
        }
        // ペアコントラクトにあるinitialize関数を呼び出す。token0とtoken1を渡し初期化
        IUniswapV2Pair(pair).initialize(token0, token1);
        // token0=>token1=pairのマッピングを保存し、作ったペアを追跡できるようにする
        getPair[token0][token1] = pair;
        // token1=>token0=pairは上記の逆で、逆方向で新規でペアが作成できないようにしたいため、逆の方向でも保存する
        getPair[token1][token0] = pair; // populate mapping in the reverse direction
        // 作成したペアのアドレスをallPairsに保存
        allPairs.push(pair);
        // ペア作成のイベントを発火
        emit PairCreated(token0, token1, pair, allPairs.length);
    }

    /**
     * @dev 手数料送信先を設定
     * @param _feeTo 手数料送信先
     */
    function setFeeTo(address _feeTo) external {
        require(msg.sender == feeToSetter, 'UniswapV2: FORBIDDEN');
        feeTo = _feeTo;
    }

    /**
     * @dev 手数料送信先を設定できるアドレスを設定
     * @param _feeToSetter 手数料送信先を設定できるアドレス
     */
    function setFeeToSetter(address _feeToSetter) external {
        require(msg.sender == feeToSetter, 'UniswapV2: FORBIDDEN');
        feeToSetter = _feeToSetter;
    }
}
