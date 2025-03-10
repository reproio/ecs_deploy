RSpec.describe "EcsDeploy::DSL" do
  using EcsDeploy::DSL

  it "defines task_definition" do
    builder = task_definition("task1") do
      cpu 256
      memory 512
    end

    expect(builder.build).to eq(task_definition_name: "task1", cpu: 256, memory: 512)
  end

  it "overrides task_definition" do
    builder = task_definition("task1") do
      cpu 256
      memory 512
    end

    builder.override do
      cpu 512
    end

    builder.override do
      memory { |v| v * 2 }
    end

    expect(builder.build).to eq(task_definition_name: "task1", cpu: 512, memory: 1024)
  end

  it "defines container_definition" do
    builder = task_definition("task1") do
      cpu 256
      memory 512
      container_definition("container1") do
      end
    end

    expect(builder.build).to eq(
      task_definition_name: "task1",
      cpu: 256,
      memory: 512,
      container_definitions: [
        {name: "container1"}
      ]
    )
  end
end
