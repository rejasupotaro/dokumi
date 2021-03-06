module Dokumi
  # modules the tools are loaded in
  module Tool end # module for Dokumi's inside tools
  module Custom # module for the user's custom code
    module Tool end # custom tools
  end
  class BuildEnvironment
    attr_reader :action, :options, :lines_around_related
    attr_writer :action_executed

    DEFAULT_LINES_AROUND_RELATED = 20
    def initialize(action, options)
      Support.validate_hash options, requires: [:work_directory, :source_directory]

      @action = action
      @options = options
      @issues = []
      @lines_around_related = options.delete(:lines_around_related) || DEFAULT_LINES_AROUND_RELATED
      @artifacts = []

      @tools = {}
      {
        Support.make_pathname(__FILE__).dirname.join("tool").realpath => Dokumi::Tool,
        BASE_DIRECTORY.join("custom", "tool") => Dokumi::Custom::Tool,
      }.each do |tools_directory, owner|
        next unless tools_directory.exist?
        tools_directory.each_child do |child_path|
          next if child_path.directory? or child_path.extname != ".rb"
          require child_path
          tool_name = child_path.basename(child_path.extname).to_s.to_sym
          class_name = Support.camel_case(tool_name)
          if methods.include?(tool_name) || @tools.include?("tool_name")
            raise "you cannot have an add-on named #{tool_name}"
          end
          define_singleton_method(tool_name) do
            @tools[tool_name] ||= owner.const_get(class_name).new(self)
          end
        end
      end
    end

    VALID_ISSUE_TYPES = [:warning, :static_analysis, :error]
    def add_issue(new_issue)
      Support.validate_hash new_issue, requires: [:type, :description], can_also_have: [:file_path, :line, :column]
      raise "an issue type has to be one of #{VALID_ISSUE_TYPES.inspect}" unless VALID_ISSUE_TYPES.include?(new_issue[:type])

      if new_issue[:file_path]
        file_path = Support.make_pathname(new_issue[:file_path])
        file_path = file_path.relative_path_from(source_directory) unless file_path.relative?
        new_issue = new_issue.merge(file_path: file_path)
      end

      similar_issue_index = @issues.index do |compared_to|
        [ :file_path, :line, :column, :description ].all? {|key| compared_to[key] == new_issue[key] }
      end
      unless similar_issue_index
        @issues << new_issue
        return
      end

      similar_issue = @issues[similar_issue_index]

      # if a similar issue is present, keep the strongest type: error > static_analysis > warning
      return if similar_issue[:type] == :error or similar_issue[:type] == new_issue[:type]
      @issues[similar_issue_index] = new_issue if [ :error, :static_analysis ].include?(new_issue[:type])
    end

    def add_artifacts(*artifacts)
      @artifacts.concat artifacts.flatten.map {|artifact| Support.make_pathname(artifact) }
      @artifacts.uniq!
    end

    def error_found?
      @issues.any? {|issue| issue[:type] == :error }
    end

    def action_executed?
      @action_executed
    end

    def issues
      @issues.dup.freeze
    end

    def artifacts
      @artifacts.dup.freeze
    end

    [
      :work_directory,
      :source_directory,
    ].each do |option_type|
      define_method(option_type) { @options[option_type] }
    end

    def make_identifier_updater(replacements)
      lambda do |value|
        replacements.each do |to_replace, replacement|
          if value == to_replace or value.start_with?("#{to_replace}.")
            value = value.sub(to_replace, replacement)
          end
        end
        value
      end
    end

    def run_script(build_script_path)
      Dir.chdir(source_directory) do
        instance_eval(IO.read(build_script_path), build_script_path.to_s)
      end
    end

    def self.build_project(action, environment_options)
      Support.validate_hash environment_options, requires: [:build_script_path, :work_directory, :source_directory]

      build_script_path = environment_options[:build_script_path]
      unless build_script_path.exist?
        raise "Cannot find build script #{build_script_path}."
      end
      build_environment = self.new(action, environment_options)
      build_environment.run_script(build_script_path)
      raise "No action executed." unless build_environment.action_executed?
      build_environment
    end
  end
end
