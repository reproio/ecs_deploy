module EcsDeploy
  class Configuration
    attr_accessor \
      :log_level,
      :access_key_id,
      :secret_access_key,
      :default_region,
      :deploy_wait_timeout,
      :ecs_service_role,
      :ecs_wait_until_services_stable_max_attempts,
      :ecs_wait_until_services_stable_delay

    def initialize
      @log_level = :info
      @deploy_wait_timeout = 300
    end
  end
end
