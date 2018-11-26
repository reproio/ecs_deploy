require "logger"
require "time"
require "yaml"

require "ecs_deploy/auto_scaler/auto_scaling_group_config"
require "ecs_deploy/auto_scaler/instance_drainer"
require "ecs_deploy/auto_scaler/service_config"
require "ecs_deploy/auto_scaler/spot_fleet_request_config"

module EcsDeploy
  module AutoScaler
    class << self
      attr_reader :logger, :error_logger

      def run(yaml_path, log_file = nil, error_log_file = nil)
        @enable_auto_scaling = true
        setup_signal_handlers
        @logger = Logger.new(log_file || STDOUT)
        @logger.level = Logger.const_get(ENV["ECS_AUTO_SCALER_LOG_LEVEL"].upcase) if ENV["ECS_AUTO_SCALER_LOG_LEVEL"]
        STDOUT.sync = true unless log_file
        @error_logger = Logger.new(error_log_file || STDERR)
        @error_logger.level = Logger.const_get(ENV["ECS_AUTO_SCALER_LOG_LEVEL"].upcase) if ENV["ECS_AUTO_SCALER_LOG_LEVEL"]
        STDERR.sync = true unless error_log_file
        load_config(yaml_path)
        service_configs
        auto_scaling_group_configs
        spot_fleet_request_configs

        config_groups = service_configs.group_by { |s| [s.region, s.auto_scaling_group_name, s.spot_fleet_request_id] }
        ths = config_groups.map do |(region, auto_scaling_group_name, spot_fleet_request_id), configs|
          if auto_scaling_group_name
            cluster_scaling_config = auto_scaling_group_configs[auto_scaling_group_name][region]
          else
            cluster_scaling_config = spot_fleet_request_configs[spot_fleet_request_id][region]
          end
          Thread.new(cluster_scaling_config, configs, &method(:main_loop)).tap { |th| th.abort_on_exception = true }
        end

        if @config["spot_instance_intrp_warns_queue_urls"]
          drainer = EcsDeploy::AutoScaler::InstanceDrainer.new(service_configs, logger)
          polling_ths = @config["spot_instance_intrp_warns_queue_urls"].map do |queue_url|
            Thread.new(queue_url) do |url|
              drainer.poll_spot_instance_interruption_warnings(url)
            end.tap { |th| th.abort_on_exception = true }
          end
        end

        ths.each(&:join)

        drainer&.stop
        polling_ths&.each(&:join)
      end

      def main_loop(cluster_scaling_config, configs)
        loop_with_polling_interval("loop of #{cluster_scaling_config.name}") do
          ths = configs.map do |service_config|
            Thread.new(service_config) do |s|
              @logger.debug "Start service scaling of #{s.name}"
              s.adjust_desired_count
            end
          end
          ths.each { |th| th.abort_on_exception = true }

          ths.each(&:join)

          @logger.debug "Start cluster scaling of #{cluster_scaling_config.name}"

          required_capacity = configs.inject(0) { |sum, s| sum + s.desired_count * s.required_capacity }
          cluster_scaling_config.update_desired_capacity(required_capacity, configs[0])
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
        @auto_scaling_group_configs ||= (@config["auto_scaling_groups"] || []).each.with_object({}) do |c, configs|
          configs[c["name"]] ||= {}
          if configs[c["name"]][c["region"]]
            raise "Duplicate entry in auto_scaling_groups (name: #{c["name"]}, region: #{c["region"]})"
          end
          configs[c["name"]][c["region"]] = AutoScalingGroupConfig.new(c, @logger)
        end
      end

      def spot_fleet_request_configs
        @spot_fleet_request_configs ||= (@config["spot_fleet_requests"] || []).each.with_object({}) do |c, configs|
          configs[c["id"]] ||= {}
          if configs[c["id"]][c["region"]]
            raise "Duplicate entry in spot_fleet_requests (id: #{c["id"]}, region: #{c["region"]})"
          end
          configs[c["id"]][c["region"]] = SpotFleetRequestConfig.new(c, @logger)
        end
      end

      private

      def setup_signal_handlers
        # Use a thread and a queue to avoid "log writing failed. can't be called from trap context"
        # cf. https://bugs.ruby-lang.org/issues/14222#note-3
        signals = Queue.new
        %i(TERM INT CONT TSTP).each do |sig|
          trap(sig) { signals << sig }
        end

        Thread.new do
          loop do
            sig = signals.pop
            case sig
            when :INT, :TERM
              @logger.info "Received SIG#{sig}, shutting down gracefully"
              @stop = true
            when :CONT
              @logger.info "Received SIGCONT, resume auto scaling"
              @enable_auto_scaling = true
            when :TSTP
              @logger.info "Received SIGTSTP, pause auto scaling. Send SIGCONT to resume it."
              @enable_auto_scaling = false
            end
          end
        end
      end

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
          next unless @enable_auto_scaling
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
