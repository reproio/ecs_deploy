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

    class << self
    end

    def method_missing(name, *args, &block)
      set(name, *args, &block)
    end

    def set(name, *args, &block)
      if block
        b = Builder.new 
        b.instance_eval(&block)
        @building_parts[name] = b
      else
        @building_parts[name] = OverridableValue.new(args.first)
      end
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

    def override(value = nil, &block)
      raise "Set either override value or block" if value && block

      Overrider.new(@building_parts).instance_eval(&block)
    end
  end

  class TaskDefinitionBuilder < Builder
    attr_reader :name

    def initialize(name)
      super()
      @name = name
      @building_parts[:task_definition_name] = OverridableValue.new(name)
    end

    def container_definition(name, &block)
      b = ContainerDefinitionBuilder.new(name)
      b.instance_eval(&block)
      @building_parts[:container_definitions] ||= []
      @building_parts[:container_definitions] << b
    end
  end

  class ContainerDefinitionBuilder < Builder
    attr_reader :name

    def initialize(name)
      super()
      @name = name
      @building_parts[:name] = OverridableValue.new(name)
    end
  end

  class Overrider
    def initialize(building_parts)
      @building_parts = building_parts
    end

    def method_missing(name, *args, &block)
      override(name, *args, &block)
    end

    def override(name, *args, &block)
      raise "Set either override value or block" if !args.empty? && block

      unless @building_parts[name]
        return @building_parts[name] = OverridableValue.new(args.first, &block)
      end

      @building_parts[name].override(args.first, &block)
    end

    def container_definition(name, &block)
      pp @building_parts
      container = @building_parts[:container_definitions].find { |c| c.name == name }
      raise "No such container definition: #{name}" unless container

      container.override(&block)
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
