require "spec_helper"

require "ecs_deploy/auto_scaler"

RSpec.describe EcsDeploy::AutoScaler do
  describe "#load_config" do
    it do
      described_class.load_config(File.join(__dir__, "..", "fixtures", "files", "ecs_auto_scaler_config_in_old_format.yaml"))
      old_config = described_class.instance_variable_get(:@config)
      described_class.load_config(File.join(__dir__, "..", "fixtures", "files", "ecs_auto_scaler_config_in_new_format.yaml"))
      new_config = described_class.instance_variable_get(:@config)
      expect(old_config).to eq new_config
    end
  end
end
