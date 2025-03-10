require 'ecs_deploy'
require 'ecs_deploy/instance_fluctuation_manager'

namespace :ecs do
  task :configure do
    EcsDeploy.configure do |c|
      c.log_level = fetch(:ecs_log_level) if fetch(:ecs_log_level)
      c.deploy_wait_timeout = fetch(:ecs_deploy_wait_timeout) if fetch(:ecs_deploy_wait_timeout)
      c.ecs_service_role = fetch(:ecs_service_role) if fetch(:ecs_service_role)
      c.default_region = Array(fetch(:ecs_region))[0] if fetch(:ecs_region)
      c.ecs_wait_until_services_stable_max_attempts = fetch(:ecs_wait_until_services_stable_max_attempts) if fetch(:ecs_wait_until_services_stable_max_attempts)
      c.ecs_wait_until_services_stable_delay = fetch(:ecs_wait_until_services_stable_delay) if fetch(:ecs_wait_until_services_stable_delay)
      c.ecs_client_params = fetch(:ecs_client_params) if fetch(:ecs_client_params)
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
          args = t.merge({region: region, task_definition_name: t[:name]})
          task_definition = EcsDeploy::TaskDefinition.new(**args)
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
      regions = [EcsDeploy.config.default_region] if regions.empty?
      regions.each do |r|
        fetch(:ecs_scheduled_tasks).each do |t|
          args = t.merge({region: region, cluster: t[:cluster] || fetch(:ecs_default_cluster)})
          scheduled_task = EcsDeploy::ScheduledTask.new(**args)
          scheduled_task.deploy
        end
      end
    end
  end

  task deploy: [:configure, :register_task_definition] do
    if fetch(:ecs_services)
      regions = Array(fetch(:ecs_region))
      regions = [EcsDeploy.config.default_region] if regions.empty?
      regions.each do |r|
        services = fetch(:ecs_services).map do |service|
          if fetch(:target_cluster) && fetch(:target_cluster).size > 0
            next unless fetch(:target_cluster).include?(service[:cluster])
          end
          if fetch(:target_task_definition) && fetch(:target_task_definition).size > 0
            next unless fetch(:target_task_definition).include?(service[:task_definition_name])
          end

          service_options = service.merge({
            region: r,
            cluster: service[:cluster] || fetch(:ecs_default_cluster),
            service_name: service[:name],
          })

          s = EcsDeploy::Service.new(**service_options)
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
      regions = [EcsDeploy.config.default_region] if regions.empty?

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

          raise "Past task_definition_arns is empty" unless rollback_arn

          service_options = service.merge({
            region: r,
            cluster: service[:cluster] || fetch(:ecs_default_cluster),
            service_name: service[:name],
            task_definition_name: rollback_arn,
          })
          s = EcsDeploy::Service.new(**service_options)
          s.deploy
          EcsDeploy::TaskDefinition.deregister(current_task_definition_arn, region: r)
          s
        end
        EcsDeploy::Service.wait_all_running(services)
      end
    end
  end

  task increase_instances_to_max_size: [:configure] do
    configs = fetch(:ecs_instance_fluctuation_manager_configs, [])
    unless configs.empty?
      regions = Array(fetch(:ecs_region))
      regions = [EcsDeploy.config.default_region] if regions.empty?
      regions.each do |region|
        configs.each do |config|
          logger = config.fetch(:logger, EcsDeploy.logger)
          m = EcsDeploy::InstanceFluctuationManager.new(
            region: config[:region] || region,
            cluster: config[:cluster] || fetch(:ecs_default_cluster),
            auto_scaling_group_name: config[:auto_scaling_group_name],
            desired_capacity: config[:desired_capacity],
            logger: logger
          )
          m.increase
        end
      end
    end
  end

  task terminate_redundant_instances: [:configure] do
    configs = fetch(:ecs_instance_fluctuation_manager_configs, [])
    unless configs.empty?
      regions = Array(fetch(:ecs_region))
      regions = [EcsDeploy.config.default_region] if regions.empty?
      regions.each do |region|
        configs.each do |config|
          logger = config.fetch(:logger, EcsDeploy.logger)
          m = EcsDeploy::InstanceFluctuationManager.new(
            region: config[:region] || region,
            cluster: config[:cluster] || fetch(:ecs_default_cluster),
            auto_scaling_group_name: config[:auto_scaling_group_name],
            desired_capacity: config[:desired_capacity],
            logger: logger
          )
          m.decrease
        end
      end
    end
  end
end
