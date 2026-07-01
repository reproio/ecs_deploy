require 'timeout'

module EcsDeploy
  class Service
    CHECK_INTERVAL = 5
    MAX_DESCRIBE_SERVICES = 10

    class TooManyAttemptsError < StandardError; end

    attr_reader :cluster, :region, :service_name, :delete, :deploy_started_at, :wait_strategy

    # Options that Aws::ECS::Client#update_service will not honor on an existing
    # service:
    # - launch_type / scheduling_strategy: not in update_service's parameter list
    # - role / client_token: create-only, no update-side equivalent
    # - deployment_controller: accepted by update_service in aws-sdk-ecs 1.238+
    #   but AWS rejects any change to the controller type at runtime
    CREATE_ONLY_KEYS = %i[launch_type scheduling_strategy role client_token deployment_controller].freeze

    VALID_WAIT_STRATEGIES = %i[legacy none service_deployment].freeze
    ECS_NATIVE_BLUE_GREEN_STRATEGIES = %w[BLUE_GREEN LINEAR CANARY].freeze

    def initialize(cluster:, service_name:, region: nil, **options)
      @cluster = cluster
      @service_name = service_name
      @options = options.dup
      @task_definition_name = @options.delete(:task_definition_name) || service_name
      @revision = @options.delete(:revision)
      @delete = @options.delete(:delete) || false
      @wait_strategy = @options.delete(:wait_strategy)
      # Snapshot the keys the user actually passed in, so warnings only fire on
      # options the caller explicitly set (not on defaults injected below).
      @user_provided_keys = (options.keys - %i[task_definition_name revision delete wait_strategy]).freeze
      if @wait_strategy && !VALID_WAIT_STRATEGIES.include?(@wait_strategy)
        raise ArgumentError, "Invalid wait_strategy #{@wait_strategy.inspect}, expected nil or one of #{VALID_WAIT_STRATEGIES.inspect}"
      end
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
      warn_on_ignored_options(current_service)

      service_options = @options.except(*CREATE_ONLY_KEYS, :tags).merge(
        cluster: @cluster,
        service: @service_name,
        task_definition: task_definition_name_with_revision,
      )
      # If the user did not set these explicitly, leave them out so ECS keeps
      # its current values (desired_count is often managed by autoscaling;
      # propagate_tags reflects an existing policy).
      service_options.delete(:desired_count)  unless @options.key?(:desired_count)
      service_options.delete(:propagate_tags) unless @options.key?(:propagate_tags)
      service_options[:force_new_deployment] = true if need_force_new_deployment?(current_service)
      service_options.delete(:placement_strategy) if @options[:scheduling_strategy] == 'DAEMON'

      update_tags(@service_name, @options[:tags])

      @response = @client.update_service(service_options)
      EcsDeploy.logger.info "updated service [#{@service_name}] [#{@cluster}] [#{@region}] [#{Paint['OK', :green]}]"
    end

    # Log a warning for user-supplied options that update_service cannot apply.
    # Silently drop keys whose value matches the current service (harmless
    # re-declaration of the current state); warn only when the user's value
    # would actually change something.
    private def warn_on_ignored_options(current_service)
      CREATE_ONLY_KEYS.each do |key|
        next unless @user_provided_keys.include?(key)
        next if create_only_matches_current?(key, current_service)
        EcsDeploy.logger.warn "[#{@service_name}] option #{key.inspect} cannot be applied by update_service (current: #{create_only_current_display(current_service, key).inspect}, requested: #{@options[key].inspect}), skipping"
      end
    end

    private def create_only_matches_current?(key, current_service)
      case key
      when :launch_type
        @options[key].to_s == current_service.launch_type.to_s
      when :scheduling_strategy
        @options[key].to_s == current_service.scheduling_strategy.to_s
      when :deployment_controller
        Hash(@options[key])[:type].to_s == current_service.deployment_controller&.type.to_s
      else
        # role / client_token have no meaningful "current" comparison; always warn.
        false
      end
    end

    private def create_only_current_display(current_service, key)
      case key
      when :launch_type          then current_service.launch_type
      when :scheduling_strategy  then current_service.scheduling_strategy
      when :deployment_controller then current_service.deployment_controller&.type
      end
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

    def skip_wait?
      case @wait_strategy
      when :none
        true
      when :legacy, :service_deployment
        false
      when nil
        ecs_native_blue_green?
      end
    end

    private def ecs_native_blue_green?
      svc = @response&.service
      return false unless svc&.deployment_controller&.type == "ECS"
      strategy = svc.deployment_configuration&.strategy.to_s
      ECS_NATIVE_BLUE_GREEN_STRATEGIES.include?(strategy)
    end

    def self.wait_all_running(services)
      threads = services.group_by { |s| [s.cluster, s.region] }.flat_map do |(cl, region), ss|
        params = EcsDeploy.config.ecs_client_params
        client = Aws::ECS::Client.new(params.merge(region: region))

        targets = ss.reject(&:delete).reject do |s|
          if s.skip_wait?
            EcsDeploy.logger.info "skip waiting for service [#{s.service_name}] [#{cl}]: ECS-managed deployment, monitor via ecs:describe_deployment"
            true
          else
            false
          end
        end

        legacy_targets = targets.reject { |s| s.wait_strategy == :service_deployment }
        sd_targets = targets.select { |s| s.wait_strategy == :service_deployment }

        legacy_threads(client, cl, ss, legacy_targets) + service_deployment_threads(client, cl, sd_targets)
      end
      threads.each(&:join)
    end

    def self.legacy_threads(client, cluster, all_services, targets)
      targets.map(&:service_name).each_slice(MAX_DESCRIBE_SERVICES).map do |chunked_service_names|
        Thread.new do
          EcsDeploy.config.ecs_wait_until_services_stable_max_attempts.times do
            EcsDeploy.logger.info "waiting for services to stabilize [#{chunked_service_names.join(", ")}] [#{cluster}]"
            resp = client.describe_services(cluster: cluster, services: chunked_service_names)
            resp.services.each do |s|
              # cf. https://github.com/aws/aws-sdk-ruby/blob/master/gems/aws-sdk-ecs/lib/aws-sdk-ecs/waiters.rb#L91-L96
              if s.deployments.size == 1 && s.running_count == s.desired_count
                chunked_service_names.delete(s.service_name)
              end
              service = all_services.detect { |sc| sc.service_name == s.service_name }
              service&.log_events(s)
            end
            break if chunked_service_names.empty?
            sleep EcsDeploy.config.ecs_wait_until_services_stable_delay
          end
          raise TooManyAttemptsError unless chunked_service_names.empty?
        end
      end
    end

    def self.service_deployment_threads(client, cluster, targets)
      targets.map do |service|
        Thread.new do
          pending = true
          EcsDeploy.config.ecs_wait_until_services_stable_max_attempts.times do
            EcsDeploy.logger.info "waiting for service deployment to settle [#{service.service_name}] [#{cluster}]"
            arns = client.list_service_deployments(
              cluster: cluster,
              service: service.service_name,
              status: %w[IN_PROGRESS PENDING],
            ).service_deployments.map(&:service_deployment_arn)
            if arns.empty?
              pending = false
              break
            end
            sleep EcsDeploy.config.ecs_wait_until_services_stable_delay
          end
          raise TooManyAttemptsError if pending
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
