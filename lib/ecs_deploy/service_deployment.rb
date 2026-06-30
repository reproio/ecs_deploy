module EcsDeploy
  module ServiceDeployment
    IN_FLIGHT_STATUSES = %w[IN_PROGRESS PENDING].freeze
    DESCRIBE_STATUSES = %w[IN_PROGRESS PENDING STOPPED].freeze

    class HookNotFoundError < StandardError; end

    module_function

    def describe(services:, regions:, default_cluster:)
      each_target(services: services, regions: regions, default_cluster: default_cluster) do |client, cluster, svc|
        deployments = list_deployments(client, cluster, svc[:name], statuses: DESCRIBE_STATUSES)
        next if deployments.empty?
        deployments.each { |d| log_deployment(d) }
      end
    end

    def invoke_lifecycle_hook(hook_id:, action:, services:, regions:, default_cluster:)
      found = false
      each_target(services: services, regions: regions, default_cluster: default_cluster) do |client, cluster, svc|
        deployments = list_deployments(client, cluster, svc[:name], statuses: IN_FLIGHT_STATUSES)
        deployments.each do |d|
          next unless Array(d.lifecycle_hook_details).any? { |h| h.hook_id == hook_id }
          client.continue_service_deployment(
            service_deployment_arn: d.service_deployment_arn,
            hook_id: hook_id,
            action: action,
          )
          EcsDeploy.logger.info "#{action.downcase}d lifecycle_hook=#{hook_id} service_deployment_arn=#{d.service_deployment_arn}"
          found = true
        end
      end
      raise HookNotFoundError, "Lifecycle hook #{hook_id} not found in any in-progress service deployment" unless found
    end

    def stop(service_deployment_arn:, region:, stop_type: nil)
      client = Aws::ECS::Client.new(EcsDeploy.config.ecs_client_params.merge(region: region))
      params = { service_deployment_arn: service_deployment_arn }
      params[:stop_type] = stop_type if stop_type
      client.stop_service_deployment(params)
      EcsDeploy.logger.info "stopped service_deployment_arn=#{service_deployment_arn}#{stop_type ? " stop_type=#{stop_type}" : ""}"
    end

    def each_target(services:, regions:, default_cluster:)
      services.each do |svc|
        cluster = svc[:cluster] || default_cluster
        regions.each do |r|
          client = Aws::ECS::Client.new(EcsDeploy.config.ecs_client_params.merge(region: r))
          yield client, cluster, svc
        end
      end
    end

    def list_deployments(client, cluster, service_name, statuses:)
      arns = client.list_service_deployments(
        cluster: cluster,
        service: service_name,
        status: statuses,
      ).service_deployments.map(&:service_deployment_arn)
      return [] if arns.empty?
      client.describe_service_deployments(service_deployment_arns: arns).service_deployments
    end

    def log_deployment(d)
      EcsDeploy.logger.info "service_deployment_arn=#{d.service_deployment_arn} status=#{d.status} lifecycle_stage=#{d.lifecycle_stage}"
      Array(d.lifecycle_hook_details).each do |hook|
        EcsDeploy.logger.info "  hook_id=#{hook.hook_id} target=#{hook.target_type} status=#{hook.status} expires_at=#{hook.expires_at} timeout_action=#{hook.timeout_action}"
      end
    end
  end
end
