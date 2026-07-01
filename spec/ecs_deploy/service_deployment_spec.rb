require "spec_helper"

RSpec.describe EcsDeploy::ServiceDeployment do
  let(:ecs_client) { Aws::ECS::Client.new(stub_responses: true, region: "us-east-1") }

  before do
    allow(Aws::ECS::Client).to receive(:new).and_return(ecs_client)
  end

  describe ".describe" do
    it "lists and describes in-flight deployments and logs lifecycle hook details" do
      ecs_client.stub_responses(:list_service_deployments, service_deployments: [
        { service_deployment_arn: "arn:aws:ecs:::service-deployment/abc" },
      ])
      ecs_client.stub_responses(:describe_service_deployments, service_deployments: [
        {
          service_deployment_arn: "arn:aws:ecs:::service-deployment/abc",
          status: "IN_PROGRESS",
          lifecycle_stage: "POST_TEST_TRAFFIC_SHIFT",
          lifecycle_hook_details: [
            {
              hook_id: "hook-1",
              target_type: "PAUSE",
              status: "PAUSED",
              expires_at: Time.now + 3600,
              timeout_action: "CONTINUE",
            },
          ],
        },
      ])

      logdev = StringIO.new
      EcsDeploy.instance_variable_set(:@logger, Logger.new(logdev))

      described_class.describe(
        services: [{ name: "svc1", cluster: "cluster1" }],
        regions: ["us-east-1"],
        default_cluster: "default-cluster",
      )

      log = logdev.string
      expect(log).to include("service_deployment_arn=arn:aws:ecs:::service-deployment/abc")
      expect(log).to include("hook_id=hook-1")
      expect(log).to include("status=PAUSED")
    end

    it "is a no-op when there are no in-flight deployments" do
      ecs_client.stub_responses(:list_service_deployments, service_deployments: [])

      expect {
        described_class.describe(
          services: [{ name: "svc1", cluster: "cluster1" }],
          regions: ["us-east-1"],
          default_cluster: "default-cluster",
        )
      }.not_to raise_error

      ops = ecs_client.api_requests.map { |r| r[:operation_name] }
      expect(ops).to include(:list_service_deployments)
      expect(ops).not_to include(:describe_service_deployments)
    end
  end

  describe ".invoke_lifecycle_hook" do
    before do
      ecs_client.stub_responses(:list_service_deployments, service_deployments: [
        { service_deployment_arn: "arn:aws:ecs:::service-deployment/abc" },
      ])
      ecs_client.stub_responses(:describe_service_deployments, service_deployments: [
        {
          service_deployment_arn: "arn:aws:ecs:::service-deployment/abc",
          lifecycle_hook_details: [{ hook_id: "hook-1" }, { hook_id: "hook-2" }],
        },
      ])
    end

    it "calls continue_service_deployment with the matching deployment arn and action" do
      described_class.invoke_lifecycle_hook(
        hook_id: "hook-2",
        action: "CONTINUE",
        services: [{ name: "svc1" }],
        regions: ["us-east-1"],
        default_cluster: "c",
      )

      call = ecs_client.api_requests.find { |r| r[:operation_name] == :continue_service_deployment }
      expect(call).not_to be_nil
      expect(call[:params]).to eq(
        service_deployment_arn: "arn:aws:ecs:::service-deployment/abc",
        hook_id: "hook-2",
        action: "CONTINUE",
      )
    end

    it "raises when the hook is not found" do
      expect {
        described_class.invoke_lifecycle_hook(
          hook_id: "missing",
          action: "ROLLBACK",
          services: [{ name: "svc1" }],
          regions: ["us-east-1"],
          default_cluster: "c",
        )
      }.to raise_error(EcsDeploy::ServiceDeployment::HookNotFoundError, /missing/)
    end
  end

  describe ".stop" do
    it "calls stop_service_deployment with the arn and stop_type when provided" do
      described_class.stop(
        service_deployment_arn: "arn:aws:ecs:::service-deployment/abc",
        region: "us-east-1",
        stop_type: "ABORT",
      )

      call = ecs_client.api_requests.find { |r| r[:operation_name] == :stop_service_deployment }
      expect(call[:params]).to eq(
        service_deployment_arn: "arn:aws:ecs:::service-deployment/abc",
        stop_type: "ABORT",
      )
    end

    it "omits stop_type when nil" do
      described_class.stop(
        service_deployment_arn: "arn:aws:ecs:::service-deployment/abc",
        region: "us-east-1",
      )

      call = ecs_client.api_requests.find { |r| r[:operation_name] == :stop_service_deployment }
      expect(call[:params]).to eq(service_deployment_arn: "arn:aws:ecs:::service-deployment/abc")
    end
  end
end
