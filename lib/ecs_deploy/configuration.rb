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
      :ecs_wait_until_services_stable_delay,
      :ecs_client_params,
      :ecs_wait_for_deployment_success

    def initialize
      @log_level = :info
      @deploy_wait_timeout = 300
      # The following values are the default values of Aws::ECS::Waiters::ServicesStable
      @ecs_wait_until_services_stable_max_attempts = 40
      @ecs_wait_until_services_stable_delay = 15
      @ecs_client_params = {}
      @ecs_wait_for_deployment_success = false
    end
  end
end
