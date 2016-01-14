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
      # p perform_request("get",
      #                   "#{base_url}/venues/#{gm.config[:venue]}/accounts/#{account_num}/orders")
    end
  end
  account_num
end

account_list = {}
order_num = 0
while order_num < 200 do
  order_num += 1
  cancel_it(order_num, api, account_list)
end
p account_list
