require "spec_helper"

RSpec.describe EcsDeploy::Service do
  let(:ecs_client) { Aws::ECS::Client.new(stub_responses: true, region: "us-east-1") }

  before do
    allow(Aws::ECS::Client).to receive(:new).and_return(ecs_client)
  end

  describe "#initialize" do
    it "raises ArgumentError on invalid wait_strategy" do
      expect {
        described_class.new(cluster: "c", service_name: "s", wait_strategy: :nope)
      }.to raise_error(ArgumentError, /wait_strategy/)
    end

    it "accepts a known wait_strategy" do
      expect {
        described_class.new(cluster: "c", service_name: "s", wait_strategy: :none)
      }.not_to raise_error
    end

    it "defaults wait_strategy to nil" do
      svc = described_class.new(cluster: "c", service_name: "s")
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
    let(:existing_service) do
      {
        service_name: "svc1",
        status: "ACTIVE",
        service_arn: "arn:aws:ecs:us-east-1:000000000000:service/cluster1/svc1",
        capacity_provider_strategy: [],
        launch_type: "FARGATE",
        scheduling_strategy: "REPLICA",
        deployment_controller: { type: "ECS" },
      }
    end

    before do
      ecs_client.stub_responses(:describe_services, services: [existing_service])
      ecs_client.stub_responses(:list_tags_for_resource, tags: [])
    end

    def build(**opts)
      described_class.new(
        cluster: "cluster1",
        service_name: "svc1",
        task_definition_name: "td1",
        **opts,
      )
    end

    def update_call
      ecs_client.api_requests.find { |r| r[:operation_name] == :update_service }
    end

    it "forwards every user-supplied SDK-accepted field to update_service" do
      build(
        desired_count: 3,
        capacity_provider_strategy: [{ capacity_provider: "cp1", weight: 1 }],
        deployment_configuration: { strategy: "LINEAR" },
        availability_zone_rebalancing: "ENABLED",
        network_configuration: { awsvpc_configuration: { subnets: ["s1"], security_groups: [], assign_public_ip: "DISABLED" } },
        placement_constraints: [{ type: "distinctInstance" }],
        placement_strategy: [{ type: "spread", field: "attribute:ecs.availability-zone" }],
        platform_version: "LATEST",
        health_check_grace_period_seconds: 300,
        enable_execute_command: true,
        enable_ecs_managed_tags: true,
        load_balancers: [{ target_group_arn: "tg", container_name: "c", container_port: 1 }],
        propagate_tags: "SERVICE",
        service_registries: [{ registry_arn: "arn:reg" }],
        service_connect_configuration: { enabled: true },
        volume_configurations: [{ name: "v1" }],
      ).deploy

      params = update_call[:params]
      expect(params[:cluster]).to eq("cluster1")
      expect(params[:service]).to eq("svc1")
      expect(params[:task_definition]).to eq("td1")
      expect(params[:desired_count]).to eq(3)
      expect(params[:capacity_provider_strategy]).to eq([{ capacity_provider: "cp1", weight: 1 }])
      expect(params[:deployment_configuration]).to eq(strategy: "LINEAR")
      expect(params[:availability_zone_rebalancing]).to eq("ENABLED")
      expect(params[:network_configuration]).to eq(awsvpc_configuration: { subnets: ["s1"], security_groups: [], assign_public_ip: "DISABLED" })
      expect(params[:placement_constraints]).to eq([{ type: "distinctInstance" }])
      expect(params[:placement_strategy]).to eq([{ type: "spread", field: "attribute:ecs.availability-zone" }])
      expect(params[:platform_version]).to eq("LATEST")
      expect(params[:health_check_grace_period_seconds]).to eq(300)
      expect(params[:enable_execute_command]).to be(true)
      expect(params[:enable_ecs_managed_tags]).to be(true)
      expect(params[:load_balancers]).to eq([{ target_group_arn: "tg", container_name: "c", container_port: 1 }])
      expect(params[:propagate_tags]).to eq("SERVICE")
      expect(params[:service_registries]).to eq([{ registry_arn: "arn:reg" }])
      expect(params[:service_connect_configuration]).to eq(enabled: true)
      expect(params[:volume_configurations]).to eq([{ name: "v1" }])
    end

    it "forwards ECS-native blue/green fields on update including load_balancers.advanced_configuration" do
      build(
        deployment_controller: { type: "ECS" },
        deployment_configuration: {
          strategy: "LINEAR",
          lifecycle_hooks: [{ hook_target_arn: "arn:hook", role_arn: "arn:role", lifecycle_stages: ["POST_TEST_TRAFFIC_SHIFT"] }],
        },
        load_balancers: [{
          target_group_arn: "arn:tg1",
          container_name: "app",
          container_port: 8080,
          advanced_configuration: {
            alternate_target_group_arn: "arn:tg2",
            production_listener_rule: "arn:rule/prod",
            role_arn: "arn:role-y",
          },
        }],
      ).deploy

      params = update_call[:params]
      expect(params[:deployment_configuration][:strategy]).to eq("LINEAR")
      expect(params[:deployment_configuration][:lifecycle_hooks].first[:lifecycle_stages]).to eq(["POST_TEST_TRAFFIC_SHIFT"])
      expect(params[:load_balancers].first[:advanced_configuration]).to include(
        alternate_target_group_arn: "arn:tg2",
        production_listener_rule: "arn:rule/prod",
      )
      # deployment_controller matches current, silent drop
      expect(params).not_to have_key(:deployment_controller)
    end

    it "honors desired_count: 0 (not silently dropped)" do
      build(desired_count: 0).deploy
      expect(update_call[:params][:desired_count]).to eq(0)
    end

    it "honors propagate_tags: 'NONE' (falsy-guarded no longer applies)" do
      build(propagate_tags: "NONE").deploy
      expect(update_call[:params][:propagate_tags]).to eq("NONE")
    end

    it "omits desired_count when the user did not set it (preserves autoscaling)" do
      build.deploy
      expect(update_call[:params]).not_to have_key(:desired_count)
    end

    it "omits propagate_tags when the user did not set it" do
      build.deploy
      expect(update_call[:params]).not_to have_key(:propagate_tags)
    end

    it "warns and drops :role" do
      expect(EcsDeploy.logger).to receive(:warn).with(/\brole\b.*skipping/)
      build(role: "arn:aws:iam::0:role/svc-role").deploy
      expect(update_call[:params]).not_to have_key(:role)
    end

    it "warns and drops :client_token" do
      expect(EcsDeploy.logger).to receive(:warn).with(/client_token.*skipping/)
      build(client_token: "abc").deploy
      expect(update_call[:params]).not_to have_key(:client_token)
    end

    it "silently drops :launch_type when it matches the current service" do
      expect(EcsDeploy.logger).not_to receive(:warn)
      build(launch_type: "FARGATE").deploy
      expect(update_call[:params]).not_to have_key(:launch_type)
    end

    it "warns and drops :launch_type when it differs from the current service" do
      expect(EcsDeploy.logger).to receive(:warn).with(/launch_type.*skipping/)
      build(launch_type: "EC2").deploy
      expect(update_call[:params]).not_to have_key(:launch_type)
    end

    it "silently drops :deployment_controller when it matches the current type" do
      expect(EcsDeploy.logger).not_to receive(:warn)
      build(deployment_controller: { type: "ECS" }).deploy
      expect(update_call[:params]).not_to have_key(:deployment_controller)
    end

    it "warns and drops :deployment_controller when it differs from current" do
      expect(EcsDeploy.logger).to receive(:warn).with(/deployment_controller.*skipping/)
      build(deployment_controller: { type: "CODE_DEPLOY" }).deploy
      expect(update_call[:params]).not_to have_key(:deployment_controller)
    end

    it "forwards unknown keys verbatim to update_service (SDK is the source of truth)" do
      expect {
        build(foo_bar_baz: "future-sdk-field").deploy
      }.to raise_error(ArgumentError)
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
