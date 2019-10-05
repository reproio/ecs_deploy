require "aws-sdk-ecs"
require "ecs_deploy"
require "ecs_deploy/auto_scaler/config_base"
require "ecs_deploy/auto_scaler/trigger_config"

module EcsDeploy
  module AutoScaler
    SERVICE_CONFIG_ATTRIBUTES = %i(name cluster region step max_task_count min_task_count idle_time scheduled_min_task_count cooldown_time_for_reach_max upscale_triggers downscale_triggers desired_count required_capacity)
    ServiceConfig = Struct.new(*SERVICE_CONFIG_ATTRIBUTES) do
      include ConfigBase

      MAX_DESCRIBABLE_TASK_COUNT = 100

      def initialize(attributes = {}, logger)
        super
        self.idle_time ||= 60
        self.max_task_count = Array(max_task_count)
        self.upscale_triggers = upscale_triggers.to_a.map do |t|
          TriggerConfig.new({"region" => region, "step" => step}.merge(t), logger)
        end
        self.downscale_triggers = downscale_triggers.to_a.map do |t|
          TriggerConfig.new({"region" => region, "step" => step}.merge(t), logger)
        end
        self.max_task_count.sort!
        self.desired_count = fetch_service.desired_count
        self.required_capacity ||= 1
        @reach_max_at = nil
        @last_updated_at = nil
        @logger = logger
      end

      def adjust_desired_count(cluster_resource_manager)
        if idle?
          @logger.debug "#{name} is idling"
          return
        end

        difference = 0
        upscale_triggers.each do |trigger|
          next if difference >= trigger.step

          if trigger.match?
            @logger.info "#{log_prefix} Fire upscale trigger by #{trigger.alarm_name} #{trigger.state}"
            difference = trigger.step
          end
        end

        if difference == 0 && desired_count > current_min_task_count
          downscale_triggers.each do |trigger|
            next unless trigger.match?

            @logger.info "#{log_prefix} Fire downscale trigger by #{trigger.alarm_name} #{trigger.state}"
            difference = [difference, -trigger.step].min
          end
        end

        if current_min_task_count > desired_count + difference
          difference = current_min_task_count - desired_count
        end

        if difference >= 0 && desired_count > max_task_count.max
          difference = max_task_count.max - desired_count
        end

        if difference != 0
          update_service(difference, cluster_resource_manager)
        end
      end

      def wait_until_desired_count_updated
        @increase_desired_count_thread&.join
      rescue => e
        AutoScaler.error_logger.warn("`#{__method__}': #{e} (#{e.class})")
      ensure
        @increase_desired_count_thread = nil
      end

      private

      def client
        Aws::ECS::Client.new(
          access_key_id: EcsDeploy.config.access_key_id,
          secret_access_key: EcsDeploy.config.secret_access_key,
          region: region,
          logger: logger
        )
      end

      def idle?
        return false unless @last_updated_at

        diff = Process.clock_gettime(Process::CLOCK_MONOTONIC, :second) - @last_updated_at
        diff < idle_time
      end

      def current_min_task_count
        return min_task_count if scheduled_min_task_count.nil? || scheduled_min_task_count.empty?

        scheduled_min_task_count.find(-> { {"count" => min_task_count} }) { |s|
          from = Time.parse(s["from"])
          to = Time.parse(s["to"])
          (from..to).cover?(Time.now)
        }["count"]
      end

      def overheat?
        return false unless @reach_max_at
        (Process.clock_gettime(Process::CLOCK_MONOTONIC, :second) - @reach_max_at) > cooldown_time_for_reach_max
      end

      def fetch_service
        res = client.describe_services(cluster: cluster, services: [name])
        raise "Service \"#{name}\" is not found" if res.services.empty?
        res.services[0]
      rescue => e
        AutoScaler.error_logger.error(e)
      end

      def update_service(difference, cluster_resource_manager)
        next_desired_count = desired_count + difference
        current_level = max_task_level(desired_count)
        next_level = max_task_level(next_desired_count)
        if current_level < next_level && overheat? # next max
          level = next_level
          @reach_max_at = nil
          @logger.info "#{log_prefix} Service is overheat, uses next max count"
        elsif current_level < next_level && !overheat? # wait cooldown
          level = current_level
          now = Process.clock_gettime(Process::CLOCK_MONOTONIC, :second)
          @reach_max_at ||= now
          @logger.info "#{log_prefix} Service waits cooldown elapsed #{(now - @reach_max_at).to_i}sec"
        elsif current_level == next_level && next_desired_count >= max_task_count[current_level] # reach current max
          level = current_level
          now = Process.clock_gettime(Process::CLOCK_MONOTONIC, :second)
          @reach_max_at ||= now
          @logger.info "#{log_prefix} Service waits cooldown elapsed #{(now - @reach_max_at).to_i}sec"
        elsif current_level == next_level && next_desired_count < max_task_count[current_level]
          level = current_level
          @reach_max_at = nil
          @logger.info "#{log_prefix} Service clears cooldown state"
        elsif current_level > next_level
          level = next_level
          @reach_max_at = nil
          @logger.info "#{log_prefix} Service clears cooldown state"
        end

        next_desired_count = [next_desired_count, max_task_count[level]].min
        if next_desired_count > desired_count
          increase_desired_count(next_desired_count - desired_count, cluster_resource_manager)
        else
          decrease_desired_count(desired_count - next_desired_count, cluster_resource_manager)
        end

        @last_updated_at = Process.clock_gettime(Process::CLOCK_MONOTONIC, :second)
        @logger.info "#{log_prefix} Update desired_count to #{next_desired_count}"
      rescue => e
        AutoScaler.error_logger.error(e)
      end

      def increase_desired_count(by, cluster_resource_manager)
        applied_desired_count = desired_count
        self.desired_count += by

        wait_until = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 180
        @increase_desired_count_thread = Thread.new do
          cl = client
          by.times do
            timeout = wait_until - Process.clock_gettime(Process::CLOCK_MONOTONIC)
            break if timeout <= 0
            break unless cluster_resource_manager.acquire(required_capacity, timeout: timeout)
            begin
              cl.update_service(cluster: cluster, service: name, desired_count: applied_desired_count + 1)
              applied_desired_count += 1
            rescue => e
              cluster_resource_manager.release(required_capacity)
              AutoScaler.error_logger.error(e)
              break
            end
          end

          if applied_desired_count != desired_count
            self.desired_count = applied_desired_count
            @logger.info "#{log_prefix} Failed to update service and set desired_count to #{desired_count}"
          end
        end
      end

      def decrease_desired_count(by, cluster_resource_manager)
        cl = client
        running_task_arns = cl.list_tasks(cluster: cluster, service_name: name, desired_status: "RUNNING").flat_map(&:task_arns)

        cl.update_service(cluster: cluster, service: name, desired_count: desired_count - by)

        cl.wait_until(:services_stable, cluster: cluster, services: [name]) do |w|
          w.before_wait do
            @logger.debug "#{log_prefix} wait service stable"
          end
        end

        stopping_task_arns = running_task_arns - cl.list_tasks(cluster: cluster, service_name: name, desired_status: "RUNNING").flat_map(&:task_arns)
        stopping_task_arns.each_slice(MAX_DESCRIBABLE_TASK_COUNT) do |arns|
          cl.wait_until(:tasks_stopped, cluster: cluster, tasks: arns) do |w|
            w.before_wait do
              @logger.debug "#{log_prefix} wait stopping tasks stopped"
            end
          end
        end

        cluster_resource_manager.release(required_capacity * by)
        self.desired_count -= by
      end

      def max_task_level(count)
        max_task_count.index { |i| count <= i } || max_task_count.size - 1
      end

      def log_prefix
        "[#{self.class.to_s.sub(/\AEcsDeploy::AutoScaler::/, "")} #{name} #{region}]"
      end
    end
  end
end
