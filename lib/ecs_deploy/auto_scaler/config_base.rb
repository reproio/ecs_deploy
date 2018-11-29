module EcsDeploy
  module AutoScaler
    module ConfigBase
      def initialize(attributes = {}, logger)
        attributes.each do |key, val|
          send("#{key}=", val)
        end
        @logger = logger
      end

      def logger
        @logger
      end
    end
  end
end
