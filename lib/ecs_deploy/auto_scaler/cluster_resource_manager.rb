require "timeout"

require "aws-sdk-ecs"

module EcsDeploy
  module AutoScaler
    class ClusterResourceManager
      class DeregisterContainerInstanceFailed < StandardError; end

      MAX_DESCRIBABLE_SERVICE_COUNT = 10

      def initialize(region:, cluster:, service_configs:, buffer: 0, logger: nil, capacity_based_on:, update_remaining_capacity_interval: 5)
        @region = region
        @cluster = cluster
        @buffer = buffer
        @logger = logger
        @service_configs = service_configs
        @capacity_based_on = capacity_based_on
        if @capacity_based_on != "instances" && @capacity_based_on != "vCPUs"
          raise ArgumentError, 'capacity_based_on should be either "instances" or "vCPUs"'
        end

        @mutex = Mutex.new
        @resource = ConditionVariable.new
        @remaining_capacity = 0
        @update_remaining_capacity_interval = update_remaining_capacity_interval
      end

      def acquire(capacity)
        with_updating_remaining_capacity do
          Timeout.timeout(300) do
            @mutex.synchronize do
              @logger&.debug("[#{self.class}, region: #{@region}, cluster: #{@cluster}] Try to acquire #{capacity} capacity (remaining_capacity: #{@remaining_capacity})")
              while @remaining_capacity < capacity
                @resource.wait(@mutex)
              end
              @remaining_capacity -= capacity
              @logger&.debug("[#{self.class}, region: #{@region}, cluster: #{@cluster}] Acquired #{capacity} capacity (remaining_capacity: #{@remaining_capacity})")
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

      def desired_capacity
        (@service_configs.sum { |s| s.desired_count * s.required_capacity } + @buffer.to_f).ceil
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

      private

      def ecs_client
        Aws::ECS::Client.new(
          access_key_id: EcsDeploy.config.access_key_id,
          secret_access_key: EcsDeploy.config.secret_access_key,
          region: @region,
          logger: @logger,
        )
      end

      def with_updating_remaining_capacity
        @mutex.synchronize do
          @updating_remaining_capacity_count ||= 0
          @updating_remaining_capacity_count += 1
          @updating_remaining_capacity_thread ||= Thread.new do
            @logger&.debug("[#{self.class}, region: #{@region}, cluster: #{@cluster}] Start updating remaining capacity")
            stop = false
            until stop
              required_capacity = @service_configs.sum { |s| s.updated_desired_count * s.required_capacity }
              @mutex.synchronize do
                begin
                  @remaining_capacity = calculate_active_instance_capacity - required_capacity
                  @resource.signal
                rescue => e
                  AutoScaler.error_logger.warn("`#{__method__}': #{e} (#{e.class})")
                end
              end

              sleep @update_remaining_capacity_interval

              @mutex.synchronize do
                if @updating_remaining_capacity_count.zero?
                  @updating_remaining_capacity_thread = nil
                  stop = true
                end
              end
            end

            @logger&.debug("[#{self.class}, region: #{@region}, cluster: #{@cluster}] Stop updating remaining capacity")
          end
        end

        yield
      ensure
        @mutex.synchronize do
          @updating_remaining_capacity_count -= 1
        end
      end
    end
  end
end
