#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "net/http"
require "uri"
require "webrick"

ROOT = File.expand_path(__dir__)
STATIC = File.expand_path("static", ROOT)
PORT = (ENV["PORT"] || 8000).to_i
FINNHUB_KEY = ENV["FINNHUB_API_KEY"].to_s.strip
FINNHUB_BASE = "https://finnhub.io/api/v1"
$FINNHUB_CACHE = {}

def finnhub_configured?
  !FINNHUB_KEY.empty?
end

def finnhub_symbol(ticker)
  ticker.to_s.strip.upcase.gsub("-", ".")
end

def finnhub_http_get(path, params = {}, cache_ttl: 120)
  raise "Finnhub API key not configured" unless finnhub_configured?

  params = params.merge(token: FINNHUB_KEY)
  query = URI.encode_www_form(params)
  url = "#{FINNHUB_BASE}#{path}?#{query}"
  cache_key = url

  if cache_ttl
    cached = $FINNHUB_CACHE[cache_key]
    return cached[:data] if cached && (Time.now.to_i - cached[:at]) < cache_ttl
  end

  uri = URI(url)
  response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 15, read_timeout: 15) do |http|
    request = Net::HTTP::Get.new(uri)
    request["User-Agent"] = USER_AGENT
    http.request(request)
  end

  unless response.is_a?(Net::HTTPSuccess)
    body = response.body.to_s
    if response.code.to_i == 403
      raise "Finnhub premium endpoint not available on free plan (#{path})"
    end
    raise "Finnhub returned #{response.code}"
  end

  data = JSON.parse(response.body)
  $FINNHUB_CACHE[cache_key] = { at: Time.now.to_i, data: data } if cache_ttl
  data
end

def finnhub_try_get(path, params = {}, cache_ttl: 120)
  finnhub_http_get(path, params, cache_ttl: cache_ttl)
rescue StandardError => e
  warn "Finnhub optional fetch failed #{path}: #{e.message}"
  nil
end

def finnhub_quote(symbol)
  data = finnhub_http_get("/quote", { symbol: finnhub_symbol(symbol) }, cache_ttl: 60)
  price = data["c"]
  raise "No Finnhub price for #{symbol}" if price.nil? || price.zero?

  price.to_f
end

def finnhub_search(query)
  data = finnhub_http_get("/search", { q: query.strip }, cache_ttl: 600)
  (data["result"] || []).first(8).map do |item|
    {
      "symbol" => item["symbol"],
      "name" => item["description"],
      "type" => item["type"],
      "exchange" => item["displaySymbol"]&.split(".")&.last
    }
  end.reject { |item| item["symbol"].nil? }
end

def finnhub_chart_range(range)
  now = Time.now.to_i
  case range
  when "1d" then ["5", now - 86_400, now]
  when "5d" then ["15", now - 5 * 86_400, now]
  when "1mo" then ["D", now - 30 * 86_400, now]
  when "6mo" then ["D", now - 180 * 86_400, now]
  when "1y" then ["D", now - 365 * 86_400, now]
  when "5y" then ["W", now - 5 * 365 * 86_400, now]
  when "max" then ["M", now - 20 * 365 * 86_400, now]
  else ["D", now - 365 * 86_400, now]
  end
end

def finnhub_chart(ticker, range)
  symbol = finnhub_symbol(ticker)
  resolution, from, to = finnhub_chart_range(range)
  data = finnhub_http_get("/stock/candle", { symbol: symbol, resolution: resolution, from: from, to: to }, cache_ttl: 120)
  raise "No Finnhub chart data for #{ticker}" unless data["s"] == "ok"

  points = (data["t"] || []).each_with_index.map do |ts, index|
    price = data["c"][index]
    next if price.nil?

    {
      "date" => Time.at(ts).utc.strftime("%Y-%m-%d"),
      "timestamp" => ts,
      "price" => price.round(2)
    }
  end.compact

  {
    "ticker" => ticker.upcase,
    "range" => range,
    "interval" => resolution,
    "currency" => "USD",
    "points" => points
  }
rescue StandardError => e
  warn "Finnhub chart unavailable, falling back to Yahoo: #{e.message}"
  fetch_yahoo_chart(ticker, range, chart_interval_for_range(range))
end

def chart_interval_for_range(range)
  case range
  when "1d" then "5m"
  when "5d" then "15m"
  when "1y", "6mo", "1mo", "3mo" then "1d"
  when "5y" then "1wk"
  when "max" then "1mo"
  else "1d"
  end
end

def fetch_chart(ticker, range, interval)
  if finnhub_configured?
    begin
      return finnhub_chart(ticker, range)
    rescue StandardError => e
      warn "Chart fetch failed: #{e.message}"
    end
  end

  fetch_yahoo_chart(ticker, range, interval)
end

def finnhub_metric_value(metrics, key)
  value = metrics&.dig("metric", key)
  value.nil? ? nil : value
end

def build_research_profile_finnhub(ticker)
  symbol = finnhub_symbol(ticker)
  quote = finnhub_http_get("/quote", { symbol: symbol }, cache_ttl: 60)
  profile = finnhub_try_get("/stock/profile2", { symbol: symbol }, cache_ttl: 3600) || {}
  metrics = finnhub_try_get("/stock/metric", { symbol: symbol, metric: "all" }, cache_ttl: 3600) || {}
  recommendations = finnhub_try_get("/stock/recommendation", { symbol: symbol }, cache_ttl: 3600) || []
  earnings = finnhub_try_get("/stock/earnings", { symbol: symbol }, cache_ttl: 3600) || []

  etf_profile = finnhub_try_get("/etf/profile", { symbol: symbol }, cache_ttl: 3600)
  is_etf = !etf_profile.nil?

  current_rec = recommendations.first || {}
  metric = metrics["metric"] || {}

  quarterly_eps = (earnings || []).first(8).map do |row|
    surprise = row["surprise"]
    {
      "period" => row["period"],
      "actual" => row["actual"],
      "estimate" => row["estimate"],
      "surprise_pct" => surprise,
      "reported_date" => row["period"]
    }
  end

  response = {
    "ticker" => ticker.upcase,
    "name" => profile["name"] || ticker.upcase,
    "quote_type" => is_etf ? "ETF" : "EQUITY",
    "is_etf" => !!is_etf,
    "exchange" => profile["exchange"],
    "sector" => profile["finnhubIndustry"],
    "industry" => profile["finnhubIndustry"],
    "website" => profile["weburl"],
    "description" => profile["name"] ? "#{profile["name"]} (#{profile["exchange"]}). Data provided by Finnhub." : nil,
    "price" => {
      "current" => quote["c"],
      "change" => quote["d"],
      "change_pct" => quote["dp"],
      "previous_close" => quote["pc"],
      "open" => quote["o"],
      "day_high" => quote["h"],
      "day_low" => quote["l"],
      "volume" => nil,
      "market_cap" => profile["marketCapitalization"] ? profile["marketCapitalization"] * 1_000_000 : nil,
      "fifty_two_week_low" => finnhub_metric_value(metrics, "52WeekLow"),
      "fifty_two_week_high" => finnhub_metric_value(metrics, "52WeekHigh"),
      "currency" => profile["currency"] || "USD"
    },
    "key_stats" => {
      "trailing_pe" => finnhub_metric_value(metrics, "peBasicExclExtraTTM"),
      "forward_pe" => finnhub_metric_value(metrics, "peNormalizedAnnual"),
      "peg_ratio" => finnhub_metric_value(metrics, "pegRatio"),
      "price_to_book" => finnhub_metric_value(metrics, "pbAnnual"),
      "price_to_sales" => finnhub_metric_value(metrics, "psAnnual"),
      "enterprise_value" => finnhub_metric_value(metrics, "enterpriseValue"),
      "ev_to_revenue" => finnhub_metric_value(metrics, "evRevenueTTM"),
      "ev_to_ebitda" => finnhub_metric_value(metrics, "evEbitdaTTM"),
      "beta" => finnhub_metric_value(metrics, "beta"),
      "dividend_yield" => finnhub_metric_value(metrics, "dividendYieldIndicatedAnnual"),
      "trailing_eps" => finnhub_metric_value(metrics, "epsBasicExclExtraItemsTTM"),
      "forward_eps" => finnhub_metric_value(metrics, "epsGrowth3Y"),
      "book_value" => finnhub_metric_value(metrics, "bookValuePerShareAnnual"),
      "shares_outstanding" => profile["shareOutstanding"] ? profile["shareOutstanding"] * 1_000_000 : nil
    },
    "financials" => {
      "revenue" => finnhub_metric_value(metrics, "revenuePerShareTTM"),
      "revenue_per_share" => finnhub_metric_value(metrics, "revenuePerShareTTM"),
      "revenue_growth" => finnhub_metric_value(metrics, "revenueGrowthTTMYoy"),
      "gross_margins" => finnhub_metric_value(metrics, "grossMarginTTM"),
      "operating_margins" => finnhub_metric_value(metrics, "operatingMarginTTM"),
      "profit_margins" => finnhub_metric_value(metrics, "netProfitMarginTTM"),
      "ebitda" => finnhub_metric_value(metrics, "ebitdaTTM"),
      "free_cash_flow" => finnhub_metric_value(metrics, "freeCashFlowTTM"),
      "operating_cash_flow" => finnhub_metric_value(metrics, "cashFlowPerShareTTM"),
      "total_cash" => finnhub_metric_value(metrics, "totalCashPerShareAnnual"),
      "total_debt" => finnhub_metric_value(metrics, "totalDebt/totalEquityAnnual"),
      "debt_to_equity" => finnhub_metric_value(metrics, "totalDebt/totalEquityAnnual"),
      "current_ratio" => finnhub_metric_value(metrics, "currentRatioAnnual"),
      "return_on_equity" => finnhub_metric_value(metrics, "roeTTM"),
      "return_on_assets" => finnhub_metric_value(metrics, "roaTTM"),
      "recommendation" => nil
    },
    "analysts" => {
      "recommendation" => nil,
      "target_price" => finnhub_metric_value(metrics, "targetMedianPrice"),
      "target_high" => finnhub_metric_value(metrics, "targetHighPrice"),
      "target_low" => finnhub_metric_value(metrics, "targetLowPrice"),
      "num_analysts" => finnhub_metric_value(metrics, "numberOfAnalystOpinions"),
      "consensus" => {
        "strong_buy" => current_rec["strongBuy"],
        "buy" => current_rec["buy"],
        "hold" => current_rec["hold"],
        "sell" => current_rec["sell"],
        "strong_sell" => current_rec["strongSell"]
      },
      "recent_actions" => []
    },
    "earnings" => {
      "quarterly_eps" => quarterly_eps,
      "quarterly_financials" => [],
      "yearly_financials" => [],
      "estimates" => []
    }
  }

  if is_etf
    etf_holdings = finnhub_try_get("/etf/holdings", { symbol: symbol }, cache_ttl: 3600) || {}
    holdings = (etf_holdings["holdings"] || []).first(25).map do |h|
      {
        "symbol" => h["symbol"],
        "name" => h["name"],
        "weight" => h["percent"]
      }
    end

    response["etf"] = {
      "category" => etf_profile["investmentSegment"],
      "family" => etf_profile["family"],
      "legal_type" => etf_profile["type"],
      "total_assets" => etf_profile["aum"],
      "holdings_count" => holdings.length,
      "holdings" => holdings,
      "sector_weightings" => []
    }
  end

  response
end

def finnhub_setup_message
  "Yahoo Finance is blocking this server. Add a free Finnhub API key: sign up at finnhub.io, copy your API key, then in Render go to Settings → Environment → add FINNHUB_API_KEY."
end

def static_file(relative_path)
  relative_path = relative_path.sub(%r{\A/}, "")
  candidates = [
    File.expand_path(relative_path, STATIC),
    File.expand_path(relative_path, ROOT),
  ]

  candidates.find do |path|
    path.start_with?(ROOT) && File.file?(path)
  end
end

def serve_file(res, path)
  res.status = 200
  res["Content-Type"] = content_type(path)
  res.body = File.read(path)
end

def not_found(res, detail = "Not found")
  res.status = 404
  res["Content-Type"] = "text/plain"
  res.body = detail
end

def json_response(res, status, body)
  res.status = status
  res["Content-Type"] = "application/json"
  res.body = JSON.generate(body)
end

def read_body(req)
  body = req.body
  return {} if body.nil? || body.empty?

  JSON.parse(body)
rescue JSON::ParserError
  nil
end

USER_AGENT = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
$YAHOO_SESSION = { cookie: nil, crumb: nil, fetched_at: 0 }
$YAHOO_CACHE = {}
$YAHOO_PRICE_CACHE = {}
$YAHOO_MUTEX = Mutex.new
$YAHOO_LAST_REQUEST_AT = 0.0
SESSION_TTL = 1800
PRICE_CACHE_TTL = 180
MIN_YAHOO_GAP = 1.0

def yahoo_throttle!
  now = Time.now.to_f
  wait = MIN_YAHOO_GAP - (now - $YAHOO_LAST_REQUEST_AT)
  sleep(wait) if wait.positive?
  $YAHOO_LAST_REQUEST_AT = Time.now.to_f
end

def yahoo_http_request(uri, cookie: nil)
  request = Net::HTTP::Get.new(uri)
  request["User-Agent"] = USER_AGENT
  request["Accept"] = "application/json,text/plain,*/*"
  request["Referer"] = "https://finance.yahoo.com/"
  request["Origin"] = "https://finance.yahoo.com"
  request["Cookie"] = cookie if cookie && !cookie.empty?

  Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 15, read_timeout: 15) do |http|
    http.request(request)
  end
end

def yahoo_http_get(url, cookie: nil, cache_ttl: 90)
  cache_key = "#{url}|#{cookie}"
  if cache_ttl
    cached = $YAHOO_CACHE[cache_key]
    return cached[:data] if cached && (Time.now.to_i - cached[:at]) < cache_ttl
  end

  last_code = nil
  5.times do |attempt|
    yahoo_throttle!
    response = yahoo_http_request(URI(url), cookie: cookie)

    if response.is_a?(Net::HTTPSuccess)
      data = JSON.parse(response.body)
      $YAHOO_CACHE[cache_key] = { at: Time.now.to_i, data: data } if cache_ttl
      return data
    end

    last_code = response.code.to_i
    sleep(2.0 * (attempt + 1) + rand * 0.75) if last_code == 429 && attempt < 4
  end

  raise "Yahoo Finance returned #{last_code || "error"}"
end

def yahoo_http_get_safe(url, cookie: nil, cache_ttl: 90)
  $YAHOO_MUTEX.synchronize do
    yahoo_http_get(url, cookie: cookie, cache_ttl: cache_ttl)
  end
end

def collect_cookies(response)
  cookies = []
  cookies << response["Set-Cookie"].split(";").first if response["Set-Cookie"]
  response.get_fields("Set-Cookie")&.each do |entry|
    cookies << entry.split(";").first
  end
  cookies
end

def fetch_yahoo_cookies
  cookies = []

  ["https://finance.yahoo.com/", "https://fc.yahoo.com/"].each do |url|
    yahoo_throttle!
    response = yahoo_http_request(URI(url))
    cookies.concat(collect_cookies(response))
  rescue StandardError
    next
  end

  cookies.uniq.join("; ")
end

def fetch_yahoo_crumb(cookie)
  [0, 1, 2].each do |attempt|
    yahoo_throttle!
    response = yahoo_http_request(URI("https://query1.finance.yahoo.com/v1/test/getcrumb"), cookie: cookie)
    return response.body.strip if response.is_a?(Net::HTTPSuccess)

    sleep(2 + attempt) if response.code.to_i == 429
  end

  yahoo_throttle!
  response = yahoo_http_request(URI("https://query2.finance.yahoo.com/v1/test/getcrumb"), cookie: cookie)
  return response.body.strip if response.is_a?(Net::HTTPSuccess)

  nil
end

def yahoo_session_unlocked(force: false)
  now = Time.now.to_i
  unless force
    cached = $YAHOO_SESSION
    if cached[:crumb] && !cached[:crumb].empty? && (now - cached[:fetched_at]) < SESSION_TTL
      return { cookie: cached[:cookie], crumb: cached[:crumb] }
    end
  end

  cookie = fetch_yahoo_cookies
  raise "Could not fetch Yahoo cookies" if cookie.nil? || cookie.empty?

  crumb = fetch_yahoo_crumb(cookie)
  raise "Could not fetch Yahoo session" if crumb.nil? || crumb.empty?

  $YAHOO_SESSION = { cookie: cookie, crumb: crumb, fetched_at: now }
  { cookie: cookie, crumb: crumb }
end

def yahoo_session(force: false)
  $YAHOO_MUTEX.synchronize { yahoo_session_unlocked(force: force) }
end

def yahoo_quote_summary(ticker, modules)
  last_error = nil

  2.times do |attempt|
    session = yahoo_session(force: attempt.positive?)
    module_list = modules.join(",")
    encoded_crumb = URI.encode_www_form_component(session[:crumb])
    url = "https://query1.finance.yahoo.com/v10/finance/quoteSummary/#{ticker}?modules=#{module_list}&crumb=#{encoded_crumb}"
    data = yahoo_http_get_safe(url, cookie: session[:cookie], cache_ttl: 300)
    result = data.dig("quoteSummary", "result", 0)
    return result unless result.nil?

    last_error = "No data found for #{ticker}"
  rescue StandardError => e
    last_error = e.message
    $YAHOO_SESSION[:fetched_at] = 0
  end

  raise last_error || "Could not fetch quote summary for #{ticker}"
end

def yahoo_search(query)
  return finnhub_search(query) if finnhub_configured?

  encoded = URI.encode_www_form_component(query.strip)
  urls = [
    "https://query2.finance.yahoo.com/v1/finance/search?q=#{encoded}&quotesCount=8&newsCount=0",
    "https://query1.finance.yahoo.com/v1/finance/search?q=#{encoded}&quotesCount=8&newsCount=0",
  ]

  last_error = nil
  urls.each do |url|
    data = yahoo_http_get_safe(url, cache_ttl: 600)
    quotes = data["quotes"] || []
    return quotes.map do |q|
      {
        "symbol" => q["symbol"],
        "name" => q["shortname"] || q["longname"],
        "type" => q["quoteType"],
        "exchange" => q["exchange"]
      }
    end.reject { |q| q["symbol"].nil? }
  rescue StandardError => e
    last_error = e.message
    next
  end

  warn "Search failed: #{last_error}" if last_error
  []
end

def yahoo_chart(ticker, range, interval)
  fetch_yahoo_chart(ticker, range, interval)
end

def fetch_yahoo_chart(ticker, range, interval)
  url = "https://query1.finance.yahoo.com/v8/finance/chart/#{encoded_ticker}?range=#{range}&interval=#{interval}&includePrePost=false"
  data = yahoo_http_get_safe(url, cache_ttl: 120)
  result = data.dig("chart", "result", 0)
  raise "No chart data for #{ticker}" if result.nil?

  timestamps = result["timestamp"] || []
  closes = result.dig("indicators", "quote", 0, "close") || []
  meta = result["meta"] || {}

  points = timestamps.each_with_index.map do |ts, i|
    price = closes[i]
    next if price.nil?

    {
      "date" => Time.at(ts).utc.strftime("%Y-%m-%d"),
      "timestamp" => ts,
      "price" => price.round(2)
    }
  end.compact

  {
    "ticker" => ticker.upcase,
    "range" => range,
    "interval" => interval,
    "currency" => meta["currency"],
    "points" => points
  }
end

def yahoo_value(obj, key)
  return nil if obj.nil?

  node = obj[key]
  return nil if node.nil?

  node["raw"].nil? ? node["fmt"] : node["raw"]
end

def build_research_profile(ticker)
  symbol = ticker.upcase.strip
  return build_research_profile_finnhub(symbol) if finnhub_configured?

  build_research_profile_from_summary(symbol)
rescue StandardError => e
  warn "Research fallback for #{symbol}: #{e.message}"
  begin
    build_fallback_profile(symbol, e.message)
  rescue StandardError
    raise finnhub_setup_message
  end
end

def yahoo_chart_meta(ticker)
  data = yahoo_http_get_safe("https://query1.finance.yahoo.com/v8/finance/chart/#{ticker}?range=1d&interval=1d&includePrePost=false", cache_ttl: 120)
  meta = data.dig("chart", "result", 0, "meta")
  raise "No chart data for #{ticker}" if meta.nil?

  meta
end

def build_fallback_profile(symbol, error_message)
  meta = yahoo_chart_meta(symbol)
  quote_type = meta["instrumentType"]
  is_etf = quote_type.to_s.upcase == "ETF"
  current = meta["regularMarketPrice"]
  previous = meta["chartPreviousClose"]
  change = current && previous ? (current - previous).round(2) : nil
  change_pct = change && previous && previous != 0 ? ((change / previous) * 100).round(2) : nil

  {
    "ticker" => symbol,
    "name" => meta["longName"] || meta["shortName"] || symbol,
    "quote_type" => quote_type,
    "is_etf" => is_etf,
    "exchange" => meta["exchangeName"] || meta["fullExchangeName"],
    "sector" => nil,
    "industry" => nil,
    "website" => nil,
    "description" => "Some detailed data is temporarily unavailable from Yahoo Finance. Price and chart data are still shown below.",
    "partial_data" => true,
    "warning" => error_message,
    "price" => {
      "current" => current,
      "change" => change,
      "change_pct" => change_pct,
      "previous_close" => previous,
      "open" => nil,
      "day_high" => meta["regularMarketDayHigh"],
      "day_low" => meta["regularMarketDayLow"],
      "volume" => meta["regularMarketVolume"],
      "market_cap" => nil,
      "fifty_two_week_low" => meta["fiftyTwoWeekLow"],
      "fifty_two_week_high" => meta["fiftyTwoWeekHigh"],
      "currency" => meta["currency"]
    },
    "key_stats" => {},
    "financials" => {},
    "analysts" => {
      "recommendation" => nil,
      "target_price" => nil,
      "target_high" => nil,
      "target_low" => nil,
      "num_analysts" => nil,
      "consensus" => {},
      "recent_actions" => []
    },
    "earnings" => {
      "quarterly_eps" => [],
      "quarterly_financials" => [],
      "yearly_financials" => [],
      "estimates" => []
    }
  }
end

def build_research_profile_from_summary(symbol)
  base_modules = %w[
    price summaryDetail assetProfile summaryProfile financialData defaultKeyStatistics
    recommendationTrend earnings earningsHistory earningsTrend upgradeDowngradeHistory
  ]
  etf_modules = %w[topHoldings fundProfile]
  data = yahoo_quote_summary(symbol, base_modules + etf_modules)

  quote_type = data.dig("price", "quoteType") || data.dig("summaryProfile", "quoteType")
  is_etf = quote_type.to_s.upcase == "ETF"

  profile = data["assetProfile"] || data["summaryProfile"] || {}
  price = data["price"] || {}
  summary = data["summaryDetail"] || {}
  financial = data["financialData"] || {}
  stats = data["defaultKeyStatistics"] || {}

  rec_trends = data.dig("recommendationTrend", "trend") || []
  current_rec = rec_trends.find { |t| t["period"] == "0m" } || rec_trends.first || {}

  quarterly_earnings = (data.dig("earnings", "earningsChart", "quarterly") || []).map do |row|
    {
      "period" => row["calendarQuarter"] || row["fiscalQuarter"] || row["date"],
      "actual" => yahoo_value(row, "actual"),
      "estimate" => yahoo_value(row, "estimate"),
      "surprise_pct" => row["surprisePct"]&.to_f,
      "reported_date" => yahoo_value(row, "reportedDate")
    }
  end

  yearly_financials = (data.dig("earnings", "financialsChart", "yearly") || []).map do |row|
    {
      "year" => row["date"],
      "revenue" => yahoo_value(row, "revenue"),
      "earnings" => yahoo_value(row, "earnings")
    }
  end

  quarterly_revenue = (data.dig("earnings", "financialsChart", "quarterly") || []).map do |row|
    {
      "period" => row["date"],
      "revenue" => yahoo_value(row, "revenue"),
      "earnings" => yahoo_value(row, "earnings")
    }
  end

  earnings_estimates = (data.dig("earningsTrend", "trend") || []).map do |row|
    {
      "period" => row["period"],
      "growth" => yahoo_value(row, "growth"),
      "avg_estimate" => yahoo_value(row.dig("earningsEstimate") || {}, "avg"),
      "low_estimate" => yahoo_value(row.dig("earningsEstimate") || {}, "low"),
      "high_estimate" => yahoo_value(row.dig("earningsEstimate") || {}, "high"),
      "num_analysts" => yahoo_value(row.dig("earningsEstimate") || {}, "numberOfAnalysts")
    }
  end

  analyst_actions = (data.dig("upgradeDowngradeHistory", "history") || []).first(8).map do |row|
    {
      "firm" => row["firm"],
      "action" => row["action"],
      "from_grade" => row["fromGrade"],
      "to_grade" => row["toGrade"],
      "price_target" => row["currentPriceTarget"],
      "prior_price_target" => row["priorPriceTarget"],
      "date" => row["epochGradeDate"] ? Time.at(row["epochGradeDate"]).utc.strftime("%Y-%m-%d") : nil
    }
  end

  response = {
    "ticker" => symbol,
    "name" => price["longName"] || price["shortName"] || profile["longName"] || symbol,
    "quote_type" => quote_type,
    "is_etf" => is_etf,
    "exchange" => price["exchangeName"] || profile["exchange"],
    "sector" => profile["sector"],
    "industry" => profile["industry"],
    "website" => profile["website"],
    "description" => profile["longBusinessSummary"],
    "price" => {
      "current" => yahoo_value(price, "regularMarketPrice"),
      "change" => yahoo_value(price, "regularMarketChange"),
      "change_pct" => yahoo_value(price, "regularMarketChangePercent"),
      "previous_close" => yahoo_value(price, "regularMarketPreviousClose"),
      "open" => yahoo_value(price, "regularMarketOpen"),
      "day_high" => yahoo_value(price, "regularMarketDayHigh"),
      "day_low" => yahoo_value(price, "regularMarketDayLow"),
      "volume" => yahoo_value(price, "regularMarketVolume"),
      "market_cap" => yahoo_value(summary, "marketCap"),
      "fifty_two_week_low" => yahoo_value(summary, "fiftyTwoWeekLow"),
      "fifty_two_week_high" => yahoo_value(summary, "fiftyTwoWeekHigh"),
      "currency" => price["currency"] || summary["currency"]
    },
    "key_stats" => {
      "trailing_pe" => yahoo_value(summary, "trailingPE"),
      "forward_pe" => yahoo_value(stats, "forwardPE"),
      "peg_ratio" => yahoo_value(stats, "pegRatio"),
      "price_to_book" => yahoo_value(stats, "priceToBook"),
      "price_to_sales" => yahoo_value(summary, "priceToSalesTrailing12Months"),
      "enterprise_value" => yahoo_value(stats, "enterpriseValue"),
      "ev_to_revenue" => yahoo_value(stats, "enterpriseToRevenue"),
      "ev_to_ebitda" => yahoo_value(stats, "enterpriseToEbitda"),
      "beta" => yahoo_value(summary, "beta"),
      "dividend_yield" => yahoo_value(summary, "dividendYield"),
      "trailing_eps" => yahoo_value(stats, "trailingEps"),
      "forward_eps" => yahoo_value(stats, "forwardEps"),
      "book_value" => yahoo_value(stats, "bookValue"),
      "shares_outstanding" => yahoo_value(stats, "sharesOutstanding")
    },
    "financials" => {
      "revenue" => yahoo_value(financial, "totalRevenue"),
      "revenue_per_share" => yahoo_value(financial, "revenuePerShare"),
      "revenue_growth" => yahoo_value(financial, "revenueGrowth"),
      "gross_margins" => yahoo_value(financial, "grossMargins"),
      "operating_margins" => yahoo_value(financial, "operatingMargins"),
      "profit_margins" => yahoo_value(financial, "profitMargins"),
      "ebitda" => yahoo_value(financial, "ebitda"),
      "free_cash_flow" => yahoo_value(financial, "freeCashflow"),
      "operating_cash_flow" => yahoo_value(financial, "operatingCashflow"),
      "total_cash" => yahoo_value(financial, "totalCash"),
      "total_debt" => yahoo_value(financial, "totalDebt"),
      "debt_to_equity" => yahoo_value(financial, "debtToEquity"),
      "current_ratio" => yahoo_value(financial, "currentRatio"),
      "return_on_equity" => yahoo_value(financial, "returnOnEquity"),
      "return_on_assets" => yahoo_value(financial, "returnOnAssets"),
      "recommendation" => financial["recommendationKey"]
    },
    "analysts" => {
      "recommendation" => financial["recommendationKey"],
      "target_price" => yahoo_value(financial, "targetMeanPrice"),
      "target_high" => yahoo_value(financial, "targetHighPrice"),
      "target_low" => yahoo_value(financial, "targetLowPrice"),
      "num_analysts" => yahoo_value(financial, "numberOfAnalystOpinions"),
      "consensus" => {
        "strong_buy" => current_rec["strongBuy"],
        "buy" => current_rec["buy"],
        "hold" => current_rec["hold"],
        "sell" => current_rec["sell"],
        "strong_sell" => current_rec["strongSell"]
      },
      "recent_actions" => analyst_actions
    },
    "earnings" => {
      "quarterly_eps" => quarterly_earnings,
      "quarterly_financials" => quarterly_revenue,
      "yearly_financials" => yearly_financials,
      "estimates" => earnings_estimates
    }
  }

  if is_etf
    fund = data["fundProfile"] || {}
    holdings = data.dig("topHoldings", "holdings") || []
    sectors = data.dig("topHoldings", "sectorWeightings") || []

    response["etf"] = {
      "category" => fund["categoryName"],
      "family" => fund["family"],
      "legal_type" => fund["legalType"],
      "total_assets" => yahoo_value(data.dig("topHoldings") || {}, "totalAssets"),
      "holdings_count" => (data.dig("topHoldings", "holdings") || []).length,
      "holdings" => holdings.map do |h|
        weight = h["holdingPercent"]
        weight = weight["raw"] if weight.is_a?(Hash)

        {
          "symbol" => h["symbol"],
          "name" => h["holdingName"],
          "weight" => weight
        }
      end,
      "sector_weightings" => sectors.map do |s|
        {
          "sector" => s.keys.first,
          "weight" => s.values.first
        }
      end
    }
  end

  response
end

def query_param(uri, key)
  return nil if uri.query.nil?

  URI.decode_www_form(uri.query).to_h[key]
end

def cache_price(symbol, price)
  $YAHOO_PRICE_CACHE[symbol] = { price: price, at: Time.now.to_i }
end

def cached_price(symbol)
  entry = $YAHOO_PRICE_CACHE[symbol]
  return entry[:price] if entry && (Time.now.to_i - entry[:at]) < PRICE_CACHE_TTL

  nil
end

def fetch_quote_from_chart(symbol, use_mutex: true)
  cached = cached_price(symbol)
  return cached if cached

  encoded = URI.encode_www_form_component(symbol)
  url = "https://query1.finance.yahoo.com/v8/finance/chart/#{encoded}?interval=1d&range=1d&includePrePost=false"
  data = if use_mutex
           yahoo_http_get_safe(url, cache_ttl: 120)
         else
           yahoo_http_get(url, cache_ttl: 120)
         end
  meta = data.dig("chart", "result", 0, "meta")
  price = meta&.[]("regularMarketPrice") || meta&.[]("chartPreviousClose")
  raise "No price for #{symbol}" if price.nil?

  price = price.to_f
  cache_price(symbol, price)
  price
end

def fetch_quotes_batch(symbols)
  symbols = symbols.map { |s| s.to_s.strip.upcase }.reject(&:empty?).uniq
  prices = {}

  symbols.each do |symbol|
    cached = cached_price(symbol)
    prices[symbol] = cached if cached
  end

  missing = symbols - prices.keys
  return prices if missing.empty?

  if finnhub_configured?
    missing.each do |symbol|
      next if prices[symbol]

      begin
        prices[symbol] = finnhub_quote(symbol)
        cache_price(symbol, prices[symbol])
      rescue StandardError => e
        warn "Finnhub quote failed for #{symbol}: #{e.message}"
      end
    end
    return prices
  end

  $YAHOO_MUTEX.synchronize do
    missing.each do |symbol|
      next if prices[symbol]

      begin
        prices[symbol] = fetch_quote_from_chart(symbol, use_mutex: false)
      rescue StandardError => e
        warn "Chart quote failed for #{symbol}: #{e.message}"
      end
    end
  end

  prices
end

def fetch_current_price(ticker)
  symbol = ticker.upcase.strip
  price = fetch_quotes_batch([symbol])[symbol]
  raise "Could not determine current price for #{symbol}" if price.nil?

  price
end

def analyze_position(position, prices = nil)
  ticker = position["ticker"].to_s.strip.upcase
  shares = position["shares"].to_f
  purchase_price = position["purchase_price"].to_f
  cost_basis = (shares * purchase_price).round(2)

  begin
    current_price = prices ? prices[ticker] : fetch_current_price(ticker)
    raise "Could not determine current price for #{ticker}" if current_price.nil?

    current_value = (shares * current_price).round(2)
    profit_loss = (current_value - cost_basis).round(2)
    profit_loss_pct = cost_basis.zero? ? 0.0 : ((profit_loss / cost_basis) * 100).round(2)

    {
      "ticker" => ticker,
      "shares" => shares,
      "purchase_price" => purchase_price,
      "cost_basis" => cost_basis,
      "current_price" => current_price.round(2),
      "current_value" => current_value,
      "profit_loss" => profit_loss,
      "profit_loss_pct" => profit_loss_pct,
      "error" => nil
    }
  rescue StandardError => e
    {
      "ticker" => ticker,
      "shares" => shares,
      "purchase_price" => purchase_price,
      "cost_basis" => cost_basis,
      "current_price" => nil,
      "current_value" => nil,
      "profit_loss" => nil,
      "profit_loss_pct" => nil,
      "error" => e.message
    }
  end
end

def analyze_portfolio(positions)
  tickers = positions.map { |p| p["ticker"].to_s.strip.upcase }
  prices = fetch_quotes_batch(tickers)
  results = positions.map { |p| analyze_position(p, prices) }
  priced = results.select { |r| r["current_value"] }

  if priced.empty?
    detail = finnhub_configured? ? "Could not fetch prices for any positions." : finnhub_setup_message
    raise detail
  end

  total_cost = results.sum { |r| r["cost_basis"] }.round(2)
  total_value = priced.sum { |r| r["current_value"] }.round(2)
  priced_cost = priced.sum { |r| r["cost_basis"] }
  total_pl = (total_value - priced_cost).round(2)
  total_pl_pct = priced_cost.zero? ? 0.0 : ((total_pl / priced_cost) * 100).round(2)

  {
    "positions" => results,
    "total_cost_basis" => total_cost,
    "total_current_value" => total_value,
    "total_profit_loss" => total_pl,
    "total_profit_loss_pct" => total_pl_pct
  }
end

def content_type(path)
  case File.extname(path)
  when ".html" then "text/html; charset=utf-8"
  when ".css" then "text/css; charset=utf-8"
  when ".js" then "application/javascript; charset=utf-8"
  when ".json" then "application/json; charset=utf-8"
  else "application/octet-stream"
  end
end

server = WEBrick::HTTPServer.new(
  Port: PORT,
  BindAddress: ENV.fetch("HOST", "0.0.0.0"),
  AccessLog: [],
  Logger: WEBrick::Log.new($stderr, WEBrick::Log::INFO)
)

server.mount_proc "/api/analyze" do |req, res|
  if req.request_method != "POST"
    json_response(res, 405, { "detail" => "Method not allowed" })
    next
  end

  payload = read_body(req)
  if payload.nil?
    json_response(res, 400, { "detail" => "Invalid JSON body" })
    next
  end

  positions = payload["positions"]
  if positions.nil? || !positions.is_a?(Array) || positions.empty?
    json_response(res, 422, { "detail" => "Provide at least one position." })
    next
  end

  positions.each do |p|
    if p["ticker"].to_s.strip.empty? || p["shares"].to_f <= 0 || p["purchase_price"].to_f <= 0
      json_response(res, 422, { "detail" => "Each position needs ticker, shares > 0, and purchase_price > 0." })
      next
    end
  end

  begin
    json_response(res, 200, analyze_portfolio(positions))
  rescue StandardError => e
    json_response(res, 422, { "detail" => e.message })
  end
end

server.mount_proc "/api/research/search" do |req, res|
  if req.request_method != "GET"
    json_response(res, 405, { "detail" => "Method not allowed" })
    next
  end

  query = query_param(req.request_uri, "q").to_s.strip
  if query.length < 1
    json_response(res, 422, { "detail" => "Provide a search query." })
    next
  end

  begin
    json_response(res, 200, { "results" => yahoo_search(query) })
  rescue StandardError => e
    json_response(res, 422, { "detail" => e.message })
  end
end

server.mount_proc "/api/research/chart" do |req, res|
  if req.request_method != "GET"
    json_response(res, 405, { "detail" => "Method not allowed" })
    next
  end

  ticker = query_param(req.request_uri, "ticker").to_s.strip.upcase
  range = query_param(req.request_uri, "range") || "1y"
  interval = query_param(req.request_uri, "interval") || "1d"
  allowed_ranges = %w[1d 5d 1mo 3mo 6mo 1y 2y 5y max]

  if ticker.empty?
    json_response(res, 422, { "detail" => "Provide a ticker symbol." })
    next
  end

  unless allowed_ranges.include?(range)
    json_response(res, 422, { "detail" => "Invalid range." })
    next
  end

  begin
    json_response(res, 200, fetch_chart(ticker, range, interval))
  rescue StandardError => e
    json_response(res, 422, { "detail" => e.message })
  end
end

server.mount_proc "/api/research/profile" do |req, res|
  if req.request_method != "GET"
    json_response(res, 405, { "detail" => "Method not allowed" })
    next
  end

  ticker = query_param(req.request_uri, "ticker").to_s.strip.upcase
  if ticker.empty?
    json_response(res, 422, { "detail" => "Provide a ticker symbol." })
    next
  end

  begin
    json_response(res, 200, build_research_profile(ticker))
  rescue StandardError => e
    json_response(res, 422, { "detail" => e.message })
  end
end

server.mount("/static", WEBrick::HTTPServlet::FileHandler, STATIC)

server.mount_proc "/" do |req, res|
  next unless req.request_method == "GET"

  relative = req.path == "/" ? "index.html" : req.path.sub(%r{\A/}, "")
  file = static_file(relative)

  if file
    serve_file(res, file)
  else
    not_found(res)
  end
end

index_path = static_file("index.html")
if index_path
  puts "Serving UI from #{index_path}"
else
  warn "WARNING: index.html not found under #{STATIC} or #{ROOT}"
end

trap("INT") { server.shutdown }

puts "Stock Portfolio Tracker running on port #{PORT}"
if finnhub_configured?
  puts "Finnhub API enabled"
else
  warn "WARNING: FINNHUB_API_KEY not set. Yahoo Finance often fails on Render — add a free key from finnhub.io"
end
server.start
