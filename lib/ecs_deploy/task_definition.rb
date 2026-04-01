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

    def initialize(task_definition_name:, region: nil, **options)
      @task_definition_name = task_definition_name
      region ||= EcsDeploy.config.default_region
      params ||= EcsDeploy.config.ecs_client_params

      @options = options.dup
      @options[:network_mode] ||= "bridge"
      @options[:volumes] ||= []
      @options[:container_definitions] ||= []
      @options[:placement_constraints] ||= []
      @options[:runtime_platform] ||= {}

      @options[:container_definitions] = @options[:container_definitions].map do |cd|
        if cd[:docker_labels]
          cd[:docker_labels] = cd[:docker_labels].map { |k, v| [k.to_s, v] }.to_h
        end
        if cd.dig(:log_configuration, :options)
          cd[:log_configuration][:options] = cd.dig(:log_configuration, :options).map { |k, v| [k.to_s, v] }.to_h
        end
        cd
      end
      @options[:cpu] = @options[:cpu]&.to_s
      @options[:memory] = @options[:memory]&.to_s

      @client = region ? Aws::ECS::Client.new(params.merge(region: region)) : Aws::ECS::Client.new(params)
      @region = @client.config.region
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
      res = @client.register_task_definition(
        @options.merge(family: @task_definition_name)
      )
      EcsDeploy.logger.info "registered task definition [#{@task_definition_name}] [#{@region}] [#{Paint['OK', :green]}]"
      res.task_definition
    end
  end
end
