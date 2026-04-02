require "ecs_deploy/auto_scaler/config_base"
require "ecs_deploy/auto_scaler/null_cluster_resource_manager"

module EcsDeploy
  module AutoScaler
    SimpleScalingConfig = Struct.new(:name, :region, :cluster, :service_configs) do
      include ConfigBase

      def initialize(attributes = {}, logger)
        attributes = attributes.dup
        services = attributes.delete("services")
        super(attributes, logger)
        self.service_configs = services.map do |s|
          ServiceConfig.new(s.merge("cluster" => cluster, "region" => region), logger)
        end
      end

      def update_desired_capacity(required_capacity)
        @logger.debug "#{log_prefix} Skipping infrastructure scaling (managed by capacity provider)"
      end

      def cluster_resource_manager
        @cluster_resource_manager ||= NullClusterResourceManager.new
      end

      private

      def log_prefix
        "[#{self.class.to_s.sub(/\AEcsDeploy::AutoScaler::/, "")} #{name} #{region}]"
      end
    end
  end
end
