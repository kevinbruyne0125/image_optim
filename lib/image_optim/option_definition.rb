class OptionDefinition

  attr_reader :name, :default, :type, :description, :proc

  def initialize(name, default, type, description, &proc)
    if type.is_a?(String)
      type, description = default.class, type
    end

    @name, @description = name.to_s, description.to_s
    @default, @type, @proc = default, type, proc
  end
end
