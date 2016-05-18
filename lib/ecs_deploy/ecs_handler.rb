require 'aws-sdk'

module EcsDeploy
  class ECSHandler
    attr_reader :clients

    def initialize(access_key_id: nil, secret_access_key: nil, regions: [])
      @clients = {}
      regions = [EcsDeploy.config.default_region].compact if regions.nil? || regions.empty?

      access_key_id ||= EcsDeploy.config.access_key_id
      secret_access_key ||= EcsDeploy.config.secret_access_key

      if regions.empty?
        cl = Aws::ECS::Client.new(
          access_key_id: access_key_id,
          secret_access_key: secret_access_key
        )
        region = cl.config.region
        raise "No region" unless region
        @clients[region] = cl
      else
        regions.each do |r|
          @clients[r] = Aws::ECS::Client.new(
            access_key_id: access_key_id,
            secret_access_key: secret_access_key,
            region: r
          )
        end
      end
    end
  end
end
