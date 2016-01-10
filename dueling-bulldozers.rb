require 'stockfighter'
load 'apikey.rb'

gm = Stockfighter::GM.new(key: $apikey, level: "dueling_bulldozers")

api = Stockfighter::Api.new(gm.config)

class String
  def currency_format()
    while self.sub!(/(\d+)(\d\d\d)/,'\1,\2'); end
    self
  end
end

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
    @price_metric = 0 # Metric for the average price of held or shorted stocks
    @open_orders = {}
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
    @open_orders[order['id']] = true

  end

  def trade(shares, price)
    if shares > 0 then # buy action
      # Recalculate the price metric for current position
      if @stock_position < 0
        if @stock_position + shares == 0
          @price_metric = 0
        elsif @stock_position + shares > 0
          @price_metric = price
        end
      else
        @price_metric = ((@price_metric * @stock_position) + (shares * price)) /
                        (@stock_position + shares)
      end

      @stock_purchased += shares
      @purchased_total += (price * shares)
    elsif shares < 0 then # sell action
      # Recalculate the price metric for current position
      if @stock_position > 0
        if @stock_position + shares == 0
          @price_metric = 0
        elsif @stock_position + shares < 0
          @price_metric = price
        end
      else
        @price_metric = ((@price_metric * @stock_position) + (shares * price)) /
            (@stock_position + shares)
      end

      @stock_sold += shares.abs
      @sold_total += (price * shares.abs)
    end
    @stock_position += shares
  end

  def current_price_metric
    @price_metric
  end

  def open_orders
    @open_orders
  end

  def close_order(order_id)
    @open_orders.delete order_id
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
$profit = 100 # The profit goal for a transaction
$temp_counter = 0

ticker_websocket = Stockfighter::Websockets.new(gm.config)
ticker_websocket.add_quote_callback { |quote|
  # Ensure you don't have long running operations (eg calling api.*) as part of this
  # callback method as the event processing for all websockets is performed on 1 thread.
  $last_quote = quote
  $last_bid = quote.has_key?('bid') ? quote['bid'] : $last_bid
  $last_ask = quote.has_key?('ask') ? quote['ask'] : $last_ask
}

execution_websocket = Stockfighter::Websockets.new(gm.config)
execution_websocket.add_execution_callback { |execution|
  # Ensure you don't have long running operations (eg calling api.*) as part of this
  # callback method as the event processing for all websockets is performed on 1 thread.
  $last_execute = execution

  if !(execution['order']['incomingComplete'])
    p 'Order: ' + (execution['order']['id']).to_s + ' is closed.'

    execution['order']['fills'].each do |fill_item|
      if execution['order']['direction'] == 'sell'
        fill_item['qty'] = fill_item['qty'] * -1
      end
      $my_pos.trade(fill_item["qty"], fill_item["price"])
    end

  end

}

# Isolate the websockets to their own thread - mixing with trades causes... bad things.
ticker_thr = Thread.new { ticker_websocket.start(tickertape_enabled:true, executions_enabled:false) }
execution_thr = Thread.new { execution_websocket.start(tickertape_enabled:false, executions_enabled:true) }

while true do
  $order_id = 0
  $last_quote = $last_quote.nil? ? api.get_quote : $last_quote
  take_action = {action: 'sleep'}

  if $last_ask.nil? || $last_bid.nil? # no quote data, sleep
    if $my_pos.current_position < 0
      take_action = {action: 'buy', amount: 20, price: ($last_quote['last']) - $profit}
    else
      take_action = {action: 'sell', amount: 20, price: ($last_quote['last']) + $profit}
    end

  elsif $my_pos.current_price_metric == 0 # no stock position - buy some stock
    take_action = {action: 'buy', amount: 20, price: ($last_ask) + 5}

  elsif $my_pos.current_position < -400 # too far on margin - buy some stock
    if $last_ask < ($my_pos.current_price_metric) - $profit # only buy if price is favourable
      take_action = {action: 'buy', amount: 100, price: ($last_ask) + 5}
    end

  elsif $my_pos.current_position > 400 # too long - sell some stock
    if $last_bid > ($my_pos.current_price_metric) + $profit
      take_action = {action: 'sell', amount: 100, price: ($last_bid) - 5}
    end

  elsif $last_bid > ($my_pos.current_price_metric) + $profit
    take_action = {action: 'sell', amount: $my_pos.current_position > 0 ? 100 : 50, price: ($last_bid) - 5}

  elsif $last_ask < ($my_pos.current_price_metric) - $profit
    take_action = {action: 'buy', amount: $my_pos.current_position < 0 ? 100 : 50, price: ($last_ask) + 5}

  else # sleep off this round

  end

  case take_action[:action]
    when 'buy'
      $my_pos.execute_trade(take_action[:amount], take_action[:price], api)
    when 'sell'
      $my_pos.execute_trade((take_action[:amount]) * -1, take_action[:price], api)
  end


  tick_output = 'NAV: $' +
    (($my_pos.profit + $last_quote['last'] * $my_pos.current_position)/100).to_s.currency_format +
        ', Pos: ' + $my_pos.current_position.to_s + ', Avg buy: ' + $my_pos.avg_purchase.to_s +
        ', Avg sell: ' + $my_pos.avg_sell.to_s +
        ', Price metric: ' + $my_pos.current_price_metric.to_s

  $last_output == tick_output ? true : (p tick_output ; $last_output = tick_output)

  #if take_action[:action] == 'sleep'
  #  sleep(1)
  #else
  #  sleep(5)
  #end

end