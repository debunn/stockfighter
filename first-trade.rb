require 'rubygems'
require 'httparty'
require 'json'

$apikey = "1f79b068932efc828b4545cc8ad89af494a2b57e"
$venue = "KKEWEX"   # Replace this with your real value.
$stock = "LIG"  #Fun fact: Japanese programmers often use "hogehoge" where Americans use "foobar."  You should probably replace this with your real value.
$base_url = "https://api.stockfighter.io/ob/api"

$account = "MFB43891225"  # Printed in bold in the level instructions. Replace with your real value.

# Connect to the quotes socket

require 'faye/websocket'
require 'eventmachine'

# Set up the order

i = 100000

while i > 0 do

  response = HTTParty.get("#{$base_url}/venues/#{$venue}/stocks/#{$stock}/quote",
                          :headers => {"X-Starfighter-Authorization" => $apikey}
  )

  p response.body
  orderbook = JSON.parse(response.body)

  if orderbook.has_key?('ask')
    price = orderbook['ask'] * 1.01
  else
    price = orderbook['last'] * 1.01
  end

  price = price.to_int

  order = {
        "account" => $account,
        "venue" => $venue,
        "symbol" => $stock,
        "price" => price,  #$250.00 -- probably ludicrously high
        "qty" => 500,
        "direction" => "buy",
        "orderType" => "immediate-or-cancel"  # See the order docs for what a limit order is
    }

    if i < order["qty"]
      order["qty"] = i
    end

response = HTTParty.post("#{$base_url}/venues/#{$venue}/stocks/#{$stock}/orders",
                         :body => JSON.dump(order),
                         :headers => {"X-Starfighter-Authorization" => $apikey}
)

#Now we analyze the order response

#puts response.body

### Here is what the response looked like.

# {
#   "ok": true,
#   "symbol": "HOGE",
#   "venue": "FOOEX",
#   "direction": "buy",
#   "originalQty": 100,
#   "qty": 0,
#   "price": 25000,
#   "orderType": "limit",
#   "id": 6408,
#   "account": "HB61251714",
#   "ts": "2015-08-18T04:00:08.340298024+09:00",
#   "fills": [
#     {
#       "price": 5960,
#       "qty": 100,
#       "ts": "2015-08-18T04:00:08.340299592+09:00"
#     }
#   ],
#   "totalFilled": 100,
#   "open": false
# }

# As we can see, I got 100 fills of the 100 shares I ordered.  Whee!
# This order is now closed (open: false).
  ret_vals = JSON.parse(response.body)
  order_id = ret_vals['id']
  sleep(3)

  # Determine order status
  response = HTTParty.get("#{$base_url}/venues/#{$venue}/stocks/#{$stock}/orders/#{order_id}",
                          :headers => {"X-Starfighter-Authorization" => $apikey}
  )

  ret_vals = JSON.parse(response.body)
  p response.body
  i -= ret_vals['totalFilled']
  puts i

end
