module GraphQL
  module Models
    module DefinitionHelpers
      def self.types
        GraphQL::DefinitionHelpers::TypeDefiner.instance
      end

      def self.type_to_graphql_type(type)
        case type
        when :boolean
          types.Boolean
        when :integer
          types.Int
        when :float
          types.Float
        when :daterange, :tsrange
          types[!types.String]
        else
          types.String
        end
      end

      def self.get_column(model_type, name)
        col = model_type.columns.detect { |c| c.name == name.to_s }
        raise ArgumentError.new("The attribute #{name} wasn't found on model #{model_type.name}.") unless col

        if model_type.respond_to?(:defined_enums) && model_type.defined_enums.include?(name.to_s)
          graphql_type = GraphQL::EnumType.define do
            name "#{model_type.name}#{name.to_s.classify}"
            description "#{name.to_s.titleize} field on #{model_type.name.titleize}"

            model_type.defined_enums[name.to_s].keys.each do |enum_val|
              value(enum_val, enum_val.titleize)
            end
          end
        else
          graphql_type = type_to_graphql_type(col.type)
        end

        if col.array
          graphql_type = types[graphql_type]
        end

        return OpenStruct.new({
          is_range: /range\z/ === col.type.to_s,
          camel_name: name.to_s.camelize(:lower).to_sym,
          graphql_type: graphql_type
        })
      end

      def self.range_to_graphql(value)
        return nil unless value

        begin
          [value.first, value.last_included]
        rescue TypeError
          [value.first, value.last]
        end
      end

      def self.traverse_path(base_model, path, context)
        model = base_model
        path.each do |segment|
          return nil unless model
          model = model.public_send(segment)
        end

        return model
      end

      # Detects the values that are valid for an attribute by looking at the inclusion validators
      def self.detect_inclusion_values(model_type, attribute)
        # Get all of the inclusion validators
        validators = model_type.validators_on(attribute).select { |v| v.is_a?(ActiveModel::Validations::InclusionValidator) }

        # Ignore any inclusion validators that are using the 'if' or 'unless' options
        validators = validators.reject { |v| v.options.include?(:if) || v.options.include?(:unless) || v.options[:in].blank? }
        return nil unless validators.any?
        return validators.map { |v| v.options[:in] }.reduce(:&)
      end

      def self.define_attribute(definer, model_type, path, attribute, options)
        column = get_column(model_type, attribute)

        field_name = options[:name] || column.camel_name

        definer.field field_name, column.graphql_type do
          description options[:description] if options.include?(:description)
          deprecation_reason options[:deprecation_reason] if options.include?(:deprecation_reason)

          resolve -> (base_model, args, context) do
            model = DefinitionHelpers.traverse_path(base_model, path, context)

            return nil unless model
            return nil unless context.can?(:read, model)

            if column.is_range
              DefinitionHelpers.range_to_graphql(model.public_send(attribute))
            else
              model.public_send(attribute)
            end
          end
        end
      end

      def self.define_attribute_type_field(definer, model_type, path, attr_type, field_name, options)
        camel_name = options[:name] || field_name.to_s.camelize(:lower).to_sym

        definer.field camel_name, attr_type.graph_type_proc do
          resolve -> (base_model, args, context) do
            model = DefinitionHelpers.traverse_path(base_model, path, context)
            return nil unless model
            return nil unless context.can?(:read, model)

            return attr_type.resolve(model, field_name)
          end
        end
      end

    end
  end
end
