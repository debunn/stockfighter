require 'stockfighter'
load 'apikey.rb'

gm = Stockfighter::GM.new(key: $apikey, level: "dueling_bulldozers", polling: true)

ansi_code = Hash.new
ansi_code['success'] = "\e[#32m"
ansi_code['info']    = "\e[#34m"
ansi_code['warning'] = "\e[#33m"
ansi_code['error']   = "\e[#31m"
ansi_code['danger']  = "\e[#31m"

gm.add_state_change_callback { |previous_state, new_state|
    if new_state == 'won'
        puts "You've won!"
    end
}

api = Stockfighter::Api.new(gm.config)

class String
  def currency_format()
    while self.sub!(/(\d+)(\d\d\d)/,'\1,\2'); end
    self
  end
end

class StockPosition

  def initialize()
    @stock_position = 0 # The number of shares currently held
    @stock_purchased = 0 # The number of shares bought to date
    @stock_sold = 0 # The number of shares sold to date
    @purchased_total = 0 # The total amount of money spent to purchase stocks
    @sold_total = 0 # The total amount of money made selling stocks
    @price_metric = 0 # Metric for the average price of held or shorted stocks
    @open_orders = []
    @closed_orders = []
    @order_log = {}
  end

  def current_position
    @stock_position
  end

  def execute_trade(shares, price, api, type='immediate-or-cancel')
    if shares < 0 then
      trade_action = 'sell'
      shares = shares.abs
    elsif shares == 0
      return
    else
      trade_action = 'buy'
    end
    order = api.place_order(price: price, quantity: shares,
                            direction: trade_action, order_type: type)
    @open_orders.push(order['id'])

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

  def closed_orders
    @closed_orders
  end

  def unresolved_orders
    @open_orders - @closed_orders
  end

  def close_order(order_id)
    @closed_orders.push(order_id)
  end
  
  def compare_orders
    @open_orders - @closed_orders
  end
  
  def record_action(order_id, ts)
    @order_log[order_id] = {ts => true}
  end
  
  def action_processed?(order_id, ts)
    if @order_log[order_id].nil? || @order_log[order_id][ts].nil?
      false
    else 
      true
    end
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

class MarketAnalysis

  def initialize
    @last_quote = {}
    @last_bid = 0
    @last_ask = 0
    @latest_bids = []
    @latest_asks = []
    @highest_last = 0 # track the historically highest sale price
    @lowest_last = 0 # track the historically lowest sale price
  end

  def last_bid
    @last_bid
  end

  def last_ask
    @last_ask
  end

  def last_quote
    @last_quote
  end
  
  def highest_last
    @highest_last
  end
  
  def lowest_last
    @lowest_last
  end
  
  def last_order
    @last_order
  end
  
  def new_quote(inbound_quote)
    @last_quote = inbound_quote.clone
    @last_bid = inbound_quote.has_key?('bid') ? inbound_quote['bid'] : @last_bid
    @last_ask = inbound_quote.has_key?('ask') ? inbound_quote['ask'] : @last_ask
    
    if inbound_quote.has_key?('last')
      @highest_last = (@highest_last == 0 ? inbound_quote['last'] : @highest_last)
      @lowest_last = (@lowest_last == 0 ? inbound_quote['last'] : @lowest_last)
      @highest_last = (inbound_quote['last'] > @highest_last ? inbound_quote['last'] : @highest_last)
      @lowest_last = (inbound_quote['last'] < @lowest_last ? inbound_quote['last'] : @lowest_last)
    end

    # Add this last bid value to the history of bids, if it isn't the same value
    if @last_bid != @latest_bids[-1] && @last_bid > 0
      @latest_bids.push(@last_bid)
      @latest_bids.length < 6 ? true : @latest_bids.shift
    end

    # Add this last ask value to the history of asks, if it isn't the same value
    if @last_ask != @latest_asks[-1] && last_ask > 0
      @latest_asks.push(@last_ask)
      @latest_asks.length < 6 ? true : @latest_asks.shift
    end
  end

  def bid_volatility
    @latest_bids[0].nil? ? 0 : (@latest_bids[-1] * 100 / @latest_bids[0]) - 100
  end

  def ask_volatility
    @latest_asks[0].nil? ? 0 : (@latest_asks[-1] * 100 / @latest_asks[0]) - 100
  end
end

$my_pos = StockPosition.new
$my_analysis = MarketAnalysis.new
$profit = 125 # The minimum profit goal for a transaction
$price_buffer = 0 # The amount above bid or below ask to charge

ticker_websocket = Stockfighter::Websockets.new(gm.config)
ticker_websocket.add_quote_callback { |quote|
  # Ensure you don't have long running operations (eg calling api.*) as part of this
  # callback method as the event processing for all websockets is performed on 1 thread.
  $my_analysis.new_quote(quote)

}

execution_websocket = Stockfighter::Websockets.new(gm.config)
execution_websocket.add_execution_callback { |execution|
  # Ensure you don't have long running operations (eg calling api.*) as part of this
  # callback method as the event processing for all websockets is performed on 1 thread.
  $last_execute = execution
  
  execution['order']['fills'].each do |fill_item|
    if execution['order']['direction'] == 'sell'
      fill_item['qty'] = fill_item['qty'] * -1
    end
    if !( $my_pos.action_processed?(execution['order']['id'], fill_item['ts']) )
      $my_pos.trade(fill_item["qty"], fill_item["price"])
      $my_pos.record_action(execution['order']['id'], fill_item['ts'])
    end
  end
    
  if !(execution['order']['open'])
    p 'Order: ' + (execution['order']['id']).to_s + ' is closed.'
    $my_pos.close_order(execution['order']['id'])
  end
  
}

# Isolate the websockets to their own thread - mixing with trades causes missed transactions
ticker_thr = Thread.new { ticker_websocket.start(tickertape_enabled:true, executions_enabled:false) }
execution_thr = Thread.new { execution_websocket.start(tickertape_enabled:false, executions_enabled:true) }

while true do
  $order_id = 0
  take_action = {action: 'sleep'}
  last_quote = $my_analysis.last_quote
  last_quote = last_quote.nil? ? api.get_quote : last_quote

=begin
  if $last_ask.nil? || $last_bid.nil? # no quote data, sleep
    if $my_pos.current_position < 0
      take_action = {action: 'buy', amount: 20, price: ($last_quote['last']) - $profit}
    else
      take_action = {action: 'sell', amount: 20, price: ($last_quote['last']) + $profit}
    end



=end

  buy_profit = $my_analysis.last_ask == 0 ? 0 : $my_pos.current_price_metric - $my_analysis.last_ask
  sell_profit = $my_analysis.last_bid == 0 ? 0 : $my_analysis.last_bid - $my_pos.current_price_metric
  #buy_profit = last_quote['last'] == 0 ? 0 : $my_pos.current_price_metric - last_quote['last']
  #sell_profit = last_quote['last'] == 0 ? 0 : last_quote['last'] - $my_pos.current_price_metric

  if !($my_pos.unresolved_orders.empty?) # resolve any open orders
    $my_pos.unresolved_orders.each do |order_id|
      order_status = api.order_status(order_id)
      order_status['open'] ? true : $my_pos.close_order(order_id)
    end
  elsif $my_pos.current_position < -300 # too far on margin - buy some stock (at cost if necessary)
    if $my_analysis.last_ask < $my_pos.current_price_metric
      take_action = {action: 'buy', amount: 200, price: $my_analysis.last_ask}
    end

  elsif $my_pos.current_position > 300 # too long - sell some stock (at cost if necessary)
    if $my_analysis.last_bid > $my_pos.current_price_metric
      take_action = {action: 'sell', amount: 200, price: $my_analysis.last_bid}
    end

  elsif $my_pos.current_price_metric == 0 # no stock position - buy some stock
    take_action = {action: 'buy', amount: 20, price: last_quote['last']}

  elsif sell_profit > buy_profit && sell_profit > 0
    if $my_analysis.last_bid > ($my_pos.current_price_metric) + ($profit + $price_buffer)
      volume = $my_pos.current_position < 0 ? 50 : (sell_profit > 300 ? 300 : sell_profit)
      take_action = {action: 'sell', amount: volume, price: ($my_analysis.last_bid - $price_buffer)}
    end

  elsif buy_profit >= sell_profit && buy_profit > 0
    if $my_analysis.last_ask < ($my_pos.current_price_metric) - ($profit + $price_buffer)
      volume = $my_pos.current_position > 0 ? 50 : (buy_profit > 300 ? 300 : buy_profit)
      take_action = {action: 'buy', amount: volume , price: ($my_analysis.last_ask + $price_buffer)}
    end

  else # sleep
    
  end


  case take_action[:action]
    when 'buy'
      $my_analysis.bid_volatility > 3 && $my_pos.current_position > 0 ? true :
          $my_pos.execute_trade(take_action[:amount], take_action[:price], api, 'immediate-or-cancel')
          p 'Buying ' + take_action[:amount].to_s + '@' + take_action[:price].to_s
    when 'sell'
      $my_analysis.ask_volatility < -3 && $my_pos.current_position < 0 ? true :
          $my_pos.execute_trade((take_action[:amount]) * -1, take_action[:price], api, 'immediate-or-cancel')
          p 'Selling ' + take_action[:amount].to_s + '@' + take_action[:price].to_s
  end

  tick_output = 'NAV: $' +
    (($my_pos.profit + (last_quote.has_key?('last') ? last_quote['last'] : 0) * $my_pos.current_position)/100).to_s.currency_format +
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