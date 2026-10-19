require 'minitest/autorun'
require 'ostruct'
require_relative 'testflight_contract'

class TestFlightContractTest < Minitest::Test
  def group(internal: true, testers: [Object.new])
    OpenStruct.new(id: 'group', name: 'Companion Internal', is_internal_group: internal, beta_testers: testers)
  end

  def build(**attributes)
    OpenStruct.new({ id: 'build', bundle_id: CompanionTestFlight::BUNDLE_ID,
      app_version: '0.1.0', version: '35', platform: 'IOS', processing_state: 'VALID', expired: false,
      build_beta_detail: OpenStruct.new(internal_build_state: 'IN_BETA_TESTING') }.merge(attributes))
  end

  def test_number_allocation_rejects_unknown_state_instead_of_resetting
    assert_equal '1', CompanionTestFlight.next_build_number(0)
    assert_equal '35', CompanionTestFlight.next_build_number(34)
    [nil, '', 'unknown', '1.2.3', '-1'].each do |value|
      assert_raises(RuntimeError) { CompanionTestFlight.next_build_number(value) }
    end
  end

  def test_distribution_selects_existing_internal_groups_with_testers
    assert_equal ['group'], CompanionTestFlight.internal_groups([group, group(internal: false)]).map(&:id)
    [[], [group(internal: false)], [group(testers: [])]].each do |groups|
      assert_raises(RuntimeError) { CompanionTestFlight.internal_groups(groups) }
    end
  end

  def test_only_the_exact_processed_group_build_is_available
    assert_equal 'build', CompanionTestFlight.available_build([build], '0.1.0', '35', ['build']).id
    [[], [build, build], [build(bundle_id: 'com.invalid.other')], [build(version: '36')],
     [build(platform: 'MAC_OS')], [build(processing_state: 'PROCESSING')], [build(processing_state: 'INVALID')],
     [build(expired: true)], [build(build_beta_detail: nil)],
     [build(build_beta_detail: OpenStruct.new(internal_build_state: 'MISSING_EXPORT_COMPLIANCE'))]].each do |builds|
      assert_raises(RuntimeError) { CompanionTestFlight.available_build(builds, '0.1.0', '35', ['build']) }
    end
    assert_raises(RuntimeError) { CompanionTestFlight.available_build([build], '0.1.0', '35', []) }
  end
end
