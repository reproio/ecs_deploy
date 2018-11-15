require "logger"
require "time"
require "yaml"

require "ecs_deploy/auto_scaler/auto_scaling_config"
require "ecs_deploy/auto_scaler/service_config"

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
          Thread.new(asg_config, configs, &method(:main_loop)).tap { |th| th.abort_on_exception = true }
        end

        ths.each(&:join)
      end

      def main_loop(asg_config, configs)
        loop_with_polling_interval("loop of #{asg_config.name}") do
          ths = configs.map do |service_config|
            Thread.new(service_config) do |s|
              @logger.debug "Start service scaling of #{s.name}"

              if s.idle?
                @logger.debug "#{s.name} is idling"
                next
              end

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
                s.update_service(difference)
              end
            end
          end
          ths.each { |th| th.abort_on_exception = true }

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
        @service_configs ||= @config["services"].map { |c| ServiceConfig.new(c, @logger) }
      end

      def auto_scaling_group_configs
        @auto_scaling_group_configs ||= @config["auto_scaling_groups"].map do |c|
          AutoScalingConfig.new(c, @logger)
        end
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
          @logger.debug "#{name} is last executed at #{last_executed_at}"
        end

        @logger.debug "Stop #{name}"
      end
    end
  end
end
