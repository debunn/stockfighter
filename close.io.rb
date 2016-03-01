require 'httparty'

action = 'post'
url = 'https://app.close.io/hackwithus/'

first_name = 'David'
last_name = 'Bunn'
email = 'debunn@yahoo.com'
phone = '416-504-0296'
cover_letter = 'http://www.davebunn.com/close-io-cover-letter.docx'
urls = '["https://ca.linkedin.com/in/david-bunn-0828314b", "https://bitbucket.org/debunn/stockfighter"]'

body = '{"first_name" : "' + first_name + '", "last_name" : "' + last_name + '", ' +
    '"email" : "' + email + '", "phone" : "' + phone + '", "cover_letter" : "' + cover_letter + '", ' +
    '"urls" : ' + urls + '}'


response = HTTParty.post(url, :body => body,
                         :headers => {'Content-Type' => 'application/json',
                                      'Accept' => 'application/json'})
p response

if response.code == 200 and response['ok']
  p response
elsif not response['ok']
  raise "Error response received from #{url}: #{response['error']}"
else
  raise "HTTP error response received from #{url}: #{response.code}"
end