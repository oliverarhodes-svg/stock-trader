const tabs = document.querySelectorAll(".tab");
const portfolioPanel = document.getElementById("portfolio-panel");
const researchPanel = document.getElementById("research-panel");
const researchForm = document.getElementById("research-form");
const researchQuery = document.getElementById("research-query");
const researchBtn = document.getElementById("research-btn");
const searchSuggestions = document.getElementById("search-suggestions");
const researchLoading = document.getElementById("research-loading");
const researchError = document.getElementById("research-error");
const researchResults = document.getElementById("research-results");

const CHART_RANGES = [
  { id: "1d", label: "1D", interval: "5m" },
  { id: "5d", label: "5D", interval: "15m" },
  { id: "1mo", label: "1M", interval: "1d" },
  { id: "6mo", label: "6M", interval: "1d" },
  { id: "1y", label: "1Y", interval: "1d" },
  { id: "5y", label: "5Y", interval: "1wk" },
  { id: "max", label: "Max", interval: "1mo" },
];

let priceChart = null;
let currentTicker = null;
let currentRange = "1y";
let searchTimeout = null;

function formatLargeNumber(value) {
  if (value == null || Number.isNaN(value)) return "—";
  const abs = Math.abs(value);
  if (abs >= 1e12) return `$${(value / 1e12).toFixed(2)}T`;
  if (abs >= 1e9) return `$${(value / 1e9).toFixed(2)}B`;
  if (abs >= 1e6) return `$${(value / 1e6).toFixed(2)}M`;
  if (abs >= 1e3) return `$${(value / 1e3).toFixed(2)}K`;
  return new Intl.NumberFormat("en-US", { style: "currency", currency: "USD" }).format(value);
}

function formatMoney(value) {
  if (value == null || Number.isNaN(value)) return "—";
  return new Intl.NumberFormat("en-US", {
    style: "currency",
    currency: "USD",
    maximumFractionDigits: value < 1 ? 4 : 2,
  }).format(value);
}

function formatPct(value, decimals = 2) {
  if (value == null || Number.isNaN(value)) return "—";
  const pct = Math.abs(value) <= 1 ? value * 100 : value;
  const sign = pct >= 0 ? "+" : "";
  return `${sign}${pct.toFixed(decimals)}%`;
}

function formatRatio(value) {
  if (value == null || Number.isNaN(value)) return "—";
  return Number(value).toFixed(2);
}

function formatCount(value) {
  if (value == null || Number.isNaN(value)) return "—";
  return new Intl.NumberFormat("en-US").format(value);
}

function plClass(value) {
  if (value == null || value === 0) return "";
  return value > 0 ? "positive" : "negative";
}

function hideResearchError() {
  researchError.classList.add("hidden");
  researchError.textContent = "";
}

function showResearchError(message) {
  researchError.textContent = message;
  researchError.classList.remove("hidden");
}

function statCard(label, value) {
  return `
    <div class="stat-card">
      <div class="stat-label">${label}</div>
      <div class="stat-value">${value}</div>
    </div>
  `;
}

function renderStatsGrid(container, items) {
  container.innerHTML = items
    .filter((item) => item.value !== "—")
    .map((item) => statCard(item.label, item.value))
    .join("");
}

tabs.forEach((tab) => {
  tab.addEventListener("click", () => {
    tabs.forEach((t) => t.classList.remove("active"));
    tab.classList.add("active");

    const isPortfolio = tab.dataset.tab === "portfolio";
    portfolioPanel.classList.toggle("hidden", !isPortfolio);
    researchPanel.classList.toggle("hidden", isPortfolio);
  });
});

function renderSuggestions(results) {
  if (!results.length) {
    searchSuggestions.classList.add("hidden");
    searchSuggestions.innerHTML = "";
    return;
  }

  searchSuggestions.innerHTML = results
    .map(
      (item) => `
        <button type="button" class="suggestion-item" data-symbol="${item.symbol}">
          <span class="suggestion-symbol">${item.symbol}</span>
          <span class="suggestion-name">${item.name || ""}</span>
          <span class="suggestion-type">${item.type || ""}</span>
        </button>
      `
    )
    .join("");
  searchSuggestions.classList.remove("hidden");
}

searchSuggestions.addEventListener("click", (event) => {
  const button = event.target.closest(".suggestion-item");
  if (!button) return;

  researchQuery.value = button.dataset.symbol;
  searchSuggestions.classList.add("hidden");
  loadResearch(button.dataset.symbol);
});

researchQuery.addEventListener("input", () => {
  clearTimeout(searchTimeout);
  const query = researchQuery.value.trim();

  if (query.length < 1) {
    searchSuggestions.classList.add("hidden");
    return;
  }

  searchTimeout = setTimeout(async () => {
    try {
      const response = await fetch(`/api/research/search?q=${encodeURIComponent(query)}`);
      const data = await response.json();
      if (!response.ok) throw new Error(data.detail || "Search failed");
      renderSuggestions(data.results || []);
    } catch {
      searchSuggestions.classList.add("hidden");
    }
  }, 250);
});

document.addEventListener("click", (event) => {
  if (!event.target.closest(".search-form")) {
    searchSuggestions.classList.add("hidden");
  }
});

function renderChartRangeButtons() {
  const container = document.getElementById("chart-ranges");
  container.innerHTML = CHART_RANGES.map(
    (range) => `
      <button type="button" class="btn btn-secondary range-btn ${range.id === currentRange ? "active" : ""}" data-range="${range.id}">
        ${range.label}
      </button>
    `
  ).join("");

  container.querySelectorAll(".range-btn").forEach((button) => {
    button.addEventListener("click", async () => {
      currentRange = button.dataset.range;
      renderChartRangeButtons();
      await loadChart(currentTicker, currentRange);
    });
  });
}

async function loadChart(ticker, range) {
  const rangeConfig = CHART_RANGES.find((item) => item.id === range) || CHART_RANGES[4];
  const response = await fetch(
    `/api/research/chart?ticker=${encodeURIComponent(ticker)}&range=${rangeConfig.id}&interval=${rangeConfig.interval}`
  );
  const data = await response.json();
  if (!response.ok) throw new Error(data.detail || "Chart failed");

  const labels = data.points.map((point) => point.date);
  const prices = data.points.map((point) => point.price);
  const first = prices[0];
  const last = prices[prices.length - 1];
  const color = last >= first ? "#3dd68c" : "#f87171";

  if (priceChart) priceChart.destroy();

  priceChart = new Chart(document.getElementById("price-chart"), {
    type: "line",
    data: {
      labels,
      datasets: [{
        label: `${ticker} price`,
        data: prices,
        borderColor: color,
        backgroundColor: `${color}22`,
        fill: true,
        tension: 0.2,
        pointRadius: 0,
        borderWidth: 2,
      }],
    },
    options: {
      responsive: true,
      maintainAspectRatio: false,
      plugins: {
        legend: { display: false },
        tooltip: {
          callbacks: {
            label: (ctx) => formatMoney(ctx.parsed.y),
          },
        },
      },
      scales: {
        x: {
          ticks: { color: "#8b9cb3", maxTicksLimit: 8 },
          grid: { color: "rgba(45, 58, 79, 0.5)" },
        },
        y: {
          ticks: {
            color: "#8b9cb3",
            callback: (value) => formatMoney(value),
          },
          grid: { color: "rgba(45, 58, 79, 0.5)" },
        },
      },
    },
  });
}

function renderAnalystBars(consensus) {
  const total =
    (consensus.strong_buy || 0) +
    (consensus.buy || 0) +
    (consensus.hold || 0) +
    (consensus.sell || 0) +
    (consensus.strong_sell || 0);

  const rows = [
    { label: "Strong buy", value: consensus.strong_buy || 0, className: "strong-buy" },
    { label: "Buy", value: consensus.buy || 0, className: "buy" },
    { label: "Hold", value: consensus.hold || 0, className: "hold" },
    { label: "Sell", value: consensus.sell || 0, className: "sell" },
    { label: "Strong sell", value: consensus.strong_sell || 0, className: "strong-sell" },
  ];

  document.getElementById("analyst-bars").innerHTML = rows
    .map((row) => {
      const pct = total ? (row.value / total) * 100 : 0;
      return `
        <div class="analyst-bar-row">
          <span class="analyst-bar-label">${row.label}</span>
          <div class="analyst-bar-track">
            <div class="analyst-bar-fill ${row.className}" style="width: ${pct}%"></div>
          </div>
          <span class="analyst-bar-count">${row.value}</span>
        </div>
      `;
    })
    .join("");
}

function renderResearch(data) {
  currentTicker = data.ticker;
  currentRange = "1y";

  document.getElementById("research-ticker").textContent = data.ticker;
  document.getElementById("research-type").textContent = data.is_etf ? "ETF" : (data.quote_type || "Stock");
  document.getElementById("research-name").textContent = data.name || "";
  document.getElementById("research-meta").textContent = [data.exchange, data.sector, data.industry].filter(Boolean).join(" · ");
  document.getElementById("research-price").textContent = formatMoney(data.price?.current);

  const change = data.price?.change;
  const changePct = data.price?.change_pct;
  const changeEl = document.getElementById("research-change");
  changeEl.textContent = `${formatMoney(change)} (${formatPct(changePct)})`;
  changeEl.className = plClass(change);

  document.getElementById("research-description").textContent = data.description || "No company description available.";

  renderStatsGrid(document.getElementById("key-stats-grid"), [
    { label: "Market cap", value: formatLargeNumber(data.price?.market_cap) },
    { label: "52-wk high", value: formatMoney(data.price?.fifty_two_week_high) },
    { label: "52-wk low", value: formatMoney(data.price?.fifty_two_week_low) },
    { label: "Trailing P/E", value: formatRatio(data.key_stats?.trailing_pe) },
    { label: "Forward P/E", value: formatRatio(data.key_stats?.forward_pe) },
    { label: "PEG ratio", value: formatRatio(data.key_stats?.peg_ratio) },
    { label: "Price / book", value: formatRatio(data.key_stats?.price_to_book) },
    { label: "Price / sales", value: formatRatio(data.key_stats?.price_to_sales) },
    { label: "Beta", value: formatRatio(data.key_stats?.beta) },
    { label: "Dividend yield", value: formatPct(data.key_stats?.dividend_yield) },
    { label: "EPS (trailing)", value: formatMoney(data.key_stats?.trailing_eps) },
    { label: "EPS (forward)", value: formatMoney(data.key_stats?.forward_eps) },
  ]);

  renderStatsGrid(document.getElementById("financials-grid"), [
    { label: "Revenue", value: formatLargeNumber(data.financials?.revenue) },
    { label: "Revenue growth", value: formatPct(data.financials?.revenue_growth) },
    { label: "Free cash flow", value: formatLargeNumber(data.financials?.free_cash_flow) },
    { label: "Operating cash flow", value: formatLargeNumber(data.financials?.operating_cash_flow) },
    { label: "EBITDA", value: formatLargeNumber(data.financials?.ebitda) },
    { label: "Gross margin", value: formatPct(data.financials?.gross_margins) },
    { label: "Operating margin", value: formatPct(data.financials?.operating_margins) },
    { label: "Profit margin", value: formatPct(data.financials?.profit_margins) },
    { label: "Return on equity", value: formatPct(data.financials?.return_on_equity) },
    { label: "Return on assets", value: formatPct(data.financials?.return_on_assets) },
    { label: "Debt / equity", value: formatRatio(data.financials?.debt_to_equity) },
    { label: "Current ratio", value: formatRatio(data.financials?.current_ratio) },
  ]);

  const rec = (data.analysts?.recommendation || "none").replace(/_/g, " ");
  document.getElementById("analyst-summary").innerHTML = `
    ${statCard("Consensus", rec.charAt(0).toUpperCase() + rec.slice(1))}
    ${statCard("Target price", formatMoney(data.analysts?.target_price))}
    ${statCard("Target range", `${formatMoney(data.analysts?.target_low)} – ${formatMoney(data.analysts?.target_high)}`)}
    ${statCard("Analysts covering", formatCount(data.analysts?.num_analysts))}
  `;
  renderAnalystBars(data.analysts?.consensus || {});

  document.getElementById("analyst-actions").innerHTML = (data.analysts?.recent_actions || [])
    .map(
      (row) => `
        <tr>
          <td>${row.date || "—"}</td>
          <td>${row.firm || "—"}</td>
          <td>${row.action || "—"}</td>
          <td>${row.from_grade ? `${row.from_grade} → ${row.to_grade}` : (row.to_grade || "—")}</td>
          <td>${row.price_target ? formatMoney(row.price_target) : "—"}</td>
        </tr>
      `
    )
    .join("") || `<tr><td colspan="5" class="muted">No recent analyst actions available.</td></tr>`;

  document.getElementById("earnings-quarterly").innerHTML = (data.earnings?.quarterly_eps || [])
    .map(
      (row) => `
        <tr>
          <td>${row.period || "—"}</td>
          <td>${formatMoney(row.actual)}</td>
          <td>${formatMoney(row.estimate)}</td>
          <td class="${plClass(row.surprise_pct)}">${row.surprise_pct != null ? formatPct(row.surprise_pct) : "—"}</td>
        </tr>
      `
    )
    .join("") || `<tr><td colspan="4" class="muted">No quarterly earnings data.</td></tr>`;

  document.getElementById("earnings-yearly").innerHTML = (data.earnings?.yearly_financials || [])
    .map(
      (row) => `
        <tr>
          <td>${row.year || "—"}</td>
          <td>${formatLargeNumber(row.revenue)}</td>
          <td>${formatLargeNumber(row.earnings)}</td>
        </tr>
      `
    )
    .join("") || `<tr><td colspan="3" class="muted">No yearly financial data.</td></tr>`;

  document.getElementById("earnings-estimates").innerHTML = (data.earnings?.estimates || [])
    .map(
      (row) => `
        <tr>
          <td>${row.period || "—"}</td>
          <td>${formatMoney(row.avg_estimate)}</td>
          <td>${formatMoney(row.low_estimate)}</td>
          <td>${formatMoney(row.high_estimate)}</td>
          <td>${formatPct(row.growth)}</td>
          <td>${formatCount(row.num_analysts)}</td>
        </tr>
      `
    )
    .join("") || `<tr><td colspan="6" class="muted">No forward estimates available.</td></tr>`;

  const etfSection = document.getElementById("etf-section");
  if (data.is_etf && data.etf) {
    etfSection.classList.remove("hidden");
    document.getElementById("etf-meta").textContent = [
      data.etf.category,
      data.etf.family,
      data.etf.total_assets ? `Assets: ${formatLargeNumber(data.etf.total_assets)}` : null,
    ].filter(Boolean).join(" · ");

    document.getElementById("etf-holdings").innerHTML = (data.etf.holdings || [])
      .map(
        (row) => `
          <tr>
            <td><strong>${row.symbol || "—"}</strong></td>
            <td>${row.name || "—"}</td>
            <td>${row.weight != null ? formatPct(row.weight) : "—"}</td>
          </tr>
        `
      )
      .join("");

    renderStatsGrid(
      document.getElementById("etf-sectors"),
      (data.etf.sector_weightings || []).map((row) => ({
        label: row.sector,
        value: formatPct(row.weight),
      }))
    );
  } else {
    etfSection.classList.add("hidden");
  }

  renderChartRangeButtons();
}

async function loadResearch(ticker) {
  hideResearchError();
  researchResults.classList.add("hidden");
  researchLoading.classList.remove("hidden");
  researchBtn.disabled = true;
  researchBtn.textContent = "Loading…";

  try {
    const response = await fetch(`/api/research/profile?ticker=${encodeURIComponent(ticker)}`);
    const data = await response.json();
    if (!response.ok) throw new Error(data.detail || "Research failed");

    renderResearch(data);
    await loadChart(ticker, currentRange);
    researchResults.classList.remove("hidden");
  } catch (err) {
    showResearchError(err.message || "Could not load research data.");
  } finally {
    researchLoading.classList.add("hidden");
    researchBtn.disabled = false;
    researchBtn.textContent = "Research";
  }
}

researchForm.addEventListener("submit", (event) => {
  event.preventDefault();
  const ticker = researchQuery.value.trim().toUpperCase();
  if (!ticker) {
    showResearchError("Enter a ticker symbol to research.");
    return;
  }
  searchSuggestions.classList.add("hidden");
  loadResearch(ticker);
});

renderChartRangeButtons();
