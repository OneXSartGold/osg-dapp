import { useState, useEffect, useCallback, useRef } from "react";
import { BrowserProvider, JsonRpcProvider, FallbackProvider, Contract, formatUnits, parseUnits, isAddress } from "ethers";
import {
  ADDRESSES, ZERO, POLYGON_CHAIN_ID, POLYGON_PARAMS, RPC_URLS,
  TOKEN_ABI, STAKING_ABI, POOL_ABI, MESSENGER_ABI, QUICKSWAP_URL,
} from "./contracts.js";
import { deriveKeypair, encryptMessage, decryptMessage, MAX_PLAINTEXT_CHARS } from "./crypto.js";

// ══════════════════════════════════════════════════════════
//  OSG logo (base64). Replace this string anytime with your
//  own logo data-URI or an imported image URL.
// ══════════════════════════════════════════════════════════
const LOGO = "data:image/jpeg;base64,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";

// ── helpers ──────────────────────────────────────────────
const short = (a) => (a ? `${a.slice(0,6)}…${a.slice(-4)}` : "");
const fmt = (v, d = 2) => Number(v).toLocaleString("en-US", { maximumFractionDigits: d });
const f18 = (bn) => { try { return formatUnits(bn ?? 0n, 18); } catch { return "0"; } };

// ── i18n ─────────────────────────────────────────────────
const I18N = {
  en:{lbl:"EN",connect:"Connect",connectWallet:"Connect Wallet",switchNet:"Switch Network",
    dashboard:"Home",staking:"Stake",referral:"Referral",swap:"Swap",messenger:"Chat",
    osgBalance:"OSG Balance",yourStaked:"Your Staked",pendingReward:"Pending Reward",poolStaked:"Pool Total Staked",
    currentlyLocked:"Currently locked",claimable:"Claimable",allUsers:"All users",
    poolEmission:"Pool & Emission",activeStakers:"Active Stakers",dailyEmission:"Daily Emission",
    yourEarned:"Your Total Earned",yourShare:"Your Share",halving:"Halving #",rewardDist:"Reward Distributed",
    verified:"Verified Contracts",amtStake:"Amount to Stake",balance:"Balance",
    referrerOpt:"Referrer (optional — first stake only)",twoStep:"Staking has two steps: first Approve the token, then Stake. Rewards are earned daily from emissions.",
    addToStake:"Add to Stake",stakeBtn:"Stake",unstakeTab:"Unstake",claimTab:"Claim",
    currentlyStaked:"Currently Staked",reqUnstakeInfo:"To unstake, first send a Request → tokens become withdrawable after the cooldown.",
    requestUnstake:"Request Unstake",cooldownDone:"Cooldown complete — you can withdraw now!",cooldownWait:"Cooldown in progress — please wait a little longer.",
    withdrawNow:"Withdraw Now",cancel:"Cancel",claimableReward:"Claimable Reward",thisChunk:"OSG (this chunk)",totalPending:"Total pending",claimReward:"Claim Reward",
    refEarned:"Referral Earned",totalRefs:"Total Referrals",pendingRef:"Pending Referral",teamBonus:"Team Bonus",
    osgTotal:"OSG total",directTeam:"Direct + team",yourRefLink:"Your Referral Link",copy:"Copy",
    shareLink:"Share this link — whoever stakes for the first time using it becomes your referral.",
    upline:"Your Upline (5 Levels)",empty:"— empty —",yourReferrer:"Your Referrer",noReferrer:"No referrer set",
    swapTitle:"Swap POL → OSG",swapDesc:"The OSG liquidity pool is now LIVE on QuickSwap. In-app swap is coming soon — for now, swap securely on QuickSwap below.",
    swapMeanwhile:"In the meantime, you can swap directly on QuickSwap below.",openQuickswap:"Open QuickSwap",
    comingSoon:"Coming Soon",msgTitle:"OSG MESSENGER",targetLaunch:"Target launch: Q3 2026",
    connectSee:"Connect your wallet to see real data",
    tEnterAmt:"Enter an amount!",tConnFirst:"Connect wallet first!",tSwitchPoly:"Switch to Polygon!",tInstall:"Please install MetaMask!",
    tApproving:"1/2 — Approving…",tStaking:"2/2 — Staking…",tStakeOk:"Stake successful!",tStakeFail:"Stake failed",
    tUnstakeReq:"Unstake requested — cooldown started!",tUnstakeOk:"Unstaked — tokens returned!",tCancelled:"Unstake cancelled",
    tClaimed:"Reward claimed!",tClaimFail:"Claim failed",tConnected:"Wallet connected!",tConnFail:"Connection failed",tCopied:"Referral link copied!",tFailed:"Failed",chatTitle:"Messages",chatSub:"Wallet-to-wallet chat on Polygon.",recipient:"Recipient address",typeMsg:"Type a message…",send:"Send",noMsgs:"No messages yet. Start the conversation!",you:"You",inbox:"Inbox",feeNote:"A small network fee may apply per message.",tSent:"Message sent!",tBadAddr:"Enter a valid recipient address!",tEmptyMsg:"Type a message first!",loadingMsgs:"Loading messages…"},
  hi:{lbl:"हिं",connect:"कनेक्ट",connectWallet:"वॉलेट कनेक्ट करें",switchNet:"नेटवर्क बदलें",
    dashboard:"होम",staking:"स्टेक",referral:"रेफरल",swap:"स्वैप",messenger:"चैट",
    osgBalance:"OSG बैलेंस",yourStaked:"आपका स्टेक",pendingReward:"लंबित इनाम",poolStaked:"पूल कुल स्टेक",
    currentlyLocked:"वर्तमान में लॉक",claimable:"क्लेम योग्य",allUsers:"सभी यूज़र",
    poolEmission:"पूल और एमिशन",activeStakers:"सक्रिय स्टेकर",dailyEmission:"दैनिक एमिशन",
    yourEarned:"आपकी कुल कमाई",yourShare:"आपका हिस्सा",halving:"हाविंग #",rewardDist:"इनाम वितरित",
    verified:"सत्यापित कॉन्ट्रैक्ट",amtStake:"स्टेक राशि",balance:"बैलेंस",
    referrerOpt:"रेफरर (वैकल्पिक — केवल पहली स्टेक)",twoStep:"स्टेकिंग के दो चरण: पहले टोकन Approve करें, फिर Stake। इनाम रोज़ एमिशन से मिलते हैं।",
    addToStake:"स्टेक में जोड़ें",stakeBtn:"स्टेक करें",unstakeTab:"अनस्टेक",claimTab:"क्लेम",
    currentlyStaked:"वर्तमान स्टेक",reqUnstakeInfo:"अनस्टेक के लिए पहले Request भेजें → कूलडाउन के बाद टोकन निकाले जा सकते हैं।",
    requestUnstake:"अनस्टेक अनुरोध",cooldownDone:"कूलडाउन पूरा — अब निकाल सकते हैं!",cooldownWait:"कूलडाउन जारी — कृपया थोड़ा इंतज़ार करें।",
    withdrawNow:"अभी निकालें",cancel:"रद्द करें",claimableReward:"क्लेम योग्य इनाम",thisChunk:"OSG (यह चंक)",totalPending:"कुल लंबित",claimReward:"इनाम क्लेम करें",
    refEarned:"रेफरल कमाई",totalRefs:"कुल रेफरल",pendingRef:"लंबित रेफरल",teamBonus:"टीम बोनस",
    osgTotal:"OSG कुल",directTeam:"प्रत्यक्ष + टीम",yourRefLink:"आपका रेफरल लिंक",copy:"कॉपी",
    shareLink:"यह लिंक शेयर करें — जो पहली बार इससे स्टेक करेगा वह आपका रेफरल बनेगा।",
    upline:"आपकी अपलाइन (5 स्तर)",empty:"— खाली —",yourReferrer:"आपका रेफरर",noReferrer:"कोई रेफरर नहीं",
    swapTitle:"POL → OSG स्वैप",swapDesc:"लिक्विडिटी पूल अभी लाइव नहीं है। जुड़ते ही इन-ऐप स्वैप यहीं उपलब्ध होगा।",
    swapMeanwhile:"तब तक आप QuickSwap पर सीधे स्वैप कर सकते हैं।",openQuickswap:"QuickSwap खोलें",
    comingSoon:"जल्द आ रहा है",msgTitle:"OSG मैसेंजर",targetLaunch:"लक्षित लॉन्च: Q3 2026",
    connectSee:"असली डेटा देखने के लिए वॉलेट कनेक्ट करें",
    tEnterAmt:"राशि दर्ज करें!",tConnFirst:"पहले वॉलेट कनेक्ट करें!",tSwitchPoly:"Polygon पर स्विच करें!",tInstall:"कृपया MetaMask इंस्टॉल करें!",
    tApproving:"1/2 — Approve हो रहा है…",tStaking:"2/2 — स्टेक हो रहा है…",tStakeOk:"स्टेक सफल!",tStakeFail:"स्टेक विफल",
    tUnstakeReq:"अनस्टेक अनुरोध — कूलडाउन शुरू!",tUnstakeOk:"अनस्टेक — टोकन वापस!",tCancelled:"अनस्टेक रद्द",
    tClaimed:"इनाम क्लेम हुआ!",tClaimFail:"क्लेम विफल",tConnected:"वॉलेट कनेक्ट!",tConnFail:"कनेक्शन विफल",tCopied:"रेफरल लिंक कॉपी हुआ!",tFailed:"विफल",chatTitle:"संदेश",chatSub:"Polygon पर वॉलेट-टू-वॉलेट चैट।",recipient:"प्राप्तकर्ता पता",typeMsg:"संदेश लिखें…",send:"भेजें",noMsgs:"अभी कोई संदेश नहीं। बातचीत शुरू करें!",you:"आप",inbox:"इनबॉक्स",feeNote:"प्रति संदेश थोड़ा नेटवर्क शुल्क लग सकता है।",tSent:"संदेश भेजा गया!",tBadAddr:"सही प्राप्तकर्ता पता डालें!",tEmptyMsg:"पहले संदेश लिखें!",loadingMsgs:"संदेश लोड हो रहे हैं…"},
  zh:{lbl:"中文",connect:"连接",connectWallet:"连接钱包",switchNet:"切换网络",
    dashboard:"首页",staking:"质押",referral:"推荐",swap:"兑换",messenger:"聊天",
    osgBalance:"OSG 余额",yourStaked:"已质押",pendingReward:"待领奖励",poolStaked:"质押池总量",
    currentlyLocked:"当前锁定",claimable:"可领取",allUsers:"所有用户",
    poolEmission:"池与释放",activeStakers:"活跃质押者",dailyEmission:"每日释放",
    yourEarned:"累计收益",yourShare:"我的占比",halving:"减半 #",rewardDist:"已分配奖励",
    verified:"已验证合约",amtStake:"质押金额",balance:"余额",
    referrerOpt:"推荐人（可选 — 仅首次质押）",twoStep:"质押分两步：先授权代币，再质押。奖励每日从释放中获得。",
    addToStake:"追加质押",stakeBtn:"质押",unstakeTab:"解押",claimTab:"领取",
    currentlyStaked:"当前质押",reqUnstakeInfo:"解押需先发送请求 → 冷却期后可提取代币。",
    requestUnstake:"申请解押",cooldownDone:"冷却完成 — 现在可提取！",cooldownWait:"冷却中 — 请稍候。",
    withdrawNow:"立即提取",cancel:"取消",claimableReward:"可领取奖励",thisChunk:"OSG（本期）",totalPending:"待领总额",claimReward:"领取奖励",
    refEarned:"推荐收益",totalRefs:"推荐总数",pendingRef:"待领推荐",teamBonus:"团队奖励",
    osgTotal:"OSG 总计",directTeam:"直推 + 团队",yourRefLink:"你的推荐链接",copy:"复制",
    shareLink:"分享此链接 — 首次通过它质押的人将成为你的推荐。",
    upline:"你的上线（5级）",empty:"— 空 —",yourReferrer:"你的推荐人",noReferrer:"未设置推荐人",
    swapTitle:"POL → OSG 兑换",swapDesc:"流动性池尚未上线。添加后，应用内兑换将在此处提供。",
    swapMeanwhile:"在此期间，你可在 QuickSwap 直接兑换。",openQuickswap:"打开 QuickSwap",
    comingSoon:"即将推出",msgTitle:"OSG 通讯",targetLaunch:"预计上线：2026 Q3",
    connectSee:"连接钱包以查看真实数据",
    tEnterAmt:"请输入金额！",tConnFirst:"请先连接钱包！",tSwitchPoly:"请切换到 Polygon！",tInstall:"请安装 MetaMask！",
    tApproving:"1/2 — 授权中…",tStaking:"2/2 — 质押中…",tStakeOk:"质押成功！",tStakeFail:"质押失败",
    tUnstakeReq:"已申请解押 — 冷却开始！",tUnstakeOk:"已解押 — 代币已返还！",tCancelled:"解押已取消",
    tClaimed:"奖励已领取！",tClaimFail:"领取失败",tConnected:"钱包已连接！",tConnFail:"连接失败",tCopied:"推荐链接已复制！",tFailed:"失败",chatTitle:"消息",chatSub:"Polygon 上的钱包间聊天。",recipient:"接收方地址",typeMsg:"输入消息…",send:"发送",noMsgs:"还没有消息。开始对话吧！",you:"你",inbox:"收件箱",feeNote:"每条消息可能收取少量网络费用。",tSent:"消息已发送！",tBadAddr:"请输入有效的接收方地址！",tEmptyMsg:"请先输入消息！",loadingMsgs:"正在加载消息…"},
  mr:{lbl:"मरा",connect:"कनेक्ट",connectWallet:"वॉलेट कनेक्ट करा",switchNet:"नेटवर्क बदला",
    dashboard:"होम",staking:"स्टेक",referral:"रेफरल",swap:"स्वॅप",messenger:"चॅट",
    osgBalance:"OSG बॅलन्स",yourStaked:"तुमचा स्टेक",pendingReward:"प्रलंबित बक्षीस",poolStaked:"पूल एकूण स्टेक",
    currentlyLocked:"सध्या लॉक",claimable:"क्लेम करण्यायोग्य",allUsers:"सर्व यूझर",
    poolEmission:"पूल आणि एमिशन",activeStakers:"सक्रिय स्टेकर",dailyEmission:"दैनिक एमिशन",
    yourEarned:"तुमची एकूण कमाई",yourShare:"तुमचा हिस्सा",halving:"हाविंग #",rewardDist:"बक्षीस वितरित",
    verified:"सत्यापित कॉन्ट्रॅक्ट",amtStake:"स्टेक रक्कम",balance:"बॅलन्स",
    referrerOpt:"रेफरर (ऐच्छिक — फक्त पहिली स्टेक)",twoStep:"स्टेकिंगचे दोन टप्पे: आधी टोकन Approve करा, मग Stake. बक्षीस रोज एमिशनमधून मिळते.",
    addToStake:"स्टेकमध्ये जोडा",stakeBtn:"स्टेक करा",unstakeTab:"अनस्टेक",claimTab:"क्लेम",
    currentlyStaked:"सध्याचा स्टेक",reqUnstakeInfo:"अनस्टेकसाठी आधी Request पाठवा → कूलडाउननंतर टोकन काढता येतील.",
    requestUnstake:"अनस्टेक विनंती",cooldownDone:"कूलडाउन पूर्ण — आता काढू शकता!",cooldownWait:"कूलडाउन चालू — कृपया थोडं थांबा.",
    withdrawNow:"आता काढा",cancel:"रद्द करा",claimableReward:"क्लेम करण्यायोग्य बक्षीस",thisChunk:"OSG (हा चंक)",totalPending:"एकूण प्रलंबित",claimReward:"बक्षीस क्लेम करा",
    refEarned:"रेफरल कमाई",totalRefs:"एकूण रेफरल",pendingRef:"प्रलंबित रेफरल",teamBonus:"टीम बोनस",
    osgTotal:"OSG एकूण",directTeam:"थेट + टीम",yourRefLink:"तुमचा रेफरल लिंक",copy:"कॉपी",
    shareLink:"हा लिंक शेअर करा — जो पहिल्यांदा यातून स्टेक करेल तो तुमचा रेफरल होईल.",
    upline:"तुमची अपलाइन (5 स्तर)",empty:"— रिकामे —",yourReferrer:"तुमचा रेफरर",noReferrer:"रेफरर सेट नाही",
    swapTitle:"POL → OSG स्वॅप",swapDesc:"लिक्विडिटी पूल अजून लाइव्ह नाही. जोडल्यावर इन-अॅप स्वॅप इथेच मिळेल.",
    swapMeanwhile:"तोवर तुम्ही QuickSwap वर थेट स्वॅप करू शकता.",openQuickswap:"QuickSwap उघडा",
    comingSoon:"लवकरच येत आहे",msgTitle:"OSG मेसेंजर",targetLaunch:"लक्ष्य लॉन्च: Q3 2026",
    connectSee:"खरा डेटा पाहण्यासाठी वॉलेट कनेक्ट करा",
    tEnterAmt:"रक्कम टाका!",tConnFirst:"आधी वॉलेट कनेक्ट करा!",tSwitchPoly:"Polygon वर स्विच करा!",tInstall:"कृपया MetaMask इन्स्टॉल करा!",
    tApproving:"1/2 — Approve होत आहे…",tStaking:"2/2 — स्टेक होत आहे…",tStakeOk:"स्टेक यशस्वी!",tStakeFail:"स्टेक अयशस्वी",
    tUnstakeReq:"अनस्टेक विनंती — कूलडाउन सुरू!",tUnstakeOk:"अनस्टेक — टोकन परत!",tCancelled:"अनस्टेक रद्द",
    tClaimed:"बक्षीस क्लेम झाले!",tClaimFail:"क्लेम अयशस्वी",tConnected:"वॉलेट कनेक्ट!",tConnFail:"कनेक्शन अयशस्वी",tCopied:"रेफरल लिंक कॉपी झाला!",tFailed:"अयशस्वी",chatTitle:"संदेश",chatSub:"Polygon वर वॉलेट-टू-वॉलेट चॅट.",recipient:"प्राप्तकर्ता पत्ता",typeMsg:"संदेश लिहा…",send:"पाठवा",noMsgs:"अजून संदेश नाहीत. संवाद सुरू करा!",you:"तुम्ही",inbox:"इनबॉक्स",feeNote:"प्रत्येक संदेशासाठी थोडं नेटवर्क शुल्क लागू शकतं.",tSent:"संदेश पाठवला!",tBadAddr:"वैध प्राप्तकर्ता पत्ता टाका!",tEmptyMsg:"आधी संदेश लिहा!",loadingMsgs:"संदेश लोड होत आहेत…"},
  es:{lbl:"ES",connect:"Conectar",connectWallet:"Conectar billetera",switchNet:"Cambiar red",
    dashboard:"Inicio",staking:"Staking",referral:"Referido",swap:"Cambiar",messenger:"Chat",
    osgBalance:"Saldo OSG",yourStaked:"En staking",pendingReward:"Recompensa pendiente",poolStaked:"Total del pool",
    currentlyLocked:"Bloqueado actualmente",claimable:"Reclamable",allUsers:"Todos los usuarios",
    poolEmission:"Pool y emisión",activeStakers:"Stakers activos",dailyEmission:"Emisión diaria",
    yourEarned:"Total ganado",yourShare:"Tu parte",halving:"Halving #",rewardDist:"Recompensa distribuida",
    verified:"Contratos verificados",amtStake:"Cantidad a stakear",balance:"Saldo",
    referrerOpt:"Referidor (opcional — solo primer stake)",twoStep:"El staking tiene dos pasos: primero Aprobar el token, luego Stakear. Las recompensas se ganan a diario.",
    addToStake:"Añadir al stake",stakeBtn:"Stakear",unstakeTab:"Retirar",claimTab:"Reclamar",
    currentlyStaked:"En staking",reqUnstakeInfo:"Para retirar, primero envía una Solicitud → los tokens se podrán retirar tras el enfriamiento.",
    requestUnstake:"Solicitar retiro",cooldownDone:"¡Enfriamiento completo — ya puedes retirar!",cooldownWait:"Enfriamiento en curso — espera un poco más.",
    withdrawNow:"Retirar ahora",cancel:"Cancelar",claimableReward:"Recompensa reclamable",thisChunk:"OSG (este tramo)",totalPending:"Total pendiente",claimReward:"Reclamar recompensa",
    refEarned:"Ganado por referidos",totalRefs:"Total referidos",pendingRef:"Referido pendiente",teamBonus:"Bono de equipo",
    osgTotal:"OSG total",directTeam:"Directo + equipo",yourRefLink:"Tu enlace de referido",copy:"Copiar",
    shareLink:"Comparte este enlace — quien haga staking por primera vez con él será tu referido.",
    upline:"Tu línea ascendente (5 niveles)",empty:"— vacío —",yourReferrer:"Tu referidor",noReferrer:"Sin referidor",
    swapTitle:"Cambiar POL → OSG",swapDesc:"El pool de liquidez aún no está activo. Cuando se añada, el cambio in-app estará aquí.",
    swapMeanwhile:"Mientras tanto, puedes cambiar directamente en QuickSwap abajo.",openQuickswap:"Abrir QuickSwap",
    comingSoon:"Próximamente",msgTitle:"OSG MENSAJERO",targetLaunch:"Lanzamiento previsto: Q3 2026",
    connectSee:"Conecta tu billetera para ver datos reales",
    tEnterAmt:"¡Ingresa una cantidad!",tConnFirst:"¡Conecta la billetera primero!",tSwitchPoly:"¡Cambia a Polygon!",tInstall:"¡Instala MetaMask!",
    tApproving:"1/2 — Aprobando…",tStaking:"2/2 — Stakeando…",tStakeOk:"¡Stake exitoso!",tStakeFail:"Stake fallido",
    tUnstakeReq:"Retiro solicitado — ¡enfriamiento iniciado!",tUnstakeOk:"Retirado — ¡tokens devueltos!",tCancelled:"Retiro cancelado",
    tClaimed:"¡Recompensa reclamada!",tClaimFail:"Reclamo fallido",tConnected:"¡Billetera conectada!",tConnFail:"Conexión fallida",tCopied:"¡Enlace de referido copiado!",tFailed:"Fallido",chatTitle:"Mensajes",chatSub:"Chat de billetera a billetera en Polygon.",recipient:"Dirección del destinatario",typeMsg:"Escribe un mensaje…",send:"Enviar",noMsgs:"Aún no hay mensajes. ¡Inicia la conversación!",you:"Tú",inbox:"Bandeja",feeNote:"Puede aplicarse una pequeña tarifa de red por mensaje.",tSent:"¡Mensaje enviado!",tBadAddr:"¡Ingresa una dirección de destinatario válida!",tEmptyMsg:"¡Escribe un mensaje primero!",loadingMsgs:"Cargando mensajes…"},
};
const LANGS = [
  {id:"en",fl:"🇬🇧",name:"English"},
  {id:"hi",fl:"🇮🇳",name:"हिंदी"},
  {id:"zh",fl:"🇨🇳",name:"中文"},
  {id:"mr",fl:"🇮🇳",name:"मराठी"},
  {id:"es",fl:"🇪🇸",name:"Español"},
];

// ── theme tokens ─────────────────────────────────────────
const C = {
  bg:"#08080B", bg2:"#0E0E14", card:"#15151E", card2:"#1B1B26",
  line:"rgba(255,255,255,.07)", line2:"rgba(255,255,255,.12)",
  txt:"#F4F4F5", txt2:"#9A9AA8", txt3:"#5E5E6E",
  gold1:"#F7D27A", gold2:"#E9B949", gold3:"#C4912E",
  green:"#46D08A", red:"#F2675C", blue:"#38BDF8", purple:"#A78BFA",
  grad:"linear-gradient(135deg,#F7D27A 0%,#E9B949 45%,#C4912E 100%)",
};

const STYLES = `
@import url('https://fonts.googleapis.com/css2?family=Bricolage+Grotesque:opsz,wght@12..96,600;12..96,700;12..96,800&family=Hanken+Grotesk:wght@400;500;600;700&family=JetBrains+Mono:wght@400;500;600&family=Noto+Sans+SC:wght@500;700&family=Noto+Sans+Devanagari:wght@500;700&display=swap');
@keyframes osgpulse{0%{box-shadow:0 0 0 0 rgba(70,208,138,.5),0 0 8px rgba(70,208,138,.6)}70%{box-shadow:0 0 0 7px rgba(70,208,138,0),0 0 8px rgba(70,208,138,.6)}100%{box-shadow:0 0 0 0 rgba(70,208,138,0),0 0 8px rgba(70,208,138,.6)}}@keyframes shine{0%{background-position:120% 0}100%{background-position:-120% 0}}
*{margin:0;padding:0;box-sizing:border-box;-webkit-tap-highlight-color:transparent}
body{font-family:'Hanken Grotesk',sans-serif;background:${C.bg};color:${C.txt}}
:lang(zh){font-family:'Noto Sans SC','Hanken Grotesk',sans-serif}
.osg-app{position:relative;width:100%;max-width:460px;margin:0 auto;min-height:100dvh;
  background:radial-gradient(120% 60% at 80% -5%,rgba(233,185,73,.12),transparent 60%),radial-gradient(90% 50% at -10% 8%,rgba(56,189,248,.06),transparent 55%),${C.bg};
  display:flex;flex-direction:column;overflow-x:hidden}
.osg-app::-webkit-scrollbar{width:0}
.disp{font-family:'Bricolage Grotesque',sans-serif}
.mono{font-family:'JetBrains Mono',monospace}
.topbar{position:sticky;top:0;z-index:50;display:flex;align-items:center;justify-content:space-between;padding:14px 16px;background:rgba(8,8,11,.78);backdrop-filter:blur(18px);-webkit-backdrop-filter:blur(18px);border-bottom:1px solid ${C.line}}
.brand{display:flex;flex-direction:column;align-items:center;gap:5px}
.logo-img{width:42px;height:42px;border-radius:12px;object-fit:cover;border:1px solid rgba(233,185,73,.25);box-shadow:0 6px 22px -6px rgba(233,185,73,.45)}
.brand .name{font-family:'Bricolage Grotesque';font-weight:800;font-size:15px;letter-spacing:-.3px}
.brand .sub{font-size:10px;color:${C.txt3};letter-spacing:1.5px;text-transform:uppercase;margin-top:2px}
.top-right{display:flex;align-items:center;gap:8px;height:42px;align-self:flex-start}
.lang{position:relative}
.lang-btn{display:flex;align-items:center;gap:6px;background:${C.card};border:1px solid ${C.line2};height:42px;padding:0 14px;border-radius:12px;cursor:pointer;font-size:12px;font-weight:600;color:${C.txt};font-family:'Hanken Grotesk'}
.lang-btn svg{width:14px;height:14px;color:${C.gold2}}
.lang-menu{position:absolute;top:44px;right:0;background:${C.card2};border:1px solid ${C.line2};border-radius:14px;padding:6px;min-width:150px;z-index:60;box-shadow:0 18px 40px -12px rgba(0,0,0,.7)}
.lang-menu button{display:flex;align-items:center;gap:9px;width:100%;background:none;border:none;color:${C.txt2};font-size:13.5px;font-weight:600;padding:10px 11px;border-radius:9px;cursor:pointer;text-align:left;font-family:'Hanken Grotesk'}
.lang-menu button:hover{background:${C.card};color:${C.txt}}
.lang-menu button.sel{color:${C.gold1}}
.net-pill{padding:5px 10px;border-radius:99px;font-size:11px;font-weight:700;cursor:pointer;border:1px solid}
.wallet-pill{display:flex;align-items:center;gap:7px;background:${C.card};border:1px solid ${C.line2};height:42px;padding:0 14px;border-radius:12px;cursor:pointer}
.wallet-pill .dot{width:7px;height:7px;border-radius:50%}
.wallet-pill .addr{font-family:'JetBrains Mono';font-size:11.5px;font-weight:500}
.btn-gold{width:100%;border:none;cursor:pointer;font-family:'Hanken Grotesk';font-weight:700;font-size:15px;color:#1A1407;background:${C.grad};border-radius:14px;padding:15px;letter-spacing:.2px;transition:.18s;box-shadow:0 10px 30px -10px rgba(233,185,73,.55)}
.btn-gold:active{transform:scale(.98)}
.btn-gold:disabled{opacity:.45;cursor:not-allowed;box-shadow:none;filter:none}
.btn-ghost{width:100%;background:transparent;color:${C.gold1};border:1px solid rgba(233,185,73,.35);border-radius:14px;padding:14px;font-family:'Hanken Grotesk';font-weight:700;font-size:14px;cursor:pointer}
.btn-ghost:disabled{opacity:.4;cursor:not-allowed}
.btn-danger{width:100%;background:transparent;color:${C.red};border:1px solid rgba(242,103,92,.4);border-radius:14px;padding:14px;font-family:'Hanken Grotesk';font-weight:700;font-size:14px;cursor:pointer}
.btn-danger:disabled{opacity:.4;cursor:not-allowed}
.screen{flex:1;padding:8px 16px 110px}
.page{animation:fade .4s ease both}
@keyframes fade{from{opacity:0;transform:translateY(10px)}to{opacity:1;transform:none}}
.stag>*{opacity:0;animation:rise .5s cubic-bezier(.2,.7,.3,1) forwards}
.stag>*:nth-child(1){animation-delay:.04s}.stag>*:nth-child(2){animation-delay:.10s}
.stag>*:nth-child(3){animation-delay:.16s}.stag>*:nth-child(4){animation-delay:.22s}
@keyframes rise{from{opacity:0;transform:translateY(16px)}to{opacity:1;transform:none}}
.card{background:${C.card};border:1px solid ${C.line};border-radius:20px;padding:18px}
.page-head{margin:12px 2px 16px}
.page-head h1{font-family:'Bricolage Grotesque';font-size:25px;font-weight:700;letter-spacing:-.6px}
.hero{position:relative;overflow:hidden;background:radial-gradient(140% 120% at 100% 0%,rgba(233,185,73,.18),transparent 55%),linear-gradient(160deg,#1C1A16,#121118);border:1px solid rgba(233,185,73,.22);border-radius:24px;padding:22px}
.hero::after{content:"";position:absolute;right:-40px;top:-40px;width:160px;height:160px;background:${C.grad};filter:blur(60px);opacity:.18;border-radius:50%}
.hero .label{font-size:12px;color:${C.txt2};letter-spacing:.3px;display:flex;align-items:center;gap:7px}
.hero .big{font-family:'JetBrains Mono';font-weight:600;font-size:34px;letter-spacing:-1.2px;margin-top:8px;line-height:1}
.hero .big small{font-family:'Hanken Grotesk';font-size:15px;color:${C.gold2};font-weight:600;margin-left:6px}
.stat-grid{display:grid;grid-template-columns:1fr 1fr;gap:12px;margin-top:14px}
.stat{background:${C.card};border:1px solid ${C.line};border-radius:14px;padding:15px;position:relative;overflow:hidden}
.stat .bar{position:absolute;top:0;left:0;right:0;height:2px}
.stat .t{font-size:10.5px;color:${C.txt3};letter-spacing:.4px;text-transform:uppercase}
.stat .v{font-family:'JetBrains Mono';font-size:20px;font-weight:600;margin-top:8px;letter-spacing:-.5px;word-break:break-all}
.stat .s{font-size:11px;color:${C.txt3};margin-top:3px}
.sec{font-size:11px;color:${C.txt3};text-transform:uppercase;letter-spacing:1px;font-weight:700;font-family:'Bricolage Grotesque';margin-bottom:12px}
.mini-grid{display:grid;grid-template-columns:1fr 1fr;gap:10px}
.mini{background:${C.card2};border:1px solid ${C.line};border-radius:12px;padding:10px 12px}
.mini .k{font-size:10px;color:${C.txt3};text-transform:uppercase;letter-spacing:.4px}
.mini .vv{font-family:'JetBrains Mono';font-size:14px;font-weight:600;margin-top:3px;color:${C.txt}}
.link-row{display:flex;justify-content:space-between;align-items:center;padding:11px 0;border-bottom:1px solid ${C.line};text-decoration:none;color:inherit}
.link-row:last-child{border-bottom:none}
.link-row .ln{font-size:13px;color:${C.txt2}}
.link-row .la{font-family:'JetBrains Mono';font-size:10.5px;color:${C.txt3}}
.tabs2{display:flex;gap:4px;background:${C.card2};border:1px solid ${C.line};border-radius:13px;padding:4px;margin-bottom:14px}
.tab2{flex:1;padding:11px 4px;border:none;border-radius:9px;cursor:pointer;background:transparent;color:${C.txt3};font-family:'Hanken Grotesk';font-weight:700;font-size:13px;transition:.18s}
.tab2.on{background:rgba(233,185,73,.12);color:${C.gold1};border:1px solid rgba(233,185,73,.35)}
.field{background:${C.bg2};border:1px solid ${C.line};border-radius:14px;padding:15px 16px}
.field .row{display:flex;justify-content:space-between;align-items:center}
.field label{font-size:11px;color:${C.txt3};text-transform:uppercase;letter-spacing:.4px}
.field .bal{font-size:11px;color:${C.txt3}}
.inp{width:100%;background:none;border:none;outline:none;color:${C.txt};font-family:'JetBrains Mono';font-size:22px;font-weight:600;letter-spacing:-.5px;margin-top:8px}
.inp::placeholder{color:${C.txt3}}
.inp-sm{width:100%;background:${C.bg2};border:1px solid ${C.line};border-radius:12px;color:${C.txt};font-family:'JetBrains Mono';font-size:12px;padding:12px 13px;outline:none;margin-top:8px}
.inp-sm:focus{border-color:rgba(233,185,73,.5)}
.inp-sm::placeholder{color:${C.txt3}}
.maxb{background:rgba(233,185,73,.15);border:1px solid rgba(233,185,73,.33);color:${C.gold1};border-radius:6px;padding:3px 9px;font-size:10px;cursor:pointer;font-weight:700}
.note{display:flex;gap:10px;align-items:flex-start;background:rgba(233,185,73,.07);border:1px solid rgba(233,185,73,.2);border-radius:13px;padding:13px;font-size:12px;color:${C.txt2};line-height:1.5}
.lvl{display:flex;align-items:center;gap:12px;padding:12px 0;border-bottom:1px solid ${C.line}}
.lvl:last-child{border-bottom:none}
.lvl .n{width:30px;height:30px;border-radius:9px;display:grid;place-items:center;font-family:'JetBrains Mono';font-weight:600;font-size:12px;border:1px solid}
.lvl .ad{flex:1;font-family:'JetBrains Mono';font-size:12.5px}
.ref-link{display:flex;gap:8px;align-items:center;margin-top:8px}
.ref-link .code{flex:1;background:${C.bg2};border:1px dashed ${C.line2};border-radius:11px;padding:11px 13px;font-family:'JetBrains Mono';font-size:11px;color:${C.txt2};overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.copy-btn{background:${C.grad};color:#1A1407;border:none;border-radius:11px;padding:0 16px;font-weight:700;font-size:13px;cursor:pointer;white-space:nowrap}
.msg-wrap{position:relative;overflow:hidden;border-radius:20px;min-height:430px;background:${C.bg2};border:1px solid rgba(233,185,73,.18)}
.msg-grid{position:absolute;inset:0;background-image:linear-gradient(rgba(233,185,73,.05) 1px,transparent 1px),linear-gradient(90deg,rgba(233,185,73,.05) 1px,transparent 1px);background-size:40px 40px;animation:gm 20s linear infinite}
@keyframes gm{to{background-position:40px 40px}}
.cs-badge{display:inline-flex;align-items:center;gap:6px;background:linear-gradient(135deg,rgba(233,185,73,.2),rgba(233,185,73,.05));border:1px solid rgba(233,185,73,.4);border-radius:99px;padding:6px 15px;font-size:11px;font-weight:700;color:${C.gold1};letter-spacing:1.4px}
.feat{display:inline-flex;align-items:center;gap:5px;background:rgba(233,185,73,.06);border:1px solid rgba(233,185,73,.18);border-radius:99px;padding:6px 12px;font-size:11.5px;color:${C.txt2};font-weight:600}
.cd{background:${C.card2};border:1px solid rgba(233,185,73,.2);border-radius:12px;padding:12px 6px;text-align:center}
.cd .cv{font-family:'JetBrains Mono';font-size:24px;font-weight:600;color:${C.gold1}}
.cd .cl{font-size:9px;color:${C.txt3};margin-top:4px;text-transform:uppercase;letter-spacing:1px}
.nav{position:fixed;bottom:0;left:50%;transform:translateX(-50%);width:100%;max-width:460px;z-index:50;display:flex;justify-content:space-around;align-items:center;padding:10px 8px calc(10px + env(safe-area-inset-bottom));background:rgba(10,10,14,.85);backdrop-filter:blur(22px);-webkit-backdrop-filter:blur(22px);border-top:1px solid ${C.line}}
.nav button{background:none;border:none;cursor:pointer;color:${C.txt3};display:flex;flex-direction:column;align-items:center;gap:5px;font-family:'Hanken Grotesk';font-size:10px;font-weight:600;padding:5px 9px;border-radius:12px}
.nav button svg{width:21px;height:21px}
.nav button.on{color:${C.gold1}}
.nav button.on svg{filter:drop-shadow(0 2px 8px rgba(233,185,73,.5))}
.toast{position:fixed;bottom:88px;left:50%;transform:translateX(-50%);background:${C.card2};border:1px solid rgba(233,185,73,.4);border-radius:13px;padding:13px 22px;font-size:13.5px;color:${C.gold1};z-index:9999;font-weight:600;max-width:90%;text-align:center;box-shadow:0 12px 36px rgba(0,0,0,.6);animation:tIn .3s ease}
@keyframes tIn{from{transform:translate(-50%,16px);opacity:0}to{transform:translate(-50%,0);opacity:1}}
.spin{display:inline-block;width:15px;height:15px;border:2px solid rgba(0,0,0,.25);border-top-color:#1A1407;border-radius:50%;animation:sp .7s linear infinite;vertical-align:middle}
@keyframes sp{to{transform:rotate(360deg)}}
`;

// ── icons ────────────────────────────────────────────────
const Ico = {
  home:<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"><path d="m3 9 9-7 9 7v11a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z"/><path d="M9 22V12h6v10"/></svg>,
  stake:<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2"><rect x="3" y="11" width="18" height="11" rx="2"/><path d="M7 11V7a5 5 0 0 1 10 0v4"/></svg>,
  ref:<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round"><path d="M16 7a4 4 0 1 0-8 0"/><circle cx="12" cy="7" r="4"/><path d="M5.3 20a8 8 0 0 1 13.4 0"/></svg>,
  swap:<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"><path d="m16 3 4 4-4 4"/><path d="M20 7H4"/><path d="m8 21-4-4 4-4"/><path d="M4 17h16"/></svg>,
  chat:<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"><path d="M21 11.5a8.38 8.38 0 0 1-.9 3.8 8.5 8.5 0 0 1-7.6 4.7 8.38 8.38 0 0 1-3.8-.9L3 21l1.9-5.7a8.38 8.38 0 0 1-.9-3.8 8.5 8.5 0 0 1 4.7-7.6 8.38 8.38 0 0 1 3.8-.9h.5a8.48 8.48 0 0 1 8 8z"/></svg>,
};

// ── reusable Stat ────────────────────────────────────────
function Stat({ label, value, sub, accent }) {
  return (
    <div className="stat">
      <div className="bar" style={{ background:`linear-gradient(90deg,${accent},transparent)` }}/>
      <div className="t">{label}</div>
      <div className="v" style={{ color:accent }}>{value}</div>
      {sub && <div className="s">{sub}</div>}
    </div>
  );
}

// ══════════════ PAGES ══════════════
function Dashboard({ data, wallet, polUsd, t }) {
  const [calcUsd, setCalcUsd] = useState("100");
  const [calcOsg, setCalcOsg] = useState("1,298.70");
  const links = [["OSG Token", ADDRESSES.token],["Staking", ADDRESSES.staking],["Reward Pool", ADDRESSES.pool],["Bond", ADDRESSES.bond],["Messenger", ADDRESSES.messenger]];

  // ============================================================
  //  OSG MARKET RATE
  //  When the liquidity pool is live, change only the 5 fields below:
  //  set live: true, and fill price / change / vol / liq with real
  //  data (or fetch them here from a DEX / contract).
  //  Give "change" a number and the green/red styling is automatic.
  // ============================================================
  var mkt = {
    live: true,             // set true when the pool is live
    price: "1 OSG = " + (function(){ if(!wallet || !(data && data.osgPerPol)) return "0.00"; var x = Number(data.osgPerPol); return (x >= 1 ? x.toFixed(x >= 100 ? 0 : 2) : x.toFixed(4)); })() + " POL",
    change: null,            // live 24h %: e.g. 2.34 or -1.2  (null = pre-market)
    vol: "—",                // live e.g. "12.3K"
    liq: "~3,160 POL",
    priceNum: (function(){ if(!wallet || !(data && data.osgPerPol)) return "0.00"; var x = Number(data.osgPerPol); return (x >= 1 ? x.toFixed(x >= 100 ? 0 : 2) : x.toFixed(4)); })(),
    holders: "22",
  };
  // ============================================================
  var _ch = mkt.change, _up = typeof _ch === "number" && _ch > 0, _dn = typeof _ch === "number" && _ch < 0;
  var _chCol = _up ? C.green : _dn ? C.red : C.txt3;
  var _chBg  = _up ? "rgba(70,208,138,.12)" : _dn ? "rgba(242,103,92,.12)" : "rgba(255,255,255,.05)";
  var _chBd  = _up ? "rgba(70,208,138,.3)" : _dn ? "rgba(242,103,92,.3)" : "transparent";
  var _chTxt = (typeof _ch === "number") ? ((_up ? "▲ +" : _dn ? "▼ " : "") + _ch.toFixed(2) + "%") : "— New";

  // halving countdown (seconds -> "2y 114d" / "30d" / "5h")
  var hsecs = Number(data.timeNextHalving) || 0;
  var hc = "";
  if (hsecs > 0) {
    var hd = Math.floor(hsecs / 86400), hy = Math.floor(hd / 365), hrd = hd % 365;
    hc = hy > 0 ? (hy + "y " + hrd + "d") : (hd > 0 ? (hd + "d") : (Math.floor(hsecs / 3600) + "h"));
  }
  var halvingVal = fmt(data.halving,0) + (hc ? ("  ·  " + hc) : "");

  return (
    <div className="page stag">

      {/* MARKET HERO — balance + market + calculator */}
      {(function(){
        var OSG_PER_POL = 1;
        var pol = (typeof polUsd === "number" && polUsd > 0) ? polUsd : 0.077;
        var cnum = function(s){ var n = parseFloat(String(s).replace(/,/g,"")); return n > 0 ? n : 0; };
        var cfmt = function(n){ return Number(n).toLocaleString("en-US",{ minimumFractionDigits:2, maximumFractionDigits:2 }); };
        return (
          <div style={{ position:"relative", overflow:"hidden", background:"linear-gradient(165deg,#16140C 0%,#121118 60%)", border:"1px solid rgba(233,185,73,.2)", borderRadius:20, padding:"18px 16px 16px", boxShadow:"0 8px 34px rgba(0,0,0,.4)" }}>
            <div style={{ position:"absolute", top:0, left:0, right:0, height:1, background:"linear-gradient(90deg,transparent," + C.gold2 + ",transparent)" }}></div>
            <div style={{ display:"flex", alignItems:"center", justifyContent:"space-between" }}>
              <span style={{ display:"flex", alignItems:"center", gap:9 }}>
                <span style={{ width:9, height:9, animation:"osgpulse 2.2s infinite", borderRadius:"50%", background: mkt.live ? C.green : C.gold2 }}></span>
                <span className="mono" style={{ fontSize:11.5, fontWeight:600, letterSpacing:".5px", color:C.txt2 }}>OSG / WPOL · QuickSwap V2</span>
              </span>
              <span style={{ fontSize:9, fontWeight:700, letterSpacing:".5px", color: mkt.live ? C.green : C.gold1, background: mkt.live ? "rgba(70,208,138,.12)" : "rgba(233,185,73,.12)", border:"1px solid " + (mkt.live ? "rgba(70,208,138,.35)" : "rgba(233,185,73,.3)"), padding:"4px 9px", borderRadius:30 }}>{mkt.live ? "● LIVE" : "PRE-MARKET"}</span>
            </div>
            <div style={{ display:"flex", alignItems:"flex-end", gap:12, flexWrap:"wrap", marginTop:15 }}>
              <span className="mono" style={{ fontWeight:700, fontSize:32, letterSpacing:"-1px", lineHeight:1, background:"linear-gradient(135deg,#fff," + C.gold1 + " 55%," + C.gold2 + ")", WebkitBackgroundClip:"text", backgroundClip:"text", WebkitTextFillColor:"transparent" }}>{mkt.price}</span>
            </div>
            <div className="mono" style={{ fontSize:11.5, color:C.txt3, marginTop:8 }}>≈ ${((wallet&&data&&data.osgPerPol?Number(data.osgPerPol):0)*pol).toFixed(4)} per OSG · 1 POL ≈ ${pol.toFixed(4)}</div>
            <div style={{ display:"flex", marginTop:15, borderTop:"1px solid " + C.line, borderBottom:"1px solid " + C.line, padding:"11px 0" }}>
              <div style={{ flex:1 }}><div style={{ fontSize:9, letterSpacing:".4px", textTransform:"uppercase", color:C.txt3, fontWeight:600 }}>Liquidity</div><div className="mono" style={{ fontSize:13.5, color:C.txt, marginTop:4 }}>{mkt.liq}</div></div>
              <div style={{ flex:1, borderLeft:"1px solid " + C.line, paddingLeft:12 }}><div style={{ fontSize:9, letterSpacing:".4px", textTransform:"uppercase", color:C.txt3, fontWeight:600 }}>Pool</div><div className="mono" style={{ fontSize:13.5, color:C.txt, marginTop:4 }}>QuickSwap</div></div>
              <div style={{ flex:1, borderLeft:"1px solid " + C.line, paddingLeft:12 }}><div style={{ fontSize:9, letterSpacing:".4px", textTransform:"uppercase", color:C.txt3, fontWeight:600 }}>Pool Staked</div><div className="mono" style={{ fontSize:13.5, color:C.txt, marginTop:4 }}>{fmt(data.totalStaked,0)}</div></div>
            </div>
            <div style={{ marginTop:13, background:C.bg2, border:"1px solid " + C.line, borderRadius:13, padding:"11px 12px" }}>
              <div style={{ fontSize:8.5, letterSpacing:"1px", textTransform:"uppercase", color:C.txt3, fontWeight:600, marginBottom:4 }}>You spend</div>
              <div style={{ display:"flex", alignItems:"center", gap:6, background:"#000", border:"1px solid " + C.line2, borderRadius:9, padding:"8px 11px" }}>
                <span className="mono" style={{ color:C.gold2, fontSize:15, fontWeight:600 }}>$</span>
                <input className="mono" inputMode="decimal" value={calcUsd} onChange={function(e){ var v = e.target.value.replace(/[^0-9.]/g,""); setCalcUsd(v); setCalcOsg(cfmt((cnum(v)/pol)*OSG_PER_POL)); }} style={{ flex:1, width:"100%", minWidth:0, background:"none", border:"none", outline:"none", color:C.txt, fontSize:16, fontWeight:700 }}/>
              </div>
              <div style={{ textAlign:"center", color:C.txt3, fontSize:13, margin:"5px 0" }}>↓</div>
              <div style={{ fontSize:8.5, letterSpacing:"1px", textTransform:"uppercase", color:C.txt3, fontWeight:600, marginBottom:4 }}>You get (estimate)</div>
              <div style={{ display:"flex", alignItems:"center", gap:6, background:"rgba(70,208,138,.07)", border:"1px solid rgba(70,208,138,.25)", borderRadius:9, padding:"8px 11px" }}>
                <span className="mono" style={{ fontSize:13, color:C.green, fontWeight:600, opacity:.9 }}>OSG</span>
                <input className="mono" inputMode="decimal" value={calcOsg} onChange={function(e){ var v = e.target.value.replace(/[^0-9.]/g,""); setCalcOsg(v); setCalcUsd(cfmt((cnum(v)/OSG_PER_POL)*pol)); }} style={{ flex:1, width:"100%", minWidth:0, background:"none", border:"none", outline:"none", color:C.green, fontSize:16, fontWeight:700 }}/>
              </div>
              <div style={{ marginTop:8, fontSize:9.5, color:C.txt3, display:"flex", alignItems:"center", gap:6 }}>1 POL ≈ <span className="mono" style={{ color:C.txt2 }}>${pol.toFixed(4)}</span> · {mkt.live ? "live rate" : "est. rate"}</div>
            </div>
            <div style={{ display:"flex", alignItems:"center", justifyContent:"space-between", marginTop:13, paddingTop:12, borderTop:"1px solid " + C.line }}>
              <div style={{ display:"flex", alignItems:"center", gap:12 }}>
                <div style={{ display:"flex", flexDirection:"column", gap:2 }}><span style={{ fontSize:9, letterSpacing:"1px", textTransform:"uppercase", color:C.gold2, fontWeight:700 }}>OSG</span><span className="mono" style={{ fontSize:15, fontWeight:600, color:C.txt }}>{wallet ? fmt(data.balance) : "0.00"}</span></div>
                <div style={{ width:1, height:22, background:C.line2 }}></div>
                <div style={{ display:"flex", flexDirection:"column", gap:2 }}><span style={{ fontSize:9, letterSpacing:"1px", textTransform:"uppercase", color:C.gold2, fontWeight:700 }}>POL</span><span className="mono" style={{ fontSize:15, fontWeight:600, color:C.txt }}>{wallet ? fmt(data.polBalance) : "0.00"}</span></div>
              </div>
              <a href={"https://polygonscan.com/address/0xA15214B09a9b3E1c821B94fB97d6d3BcA8201Cd2"} target="_blank" rel="noreferrer" style={{ color:C.gold2, fontWeight:600, fontSize:13, textDecoration:"none" }}>View pool ↗️</a>
            </div>
          </div>
        );
      })()}

      {/* compact Reward Secured */}
      {wallet && Number(data.storageReward) > 1 && (
        <div style={{ marginTop:10, background:"rgba(70,208,138,.06)", border:"1px solid rgba(70,208,138,.25)", borderRadius:16, padding:"13px 15px" }}>
          <div style={{ display:"flex", justifyContent:"space-between", alignItems:"center", marginBottom:6 }}>
            <span style={{ fontSize:11, color:C.txt2, letterSpacing:".3px" }}>{t.rewardSafe || "Reward Secured"}</span>
            <span style={{ fontSize:9, fontWeight:700, color:C.green, background:"rgba(70,208,138,.12)", border:"1px solid rgba(70,208,138,.35)", padding:"3px 9px", borderRadius:99, letterSpacing:".4px" }}>{t.safeTag || "SAFE"}</span>
          </div>
          <div className="mono" style={{ fontSize:22, fontWeight:700, color:C.green, letterSpacing:"-.5px", lineHeight:1 }}>{fmt(data.storageReward,2)}<span style={{ fontSize:12, color:C.txt2, fontWeight:600, marginLeft:5 }}>OSG</span></div>
          <div style={{ fontSize:11, color:C.txt3, marginTop:6, lineHeight:1.4 }}>ⓘ {t.rewardSafeNote || "Safe & held on-chain. Up to 500 OSG/hr mints to your wallet — keep claiming, arrives in full."}</div>
        </div>
      )}

      {/* below: unchanged */}
      <div className="stat-grid">
        <Stat label={t.yourStaked} value={wallet?fmt(data.staked):"—"} sub={t.currentlyLocked} accent={C.blue}/>
        <Stat label={t.pendingReward} value={wallet?fmt(data.pending,4):"—"} sub={t.claimable} accent={C.green}/>
        <Stat label={t.osgBalance} value={wallet?fmt(data.balance):"—"} sub="OSG" accent={C.gold2}/>
        <Stat label={t.poolStaked} value={fmt(data.totalStaked)} sub={t.allUsers} accent={C.purple}/>
      </div>
      <div className="card" style={{ marginTop:14 }}>
        <div className="sec">{t.poolEmission}</div>
        <div className="mini-grid">
          {[[t.activeStakers,fmt(data.activeStakers,0)],[t.dailyEmission,fmt(data.dailyEmission,2)+" OSG"],[t.yourEarned,fmt(data.totalEarned,4)],[t.yourShare,fmt(data.sharePercent,4)+" %"],[t.halving,halvingVal],[t.rewardDist,fmt(data.rewardDistributed,2)]].map(([k,v])=>(
            <div className="mini" key={k}><div className="k">{k}</div><div className="vv">{v}</div></div>
          ))}
        </div>
      </div>
      <div className="card" style={{ marginTop:14 }}>
        <div className="sec">{t.verified}</div>
        {links.map(([n,a])=>(
          <a className="link-row" key={n} href={"https://polygonscan.com/address/" + a} target="_blank" rel="noreferrer">
            <span className="ln">{n}</span><span className="la">{short(a)} ↗️</span>
          </a>
        ))}
      </div>
    </div>
  );
}

function Staking({ wallet, data, refParam, actions, busy, t }) {
  const [tab, setTab] = useState("stake");
  const [amount, setAmount] = useState("");
  const [refInput, setRefInput] = useState("");
  useEffect(() => { if (refParam && isAddress(refParam)) setRefInput(refParam); }, [refParam]);
  const info = data.stakingInfo;
  const hasStake = Number(data.staked) > 0;
  return (
    <div className="page">
      <div className="page-head"><h1>{t.staking}</h1></div>
      <div className="tabs2">
        {[["stake",t.stakeBtn],["unstake",t.unstakeTab],["claim",t.claimTab]].map(([k,l])=>(
          <button key={k} className={`tab2 ${tab===k?"on":""}`} onClick={()=>setTab(k)}>{l}</button>
        ))}
      </div>

      {tab==="stake" && (
        <div className="card">
          <div className="field">
            <div className="row"><label>{t.amtStake}</label><span className="bal">{t.balance}: {fmt(data.balance)} OSG</span></div>
            <div style={{ display:"flex",alignItems:"center",gap:10 }}>
              <input className="inp" placeholder="0.0" value={amount} inputMode="decimal" onChange={e=>setAmount(e.target.value.replace(/[^0-9.]/g,""))}/>
              <button className="maxb" onClick={()=>setAmount(String(data.balance).replace(/,/g,""))}>MAX</button>
            </div>
          </div>
          {!hasStake && (
            <div style={{ marginTop:12 }}>
              <label style={{ fontSize:12,color:C.txt2 }}>{t.referrerOpt}</label>
              <input className="inp-sm" placeholder="0x… referrer address" value={refInput} onChange={e=>setRefInput(e.target.value.trim())}/>
            </div>
          )}
          <div className="note" style={{ margin:"14px 0" }}>ⓘ {t.twoStep}</div>
          <button className="btn-gold" disabled={busy.stake||!wallet} onClick={()=>actions.stake(amount, hasStake?null:refInput)}>
            {busy.stake ? <span className="spin"/> : `${hasStake?t.addToStake:t.stakeBtn} ${amount||"0"} OSG`}
          </button>
        </div>
      )}

      {tab==="unstake" && (
        <div className="card">
          <div className="label" style={{ fontSize:12,color:C.txt2 }}>{t.currentlyStaked}</div>
          <div className="big mono" style={{ fontSize:32,fontWeight:600,color:C.gold1,margin:"6px 0 16px" }}>{fmt(data.staked)} <span style={{ fontSize:14,color:C.txt3 }}>OSG</span></div>
          {!info.unstakePending ? (
            <>
              <div className="note" style={{ marginBottom:14 }}>ⓘ {t.reqUnstakeInfo}</div>
              <button className="btn-danger" disabled={busy.unstake||!hasStake} onClick={actions.requestUnstake}>{busy.unstake?<span className="spin"/>:t.requestUnstake}</button>
            </>
          ) : (
            <>
              <div className="note" style={{ marginBottom:14, color:info.canUnstakeNow?C.green:C.red, borderColor:info.canUnstakeNow?"rgba(70,208,138,.3)":"rgba(242,103,92,.3)", background:info.canUnstakeNow?"rgba(70,208,138,.08)":"rgba(242,103,92,.08)" }}>
                {info.canUnstakeNow ? "✅ "+t.cooldownDone : "⏳ "+t.cooldownWait}
              </div>
              <div style={{ display:"flex",gap:10 }}>
                <button className="btn-gold" disabled={busy.unstake||!info.canUnstakeNow} onClick={actions.unstake}>{busy.unstake?<span className="spin"/>:t.withdrawNow}</button>
                <button className="btn-ghost" disabled={busy.cancel} onClick={actions.cancelUnstake} style={{ width:"auto",padding:"14px 18px" }}>{busy.cancel?<span className="spin"/>:t.cancel}</button>
              </div>
            </>
          )}
        </div>
      )}

     {tab==="claim" && (function () {
        var chunkSize = 500;
        var totalPend = Number(data.claim.total) || Number(data.pending) || 0;
        var thisChunk = Number(data.claim.amount) || 0;
        var claimsLeft = totalPend > 0 ? Math.ceil(totalPend / chunkSize) : 0;
        var moreAfter = totalPend > chunkSize;
        return (
          <div className="card" style={{ textAlign:"center", padding:24 }}>
            <div className="sec" style={{ marginBottom:8 }}>{t.claimableReward}</div>
            <div className="mono" style={{ fontSize:40, fontWeight:600, color:C.green, lineHeight:1 }}>{fmt(thisChunk,4)}</div>
            <div style={{ fontSize:13, color:C.txt3, margin:"6px 0 12px" }}>{t.thisChunk}</div>

            <div style={{ display:"flex", gap:10, marginBottom:14 }}>
              <div style={{ flex:1, background:C.card2, border:"1px solid "+C.line, borderRadius:12, padding:"10px 8px" }}>
                <div style={{ fontSize:10, color:C.txt3, textTransform:"uppercase", letterSpacing:".4px" }}>{t.totalPending || "Total pending"}</div>
                <div className="mono" style={{ fontSize:16, fontWeight:600, color:C.gold1, marginTop:4 }}>{fmt(totalPend,2)}</div>
              </div>
              <div style={{ flex:1, background:C.card2, border:"1px solid "+C.line, borderRadius:12, padding:"10px 8px" }}>
                <div style={{ fontSize:10, color:C.txt3, textTransform:"uppercase", letterSpacing:".4px" }}>{t.claimsLeft || "Claims left"}</div>
                <div className="mono" style={{ fontSize:16, fontWeight:600, color:C.blue, marginTop:4 }}>{claimsLeft > 0 ? ("~" + claimsLeft) : "0"}</div>
              </div>
            </div>

            {moreAfter && (
              <div className="note" style={{ marginBottom:14, justifyContent:"flex-start", textAlign:"left" }}>
                ⓘ {t.claimCapNote || "Up to 500 OSG mints per claim (hourly limit). Claim once, then come back in about 1 hour for the next 500. Your reward stays safe on-chain until fully claimed."}
              </div>
            )}

            {!data.claim.canClaim && data.claim.reason && (
              <div className="note" style={{ marginBottom:14, color:C.red, justifyContent:"center" }}>ⓘ {data.claim.reason}</div>
            )}

            <button className="btn-gold" disabled={busy.claim || !data.claim.canClaim} onClick={actions.claim}>
              {busy.claim ? <span className="spin"/> : ((t.claimReward || "Claim Reward") + (thisChunk > 0 ? (" " + fmt(thisChunk,2) + " OSG") : ""))}
            </button>
          </div>
        );
      })()}
</div>
  );    
}

function Referral({ wallet, data, showToast, t }) {
  const origin = typeof window!=="undefined" ? window.location.origin : "";
  const refLink = wallet ? `${origin}/?ref=${wallet}` : "—";
  const [copied, setCopied] = useState(false);
  const copy = async () => {
    if (!wallet) { showToast("⚠️ "+t.tConnFirst); return; }
    try { await navigator.clipboard.writeText(refLink); } catch {}
    setCopied(true); showToast("🔗 "+t.tCopied); setTimeout(()=>setCopied(false),1800);
  };
  const r = data.referralInfo, chain = data.referralChain;
  const labels = ["L1","L2","L3","L4","L5"], colors = [C.gold1,"#C0C0C0","#CD7F32",C.green,C.blue];
  return (
    <div className="page stag">
      <div className="page-head"><h1>{t.referral}</h1></div>
      <div className="stat-grid">
        <Stat label={t.refEarned} value={fmt(r.totalReferralEarned,4)} sub={t.osgTotal} accent={C.gold2}/>
        <Stat label={t.totalRefs} value={fmt(r.totalReferrals,0)} sub={t.directTeam} accent={C.green}/>
        <Stat label={t.pendingRef} value={fmt(r.pendingReferral,4)} sub="OSG" accent={C.blue}/>
        <Stat label={t.teamBonus} value={fmt(r.teamBonusEarned,4)} sub="OSG" accent={C.purple}/>
      </div>
      <div className="card" style={{ marginTop:14 }}>
        <div className="sec">{t.yourRefLink}</div>
        <div className="ref-link">
          <div className="code">{refLink}</div>
          <button className="copy-btn" onClick={copy}>{copied?"✓":"🔗"} {t.copy}</button>
        </div>
        <div style={{ fontSize:11,color:C.txt3,marginTop:8,lineHeight:1.5 }}>{t.shareLink}</div>
      </div>
      <div className="card" style={{ marginTop:14 }}>
        <div className="sec">{t.upline}</div>
        {chain.map((addr,i)=>(
          <div className="lvl" key={i}>
            <div className="n" style={{ color:colors[i],borderColor:colors[i]+"55",background:colors[i]+"18" }}>{labels[i]}</div>
            <span className="ad" style={{ color: addr&&addr!==ZERO?C.txt:C.txt3 }}>{addr&&addr!==ZERO?short(addr):t.empty}</span>
          </div>
        ))}
      </div>
      <div className="card" style={{ marginTop:14 }}>
        <div className="sec">{t.yourReferrer}</div>
        <div className="mono" style={{ fontSize:13,color: r.referrer&&r.referrer!==ZERO?C.gold1:C.txt3 }}>{r.referrer&&r.referrer!==ZERO?short(r.referrer):t.noReferrer}</div>
      </div>
      <div className="card" style={{ marginTop:14 }}>
        <div className="sec">{t.yourReferralsTitle || "Your Referrals"}{(data.directReferrals||[]).filter(function(a){return a&&a!==ZERO;}).length ? " · " + (data.directReferrals||[]).filter(function(a){return a&&a!==ZERO;}).length : ""}</div>
        {(data.directReferrals||[]).filter(function(a){return a&&a!==ZERO;}).length === 0 ? (
          <div style={{ fontSize:12, color:C.txt3, padding:"6px 0", lineHeight:1.5 }}>
            {t.noReferralsYet || "No one has joined with your link yet. Share it to grow your team!"}
          </div>
        ) : (
          (data.directReferrals||[]).filter(function(a){return a&&a!==ZERO;}).map(function(addr,i){
            return (
              <div className="lvl" key={addr + i}>
                <div className="n" style={{ color:C.green, borderColor:C.green+"55", background:C.green+"18" }}>{i + 1}</div>
                <a className="ad" href={"https://polygonscan.com/address/" + addr} target="_blank" rel="noreferrer" style={{ color:C.gold1, textDecoration:"none" }}>{short(addr)} ↗️</a>
              </div>
            );
          })
        )}
      </div>
    </div>
  );
}

function Swap({ t }) {
  var POOL = "0xA15214B09a9b3E1c821B94fB97d6d3BcA8201Cd2";
  var chartSrc = "https://www.geckoterminal.com/polygon_pos/pools/" + POOL + "?embed=1&info=0&swaps=1&chart_type=price&resolution=15m";
  return (
    <div className="page">
      <div className="page-head"><h1>{t.swap}</h1></div>

      <div style={{ background:"linear-gradient(160deg,#1C1A16,#121118)", border:"1px solid rgba(233,185,73,.2)", borderRadius:16, padding:"13px 15px", marginBottom:10 }}>
        <div style={{ display:"flex", justifyContent:"space-between", alignItems:"center" }}>
          <div style={{ display:"flex", alignItems:"center", gap:9 }}>
            <span style={{ width:8, height:8, animation:"osgpulse 2s infinite", borderRadius:"50%", background:C.green, boxShadow:"0 0 0 3px rgba(70,208,138,.18), 0 0 10px " + C.green }}></span>
            <div>
              <div className="mono" style={{ fontSize:14, fontWeight:700, color:"#fff", lineHeight:1 }}>OSG / WPOL</div>
              <div style={{ fontSize:10, color:C.txt3, marginTop:3, letterSpacing:".3px" }}>Polygon · QuickSwap V2</div>
            </div>
          </div>
          <span style={{ fontSize:9, fontWeight:700, color:C.green, background:"rgba(70,208,138,.12)", border:"1px solid rgba(70,208,138,.35)", padding:"4px 10px", borderRadius:99, letterSpacing:".4px" }}>● LIVE</span>
        </div>
      </div>

      <div style={{ position:"relative", overflow:"hidden", borderRadius:16, border:"1px solid rgba(233,185,73,.18)", background:"#0d0c12", marginBottom:10 }}>
        <iframe title="OSG live chart" src={chartSrc} style={{ width:"100%", height:420, border:"none", display:"block" }} allow="clipboard-write" allowFullScreen></iframe>
      </div>

      <div style={{ display:"flex", gap:8, marginBottom:10, flexWrap:"wrap" }}>
        <a href={"https://dexscreener.com/polygon/" + POOL} target="_blank" rel="noreferrer" style={{ flex:1, textAlign:"center", fontSize:11, fontWeight:600, color:C.txt2, background:"rgba(255,255,255,.04)", border:"1px solid rgba(255,255,255,.08)", borderRadius:10, padding:"9px 6px", textDecoration:"none", whiteSpace:"nowrap" }}>DexScreener ↗️</a>
        <a href={"https://www.geckoterminal.com/polygon_pos/pools/" + POOL} target="_blank" rel="noreferrer" style={{ flex:1, textAlign:"center", fontSize:11, fontWeight:600, color:C.txt2, background:"rgba(255,255,255,.04)", border:"1px solid rgba(255,255,255,.08)", borderRadius:10, padding:"9px 6px", textDecoration:"none", whiteSpace:"nowrap" }}>GeckoTerminal ↗️</a>
        <a href={"https://polygonscan.com/address/" + POOL} target="_blank" rel="noreferrer" style={{ flex:1, textAlign:"center", fontSize:11, fontWeight:600, color:C.txt2, background:"rgba(255,255,255,.04)", border:"1px solid rgba(255,255,255,.08)", borderRadius:10, padding:"9px 6px", textDecoration:"none", whiteSpace:"nowrap" }}>Pool ↗️</a>
      </div>

      <div className="card" style={{ textAlign:"center", padding:"20px 18px" }}>
        <div className="disp" style={{ fontSize:17, fontWeight:700, color:C.gold1, marginBottom:6 }}>{t.swapTitle}</div>
        <div style={{ fontSize:12.5, color:C.txt2, marginBottom:16, lineHeight:1.5 }}>{t.swapDesc}</div>
        <a href={QUICKSWAP_URL} target="_blank" rel="noreferrer"><button className="btn-gold">{t.openQuickswap} ↗️</button></a>
        <div className="mono" style={{ fontSize:11, color:C.txt3, marginTop:12 }}>OSG: {short(ADDRESSES.token)}</div>
      </div>
    </div>
  );
}

// IPFS helpers (talk to our own /api routes; no secrets here)
async function uploadToIpfs(content) {
  const r = await fetch("/api/pinata-upload", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ content: content }),
  });
  if (!r.ok) throw new Error("IPFS upload failed");
  const data = await r.json();
  if (!data.cid) throw new Error("No CID returned");
  return data.cid;
}
async function fetchFromIpfs(cid) {
  const r = await fetch("/api/ipfs-fetch?cid=" + encodeURIComponent(cid));
  if (!r.ok) throw new Error("IPFS fetch failed");
  const data = await r.json();
  return data.osg;
}
// ===== Media helpers (photo / file in chat) =====

// Read a File as a base64 data URL (small non-image files).
function fileToDataUrl(file) {
  return new Promise(function (resolve, reject) {
    var fr = new FileReader();
    fr.onload = function () { resolve(fr.result); };
    fr.onerror = function () { reject(new Error("read failed")); };
    fr.readAsDataURL(file);
  });
}

// Compress an image File via canvas -> base64 data URL (keeps payload small).
function compressImage(file, maxDim, quality) {
  if (maxDim === undefined) maxDim = 1024;
  if (quality === undefined) quality = 0.7;
  return new Promise(function (resolve, reject) {
    var url = URL.createObjectURL(file);
    var img = new Image();
    img.onload = function () {
      var w = img.width, h = img.height;
      if (w > h && w > maxDim) { h = Math.round(h * maxDim / w); w = maxDim; }
      else if (h >= w && h > maxDim) { w = Math.round(w * maxDim / h); h = maxDim; }
      var canvas = document.createElement("canvas");
      canvas.width = w; canvas.height = h;
      var ctx = canvas.getContext("2d");
      ctx.drawImage(img, 0, 0, w, h);
      URL.revokeObjectURL(url);
      try { resolve(canvas.toDataURL("image/jpeg", quality)); }
      catch (e) { reject(e); }
    };
    img.onerror = function () { URL.revokeObjectURL(url); reject(new Error("image load failed")); };
    img.src = url;
  });
}

// Turn a selected File into an encrypt-ready payload.
// Returns { kind:"image"|"file", dataUrl, name }.
async function fileToPayload(file) {
  var isImg = file.type && file.type.indexOf("image/") === 0;
  var dataUrl;
  if (isImg) {
    dataUrl = await compressImage(file, 1600, 0.85);
    if (dataUrl.length > 400000) dataUrl = await compressImage(file, 1280, 0.8);
    if (dataUrl.length > 400000) dataUrl = await compressImage(file, 1024, 0.7);
    if (dataUrl.length > 400000) dataUrl = await compressImage(file, 800, 0.6);
  } else {
    dataUrl = await fileToDataUrl(file);
  }
  return { kind: isImg ? "image" : "file", dataUrl: dataUrl, name: file.name || (isImg ? "photo.jpg" : "file") };
}

// Generous message cap (IPFS removes the old ~65-char on-chain limit).
const MAX_MSG = 1000;

function Messenger({ wallet, network, getProvider, ensureReady, showToast, t }) {
  // ── Chat themes (Messages page only) ──
  const CHAT_THEMES = {
    midnight: { bg:"linear-gradient(180deg,#0a0a0d,#080809)", head:"linear-gradient(180deg,rgba(240,165,0,.08),rgba(10,10,13,0))", headTxt:"#ffffff", headSub:"#8b93a2", inBg:"#1b1c23", inTxt:"#e9edf3", inEdge:"rgba(255,255,255,.06)", outBg:"linear-gradient(180deg,#332a14,#2b2412)", outTxt:"#f5ecd6", outEdge:"#5a4715", meta:"#8b93a2", outMeta:"#b79a5c", tick:"#f0a500", accent:"#f0a500", barBg:"#15141b", barEdge:"rgba(255,255,255,.07)", inputTxt:"#e9edf3", ph:"#5d6470", sendBg:"linear-gradient(135deg,#ffd66b,#b8841c)", sendTxt:"#1a1205", dayBg:"rgba(255,255,255,.05)", dayTxt:"#8b93a2" },
    sky: { bg:"linear-gradient(180deg,#eaf6ff,#cfe8ff)", head:"linear-gradient(135deg,#1f8fff,#0f6fe0)", headTxt:"#ffffff", headSub:"rgba(255,255,255,.85)", inBg:"#ffffff", inTxt:"#0b2440", inEdge:"transparent", outBg:"linear-gradient(180deg,#dcf0ff,#cfe8ff)", outTxt:"#0b2440", outEdge:"#bfe2ff", meta:"#5b7693", outMeta:"#5b7693", tick:"#34b7f1", accent:"#1f8fff", barBg:"#ffffff", barEdge:"#d8e8f5", inputTxt:"#0b2440", ph:"#9bb3c9", sendBg:"linear-gradient(135deg,#34a0ff,#0f6fe0)", sendTxt:"#ffffff", dayBg:"rgba(255,255,255,.75)", dayTxt:"#5b7693" },
    pearl: { bg:"linear-gradient(180deg,#fdfaf2,#f4ecd8)", head:"linear-gradient(135deg,#ffd97a,#e7ab28)", headTxt:"#2a1d00", headSub:"rgba(42,29,0,.62)", inBg:"#ffffff", inTxt:"#2a2417", inEdge:"#efe6cf", outBg:"linear-gradient(180deg,#ffe9ad,#f6d278)", outTxt:"#3a2a05", outEdge:"#e8c662", meta:"#9a8a64", outMeta:"#8a6c22", tick:"#c8911c", accent:"#e0a21f", barBg:"#ffffff", barEdge:"#efe6cf", inputTxt:"#2a2417", ph:"#b3a884", sendBg:"linear-gradient(135deg,#ffd66b,#e0a21f)", sendTxt:"#1a1205", dayBg:"rgba(255,255,255,.8)", dayTxt:"#9a8a64" },
    ocean: { bg:"linear-gradient(180deg,#effaf6,#d6f2e8)", head:"linear-gradient(135deg,#15c191,#0c9b73)", headTxt:"#ffffff", headSub:"rgba(255,255,255,.85)", inBg:"#ffffff", inTxt:"#08332a", inEdge:"transparent", outBg:"linear-gradient(180deg,#cdf3e6,#bcecdb)", outTxt:"#08332a", outEdge:"#a9e6d2", meta:"#5a8d80", outMeta:"#5a8d80", tick:"#12b886", accent:"#12b886", barBg:"#ffffff", barEdge:"#cdeee2", inputTxt:"#08332a", ph:"#8fb8ad", sendBg:"linear-gradient(135deg,#19cf9b,#0c9b73)", sendTxt:"#ffffff", dayBg:"rgba(255,255,255,.78)", dayTxt:"#5a8d80" }
  };
  const [chatTheme, setChatTheme] = useState("midnight");
  const [themeOpen, setThemeOpen] = useState(false);
  const [viewer, setViewer] = useState(null);
  const TH = CHAT_THEMES[chatTheme] || CHAT_THEMES.midnight;
  const [to, setTo] = useState("");
  const [text, setText] = useState("");
  const [msgs, setMsgs] = useState([]);
  const [sent, setSent] = useState([]);
  const [loading, setLoading] = useState(false);
  const [sending, setSending] = useState(false);
  const [keypair, setKeypair] = useState(null);
  const [setupBusy, setSetupBusy] = useState(false);
  const [attach, setAttach] = useState(null);
  const fileRef = useRef(null);
  const pubCache = useRef({});
  const endRef = useRef(null);

  const getPub = useCallback(async (addr) => {
    if (!addr) return null;
    const k = addr.toLowerCase();
    if (k in pubCache.current) return pubCache.current[k];
    try {
      const p = getProvider();
      const c = new Contract(ADDRESSES.messenger, MESSENGER_ABI, p);
      const pk = await c.publicKeys(addr);
      pubCache.current[k] = pk && pk.length > 3 ? pk : null;
    } catch { pubCache.current[k] = null; }
    return pubCache.current[k];
  }, [getProvider]);

  const ensureKeypair = useCallback(async (signer) => {
    if (keypair) return keypair;
    setSetupBusy(true);
    try {
      showToast("🔑 " + (t.tKeySign || "Sign to enable secure messaging…"));
      const kp = await deriveKeypair(signer);
      const p = getProvider();
      let onchain = "";
      try { onchain = await new Contract(ADDRESSES.messenger, MESSENGER_ABI, p).publicKeys(wallet); } catch {}
      if (!onchain || onchain.toLowerCase() !== kp.pubHex.toLowerCase()) {
        showToast("🔑 " + (t.tKeyReg || "Registering your key on-chain…"));
        const cw = new Contract(ADDRESSES.messenger, MESSENGER_ABI, signer);
        const tx = await cw.setPublicKey(kp.pubHex);
        await tx.wait();
      }
      pubCache.current[wallet.toLowerCase()] = kp.pubHex;
      setKeypair(kp);
      showToast("✅ " + (t.tKeyOk || "Secure messaging enabled"));
      return kp;
    } catch (e) {
      console.error(e);
      showToast("❌ " + (e?.shortMessage || e?.reason || (t.tKeyFail || "Key setup failed")));
      return null;
    } finally { setSetupBusy(false); }
  }, [keypair, wallet, getProvider, showToast, t]);

  const load = useCallback(async () => {
    if (!wallet) return;
    setLoading(true);
    try {
      const p = getProvider(); if (!p) return;
      const c = new Contract(ADDRESSES.messenger, MESSENGER_ABI, p);
      const len = Number(await c.getInboxLength(wallet));
      let list = [];
      if (len > 0) {
        const start = len > 50 ? len - 50 : 0;
        const raw = await c.getMessages.staticCall(start, 50, { from: wallet });
        const active = raw
          .map((mm, k) => ({ mm: mm, idx: start + k }))
         .filter(o => !o.mm.isDeleted && (o.mm.fileType === "text" || o.mm.fileType === "image" || o.mm.fileType === "file"));
        list = await Promise.all(active.map(async (o) => {
          const mm = o.mm;
          let body = mm.cid, locked = false, enc = false;
          const isInline = mm.cid && mm.cid.startsWith("e1:");
          const isIpfs   = mm.cid && mm.cid.startsWith("e2:");
          if (isInline || isIpfs) {
            enc = true;
            if (!keypair) {
              body = "🔒 " + (t.lockedMsg || "Secure message — tap Unlock");
              locked = true;
            } else {
              try {
                const senderPub = await getPub(mm.from);
                let payload = mm.cid;
                if (isIpfs) payload = await fetchFromIpfs(mm.cid.slice(3));
                var dec = decryptMessage(payload, keypair.priv, senderPub).text;
                if (mm.fileType === "image" || mm.fileType === "file") {
                  try {
                    var parsed = JSON.parse(dec);
                    body = parsed.t || "";
                    var media = { kind: mm.fileType, dataUrl: parsed.d, name: parsed.n };
                    return { from: mm.from, text: body, media: media, ts: Number(mm.timestamp), locked: locked, enc: enc, mine: false, idx: o.idx };
                  } catch (e2) { body = dec; }
                } else {
                  body = dec;
                }
              } catch (e) {
                console.error("decrypt/load:", e);
                body = "🔒 " + (t.decFail || "unable to load message");
              }
            }
          }
          return { from: mm.from, text: body, ts: Number(mm.timestamp), locked: locked, enc: enc, mine: false, idx: o.idx };
        }));
      }
      setMsgs(list);
    } catch (e) { console.error("msg load:", e); }
    finally { setLoading(false); }
  }, [wallet, getProvider, keypair, getPub, t]);

  useEffect(() => { load(); }, [load]);
  useEffect(() => { if (!wallet) return; const tm = setInterval(load, 15000); return () => clearInterval(tm); }, [wallet, load]);
  useEffect(() => { setSent([]); }, [wallet]);

  const thread = [...msgs, ...sent].sort((a, b) => a.ts - b.ts);
  useEffect(() => { endRef.current?.scrollIntoView({ behavior: "smooth" }); }, [msgs, sent]);

  const pickFile = () => { if (fileRef.current) fileRef.current.click(); };

  const onFilePicked = async (e) => {
    const f = e.target.files && e.target.files[0];
    e.target.value = "";
    if (!f) return;
    try {
      const payload = await fileToPayload(f);
      if (payload.dataUrl.length > 400000) {
        showToast("⚠️ " + (t.tFileTooBig || "File too large — try a smaller one"));
        return;
      }
      setAttach(payload);
    } catch (err) {
      console.error(err);
      showToast("❌ " + (t.tFileFail || "Could not read file"));
    }
  };

  const clearAttach = () => setAttach(null);
  const unlock = async () => {
    const signer = await ensureReady(); if (!signer) return;
    await ensureKeypair(signer);
  };

  const send = async () => {
    if (!isAddress(to)) { showToast("⚠️ " + t.tBadAddr); return; }
    const body = text.trim();
    if (!body && !attach) { showToast("⚠️ " + t.tEmptyMsg); return; }
    if (body.length > MAX_MSG) { showToast("⚠️ " + (t.tTooLong || ("Too long — max " + MAX_MSG + " chars"))); return; }
    const signer = await ensureReady(); if (!signer) return;
    setSending(true);
    const localId = "s" + Date.now();
    try {
      const kp = await ensureKeypair(signer);
      if (!kp) return;
      const theirPub = await getPub(to);
      if (!theirPub) {
        showToast("⚠️ " + (t.tNoRecipientKey || "Recipient hasn't enabled secure messaging yet"));
        return;
      }
      var msgType = "text";
        var payloadStr = body;
        if (attach) {
          msgType = attach.kind;
          payloadStr = JSON.stringify({ t: body, d: attach.dataUrl, n: attach.name });
        }
        const blob = encryptMessage(payloadStr, kp.priv, theirPub);
        showToast("📤 " + (t.tUploading || "Encrypting & uploading…"));
        const cid = await uploadToIpfs(blob);
        const ref = "e2:" + cid;
      setSent(prev => [...prev, { id: localId, from: wallet, to: to, text: body, ts: Math.floor(Date.now() / 1000), locked: false, enc: true, mine: true, status: "sending" }]);
     setAttach(null);
      const c = new Contract(ADDRESSES.messenger, MESSENGER_ABI, signer);

        // ── OSG fee handling (exact approve per message) ──
        let nativeFee = 0n;
        try {
          var useOsg = await c.useOSGFee();
          if (useOsg) {
            var osgFee = await c.messagingFeeOSG();
            if (osgFee > 0n) {
              var tokenC = new Contract(ADDRESSES.token, TOKEN_ABI, signer);
              var allow = await tokenC.allowance(wallet, ADDRESSES.messenger);
              if (allow < osgFee) {
                showToast("1/2 — " + (t.tApproveOsg || "Approving 0.1 OSG fee..."));
                var txA = await tokenC.approve(ADDRESSES.messenger, osgFee);
                await txA.wait();
              }
            }
            nativeFee = 0n;
          } else {
            try { nativeFee = await c.getUserFee(wallet); } catch {}
          }
        } catch (e) {
          try { nativeFee = await c.getUserFee(wallet); } catch {}
        }

        showToast("2/2 — " + (t.tSendingMsg || "Sending message..."));
        const tx = await c.sendMessage(to, ref, msgType, { value: nativeFee });
      await tx.wait();
      showToast("✅ " + t.tSent);
      setSent(prev => prev.map(m => m.id === localId ? { ...m, status: "delivered" } : m));
      await load();
    } catch (e) {
      console.error(e);
      showToast("❌ " + (e?.shortMessage || e?.reason || t.tFailed));
      setSent(prev => prev.map(m => m.id === localId ? { ...m, status: "failed" } : m));
    } finally { setSending(false); }
  };

  const removeMsg = async (idx) => {
    if (idx === undefined || idx === null) return;
    if (!window.confirm(t.delConfirm || "Delete this message? (only hides it for you)")) return;
    const signer = await ensureReady(); if (!signer) return;
    try {
      const c = new Contract(ADDRESSES.messenger, MESSENGER_ABI, signer);
      const tx = await c.deleteMessage(idx);
      await tx.wait();
      showToast("🗑️ " + (t.delOk || "Message deleted"));
      await load();
    } catch (e) {
      console.error(e);
      showToast("❌ " + (e?.shortMessage || e?.reason || (t.delFail || "Delete failed")));
    }
  };

  const over = text.length > MAX_MSG;
// download a base64 dataURL to the device (works on mobile)
  const downloadData = (dataUrl, name) => {
    try {
      const a = document.createElement("a");
      a.href = dataUrl;
      a.download = name || "osg-image.jpg";
      document.body.appendChild(a);
      a.click();
      document.body.removeChild(a);
      showToast("⬇️ " + (t.tSaved || "Saved"));
    } catch (e) { showToast("❌ " + (t.tSaveFail || "Save failed")); }
  };

  // long-press to copy a message's text
  const pressRef = useRef(null);
  const startPress = (txt) => {
    clearTimeout(pressRef.current);
    pressRef.current = setTimeout(() => {
      if (!txt) return;
      try {
        if (navigator.clipboard && navigator.clipboard.writeText) navigator.clipboard.writeText(txt);
        showToast("📋 " + (t.tCopiedMsg || "Copied"));
      } catch (e) {}
    }, 420);
  };
  const endPress = () => clearTimeout(pressRef.current);
  return (
    <div className="page">
      <div className="page-head"><h1>{t.chatTitle}</h1><p>{t.chatSub}</p></div>
      {/* 🎨 theme picker */}
      <div style={{ display:"flex", justifyContent:"flex-end", marginTop:-6, marginBottom:6, position:"relative" }}>
        <button onClick={()=>setThemeOpen(o=>!o)} title="Chat theme"
          style={{ background:"transparent", border:"1px solid "+C.line, color:C.gold1, width:40, height:40, borderRadius:12, fontSize:18, cursor:"pointer" }}>🎨</button>
        {themeOpen && (
          <div style={{ position:"absolute", top:46, right:0, zIndex:30, background:C.card2, border:"1px solid "+C.line, borderRadius:12, padding:6, display:"flex", flexDirection:"column", gap:4, minWidth:150, boxShadow:"0 10px 30px rgba(0,0,0,.5)" }}>
            {[["midnight","Midnight","#f0a500"],["sky","Sky","#1f8fff"],["pearl","Pearl Gold","#e0a21f"],["ocean","Ocean","#12b886"]].map(function(o){
              return (
                <button key={o[0]} onClick={()=>{ setChatTheme(o[0]); setThemeOpen(false); }}
                  style={{ display:"flex", alignItems:"center", gap:9, background: chatTheme===o[0] ? C.card : "transparent", border:"1px solid "+(chatTheme===o[0]?C.gold3:"transparent"), color:C.txt, padding:"9px 11px", borderRadius:9, cursor:"pointer", fontSize:13, textAlign:"left" }}>
                  <span style={{ width:12, height:12, borderRadius:"50%", background:o[2], display:"inline-block" }}/>{o[1]}
                </button>
              );
            })}
          </div>
        )}
      </div>

      {/* full-screen image viewer */}
      {viewer && (
        <div onClick={()=>setViewer(null)}
          style={{ position:"fixed", inset:0, zIndex:100, background:"rgba(0,0,0,.92)", display:"flex", flexDirection:"column", alignItems:"center", justifyContent:"center", padding:16 }}>
          <div style={{ position:"absolute", top:14, right:14, display:"flex", gap:10 }}>
            <button onClick={(e)=>{ e.stopPropagation(); downloadData(viewer.dataUrl, viewer.name); }}
              style={{ background:C.gold2, color:"#1a1205", border:0, borderRadius:10, padding:"10px 14px", fontWeight:700, cursor:"pointer", fontSize:14 }}>⬇️ Download</button>
            <button onClick={()=>setViewer(null)}
              style={{ background:"rgba(255,255,255,.15)", color:"#fff", border:0, borderRadius:10, padding:"10px 14px", fontWeight:700, cursor:"pointer", fontSize:14 }}>✕</button>
          </div>
          <img src={viewer.dataUrl} alt={viewer.name||"image"} onClick={(e)=>e.stopPropagation()}
            style={{ maxWidth:"100%", maxHeight:"82vh", borderRadius:12, objectFit:"contain" }}/>
        </div>
      )}

      {wallet && !keypair && (
        <div className="card" style={{ marginBottom:12, display:"flex", gap:12, alignItems:"center", flexWrap:"wrap" }}>
          <div style={{ flex:1, minWidth:170, fontSize:12, color:C.txt2, lineHeight:1.5 }}>
            🔒 {t.e2eInfo || "Messages are end-to-end encrypted. Enable once (free signature) to read & send."}
          </div>
          <button className="btn-ghost" style={{ width:"auto", padding:"12px 16px" }} disabled={setupBusy} onClick={unlock}>
            {setupBusy ? <span className="spin"/> : (t.enableSecure || "Enable")}
          </button>
        </div>
      )}

      <div className="card" style={{ padding:14 }}>
        <label style={{ fontSize:11,color:C.txt3,textTransform:"uppercase",letterSpacing:".4px" }}>{t.recipient}</label>
        <input className="inp-sm" placeholder="0x…" value={to} onChange={e=>setTo(e.target.value.trim())}/>
      </div>

      <div className="card" style={{ marginTop:12, minHeight:380, display:"flex", flexDirection:"column" }}>
        <div className="sec" style={{ marginBottom:10 }}>{t.inbox}{thread.length ? " · " + thread.length : ""}</div>
        <div style={{ flex:1, display:"flex", flexDirection:"column", gap:8, maxHeight:440, overflowY:"auto", background:TH.bg, borderRadius:12, padding:"12px 8px" }}>
          {!wallet ? (
            <div style={{ textAlign:"center",color:TH.meta,fontSize:13,marginTop:30 }}>👆 {t.connectSee}</div>
          ) : loading && thread.length===0 ? (
            <div style={{ textAlign:"center",color:TH.meta,fontSize:13,marginTop:30 }}>{t.loadingMsgs}</div>
          ) : thread.length===0 ? (
            <div style={{ textAlign:"center",color:TH.meta,fontSize:13,marginTop:30 }}>💬 {t.noMsgs}</div>
          ) : thread.map((mm,i)=>(
            <div key={mm.id ? mm.id : ("r" + i + "-" + mm.ts)}
              onClick={mm.locked?unlock:undefined}
              onMouseDown={()=>startPress(mm.text)} onMouseUp={endPress} onMouseLeave={endPress}
              onTouchStart={()=>startPress(mm.text)} onTouchEnd={endPress} onTouchMove={endPress}
              style={{
                alignSelf: mm.mine ? "flex-end" : "flex-start",
                maxWidth:"82%",
                background: mm.mine ? TH.outBg : TH.inBg,
                border:"1px solid " + (mm.mine ? TH.outEdge : TH.inEdge),
                borderRadius: mm.mine ? "16px 6px 16px 16px" : "6px 16px 16px 16px",
                padding:"8px 11px",
                boxShadow:"0 1px 1.5px rgba(0,0,0,.14)",
                cursor: mm.locked?"pointer":"default",
                WebkitUserSelect:"none", userSelect:"none"
              }}>
              <div className="mono" style={{ fontSize:10, color: mm.mine ? TH.outMeta : TH.meta, marginBottom:4, display:"flex", justifyContent:"space-between", alignItems:"center", gap:8 }}>
                <span>{mm.mine ? (t.youLabel || "You") : short(mm.from)} {mm.enc && !mm.locked ? "🔒" : ""}</span>
                {!mm.mine && mm.idx !== undefined && (
                  <span onClick={(e)=>{ e.stopPropagation(); removeMsg(mm.idx); }}
                    style={{ cursor:"pointer", opacity:.6, fontSize:12 }} title={t.delete || "Delete"}>🗑️</span>
                )}
              </div>
              {mm.media && mm.media.kind === "image" && (
                <img src={mm.media.dataUrl} alt={mm.media.name||"image"}
                  onClick={(e)=>{ e.stopPropagation(); setViewer({ dataUrl: mm.media.dataUrl, name: mm.media.name }); }}
                  style={{ maxWidth:"100%", maxHeight:260, borderRadius:12, marginBottom: mm.text?6:0, cursor:"pointer", display:"block" }}/>
              )}
              {mm.media && mm.media.kind === "file" && (
                <a href={mm.media.dataUrl} download={mm.media.name||"file"}
                  style={{ display:"flex", alignItems:"center", gap:8, marginBottom: mm.text?6:0, color: mm.mine?TH.outTxt:TH.accent, textDecoration:"none", fontSize:13 }}>
                  📄 <span style={{ textDecoration:"underline", wordBreak:"break-all" }}>{mm.media.name||"file"}</span>
                </a>
              )}
              {mm.text && <div style={{ fontSize:15, color: mm.mine ? TH.outTxt : TH.inTxt, wordBreak:"break-word", lineHeight:1.4 }}>{mm.text}</div>}
              <div style={{ fontSize:10, color: mm.mine ? TH.outMeta : TH.meta, marginTop:4, textAlign:"right", display:"flex", gap:5, justifyContent:"flex-end", alignItems:"center" }}>
                <span>{new Date(mm.ts*1000).toLocaleString()}</span>
                {mm.mine && mm.status === "sending"   && <span style={{ color:TH.outMeta }}>✓</span>}
                {mm.mine && mm.status === "delivered" && <span style={{ color:TH.tick, fontWeight:700 }}>✓✓</span>}
                {mm.mine && mm.status === "failed"    && <span style={{ color:"#e5484d", fontWeight:700 }}>✕</span>}
              </div>
            </div>
          ))}
          <div ref={endRef}/>
        </div>
      </div>

      <div className="card" style={{ marginTop:12, padding:12, background:TH.barBg, border:"1px solid "+TH.barEdge }}>

        {attach && (
          <div style={{ display:"flex", alignItems:"center", gap:10, marginBottom:10, padding:8, background:TH.inBg, border:"1px solid "+TH.barEdge, borderRadius:10 }}>
            {attach.kind === "image"
              ? <img src={attach.dataUrl} alt="preview" style={{ width:44, height:44, objectFit:"cover", borderRadius:8 }}/>
              : <span style={{ fontSize:22 }}>📄</span>}
            <div style={{ flex:1, minWidth:0, fontSize:12, color:TH.inTxt, overflow:"hidden", textOverflow:"ellipsis", whiteSpace:"nowrap" }}>{attach.name}</div>
            <span onClick={clearAttach} title={t.remove || "Remove"} style={{ cursor:"pointer", color:TH.meta, fontSize:18, padding:"0 4px" }}>✕</span>
          </div>
        )}

        <div style={{ display:"flex", gap:8, alignItems:"flex-end" }}>

          <input ref={fileRef} type="file" accept="image/*,application/pdf,.txt,.doc,.docx,.zip" style={{ display:"none" }} onChange={onFilePicked}/>

          <div style={{ flex:1, display:"flex", alignItems:"flex-end", gap:6, background:TH.inBg, border:"1px solid "+TH.barEdge, borderRadius:22, padding:"6px 8px 6px 12px" }}>

            <button onClick={pickFile} title={t.attach || "Attach"} style={{ background:"transparent", border:"none", cursor:"pointer", fontSize:20, lineHeight:1, padding:0, color:TH.meta, flexShrink:0 }}>📎</button>

            <textarea
              placeholder={t.typeMsg}
              value={text}
              onChange={e=>setText(e.target.value)}
              onKeyDown={e=>{ if(e.key==="Enter" && !e.shiftKey){ e.preventDefault(); send(); } }}
              rows={1}
              style={{ flex:1, resize:"none", border:"none", outline:"none", background:"transparent", color:TH.inputTxt, fontSize:15, lineHeight:1.4, maxHeight:120, overflowY:"auto", fontFamily:"inherit", padding:"4px 0" }}
            />

          </div>

          <button onClick={send} disabled={sending || over} title={t.send}
            style={{ width:46, height:46, flexShrink:0, borderRadius:"50%", border:"none", cursor:(sending||over)?"default":"pointer", background:TH.sendBg, color:TH.sendTxt, display:"flex", alignItems:"center", justifyContent:"center", opacity: over?0.5:1 }}>
            {sending
              ? <span className="spin"/>
              : (text.trim().length>0 || attach)
                ? <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"><line x1="22" y1="2" x2="11" y2="13"/><polygon points="22 2 15 22 11 13 2 9 22 2"/></svg>
                : <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"><path d="M12 1a3 3 0 0 0-3 3v8a3 3 0 0 0 6 0V4a3 3 0 0 0-3-3z"/><path d="M19 10v2a7 7 0 0 1-14 0v-2"/><line x1="12" y1="19" x2="12" y2="23"/><line x1="8" y1="23" x2="16" y2="23"/></svg>}
          </button>

        </div>

        <div style={{ display:"flex", justifyContent:"space-between", alignItems:"center", marginTop:8, fontSize:11, color:TH.meta }}>
          <span>🔒 {t.feeNote}</span>
          <span className="mono" style={{ color: over ? "#e5484d" : TH.meta }}>{text.length}/{MAX_MSG}</span>
        </div>

      </div>
    </div>
  );
}

// ══════════════ MAIN APP ══════════════
const EMPTY = {
  balance:"0", staked:"0", pending:"0", totalStaked:"0",
  activeStakers:"0", dailyEmission:"0", totalEarned:"0", sharePercent:"0", halving:"0", rewardDistributed:"0",
  stakingInfo:{ unstakePending:false, canUnstakeNow:false },
  referralInfo:{ referrer:ZERO, totalReferrals:"0", totalReferralEarned:"0", pendingReferral:"0", teamBonusEarned:"0", totalTeamVolume:"0" },
  referralChain:[ZERO,ZERO,ZERO,ZERO,ZERO],
  directReferrals: [],
  claim:{ canClaim:false, amount:"0", total:"0", reason:"" },
};

export default function App() {
  const [lang, setLang] = useState("en");
  const [langOpen, setLangOpen] = useState(false);
  const [tab, setTab] = useState("dashboard");
  const [wallet, setWallet] = useState(null);
  const [network, setNetwork] = useState(false);
  const [toast, setToast] = useState(null);
  const [connecting, setConnecting] = useState(false);
  const [data, setData] = useState(EMPTY);
  const [busy, setBusy] = useState({});
  const [refParam, setRefParam] = useState(null);
  const [polUsd, setPolUsd] = useState(0.077);
  const providerRef = useRef(null);
  const t = I18N[lang] || I18N.en;

  const showToast = useCallback((msg) => { setToast(msg); setTimeout(()=>setToast(null), 3000); }, []);
  const setBusyKey = (k,v) => setBusy(b => ({ ...b, [k]:v }));

  useEffect(() => { try { const p = new URLSearchParams(window.location.search).get("ref"); if (p && isAddress(p)) setRefParam(p); } catch {} }, []);
  useEffect(() => { document.documentElement.lang = (lang==="zh")?"zh":lang; }, [lang]);
  useEffect(() => { var go = function(){ fetch("https://api.coingecko.com/api/v3/simple/price?ids=polygon-ecosystem-token&vs_currencies=usd").then(function(r){ return r.json(); }).then(function(d){ var p = d && d["polygon-ecosystem-token"] && d["polygon-ecosystem-token"].usd; if (p > 0) setPolUsd(p); }).catch(function(){}); }; go(); var id = setInterval(go, 60000); return function(){ clearInterval(id); }; }, []);

  const readProviderRef = useRef(null);
  const getReadProvider = () => {
    if (!readProviderRef.current) {
      var list = RPC_URLS.map(function(u, i){ return { provider: new JsonRpcProvider(u, 137), priority: i + 1, weight: 1, stallTimeout: 1500 }; });
      readProviderRef.current = new FallbackProvider(list, 137, { quorum: 1 });
    }
    return readProviderRef.current;
  };
  const getProvider = () => {
    if (!window.ethereum) { showToast("⚠️ "+t.tInstall); return null; }
    if (!providerRef.current) providerRef.current = new BrowserProvider(window.ethereum);
    return providerRef.current;
  };
  const ensureReady = async () => {
    if (!wallet) { showToast("⚠️ "+t.tConnFirst); return null; }
    if (!network) { showToast("⚠️ "+t.tSwitchPoly); await switchNetwork(); return null; }
    const p = getProvider(); if (!p) return null;
    return await p.getSigner();
  };

 
  const loadData = useCallback(async (account) => {
    const p = getReadProvider();
    const token = new Contract(ADDRESSES.token, TOKEN_ABI, p);
    const stk = new Contract(ADDRESSES.staking, STAKING_ABI, p);
    var _lpP = new JsonRpcProvider("https://polygon-bor-rpc.publicnode.com", 137);

    // Read each value INDEPENDENTLY so one failing call
    // (e.g. a staking read reverting for a fresh user) never
    // blanks out the others — especially the OSG balance.
    const results = await Promise.allSettled([
      account ? token.balanceOf(account) : Promise.resolve(0n),         // 0 balance
      account ? stk.getUserStakingInfo(account) : Promise.resolve(null),// 1
      account ? stk.getUserReferralInfo(account) : Promise.resolve(null),//2
      account ? stk.getReferralChain(account) : Promise.resolve(null),  // 3
      stk.totalStaked(),                                                // 4
      account ? stk.pendingReward(account) : Promise.resolve(0n),       // 5
      account ? stk.canClaimNow(account) : Promise.resolve(null),       // 6
      stk.getPoolInfo(),                                                // 7
      stk.getEmissionSchedule(),                                        // 8
      account ? stk.getDirectReferrals(account) : Promise.resolve([]),  // 9
      account ? p.getBalance(account) : Promise.resolve(0n),            // 10 POL balance
      new Contract("0xA15214B09a9b3E1c821B94fB97d6d3BcA8201Cd2", ["function getReserves() view returns (uint112,uint112,uint32)"], _lpP).getReserves().catch(function(e){ console.warn("getReserves FAIL:", (e && (e.shortMessage || e.message)) || e); return null; }),
        new Contract("0xA15214B09a9b3E1c821B94fB97d6d3BcA8201Cd2", ["function token0() view returns (address)"], _lpP).token0().catch(function(e){ console.warn("token0 FAIL:", (e && (e.shortMessage || e.message)) || e); return null; }),
      ]);

    // helper: value if fulfilled, else fallback
    const val = (i, d) => (results[i].status === "fulfilled" ? results[i].value : d);

    // debug: log any read that failed (open DevTools console to see)
    results.forEach(function (r, i) {
      if (r.status === "rejected") {
        console.warn("loadData read #" + i + " FAILED:", (r.reason && (r.reason.shortMessage || r.reason.reason || r.reason.message)) || r.reason);
      }
    });

    const bal = val(0, 0n);
    const si = val(1, null);
    const ri = val(2, null);
    const chain = val(3, null);
    const totStk = val(4, 0n);
    const pend = val(5, 0n);
    const claimNow = val(6, null);
    const pool = val(7, null);
    const emis = val(8, null);
    const directs = val(9, []);
    const polBal = val(10, 0n);
    var _lpRes = val(11, null);
        var _lpT0 = val(12, null);
        var osgPerPol = 1;
        try {
          if (_lpRes && _lpT0) {
            var _r0 = Number(formatUnits(_lpRes[0], 18));
            var _r1 = Number(formatUnits(_lpRes[1], 18));
            var _osgIsToken0 = _lpT0.toLowerCase() === ADDRESSES.token.toLowerCase();
            var _osgRes = _osgIsToken0 ? _r0 : _r1;
            var _polRes = _osgIsToken0 ? _r1 : _r0;
            if (_osgRes > 0) osgPerPol = _polRes / _osgRes;
            }
        } catch (e) { osgPerPol = 1; }
    console.log("LP_DEBUG", { resNull: !_lpRes, t0Null: !_lpT0, osgPerPol: osgPerPol });
    setData({
      balance: f18(bal),
      polBalance: f18(polBal),
      osgPerPol: osgPerPol,
      staked: si ? f18(si.staked) : "0",
      storageReward: si ? f18(si.rewardPoolPending) : "0",
      pending: f18(pend),
      totalStaked: f18(totStk),
      activeStakers: pool ? String(pool.currentActiveStakers) : "0",
      dailyEmission: pool ? f18(pool.dailyStakingEmission) : "0",
      rewardDistributed: pool ? f18(pool.rewardDistributed) : "0",
      totalEarned: si ? f18(si.totalEarned) : "0",
      sharePercent: si ? (Number(si.sharePercent) / 100).toString() : "0",
      halving: emis ? String(emis.halvingNumber) : "0",
      directReferrals: directs ? directs : [],
      timeNextHalving: emis ? String(emis.timeToNextHalving) : "0",
      stakingInfo: si ? { unstakePending: si.unstakePending, canUnstakeNow: si.canUnstakeNow, unstakeAvailableAt: Number(si.unstakeAvailableAt) } : EMPTY.stakingInfo,
      referralInfo: ri ? { referrer: ri.referrer, totalReferrals: String(ri.totalReferrals), totalReferralEarned: f18(ri.totalReferralEarned), pendingReferral: f18(ri.pendingReferral), teamBonusEarned: f18(ri.teamBonusEarned), totalTeamVolume: f18(ri.totalTeamVolume) } : EMPTY.referralInfo,
      referralChain: chain ? [chain.l1, chain.l2, chain.l3, chain.l4, chain.l5] : EMPTY.referralChain,
      claim: claimNow ? { canClaim: claimNow.canClaim, amount: f18(claimNow.amount), total: f18(claimNow.total), reason: claimNow.reason } : EMPTY.claim,
    });
  }, []);

  const switchNetwork = async () => {
    try {
      await window.ethereum.request({ method:"wallet_switchEthereumChain", params:[{ chainId: POLYGON_CHAIN_ID }] });
      setNetwork(true);
    } catch (e) {
      if (e.code === 4902) {
        try { await window.ethereum.request({ method:"wallet_addEthereumChain", params:[POLYGON_PARAMS] }); setNetwork(true); } catch { showToast("❌ Network add failed"); }
      } else { showToast("❌ "+t.tFailed); }
    }
  };

  const connect = async () => {
    if (!window.ethereum) { showToast("⚠️ "+t.tInstall); return; }
    setConnecting(true);
    try {
      const accs = await window.ethereum.request({ method:"eth_requestAccounts" });
      const cid = await window.ethereum.request({ method:"eth_chainId" });
      setWallet(accs[0]);
      const onPoly = cid === POLYGON_CHAIN_ID;
      setNetwork(onPoly);
      if (!onPoly) await switchNetwork(); else showToast("✅ "+t.tConnected);
      await loadData(accs[0]);
    } catch { showToast("❌ "+t.tConnFail); }
    finally { setConnecting(false); }
  };

  useEffect(() => {
    if (!window.ethereum) return;
    const onAcc = (accs) => { if (accs.length) { setWallet(accs[0]); loadData(accs[0]); } else { setWallet(null); setData(EMPTY); } };
    const onChain = (cid) => { setNetwork(cid === POLYGON_CHAIN_ID); providerRef.current = null; if (wallet) loadData(wallet); };
    window.ethereum.on("accountsChanged", onAcc);
    window.ethereum.on("chainChanged", onChain);
    return () => { window.ethereum.removeListener("accountsChanged", onAcc); window.ethereum.removeListener("chainChanged", onChain); };
  }, [wallet, loadData]);

  useEffect(() => { if (!wallet) return; const tm = setInterval(() => loadData(wallet), 20000); return () => clearInterval(tm); }, [wallet, loadData]);

  const actions = {
    stake: async (amount, referrer) => {
      if (!amount || Number(amount) <= 0) { showToast("⚠️ "+t.tEnterAmt); return; }
      const signer = await ensureReady(); if (!signer) return;
      setBusyKey("stake", true);
      try {
        const amt = parseUnits(String(amount), 18);
        const token = new Contract(ADDRESSES.token, TOKEN_ABI, signer);
        const allowance = await token.allowance(wallet, ADDRESSES.staking);
        if (allowance < amt) { showToast(t.tApproving); const txA = await token.approve(ADDRESSES.staking, amt); await txA.wait(); }
        const stk = new Contract(ADDRESSES.staking, STAKING_ABI, signer);
        showToast(t.tStaking);
        const ref = referrer && isAddress(referrer) ? referrer : ZERO;
        let tx; if (referrer === null) tx = await stk.addToStake(amt); else tx = await stk.stake(amt, ref);
        await tx.wait(); showToast("✅ "+t.tStakeOk); await loadData(wallet);
      } catch (e) { console.error(e); showToast("❌ " + (e?.shortMessage || e?.reason || t.tStakeFail)); }
      finally { setBusyKey("stake", false); }
    },
    requestUnstake: async () => {
      const signer = await ensureReady(); if (!signer) return; setBusyKey("unstake", true);
      try { const stk = new Contract(ADDRESSES.staking, STAKING_ABI, signer); const tx = await stk.requestUnstake(); await tx.wait(); showToast("⏳ "+t.tUnstakeReq); await loadData(wallet); }
      catch (e) { showToast("❌ " + (e?.shortMessage || e?.reason || t.tFailed)); } finally { setBusyKey("unstake", false); }
    },
    unstake: async () => {
      const signer = await ensureReady(); if (!signer) return; setBusyKey("unstake", true);
      try { const stk = new Contract(ADDRESSES.staking, STAKING_ABI, signer); const tx = await stk.unstake(); await tx.wait(); showToast("✅ "+t.tUnstakeOk); await loadData(wallet); }
      catch (e) { showToast("❌ " + (e?.shortMessage || e?.reason || t.tFailed)); } finally { setBusyKey("unstake", false); }
    },
    cancelUnstake: async () => {
      const signer = await ensureReady(); if (!signer) return; setBusyKey("cancel", true);
      try { const stk = new Contract(ADDRESSES.staking, STAKING_ABI, signer); const tx = await stk.cancelUnstake(); await tx.wait(); showToast("↩️ "+t.tCancelled); await loadData(wallet); }
      catch (e) { showToast("❌ " + (e?.shortMessage || e?.reason || t.tFailed)); } finally { setBusyKey("cancel", false); }
    },
    claim: async () => {
      const signer = await ensureReady(); if (!signer) return; setBusyKey("claim", true);
      try {
        // ── STEP 1: Staking.claimReward() — pushes pending into RewardStorage ──
        showToast("1/2 — " + (t.tClaimStep1 || "Moving reward to pool..."));
        const stk = new Contract(ADDRESSES.staking, STAKING_ABI, signer);
        try {
          const tx1 = await stk.claimReward();
          await tx1.wait();
        } catch (e1) {
          // "No rewards" here is OK if storage already holds a balance — keep going.
          var msg1 = (e1 && (e1.shortMessage || e1.reason || e1.message)) || "";
          var benign = msg1.toLowerCase().indexOf("no reward") !== -1
                    || msg1.toLowerCase().indexOf("nothing") !== -1;
          if (!benign) throw e1;
        }

        // ── STEP 2: RewardPool.claim() — mints up to 500 OSG from storage to wallet ──
        showToast("2/2 — " + (t.tClaimStep2 || "Minting OSG to wallet..."));
        const pool = new Contract(ADDRESSES.pool, POOL_ABI, signer);
        const tx2 = await pool.claim();
        await tx2.wait();

        showToast("💰 " + t.tClaimed);
        await loadData(wallet);
      } catch (e) {
        var m = (e && (e.shortMessage || e.reason || e.message)) || "";
        // Friendly message for the hourly-cap restore case
        if (m.indexOf("Mint failed") !== -1 || m.indexOf("reward restored") !== -1) {
          showToast("⏳ " + (t.tCapHit || "Hourly cap reached (500 OSG/hr). Reward is safe — try again in ~1 hour."));
        } else if (m.toLowerCase().indexOf("no reward") !== -1) {
          showToast("ℹ️ " + (t.tNoReward || "No claimable reward right now."));
        } else {
          showToast("❌ " + (m || t.tClaimFail));
        }
        await loadData(wallet);
      } finally { setBusyKey("claim", false); }
    },
  };

  const navItems = [
    ["dashboard", Ico.home, t.dashboard],
    ["staking", Ico.stake, t.staking],
    ["referral", Ico.ref, t.referral],
    ["swap", Ico.swap, t.swap],
    ["messenger", Ico.chat, t.messenger],
  ];

  return (
    <>
      <style>{STYLES}</style>
      <div className="osg-app">
        {/* TOP BAR */}
        <header className="topbar">
          <div className="brand">
            <img className="logo-img" src={LOGO} alt="OSG"/>
            <div className="name" style={{ fontSize:18, letterSpacing:"3.5px", background:"linear-gradient(110deg," + C.gold3 + " 20%," + C.gold1 + " 40%,#fff7e0 50%," + C.gold1 + " 60%," + C.gold3 + " 80%)", backgroundSize:"220% 100%", WebkitBackgroundClip:"text", backgroundClip:"text", color:"transparent", animation:"shine 3.2s linear infinite", filter:"drop-shadow(0 0 10px rgba(233,185,73,.35))" }}>OSG</div><div style={{ fontSize:6.5, letterSpacing:"2.5px", textTransform:"uppercase", color:C.green, fontWeight:600, marginTop:1, whiteSpace:"nowrap" }}>OneX Smart Gold</div>
          </div>
          <div className="top-right">
            <div className="lang">
              <button className="lang-btn" onClick={(e)=>{e.stopPropagation();setLangOpen(o=>!o);}}>
                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2"><circle cx="12" cy="12" r="10"/><path d="M2 12h20M12 2a15.3 15.3 0 0 1 4 10 15.3 15.3 0 0 1-4 10 15.3 15.3 0 0 1-4-10 15.3 15.3 0 0 1 4-10z"/></svg>
                {t.lbl}
              </button>
              {langOpen && (
                <div className="lang-menu" onClick={e=>e.stopPropagation()}>
                  {LANGS.map(L=>(
                    <button key={L.id} className={lang===L.id?"sel":""} onClick={()=>{setLang(L.id);setLangOpen(false);}}>
                      <span>{L.fl}</span> {L.name}
                    </button>
                  ))}
                </div>
              )}
            </div>
           
            {wallet
              ? <div className="wallet-pill"><span className="dot" style={{ background:network?C.green:C.red,boxShadow:network?`0 0 8px ${C.green}`:"none" }}/><span className="addr">{short(wallet)}</span></div>
              : <button className="btn-gold" onClick={connect} disabled={connecting} style={{ width:"auto", height:42, padding:"0 20px", fontSize:13.5, borderRadius:12, background:"linear-gradient(135deg,#FCE9B0 0%," + C.gold1 + " 30%," + C.gold2 + " 65%," + C.gold3 + " 100%)", boxShadow:"0 8px 24px -6px rgba(233,185,73,.6), inset 0 1px 0 rgba(255,255,255,.45)" }}>{connecting?<span className="spin"/>:t.connectWallet}</button>}
          </div>
        </header>

        {/* SCREEN */}
        <main className="screen" onClick={()=>setLangOpen(false)}>
          {tab==="dashboard" && <Dashboard data={data} wallet={wallet} polUsd={polUsd} t={t}/>}
          {tab==="staking"   && <Staking wallet={wallet} data={data} refParam={refParam} actions={actions} busy={busy} t={t}/>}
          {tab==="referral"  && <Referral wallet={wallet} data={data} showToast={showToast} t={t}/>}
          {tab==="swap"      && <Swap t={t}/>}
          {tab==="messenger" && <Messenger wallet={wallet} network={network} getProvider={getProvider} ensureReady={ensureReady} showToast={showToast} t={t}/>}
          {!wallet && <div style={{ textAlign:"center",marginTop:20,fontSize:13,color:C.txt3 }}>👆 {t.connectSee}</div>}
        </main>

        {/* BOTTOM NAV */}
        <nav className="nav">
          {navItems.map(([id,icon,label])=>(
            <button key={id} className={tab===id?"on":""} onClick={()=>setTab(id)}>{icon}<span>{label}</span></button>
          ))}
        </nav>
      </div>
      {toast && <div className="toast">{toast}</div>}
    </>
  );
}
