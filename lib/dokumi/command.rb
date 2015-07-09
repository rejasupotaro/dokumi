module Dokumi
  module Command
    def self.archive(host, owner, repo, branch_or_tag_name, environment_options = {})
      prepare_directories_and_options host, owner, repo, environment_options

      type, branch_or_tag_name = VersionControl::GitHub.branch_or_tag(host, owner, repo, branch_or_tag_name)
      if type == :branch
        environment_options[:branch] = branch_or_tag_name
        branch_or_tag = VersionControl::GitHub::Branch.new(host, owner, repo, branch_or_tag_name)
      elsif type == :tag
        environment_options[:tag] = branch_or_tag_name
        branch_or_tag = VersionControl::GitHub::Tag.new(host, owner, repo, branch_or_tag_name)
      else
        raise "Unknown type #{type.inspect}."
      end
      local_copy = branch_or_tag.fetch_into(environment_options[:source_directory])

      environment_options[:local_copy] = local_copy
      BuildEnvironment.build_project(:archive, environment_options)
    end

    def self.review(host, owner, repo, pull_request_number, environment_options = {})
      prepare_directories_and_options host, owner, repo, environment_options

      pull_request = VersionControl::GitHub::PullRequest.new(host, owner, repo, pull_request_number)
      local_copy = pull_request.fetch_into(environment_options[:source_directory])

      environment_options[:pull_request] = pull_request
      environment_options[:branch] = pull_request.head.ref
      environment_options[:local_copy] = local_copy
      environment = BuildEnvironment.build_project(:review, environment_options)

      diff = local_copy.diff_with_merge_base
      issues = diff.filter_out_unrelated_issues(environment.issues, lines_around_related: environment.lines_around_related)
      pull_request.add_comments_for_issues(issues, diff) unless environment_options[:skip_comment_creation]

      issues
    end

    def self.review_and_report(host, owner, repo, pull_request_number, environment_options)
      issues = review(host, owner, repo, pull_request_number, environment_options)

      if issues.length == 0
        puts "great, no issue found"
        exit true
      else
        puts "issues found:"
        issues.each do |issue|
          puts "- #{issue[:file_path]}:#{issue[:line]}: #{issue[:description]}"
        end
        if issues.all? {|issue| issue[:type] == :warning }
          puts "warnings only - should be fixed but not considered a failure"
          exit true
        else
          puts "exiting in error"
          exit false
        end
      end
    end

    def self.prepare_directories_and_options(host, owner, repo, environment_options)
      repository = {owner: owner, repo: repo}

      work_directory = Support.make_pathname(environment_options[:work_directory])
      if work_directory and work_directory.exist?
        puts "warning: removing #{work_directory}"
      else
        work_directory = BASE_DIRECTORY.join("work", host, owner, repo)
      end
      environment_options[:work_directory] = work_directory
      environment_options[:source_directory] = BASE_DIRECTORY.join("source", host, owner, repo)
      if environment_options[:build_script]
        build_script_path = Support.make_pathname(environment_options.delete(:build_script))
        raise "Cannot find the build script asked for #{build_script_path}." unless build_script_path.exist?
      else
        build_script_path = BASE_DIRECTORY.join("custom", "build", host, owner, "#{repo}.rb")
        build_script_path = BASE_DIRECTORY.join("custom", "build", host, "fallback.rb") unless build_script_path.exist?
        build_script_path = BASE_DIRECTORY.join("custom", "build", "fallback.rb") unless build_script_path.exist?
        raise "Cannot find a build script for the #{owner}/#{repo} repository on #{host}." unless build_script_path.exist?
      end
      puts "building with script #{build_script_path}"
      environment_options[:build_script_path] = build_script_path

      work_directory.rmtree if work_directory.exist?
      work_directory.mkpath
    end

    def self.extract_environment_options
      environment_options = {}
      ARGV.delete_if do |arg|
        if (md = /\A--([a-z_0-9]+)=(.*)\z/m.match(arg))
          environment_options[md[1]] = md[2]
          true
        else
          false
        end
      end
      Support.symbolize_keys environment_options
    end
  end
end