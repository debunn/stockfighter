require 'stockfighter'

apikey = "1f79b068932efc828b4545cc8ad89af494a2b57e"

gm = Stockfighter::GM.new(key: apikey, level: "sell_side")

api = Stockfighter::Api.new(gm.config)

=begin
websockets = Stockfighter::Websockets.new(gm.config)
websockets.add_quote_callback { |quote|
  # Ensure you don't have long running operations (eg calling api.*) as part of this
  # callback method as the event processing for all websockets is performed on 1 thread.
  puts quote
}

websockets.add_execution_callback { |execution|
  # Ensure you don't have long running operations (eg calling api.*) as part of this
  # callback method as the event processing for all websockets is performed on 1 thread.
  puts execution
}

websockets.start()
=end

class Stock_Position

  def initialize()
    @stock_position = 0 # The number of shares currently held
    @stock_purchased = 0 # The number of shares bought to date
    @stock_sold = 0 # The number of shares sold to date
    @purchased_total = 0 # The total amount of money spent to purchase stocks
    @sold_total = 0 # The total amount of money made selling stocks
  end

  def current_position
    @stock_position
  end

  def execute_trade(shares, price, api)
    if shares < 0 then
      trade_action = 'sell'
      shares = shares.abs
    else
      trade_action = 'buy'
    end
    order = api.place_order(price: price, quantity: shares,
                            direction: trade_action, order_type: 'immediate-or-cancel')
    while order["open"] do
      sleep(1)
      order = api.order_status(order['id'])
    end

    order["fills"].each do |fill_item|
      if order['direction'] == 'sell'
        fill_item['qty'] = fill_item['qty'] * -1
      end
      self.trade(fill_item["qty"], fill_item["price"])
    end
  end

  def trade(shares, price)
    if shares > 0 then
      @stock_purchased += shares
      @purchased_total += (price * shares)
    elsif shares < 0 then
      @stock_sold += shares.abs
      @sold_total += (price * shares.abs)
    end
    @stock_position += shares
  end

  def avg_purchase()
    @stock_purchased == 0 ? 0 : @purchased_total / @stock_purchased
  end

  def avg_sell()
    @stock_sold == 0 ? 0 : @sold_total / @stock_sold
  end

  def profit()
    @sold_total - @purchased_total
  end

end

$my_pos = Stock_Position.new
$profit = 50 # The profit goal for a transaction

while true do
  $order_id = 0
  $last_quote = api.get_quote
  take_action = {action: 'sleep'}

  if !($last_quote.has_key?('ask')) || !($last_quote.has_key?('bid')) # no quote data, sleep

  elsif $my_pos.avg_purchase == 0 # default open position - buy some stock
    take_action = {action: 'buy', amount: 100, price: ($last_quote['bid']) + 5}

  elsif $my_pos.current_position < -800 # too far on margin - buy some stock
    if $last_quote['ask'] < ($my_pos.avg_purchase) - $profit # only buy if price is favourable
      take_action = {action: 'buy', amount: 100, price: ($last_quote['ask']) + 5}
    end

  elsif $my_pos.current_position > 800 # too long - sell some stock
    if $last_quote['bid'] > ($my_pos.avg_purchase) + $profit
      take_action = {action: 'sell', amount: 100, price: ($last_quote['bid']) - 5}
    end

  elsif $last_quote['ask'] < ($my_pos.avg_purchase) - $profit
    take_action = {action: 'buy', amount: 100, price: ($last_quote['ask']) + 5}

  elsif $last_quote['bid'] > ($my_pos.avg_purchase) + $profit
    take_action = {action: 'sell', amount: 100, price: ($last_quote['bid']) - 5}

  else # sleep off this round

  end

  case take_action[:action]
    when 'sleep'
      sleep(1)
    when 'buy'
      $my_pos.execute_trade(take_action[:amount], take_action[:price], api)
    when 'sell'
      $my_pos.execute_trade((take_action[:amount]) * -1, take_action[:price], api)
  end

  p 'Cash: ' + $my_pos.profit.to_s + ', Pos: ' + $my_pos.current_position.to_s +
        ', Avg buy: ' + $my_pos.avg_purchase.to_s + ', Avg sell: ' + $my_pos.avg_sell.to_s

end