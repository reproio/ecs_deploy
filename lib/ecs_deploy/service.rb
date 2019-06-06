require 'timeout'

module EcsDeploy
  class Service
    CHECK_INTERVAL = 5
    MAX_DESCRIBE_SERVICES = 10

    attr_reader :cluster, :region, :service_name, :delete

    def initialize(
      cluster:, service_name:, task_definition_name: nil, revision: nil,
      load_balancers: nil,
      desired_count: nil, deployment_configuration: {maximum_percent: 200, minimum_healthy_percent: 100},
      launch_type: nil,
      placement_constraints: [],
      placement_strategy: [],
      network_configuration: nil,
      health_check_grace_period_seconds: nil,
      scheduling_strategy: 'REPLICA',
      enable_ecs_managed_tags: nil,
      tags: nil,
      propagate_tags: nil,
      region: nil,
      delete: false
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
      @network_configuration = network_configuration
      @health_check_grace_period_seconds = health_check_grace_period_seconds
      @scheduling_strategy = scheduling_strategy
      @revision = revision
      @enable_ecs_managed_tags = enable_ecs_managed_tags
      @tags = tags
      @propagate_tags = propagate_tags

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
      }
      if res.services.select{ |s| s.status == 'ACTIVE' }.empty?
        return if @delete

        service_options.merge!({
          service_name: @service_name,
          desired_count: @desired_count.to_i,
          launch_type: @launch_type,
          placement_constraints: @placement_constraints,
          placement_strategy: @placement_strategy,
          enable_ecs_managed_tags: @enable_ecs_managed_tags,
          tags: @tags,
          propagate_tags: @propagate_tags,
        })

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

        if @scheduling_strategy == 'DAEMON'
          service_options[:scheduling_strategy] = @scheduling_strategy
          service_options.delete(:desired_count)
        end
        @response = @client.create_service(service_options)
        EcsDeploy.logger.info "create service [#{@service_name}] [#{@region}] [#{Paint['OK', :green]}]"
      else
        return delete_service if @delete

        service_options.merge!({service: @service_name})
        service_options.merge!({desired_count: @desired_count}) if @desired_count
        update_tags(@service_name, @tags)
        @response = @client.update_service(service_options)
        EcsDeploy.logger.info "update service [#{@service_name}] [#{@region}] [#{Paint['OK', :green]}]"
      end
    end

    def delete_service
      if @scheduling_strategy != 'DAEMON'
        @client.update_service(cluster: @cluster, service: @service_name, desired_count: 0)
        sleep 1
      end
      @client.delete_service(cluster: @cluster, service: @service_name)
      EcsDeploy.logger.info "delete service [#{@service_name}] [#{@region}] [#{Paint['OK', :green]}]"
    end

    def update_tags(service_name, tags)
      service_arn = @client.describe_services(services: [service_name]).services.first.service_arn
      if service_arn.split('/').size == 2 && tags
        EcsDeploy.logger.warn "#{service_name} doesn't support tagging operations, so tags are ignored. Long arn format must be used for tagging operations."
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

    def wait_running
      return if @response.nil?

      service = @response.service

      @client.wait_until(:services_stable, cluster: @cluster, services: [service.service_name]) do |w|
        w.delay = EcsDeploy.config.ecs_wait_until_services_stable_delay if EcsDeploy.config.ecs_wait_until_services_stable_delay
        w.max_attempts = EcsDeploy.config.ecs_wait_until_services_stable_max_attempts if EcsDeploy.config.ecs_wait_until_services_stable_max_attempts

        w.before_attempt do
          EcsDeploy.logger.info "wait service stable [#{service.service_name}]"
        end
      end
    end

    def self.wait_all_running(services)
      services.group_by { |s| [s.cluster, s.region] }.each do |(cl, region), ss|
        client = Aws::ECS::Client.new(region: region)
        ss.reject(&:delete).map(&:service_name).each_slice(MAX_DESCRIBE_SERVICES) do |chunked_service_names|
          client.wait_until(:services_stable, cluster: cl, services: chunked_service_names) do |w|
            w.delay = EcsDeploy.config.ecs_wait_until_services_stable_delay if EcsDeploy.config.ecs_wait_until_services_stable_delay
            w.max_attempts = EcsDeploy.config.ecs_wait_until_services_stable_max_attempts if EcsDeploy.config.ecs_wait_until_services_stable_max_attempts

            w.before_attempt do
              EcsDeploy.logger.info "wait service stable [#{chunked_service_names.join(", ")}]"
            end
          end
        end
      end
    end

    private

    def task_definition_name_with_revision
      suffix = @revision ? ":#{@revision}" : ""
      "#{@task_definition_name}#{suffix}"
    end
  end
end
