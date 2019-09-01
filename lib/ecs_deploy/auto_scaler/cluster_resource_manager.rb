require "aws-sdk-ecs"

module EcsDeploy
  module AutoScaler
    class ClusterResourceManager
      class DeregisterContainerInstanceFailed < StandardError; end

      def initialize(region:, cluster:, buffer:, service_configs:, logger: nil)
        @region = region
        @cluster = cluster
        @buffer = buffer
        @logger = logger
        @service_configs = service_configs
      end

      def desired_capacity
        (@service_configs.sum { |s| s.desired_count * s.required_capacity } + @buffer.to_f).ceil
      end

      def fetch_container_instances_in_cluster
        cl = ecs_client
        cl.list_container_instances(cluster: @cluster).flat_map do |resp|
          cl.describe_container_instances(cluster: @cluster, container_instances: resp.container_instance_arns).container_instances
        end
      end

      def fetch_container_instance_arns_in_service
        task_groups = @service_configs.map { |s| "service:#{s.name}" }
        ecs_client.list_container_instances(cluster: @cluster, filter: "task:group in [#{task_groups.join(",")}]").flat_map(&:container_instance_arns)
      end

      def deregister_container_instance(container_instance_arn)
        ecs_client.deregister_container_instance(cluster: @cluster, container_instance: container_instance_arn, force: true)
      rescue Aws::ECS::Errors::InvalidParameterException
        raise DeregisterContainerInstanceFailed
      end

      def ecs_client
        Aws::ECS::Client.new(
          access_key_id: EcsDeploy.config.access_key_id,
          secret_access_key: EcsDeploy.config.secret_access_key,
          region: @region,
          logger: @logger,
        )
      end
    end
  end
end
