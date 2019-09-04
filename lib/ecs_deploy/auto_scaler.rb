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

        ths = (auto_scaling_group_configs + spot_fleet_request_configs).map do |cluster_scaling_config|
          Thread.new(cluster_scaling_config, &method(:main_loop)).tap { |th| th.abort_on_exception = true }
        end

        if @config["spot_instance_intrp_warns_queue_urls"]
          drainer = EcsDeploy::AutoScaler::InstanceDrainer.new(
            auto_scaling_group_configs: auto_scaling_group_configs,
            spot_fleet_request_configs: spot_fleet_request_configs,
            logger: logger,
          )
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

      def main_loop(cluster_scaling_config)
        loop_with_polling_interval("loop of #{cluster_scaling_config.name}") do
          ths = cluster_scaling_config.service_configs.map do |service_config|
            Thread.new(service_config) do |s|
              @logger.debug "Start service scaling of #{s.name}"
              s.adjust_desired_count(cluster_scaling_config.cluster_resource_manager)
            end
          end
          ths.each { |th| th.abort_on_exception = true }

          ths.each(&:join)

          @logger.debug "Start cluster scaling of #{cluster_scaling_config.name}"

          required_capacity = cluster_scaling_config.service_configs.sum { |s| s.desired_count * s.required_capacity }
          cluster_scaling_config.update_desired_capacity(required_capacity)

          cluster_scaling_config.service_configs.each(&:wait_until_desired_count_updated)
        end
      end

      def load_config(yaml_path)
        @config = YAML.load_file(yaml_path)
        @polling_interval = @config["polling_interval"] || 30
        if @config["services"]
          @error_logger&.warn('"services" property in root-level is deprecated. Please define it in "auto_scaling_groups" property or "spot_fleet_requests" property.')
          @config.delete("services").each do |svc|
            if svc["auto_scaling_group_name"] && svc["spot_fleet_request_id"]
              raise "You can specify only one of 'auto_scaling_group_name' or 'spot_fleet_request_name'"
            end

            svc_region = svc.delete("region")
            if svc["auto_scaling_group_name"]
              asg_name = svc.delete("auto_scaling_group_name")
              asg = @config["auto_scaling_groups"].find { |g| g["region"] == svc_region && g["name"] == asg_name }
              asg["services"] ||= []
              asg["services"] << svc
              asg["cluster"] = svc.delete("cluster")
            end

            if svc["spot_fleet_request_id"]
              sfr_id = svc.delete("spot_fleet_request_id")
              sfr = @config["spot_fleet_requests"].find { |r| r["region"] == svc_region && r["id"] == sfr_id }
              sfr["services"] ||= []
              sfr["services"] << svc
              sfr["cluster"] = svc.delete("cluster")
            end
          end
        end
      end

      def auto_scaling_group_configs
        @auto_scaling_group_configs ||= (@config["auto_scaling_groups"] || []).each.with_object({}) do |c, configs|
          configs[c["name"]] ||= {}
          if configs[c["name"]][c["region"]]
            raise "Duplicate entry in auto_scaling_groups (name: #{c["name"]}, region: #{c["region"]})"
          end
          configs[c["name"]][c["region"]] = AutoScalingGroupConfig.new(c, @logger)
        end.values.flat_map(&:values)
      end

      def spot_fleet_request_configs
        @spot_fleet_request_configs ||= (@config["spot_fleet_requests"] || []).each.with_object({}) do |c, configs|
          configs[c["id"]] ||= {}
          if configs[c["id"]][c["region"]]
            raise "Duplicate entry in spot_fleet_requests (id: #{c["id"]}, region: #{c["region"]})"
          end
          configs[c["id"]][c["region"]] = SpotFleetRequestConfig.new(c, @logger)
        end.values.flat_map(&:values)
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
