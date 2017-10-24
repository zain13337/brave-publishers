module Eyeshade
  class Balance
    attr_reader :balance_json, :probi, :currency, :altcurrency, :amount, :rates

    def initialize(balance_json:)
      @balance_json = balance_json

      @probi = Integer(balance_json['probi'])
      @currency = balance_json['currency']
      @altcurrency = balance_json['altcurrency']
      @amount = balance_json['amount'].to_f

      @rates = {"BAT" => 1.0}
      balance_json['rates'].each_pair do |k,v|
        @rates[k.upcase] = v.to_f
      end
    end

    def BAT
      @probi / BigDecimal.new('1.0e18')
    end

    def convert_to(currency_code = 'USD')
      rate = rates[currency_code.upcase]
      raise "Missing currency conversion rate #{currency_code.upcase} for #{@balance_json}" unless rate

      self.BAT * rate
    end
  end
end