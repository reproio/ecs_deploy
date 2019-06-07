require 'ecs_deploy'

namespace :ecs do
  task :configure do
    EcsDeploy.configure do |c|
      c.log_level = fetch(:ecs_log_level) if fetch(:ecs_log_level)
      c.deploy_wait_timeout = fetch(:ecs_deploy_wait_timeout) if fetch(:ecs_deploy_wait_timeout)
      c.ecs_service_role = fetch(:ecs_service_role) if fetch(:ecs_service_role)
      c.default_region = Array(fetch(:ecs_region))[0] if fetch(:ecs_region)
      c.ecs_wait_until_services_stable_max_attempts = fetch(:ecs_wait_until_services_stable_max_attempts) if fetch(:ecs_wait_until_services_stable_max_attempts)
      c.ecs_wait_until_services_stable_delay = fetch(:ecs_wait_until_services_stable_delay) if fetch(:ecs_wait_until_services_stable_delay)
    end

    if ENV["TARGET_CLUSTER"]
      set :target_cluster, ENV["TARGET_CLUSTER"].split(",").map(&:strip)
    end
    if ENV["TARGET_TASK_DEFINITION"]
      set :target_task_definition, ENV["TARGET_TASK_DEFINITION"].split(",").map(&:strip)
    end
  end

  task register_task_definition: [:configure] do
    if fetch(:ecs_tasks)
      regions = Array(fetch(:ecs_region))
      regions = [EcsDeploy.config.default_region] if regions.empty?
      ecs_registered_tasks = {}
      regions.each do |region|
        ecs_registered_tasks[region] = {}
        fetch(:ecs_tasks).each do |t|
          task_definition = EcsDeploy::TaskDefinition.new(
            region: region,
            task_definition_name: t[:name],
            container_definitions: t[:container_definitions],
            task_role_arn: t[:task_role_arn],
            execution_role_arn: t[:execution_role_arn],
            volumes: t[:volumes],
            network_mode: t[:network_mode],
            placement_constraints: t[:placement_constraints],
            requires_compatibilities: t[:requires_compatibilities],
            cpu: t[:cpu],
            memory: t[:memory],
            tags: t[:tags],
          )
          result = task_definition.register
          ecs_registered_tasks[region][t[:name]] = result
        end
      end

      set :ecs_registered_tasks, ecs_registered_tasks
    end
  end

  task deploy_scheduled_task: [:configure, :register_task_definition] do
    if fetch(:ecs_scheduled_tasks)
      regions = Array(fetch(:ecs_region))
      regions = [nil] if regions.empty?
      regions.each do |r|
        fetch(:ecs_scheduled_tasks).each do |t|
          scheduled_task = EcsDeploy::ScheduledTask.new(
            region: r,
            cluster: t[:cluster] || fetch(:ecs_default_cluster),
            rule_name: t[:rule_name],
            schedule_expression: t[:schedule_expression],
            enabled: t[:enabled] != false,
            description: t[:description],
            target_id: t[:target_id],
            task_definition_name: t[:task_definition_name],
            network_configuration: t[:network_configuration],
            launch_type: t[:launch_type],
            platform_version: t[:platform_version],
            group: t[:group],
            revision: t[:revision],
            task_count: t[:task_count],
            role_arn: t[:role_arn],
            container_overrides: t[:container_overrides],
          )
          scheduled_task.deploy
        end
      end
    end
  end

  task deploy: [:configure, :register_task_definition] do
    if fetch(:ecs_services)
      regions = Array(fetch(:ecs_region))
      regions = [nil] if regions.empty?
      regions.each do |r|
        services = fetch(:ecs_services).map do |service|
          if fetch(:target_cluster) && fetch(:target_cluster).size > 0
            next unless fetch(:target_cluster).include?(service[:cluster])
          end
          if fetch(:target_task_definition) && fetch(:target_task_definition).size > 0
            next unless fetch(:target_task_definition).include?(service[:task_definition_name])
          end

          service_options = {
            region: r,
            cluster: service[:cluster] || fetch(:ecs_default_cluster),
            service_name: service[:name],
            task_definition_name: service[:task_definition_name],
            load_balancers: service[:load_balancers],
            desired_count: service[:desired_count],
            launch_type: service[:launch_type],
            network_configuration: service[:network_configuration],
            health_check_grace_period_seconds: service[:health_check_grace_period_seconds],
            delete: service[:delete],
            enable_ecs_managed_tags: service[:enable_ecs_managed_tags],
            tags: service[:tags],
            propagate_tags: service[:propagate_tags],
          }
          service_options[:deployment_configuration] = service[:deployment_configuration] if service[:deployment_configuration]
          service_options[:placement_constraints] = service[:placement_constraints] if service[:placement_constraints]
          service_options[:placement_strategy] = service[:placement_strategy] if service[:placement_strategy]
          service_options[:scheduling_strategy] = service[:scheduling_strategy] if service[:scheduling_strategy]
          s = EcsDeploy::Service.new(service_options)
          s.deploy
          s
        end
        EcsDeploy::Service.wait_all_running(services)
      end
    end
  end

  task rollback: [:configure] do
    if fetch(:ecs_services)
      regions = Array(fetch(:ecs_region))
      regions = [nil] if regions.empty?

      rollback_routes = {}
      regions.each do |r|
        services = fetch(:ecs_services).map do |service|
          if fetch(:target_cluster) && fetch(:target_cluster).size > 0
            next unless fetch(:target_cluster).include?(service[:cluster])
          end
          if fetch(:target_task_definition) && fetch(:target_task_definition).size > 0
            next unless fetch(:target_task_definition).include?(service[:task_definition_name])
          end

          task_definition_arns = EcsDeploy::TaskDefinition.new(
            region: r,
            task_definition_name: service[:task_definition_name] || service[:name],
          ).recent_task_definition_arns

          rollback_step = (ENV["STEP"] || 1).to_i

          current_task_definition_arn = EcsDeploy::Service.new(
            region: r,
            cluster: service[:cluster] || fetch(:ecs_default_cluster),
            service_name: service[:name],
          ).current_task_definition_arn

          unless (rollback_arn = rollback_routes[current_task_definition_arn])
            current_arn_index = task_definition_arns.index do |arn|
              arn == current_task_definition_arn
            end

            rollback_arn = task_definition_arns[current_arn_index + rollback_step]

            rollback_routes[current_task_definition_arn] = rollback_arn
          end

          EcsDeploy.logger.info "#{current_task_definition_arn} -> #{rollback_arn}"

          raise "Past task_definition_arns is nothing" unless rollback_arn

          service_options = {
            region: r,
            cluster: service[:cluster] || fetch(:ecs_default_cluster),
            service_name: service[:name],
            task_definition_name: rollback_arn,
            load_balancers: service[:load_balancers],
            desired_count: service[:desired_count],
            launch_type: service[:launch_type],
            network_configuration: service[:network_configuration],
            health_check_grace_period_seconds: service[:health_check_grace_period_seconds],
          }
          service_options[:deployment_configuration] = service[:deployment_configuration] if service[:deployment_configuration]
          service_options[:placement_constraints] = service[:placement_constraints] if service[:placement_constraints]
          service_options[:placement_strategy] = service[:placement_strategy] if service[:placement_strategy]
          s = EcsDeploy::Service.new(service_options)
          s.deploy
          EcsDeploy::TaskDefinition.deregister(current_task_definition_arn, region: r)
          s
        end
        EcsDeploy::Service.wait_all_running(services)
      end
    end
  end
end
