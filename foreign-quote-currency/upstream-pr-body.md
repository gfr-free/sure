Before: a security quoted in a different currency from the trade or account (e.g. a USD-listed stock in a EUR account) showed its quote unconverted as "Current Market Price" in the trade drawer. The unrealized gain/loss then subtracted the purchase price from that quote as if both were in the same currency. Example: 10 shares bought at €180, quoted at $200, USD→EUR 0.90. The drawer showed **$200.00** and **+$200.00 (+11.1%)**; the correct figures are €180.00 and no change. The holding drawer also showed the quote unconverted next to values in the account currency, and the "convert to trade" security picker compared the quote against the transaction's price without converting it.

After: the quote is converted into the trade's or holding's currency at the quote's date, with the original quote shown next to it: **€180.00 ($200.00)**. The unrealized gain is computed in the trade's currency. When no exchange rate is available, the gain is hidden (unknown rather than wrong), only the original quote is shown, and nothing is converted 1:1.

`Money#-` takes the right operand's bare amount without checking its currency, so `Trade#unrealized_gain_loss` netted `quote × qty` (listing currency) against the cost basis (trade currency) and labelled the result with the quote's currency. This affects every security whose listing currency differs from the trade's; same-currency positions are unchanged.

### How
- New `Security#current_price_in(currency)`: converts the current quote with `Money#exchange_to` at the quote's date (the same way `Holding::PortfolioCache` converts prices), returns `nil` without a rate, and is memoised per currency.
- `Trade#unrealized_gain_loss` uses it.
- New partial `securities/_current_price` shows the converted price plus the original quote. It is used by the trade drawer, the holding drawer and the holding `sync_prices` turbo stream.
- The convert-to-trade picker uses the converted price for its price sanity check. A quote it cannot convert is still shown, but kept out of the check.

This only changes display and the drawer's unrealized gain. Balances, holdings, reports and syncs are unchanged. It is compatible with #2924: once holdings keep their native currency, the conversion becomes a no-op where holding and quote share a currency.

### Screenshots (demo data)
Trade drawer:
![trade](https://raw.githubusercontent.com/gfr-free/sure/pr-screenshots/foreign-quote-currency/1-trade-before-after.png)

Holding drawer:
![holding](https://raw.githubusercontent.com/gfr-free/sure/pr-screenshots/foreign-quote-currency/2-holding-before-after.png)

### Validation
- 6 new tests: `TradeTest` (cross-currency gain, missing rate), `TradesControllerTest`, `HoldingsControllerTest`, and `TransactionsTradeConversionTest` (converted quote, unconvertible quote). All fail without the fix.
- Full `bin/rails test`, `bin/rubocop`, `erb_lint` and `brakeman` are green locally on current `main`.
