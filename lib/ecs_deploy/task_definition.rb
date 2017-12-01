module EcsDeploy
  class TaskDefinition
    def self.deregister(arn, region: nil)
      region = region || EcsDeploy.config.default_region || ENV["AWS_DEFAULT_REGION"]
      client = Aws::ECS::Client.new(region: region)
      client.deregister_task_definition({
        task_definition: arn,
      })
      EcsDeploy.logger.info "deregister task definition [#{arn}] [#{region}] [#{Paint['OK', :green]}]"
    end

    def initialize(
      task_definition_name:, region: nil,
      network_mode: "bridge", volumes: [], container_definitions: [], placement_constraints: [],
      task_role_arn: nil
    )
      @task_definition_name = task_definition_name
      @task_role_arn        = task_role_arn
      @region = region || EcsDeploy.config.default_region
      options = {}
      options[:region] = @region if @region
      @container_definitions = container_definitions.map do |cd|
        if cd[:docker_labels]
          cd[:docker_labels] = cd[:docker_labels].map { |k, v| [k.to_s, v] }.to_h
        end
        if cd[:log_configuration] && cd[:log_configuration][:options]
          cd[:log_configuration][:options] = cd[:log_configuration][:options].map { |k, v| [k.to_s, v] }.to_h
        end
        cd
      end
      @volumes = volumes
      @network_mode = network_mode
      @placement_constraints = placement_constraints

      @client = Aws::ECS::Client.new(options)
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
      })
      EcsDeploy.logger.info "register task definition [#{@task_definition_name}] [#{@region}] [#{Paint['OK', :green]}]"
      res.task_definition
    end
  end
end
