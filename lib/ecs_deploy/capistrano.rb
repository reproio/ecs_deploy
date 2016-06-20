require 'ecs_deploy'

namespace :ecs do
  task :configure do
    EcsDeploy.configure do |c|
      c.log_level = fetch(:ecs_log_level) if fetch(:ecs_log_level)
      c.deploy_wait_timeout = fetch(:ecs_deploy_wait_timeout) if fetch(:ecs_deploy_wait_timeout)
      c.ecs_service_role = fetch(:ecs_service_role) if fetch(:ecs_service_role)
      c.default_region = Array(fetch(:ecs_region))[0] if fetch(:ecs_region)
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
      regions = [nil] if regions.empty?
      regions.each do |r|
        fetch(:ecs_tasks).each do |t|
          task_definition = EcsDeploy::TaskDefinition.new(
            region: r,
            task_definition_name: t[:name],
            container_definitions: t[:container_definitions],
            volumes: t[:volumes]
          )
          task_definition.register

          t[:executions].to_a.each do |exec|
            exec[:cluster] ||= fetch(:ecs_default_cluster)
            task_definition.run(exec)
          end
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
            elb_name: service[:elb_name],
            elb_service_port: service[:elb_service_port],
            elb_healthcheck_port: service[:elb_healthcheck_port],
            elb_container_name: service[:elb_container_name],
            desired_count: service[:desired_count],
          }
          service_options[:deployment_configuration] = service[:deployment_configuration] if service[:deployment_configuration]
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

          current_arn_index = task_definition_arns.index do |arn|
            arn == current_task_definition_arn
          end

          rollback_arn = task_definition_arns[current_arn_index + rollback_step]

          EcsDeploy.logger.info "#{current_task_definition_arn} -> #{rollback_arn}"

          raise "Past task_definition_arns is nothing" unless rollback_arn

          service_options = {
            region: r,
            cluster: service[:cluster] || fetch(:ecs_default_cluster),
            service_name: service[:name],
            task_definition_name: rollback_arn,
            elb_name: service[:elb_name],
            elb_service_port: service[:elb_service_port],
            elb_healthcheck_port: service[:elb_healthcheck_port],
            elb_container_name: service[:elb_container_name],
            desired_count: service[:desired_count],
          }
          service_options[:deployment_configuration] = service[:deployment_configuration] if service[:deployment_configuration]
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
