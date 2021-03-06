require 'stockfighter'
load 'apikey.rb'

# Initiate this level
gm = Stockfighter::GM.new(key: $apikey, level: "irrational_exuberance", polling: true)

#gm.restart

ansi_code = Hash.new
ansi_code['success'] = "\e[#32m"
ansi_code['info']    = "\e[#34m"
ansi_code['warning'] = "\e[#33m"
ansi_code['error']   = "\e[#31m"
ansi_code['danger']  = "\e[#31m"

# Output win message, stop level when level informs of win conditions
gm.add_state_change_callback { |previous_state, new_state|
  if new_state == 'won'
    puts "You've won!"
    gm.stop
  end
}

api = Stockfighter::Api.new(gm.config)

# Add currency formatting for NAV value
class String
  def currency_format()
    while self.sub!(/(\d+)(\d\d\d)/,'\1,\2'); end
    self
  end
end

# This class holds all the information on the currently held position / pricing
class StockPosition

  def initialize()
    @stock_position = 0 # The number of shares currently held
    @stock_purchased = 0 # The number of shares bought to date
    @stock_sold = 0 # The number of shares sold to date
    @purchased_total = 0 # The total amount of money spent to purchase stocks
    @sold_total = 0 # The total amount of money made selling stocks
    @price_metric = 0 # Metric for the average price paid for held/shorted stocks
    @last_trade = 0 # Holds the last traded value we executed on
    @open_orders = [] # Stores order numbers for all placed orders
    @closed_orders = [] # Stores order numbers where order['open'] = false
    @order_log = {} # Tracks each transaction, prevents duplicate processing
    @semaphore_lock = 0 # Shows the concurrency lock state for this object
  end

  def semaphore_lock
    # Sets the 'locked' flag for semaphore concurrency
    if @semaphore_lock == 0
      @semaphore_lock = 1
      true
    else
      false
    end
  end

  def semaphore_unlock
    # Un-sets the 'locked' flag for semaphore concurrency
    if @semaphore_lock == 1
      @semaphore_lock = 0
      true
    else
      false
    end
  end

  def current_position
    # Number of shares held: >0 for long, <0 for short
    @stock_position
  end

  def execute_trade(shares, price, api, type='immediate-or-cancel')
    # Executes trade via API, and logs the order number in open orders
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
    # Resolves current position based on trade transaction information
    # This currently is called only by the execution websocket thread

    if shares > 0 then # buy action
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
    @last_trade = price
    $loop_kicker = $profit * -1 # set the loop kicker to lower my asking price
    @stock_position += shares
  end

  def current_price_metric
    @price_metric
  end

  def last_trade
    @last_trade
  end

  def open_orders
    @open_orders
  end

  def closed_orders
    @closed_orders
  end

  def unresolved_orders
    # Returns any orders which are logged as open, but not yet closed
    # Needed as orders can close via websockets faster than they open via API

    @open_orders - @closed_orders
  end

  def close_order(order_id)
    # Add the order number to the closed orders array

    @closed_orders.push(order_id)
  end

  def record_action(order_id, ts, qty, price)
    # Record that this transaction has occurred for this order
    if @order_log.has_key?(order_id)
      @order_log[order_id][ts.to_s] = {'qty' => qty, 'price' => price}
    else
      @order_log[order_id] = {ts.to_s => {'qty' => qty, 'price' => price}}
    end
  end

  def order_log(order_id)
    # Return any processed transactions for this order
    @order_log.has_key?(order_id) ? @order_log[order_id].clone : {}
  end

  def action_processed?(order_id, ts)
    # Determine if this transaction has already been processed

    if @order_log[order_id].nil? || !(@order_log[order_id].has_key?(ts))
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

# This class holds information about market trending
class MarketAnalysis

  def initialize
    @last_quote = {}
    @last_bid = 0
    @last_ask = 0
    @latest_bids = [] # Tracks the latest bids for trend analysis
    @latest_asks = [] # Tracks the latest asks for trend analysis
    @history_size = 6 # The number of previous quote prices to record
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
    # Update analysis based on incoming quote

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
      @latest_bids.length < @history_size ? true : @latest_bids.shift
    end

    # Add this last ask value to the history of asks, if it isn't the same value
    if @last_ask != @latest_asks[-1] && @last_ask > 0
      @latest_asks.push(@last_ask)
      @latest_asks.length < @history_size ? true : @latest_asks.shift
    end
  end

  def bid_volatility
    # Returns the percentage difference between the first and last saved bids

    @latest_bids[0].nil? ? 0 : (@latest_bids[-1] * 100 / @latest_bids[0]) - 100
  end

  def ask_volatility
    # Returns the percentage difference between the first and last saved asks

    @latest_asks[0].nil? ? 0 : (@latest_asks[-1] * 100 / @latest_asks[0]) - 100
  end
end

$my_pos = StockPosition.new
$my_analysis = MarketAnalysis.new
$profit = 200 # The minimum profit goal for a transaction
$price_buffer = 10 # The amount above bid or below ask to charge
$loop_kicker = 0 # The amount to kick up my asking price (increased per loop iteration)

# Set functionality for when the ticker websocket receives a new quote
ticker_websocket = Stockfighter::Websockets.new(gm.config)
ticker_websocket.add_quote_callback { |quote|
  # Ensure you don't have long running operations (eg calling api.*) as part of this
  # callback method as the event processing for all websockets is performed on 1 thread.
  $my_analysis.new_quote(quote)

}

# Set functionality for when the execution websocket receives trade information
execution_websocket = Stockfighter::Websockets.new(gm.config)
execution_websocket.add_execution_callback { |execution|
  # Ensure you don't have long running operations (eg calling api.*) as part of this
  # callback method as the event processing for all websockets is performed on 1 thread.

  # Process each fill item as it is received - verify execution is valid first

  if execution['order']['account'] == gm.config[:account] &&
      execution['order']['symbol'] == gm.config[:symbol] &&
      execution['order']['venue'] == gm.config[:venue]

    # Attempt to lock the $my_pos object for updating
    semaphore = $my_pos.semaphore_lock

    while !(semaphore) do
      # keep looping until it's available
      semaphore = $my_pos.semaphore_lock
    end

    order_log = $my_pos.order_log(execution['order']['id'])
    execution['order']['fills'].each do |fill_item|
      if execution['order']['direction'] == 'sell'
        fill_item['qty'] = (fill_item['qty']).abs * -1
      end

      item_found = false
      order_log.each do |key, log_item|
        if log_item['qty'] == fill_item['qty'] &&
            log_item['price'] == fill_item['price'] && !(item_found)
          order_log.delete(key)
          item_found = true
        end
      end

      # If this fill was not found in recorded transactions, process it
      if !(item_found)
        $my_pos.trade(fill_item["qty"], fill_item["price"])
        $my_pos.record_action(execution['order']['id'], fill_item['ts'],
                              fill_item['qty'], fill_item['price'])
      end

    end


    # Resolve the trade if it is no longer open

    if !(execution['order']['open'])
      p 'Order: ' + (execution['order']['id']).to_s + ' is closed.'
      $my_pos.close_order(execution['order']['id'])
    end

    # Unlock the $my_pos object for updating
    semaphore = $my_pos.semaphore_unlock

  end

}

# Isolate the websockets to their own individual threads - mixing with trades causes missed transactions
ticker_thr = Thread.new { ticker_websocket.start(tickertape_enabled:true, executions_enabled:false) }
execution_thr = Thread.new { execution_websocket.start(tickertape_enabled:false, executions_enabled:true) }

# Main processing loop - stops when the game state is not active
while true do
  $order_id = 0
  take_action = {action: 'sleep', order_type: 'immediate-or-cancel'}
  last_quote = $my_analysis.last_quote
  last_quote = last_quote.nil? ? api.get_quote : last_quote

  buy_profit = $my_analysis.last_ask == 0 ? 0 : $my_pos.current_price_metric - $my_analysis.last_ask
  sell_profit = $my_analysis.last_bid == 0 ? 0 : $my_analysis.last_bid - $my_pos.current_price_metric

=begin
  if !($my_pos.unresolved_orders.empty?) # resolve any open orders
    $my_pos.unresolved_orders.each do |order_id|
      order_status = api.order_status(order_id)
      order_status['open'] ? true : $my_pos.close_order(order_id)
    end
  elsif $my_pos.current_position < 0 # too far on margin - buy some stock (at cost if necessary)
    if $my_analysis.last_ask < $my_pos.current_price_metric
      take_action = {action: 'buy', amount: 200, price: ($my_pos.last_trade - $profit)}
    end

  elsif $my_pos.current_position > 600 # too long - sell some stock (at cost if necessary)
    if $my_analysis.last_bid > $my_pos.current_price_metric
      take_action = {action: 'sell', amount: 600, price: ($my_pos.last_trade + $profit)}
    end

  elsif $my_pos.current_position == 0 # no stock position - buy some stock
    take_action = {action: 'buy', amount: 200, price: ($my_analysis.last_ask + $price_buffer)}

  elsif $my_pos.profit > 7000000 # Attempt to pop the bubble
    $my_pos.execute_trade(-2000, ($my_pos.last_trade * 0.1), api, 'limit')
    p 'Selling 2000@' + ($my_pos.last_trade * 0.1).to_s

  else # Try a buy based on my last trade, plus a loop based increase
    take_action = {action: 'buy', amount: 50, price: ($my_pos.last_trade + $loop_kicker)}
  end
=end

  if !($my_pos.unresolved_orders.empty?) # resolve any open orders
    $my_pos.unresolved_orders.each do |order_id|
      order_status = api.order_status(order_id)
      order_status['open'] ? true : $my_pos.close_order(order_id)
    end

  elsif $my_pos.current_position == 0 # no stock position - buy some stock
    if $my_analysis.last_ask > 0
      $my_pos.execute_trade(500, ($my_analysis.last_ask + $price_buffer), api)
      p 'Buying 500@' + ($my_analysis.last_ask + $price_buffer).to_s
    end

  elsif $my_pos.profit > 20000000 # Sufficient profit - try blowing up the market
    $my_pos.execute_trade(-200, 100000, api, 'limit')
    $my_pos.execute_trade(500, 80000, api, 'limit')
    sleep(1)
    p 'Selling 200@100000'
    p 'Buying 5@80000'
    sleep(30)
    $my_pos.execute_trade(-3000, 100, api, 'limit')
    p 'Selling 2000@100'
    p 'Buying 1000@200'


  else # Exploit any open (*STUPID*) market orders
    $my_pos.execute_trade(-1, 2000000000, api, 'limit')
    p 'Selling 1@200000000'

  end

  # Execute any action assigned in this loop, otherwise skip this turn
  case take_action[:action]
    when 'buy'
      $my_pos.current_position > 0 ? true :
          $my_pos.execute_trade(take_action[:amount], take_action[:price], api)
      p 'Buying ' + take_action[:amount].to_s + '@' + take_action[:price].to_s
    when 'sell'
      $my_pos.current_position < 0 ? true :
          $my_pos.execute_trade((take_action[:amount]) * -1, take_action[:price], api)
      p 'Selling ' + take_action[:amount].to_s + '@' + take_action[:price].to_s
  end

  tick_output = 'NAV: $' +
      (($my_pos.profit + (last_quote.has_key?('last') ? last_quote['last'] : 0) * $my_pos.current_position)/100).to_s.currency_format +
      ', Pos: ' + $my_pos.current_position.to_s + ', Avg buy: ' + $my_pos.avg_purchase.to_s +
      ', Avg sell: ' + $my_pos.avg_sell.to_s +
      ', Price metric: ' + $my_pos.current_price_metric.to_s

  $last_output == tick_output ? true : (p tick_output ; $last_output = tick_output)

  $loop_kicker += 25

end