module EcsDeploy
  module DSL
    refine Object do
      def task_definition(name, &block)
        b = TaskDefinitionBuilder.new(name)
        b.instance_eval(&block)
        b
      end
    end
  end

  class Builder
    def initialize
      @building_parts = {}
    end

    def method_missing(name, *args)
      @building_parts[name] = OverridableValue.new(args.first)
    end

    def build
      @building_parts.transform_values do |v|
        if v.is_a?(Array)
          v.map(&:build)
        else
          v.build
        end
      end
    end

    def override(&block)
      Overrider.new(@building_parts).instance_eval(&block)
    end
  end

  class TaskDefinitionBuilder < Builder
    def initialize(name)
      super()
      @building_parts[:task_definition_name] = OverridableValue.new(name)
    end

    def container_definition(name, &block)
      b = ContainerDefinitionBuilder.new(name)
      b.instance_eval(&block)
      b
      @building_parts[:container_definitions] ||= []
      @building_parts[:container_definitions] << b
    end
  end

  class ContainerDefinitionBuilder < Builder
    def initialize(name)
      super()
      @building_parts[:name] = OverridableValue.new(name)
    end
  end

  class Overrider
    def initialize(building_parts)
      @building_parts = building_parts
    end

    def method_missing(name, *args, &block)
      raise "Set either override value or block" if !args.empty? && block

      unless @building_parts[name]
        return @building_parts[name] = OverridableValue.new(args.first, &block)
      end

      @building_parts[name].override(args.first, &block)
    end
  end

  class OverridableValue
    def initialize(default)
      @part = proc { default }
    end

    def build
      @part.call
    end

    def override(value = nil, &block)
      raise "Set either override value or block" if value && block

      if value
        @part = proc { value }
      else
        old_part = @part
        @part = proc { block.call(old_part.call) }
      end
    end
  end
end
