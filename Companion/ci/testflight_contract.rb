require 'json'
require 'fileutils'

module CompanionTestFlight
  BUNDLE_ID = 'com.maurice.semreh'.freeze
  TEAM_ID = '6D65NQ2V3Q'.freeze

  def self.next_build_number(latest)
    value = latest.to_s
    raise 'App Store Connect returned a noninteger build number' unless value.match?(/\A\d+\z/)
    (Integer(value, 10) + 1).to_s
  end

  def self.internal_groups(groups)
    matches = groups.select do |group|
      group.is_internal_group == true && group.beta_testers && !group.beta_testers.empty?
    end
    raise 'Semreh must have at least one populated internal TestFlight group' if matches.empty?
    matches
  end

  def self.available_build(builds, version, number, group_build_ids)
    matches = builds.select do |build|
      build.bundle_id == BUNDLE_ID && build.app_version == version && build.version == number && build.platform == 'IOS'
    end
    raise 'App Store Connect did not return exactly one matching build' unless matches.length == 1
    build = matches.first
    raise "Apple processing state is #{build.processing_state}" unless build.processing_state == 'VALID'
    raise 'Apple reports that the build has expired' unless build.expired == false
    state = build.build_beta_detail&.internal_build_state
    raise "Internal testing is not available (#{state})" unless %w[READY_FOR_BETA_TESTING IN_BETA_TESTING].include?(state)
    raise 'The build is not assigned to the selected internal group' unless group_build_ids.include?(build.id)
    build
  end

  def self.write_receipt(path, receipt)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, JSON.pretty_generate(receipt) + "\n")
  end
end
