require 'graphql_java_gen/version'
require 'graphql_java_gen/reformatter'
require 'graphql_java_gen/scalar'
require 'graphql_java_gen/annotation'

require 'erb'
require 'set'

class GraphQLJavaGen
  attr_reader :schema, :package_name, :scalars, :imports, :script_name, :schema_name

  def initialize(schema,
    package_name:, nest_under:, script_name: 'graphql_java_gen gem',
    custom_scalars: [], custom_annotations: []
  )
    @schema = schema
    @schema_name = nest_under
    @script_name = script_name
    @package_name = package_name
    @scalars = (BUILTIN_SCALARS + custom_scalars).reduce({}) { |hash, scalar| hash[scalar.type_name] = scalar; hash }
    @scalars.default_proc = ->(hash, key) { DEFAULT_SCALAR }
    @annotations = custom_annotations
    @imports = (@scalars.values.map(&:imports) + @annotations.map(&:imports)).flatten.sort.uniq
  end

  def save(path)
    File.write(path, generate)
  end

  def generate
    reformat(TEMPLATE_ERB.result(binding))
  end

  private

  class << self
    private

    def erb_for(template_filename)
      erb = ERB.new(File.read(template_filename))
      erb.filename = template_filename
      erb
    end
  end

  TEMPLATE_ERB = erb_for(File.expand_path("../graphql_java_gen/templates/APISchema.java.erb", __FILE__))
  private_constant :TEMPLATE_ERB

  DEFAULT_SCALAR = Scalar.new(
    type_name: nil,
    java_type: 'String',
    deserialize_expr: ->(expr) { "jsonAsString(#{expr}, key)" },
  )
  private_constant :DEFAULT_SCALAR

  BUILTIN_SCALARS = [
    Scalar.new(
      type_name: 'Int',
      java_type: 'int',
      deserialize_expr: ->(expr) { "jsonAsInteger(#{expr}, key)" },
    ),
    Scalar.new(
      type_name: 'Float',
      java_type: 'double',
      deserialize_expr: ->(expr) { "jsonAsDouble(#{expr}, key)" },
    ),
    Scalar.new(
      type_name: 'String',
      java_type: 'String',
      deserialize_expr: ->(expr) { "jsonAsString(#{expr}, key)" },
    ),
    Scalar.new(
      type_name: 'Boolean',
      java_type: 'boolean',
      deserialize_expr: ->(expr) { "jsonAsBoolean(#{expr}, key)" },
    ),
    Scalar.new(
      type_name: 'ID',
      java_type: 'ID',
      deserialize_expr: ->(expr) { "new ID(jsonAsString(#{expr}, key))" },
      imports: ['com.shopify.graphql.support.ID'],
    ),
  ]
  private_constant :BUILTIN_SCALARS

  # From: http://docs.oracle.com/javase/tutorial/java/nutsandbolts/_keywords.html
  RESERVED_WORDS = [
    "abstract", "assert", "boolean", "break", "byte", "case", "catch", "char", "class", "const", "continue", "default", "do", "double", "else", "enum", "extends", "final", "finally", "float",
    "for", "goto", "if", "implements", "import", "instanceof", "int", "interface", "long", "native", "new", "package", "private", "protected", "public", "return", "short", "static", "strictfp", "super",
    "switch", "synchronized", "this", "throw", "throws", "transient", "try", "void", "volatile", "while"
  ]
  private_constant :RESERVED_WORDS

  def escape_reserved_word(word)
    return word unless RESERVED_WORDS.include?(word)
    "#{word}Value"
  end

  def reformat(code)
    Reformatter.new(indent: " " * 4).reformat(code)
  end

  def java_input_type(type, non_null: false)
    case type.kind
    when "NON_NULL"
      java_input_type(type.of_type, non_null: true)
    when "SCALAR"
      non_null ? scalars[type.name].non_nullable_type : scalars[type.name].nullable_type
    when 'LIST'
      "List<#{java_input_type(type.of_type.unwrap_non_null)}>"
    when 'INPUT_OBJECT', 'ENUM'
      type.name
    else
      raise NotImplementedError, "Unhandled #{type.kind} input type"
    end
  end

  def java_output_type(type)
    type = type.unwrap_non_null
    case type.kind
    when "SCALAR"
      scalars[type.name].nullable_type
    when 'LIST'
      "List<#{java_output_type(type.of_type)}>"
    when 'ENUM', 'OBJECT', 'INTERFACE', 'UNION'
      type.name
    else
      raise NotImplementedError, "Unhandled #{type.kind} response type"
    end
  end

  def generate_build_input_code(expr, type, depth: 1)
    type = type.unwrap_non_null
    case type.kind
    when 'SCALAR'
      if ['Int', 'Float', 'Boolean'].include?(type.name)
        "_queryBuilder.append(#{expr});"
      else
        "Query.appendQuotedString(_queryBuilder, #{expr}.toString());"
      end
    when 'ENUM'
      "_queryBuilder.append(#{expr}.toString());"
    when 'LIST'
      item_type = type.of_type
      <<-JAVA
        _queryBuilder.append('[');

        String listSeperator#{depth} = "";
        for (#{java_input_type(item_type)} item#{depth} : #{expr}) {
          _queryBuilder.append(listSeperator#{depth});
          listSeperator#{depth} = ",";
          #{generate_build_input_code("item#{depth}", item_type, depth: depth + 1)}
        }
        _queryBuilder.append(']');
      JAVA
    when 'INPUT_OBJECT'
      "#{expr}.appendTo(_queryBuilder);"
    else
      raise NotImplementedError, "Unexpected #{type.kind} argument type"
    end
  end

  def generate_build_output_code(expr, type, depth: 1, non_null: false, &block)
    if type.non_null?
      return generate_build_output_code(expr, type.of_type, depth: depth, non_null: true, &block)
    end

    statements = ""
    unless non_null
      optional_name = "optional#{depth}"
      generate_build_output_code(expr, type, depth: depth, non_null: true) do |item_statements, item_expr|
        statements = <<-JAVA
          #{java_output_type(type)} #{optional_name} = null;
          if (!#{expr}.isJsonNull()) {
            #{item_statements}
            #{optional_name} = #{item_expr};
          }
        JAVA
      end
      return yield statements, optional_name
    end

    expr = case type.kind
    when 'SCALAR'
      scalars[type.name].deserialize(expr)
    when 'LIST'
      list_name = "list#{depth}"
      element_name = "element#{depth}"
      generate_build_output_code(element_name, type.of_type, depth: depth + 1) do |item_statements, item_expr|
        statements = <<-JAVA
          #{java_output_type(type)} #{list_name} = new ArrayList<>();
          for (JsonElement #{element_name} : jsonAsArray(#{expr}, key)) {
            #{item_statements}
            #{list_name}.add(#{item_expr});
          }
        JAVA
      end
      list_name
    when 'OBJECT'
      "new #{type.name}(jsonAsObject(#{expr}, key))"
    when 'INTERFACE', 'UNION'
      "Unknown#{type.name}.create(jsonAsObject(#{expr}, key))"
    when 'ENUM'
       "#{type.name}.fromGraphQl(jsonAsString(#{expr}, key))"
    else
      raise NotImplementedError, "Unexpected #{type.kind} argument type"
    end
    yield statements, expr
  end

  def java_arg_defs(field, skip_optional: false)
    defs = []
    field.required_args.each do |arg|
      defs << "#{java_input_type(arg.type)} #{escape_reserved_word(arg.camelize_name)}"
    end
    unless field.optional_args.empty? || skip_optional
      defs << "#{field.classify_name}ArgumentsDefinition argsDef"
    end
    if field.subfields?
      defs << "#{field.type.unwrap.name}QueryDefinition queryDef"
    end
    defs.join(', ')
  end

  def java_required_arg_defs(field)
    defs = []
    field.required_args.each do |arg|
      defs << "#{java_input_type(arg.type)} #{escape_reserved_word(arg.camelize_name)}"
    end
    unless field.optional_args.empty?
      defs << "#{field.classify_name}ArgumentsDefinition argsDef"
    end
    if field.subfields?
      defs << "#{field.type.unwrap.classify_name}QueryDefinition queryDef"
    end
    defs.join(', ')
  end

  def java_arg_expresions_with_empty_optional_args(field)
    expressions = field.required_args.map { |arg| escape_reserved_word(arg.camelize_name) }
    expressions << "args -> {}"
    if field.subfields?
      expressions << "queryDef"
    end
    expressions.join(', ')
  end

  def java_implements(type)
    return "implements #{type.name} " unless type.object?
    return "" if type.interfaces.empty?
    "implements #{type.interfaces.map{ |interface| interface.name }.join(', ')} "
  end

  def java_annotations(field)
    @annotations.map do |annotation|
      "@#{annotation.name}" if annotation.annotate?(field)
    end.compact.join("\n")
  end

  def type_names_set
    @type_names_set ||= schema.types.map(&:name).to_set
  end
end
