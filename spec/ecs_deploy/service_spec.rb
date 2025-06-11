require 'spec_helper'

RSpec.describe EcsDeploy::Service do
  describe ".deployment_successful?" do
    let(:service_single_deployment_successful) do
      double('service', 
        deployments: [double('deployment', status: 'SUCCESSFUL')],
        running_count: 2,
        desired_count: 2
      )
    end

    let(:service_single_deployment_pending) do
      double('service',
        deployments: [double('deployment', status: 'PENDING')],
        running_count: 2,
        desired_count: 2
      )
    end

    let(:service_multiple_deployments) do
      double('service',
        deployments: [
          double('deployment', status: 'SUCCESSFUL'),
          double('deployment', status: 'PENDING')
        ],
        running_count: 2,
        desired_count: 2
      )
    end

    let(:service_count_mismatch) do
      double('service',
        deployments: [double('deployment', status: 'SUCCESSFUL')],
        running_count: 1,
        desired_count: 2
      )
    end

    it "returns true when single deployment is successful and counts match" do
      expect(described_class.send(:deployment_successful?, service_single_deployment_successful)).to be true
    end

    it "returns false when deployment is not successful" do
      expect(described_class.send(:deployment_successful?, service_single_deployment_pending)).to be false
    end

    it "returns false when there are multiple deployments" do
      expect(described_class.send(:deployment_successful?, service_multiple_deployments)).to be false
    end

    it "returns false when running count doesn't match desired count" do
      expect(described_class.send(:deployment_successful?, service_count_mismatch)).to be false
    end
  end
end