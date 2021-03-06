require 'stockfighter'
load 'apikey.rb'

gm = Stockfighter::GM.new(key: $apikey, level: 'making_amends')
post_url = "https://www.stockfighter.io/gm/instances/#{gm.instance_id}/judge"

#######################################
# UPDATE THIS SECTION BEFORE SENDING!
#######################################
accuse_account = 'FLP56310848'
exec_summary = 'The accused account was discovered by monitoring all accounts ' +
    '(determined by running order close commands on the first 600 orders) ' +
    'trading on this exchange, and then performing trading analysis on their executions. ' +
    'Determining the account involved was done by calculating the average profit made ' +
    'per order, and then comparing all accounts to see which one(s) stood out. ' +
    'This assumes that the accused account was using a strategy to maximize profits per ' +
    'transaction (which is the usual red flag for insider trading.) ' +
    'A link to a more detailed report is attached via the explanation_link URL.'
report_url = 'https://bitbucket.org/debunn/stockfighter/downloads/making-amends-report.txt'
#######################################
# DON'T FORGET TO UPLOAD THE REPORT TO BITBUCKET'S DOWNLOADS
#######################################

def perform_request(action, url, body)
  options = {
      :headers => {"X-Starfighter-Authorization" => $apikey},
      :format => :json
  }
  if body != nil
    options[:body] = body
  end
  response = HTTParty.method(action).call(url, options)

  if response.code == 200 and response['ok']
    response
  elsif not response['ok']
    raise "Error response received from #{url}: #{response['error']}"
  else
    raise "HTTP error response received from #{url}: #{response.code}"
  end
end

send_body = "{\"account\" : \"#{accuse_account}\", \"explanation_link\" : \"#{report_url}\", " +
    "\"executive_summary\" : \"#{exec_summary}\"}"

p perform_request('post', post_url, send_body)