require 'sinatra'
require "http"
require 'json'
require "base64"
require 'twilio-ruby'
require "redis"

client_id = 'staging-hackathalon'
client_secret = 'ac2c2f5b-cea8-4c62-9b28-a6de77e221df'
service_name = "Dove"

redis = Redis.new

registered_users = {
	# "9810181713" => '77cb89f5-35da-4011-92f1-deffd0972200',
	"7838121295" => 'e7fdbe44-2c8d-43ca-8c17-269b2d78cdfa'
}

def send_twilio_message(to_number, message)
	account_sid = 'ACce698a0c8a05f3cb16eb6f928faed8ea'
	auth_token = '0b03d049efc458da06e4b702c6347bb6'

	# set up a client to talk to the Twilio REST API
	@client = Twilio::REST::Client.new account_sid, auth_token
	@client.account.messages.create({
		:from => '+12058815273',
		:to => to_number,
		:body => message,
	})
end

def check_bal(redis, me, registered_users)
	sms_message = nil

	check_balance_api_url = 'https://trust-uat.paytm.in/wallet-web/checkBalance'
	me.slice! "+91"
	
	user_token = redis.get("user_tokens:#{me}")
	if user_token
		response = HTTP.headers(:ssotoken => user_token).post(check_balance_api_url)

		if response.code != 200
			puts "Failed Request | #{response.code}"
		else
			json_response = JSON.parse(response.body)
			amount = json_response['response']['amount']
			sms_message = "\nHi!\nYour wallet balance is : " + amount.to_s
		end
	else
		sms_message = "\nSorry! We don't have any account associated with +91-" + me + "\nSend 'paytm reg <email>' to register your number"
	end
	
	if sms_message
		send_twilio_message("+91" + me, sms_message)
	end
end

def reg_user(redis, mobile_number, email, client_id)
	sms_message = nil
	
	register_user_api_url = "https://accounts-uat.paytm.com/signin/otp"
	mobile_number.slice! "+91"

	get_state_hash = {
		:email => email,
		:phone => mobile_number,
		:clientId => client_id,
		:scope => 'wallet',
		:responseType => 'token'
	}

	response = HTTP.post(register_user_api_url, :body => get_state_hash.to_json)
	if response.code != 200
		puts "Failed Request | #{response.code}"
	else
		sms_message = "\nFinal Step! Send the OTP received as 'paytm validate <OTP>' from your registered mobile number"
		redis_key = "validate_state:" + mobile_number
		json_response = JSON.parse(response.body)
		redis.set(redis_key, json_response['state'])
	end

	if sms_message
		send_twilio_message("+91" + mobile_number, sms_message)
	end
end

def validate_user(redis, client_id, client_secret, mobile_number, user_otp)
	sms_message = nil

	validate_user_api_url = "https://accounts-uat.paytm.com/signin/validate/otp"
	mobile_number.slice! "+91"

	basic_auth = "Basic "<<Base64.strict_encode64("#{client_id}:#{client_secret}")
	get_token_hash = {
		:otp => user_otp,
		:state => redis.get("validate_state:#{mobile_number}")
	}
	puts get_token_hash[:state]
	puts get_token_hash[:state].class
	response = HTTP.headers("Authorization" => basic_auth, "Content-Type" => 'application/json').post(validate_user_api_url, :body => get_token_hash.to_json)
	if response.code != 200
		puts "Failed Request | #{response.code}"
	else
		sms_message = "\nCongrats\n You can now use Dove!"
		json_response = JSON.parse(response.body)
		puts json_response["access_token"]
		puts response.body
		redis.set("user_tokens:#{mobile_number}", json_response["access_token"])
	end
end


get '/' do
	mobile_number = params['from']
	message = params['message']
	mobile_number[0] = '+'
	tokens = message.split()
	if tokens[0].downcase == "paytm"
		case tokens[1].downcase
		when 'send', 'pay'
			puts 'call API 1'
		when 'balance', 'bal'
			puts "entering balance"
			check_bal(redis, mobile_number, registered_users)
		when 'register', 'reg'
			puts "entering registration"
			email = tokens[2].downcase
			reg_user(redis, mobile_number, email, client_id)
		when 'validate'
			puts "entering registration step 2"
			user_otp = tokens[2].downcase
			validate_user(redis, client_id, client_secret, mobile_number, user_otp)
		end
	end
	"YOLO | Flow Succesful"
end

get '/getToken' do
	
end

get '/transfer' do
	from = params['from']
	to = params['to']
	amt = params['amt'].to_i

	query = {
		:request => {
			:isToVerify => 0,
			:isLimitApplicable => 0,
			:payeeEmail => "",
			:payeeMobile => to,
			:payeeCustId => "",
			:amount => amt,
			:currencyCode => "INR",
			:comment => "Loan"
		},
		:ipAddress => "127.0.0.1",
		:platformName => "PayTM",
		:operationType => "P2P_TRANSFER"
	}

	response = HTTP.headers(:ssotoken => registered_users[from]).post('https://trust-uat.paytm.in/wallet-web/wrapper/p2pTransfer', :body => query.to_json)
	if response.code != 200
		"Failed Transfer request"
	else
		response.body
	end
end
