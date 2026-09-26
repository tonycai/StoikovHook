# Live Judging Notes

Live judging: 2026-09-27, 09:30 JST. A 4-minute demo, then 3 minutes of questions. All in English.

Rules for these notes:
- Short sentences and simple words.
- For fees, say the percent first. The pips number is in brackets for you. 1 pip = 0.0001%, so 100 pips = 0.01%.
- If you forget a line, say the short version in **bold**.
- Every number comes from the README. The sources are in part 3.

How to say the hard names:

| Word | Say it like |
|---|---|
| Avellaneda | ah-veh-yah-NEH-dah |
| Stoikov | STOY-kov |
| τR | "tau R" (tau rhymes with "now") |
| Sepolia | seh-POH-lee-ah |
| oracle | OR-uh-kul |
| LVR | the letters: L, V, R |

---

## 1. The 4-Minute Demo

### Before you start

Open these tabs, in this order:

1. The GitHub README: github.com/tonycai/StoikovHook
2. `docs/figures/png/fee-curve.png`
3. `docs/figures/png/lp-performance.png`
4. The hook on Etherscan: sepolia.etherscan.io/address/0x67b97620e35DAf13de266F84cAbC8c8d45755080#code
5. The price-down swap: sepolia.etherscan.io/tx/0x266a7eaa4f6f8888b6047174dd66cc1b3d1f2dcd4d60484b0ee3bb47e620d0a7 (open the "Logs" tab)
6. The price-up swap: sepolia.etherscan.io/tx/0x316450c5cbe165e81fe51cef36a0a0d44d9d63a1c4514eb86dd18d0b8903d574 (open the "Logs" tab)
7. `src/StoikovHook.sol` on GitHub, at lines 200 to 219
8. `docs/figures/png/attack-defense.png`

No internet? Use the images in `docs/figures/png/` and the tables in `docs/deployments/sepolia.md`.

### Step 1 (0:00–0:30): What it is

**Show:** the top of the README.

**Say:**
- "Hi, I'm Tony. StoikovHook is a Uniswap v4 hook. It sets swap fees the way a market maker does."
- "Bots take money from LPs when the price moves. We call this LVR."
- "My hook makes the bots pay more in fees. Regular users pay the same on average."

### Step 2 (0:30–1:10): How it works

**Show:** `fee-curve.png`.

**Say:**
- "Every block has two fees. One for swaps that push the price up, one for swaps that push it down."
- "If the price moved away from its average, the swap that pushes it further pays more. The swap that brings it back pays less."
- "When the price moves a lot, both fees go up."

### Step 3 (1:10–2:00): The test results

**Show:** `lp-performance.png`. Point at panel (c), on the right.

**Say:**
- "I tested it in a computer market: 20 runs, 400 blocks each. Every pool sees the same bots and the same users."
- "I compare it with a normal pool that charges users the same average fee. My pool wins in all 20 runs."
- "But the win is small: about 2% of what LPs lose. The bots do not earn less. They just pay more of it back to LPs as fees."

### Step 4 (2:00–2:45): Live on Sepolia

**Show:** the hook page on Etherscan, then the two swap transactions ("Logs" tab).

**Say:**
- "This is the hook on Sepolia. The source code is verified on Etherscan."
- "This swap pushed the price down. It paid 0.20 percent (1,987 pips). The next swap pushed the price up. It paid 0.28 percent (2,799 pips)."
- "The hook's event shows both fees for the block: 0.29 percent up, 0.20 percent down (2,949 and 1,987 pips)."

### Step 5 (2:45–3:30): The code and one safety feature

**Show:** `src/StoikovHook.sol`, lines 200 to 219. Then `attack-defense.png`.

**Say:**
- "The fee is set once per block, at the first swap. No oracle, no admin. It only reads the pool's own price."
- "Why once per block? Without it, a trick inside one block cuts the fee from 0.63 to 0.49 percent (6,302 to 4,933 pips). With it, the trick does nothing."
- "It costs about 3,700 extra gas for most swaps."

### Step 6 (3:30–4:00): Limits and next steps

**Show:** the README, "Limitations" section.

**Say:**
- "The limits: the win is small, and I tuned only one setting. In my test, users do not react to fees."
- "Next: test more kinds of markets, make the fee depend on trade size, and get an audit before mainnet."
- "Thank you. Happy to take questions."

---

## 2. Likely Questions

### Q1. "The effect is so small. Why does it matter?"

- "Yes, it is small. LPs win back about 2% of what they lose (0.16 bps of the pool)."
- "But it wins in all 20 runs, and regular users pay the same average fee."
- "And most settings are not tuned yet. This is a first step."

**Short version: "Small, but it wins every time, and users do not pay more."**

### Q2. "Why no oracle?"

- "An oracle adds trust and delay."
- "Also, with an outside price, the cheap side would be the side the bots trade. The bots would get the discount."
- "So the hook uses the pool's own slow average price."

**Short version: "An outside price would give the discount to the bots."**

### Q3. "How much gas does it add?"

- "Most swaps pay about 3,700 more gas, about 9% more."
- "The first swap in each block does the math. It pays about 14,900 more, about 37% more."
- "On a Layer 2, gas is cheap, so this matters less."

**Short version: "About 9% more for most swaps."**

### Q4. "Can someone trick the volatility number?"

- "Inside one block, no. The fee is fixed for the whole block."
- "To push the fee up, you must really move the price across blocks. That costs you fees, and bots trade against you. You cannot push it down by trading. It only goes down with time."
- "One known limit: a block builder who controls two blocks in a row can move it a little. The gain is limited, and it has a cost."

**Short version: "Tricks inside one block do nothing, and pushing it up costs money."**

### Q5. "How is this different from other dynamic fee hooks?"

- "Many hooks use one fee for both sides. Others need an oracle or a keeper bot."
- "My hook has two fees, one for each direction. It uses only the pool's own price, and the fee is fixed per block."
- "I did not study every other hook, so I talk about types, not names."

**Short version: "Two fees, one per direction, and no oracle."**

### Q6. "Why did you pick 900 seconds for τR?"

- "τR is how long the average price remembers. 900 seconds is 15 minutes."
- "One hour won in my main test, and my own rule said to pick it. But when the trend turned around, one hour lost."
- "So I kept 15 minutes as the safer choice, and I wrote down why. It is not proven to be the best."

**Short version: "One hour won one test and lost the other. 15 minutes was safer."**

### Q7. "What did AI do, and what did you do?"

- "I used Claude to plan and review, and Claude Code to write the code, tests and docs, and to run them. Claude Code also suggested some ideas, like no oracle and the per-block fee. I approved them."
- "I made the main choices: the idea, block-number windows, what the tests must include, and keeping 15 minutes."
- "I checked every change to fees or funds, I held the keys, and I did the Sepolia deploy myself. It is all in AI_USAGE.md."

**Short version: "AI wrote and ran the code. I made the choices and checked every fee change."**

### Q8. "What will you do next?"

- "First, test many more kinds of markets, and tune all the settings."
- "Second, make the fee depend on trade size."
- "Third, get an audit before any mainnet use."

**Short version: "More tests, size-based fees, then an audit."**

### If you did not understand the question

- "Sorry, could you say that again, a bit slower?"
- "Do you mean the gas cost, or the fee?"
- "Good question. The short answer is …"

---

## 3. Key Numbers

Say the first column out loud. The other columns are for checking.

| What | Say | Exact number | Source |
|---|---|---|---|
| Base fee | "0.05 percent" | 500 pips | `README.md:103` |
| Lowest and highest fee | "0.01 percent to 1 percent" | 100 to 10,000 pips | `README.md:134` |
| Test market size | "20 runs, 400 blocks each" | 20 seeds × 400 blocks, 12 s blocks | `README.md:178` |
| LP gain over the same-fee pool | "a tiny gain, in all 20 runs" | +0.160 ± 0.105 bps (0.0016% of the pool), 20 of 20 seeds, t = 6.8 | `README.md:187` |
| Share of LP loss won back | "about 2 percent" | ≈ 2.2% of the loss versus HODL | `README.md:187` |
| Extra fees paid by bots | "bots pay more" | +0.175 bps; regular users: 0.000 ± 0.001 bps difference | `README.md:188` |
| Bot profit | "not lower" | +1.6% | `README.md:202` |
| Bots' share of the value they take | "from 33 to 30 percent" | 32.9% → 30.3% | `README.md:202` |
| When it helps | "only while the price trends" | no gain in the mean-reversion segment | `README.md:203` |
| Average fee users pay | "about 0.22 percent" | 2,198 pips | `README.md:183`; `docs/simulation/README.md:20` |
| LP − HODL by pool | (only if asked) | StoikovHook −7.036, same-fee pool −7.196, 0.05% pool −10.497, 0.30% pool −5.766 bps | `README.md:182-185` |
| Gas, most swaps | "about 3,700, about 9% more" | 3,678 gas | `README.md:168`, `README.md:174` |
| Gas, first swap of a block | "about 14,900, about 37% more" | 14,905 gas | `README.md:169`, `README.md:174` |
| Gas, the same swap with no hook | "about 40,000" | 40,120 gas | `README.md:170` |
| Trick inside one block | "0.63 down to 0.49 percent, 22% lower, without the cache" | 6,302 → 4,933 pips | `README.md:153`, `README.md:160` |
| Sepolia, price-down swap | "0.20 percent" | 1,987 pips | `README.md:325` |
| Sepolia, price-up swap | "0.28 percent" | 2,799 pips | `README.md:326` |
| Sepolia, both fees in one block | "0.29 up, 0.20 down" | 2,949 / 1,987 pips | `README.md:325` |
| Hook address | "ends in 5080" | `0x67b97620e35DAf13de266F84cAbC8c8d45755080` | `README.md:308` |
| Deploy cost | "15 transactions, about 0.0055 ETH" | 15 transactions, 0.0055 ETH | `README.md:300` |
| τR | "15 minutes" | 900 s | `README.md:209`; `docs/simulation/README.md:88` |
| One hour vs 15 minutes, main test | "one hour a little better" | +0.042 ± 0.027 bps, t = 6.9 | `docs/simulation/README.md:91` |
| One hour vs 15 minutes, trend turns around | "one hour worse" | −0.117 ± 0.062 bps, t = −8.5 | `docs/simulation/README.md:102` |
| Tests | "35 tests, fuzz tests up to 5,000 runs" | 35 hook tests, fuzz tests at 1,000–5,000 runs | `README.md:109` |
