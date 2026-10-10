import React from 'react'
import ReactDOM from 'react-dom/client'
import { JsonRpcProvider } from 'ethers'
import App from './App.jsx'
import { RPC_URLS, activateReferralV6 } from './contracts.js'

// Decide v5 or v6 for referral once, before the first screen reads it.
// Tries the read nodes in order (1.5 s each); after 3 s in total the app
// renders anyway and stays on v5. A late answer is ignored.
let open = true
const stillOpen = () => open

async function pickReferral() {
  for (const url of RPC_URLS) {
    try {
      const p = new JsonRpcProvider(url, 137, { staticNetwork: true })
      const answered = await Promise.race([
        activateReferralV6(p, stillOpen).then(() => true),
        new Promise((r) => setTimeout(() => r(false), 1500)),
      ])
      if (answered) return
    } catch (e) {}
  }
}

const deadline = new Promise((r) => setTimeout(r, 3000))
Promise.race([pickReferral(), deadline]).finally(() => {
  open = false
  ReactDOM.createRoot(document.getElementById('root')).render(
    <React.StrictMode>
      <App />
    </React.StrictMode>,
  )
})
