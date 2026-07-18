const form = document.getElementById("portfolio-form");
const positionsBody = document.getElementById("positions-body");
const addRowBtn = document.getElementById("add-row");
const resultsSection = document.getElementById("results-section");
const resultsBody = document.getElementById("results-body");
const resultsFoot = document.getElementById("results-foot");
const errorBanner = document.getElementById("error-banner");
const analyzeBtn = document.getElementById("analyze-btn");
const updatedAt = document.getElementById("updated-at");

function formatMoney(value) {
  if (value == null) return "—";
  return new Intl.NumberFormat("en-US", {
    style: "currency",
    currency: "USD",
  }).format(value);
}

function formatPct(value) {
  if (value == null) return "—";
  const sign = value >= 0 ? "+" : "";
  return `${sign}${value.toFixed(2)}%`;
}

function plClass(value) {
  if (value == null || value === 0) return "";
  return value > 0 ? "positive" : "negative";
}

function createRow() {
  const tr = document.createElement("tr");
  tr.className = "position-row";
  tr.innerHTML = `
    <td><input type="text" name="ticker" placeholder="AAPL" required maxlength="10"></td>
    <td><input type="number" name="shares" placeholder="10" min="0.0001" step="any" required></td>
    <td><input type="number" name="purchase_price" placeholder="150.00" min="0.01" step="0.01" required></td>
    <td><button type="button" class="btn btn-ghost remove-row" title="Remove">×</button></td>
  `;
  return tr;
}

function hideError() {
  errorBanner.classList.add("hidden");
  errorBanner.textContent = "";
}

function showError(message) {
  errorBanner.textContent = message;
  errorBanner.classList.remove("hidden");
}

function collectPositions() {
  const rows = positionsBody.querySelectorAll(".position-row");
  const positions = [];

  for (const row of rows) {
    const ticker = row.querySelector('[name="ticker"]').value.trim();
    const shares = parseFloat(row.querySelector('[name="shares"]').value);
    const purchasePrice = parseFloat(row.querySelector('[name="purchase_price"]').value);

    if (!ticker || !shares || !purchasePrice) continue;

    positions.push({
      ticker,
      shares,
      purchase_price: purchasePrice,
    });
  }

  return positions;
}

function renderResults(data) {
  resultsBody.innerHTML = "";

  for (const pos of data.positions) {
    const tr = document.createElement("tr");

    if (pos.error) {
      tr.innerHTML = `
        <td><strong>${pos.ticker}</strong></td>
        <td>${pos.shares}</td>
        <td>${formatMoney(pos.purchase_price)}</td>
        <td>${formatMoney(pos.cost_basis)}</td>
        <td colspan="4" class="error-cell">${pos.error}</td>
      `;
    } else {
      tr.innerHTML = `
        <td><strong>${pos.ticker}</strong></td>
        <td>${pos.shares}</td>
        <td>${formatMoney(pos.purchase_price)}</td>
        <td>${formatMoney(pos.cost_basis)}</td>
        <td>${formatMoney(pos.current_price)}</td>
        <td>${formatMoney(pos.current_value)}</td>
        <td class="${plClass(pos.profit_loss)}">${formatMoney(pos.profit_loss)}</td>
        <td class="${plClass(pos.profit_loss_pct)}">${formatPct(pos.profit_loss_pct)}</td>
      `;
    }

    resultsBody.appendChild(tr);
  }

  resultsFoot.innerHTML = `
    <tr>
      <td colspan="3"><strong>Portfolio total</strong></td>
      <td>${formatMoney(data.total_cost_basis)}</td>
      <td>—</td>
      <td>${formatMoney(data.total_current_value)}</td>
      <td class="${plClass(data.total_profit_loss)}">${formatMoney(data.total_profit_loss)}</td>
      <td class="${plClass(data.total_profit_loss_pct)}">${formatPct(data.total_profit_loss_pct)}</td>
    </tr>
  `;

  updatedAt.textContent = `Updated ${new Date().toLocaleString()}`;
  resultsSection.classList.remove("hidden");
}

addRowBtn.addEventListener("click", () => {
  positionsBody.appendChild(createRow());
});

positionsBody.addEventListener("click", (event) => {
  if (!event.target.classList.contains("remove-row")) return;

  const rows = positionsBody.querySelectorAll(".position-row");
  if (rows.length <= 1) return;

  event.target.closest(".position-row").remove();
});

form.addEventListener("submit", async (event) => {
  event.preventDefault();
  hideError();

  const positions = collectPositions();
  if (positions.length === 0) {
    showError("Add at least one complete position (ticker, shares, and purchase price).");
    return;
  }

  analyzeBtn.disabled = true;
  analyzeBtn.textContent = "Fetching prices…";

  try {
    const response = await fetch("/api/analyze", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ positions }),
    });

    const data = await response.json();

    if (!response.ok) {
      const detail = data.detail;
      const message = Array.isArray(detail)
        ? detail.map((item) => item.msg || item).join(", ")
        : detail || "Failed to analyze portfolio.";
      throw new Error(message);
    }

    renderResults(data);
  } catch (err) {
    showError(err.message || "Something went wrong. Please try again.");
  } finally {
    analyzeBtn.disabled = false;
    analyzeBtn.textContent = "Analyze portfolio";
  }
});
