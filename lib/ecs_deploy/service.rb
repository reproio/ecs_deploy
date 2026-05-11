require 'timeout'

module EcsDeploy
  class Service
    CHECK_INTERVAL = 5
    MAX_DESCRIBE_SERVICES = 10

    class TooManyAttemptsError < StandardError; end

    attr_reader :cluster, :region, :service_name, :delete, :deploy_started_at

    # Immutable service properties that can only be set at creation time
    CREATE_ONLY_KEYS = %i[launch_type scheduling_strategy].freeze

    def initialize(cluster:, service_name:, region: nil, **options)
      @cluster = cluster
      @service_name = service_name
      @options = options.dup
      @task_definition_name = @options.delete(:task_definition_name) || service_name
      @revision = @options.delete(:revision)
      @delete = @options.delete(:delete) || false
      @options[:deployment_configuration] ||= {maximum_percent: 200, minimum_healthy_percent: 100}
      @options[:placement_constraints] ||= []
      @options[:placement_strategy] ||= []
      @options[:scheduling_strategy] ||= 'REPLICA'
      @options[:enable_execute_command] ||= false

      @response = nil

      region ||= EcsDeploy.config.default_region
      params ||= EcsDeploy.config.ecs_client_params
      @client = region ? Aws::ECS::Client.new(params.merge(region: region)) : Aws::ECS::Client.new(params)
      @region = @client.config.region
    end

    def current_task_definition_arn
      res = @client.describe_services(cluster: @cluster, services: [@service_name])
      res.services[0].task_definition
    end

    def deploy
      @deploy_started_at = Time.now
      res = @client.describe_services(cluster: @cluster, services: [@service_name])

      if res.services.select{ |s| s.status == 'ACTIVE' }.empty?
        return if @delete
        create_service
      else
        return delete_service if @delete
        update_service(res.services[0])
      end
    end

    private def create_service
      service_options = @options.merge(
        cluster: @cluster,
        service_name: @service_name,
        task_definition: task_definition_name_with_revision,
      )
      service_options[:desired_count] = service_options[:desired_count].to_i

      if service_options[:load_balancers] && EcsDeploy.config.ecs_service_role
        service_options[:role] = EcsDeploy.config.ecs_service_role
      end

      if service_options[:scheduling_strategy] == 'DAEMON'
        service_options.delete(:desired_count)
        service_options.delete(:placement_strategy)
      end

      @response = @client.create_service(service_options)
      EcsDeploy.logger.info "created service [#{@service_name}] [#{@cluster}] [#{@region}] [#{Paint['OK', :green]}]"
    end

    private def update_service(current_service)
      service_options = @options.except(*CREATE_ONLY_KEYS, :tags).merge(
        cluster: @cluster,
        service: @service_name,
        task_definition: task_definition_name_with_revision,
      )
      service_options.delete(:desired_count) unless @options[:desired_count]
      service_options.delete(:propagate_tags) unless @options[:propagate_tags]
      service_options[:force_new_deployment] = true if need_force_new_deployment?(current_service)

      update_tags(@service_name, @options[:tags])
      if @options[:scheduling_strategy] == 'DAEMON'
        service_options.delete(:placement_strategy)
      end

      @response = @client.update_service(service_options)
      EcsDeploy.logger.info "updated service [#{@service_name}] [#{@cluster}] [#{@region}] [#{Paint['OK', :green]}]"
    end

    private def need_force_new_deployment?(service)
      return false unless @options[:capacity_provider_strategy]
      return true unless service.capacity_provider_strategy

      return true if @options[:capacity_provider_strategy].size != service.capacity_provider_strategy.size

      match_array = @options[:capacity_provider_strategy].all? do |strategy|
        service.capacity_provider_strategy.find do |current_strategy|
          strategy[:capacity_provider] == current_strategy.capacity_provider &&
            strategy[:weight] == current_strategy.weight &&
            strategy[:base] == current_strategy.base
        end
      end

      !match_array
    end

    def delete_service
      if @options[:scheduling_strategy] != 'DAEMON'
        @client.update_service(cluster: @cluster, service: @service_name, desired_count: 0)
        sleep 1
      end
      @client.delete_service(cluster: @cluster, service: @service_name)
      EcsDeploy.logger.info "deleted service [#{@service_name}] [#{@cluster}] [#{@region}] [#{Paint['OK', :green]}]"
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

    def log_events(ecs_service)
      ecs_service.events.sort_by(&:created_at).each do |e|
        next if e.created_at <= deploy_started_at
        next if @last_event && e.created_at <= @last_event.created_at

        EcsDeploy.logger.info e.message
        @last_event = e
      end
    end

    def self.wait_all_running(services)
      services.group_by { |s| [s.cluster, s.region] }.flat_map do |(cl, region), ss|
        params ||= EcsDeploy.config.ecs_client_params
        client = Aws::ECS::Client.new(params.merge(region: region))
        ss.reject(&:delete).map(&:service_name).each_slice(MAX_DESCRIBE_SERVICES).map do |chunked_service_names|
          Thread.new do
            EcsDeploy.config.ecs_wait_until_services_stable_max_attempts.times do
              EcsDeploy.logger.info "waiting for services to stabilize [#{chunked_service_names.join(", ")}] [#{cl}]"
              resp = client.describe_services(cluster: cl, services: chunked_service_names)
              resp.services.each do |s|
                # cf. https://github.com/aws/aws-sdk-ruby/blob/master/gems/aws-sdk-ecs/lib/aws-sdk-ecs/waiters.rb#L91-L96
                if s.deployments.size == 1 && s.running_count == s.desired_count
                  chunked_service_names.delete(s.service_name)
                end
                service = ss.detect {|sc| sc.service_name == s.service_name }
                service.log_events(s)
              end
              break if chunked_service_names.empty?
              sleep EcsDeploy.config.ecs_wait_until_services_stable_delay
            end
            raise TooManyAttemptsError unless chunked_service_names.empty?
          end
        end
      end.each(&:join)
    end

    def self.wait_all_deployment_successful(services)
      services.group_by { |s| [s.cluster, s.region] }.flat_map do |(cl, region), ss|
        params ||= EcsDeploy.config.ecs_client_params
        client = Aws::ECS::Client.new(params.merge(region: region))
        
        # Get latest deployment ARNs for each service
        service_deployment_map = {}
        ss.reject(&:delete).each do |service|
          begin
            list_resp = client.list_service_deployments(
              cluster: cl,
              service: service.service_name
            )
            if list_resp.service_deployments.any?
              service_deployment_map[service.service_name] = list_resp.service_deployments.first.service_deployment_arn
            else
              EcsDeploy.logger.warn "No deployments found for service #{service.service_name} in cluster #{cl}"
            end
          rescue Aws::ECS::Errors::ServiceError => e
            EcsDeploy.logger.warn "Failed to list service deployments for #{service.service_name}: #{e.message}"
          end
        end
        
        service_deployment_map.each_slice(MAX_DESCRIBE_SERVICES).map do |chunked_deployment_map|
          Thread.new do
            EcsDeploy.config.ecs_wait_until_services_stable_max_attempts.times do
              EcsDeploy.logger.info "waiting for deployments to be successful [#{chunked_deployment_map.keys.join(", ")}] [#{cl}]"
              
              chunked_deployment_map.dup.each do |service_name, deployment_arn|
                chunked_deployment_map.delete(service_name) if deployment_successful?(client, deployment_arn)
              end
              
              # Log service events for services in this chunk
              chunked_deployment_map.keys.each do |service_name|
                service = ss.detect {|sc| sc.service_name == service_name }
                if service
                  resp = client.describe_services(cluster: cl, services: [service_name])
                  service.log_events(resp.services.first) if resp.services.any?
                end
              end
              
              break if chunked_deployment_map.empty?
              sleep EcsDeploy.config.ecs_wait_until_services_stable_delay
            end
            raise TooManyAttemptsError unless chunked_deployment_map.empty?
          end
        end
      end.each(&:join)
    end

    private_class_method def self.deployment_successful?(client, deployment_arn)
      begin
        resp = client.describe_service_deployments(
          service_deployment_arns: [deployment_arn]
        )
        
        if resp.service_deployments.empty?
          EcsDeploy.logger.warn "Service deployment #{deployment_arn} not found, assuming completed"
          return true
        end
        
        deployment = resp.service_deployments.first
        # cf. https://docs.aws.amazon.com/AmazonECS/latest/APIReference/API_ServiceDeployment.html#API_ServiceDeployment_Contents
        case deployment.status
        when 'SUCCESSFUL', 'ROLLBACK_SUCCESSFUL'
          true
        when 'STOPPED', 'ROLLBACK_FAILED', 'STOP_REQUESTED'
          raise "Service deployment failed with status: #{deployment.status}"
        else
          false
        end
      rescue Aws::ECS::Errors::ServiceError => e
        EcsDeploy.logger.warn "Failed to describe service deployment #{deployment_arn}: #{e.message}"
        false
      end
    end

    private

    def task_definition_name_with_revision
      suffix = @revision ? ":#{@revision}" : ""
      "#{@task_definition_name}#{suffix}"
    end
  end
end
