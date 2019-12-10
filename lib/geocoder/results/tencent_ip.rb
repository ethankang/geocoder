require 'geocoder/results/base'

module Geocoder::Result
  class TencentIp < Base
    def coordinates
      ['lat', 'lng'].map{ |i| @data['location'][i] }
    end

    def state
      province
    end

    def province
      ad_info['province']
    end

    def city
      ad_info['city']
    end

    def district
      ad_info['district']
    end

    def street
      ""
    end

    def street_number
      ""
    end

    def state_code
      ""
    end

    def postal_code
      ""
    end

    def country
      "China"
    end

    def country_code
      "CN"
    end

    private

    def ad_info
      @data['ad_info']
    end
  end
end
