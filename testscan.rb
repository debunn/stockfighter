require 'stockfighter'
require 'httparty'
load 'apikey.rb'

gm = Stockfighter::GM.new(key: $apikey, level: "making_amends", polling: true)
api = Stockfighter::Api.new(gm.config)
base_url = 'https://api.stockfighter.io/ob/api'

def perform_request(action, url, body:nil)

  options = {
      :headers => {"X-Starfighter-Authorization" => $apikey},
      :format => :json
  }
  if body != nil
    options[:body] = body
  end
  response = HTTParty.method(action).call(url, options)

  if response.code == 200 and response["ok"]
    response
  elsif not response["ok"]
    raise "Error response received from #{url}: #{response['error']}"
  else
    raise "HTTP error response received from #{url}: #{response.code}"
  end
end

def cancel_it(order_num, api, account_list)
  begin
    api.cancel_order(order_num)
  rescue => error
    if !(error.message.index('You have to own account').nil?)
      account_num = error.message.split(' ')[-1].chop
      account_list[account_num] = true
    else
      p error.message
    end
  end
  account_num
end


account_list = {}
order_num = 0
while order_num < 1000 do
  order_num += 1
  cancel_it(order_num, api, account_list)
  order_num % 100 == 0 ? (p account_list.length.to_s + '@' + order_num.to_s) : true
end
p account_list
p account_list.length.to_s

temp_config = {key: $apikey, account: 'HAM15882564',
               symbol: gm.config[:symbol], venue: gm.config[:venue]}
execution_websocket = Stockfighter::Websockets.new(temp_config)
execution_websocket.add_execution_callback { |execution|
  # Ensure you don't have long running operations (eg calling api.*) as part of this
  # callback method as the event processing for all websockets is performed on 1 thread.

  # Process each fill item as it is received - verify execution is valid first

  p execution
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
#ticker_thr = Thread.new { ticker_websocket.start(tickertape_enabled:true, executions_enabled:false) }
#execution_thr = Thread.new { execution_websocket.start(tickertape_enabled:false, executions_enabled:true) }

#sleep(10)