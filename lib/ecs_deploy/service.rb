require 'timeout'

module EcsDeploy
  class Service
    CHECK_INTERVAL = 5
    MAX_DESCRIBE_SERVICES = 10

    class TooManyAttemptsError < StandardError; end

    attr_reader :cluster, :region, :service_name, :delete

    def initialize(
      cluster:, service_name:, task_definition_name: nil, revision: nil,
      load_balancers: nil,
      desired_count: nil, deployment_configuration: {maximum_percent: 200, minimum_healthy_percent: 100},
      launch_type: nil,
      placement_constraints: [],
      placement_strategy: [],
      capacity_provider_strategy: nil,
      network_configuration: nil,
      health_check_grace_period_seconds: nil,
      scheduling_strategy: 'REPLICA',
      enable_ecs_managed_tags: nil,
      tags: nil,
      propagate_tags: nil,
      region: nil,
      delete: false,
      enable_execute_command: false
    )
      @cluster = cluster
      @service_name = service_name
      @task_definition_name = task_definition_name || service_name
      @load_balancers = load_balancers
      @desired_count = desired_count
      @deployment_configuration = deployment_configuration
      @launch_type = launch_type
      @placement_constraints = placement_constraints
      @placement_strategy = placement_strategy
      @capacity_provider_strategy = capacity_provider_strategy
      @network_configuration = network_configuration
      @health_check_grace_period_seconds = health_check_grace_period_seconds
      @scheduling_strategy = scheduling_strategy
      @revision = revision
      @enable_ecs_managed_tags = enable_ecs_managed_tags
      @tags = tags
      @propagate_tags = propagate_tags
      @enable_execute_command = enable_execute_command

      @response = nil

      region ||= EcsDeploy.config.default_region
      @client = region ? Aws::ECS::Client.new(region: region) : Aws::ECS::Client.new
      @region = @client.config.region

      @delete = delete
    end

    def current_task_definition_arn
      res = @client.describe_services(cluster: @cluster, services: [@service_name])
      res.services[0].task_definition
    end

    def deploy
      res = @client.describe_services(cluster: @cluster, services: [@service_name])
      service_options = {
        cluster: @cluster,
        task_definition: task_definition_name_with_revision,
        deployment_configuration: @deployment_configuration,
        network_configuration: @network_configuration,
        health_check_grace_period_seconds: @health_check_grace_period_seconds,
        capacity_provider_strategy: @capacity_provider_strategy,
        enable_execute_command: @enable_execute_command,
        enable_ecs_managed_tags: @enable_ecs_managed_tags,
        placement_constraints: @placement_constraints,
        placement_strategy: @placement_strategy,
      }

      if @load_balancers && EcsDeploy.config.ecs_service_role
        service_options.merge!({
          role: EcsDeploy.config.ecs_service_role,
        })
      end

      if @load_balancers
        service_options.merge!({
          load_balancers: @load_balancers,
        })
      end

      if res.services.select{ |s| s.status == 'ACTIVE' }.empty?
        return if @delete

        service_options.merge!({
          service_name: @service_name,
          desired_count: @desired_count.to_i,
          launch_type: @launch_type,
          tags: @tags,
          propagate_tags: @propagate_tags,
        })

        if @scheduling_strategy == 'DAEMON'
          service_options[:scheduling_strategy] = @scheduling_strategy
          service_options.delete(:desired_count)
        end
        @response = @client.create_service(service_options)
        EcsDeploy.logger.info "create service [#{@service_name}] [#{@cluster}] [#{@region}] [#{Paint['OK', :green]}]"
      else
        return delete_service if @delete

        service_options.merge!({service: @service_name})
        service_options.merge!({desired_count: @desired_count}) if @desired_count

        current_service = res.services[0]
        service_options.merge!({force_new_deployment: true}) if need_force_new_deployment?(current_service)

        update_tags(@service_name, @tags)
        @response = @client.update_service(service_options)
        EcsDeploy.logger.info "update service [#{@service_name}] [#{@cluster}] [#{@region}] [#{Paint['OK', :green]}]"
      end
    end

    private def need_force_new_deployment?(service)
      return false unless @capacity_provider_strategy
      return true unless service.capacity_provider_strategy

      return true if @capacity_provider_strategy.size != service.capacity_provider_strategy.size

      match_array = @capacity_provider_strategy.all? do |strategy|
        service.capacity_provider_strategy.find do |current_strategy|
          strategy[:capacity_provider] == current_strategy.capacity_provider &&
            strategy[:weight] == current_strategy.weight &&
            strategy[:base] == current_strategy.base
        end
      end

      !match_array
    end

    def delete_service
      if @scheduling_strategy != 'DAEMON'
        @client.update_service(cluster: @cluster, service: @service_name, desired_count: 0)
        sleep 1
      end
      @client.delete_service(cluster: @cluster, service: @service_name)
      EcsDeploy.logger.info "delete service [#{@service_name}] [#{@cluster}] [#{@region}] [#{Paint['OK', :green]}]"
    end

    def update_tags(service_name, tags)
      service_arn = @client.describe_services(cluster: @cluster, services: [service_name]).services.first.service_arn
      if service_arn.split('/').size == 2
        if tags
          EcsDeploy.logger.warn "#{service_name} doesn't support tagging operations, so tags are ignored. Long arn format must be used for tagging operations."
        end
        return
      end

      tags ||= []
      current_tag_keys = @client.list_tags_for_resource(resource_arn: service_arn).tags.map(&:key)
      deleted_tag_keys = current_tag_keys - tags.map { |t| t[:key] }

      unless deleted_tag_keys.empty?
        @client.untag_resource(resource_arn: service_arn, tag_keys: deleted_tag_keys)
      end

      unless tags.empty?
        @client.tag_resource(resource_arn: service_arn, tags: tags)
      end
    end

    def self.wait_all_running(services)
      services.group_by { |s| [s.cluster, s.region] }.flat_map do |(cl, region), ss|
        client = Aws::ECS::Client.new(region: region)
        ss.reject(&:delete).map(&:service_name).each_slice(MAX_DESCRIBE_SERVICES).map do |chunked_service_names|
          Thread.new do
            EcsDeploy.config.ecs_wait_until_services_stable_max_attempts.times do
              EcsDeploy.logger.info "wait service stable [#{chunked_service_names.join(", ")}] [#{cl}]"
              resp = client.describe_services(cluster: cl, services: chunked_service_names)
              resp.services.each do |s|
                # cf. https://github.com/aws/aws-sdk-ruby/blob/master/gems/aws-sdk-ecs/lib/aws-sdk-ecs/waiters.rb#L91-L96
                if s.deployments.size == 1 && s.running_count == s.desired_count
                  chunked_service_names.delete(s.service_name)
                end
              end
              break if chunked_service_names.empty?
              sleep EcsDeploy.config.ecs_wait_until_services_stable_delay
            end
            raise TooManyAttemptsError unless chunked_service_names.empty?
          end
        end
      end.each(&:join)
    end

    private

    def task_definition_name_with_revision
      suffix = @revision ? ":#{@revision}" : ""
      "#{@task_definition_name}#{suffix}"
    end
  end
end
