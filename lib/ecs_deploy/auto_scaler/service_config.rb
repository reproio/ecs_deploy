require "aws-sdk-ecs"
require "ecs_deploy"
require "ecs_deploy/auto_scaler/config_base"
require "ecs_deploy/auto_scaler/trigger_config"

module EcsDeploy
  module AutoScaler
    SERVICE_CONFIG_ATTRIBUTES = %i(name cluster region auto_scaling_group_name step max_task_count min_task_count idle_time scheduled_min_task_count cooldown_time_for_reach_max upscale_triggers downscale_triggers desired_count)
    ServiceConfig = Struct.new(*SERVICE_CONFIG_ATTRIBUTES) do
      include ConfigBase

      MAX_DETACHABLE_INSTANCE_COUNT = 20

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
        @reach_max_at = nil
        @last_updated_at = nil
        @logger = logger
      end

      def adjust_desired_count
        if idle?
          @logger.debug "#{name} is idling"
          return
        end

        difference = 0
        upscale_triggers.each do |trigger|
          next if difference >= trigger.step

          if trigger.match?
            @logger.info "Fire upscale trigger of #{name} by #{trigger.alarm_name} #{trigger.state}"
            difference = trigger.step
          end
        end

        if difference == 0 && desired_count > current_min_task_count
          downscale_triggers.each do |trigger|
            next unless trigger.match?

            @logger.info "Fire downscale trigger of #{name} by #{trigger.alarm_name} #{trigger.state}"
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
          update_service(difference)
        end
      end

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

      def update_service(difference)
        next_desired_count = desired_count + difference
        current_level = max_task_level(desired_count)
        next_level = max_task_level(next_desired_count)
        if current_level < next_level && overheat? # next max
          level = next_level
          @reach_max_at = nil
          @logger.info "Service \"#{name}\" is overheat, uses next max count"
        elsif current_level < next_level && !overheat? # wait cooldown
          level = current_level
          now = Process.clock_gettime(Process::CLOCK_MONOTONIC, :second)
          @reach_max_at ||= now
          @logger.info "Service \"#{name}\" waits cooldown elapsed #{(now - @reach_max_at).to_i}sec"
        elsif current_level == next_level && next_desired_count >= max_task_count[current_level] # reach current max
          level = current_level
          now = Process.clock_gettime(Process::CLOCK_MONOTONIC, :second)
          @reach_max_at ||= now
          @logger.info "Service \"#{name}\" waits cooldown elapsed #{(now - @reach_max_at).to_i}sec"
        elsif current_level == next_level && next_desired_count < max_task_count[current_level]
          level = current_level
          @reach_max_at = nil
          @logger.info "Service \"#{name}\" clears cooldown state"
        elsif current_level > next_level
          level = next_level
          @reach_max_at = nil
          @logger.info "Service \"#{name}\" clears cooldown state"
        end

        cl = client
        next_desired_count = [next_desired_count, max_task_count[level]].min
        cl.update_service(
          cluster: cluster,
          service: name,
          desired_count: next_desired_count,
        )
        cl.wait_until(:services_stable, cluster: cluster, services: [name]) do |w|
          w.before_wait do
            @logger.debug "wait service stable [#{name}]"
          end
        end if difference < 0
        @last_updated_at = Process.clock_gettime(Process::CLOCK_MONOTONIC, :second)
        self.desired_count = next_desired_count
        @logger.info "Update service \"#{name}\": desired_count -> #{next_desired_count}"
      rescue => e
        AutoScaler.error_logger.error(e)
      end

      def fetch_container_instances_in_cluster
        arns = []
        cl = client
        resp = cl.list_container_instances(cluster: cluster)
        resp.each do |r|
          arns.concat(r.container_instance_arns)
        end

        chunk_size = 50
        container_instances = []
        arns.each_slice(chunk_size) do |arn_chunk|
          is = cl.describe_container_instances(cluster: cluster, container_instances: arn_chunk).container_instances
          container_instances.concat(is)
        end

        container_instances
      end

      def fetch_container_instance_arns_in_service
        arns = []
        resp = client.list_container_instances(cluster: cluster, filter: "task:group == service:#{name}")
        resp.each do |r|
          arns.concat(r.container_instance_arns)
        end

        arns
      end

      private

      def max_task_level(count)
        max_task_count.index { |i| count <= i } || max_task_count.size - 1
      end
    end
  end
end
