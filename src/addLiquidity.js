// ======================================================================
//  addLiquidity.js -- OSG DApp -- In-app "Add Liquidity" module
//
//  Talks directly to the QuickSwap V2 Router so users can add OSG + POL
//  liquidity and get LP tokens without leaving the DApp. No new Solidity
//  contract is needed -- this just calls QuickSwap's already-deployed
//  Router from the frontend.
//
//  All addresses and ABIs come from contracts.js (single source of
//  truth) -- nothing is duplicated or hardcoded here.
//
//  Uses the Router's addLiquidityETH() function:
//   - Only the OSG token needs an approve() call (no separate WPOL
//     approve -- POL is sent directly as payable value, the Router
//     wraps it internally)
//   - Any leftover POL (unused, if the ratio doesn't match exactly)
//     is automatically refunded to the user's wallet
// ======================================================================

import { ethers } from "ethers";
import {
  ADDRESSES,
  TOKEN_ABI,
  ROUTER_ABI,
  PAIR_ABI,
  LP_TOKEN_ABI,
} from "./contracts.js";

// ======================================================================
//  STEP 1 -- Ratio calculator (read-only, no transaction)
//  Given an OSG amount the user typed in, works out how much POL is
//  needed at the pool's current live ratio.
// ======================================================================

/**
 * Works out how much POL is required for a given OSG amount, based on
 * the pool's current reserves. Read-only -- no wallet signature needed.
 *
 * @param {ethers.Provider} provider  - read-only provider
 * @param {string} osgAmountHuman     - OSG amount the user typed, e.g. "100"
 * @returns {Promise<{osgAmount: bigint, polAmount: bigint, polAmountHuman: string}>}
 */
export async function calculateRequiredPOL(provider, osgAmountHuman) {
  const pair = new ethers.Contract(ADDRESSES.lpPair, PAIR_ABI, provider);
  const [reserve0, reserve1] = await pair.getReserves();
  const token0 = (await pair.token0()).toLowerCase();

  // Uniswap-V2-style pairs don't guarantee token order, so work out
  // which reserve belongs to which token from token0().
  const isOSGToken0 = token0 === ADDRESSES.token.toLowerCase();
  const [osgReserve, polReserve] = isOSGToken0
    ? [reserve0, reserve1]
    : [reserve1, reserve0];

  const osgAmount = ethers.parseUnits(osgAmountHuman, 18);

  // Standard constant-product ratio math (same formula the Router's
  // quote() function uses internally):
  // polAmount = osgAmount * polReserve / osgReserve
  const polAmount = (osgAmount * polReserve) / osgReserve;

  return {
    osgAmount,
    polAmount,
    polAmountHuman: ethers.formatUnits(polAmount, 18),
  };
}

// ======================================================================
//  STEP 2 -- Approve + Add Liquidity (actual transactions)
// ======================================================================

const SLIPPAGE_BPS = 150n; // 1.5% default slippage tolerance -- expose in UI
const DEADLINE_MINUTES = 20;

function applySlippage(amount) {
  // amount * (10000 - 150) / 10000 => minimum acceptable amount after 1.5% slippage
  return (amount * (10000n - SLIPPAGE_BPS)) / 10000n;
}

/**
 * Approves the Router to spend OSG, but only if the current allowance
 * isn't already sufficient -- avoids a wasted gas transaction.
 * Reuses TOKEN_ABI (already defined in contracts.js for OSG).
 *
 * @param {ethers.Signer} signer
 * @param {bigint} osgAmount
 */
export async function ensureOSGApproval(signer, osgAmount) {
  const userAddress = await signer.getAddress();
  const osgToken = new ethers.Contract(ADDRESSES.token, TOKEN_ABI, signer);

  const currentAllowance = await osgToken.allowance(
    userAddress,
    ADDRESSES.quickswapRouter
  );
  if (currentAllowance >= osgAmount) {
    return null; // already approved enough, skip the transaction
  }

  const tx = await osgToken.approve(ADDRESSES.quickswapRouter, osgAmount);
  await tx.wait();
  return tx;
}

/**
 * Adds liquidity -- sends approved OSG plus POL (as payable value) and
 * receives LP tokens back. Any unused POL is automatically refunded.
 *
 * @param {ethers.Signer} signer
 * @param {string} osgAmountHuman     - e.g. "100"
 * @param {bigint} expectedPolAmount  - from calculateRequiredPOL()
 * @returns {Promise<ethers.TransactionReceipt>}
 */
export async function addLiquidity(signer, osgAmountHuman, expectedPolAmount) {
  const userAddress = await signer.getAddress();
  const router = new ethers.Contract(
    ADDRESSES.quickswapRouter,
    ROUTER_ABI,
    signer
  );

  const osgAmount = ethers.parseUnits(osgAmountHuman, 18);
  const osgAmountMin = applySlippage(osgAmount);
  const polAmountMin = applySlippage(expectedPolAmount);
  const deadline = Math.floor(Date.now() / 1000) + DEADLINE_MINUTES * 60;

  const tx = await router.addLiquidityETH(
    ADDRESSES.token,
    osgAmount,
    osgAmountMin,
    polAmountMin,
    userAddress,
    deadline,
    { value: expectedPolAmount } // POL is sent here directly as payable value
  );

  return await tx.wait();
}

/**
 * Reads the user's current LP token balance. Handy for showing
 * "Balance: X LP" in the UI and for the empty-state check.
 *
 * @param {ethers.Provider} provider
 * @param {string} userAddress
 * @returns {Promise<{raw: bigint, human: string}>}
 */
export async function getLPBalance(provider, userAddress) {
  const lpToken = new ethers.Contract(ADDRESSES.lpPair, LP_TOKEN_ABI, provider);
  const raw = await lpToken.balanceOf(userAddress);
  return { raw, human: ethers.formatUnits(raw, 18) };
}

// ======================================================================
//  Full flow -- how the UI would call this (example only, not a
//  component)
// ======================================================================
//
//  const { osgAmount, polAmount, polAmountHuman } =
//      await calculateRequiredPOL(provider, "100");
//
//  // ... show polAmountHuman to the user, get an "I understand the
//  //     risk" checkbox confirmed ...
//
//  await ensureOSGApproval(signer, osgAmount);   // step a (only if needed)
//  const receipt = await addLiquidity(signer, "100", polAmount); // step b
//
//  // once the receipt succeeds -- show "You received X LP tokens",
//  // and offer a shortcut to "Deposit into Mining now".
//
// ======================================================================
