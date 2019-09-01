require "spec_helper"

require "ecs_deploy/auto_scaler/cluster_resource_manager"

RSpec.describe EcsDeploy::AutoScaler::ClusterResourceManager do
  let(:cluster_resource_manager) do
    described_class.new(
      region: "ap-northeast-1",
      cluster: "cluster",
      service_configs: service_configs,
      capacity_based_on: capacity_based_on,
      update_remaining_capacity_interval: 0.1,
    )
  end
  let(:service_configs) { [] }

  describe "#acquire" do
    let(:capacity_based_on) { "instances" }
    let(:service_configs) { [service_config] }
    let(:service_config) do
      double(name: "service_name", required_capacity: 0.5, desired_count: 6, updated_desired_count: 4)
    end

    before do
      ecs_client = Aws::ECS::Client.new(stub_responses: true)
      @container_instance_arns = ["arn", "arn"]
      ecs_client.stub_responses(:list_container_instances, ->(_) {
        { container_instance_arns: @container_instance_arns }
      })
      allow(cluster_resource_manager).to receive(:ecs_client) { ecs_client }
    end

    it do
      expect {
        Timeout::timeout(0.5) do
          cluster_resource_manager.acquire(1)
        end
      }.to raise_error { Timeout::Error }

      @container_instance_arns << "arn"
      expect {
        Timeout::timeout(0.5) do
          cluster_resource_manager.acquire(1)
        end
      }.to_not raise_error { Timeout::Error }
    end
  end

  describe "#calculate_active_instance_capacity" do
    context "when capacity_based_on is 'instances'" do
      let(:capacity_based_on) { "instances" }

      before do
        ecs_client = Aws::ECS::Client.new(stub_responses: true)
        ecs_client.stub_responses(:list_container_instances, {
          container_instance_arns: %w[arn1 arn2],
        })
        allow(cluster_resource_manager).to receive(:ecs_client) { ecs_client }
      end

      it do
        expect(cluster_resource_manager.calculate_active_instance_capacity).to eq 2
      end
    end

    context "when capacity_based_on is 'instances'" do
      let(:capacity_based_on) { "vCPUs" }

      let(:container_instances) do
        [
          Aws::ECS::Types::ContainerInstance.new(
            container_instance_arn: "2vCPUs_instance_arn",
            registered_resources: [
              {
                integer_value: 2048,
                name: "CPU",
              },
            ],
          ),
          Aws::ECS::Types::ContainerInstance.new(
            container_instance_arn: "4vCPUs_instance_arn",
            registered_resources: [
              {
                integer_value: 4096,
                name: "CPU",
              },
            ],
          ),
        ]
      end

      before do
        ecs_client = Aws::ECS::Client.new(stub_responses: true)
        ecs_client.stub_responses(:list_container_instances, {
          container_instance_arns: container_instances.map(&:container_instance_arn),
        })
        ecs_client.stub_responses(:describe_container_instances, {
          container_instances: container_instances,
        })
        allow(cluster_resource_manager).to receive(:ecs_client) { ecs_client }
      end

      it do
        expect(cluster_resource_manager.calculate_active_instance_capacity).to eq 6
      end
    end
  end
end
