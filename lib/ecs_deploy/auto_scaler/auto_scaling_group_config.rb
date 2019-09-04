require "aws-sdk-autoscaling"
require "aws-sdk-ec2"
require "ecs_deploy"
require "ecs_deploy/auto_scaler/config_base"
require "ecs_deploy/auto_scaler/cluster_resource_manager"

module EcsDeploy
  module AutoScaler
    AutoScalingGroupConfig = Struct.new(:name, :region, :cluster, :buffer, :service_configs) do
      include ConfigBase

      MAX_DETACHABLE_INSTANCE_COUNT = 20

      def initialize(attributes = {}, logger)
        attributes = attributes.dup
        services = attributes.delete("services")
        super(attributes, logger)
        self.service_configs = services.map do |s|
          ServiceConfig.new(s.merge("cluster" => cluster, "region" => region), logger)
        end
      end

      def update_desired_capacity(required_capacity)
        detach_and_terminate_orphan_instances

        desired_capacity = (required_capacity + buffer.to_f).ceil

        current_asg = client.describe_auto_scaling_groups({
          auto_scaling_group_names: [name],
        }).auto_scaling_groups[0]

        if current_asg.desired_capacity > desired_capacity
          decreased_capacity = decrease_desired_capacity(current_asg.desired_capacity - desired_capacity)
          if decreased_capacity > 0
            new_desired_capacity = current_asg.desired_capacity - decreased_capacity
            cluster_resource_manager.trigger_capacity_update(current_asg.desired_capacity, new_desired_capacity)
            @logger.info "Update auto scaling group \"#{name}\": desired_capacity -> #{new_desired_capacity}"
          else
            @logger.info "Tried to Update auto scaling group \"#{name}\" but there were no deregisterable instances"
          end
        elsif current_asg.desired_capacity < desired_capacity
          client.update_auto_scaling_group(
            auto_scaling_group_name: name,
            min_size: 0,
            max_size: [current_asg.max_size, desired_capacity].max,
            desired_capacity: desired_capacity,
          )
          cluster_resource_manager.trigger_capacity_update(current_asg.desired_capacity, desired_capacity)
          @logger.info "Update auto scaling group \"#{name}\": desired_capacity -> #{desired_capacity}"
        end
      rescue => e
        AutoScaler.error_logger.error(e)
      end

      def cluster_resource_manager
        @cluster_resource_manager ||= EcsDeploy::AutoScaler::ClusterResourceManager.new(
          region: region,
          cluster: cluster,
          service_configs: service_configs,
          capacity_based_on: "instances",
          logger: @logger,
        )
      end

      private

      def decrease_desired_capacity(count)
        container_instance_arns_in_service = cluster_resource_manager.fetch_container_instance_arns_in_service
        container_instances_in_cluster = cluster_resource_manager.fetch_container_instances_in_cluster
        deregisterable_instances = container_instances_in_cluster.select do |i|
          i.pending_tasks_count == 0 && !running_essential_task?(i, container_instance_arns_in_service)
        end

        @logger.info "Fetch deregisterable instances: #{deregisterable_instances.map(&:ec2_instance_id).inspect}"

        az_to_instance_count = instances(reload: true).each_with_object(Hash.new(0)) { |i, h| h[i.availability_zone] += 1 }
        az_to_deregisterable_instances = deregisterable_instances.group_by do |i|
          i.attributes.find { |a| a.name == "ecs.availability-zone" }.value
        end

        deregistered_instance_ids = []
        prev_max_count = nil
        # Select instances to be deregistered keeping the balance of instance count per availability zone
        while deregistered_instance_ids.size < count
          max_count = az_to_instance_count.each_value.max
          break if max_count == prev_max_count # No more deregistable instances with keeping the balance

          azs = az_to_instance_count.select { |_, c| c == max_count }.keys
          azs.each do |az|
            instance = az_to_deregisterable_instances[az]&.pop
            next if instance.nil?
            begin
              cluster_resource_manager.deregister_container_instance(instance.container_instance_arn)
              deregistered_instance_ids << instance.ec2_instance_id
              az_to_instance_count[az] -= 1
            rescue EcsDeploy::AutoScaler::ClusterResourceManager::DeregisterContainerInstanceFailed
            end
            break if deregistered_instance_ids.size >= count
          end
          prev_max_count = max_count
        end

        @logger.info "Deregistered instances: #{deregistered_instance_ids.inspect}"

        detach_and_terminate_instances(deregistered_instance_ids)

        deregistered_instance_ids.size
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

        @logger.info "Detach instances from ASG #{name}: #{instance_ids.inspect}"
        sleep 3

        ec2_client.terminate_instances(instance_ids: instance_ids)

        @logger.info "Terminated instances: #{instance_ids.inspect}"
      rescue => e
        AutoScaler.error_logger.error(e)
      end

      def detach_and_terminate_orphan_instances
        container_instance_ids = cluster_resource_manager.fetch_container_instances_in_cluster.map(&:ec2_instance_id)
        orphans = instances(reload: true).reject { |i| container_instance_ids.include?(i.instance_id) }.map(&:instance_id)

        return if orphans.empty?

        targets = ec2_client.describe_instances(instance_ids: orphans).reservations.flat_map(&:instances).select do |i|
          (Time.now - i.launch_time) > 600
        end

        detach_and_terminate_instances(targets.map(&:instance_id))
      rescue => e
        AutoScaler.error_logger.error(e)
      end

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

      def running_essential_task?(instance, container_instance_arns_in_service)
        return false if instance.running_tasks_count == 0

        container_instance_arns_in_service.include?(instance.container_instance_arn)
      end
    end
  end
end
