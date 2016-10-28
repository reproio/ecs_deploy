require 'yaml'
require 'logger'
require 'time'

module EcsDeploy
  module AutoScaler
    class << self
      attr_reader :logger, :error_logger

      def run(yaml_path, log_file = nil, error_log_file = nil)
        trap(:TERM) { @stop = true }
        trap(:INT) { @stop = true }
        @logger = Logger.new(log_file || STDOUT)
        @logger.level = Logger.const_get(ENV["ECS_AUTO_SCALER_LOG_LEVEL"].upcase) if ENV["ECS_AUTO_SCALER_LOG_LEVEL"]
        STDOUT.sync = true unless log_file
        @error_logger = Logger.new(error_log_file || STDERR)
        @error_logger.level = Logger.const_get(ENV["ECS_AUTO_SCALER_LOG_LEVEL"].upcase) if ENV["ECS_AUTO_SCALER_LOG_LEVEL"]
        STDERR.sync = true unless error_log_file
        load_config(yaml_path)
        service_configs
        auto_scaling_group_configs

        config_groups = service_configs.group_by { |s| [s.region, s.auto_scaling_group_name] }
        ths = config_groups.map do |(region, auto_scaling_group_name), configs|
          asg_config = auto_scaling_group_configs.find { |c| c.name == auto_scaling_group_name && c.region == region }
          Thread.new(asg_config, configs, &method(:main_loop))
        end

        ths.each(&:join)
      end

      def main_loop(asg_config, configs)
        loop_with_polling_interval("loop of #{asg_config.name}") do
          ths = configs.map do |service_config|
            Thread.new(service_config) do |s|
              next if s.idle?

              @logger.debug "Start service scaling of #{s.name}"

              difference = 0
              s.upscale_triggers.each do |trigger|
                step = trigger.step || s.step
                next if difference >= step

                if trigger.match?
                  logger.info "Fire upscale trigger of #{s.name} by #{trigger.alarm_name} #{trigger.state}"
                  difference = step
                end
              end

              if difference == 0 && s.desired_count > s.current_min_task_count
                s.downscale_triggers.each do |trigger|
                  next unless trigger.match?

                  logger.info "Fire downscale trigger of #{s.name} by #{trigger.alarm_name} #{trigger.state}"
                  step = trigger.step || s.step
                  difference = [difference, -step].min
                end
              end

              if s.current_min_task_count > s.desired_count + difference
                difference = s.current_min_task_count - s.desired_count
              end

              if difference >= 0 && s.desired_count > s.max_task_count.max
                difference = s.max_task_count.max - s.desired_count
              end

              if difference != 0
                s.update_service(s.desired_count + difference)
              end
            end
          end

          ths.each(&:join)

          @logger.debug "Start asg scaling of #{asg_config.name}"

          total_service_count = configs.inject(0) { |sum, s| sum + s.desired_count }
          asg_config.update_auto_scaling_group(total_service_count, configs[0])
          asg_config.detach_and_terminate_orphan_instances(configs[0])
        end
      end

      def load_config(yaml_path)
        @config = YAML.load_file(yaml_path)
        @polling_interval = @config["polling_interval"] || 30
      end

      def service_configs
        @service_configs ||= @config["services"].map(&ServiceConfig.method(:new))
      end

      def auto_scaling_group_configs
        @auto_scaling_group_configs ||= @config["auto_scaling_groups"].map(&AutoScalingConfig.method(:new))
      end

      private

      def wait_polling_interval?(last_executed_at)
        current = Process.clock_gettime(Process::CLOCK_MONOTONIC, :second)
        diff = current - last_executed_at
        diff <= @polling_interval
      end

      def loop_with_polling_interval(name)
        @logger.debug "Start #{name}"

        last_executed_at = 0
        loop do
          break if @stop
          sleep 1
          next if wait_polling_interval?(last_executed_at)
          yield
          last_executed_at = Process.clock_gettime(Process::CLOCK_MONOTONIC, :second)
        end

        @logger.debug "Stop #{name}"
      end
    end

    module ConfigBase
      def initialize(attributes = {})
        attributes.each do |key, val|
          send("#{key}=", val)
        end
      end
    end

    SERVICE_CONFIG_ATTRIBUTES = %i(name cluster region auto_scaling_group_name step max_task_count min_task_count idle_time scheduled_min_task_count cooldown_time_for_reach_max upscale_triggers downscale_triggers desired_count)
    ServiceConfig = Struct.new(*SERVICE_CONFIG_ATTRIBUTES) do
      include ConfigBase

      def initialize(attributes = {})
        super(attributes)
        self.idle_time ||= 60
        self.max_task_count = Array(max_task_count)
        self.upscale_triggers = upscale_triggers.to_a.map do |t|
          TriggerConfig.new(t.merge(region: region))
        end
        self.downscale_triggers = downscale_triggers.to_a.map do |t|
          TriggerConfig.new(t.merge(region: region))
        end
        self.max_task_count.sort!
        self.desired_count = fetch_service.desired_count
        @reach_max_at = nil
        @last_updated_at = nil
      end

      def client
        Thread.current["ecs_auto_scaler_ecs_#{region}"] ||= Aws::ECS::Client.new(
          access_key_id: EcsDeploy.config.access_key_id,
          secret_access_key: EcsDeploy.config.secret_access_key,
          region: region
        )
      end

      def clear_client
        Thread.current["ecs_auto_scaler_ecs_#{region}"] = nil
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
        clear_client
      end

      def update_service(next_desired_count)
        current_level = max_task_level(desired_count)
        next_level = max_task_level(next_desired_count)
        if current_level < next_level && overheat? # next max
          level = next_level
          @reach_max_at = nil
          AutoScaler.logger.info "Service \"#{name}\" is overheat, uses next max count"
        elsif current_level < next_level && !overheat? # wait cooldown
          level = current_level
          now = Process.clock_gettime(Process::CLOCK_MONOTONIC, :second)
          @reach_max_at ||= now
          AutoScaler.logger.info "Service \"#{name}\" waits cooldown elapsed #{(now - @reach_max_at).to_i}sec"
        elsif current_level == next_level && next_desired_count >= max_task_count[current_level] # reach current max
          level = current_level
          now = Process.clock_gettime(Process::CLOCK_MONOTONIC, :second)
          @reach_max_at ||= now
          AutoScaler.logger.info "Service \"#{name}\" waits cooldown elapsed #{(now - @reach_max_at).to_i}sec"
        elsif current_level == next_level && next_desired_count < max_task_count[current_level]
          level = current_level
          @reach_max_at = nil
          AutoScaler.logger.info "Service \"#{name}\" clears cooldown state"
        elsif current_level > next_level
          level = next_level
          @reach_max_at = nil
          AutoScaler.logger.info "Service \"#{name}\" clears cooldown state"
        end

        next_desired_count = [next_desired_count, max_task_count[level]].min
        client.update_service(
          cluster: cluster,
          service: name,
          desired_count: next_desired_count,
        )
        client.wait_until(:services_stable, cluster: cluster, services: [name]) do |w|
          w.before_wait do
            AutoScaler.logger.debug "wait service stable [#{name}]"
          end
        end
        @last_updated_at = Process.clock_gettime(Process::CLOCK_MONOTONIC, :second)
        self.desired_count = next_desired_count
        AutoScaler.logger.info "Update service \"#{name}\": desired_count -> #{next_desired_count}"
      rescue => e
        AutoScaler.error_logger.error(e)
        clear_client
      end

      def fetch_container_instances
        arns = []
        resp = nil
        loop do
          options = {cluster: cluster}
          options.merge(next_token: resp.next_token) if resp && resp.next_token
          resp = client.list_container_instances(options)
          arns.concat(resp.container_instance_arns)
          break unless resp.next_token
        end

        chunk_size = 50
        container_instances = []
        arns.each_slice(chunk_size) do |arn_chunk|
          is = client.describe_container_instances(cluster: cluster, container_instances: arn_chunk).container_instances
          container_instances.concat(is)
        end

        container_instances
      end

      private

      def max_task_level(count)
        max_task_count.index { |i| count <= i } || max_task_count.size - 1
      end
    end

    TriggerConfig = Struct.new(:alarm_name, :region, :state, :step) do
      include ConfigBase

      def self.alarm_cache
        @alarm_cache ||= {}
      end

      def self.clear_alarm_cache
        @alarm_cache.clear if @alarm_cache
      end

      def client
        Thread.current["ecs_auto_scaler_cloud_watch_#{region}"] ||= Aws::CloudWatch::Client.new(
          access_key_id: EcsDeploy.config.access_key_id,
          secret_access_key: EcsDeploy.config.secret_access_key,
          region: region
        )
      end

      def clear_client
        Thread.current["ecs_auto_scaler_cloud_watch_#{region}"] = nil
      end

      def match?
        fetch_alarm.state_value == state
      end

      def fetch_alarm
        alarm_cache = self.class.alarm_cache
        return alarm_cache[region][alarm_name] if alarm_cache[region] && alarm_cache[region][alarm_name]

        res = client.describe_alarms(alarm_names: [alarm_name])
        raise "Alarm \"#{alarm_name}\" is not found" if res.metric_alarms.empty?
        res.metric_alarms[0].tap do |alarm|
          AutoScaler.logger.debug(alarm.to_json)
          alarm_cache[region] ||= {}
          alarm_cache[region][alarm_name] = alarm
        end
      rescue => e
        AutoScaler.error_logger.error(e)
        clear_client
      end
    end

    AutoScalingConfig = Struct.new(:name, :region, :buffer) do
      include ConfigBase

      def client
        Thread.current["ecs_auto_scaler_auto_scaling_#{region}"] ||= Aws::AutoScaling::Client.new(
          access_key_id: EcsDeploy.config.access_key_id,
          secret_access_key: EcsDeploy.config.secret_access_key,
          region: region
        )
      end

      def clear_client
        Thread.current["ecs_auto_scaler_auto_scaling_#{region}"] = nil
      end

      def ec2_client
        Thread.current["ecs_auto_scaler_ec2_#{region}"] ||= Aws::EC2::Client.new(
          access_key_id: EcsDeploy.config.access_key_id,
          secret_access_key: EcsDeploy.config.secret_access_key,
          region: region
        )
      end

      def clear_ec2_client
        Thread.current["ecs_auto_scaler_ec2_#{region}"] = nil
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
          container_instances = service_config.fetch_container_instances
          deregisterable_instances = container_instances.select do |i|
            i.pending_tasks_count == 0 && i.running_tasks_count == 0
          end

          AutoScaler.logger.info "Fetch deregisterable instances: #{deregisterable_instances.map(&:ec2_instance_id).inspect}"

          deregistered_instance_ids = []
          deregisterable_instances.each do |i|
            break if deregistered_instance_ids.size >= diff

            begin
              service_config.client.deregister_container_instance(cluster: service_config.cluster, container_instance: i.container_instance_arn, force: false)
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
        clear_client
      end

      def detach_and_terminate_instances(instance_ids)
        return if instance_ids.empty?

        client.detach_instances(
          auto_scaling_group_name: name,
          instance_ids: instance_ids,
          should_decrement_desired_capacity: true
        )

        AutoScaler.logger.info "Detach instances from ASG #{name}: #{instance_ids.inspect}"
        sleep 3

        ec2_client.terminate_instances(instance_ids: instance_ids)

        AutoScaler.logger.info "Terminated instances: #{instance_ids.inspect}"
      rescue => e
        AutoScaler.error_logger.error(e)
        clear_client
        clear_ec2_client
      end

      def detach_and_terminate_orphan_instances(service_config)
        container_instance_ids = service_config.fetch_container_instances.map(&:ec2_instance_id)
        orphans = instances(reload: true).reject { |i| container_instance_ids.include?(i.instance_id) }.map(&:instance_id)

        return if orphans.empty?

        targets = ec2_client.describe_instances(instance_ids: orphans).reservations[0].instances.select do |i|
          (Time.now - i.launch_time) > 600
        end

        detach_and_terminate_instances(targets.map(&:instance_id))
      rescue => e
        AutoScaler.error_logger.error(e)
        clear_client
        clear_ec2_client
      end
    end
  end
end
