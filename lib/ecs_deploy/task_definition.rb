module EcsDeploy
  class TaskDefinition
    def self.deregister(arn, region: nil)
      region ||= EcsDeploy.config.default_region
      params ||= EcsDeploy.config.ecs_client_params
      client = region ? Aws::ECS::Client.new(params.merge(region: region)) : Aws::ECS::Client.new(params)
      client.deregister_task_definition({
        task_definition: arn,
      })
      EcsDeploy.logger.info "deregistered task definition [#{arn}] [#{client.config.region}] [#{Paint['OK', :green]}]"
    end

    def initialize(
      task_definition_name:, region: nil,
      network_mode: "bridge", volumes: [], container_definitions: [], placement_constraints: [],
      task_role_arn: nil,
      execution_role_arn: nil,
      requires_compatibilities: nil,
      cpu: nil, memory: nil,
      tags: nil,
      runtime_platform: {}
    )
      @task_definition_name = task_definition_name
      @task_role_arn        = task_role_arn
      @execution_role_arn   = execution_role_arn
      region ||= EcsDeploy.config.default_region
      params ||= EcsDeploy.config.ecs_client_params

      @container_definitions = container_definitions.map do |cd|
        if cd[:docker_labels]
          cd[:docker_labels] = cd[:docker_labels].map { |k, v| [k.to_s, v] }.to_h
        end
        if cd.dig(:log_configuration, :options)
          cd[:log_configuration][:options] = cd.dig(:log_configuration, :options).map { |k, v| [k.to_s, v] }.to_h
        end
        cd
      end
      @volumes = volumes
      @network_mode = network_mode
      @placement_constraints = placement_constraints
      @requires_compatibilities = requires_compatibilities
      @cpu = cpu&.to_s
      @memory = memory&.to_s
      @tags = tags
      @client = region ? Aws::ECS::Client.new(params.merge(region: region)) : Aws::ECS::Client.new(params)
      @region = @client.config.region
      @runtime_platform = runtime_platform
    end

    def recent_task_definition_arns
      resp = @client.list_task_definitions(
        family_prefix: @task_definition_name,
        sort: "DESC"
      )
      resp.task_definition_arns
    rescue
      []
    end

    def register
      res = @client.register_task_definition({
        family: @task_definition_name,
        network_mode: @network_mode,
        container_definitions: @container_definitions,
        volumes: @volumes,
        placement_constraints: @placement_constraints,
        task_role_arn: @task_role_arn,
        execution_role_arn: @execution_role_arn,
        requires_compatibilities: @requires_compatibilities,
        cpu: @cpu, memory: @memory,
        tags: @tags,
        runtime_platform: @runtime_platform
      })
      EcsDeploy.logger.info "registered task definition [#{@task_definition_name}] [#{@region}] [#{Paint['OK', :green]}]"
      res.task_definition
    end
  end
end
