# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"
require "stringio"

# Runs the real Linux helper script (without sudo) against a fake nft that
# logs what it's asked to load, so no real firewall is touched.
class NftIsolationTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
    @log = File.join(@dir, "nft.log")
    @nft = File.join(@dir, "nft")
    File.write(@nft, <<~SH)
      #!/bin/sh
      [ -e #{@dir}/fail ] && { echo "Error: Could not process rule: Operation not permitted"; exit 1; }
      printf '%s\\n' "$*" >> #{@log}
      cat >> #{@log}
      echo "--" >> #{@log}
      exit 0
    SH
    File.chmod(0o755, @nft)
    @iso = Merlin::NftIsolation.new(state_path: File.join(@dir, "isolation.json"), interface: "wlan0",
                                    sudo: [], nft: @nft, out: StringIO.new)
  end

  def teardown
    @iso&.shutdown_helper
    FileUtils.rm_rf(@dir)
  end

  def test_rules_only_let_the_transfer_and_dhcp_out_of_the_speaker_subnet
    rules = @iso.rules
    assert rules.start_with?("table inet merlin\ndelete table inet merlin\n"), "loading must replace any leftover table"
    assert_includes rules, %(oifname "wlan0" ip daddr 192.168.4.1 tcp dport 50000 accept)
    assert_includes rules, %(oifname "wlan0" udp sport 68 udp dport 67 accept)
    assert_includes rules, %(oifname "wlan0" ip saddr 192.168.4.0/24 drop)
  end

  def test_on_and_off_through_one_helper
    @iso.authorize!
    2.times do
      @iso.enable!
      assert @iso.active?
      assert @iso.leftover?
      @iso.disable!
      refute @iso.active?
      refute @iso.leftover?
    end
    loads = File.read(@log).split("--\n")
    assert_equal 4, loads.size
    assert_equal "-f -\n#{@iso.rules}", loads[0]
    assert_equal "-f -\ntable inet merlin\ndelete table inet merlin\n", loads[1]
  end

  def test_leftover_from_a_crashed_run_is_cleaned_before_enabling
    File.write(File.join(@dir, "isolation.json"), JSON.generate(token: nil))
    @iso.authorize!
    @iso.enable!
    loads = File.read(@log).split("--\n")
    assert_equal ["-f -\ntable inet merlin\ndelete table inet merlin\n", "-f -\n#{@iso.rules}"], loads
  end

  def test_nft_failure_is_reported_and_the_helper_stays_usable
    File.write(File.join(@dir, "fail"), "")
    @iso.authorize!
    err = assert_raises(Merlin::Error) { @iso.enable! }
    assert_match(/nft on failed: Error: Could not process rule: Operation not permitted/, err.message)
    File.delete(File.join(@dir, "fail"))
    assert @iso.enable!
  end
end
