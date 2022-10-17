require "json"
require "timeout"

require "aws-sdk-ec2"
require "ecs_deploy"
require "ecs_deploy/auto_scaler/config_base"
require "ecs_deploy/auto_scaler/cluster_resource_manager"

module EcsDeploy
  module AutoScaler
    SpotFleetRequestConfig = Struct.new(:id, :region, :cluster, :buffer, :service_configs, :disable_draining) do
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

      def update_desired_capacity(required_capacity)
        terminate_orphan_instances

        desired_capacity = (required_capacity + buffer.to_f).ceil

        request_config = ec2_client.describe_spot_fleet_requests(
          spot_fleet_request_ids: [id]
        ).spot_fleet_request_configs[0].spot_fleet_request_config

        return if desired_capacity == request_config.target_capacity

        ec2_client.modify_spot_fleet_request(spot_fleet_request_id: id, target_capacity: desired_capacity)

        cluster_resource_manager.trigger_capacity_update(
          request_config.target_capacity,
          desired_capacity,
          # Wait until the capacity is updated to prevent the process from terminating before container draining is completed
          wait_until_capacity_updated: desired_capacity < request_config.target_capacity,
        )
        @logger.info "#{log_prefix} Update desired_capacity to #{desired_capacity}"
      rescue => e
        AutoScaler.error_logger.error(e)
      end

      def cluster_resource_manager
        @cluster_resource_manager ||= EcsDeploy::AutoScaler::ClusterResourceManager.new(
          region: region,
          cluster: cluster,
          service_configs: service_configs,
          capacity_based_on: "vCPUs",
          logger: @logger,
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

        @logger.info "#{log_prefix} Terminated instances: #{instance_ids.inspect}"
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

      def log_prefix
        "[#{self.class.to_s.sub(/\AEcsDeploy::AutoScaler::/, "")} #{name} #{region}]"
      end
    end
  end
end
