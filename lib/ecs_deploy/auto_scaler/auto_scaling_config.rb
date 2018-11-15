require "aws-sdk-autoscaling"
require "aws-sdk-ec2"
require "aws-sdk-ecs"
require "ecs_deploy"
require "ecs_deploy/auto_scaler/config_base"

module EcsDeploy
  module AutoScaler
    AutoScalingConfig = Struct.new(:name, :region, :buffer) do
      include ConfigBase

      def client
        Aws::AutoScaling::Client.new(
          access_key_id: EcsDeploy.config.access_key_id,
          secret_access_key: EcsDeploy.config.secret_access_key,
          region: region,
          logger: logger
        )
      end

      def ec2_client
        Aws::EC2::Client.new(
          access_key_id: EcsDeploy.config.access_key_id,
          secret_access_key: EcsDeploy.config.secret_access_key,
          region: region,
          logger: logger
        )
      end

      def instances(reload: false)
        if reload || @instances.nil?
          resp = client.describe_auto_scaling_groups({
            auto_scaling_group_names: [name],
          })
          @instances = resp.auto_scaling_groups[0].instances
        else
          @instances
        end
      end

      def update_auto_scaling_group(total_service_count, service_config)
        desired_capacity = total_service_count + buffer.to_i

        current_asg = client.describe_auto_scaling_groups({
          auto_scaling_group_names: [name],
        }).auto_scaling_groups[0]

        if current_asg.desired_capacity > desired_capacity
          diff = current_asg.desired_capacity - desired_capacity
          container_instance_arns_in_service = service_config.fetch_container_instance_arns_in_service
          container_instances_in_cluster = service_config.fetch_container_instances_in_cluster
          deregisterable_instances = container_instances_in_cluster.select do |i|
            i.pending_tasks_count == 0 && !running_essential_task?(i, container_instance_arns_in_service)
          end

          AutoScaler.logger.info "Fetch deregisterable instances: #{deregisterable_instances.map(&:ec2_instance_id).inspect}"

          deregistered_instance_ids = []
          deregisterable_instances.each do |i|
            break if deregistered_instance_ids.size >= diff
            begin
              service_config.client.deregister_container_instance(cluster: service_config.cluster, container_instance: i.container_instance_arn, force: true)
              deregistered_instance_ids << i.ec2_instance_id
            rescue Aws::ECS::Errors::InvalidParameterException
            end
          end

          AutoScaler.logger.info "Deregistered instances: #{deregistered_instance_ids.inspect}"

          detach_and_terminate_instances(deregistered_instance_ids)

          AutoScaler.logger.info "Update auto scaling group \"#{name}\": desired_capacity -> #{desired_capacity}"
        elsif current_asg.desired_capacity < desired_capacity
          client.update_auto_scaling_group(
            auto_scaling_group_name: name,
            min_size: 0,
            max_size: [current_asg.max_size, desired_capacity].max,
            desired_capacity: desired_capacity,
          )
          AutoScaler.logger.info "Update auto scaling group \"#{name}\": desired_capacity -> #{desired_capacity}"
        end
      rescue => e
        AutoScaler.error_logger.error(e)
      end

      def detach_and_terminate_instances(instance_ids)
        return if instance_ids.empty?

        instance_ids.each_slice(MAX_DETACHABLE_INSTANCE_COUNT) do |ids|
          client.detach_instances(
            auto_scaling_group_name: name,
            instance_ids: ids,
            should_decrement_desired_capacity: true
          )
        end

        AutoScaler.logger.info "Detach instances from ASG #{name}: #{instance_ids.inspect}"
        sleep 3

        ec2_client.terminate_instances(instance_ids: instance_ids)

        AutoScaler.logger.info "Terminated instances: #{instance_ids.inspect}"
      rescue => e
        AutoScaler.error_logger.error(e)
      end

      def detach_and_terminate_orphan_instances(service_config)
        container_instance_ids = service_config.fetch_container_instances_in_cluster.map(&:ec2_instance_id)
        orphans = instances(reload: true).reject { |i| container_instance_ids.include?(i.instance_id) }.map(&:instance_id)

        return if orphans.empty?

        targets = ec2_client.describe_instances(instance_ids: orphans).reservations[0].instances.select do |i|
          (Time.now - i.launch_time) > 600
        end

        detach_and_terminate_instances(targets.map(&:instance_id))
      rescue => e
        AutoScaler.error_logger.error(e)
      end

      def running_essential_task?(instance, container_instance_arns_in_service)
        return false if instance.running_tasks_count == 0

        container_instance_arns_in_service.include?(instance.container_instance_arn)
      end
    end
  end
end
