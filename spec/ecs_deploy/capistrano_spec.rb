require "spec_helper"
require "rake"

module CapistranoStub
  def fetch(key, default = nil)
    settings = Thread.current[:capistrano_settings] || {}
    settings.fetch(key, default)
  end

  def set(key, value)
    Thread.current[:capistrano_settings] ||= {}
    Thread.current[:capistrano_settings][key] = value
  end
end

Object.include(CapistranoStub)

RSpec.describe "ecs:deploy capistrano task" do
  before(:all) do
    Rake.application = Rake::Application.new
    load File.expand_path("../../lib/ecs_deploy/capistrano.rb", __dir__)
  end

  before do
    Thread.current[:capistrano_settings] = {
      ecs_default_cluster: "default-cluster",
      ecs_region: "us-east-1",
    }
    Rake::Task["ecs:configure"].clear_actions
    Rake::Task["ecs:register_task_definition"].clear_actions
    Rake::Task["ecs:configure"].reenable
    Rake::Task["ecs:register_task_definition"].reenable
    Rake::Task["ecs:deploy"].reenable
    allow(EcsDeploy::Service).to receive(:wait_all_running)
  end

  after do
    Thread.current[:capistrano_settings] = nil
  end

  it "passes the whole service hash through to EcsDeploy::Service.new" do
    Thread.current[:capistrano_settings][:ecs_services] = [
      {
        name: "svc1",
        task_definition_name: "td1",
        deployment_controller: { type: "ECS" },
        deployment_configuration: { strategy: "LINEAR" },
        load_balancers: [{ advanced_configuration: { production_listener_rule: "rule-prod" } }],
        wait_strategy: :none,
        foo_bar_baz: "future-sdk-field",
      },
    ]

    received_kwargs = nil
    fake_service = instance_double(EcsDeploy::Service, deploy: nil)
    allow(EcsDeploy::Service).to receive(:new) do |**kwargs|
      received_kwargs = kwargs
      fake_service
    end

    Rake::Task["ecs:deploy"].invoke

    expect(received_kwargs).to include(
      service_name: "svc1",
      task_definition_name: "td1",
      deployment_controller: { type: "ECS" },
      deployment_configuration: { strategy: "LINEAR" },
      load_balancers: [{ advanced_configuration: { production_listener_rule: "rule-prod" } }],
      wait_strategy: :none,
      foo_bar_baz: "future-sdk-field",
      cluster: "default-cluster",
      region: "us-east-1",
    )
    expect(received_kwargs).not_to have_key(:name)
  end

  it "preserves explicit :cluster instead of overriding with default" do
    Thread.current[:capistrano_settings][:ecs_services] = [
      { name: "svc1", task_definition_name: "td1", cluster: "explicit-cluster" },
    ]

    received_kwargs = nil
    allow(EcsDeploy::Service).to receive(:new) { |**kwargs|
      received_kwargs = kwargs
      instance_double(EcsDeploy::Service, deploy: nil)
    }

    Rake::Task["ecs:deploy"].invoke

    expect(received_kwargs[:cluster]).to eq("explicit-cluster")
  end

  it "filters services by TARGET_CLUSTER and compacts the result" do
    Thread.current[:capistrano_settings][:ecs_services] = [
      { name: "a", task_definition_name: "td", cluster: "keep" },
      { name: "b", task_definition_name: "td", cluster: "drop" },
    ]
    Thread.current[:capistrano_settings][:target_cluster] = ["keep"]

    invoked = []
    allow(EcsDeploy::Service).to receive(:new) { |**kwargs|
      invoked << kwargs[:service_name]
      instance_double(EcsDeploy::Service, deploy: nil)
    }
    allow(EcsDeploy::Service).to receive(:wait_all_running) do |services|
      expect(services).to all(be_a(RSpec::Mocks::InstanceVerifyingDouble))
    end

    Rake::Task["ecs:deploy"].invoke

    expect(invoked).to eq(["a"])
  end
end
