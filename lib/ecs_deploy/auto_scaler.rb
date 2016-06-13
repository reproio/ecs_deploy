require 'yaml'
require 'logger'

module EcsDeploy
  module AutoScaler
    class << self
      attr_reader :logger, :error_logger

      def run(yaml_path, log_file = nil, error_log_file = nil)
        trap(:TERM) { @stop = true }
        @logger = Logger.new(log_file || STDOUT)
        STDOUT.sync = true unless log_file
        @error_logger = Logger.new(error_log_file || STDERR)
        STDERR.sync = true unless error_log_file
        load_config(yaml_path)

        until @stop
          run_loop
        end
      end

      def stop
        @stop = true
      end

      def run_loop
        service_configs.each do |s|
          difference = 0
          s.upscale_triggers.each do |trigger|
            step = trigger.step || s.step
            next if difference >= step

            if trigger.match?
              logger.info "Fire upscale trigger of #{s.name} by #{trigger.alarm_name} #{trigger.state}"
              difference = step
            end
          end

          if difference == 0 && s.desired_count > s.min_task_count
            s.downscale_triggers.each do |trigger|
              if trigger.match?
                logger.info "Fire downscale trigger of #{s.name} by #{trigger.alarm_name} #{trigger.state}"
                step = trigger.step || s.step
                difference = [difference, -(step)].min
                if s.min_task_count > s.desired_count + difference
                  difference = s.min_task_count - s.desired_count
                end
              end
            end
          end

          if difference >= 0 && s.desired_count > s.max_task_count.max
            difference = s.max_task_count.max - s.desired_count
          end

          if difference != 0
            s.update_service(s.desired_count + difference)
          end
        end

        service_configs.group_by { |s| [s.region, s.auto_scaling_group_name] }.each do |(region, auto_scaling_group_name), configs|
          total_service_count = configs.inject(0) { |sum, s| sum + s.desired_count }
          asg_config = auto_scaling_group_configs.find { |c| c.name == auto_scaling_group_name && c.region == region }
          asg_config.update_auto_scaling_group(total_service_count)
        end

        TriggerConfig.clear_alarm_cache

        sleep @polling_interval
      end

      def load_config(yaml_path)
        @config = YAML.load_file(yaml_path)
        @polling_interval = @config["polling_interval"]
      end

      def service_configs
        @service_configs ||= @config["services"].map(&ServiceConfig.method(:new))
      end

      def auto_scaling_group_configs
        @auto_scaling_group_configs ||= @config["auto_scaling_groups"].map(&AutoScalingConfig.method(:new))
      end
    end

    module ConfigBase
      module ClassMethods
        def client_table
          @client_table ||= {}
        end
      end

      def initialize(attributes = {})
        attributes.each do |key, val|
          send("#{key}=", val)
        end
      end
    end

    SERVICE_CONFIG_ATTRIBUTES = %i(name cluster region auto_scaling_group_name step max_task_count min_task_count cooldown_time_for_reach_max upscale_triggers downscale_triggers desired_count)
    ServiceConfig = Struct.new(*SERVICE_CONFIG_ATTRIBUTES) do
      include ConfigBase
      extend ConfigBase::ClassMethods

      def initialize(attributes = {})
        super(attributes)
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
      end

      def client
        self.class.client_table[region] ||= Aws::ECS::Client.new(
          access_key_id: EcsDeploy.config.access_key_id,
          secret_access_key: EcsDeploy.config.secret_access_key,
          region: region
        )
      end

      def overheat?
        return false unless @reach_max_at
        (Time.now - @reach_max_at) > cooldown_time_for_reach_max
      end

      def fetch_service
        res = client.describe_services(cluster: cluster, services: [name])
        raise "Service \"#{name}\" is not found" if res.services.empty?
        res.services[0]
      rescue => e
        AutoScaler.error_logger.error(e)
        self.class.client_table[region] = nil
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
          @reach_max_at ||= Time.now
          AutoScaler.logger.info "Service \"#{name}\" waits cooldown in #{(Time.now - @reach_max_at).to_i}sec"
        elsif current_level == next_level && next_desired_count >= max_task_count[current_level] # reach current max
          level = current_level
          @reach_max_at ||= Time.now
          AutoScaler.logger.info "Service \"#{name}\" waits cooldown in #{(Time.now - @reach_max_at).to_i}sec"
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
        self.desired_count = next_desired_count
        AutoScaler.logger.info "Update service \"#{name}\": desired_count -> #{next_desired_count}"
      rescue => e
        AutoScaler.error_logger.error(e)
        self.class.client_table[region] = nil
      end

      private

      def max_task_level(count)
        max_task_count.index { |i| count <= i } || max_task_count.size - 1
      end
    end

    TriggerConfig = Struct.new(:alarm_name, :region, :state, :step) do
      include ConfigBase
      extend ConfigBase::ClassMethods

      def self.alarm_cache
        @alarm_cache ||= {}
      end

      def self.clear_alarm_cache
        @alarm_cache.clear if @alarm_cache
      end

      def client
        self.class.client_table[region] ||= Aws::CloudWatch::Client.new(
          access_key_id: EcsDeploy.config.access_key_id,
          secret_access_key: EcsDeploy.config.secret_access_key,
          region: region
        )
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
        self.class.client_table[region] = nil
      end
    end

    AutoScalingConfig = Struct.new(:name, :region, :buffer) do
      include ConfigBase
      extend ConfigBase::ClassMethods

      def client
        self.class.client_table[region] ||= Aws::AutoScaling::Client.new(
          access_key_id: EcsDeploy.config.access_key_id,
          secret_access_key: EcsDeploy.config.secret_access_key,
          region: region
        )
      end

      def update_auto_scaling_group(total_service_count)
        desired_capacity = total_service_count + buffer.to_i
        client.update_auto_scaling_group(
          auto_scaling_group_name: name,
          min_size: desired_capacity,
          max_size: desired_capacity,
          desired_capacity: desired_capacity,
        )
        AutoScaler.logger.info "Update auto scaling group \"#{name}\": desired_capacity -> #{desired_capacity}"
      rescue => e
        AutoScaler.error_logger.error(e)
        self.class.client_table[region] = nil
      end
    end
  end
end
