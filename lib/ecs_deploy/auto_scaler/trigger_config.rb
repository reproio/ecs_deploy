require "aws-sdk-cloudwatch"
require "ecs_deploy"
require "ecs_deploy/auto_scaler"
require "ecs_deploy/auto_scaler/config_base"

module EcsDeploy
  module AutoScaler
    TriggerConfig = Struct.new(:alarm_name, :region, :state, :step, :prioritized_over_upscale_triggers) do
      include ConfigBase

      def match?
        fetch_alarm.state_value == state
      end

      def prioritized_over_upscale_triggers?
        !!prioritized_over_upscale_triggers
      end

      private

      def client
        Aws::CloudWatch::Client.new(
          access_key_id: EcsDeploy.config.access_key_id,
          secret_access_key: EcsDeploy.config.secret_access_key,
          region: region,
          logger: logger
        )
      end

      def fetch_alarm
        res = client.describe_alarms(alarm_names: [alarm_name])

        raise "Alarm \"#{alarm_name}\" is not found" if res.metric_alarms.empty?
        res.metric_alarms[0].tap do |alarm|
          AutoScaler.logger.debug("#{alarm.alarm_name} state is #{alarm.state_value}")
        end
      rescue => e
        AutoScaler.error_logger.error(e)
      end
    end
  end
end
