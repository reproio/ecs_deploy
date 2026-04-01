module EcsDeploy
  module AutoScaler
    class NullClusterResourceManager
      def acquire(capacity, timeout: nil)
        true
      end

      def release(capacity)
        true
      end
    end
  end
end
