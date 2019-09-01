require "json"
require "timeout"

require "aws-sdk-ec2"
require "aws-sdk-ecs"
require "ecs_deploy"
require "ecs_deploy/auto_scaler/config_base"
require "ecs_deploy/auto_scaler/cluster_resource_manager"

module EcsDeploy
  module AutoScaler
    SpotFleetRequestConfig = Struct.new(:id, :region, :cluster, :buffer, :service_configs) do
      include ConfigBase

      def initialize(attributes = {}, logger)
        attributes = attributes.dup
        services = attributes.delete("services")
        super(attributes, logger)
        self.service_configs = services.map do |s|
          ServiceConfig.new(s.merge("cluster" => cluster, "region" => region), logger)
        end
      end

      def name
        id
      end

      def update_desired_capacity
        terminate_orphan_instances

        desired_capacity = cluster_resource_manager.desired_capacity

        request_config = ec2_client.describe_spot_fleet_requests(
          spot_fleet_request_ids: [id]
        ).spot_fleet_request_configs[0].spot_fleet_request_config

        return if desired_capacity == request_config.target_capacity

        ec2_client.modify_spot_fleet_request(spot_fleet_request_id: id, target_capacity: desired_capacity)
        if desired_capacity < request_config.target_capacity
          wait_for_capacity_decrease(cluster, request_config.target_capacity - desired_capacity)
        end
        @logger.info "Update spot fleet request \"#{id}\": desired_capacity -> #{desired_capacity}"
      rescue => e
        AutoScaler.error_logger.error(e)
      end

      def cluster_resource_manager
        @cluster_resource_manager ||= EcsDeploy::AutoScaler::ClusterResourceManager.new(
          region: region,
          cluster: cluster,
          buffer: buffer,
          service_configs: service_configs,
        )
      end

      private

      def terminate_orphan_instances
        container_instance_ids = cluster_resource_manager.fetch_container_instances_in_cluster.map(&:ec2_instance_id)
        spot_fleet_instances = ec2_client.describe_spot_fleet_instances(spot_fleet_request_id: id).active_instances
        orphans = spot_fleet_instances.reject { |i| container_instance_ids.include?(i.instance_id) }.map(&:instance_id)

        return if orphans.empty?

        running_instances = ec2_client.describe_instances(
          instance_ids: orphans,
          filters: [{ name: "instance-state-name", values: ["running"] }],
        ).reservations.flat_map(&:instances)
        # instances which have just launched might not be registered to the cluster yet.
        instance_ids = running_instances.select { |i| (Time.now - i.launch_time) > 600 }.map(&:instance_id)

        return if instance_ids.empty?

        # Terminate orpahns without canceling spot instance request
        # because we can't terminate canceled spot instances by decreasing the capacity
        ec2_client.terminate_instances(instance_ids: instance_ids)

        @logger.info "Terminated instances: #{instance_ids.inspect}"
      rescue => e
        AutoScaler.error_logger.error(e)
      end

      def ec2_client
        Aws::EC2::Client.new(
          access_key_id: EcsDeploy.config.access_key_id,
          secret_access_key: EcsDeploy.config.secret_access_key,
          region: region,
          logger: logger,
        )
      end

      def ecs_client
        Aws::ECS::Client.new(
          access_key_id: EcsDeploy.config.access_key_id,
          secret_access_key: EcsDeploy.config.secret_access_key,
          region: region,
          logger: logger,
        )
      end

      def wait_for_capacity_decrease(cluster, capacity)
        initial_capacity = calculate_active_instance_capacity(cluster)
        @logger.info "Wait for the capacity of active instances becoming #{initial_capacity - capacity} from #{initial_capacity}"
        Timeout.timeout(180) do
          loop do
            break if calculate_active_instance_capacity(cluster) <= initial_capacity - capacity
            sleep 5
          end
        end
      rescue Timeout::Error => e
        AutoScaler.error_logger.warn("`#{__method__}': #{e} (#{e.class})")
      end

      def calculate_active_instance_capacity(cluster)
        cl = ecs_client
        total_cpu = cl.list_container_instances(cluster: cluster, status: "ACTIVE").sum do |resp|
          next 0 if resp.container_instance_arns.empty?
          ecs_client.describe_container_instances(
            cluster: cluster,
            container_instances: resp.container_instance_arns,
          ).container_instances.sum { |ci| ci.registered_resources.find { |r| r.name == "CPU" }.integer_value }
        end

        total_cpu / 1024
      end
    end
  end
end
