module Dokumi
  module Tool
    class Android
      class FindBugs
        FINDBUGS_REPORT_FILE = "build/reports/findbugs/findbugs.xml"

        class << self
          def parse_report(target_project)
            report_path = Support.make_pathname(target_project).join(FINDBUGS_REPORT_FILE)
            File.open(report_path) do |file|
              report = Nokogiri::XML(file)

              report.xpath("//BugInstance").map do |info|
                source_path = info.xpath("SourceLine/@sourcepath").first.to_s
                file_path = Pathname.pwd.join(target_project, "src/main/java", source_path)

                {
                    description: info.xpath("LongMessage/text()").first.to_s,
                    file_path: file_path,
                    line: info.xpath("SourceLine/@start").first.to_s.to_i,
                }
              end
            end
          end
        end
      end
    end
  end
end
