(function(){
"use strict";
var TOKEN="0xba05176748347944CC26900c821AbFeBeBC57415";
var PAIR="0xA15214B09a9b3E1c821B94fB97d6d3BcA8201Cd2";
var POOL="0xDc4fE983ed301AD42F4E4C43951aa07A7a182855";
var RPCS=["https://polygon-rpc.com","https://polygon.drpc.org","https://1rpc.io/matic","https://polygon-bor-rpc.publicnode.com"];
var CONTRACTS=[
  ["OSG Token","ERC-20 token · 18 decimals","core",TOKEN],
  ["OSG / WPOL Pair","QuickSwap V2 liquidity pool","core",PAIR],
  ["Reward Pool","Daily release & split","core",POOL],
  ["Treasury","Bonus & reserve funds","core","0x4669b2d38098Ae28D0332F03D1630B334aDDDF50"],
  ["LP Mining · 12 months","365-day LP lock","mining","0x1F04F1441208ee8dDD3a124DEfc4a493d768d0fC"],
  ["LP Mining · 6 & 18 months","180 / 540-day LP locks","mining","0x333a6c51Baa2d19Af036f45f32eaCF10234F17C8"],
  ["Term Staking","Closed to new stakes","mining","0xb3DE3956DF62a069c9AC428Ec58120b3d9CD7cCc"],
  ["Staking (legacy)","Original flexible pool","mining","0x048E814C02e85ec1438Ab8C1d2e9150A5289A886"],
  ["Community","Community programme","community","0x58383A8171014a8008d28e7CbB509e21412ec52A"],
  ["Spot Reward","One-time sponsor bonus","community","0x7Ee98AE2BeAEf2251A8bBB3810006495F62b7C92"],
  ["P2P Exchange","Order book in POL & USDT","tools","0x269EcA6aDb7c9c1beFDc6c0be48a545b1920E1bb"],
  ["Messenger","Encrypted wallet chat","tools","0x29c63cd4C3F03B1f64e929b0b8baC691DEB5FA5c"],
  ["Media Storage","IPFS media index","tools","0x88E64Cbc22a35c2928038f2bc13F06630C93D07A"],
  ["Timelock DAO","Delayed governance actions","gov","0xE2E82A8ACdd3Af7FA74Eacb3331231A769d80D4c"]
];
var TAG={core:["Core","p-gold"],mining:["Mining","p-gold"],community:["Community","p-purple"],tools:["Tools","p-blue"],gov:["Governance","p-green"]};
var $=function(id){return document.getElementById(id)};
function set(id,v){var e=$(id);if(e)e.textContent=v}
function toast(m){var t=$("toast");if(!t)return;t.textContent=m;t.classList.add("on");clearTimeout(toast.h);toast.h=setTimeout(function(){t.classList.remove("on")},2200)}
function short(a){return a.slice(0,6)+"…"+a.slice(-4)}
function nf(n,d){return Number(n).toLocaleString("en-US",{maximumFractionDigits:d==null?0:d,minimumFractionDigits:d==null?0:Math.min(d,2)})}
function usdK(n){if(!(n>0))return"—";if(n>=1e6)return"$"+(n/1e6).toFixed(2)+"M";if(n>=1e3)return"$"+(n/1e3).toFixed(2)+"K";return"$"+n.toFixed(2)}
set("yr",new Date().getFullYear());

/* nav */
if($("menu")&&$("links")){
  $("menu").onclick=function(){var o=$("links").classList.toggle("open");$("menu").setAttribute("aria-expanded",o?"true":"false")};
  document.querySelectorAll("#links a").forEach(function(a){a.onclick=function(){$("links").classList.remove("open")}});
}

/* reveal */
var io="IntersectionObserver" in window?new IntersectionObserver(function(es){es.forEach(function(e){if(e.isIntersecting){e.target.classList.add("in");io.unobserve(e.target)}})},{threshold:.12}):null;
document.querySelectorAll(".reveal").forEach(function(el){io?io.observe(el):el.classList.add("in")});

/* contracts */
var copySvg='<svg viewBox="0 0 24 24"><rect x="9" y="9" width="11" height="11" rx="2"/><path d="M5 15V5a2 2 0 0 1 2-2h8"/></svg>';
var extSvg='<svg viewBox="0 0 24 24"><path d="M14 4h6v6M20 4l-9 9M18 14v5a1 1 0 0 1-1 1H5a1 1 0 0 1-1-1V7a1 1 0 0 1 1-1h5"/></svg>';
function renderCt(f){
  $("ctList").innerHTML=CONTRACTS.filter(function(c){return f==="all"||c[2]===f}).map(function(c){
    var t=TAG[c[2]];
    return '<div class="ct"><div><div class="nm">'+c[0]+' <span class="pill '+t[1]+'" style="margin-left:8px">'+t[0]+'</span></div><div class="ds">'+c[1]+'</div></div>'+
      '<div class="acts"><button class="icbtn" data-copy="'+c[3]+'" aria-label="Copy address">'+copySvg+'</button><a class="icbtn" href="https://polygonscan.com/address/'+c[3]+'#code" target="_blank" rel="noopener" aria-label="Open on Polygonscan">'+extSvg+'</a></div>'+
      '<div class="ad">'+c[3]+'</div></div>';
  }).join("");
}
if($("ctList"))renderCt("all");
if($("filters"))$("filters").onclick=function(e){var b=e.target.closest("button");if(!b)return;document.querySelectorAll("#filters button").forEach(function(x){x.classList.toggle("on",x===b)});renderCt(b.dataset.f)};
document.addEventListener("click",function(e){var b=e.target.closest("[data-copy]");if(!b)return;var v=b.getAttribute("data-copy");
  (navigator.clipboard?navigator.clipboard.writeText(v):Promise.reject()).then(function(){toast("Address copied")},function(){toast(v)})});

/* deck */
if($("slides")&&$("dots")){
var slides=[].slice.call(document.querySelectorAll(".slide")),cur=0,dots=$("dots");
slides.forEach(function(_,i){var b=document.createElement("button");b.setAttribute("aria-label","Slide "+(i+1));b.onclick=function(){go(i)};dots.appendChild(b)});
function go(i){cur=(i+slides.length)%slides.length;slides.forEach(function(s,j){s.classList.toggle("on",j===cur)});[].forEach.call(dots.children,function(d,j){d.classList.toggle("on",j===cur)})}
go(0);
$("prev").onclick=function(){go(cur-1)};$("next").onclick=function(){go(cur+1)};
document.addEventListener("keydown",function(e){var r=($("deck")||$("slides")).getBoundingClientRect();if(r.top<innerHeight&&r.bottom>0){if(e.key==="ArrowRight")go(cur+1);if(e.key==="ArrowLeft")go(cur-1)}});
var sx=null;$("slides").addEventListener("touchstart",function(e){sx=e.touches[0].clientX},{passive:true});
$("slides").addEventListener("touchend",function(e){if(sx==null)return;var dx=e.changedTouches[0].clientX-sx;if(Math.abs(dx)>40)go(cur+(dx<0?1:-1));sx=null});
if($("printDeck"))$("printDeck").onclick=function(){window.print()};
if($("fullDeck"))$("fullDeck").onclick=function(){var el=document.querySelector(".deck");(el.requestFullscreen||el.webkitRequestFullscreen||function(){}).call(el)};
}

/* add token */
if($("addToken"))$("addToken").onclick=function(){
  if(!window.ethereum){toast("Open this page in a wallet browser (MetaMask, Trust…)");return}
  window.ethereum.request({method:"wallet_watchAsset",params:{type:"ERC20",options:{address:TOKEN,symbol:"OSG",decimals:18,image:location.origin+"/logo.png"}}})
    .then(function(ok){toast(ok?"OSG added to your wallet":"Not added")},function(){toast("Not added")});
};

/* market data (DexScreener) */
// circ = circulating supply, same method as the whitepaper:
// totalSupply - Treasury balance - Reward Storage balance.
var priceUsd=0,circ=0;
var TREASURY="0x4669b2d38098Ae28D0332F03D1630B334aDDDF50",REWARD_STORAGE="0xa0b2DcB18Cf0BdF61bcB9D33F538167dF501BEcB";
function paintMcap(){if(priceUsd>0&&circ>0)set("sMcap",usdK(priceUsd*circ))}
if($("sPrice")||$("pricePol")||$("q"))fetch("https://api.dexscreener.com/latest/dex/pairs/polygon/"+PAIR).then(function(r){return r.json()}).then(function(d){
  var p=d&&(d.pair||(d.pairs&&d.pairs[0]));if(!p)return;
  priceUsd=Number(p.priceUsd)||0;
  set("sPrice",priceUsd>0?"$"+priceUsd.toFixed(priceUsd>=1?2:4):"—");
  var pn=Number(p.priceNative);set("sPricePol",pn>0?nf(pn,2)+" POL":"—");
  set("pricePol",pn>0?nf(pn,4)+" POL":"—");
  var liq=p.liquidity&&Number(p.liquidity.usd);set("sLiq",usdK(liq));
  var c=p.priceChange&&Number(p.priceChange.h24);
  if(isFinite(c)&&$("sChg")){$("sChg").textContent=(c>=0?"▲ +":"▼ ")+c.toFixed(2)+"%";$("sChg").style.color=c>=0?"var(--green)":"var(--red)"}
  paintMcap();
}).catch(function(){set("sPricePol","Price feed unavailable")});

/* chain reads */
function provider(){
  var list=RPCS.map(function(u){return new ethers.JsonRpcProvider(u,137,{staticNetwork:true})});
  return list;
}
async function withRpc(fn){
  var ps=provider();
  for(var i=0;i<ps.length;i++){try{return await fn(ps[i])}catch(e){}}
  throw new Error("all RPCs failed");
}
var ERC20=["function totalSupply() view returns (uint256)","function balanceOf(address) view returns (uint256)","event Transfer(address indexed from,address indexed to,uint256 value)"];
var POOLABI=["function getDailyBase() view returns (uint256)","function stakingPercent() view returns (uint256)","function miningPercent() view returns (uint256)","function referralPercent() view returns (uint256)",
  "function getEmissionInfo() view returns (uint256 halving,uint256 dailyBase,uint256 nextHalvingIn,uint256 emissionEndsIn,uint256 remainingBudget,bool stopped,uint256 daysBehind,bool needsSync,bool inEmergency)"];

function chain(){
  if($("supply")||$("sMcap"))withRpc(function(p){var t=new ethers.Contract(TOKEN,ERC20,p);return Promise.all([t.totalSupply(),t.balanceOf(TREASURY),t.balanceOf(REWARD_STORAGE)])}).then(function(r){
    var minted=Number(ethers.formatUnits(r[0],18));
    circ=Number(ethers.formatUnits(r[0]-r[1]-r[2],18));
    set("supply",nf(minted));
    var pct=minted/23e6*100;set("supplyPct",pct.toFixed(2)+"%");
    setTimeout(function(){if($("supplyBar"))$("supplyBar").style.width=Math.max(pct,1.2)+"%"},200);
    paintMcap();
  }).catch(function(){set("supply","—")});

  if($("daily")||$("dailyDonut")||$("split"))withRpc(function(p){var c=new ethers.Contract(POOL,POOLABI,p);return Promise.all([c.getDailyBase(),c.stakingPercent(),c.miningPercent(),c.referralPercent()])}).then(function(r){
    var d=Number(ethers.formatUnits(r[0],18));
    set("daily",nf(d)+" OSG");set("dailyDonut",nf(d));
    set("split","Mining "+r[2]+"% · Community "+r[3]+"% · Staking "+r[1]+"%");
  }).catch(function(){});

  if($("halving"))withRpc(function(p){return new ethers.Contract(POOL,POOLABI,p).getEmissionInfo()}).then(function(e){
    var s=Number(e.nextHalvingIn);if(!(s>0))return;
    var days=Math.floor(s/86400),dt=new Date(Date.now()+s*1000);
    $("halving").textContent="in "+nf(days)+" days · "+dt.toLocaleDateString("en-GB",{day:"numeric",month:"short",year:"numeric"});
    $("halving").style.color="var(--blue)";
  }).catch(function(){});

  if($("txs"))loadTx();
}
var seen={};
function loadTx(){
  withRpc(async function(p){
    var bn=await p.getBlockNumber();
    var c=new ethers.Contract(TOKEN,ERC20,p);
    var logs=await c.queryFilter("Transfer",bn-3000,bn);
    return logs.slice(-8).reverse();
  }).then(function(logs){
    if(!logs.length){$("txs").innerHTML='<p class="muted" style="font-size:14px;padding:12px 0">No transfers in the last ~2 hours.</p>';return}
    $("txs").innerHTML=logs.map(function(l){
      var v=Number(ethers.formatUnits(l.args[2],18));
      var fr=l.args[0],to=l.args[1],mint=/^0x0{40}$/i.test(fr);
      return '<div class="tx"><span class="pill '+(mint?"p-gold":"p-blue")+'">'+(mint?"Released":"Transfer")+'</span>'+
        '<span class="ad">'+(mint?"Reward Pool":short(fr))+' → '+short(to)+'</span>'+
        '<a class="num" style="color:var(--gold-hi);font-weight:700;text-decoration:none" href="https://polygonscan.com/tx/'+l.transactionHash+'" target="_blank" rel="noopener">'+nf(v,2)+'</a></div>';
    }).join("");
  }).catch(function(){$("txs").innerHTML='<p class="muted" style="font-size:14px;padding:12px 0">Could not reach a public Polygon node right now. Try again in a minute.</p>';$("txState").className="pill p-red";$("txState").textContent="Offline"});
}



/* ---------- socials: fill these two links ---------- */
var SOCIAL={telegram:"https://t.me/onexgoldofficial",x:"https://x.com/OSG_OneXGold"};
document.querySelectorAll("[data-social]").forEach(function(a){var u=SOCIAL[a.getAttribute("data-social")];if(u){a.href=u}else{a.style.display="none"}});
if(!SOCIAL.telegram&&!SOCIAL.x){var so=document.getElementById("social");if(so)so.style.display="none"}

/* ---------- explorer ---------- */
var LABELS={};CONTRACTS.forEach(function(c){LABELS[c[3].toLowerCase()]=c[0]});
LABELS["0xf8acaa5617dff6db3d0cb44ca8de0e50a449bb83"]="OSG-MAIN (owner)";
LABELS["0x0d500b1d8e8ef31e21c99d1db9a6444d3adf1270"]="WPOL";
LABELS["0xa5e0829caced8ffdd4de3c43696c57f7d7a678ff"]="QuickSwap Router";
LABELS["0xc2132d05d31c914a87c6611c10748aeb04b58e8f"]="USDT";
var METHODS={"0xa9059cbb":"Transfer","0x095ea7b3":"Approve","0x23b872dd":"Transfer from","0x4e71d92d":"Claim","0xb6b55f25":"Deposit","0x2e1a7d4d":"Withdraw","0xe8e33700":"Add liquidity","0xf305d719":"Add liquidity (POL)","0x38ed1739":"Swap","0x7ff36ab5":"Swap POL → token","0x18cbafe5":"Swap token → POL","0x791ac947":"Swap token → POL","0xb6f9de95":"Swap POL → token"};
function esc(t){return String(t).replace(/[&<>"]/g,function(c){return{"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;"}[c]})}
function addrHtml(a){if(!a)return'<span class="muted">—</span>';var l=LABELS[a.toLowerCase()];return'<a class="hash" style="color:var(--gold-hi);text-decoration:none" href="#" data-q="'+a+'">'+(l?'<span style="font-family:Manrope;font-weight:700;color:var(--purple)">'+esc(l)+'</span><br>':'')+a+'</a>'}
function cell(k,v,wide){return'<div class="dcell'+(wide?" wide":"")+'"><small>'+k+'</small><b>'+v+'</b></div>'}
function showDetail(h){var d=$("detail");d.innerHTML=h;d.classList.add("on")}
function fmtTime(ts){var dt=new Date(ts*1000);return dt.toLocaleString("en-GB",{day:"numeric",month:"short",year:"numeric",hour:"2-digit",minute:"2-digit"})}
function ago(ts){var s=Math.max(0,Date.now()/1000-ts);if(s<60)return Math.floor(s)+" sec ago";if(s<3600)return Math.floor(s/60)+" min ago";if(s<86400)return Math.floor(s/3600)+" h ago";return Math.floor(s/86400)+" days ago"}
var TRANSFER_TOPIC="0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef";

async function lookAddress(a,p){
  var tok=new ethers.Contract(TOKEN,ERC20,p);
  var r=await Promise.all([tok.balanceOf(a),p.getBalance(a),p.getTransactionCount(a),p.getCode(a),p.getBlockNumber()]);
  var osg=Number(ethers.formatUnits(r[0],18)),pol=Number(ethers.formatEther(r[1])),isC=r[3]&&r[3]!=="0x";
  var pad=ethers.zeroPadValue(a,32),bn=r[4],from=bn-5000;
  var logs=[];try{var l1=await p.getLogs({address:TOKEN,topics:[TRANSFER_TOPIC,pad],fromBlock:from,toBlock:bn});var l2=await p.getLogs({address:TOKEN,topics:[TRANSFER_TOPIC,null,pad],fromBlock:from,toBlock:bn});logs=l1.concat(l2).sort(function(x,y){return y.blockNumber-x.blockNumber||y.index-x.index}).slice(0,8)}catch(e){logs=null}
  return {osg:osg,pol:pol,n:r[2],isC:isC,logs:logs};
}
async function lookTx(h,p){
  var r=await Promise.all([p.getTransaction(h),p.getTransactionReceipt(h)]);
  if(!r[0])return null;
  var blk=r[0].blockNumber!=null?await p.getBlock(r[0].blockNumber):null;
  return {tx:r[0],rc:r[1],blk:blk};
}
function renderAddress(a,x){
  var label=LABELS[a.toLowerCase()];
  var h='<div class="dhead"><span class="pill '+(x.isC?"p-purple":"p-blue")+'">'+(x.isC?"Contract":"Wallet")+'</span><h4>'+(label?esc(label):"Address")+'</h4>'+(label?'<span class="pill p-green">Known OSG address</span>':'')+'</div>';
  h+='<div class="dgrid">'+cell("Address",'<span class="hash" style="color:var(--gold-hi)">'+a+'</span>',true)+
     cell("OSG balance",'<span class="serif num" style="font-size:24px;color:'+(x.osg>0?"var(--gold-hi)":"var(--txt2)")+'">'+nf(x.osg,2)+'</span>')+
     cell("Value in USD",priceUsd>0&&x.osg>0?'<span class="num c-blue">$'+nf(x.osg*priceUsd,2)+'</span>':'<span class="muted">—</span>')+
     cell("POL balance",'<span class="num '+(x.pol>0?"c-blue":"muted")+'">'+nf(x.pol,4)+' POL</span>')+
     cell("Transactions sent",'<span class="num '+(x.n>0?"c-purple":"muted")+'">'+nf(x.n)+'</span>')+
     cell("Type",x.isC?'<span class="c-purple">Smart contract</span>':'<span class="c-blue">Wallet (EOA)</span>')+
     cell("Explorer",'<a class="c-green" href="https://polygonscan.com/address/'+a+'" target="_blank" rel="noopener">Open on Polygonscan</a>')+'</div>';
  h+='<div class="subt">Recent OSG transfers <span class="muted" style="font-weight:500;font-size:13px">(last ~3 hours)</span></div>';
  if(x.logs===null)h+='<p class="muted" style="font-size:14px">The public node limited this query. Open Polygonscan for the full history.</p>';
  else if(!x.logs.length)h+='<p class="muted" style="font-size:14px">No OSG transfers in the last ~3 hours.</p>';
  else h+=x.logs.map(function(l){var fr=ethers.getAddress("0x"+l.topics[1].slice(26)),to=ethers.getAddress("0x"+l.topics[2].slice(26)),v=Number(ethers.formatUnits(l.data,18)),out=fr.toLowerCase()===a.toLowerCase();
     return'<div class="tx"><span class="pill '+(out?"p-red":"p-green")+'">'+(out?"Out":"In")+'</span><span class="ad">'+(out?"to "+short(to):"from "+short(fr))+'</span><a class="num" href="#" data-q="'+l.transactionHash+'" style="color:'+(out?"var(--red)":"var(--green)")+';font-weight:700;text-decoration:none">'+(out?"−":"+")+nf(v,2)+' OSG</a></div>'}).join("");
  showDetail(h);
}
function renderTx(h,x){
  var tx=x.tx,rc=x.rc,blk=x.blk;
  var st=!rc?["Pending","p-gold"]:rc.status===1?["Success","p-green"]:["Failed","p-red"];
  var sel=tx.data&&tx.data.length>=10?tx.data.slice(0,10):"";
  var method=sel?(METHODS[sel]||"Contract call"):"POL transfer";
  var fee=rc&&rc.gasUsed!=null?Number(ethers.formatEther(rc.gasUsed*(rc.gasPrice||tx.gasPrice||0n))):null;
  var out='<div class="dhead"><span class="pill '+st[1]+'">'+st[0]+'</span><h4>'+esc(method)+'</h4>'+(blk?'<span class="pill p-blue">'+ago(blk.timestamp)+'</span>':'')+'</div>';
  out+='<div class="dgrid">'+cell("Transaction ID",'<span class="hash" style="color:var(--gold-hi)">'+h+'</span>',true)+
    cell("From",addrHtml(tx.from))+cell("To",addrHtml(tx.to))+
    cell("Block",tx.blockNumber!=null?'<span class="num c-blue">'+nf(tx.blockNumber)+'</span>':'<span class="c-gold">Not yet in a block</span>')+
    cell("Time",blk?'<span class="c-blue">'+fmtTime(blk.timestamp)+'</span>':'<span class="muted">—</span>')+
    cell("POL sent",'<span class="num '+(tx.value>0n?"c-blue":"muted")+'">'+nf(Number(ethers.formatEther(tx.value)),4)+' POL</span>')+
    cell("Network fee",fee!=null?'<span class="num muted">'+nf(fee,5)+' POL</span>':'<span class="muted">—</span>')+
    cell("Explorer",'<a class="c-green" href="https://polygonscan.com/tx/'+h+'" target="_blank" rel="noopener">Open on Polygonscan</a>')+'</div>';
  var osgLogs=rc?rc.logs.filter(function(l){return l.address.toLowerCase()===TOKEN.toLowerCase()&&l.topics[0]===TRANSFER_TOPIC}):[];
  out+='<div class="subt">OSG moved in this transaction</div>';
  if(!osgLogs.length)out+='<p class="muted" style="font-size:14px">No OSG token transfer in this transaction.</p>';
  else out+=osgLogs.map(function(l){var fr=ethers.getAddress("0x"+l.topics[1].slice(26)),to=ethers.getAddress("0x"+l.topics[2].slice(26)),v=Number(ethers.formatUnits(l.data,18)),mint=/^0x0{40}$/i.test(fr);
     return'<div class="tx"><span class="pill '+(mint?"p-gold":"p-blue")+'">'+(mint?"Released":"Transfer")+'</span><span class="ad">'+(mint?"Reward Pool":(LABELS[fr.toLowerCase()]||short(fr)))+' → '+(LABELS[to.toLowerCase()]||short(to))+'</span><b class="num c-gold">'+nf(v,4)+' OSG</b></div>'}).join("");
  showDetail(out);
}
async function search(q){
  q=(q||"").trim();
  if(typeof ethers==="undefined"){showDetail('<p class="muted">Still loading, try again in a second.</p>');return}
  if(/^0x[0-9a-fA-F]{64}$/.test(q)){
    showDetail('<p class="muted">Reading the transaction from Polygon…</p>');
    try{var x=await withRpc(function(p){return lookTx(q,p)});if(!x){showDetail('<p class="c-red">No transaction found with this ID on Polygon. Check that you copied the full hash.</p>');return}renderTx(q,x)}
    catch(e){showDetail('<p class="c-red">Could not reach a Polygon node. Try again in a minute.</p>')}
  }else if(ethers.isAddress(q)){
    var a=ethers.getAddress(q);
    showDetail('<p class="muted">Reading the address from Polygon…</p>');
    try{var y=await withRpc(function(p){return lookAddress(a,p)});renderAddress(a,y)}
    catch(e){showDetail('<p class="c-red">Could not reach a Polygon node. Try again in a minute.</p>')}
  }else{
    showDetail('<p class="c-red">Enter a 42-character address (0x…) or a 66-character transaction ID.</p>');
  }
}
if($("q")&&$("qGo")){
$("qGo").onclick=function(){search($("q").value)};
$("q").addEventListener("keydown",function(e){if(e.key==="Enter")search($("q").value)});
document.addEventListener("click",function(e){var t=e.target.closest("[data-try],[data-q]");if(!t)return;e.preventDefault();var v=t.getAttribute("data-try")||t.getAttribute("data-q");$("q").value=v;search(v);document.getElementById("q").scrollIntoView({behavior:"smooth",block:"center"})});
}

/* chain reads run only on pages that show chain data and load ethers */
var needsChain=["sMcap","supply","daily","dailyDonut","halving","txs"].some(function(id){return $(id)});
var tries=0;
function start(){if(typeof ethers==="undefined"){if(++tries>100)return;return setTimeout(start,150)}chain();if($("txs"))setInterval(loadTx,60000)}
if(needsChain&&document.querySelector('script[src*="ethers"]'))start();
})();
