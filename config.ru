#encoding: UTF-8

require "rubygems"
require "tweetstream"
require "em-http-request"
require "httparty"
require "simple_oauth"
require "json"
require "uri"
require "redis"

# require the file with the API keys
require "./oauth-keys"

# config oauth
ACCOUNT_ID = OAUTH[:token].split("-").first.to_i

TweetStream.configure do |config|
 config.consumer_key       = OAUTH[:consumer_key]
 config.consumer_secret    = OAUTH[:consumer_secret]
 config.oauth_token        = OAUTH[:token]
 config.oauth_token_secret = OAUTH[:token_secret]
 config.auth_method = :oauth
end

# redis setup
redis = Redis.new(REDIS)
redis.set("count", 0)

#def fetch_cotations
#  response = HTTParty.get(BIT_AVERAGE_URL)
#  $COTATIONS[:data] = JSON.parse response.body
#  $COTATIONS[:timestamp] = Time.now
#end

# constants
BIT_AVERAGE_URL = "https://api.bitcoinaverage.com/all" #bitcoinaverage.com API endpoint

# variables

twurl = URI.parse("https://api.twitter.com/1.1/statuses/update.json")
bit_regex = /\d+(\.|,)?(\d+)?/ # any money amount | accepts both . or , as separator
currency_regex = /#[A-Z]{3}/ # "#" followed by 3 capital letters
bitcoin_cotation = 0
has_cotation = false
cotation_timestamp = ""

# user stream connection
@client  = TweetStream::Client.new

puts "[STARTING] rack..."
run lambda { |env| [200, {'Content-Type'=>'text/plain'}, StringIO.new("#{redis.get("count")} conversions so far")] }

Thread.new do
puts "[STARTING] bot..."
@client.userstream() do |status|
    puts "[NEW TWEET] #{status.text}"

    retweet = status.retweet?
    reply_to_me = status.in_reply_to_user_id == ACCOUNT_ID
    contains_currency = status.text =~ currency_regex
    contains_amount = status.text =~ bit_regex

    puts retweet
    puts reply_to_me
    puts contains_currency
    puts contains_amount

    # check if stream is not a retweet and is valid
    if !retweet && reply_to_me && contains_amount && contains_currency
        puts "[PROCESSING] #{status.text}"
        bit_amount = status.text[bit_regex].to_f # grabs the amount on the tweet
        currency = status.text[currency_regex][1..-1] # takes the "#" out
        p bit_amount
        p currency

        # bloquing cotation update
        operation = proc {
            def cotations_updated?
                if redis.exists("timestamp") == 1
                    (Time.now - redis.get("timestamp")) < 10
                else
                    return false
                end
            end


            unless cotations_updated?
                puts "Will fetch new cotations"
                response = HTTParty.get(BIT_AVERAGE_URL)
                redis.set("data", response.body)
                redis.set("timestamp", Time.now)
                puts "Cotations fetched: #{redis.get("data")}"
            end

            def final_amount(amount, currency)
                puts "Will compute final_amount"
                cotations = JSON.parse(redis.get("data"))
                if cotations[:data][currency]
                    cotations[:data][currency]["averages"]["last"] * amount
                else
                    -1
                end
        	end

            result = final_amount(bit_amount, currency)
            result = result.round(2)
            puts "Should return #{result}"
        	result
        }

            callback = proc { |this_amount|
                cotations = JSON.parse(redis.get("data"))
                if cotations("data")[currency]
                    reply = "#{bit_amount} bitcoins in #{currency} is #{this_amount}"
                else
                    reply = "Currency #{currency} not found :("
                 end
        #create the reply tweet
        puts reply

        tweet = {
            "status" => "@#{status.user.screen_name} " + reply,
            "in_reply_to_status_id" => status.id.to_s
            }
        puts tweet

        authorization = SimpleOAuth::Header.new(:post, twurl.to_s, tweet, OAUTH)

        http = EventMachine::HttpRequest.new(twurl.to_s).post({
            	:head => {"Authorization" => authorization},
            	:body => tweet
        })
        	http.errback {
                puts "[ERROR] errback"
          }
        	http.callback {
                redis.set("count", redis.get("count") + 1)
                puts "[count] = #{redis.get("count")}"
                if http.response_header.status.to_i == 200
                    puts "[HTTP_OK] #{http.response_header.status}"
                else
                    puts "[HTTP_ERROR] #{http.response_header.status}"
                end
          }
        }

        EventMachine.defer(operation, callback)
    end
end
end

