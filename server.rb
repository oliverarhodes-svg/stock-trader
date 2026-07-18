#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "net/http"
require "uri"
require "webrick"

ROOT = File.expand_path(__dir__)
STATIC = File.join(ROOT, "static")
PORT = (ENV["PORT"] || 8000).to_i

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

def fetch_current_price(ticker)
  symbol = ticker.upcase.strip
  uri = URI("https://query1.finance.yahoo.com/v8/finance/chart/#{symbol}?interval=1d&range=1d")

  response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 10, read_timeout: 10) do |http|
    request = Net::HTTP::Get.new(uri)
    request["User-Agent"] = "Mozilla/5.0 (compatible; StockTracker/1.0)"
    http.request(request)
  end

  raise "Yahoo Finance returned #{response.code}" unless response.is_a?(Net::HTTPSuccess)

  data = JSON.parse(response.body)
  meta = data.dig("chart", "result", 0, "meta")
  raise "No market data for #{symbol}" if meta.nil?

  price = meta["regularMarketPrice"] || meta["chartPreviousClose"]
  raise "Could not determine current price for #{symbol}" if price.nil?

  price.to_f
end

def analyze_position(position)
  ticker = position["ticker"].to_s.strip.upcase
  shares = position["shares"].to_f
  purchase_price = position["purchase_price"].to_f
  cost_basis = (shares * purchase_price).round(2)

  begin
    current_price = fetch_current_price(ticker)
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
  results = []
  positions.each_with_index do |p, index|
    sleep(0.25) if index.positive?
    results << analyze_position(p)
  end
  priced = results.select { |r| r["current_value"] }

  raise "Could not fetch prices for any positions." if priced.empty?

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

server.mount("/static", WEBrick::HTTPServlet::FileHandler, STATIC)

server.mount_proc "/" do |req, res|
  path = req.path == "/" ? "/index.html" : req.path
  file = File.join(STATIC, path.sub(%r{\A/}, ""))

  if !file.start_with?(STATIC) || !File.file?(file)
    res.status = 404
    res["Content-Type"] = "text/plain"
    res.body = "Not found"
    next
  end

  res.status = 200
  res["Content-Type"] = content_type(file)
  res.body = File.read(file)
end

trap("INT") { server.shutdown }

puts "Stock Portfolio Tracker running on port #{PORT}"
server.start
