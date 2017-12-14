module EcsDeploy
  class Configuration
    attr_accessor \
      :log_level,
      :access_key_id,
      :secret_access_key,
      :default_region,
      :deploy_wait_timeout,
      :ecs_service_role,
      :ecs_service_wait_until_max_attempts,
      :ecs_service_wait_until_delay

    def initialize
      @log_level = :info
      @deploy_wait_timeout = 300
      @ecs_service_role = "ecsServiceRole"
    end
  end
end
