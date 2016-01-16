require 'stockfighter'
load 'apikey.rb'

gm = Stockfighter::GM.new(key: $apikey, level: "making_amends", polling: true)

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

$account_list = {}
$time_format = '%H:%M:%S'

# Attempt to cancel order, record the account number for the order on error
def cancel_it(order_num, api)
  begin
    api.cancel_order(order_num)
  rescue => error
    if !(error.message.index('You have to own account').nil?)
      account_num = error.message.split(' ')[-1].tr('\"', '').chop
      $account_list[account_num] = true
    else
      p error.message
    end
  end
  true # Return true - value doesn't matter
end

# Add currency formatting for NAV value
class String
  def currency_format()
    while self.sub!(/(\d+)(\d\d\d)/,'\1,\2'); end
    self
  end
end

# This class holds all the information on the currently held position / pricing
class StockPosition

  attr_reader :trade_history
  attr_reader :trade_total

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
    @trade_history = '' # A text record of trading, for audit purposes
    @trade_total = 0
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
    @stock_position += shares
    @trade_total += 1
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
    @trade_history = @trade_history + Time.now.strftime($time_format) + ' - ' +
        (qty > 0 ? 'buy ' : 'sell ') + qty.abs.to_s + '@' + price.to_s + "\n"
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

  def avg_purchase
    @stock_purchased == 0 ? 0 : @purchased_total / @stock_purchased
  end

  def avg_sell
    @stock_sold == 0 ? 0 : @sold_total / @stock_sold
  end

  def profit
    @sold_total - @purchased_total
  end

  def profit_metric
    # Calculate the avg amount of profit per order overall
    if @order_log.length == 0
      0
    else
      (@sold_total - @purchased_total) / @order_log.length
    end
  end

end

# This class holds information about market trending
class MarketAnalysis
  attr_reader :last_bid
  attr_reader :last_ask
  attr_reader :last_quote
  attr_reader :highest_last
  attr_reader :lowest_last
  attr_reader :last_trade
  attr_reader :bid_size
  attr_reader :ask_size

  def initialize
    @last_quote = {}
    @last_bid = 0
    @last_ask = 0
    @latest_bids = [] # Tracks the latest bids for trend analysis
    @latest_asks = [] # Tracks the latest asks for trend analysis
    @history_size = 6 # The number of previous quote prices to record
    @highest_last = 0 # track the historically highest sale price
    @lowest_last = 0 # track the historically lowest sale price
    @last_trade = 0 # track the amount of the last trade
    @bid_size = 0 # track the number of buy orders
    @ask_size = 0 # track the number of sell orders
  end

  def new_quote(inbound_quote)
    # Update analysis based on incoming quote

    @last_quote = inbound_quote.clone
    @last_bid = inbound_quote.has_key?('bid') ? inbound_quote['bid'] : @last_bid
    @last_ask = inbound_quote.has_key?('ask') ? inbound_quote['ask'] : @last_ask
    @last_trade = inbound_quote.has_key?('last') ? inbound_quote['last'] : @last_trade
    @bid_size = inbound_quote.has_key?('bidSize') ? inbound_quote['bidSize'] : @last_trade
    @ask_size = inbound_quote.has_key?('askSize') ? inbound_quote['askSize'] : @last_trade

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

#$my_pos = StockPosition.new
$my_analysis = MarketAnalysis.new
$profit = 200 # The minimum profit goal for a transaction
$price_buffer = 10 # The amount above bid or below ask to charge

# Set functionality for when the ticker websocket receives a new quote
ticker_websocket = Stockfighter::Websockets.new(gm.config)
ticker_websocket.add_quote_callback { |quote|
  # Ensure you don't have long running operations (eg calling api.*) as part of this
  # callback method as the event processing for all websockets is performed on 1 thread.
  $my_analysis.new_quote(quote)
  p Time.now.strftime($time_format) + ' - last: ' + $my_analysis.last_trade.to_s +
        ', bid: ' + $my_analysis.last_bid.to_s +
        '(' + $my_analysis.bid_size.to_s + '), ask:' + $my_analysis.last_ask.to_s +
        '(' + $my_analysis.ask_size.to_s + ')'

}

# Isolate the ticker to its own individual thread
ticker_thr = Thread.new {
  ticker_websocket.start(tickertape_enabled:true, executions_enabled:false)
}

# Scan through the first 700 orders to determine a list of all account numbers
order_num = 0
sleep(60)
while order_num < 600 do
  order_num += 1
  cancel_it((order_num + 1000), api)
end
p $account_list.length.to_s + ' total accounts found.'

# Run through the list of accounts, and create an execution websocket,
# thread and position object for each
$execution_websockets = {}
$account_positions = {}
$execution_threads = {}

$account_list.each do |account_key, account_bool|
  # Set functionality for when each execution websocket receives trade information
  temp_config = {key: $apikey, account: account_key,
                 symbol: gm.config[:symbol], venue: gm.config[:venue]}
  $execution_websockets[account_key] = Stockfighter::Websockets.new(temp_config)
  $account_positions[account_key] = StockPosition.new

  $execution_websockets[account_key].add_execution_callback { |execution|
    # Ensure you don't have long running operations (eg calling api.*) as part of this
    # callback method as the event processing for all websockets is performed on 1 thread.

    # Process each fill item as it is received - verify execution is valid first

    if execution['order']['symbol'] == gm.config[:symbol] &&
        execution['order']['venue'] == gm.config[:venue]

      ex_account = execution['order']['account']
      order_log = $account_positions[ex_account].order_log(execution['order']['id'])
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
          $account_positions[ex_account].trade(fill_item["qty"], fill_item["price"])
          $account_positions[ex_account].record_action(execution['order']['id'], fill_item['ts'],
                                fill_item['qty'], fill_item['price'])
        end

      end

      # Resolve the trade if it is no longer open
      if !(execution['order']['open'])
        $account_positions[ex_account].close_order(execution['order']['id'])
      end

    end

  }

  $execution_threads[account_key] = Thread.new {
    $execution_websockets[account_key].start(tickertape_enabled:false, executions_enabled:true)
  }

end

# Main analysis
p 'Sleeping for 10 minutes to allow for trade data collection'
sleep(5 * 60)

# Kill the quote thread and re-connect - it seems to time out
Thread.kill(ticker_thr)
ticker_thr = Thread.new {
  ticker_websocket.start(tickertape_enabled:true, executions_enabled:false)
}

# Kill all websockets and re-connect - they seem to time out
$execution_threads.each do |key, thread|
  Thread.kill(thread)

  $execution_threads[key] = Thread.new {
    $execution_websockets[key].start(tickertape_enabled:false, executions_enabled:true)
  }
end

sleep(5 * 60)

metrics_hash = {}

$account_list.each do |account_key, account_bool|
  this_metric = $account_positions[account_key].profit_metric
  puts 'Account: ' + account_key.to_s + ', profit metric: ' + this_metric.to_s + "\n"
end

$account_list.each do |account_key, account_bool|
  this_metric = $account_positions[account_key].profit_metric
  metrics_hash[this_metric] = account_key
  if this_metric > 100000
    p '-----------------------------------------------------------------------------'
    puts 'Dumping trades for account: ' + account_key.to_s
    puts $account_positions[account_key].trade_history
    p '-----------------------------------------------------------------------------'
  end
end
