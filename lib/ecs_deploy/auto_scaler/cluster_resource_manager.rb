require "timeout"

require "aws-sdk-ecs"

module EcsDeploy
  module AutoScaler
    class ClusterResourceManager
      class DeregisterContainerInstanceFailed < StandardError; end

      MAX_DESCRIBABLE_SERVICE_COUNT = 10

      def initialize(region:, cluster:, service_configs:, logger: nil, capacity_based_on:)
        @region = region
        @cluster = cluster
        @logger = logger
        @service_configs = service_configs
        @capacity_based_on = capacity_based_on
        if @capacity_based_on != "instances" && @capacity_based_on != "vCPUs"
          raise ArgumentError, 'capacity_based_on should be either "instances" or "vCPUs"'
        end

        @mutex = Mutex.new
        @resource = ConditionVariable.new
        @used_capacity = @service_configs.sum { |s| s.desired_count * s.required_capacity }
        @capacity = calculate_active_instance_capacity
      end

      def acquire(capacity, timeout: nil)
        @mutex.synchronize do
          @logger&.debug("#{log_prefix} Try to acquire #{capacity} capacity (capacity: #{@capacity}, used_capacity: #{@used_capacity})")
          Timeout.timeout(timeout) do
            while @capacity - @used_capacity < capacity
              @resource.wait(@mutex)
            end
          end
          @used_capacity += capacity
          @logger&.debug("#{log_prefix} Acquired #{capacity} capacity (capacity: #{@capacity}, used_capacity: #{@used_capacity})")
        end
        true
      rescue Timeout::Error
        false
      end

      def release(capacity)
        @mutex.synchronize do
          @used_capacity -= capacity
          @resource.broadcast
        end
        @logger&.debug("#{log_prefix} Released #{capacity} capacity (capacity: #{@capacity}, used_capacity: #{@used_capacity})")
        true
      end

      def fetch_container_instances_in_cluster
        cl = ecs_client
        resp = cl.list_container_instances(cluster: @cluster)
        if resp.container_instance_arns.empty?
          []
        else
          resp.flat_map do |resp|
            cl.describe_container_instances(cluster: @cluster, container_instances: resp.container_instance_arns).container_instances
          end
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

      def trigger_capacity_update(old_desired_capacity, new_desired_capacity, interval: 5, wait_until_capacity_updated: false)
        th = Thread.new do
          @logger&.info "#{log_prefix} Start updating capacity: #{old_desired_capacity} -> #{new_desired_capacity}"
          Timeout.timeout(180) do
            until @capacity == new_desired_capacity || (new_desired_capacity >= old_desired_capacity && @capacity > new_desired_capacity)
              @mutex.synchronize do
                @capacity = calculate_active_instance_capacity
                @resource.broadcast
              rescue => e
                AutoScaler.error_logger.warn("#{log_prefix} `#{__method__}': #{e} (#{e.class})")
              end

              sleep interval
            end
            @logger&.info "#{log_prefix} capacity is updated to #{@capacity}"
          end
        end

        if wait_until_capacity_updated
          @logger&.info "#{log_prefix} Wait for the capacity of active instances to become #{new_desired_capacity} from #{old_desired_capacity}"
          begin
            th.join
          rescue Timeout::Error => e
            msg = "#{log_prefix} `#{__method__}': #{e} (#{e.class})"
            if @capacity_based_on == "vCPUs"
              # Timeout::Error sometimes occur.
              # For example, @capacity won't be new_desired_capacity if new_desired_capacity is odd and all instances have 2 vCPUs
              AutoScaler.error_logger.warn(msg)
            else
              AutoScaler.error_logger.error(msg)
            end
          end
        end
      end

      def calculate_active_instance_capacity
        cl = ecs_client

        if @capacity_based_on == "instances"
          return cl.list_container_instances(cluster: @cluster, status: "ACTIVE").sum do |resp|
            resp.container_instance_arns.size
          end
        end

        total_cpu = cl.list_container_instances(cluster: @cluster, status: "ACTIVE").sum do |resp|
          next 0 if resp.container_instance_arns.empty?
          ecs_client.describe_container_instances(
            cluster: @cluster,
            container_instances: resp.container_instance_arns,
          ).container_instances.sum { |ci| ci.registered_resources.find { |r| r.name == "CPU" }.integer_value }
        end

        total_cpu / 1024
      end

      private

      def ecs_client
        Aws::ECS::Client.new(
          access_key_id: EcsDeploy.config.access_key_id,
          secret_access_key: EcsDeploy.config.secret_access_key,
          region: @region,
          logger: @logger,
        )
      end

      def log_prefix
        "[#{self.class.to_s.gsub(/\AEcsDeploy::AutoScaler::/, "")} #{@region} #{@cluster}]"
      end
    end
  end
end
