require_relative "xcode/project_helper"
require_relative "xcode/unchanged_storyboard_finder"
require_relative "xcode/error_extractor"

module Dokumi
  module Tool
    class Xcode
      def initialize(environment)
        @environment = environment
        @xcode_version = :default
      end

      def use_xcode_version(version)
        version = version.to_s
        version = :default if version == "default"
        configuration = self.class.read_configuration
        raise "Xcode version #{version} is not configured in xcode_versions.yml" unless configuration[version]
        @xcode_version = version
      end

      def modify_project(xcodeproj_path)
        yield Xcode::ProjectHelper.new(xcodeproj_path)
      end

      def icon_paths_in_project(xcodeproj_path)
        Xcode::ProjectHelper.new(xcodeproj_path).icon_paths
      end

      def analyze(project_path, options)
        Support.validate_hash options, requires_only: :scheme
        @environment.action_executed = true

        xcodebuild project_path, actions: :analyze, scheme: options[:scheme], sdk: "iphoneos"

        project_basename = File.basename(project_path, File.extname(project_path))
        static_analyzer_plist_pattern = @environment.work_directory.join(
          "Build",
          "Intermediates",
          "#{project_basename}.build",
          "**",
          "StaticAnalyzer",
          "**",
          "*.plist"
        )
        Dir.glob(static_analyzer_plist_pattern).each do |plist_path|
          content = Xcodeproj::PlistHelper.read(plist_path)
          next unless content["clang_version"] and content["files"] and content["diagnostics"]
          next if content["files"].empty? or content["diagnostics"].empty?
          content["diagnostics"].each do |diagnostic|
            location = diagnostic["location"]
            @environment.add_issue(
              file_path: content["files"][location["file"]],
              line: location["line"].to_i,
              column: location["col"].to_i,
              type: :static_analysis,
              description: diagnostic["description"],
            )
          end
        end
      end

      def test(project_path, options)
        Support.validate_hash options, requires_only: [:scheme, :destination]
        @environment.action_executed = true

        [ options[:destination] ].flatten.each do |destination|
          Support::Shell.quit_osx_application "iOS Simulator"
          xcodebuild project_path, actions: :test, scheme: options[:scheme], sdk: "iphonesimulator", destination: destination
          Support::Shell.quit_osx_application "iOS Simulator"
        end
      end

      def archive(project_path, options)
        Support.validate_hash options, requires_only: :scheme
        @environment.action_executed = true

        project_basename = File.basename(project_path, File.extname(project_path))
        archive_path = @environment.work_directory.join("#{project_basename}.xcarchive")
        ipa_path = @environment.work_directory.join("#{project_basename}.ipa")

        xcodebuild project_path, actions: :archive, scheme: options[:scheme], sdk: "iphoneos", archive_path: archive_path
        raise "an error was found while build the archive" if @environment.error_found?

        # As xcodebuild -exportArchive doesn't seem to work properly with WatchKit apps, I ended up making the IPA file by hand.
        # https://devforums.apple.com/message/1120211#1120211 has some information about doing that:
        # If you are building your final product outside of Xcode (or have interesting build scripts), before zipping contents to create the IPA, you should:
        # 1. Create a directory named WatchKitSupport as a sibling to Payload.
        # 2. Copy a binary named "WK" from the iOS 8.2 SDK in Xcode to your new WatchKitSupport directory. This binary can be found at:
        #  /Applications/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS.sdk/Library/Application Support/WatchKit/
        # 3. Make sure the "WK" binary is not touched/re-signed in any way. This is important for validation on device.
        # 4. Zip everything into an IPA.
        #
        # When expanded the IPA should contain (at least):
        # xxx.ipa
        # |________Payload/
        # |________Symbols/
        # |________WatchKitSupport/
        #                    |_____WK
        # That should help when building.
        directory_for_archiving = @environment.work_directory.join("archiving")
        directory_for_archiving.mkpath
        Dir.chdir(directory_for_archiving) do
          # we are creating symbolic links, but in the zip (ipa) they will be stored as normal directories (and that's what we want)
          FileUtils.ln_s archive_path.join("Products", "Applications"), "Payload"
          ["WatchKitSupport", "SwiftSupport"].each do |support_type|
            support_source_path = archive_path.join(support_type)
            FileUtils.ln_s support_source_path, support_source_path.basename if support_source_path.exist?
          end

          Support::Shell.run "zip", "-r", ipa_path, "."
          @environment.add_artifacts ipa_path
        end

        to_archive = archive_path.join("dSYMs").children + archive_path.join("Products", "Applications").children
        to_archive.select! {|path| [ ".app", ".dSYM" ].include?(path.extname) }
        to_archive.each do |path|
          Dir.chdir path.dirname do
            zip_path = @environment.work_directory.join("#{path.basename}.zip")
            Support::Shell.run "zip", "-r", zip_path, path.basename
            @environment.add_artifacts zip_path
          end
        end

      end

      def install_pods
        raise "does not use CocoaPods" unless File.exist?("Podfile")
        args = ["install"]
        if File.exist?("Gemfile")
          Support::Shell.run "bundle", "install"
          command = ["bundle", "exec", "pod", *args]
        elsif File.exist?("Podfile.lock")
          cocoapods_version = YAML.load(IO.read("Podfile.lock"))["COCOAPODS"]
          command = ["pod", "_#{cocoapods_version}_", *args]
        else
          command = ["pod", *args]
        end
        Support::Shell.run *command
        Support::Shell.popen_each_line(*command) do |type, line|
          puts line
          if type == :error and line.start_with?("[!] ")
            description = line.sub("[!] ", "").strip
            @environment.add_issue type: :warning, description: description
          end
        end
      end

      def find_unchanged_storyboards
        @environment.action_executed = true
        UnchangedStoryboardFinder.find_issues @environment
      end

      private

      def xcodebuild(project_path, options)
        Support.validate_hash options, requires: [:scheme, :actions, :sdk], can_also_have: [:destination, :archive_path]

        configuration = self.class.read_configuration
        xcode_version = @xcode_version
        if xcode_version == :default
          xcode_version = configuration[:default]
          raise "either set an explicit version of Xcode in the build script, or set a default Xcode version in xcode_versions.yml" unless xcode_version
          # default might point to either a version number or directly to a path
          if configuration[xcode_version]
            xcode_path = configuration[xcode_version]
          else
            xcode_path = xcode_version
          end
        else
          xcode_path = configuration[xcode_version]
        end
        raise "Xcode version #{xcode_version} is not configured in xcode_versions.yml" unless xcode_path
        xcode_path = Support.make_pathname(xcode_path)
        raise "#{xcode_path} doesn't point to a existing Xcode" unless xcode_path.exist?
        xcodebuild_path = xcode_path.join("Contents", "Developer", "usr", "bin", "xcodebuild")
        raise "cannot find xcodebuild at #{xcodebuild_path}" unless xcodebuild_path.exist?

        args = [ xcodebuild_path ]
        case File.extname(project_path)
        when ".xcodeproj"
          args << [ "-project", project_path ]
        when ".xcworkspace"
          args << [ "-workspace", project_path ]
        else
          raise "unknown project type for #{project_path}"
        end
        args << [ "-scheme", options[:scheme] ]
        args << [ "-sdk", options[:sdk] ]
        args << [ "-derivedDataPath", @environment.work_directory ]
        args << [ "-archivePath", options[:archive_path] ] if options[:archive_path]
        args << [ "-destination", options[:destination] ] if options[:destination]
        args << options[:actions]
        args.flatten!

        log_file_path = @environment.work_directory.join("xcodebuild-#{Time.new.strftime("%Y%m%d-%H%M%S%L")}.log")
        exit_code = nil
        error_extractor = ErrorExtractor.new(@environment)
        File.open(log_file_path, "w") do |log_file|
          log_file.puts "running #{args.inspect}"
          puts "redirecting output to #{log_file_path}"
          exit_code = Support::Shell.popen_each_line(*args, allow_errors: true) do |output_type, line|
            log_file.puts "#{output_type.to_s.upcase[0..2]}: #{line}"
            error_extractor.process_line(output_type, line)
          end
          error_extractor.flush
        end
        puts # make some space

        if exit_code != 0 and !error_extractor.new_error_found
          raise "unkown error (#{exit_code}) happened while running xcodebuild"
        end
      rescue
        if log_file_path and log_file_path.exist?
          STDERR.puts "An error occurred - displaying the 200 last lines of the log."
          STDERR.puts `tail -200 #{log_file_path.to_s.shellescape}`
        end
        raise
      end

      def self.read_configuration
        configuration_path = BASE_DIRECTORY.join("config", "xcode_versions.yml")
        unless configuration_path.exist?
          # if there is no existing Xcode configuration, just create a default one
          default_path = `xcode-select -p 2> /dev/null`.strip.sub(%r{/Contents/Developer\z}, "")
          default_path = "/Applications/Xcode.app" if default_path.empty?
          IO.write(configuration_path, "default: \"#{default_path}\"")
        end
        raw_configuration = YAML.load(IO.read(configuration_path))
        configuration = {}
        raw_configuration.each do |key, value|
          # 6.2 might be read as a float so make sure to make keys string
          key = key == "default" ? :default : key.to_s
          configuration[key] = value.to_s
        end
        configuration
      end

    end
  end
end
