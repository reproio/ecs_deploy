require "spec_helper"

RSpec.describe EcsDeploy::Service do
  let(:ecs_client) { Aws::ECS::Client.new(stub_responses: true, region: "us-east-1") }

  before do
    allow(Aws::ECS::Client).to receive(:new).and_return(ecs_client)
  end

  describe "#initialize" do
    it "raises ArgumentError on invalid update_strategy" do
      expect {
        described_class.new(cluster: "c", service_name: "s", update_strategy: :nope)
      }.to raise_error(ArgumentError, /update_strategy/)
    end

    it "raises ArgumentError on invalid wait_strategy" do
      expect {
        described_class.new(cluster: "c", service_name: "s", wait_strategy: :nope)
      }.to raise_error(ArgumentError, /wait_strategy/)
    end

    it "accepts known update_strategy and wait_strategy" do
      expect {
        described_class.new(
          cluster: "c",
          service_name: "s",
          update_strategy: :task_definition_only,
          wait_strategy: :none,
        )
      }.not_to raise_error
    end

    it "defaults update_strategy and wait_strategy to nil" do
      svc = described_class.new(cluster: "c", service_name: "s")
      expect(svc.update_strategy).to be_nil
      expect(svc.wait_strategy).to be_nil
    end
  end

  describe "#deploy on a non-existent service" do
    before do
      ecs_client.stub_responses(:describe_services, services: [])
    end

    it "passes ECS-native blue/green options through to create_service" do
      service = described_class.new(
        cluster: "cluster1",
        service_name: "svc1",
        task_definition_name: "td1",
        launch_type: "FARGATE",
        platform_version: "LATEST",
        desired_count: 1,
        deployment_controller: { type: "ECS" },
        deployment_configuration: {
          strategy: "LINEAR",
          linear_configuration: { step_percent: 50.0, step_bake_time_in_minutes: 60 },
          bake_time_in_minutes: 5,
          deployment_circuit_breaker: { enable: true, rollback: true },
          lifecycle_hooks: [
            {
              hook_target_arn: "arn:aws:lambda:us-east-1:0:function:pause",
              role_arn: "arn:aws:iam::0:role/role-x",
              lifecycle_stages: ["POST_TEST_TRAFFIC_SHIFT"],
            },
          ],
        },
        load_balancers: [
          {
            target_group_arn: "arn:aws:elasticloadbalancing:::targetgroup/tg1",
            container_name: "app",
            container_port: 8080,
            advanced_configuration: {
              alternate_target_group_arn: "arn:aws:elasticloadbalancing:::targetgroup/tg2",
              production_listener_rule: "arn:aws:elasticloadbalancing:::listener-rule/prod",
              test_listener_rule: "arn:aws:elasticloadbalancing:::listener-rule/test",
              role_arn: "arn:aws:iam::0:role/role-y",
            },
          },
        ],
      )

      service.deploy

      create_call = ecs_client.api_requests.find { |r| r[:operation_name] == :create_service }
      expect(create_call).not_to be_nil
      params = create_call[:params]
      expect(params[:deployment_controller]).to eq(type: "ECS")
      expect(params[:deployment_configuration][:strategy]).to eq("LINEAR")
      expect(params[:deployment_configuration][:linear_configuration]).to eq(step_percent: 50.0, step_bake_time_in_minutes: 60)
      expect(params[:deployment_configuration][:lifecycle_hooks].first).to include(
        hook_target_arn: "arn:aws:lambda:us-east-1:0:function:pause",
        lifecycle_stages: ["POST_TEST_TRAFFIC_SHIFT"],
      )
      expect(params[:load_balancers].first[:advanced_configuration]).to include(
        alternate_target_group_arn: "arn:aws:elasticloadbalancing:::targetgroup/tg2",
        production_listener_rule: "arn:aws:elasticloadbalancing:::listener-rule/prod",
      )
      expect(params[:platform_version]).to eq("LATEST")
    end

    it "preserves the user-supplied deployment_configuration without overwriting it with defaults" do
      service = described_class.new(
        cluster: "cluster1",
        service_name: "svc1",
        task_definition_name: "td1",
        desired_count: 1,
        deployment_configuration: { strategy: "LINEAR" },
      )

      service.deploy

      create_call = ecs_client.api_requests.find { |r| r[:operation_name] == :create_service }
      expect(create_call[:params][:deployment_configuration]).to eq(strategy: "LINEAR")
    end
  end

  describe "#deploy on an existing service" do
    before do
      ecs_client.stub_responses(:describe_services, services: [
        {
          service_name: "svc1",
          status: "ACTIVE",
          service_arn: "arn:aws:ecs:us-east-1:000000000000:service/cluster1/svc1",
          capacity_provider_strategy: [],
        },
      ])
    end

    context "with update_strategy: :task_definition_only" do
      it "sends only cluster, service, task_definition to update_service" do
        service = described_class.new(
          cluster: "cluster1",
          service_name: "svc1",
          task_definition_name: "td1",
          revision: 7,
          desired_count: 3,
          launch_type: "FARGATE",
          deployment_controller: { type: "ECS" },
          deployment_configuration: { strategy: "LINEAR" },
          load_balancers: [{ target_group_arn: "tg", container_name: "c", container_port: 1 }],
          update_strategy: :task_definition_only,
        )

        service.deploy

        update_call = ecs_client.api_requests.find { |r| r[:operation_name] == :update_service }
        expect(update_call).not_to be_nil
        expect(update_call[:params].keys).to contain_exactly(:cluster, :service, :task_definition)
        expect(update_call[:params][:task_definition]).to eq("td1:7")
      end

      it "does not call update_tags when :tags is not provided" do
        service = described_class.new(
          cluster: "cluster1",
          service_name: "svc1",
          task_definition_name: "td1",
          update_strategy: :task_definition_only,
        )

        service.deploy

        called = ecs_client.api_requests.map { |r| r[:operation_name] }
        expect(called).not_to include(:list_tags_for_resource)
      end
    end

    context "with default update_strategy (nil)" do
      it "still excludes CREATE_ONLY_KEYS (including deployment_controller) from update_service" do
        ecs_client.stub_responses(:list_tags_for_resource, tags: [])

        service = described_class.new(
          cluster: "cluster1",
          service_name: "svc1",
          task_definition_name: "td1",
          launch_type: "FARGATE",
          deployment_controller: { type: "ECS" },
          network_configuration: { awsvpc_configuration: { subnets: ["s1"], security_groups: [], assign_public_ip: "DISABLED" } },
          desired_count: 2,
        )

        service.deploy

        update_call = ecs_client.api_requests.find { |r| r[:operation_name] == :update_service }
        expect(update_call).not_to be_nil
        params = update_call[:params]
        expect(params).not_to have_key(:launch_type)
        expect(params).not_to have_key(:deployment_controller)
        expect(params[:network_configuration]).to eq(awsvpc_configuration: { subnets: ["s1"], security_groups: [], assign_public_ip: "DISABLED" })
        expect(params[:desired_count]).to eq(2)
      end
    end
  end

  describe ".wait_all_running" do
    def build_service_after_deploy(stub_create_service:, **service_options)
      ecs_client.stub_responses(:describe_services, services: [])
      ecs_client.stub_responses(:create_service, service: stub_create_service)
      service = described_class.new(
        cluster: "cluster1",
        service_name: "svc1",
        task_definition_name: "td1",
        desired_count: 1,
        **service_options,
      )
      service.deploy
      ecs_client.api_requests.clear
      service
    end

    it "auto-detects ECS-managed blue/green and skips polling" do
      service = build_service_after_deploy(
        stub_create_service: {
          deployment_controller: { type: "ECS" },
          deployment_configuration: { strategy: "LINEAR" },
        },
        deployment_controller: { type: "ECS" },
        deployment_configuration: { strategy: "LINEAR" },
      )

      described_class.wait_all_running([service])

      wait_calls = ecs_client.api_requests.map { |r| r[:operation_name] }
      expect(wait_calls).not_to include(:describe_services)
      expect(wait_calls).not_to include(:list_service_deployments)
    end

    it "skips polling for an explicit wait_strategy: :none" do
      service = build_service_after_deploy(
        stub_create_service: {},
        wait_strategy: :none,
      )

      described_class.wait_all_running([service])

      wait_calls = ecs_client.api_requests.map { |r| r[:operation_name] }
      expect(wait_calls).not_to include(:describe_services)
      expect(wait_calls).not_to include(:list_service_deployments)
    end

    it "uses list_service_deployments for wait_strategy: :service_deployment" do
      service = build_service_after_deploy(
        stub_create_service: {},
        wait_strategy: :service_deployment,
      )
      ecs_client.stub_responses(:list_service_deployments, service_deployments: [])

      described_class.wait_all_running([service])

      ops = ecs_client.api_requests.map { |r| r[:operation_name] }
      expect(ops).to include(:list_service_deployments)
      expect(ops).not_to include(:describe_services)
    end

    it "falls back to legacy polling for non-ECS-managed services" do
      service = build_service_after_deploy(
        stub_create_service: {
          deployment_controller: { type: "CODE_DEPLOY" },
        },
        deployment_controller: { type: "CODE_DEPLOY" },
      )
      ecs_client.stub_responses(:describe_services, services: [
        {
          service_name: "svc1",
          status: "ACTIVE",
          desired_count: 1,
          running_count: 1,
          deployments: [{ id: "d1" }],
          events: [],
        },
      ])

      described_class.wait_all_running([service])

      ops = ecs_client.api_requests.map { |r| r[:operation_name] }
      expect(ops).to include(:describe_services)
      expect(ops).not_to include(:list_service_deployments)
    end
  end
end
