# CLAUDE.md — OSG DApp

## Communication
- Talk to the owner in Marathi. Code, identifiers, comments and commit messages in English only.

## Change control
- Read-only by default. No code change, commit or PR until the owner says "हो" explicitly.
- Never push to main. One change = one branch = one PR. The owner reviews the diff and merges.

## Money-related code (claim, stake, treasury, spot)
- Read the contract source in contracts/*.sol first. Take every number, limit and rule from the contract, never from guesses.
- Simulate (staticCall) before every write; show the user the contract's answer.

## Secrets and identity
- Never ask for, store or commit private keys, seed phrases or API keys.
- The dRPC key lives only in Vercel env DRPC_KEY; it must never reach the browser bundle.
- Never write any personal name or email anywhere in the repo, commits or PRs.

## Stack
- React + Vite, ethers v6, Vercel (functions region bom1), Polygon mainnet (chainId 137).
- Main files: src/App.jsx, src/contracts.js, api/*.js, public/admin-v5.html, contracts/*.sol.
- Reads: RPC_URLS with /api/rpc first; FailoverRpcProvider (batch 10, timeout 4s). Admin page mirrors this.

## Checks before any PR
- npm install && npx vite build must pass.
- Keep package-lock.json in sync with package.json.
- Never commit package-lock.json changes unless the PR is about dependencies.

## Live addresses (Polygon)
- Token 0xba05176748347944CC26900c821AbFeBeBC57415
- Referral v5 0x58383A8171014a8008d28e7CbB509e21412ec52A
- Term 0xb3DE3956DF62a069c9AC428Ec58120b3d9CD7cCc
- LP Mining 0x1F04F1441208ee8dDD3a124DEfc4a493d768d0fC
- Treasury 0x4669b2d38098Ae28D0332F03D1630B334aDDDF50
- OSGSpotReward 0x7Ee98AE2BeAEf2251A8bBB3810006495F62b7C92
  (adapters: Term 0x7cBfD31Fc4eA31D5390f20aDbfFd0CbfB839912e, LP 0xdD065840f5Bd458DC4E9dEeAeD7f1946812870A6)
- Owner 0xF8acaA5617DfF6DB3d0cb44ca8de0E50A449BB83
